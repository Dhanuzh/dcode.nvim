-- lua/dcode/ui.lua
-- Chat window: persistent buffer, nvim_buf_set_text streaming, extmark spinner,
-- 50ms throttle, conditional cursor follow, named filetype.
-- Pattern credit: CopilotChat.nvim / avante.nvim

local M = {}

-- ─── Highlight setup ─────────────────────────────────────────────────────────

local HL = {
  border    = "DcodeBorder",
  title     = "DcodeTitle",
  user      = "DcodeUser",
  assistant = "DcodeAssistant",
  tool      = "DcodeTool",
  thinking  = "DcodeThinking",
  cost      = "DcodeCost",
  separator = "DcodeSeparator",
  status_ok = "DcodeStatusOk",
  status_err= "DcodeStatusErr",
}

function M.setup_highlights()
  local h = function(g, o) vim.api.nvim_set_hl(0, g, o) end
  h(HL.border,    { fg = "#7aa2f7", bold = true })
  h(HL.title,     { fg = "#bb9af7", bold = true })
  h(HL.user,      { fg = "#9ece6a", bold = true })
  h(HL.assistant, { fg = "#7dcfff", bold = true })
  h(HL.tool,      { fg = "#e0af68", italic = true })
  h(HL.thinking,  { fg = "#565f89", italic = true })
  h(HL.cost,      { fg = "#565f89" })
  h(HL.separator, { fg = "#3b4261" })
  h(HL.status_ok, { fg = "#9ece6a" })
  h(HL.status_err,{ fg = "#f7768e" })
end

-- ─── State ───────────────────────────────────────────────────────────────────

local ns_spinner = vim.api.nvim_create_namespace("dcode_spinner")
local ns_header  = vim.api.nvim_create_namespace("dcode_header")

-- Single persistent chat buffer (never wiped, only grown)
local chat_buf  = nil   ---@type integer|nil
local chat_win  = nil   ---@type integer|nil

-- Streaming state
local stream = {
  active     = false,
  buf        = "",          -- partial line accumulator
  last_line  = 0,           -- 0-based line of the partial cursor line
  last_col   = 0,           -- byte col of end of partial line
  timer      = nil,         -- throttle timer
  pending    = false,       -- dirty flag for throttle
}

local spinner_extmark_id = nil
local SPINNER_FRAMES = { "⠋","⠙","⠹","⠸","⠼","⠴","⠦","⠧","⠇","⠏" }
local spinner_idx = 0
local spinner_timer = nil

-- ─── Buffer helpers ───────────────────────────────────────────────────────────

local function buf_valid()
  return chat_buf ~= nil and vim.api.nvim_buf_is_valid(chat_buf)
end

local function win_valid()
  return chat_win ~= nil and vim.api.nvim_win_is_valid(chat_win)
end

local function buf_set(name, value)
  if not buf_valid() then return end
  vim.api.nvim_set_option_value(name, value, { buf = chat_buf })
end

local function win_set_opt(name, value)
  if not win_valid() then return end
  vim.api.nvim_set_option_value(name, value, { win = chat_win })
end

--- Set buf modifiable, run fn, restore to non-modifiable.
local function with_modifiable(fn)
  if not buf_valid() then return end
  vim.api.nvim_set_option_value("modifiable", true, { buf = chat_buf })
  local ok, err = pcall(fn)
  vim.api.nvim_set_option_value("modifiable", false, { buf = chat_buf })
  if not ok then vim.notify("[dcode] ui error: " .. tostring(err), vim.log.levels.ERROR) end
end

--- Append lines to buffer. Conditionally auto-scroll.
local function buf_append_lines(lines)
  if not buf_valid() then return end
  with_modifiable(function()
    local count = vim.api.nvim_buf_line_count(chat_buf)
    vim.api.nvim_buf_set_lines(chat_buf, count, count, false, lines)
  end)
  if win_valid() then
    local count   = vim.api.nvim_buf_line_count(chat_buf)
    local cur_row = vim.api.nvim_win_get_cursor(chat_win)[1]
    -- Only auto-scroll if cursor is near the bottom (within 3 lines)
    -- Respects user scrolling up to review history
    if cur_row >= count - 3 then
      vim.api.nvim_win_set_cursor(chat_win, { count, 0 })
    end
  end
end

-- ─── Spinner ─────────────────────────────────────────────────────────────────

local function spinner_stop()
  if spinner_timer then
    spinner_timer:stop()
    spinner_timer:close()
    spinner_timer = nil
  end
  if buf_valid() and spinner_extmark_id then
    pcall(vim.api.nvim_buf_del_extmark, chat_buf, ns_spinner, spinner_extmark_id)
    spinner_extmark_id = nil
  end
end

local function spinner_start()
  spinner_stop()
  if not buf_valid() then return end
  spinner_idx = 0
  spinner_timer = vim.loop.new_timer()
  spinner_timer:start(0, 80, vim.schedule_wrap(function()
    if not buf_valid() then spinner_stop(); return end
    spinner_idx = (spinner_idx % #SPINNER_FRAMES) + 1
    local last = math.max(0, vim.api.nvim_buf_line_count(chat_buf) - 1)
    spinner_extmark_id = vim.api.nvim_buf_set_extmark(chat_buf, ns_spinner, last, 0, {
      id       = spinner_extmark_id or nil,
      virt_text= { { " " .. SPINNER_FRAMES[spinner_idx] .. " thinking…", HL.thinking } },
      virt_text_pos = "eol",
    })
  end))
end

-- ─── Window open / close / toggle ────────────────────────────────────────────

--- Ensure a persistent chat buffer exists.
local function ensure_buf()
  if buf_valid() then return end
  chat_buf = vim.api.nvim_create_buf(false, true)
  -- Named filetype so treesitter renders markdown inside it
  vim.api.nvim_set_option_value("filetype",   "dcode-chat", { buf = chat_buf })
  vim.api.nvim_set_option_value("bufhidden",  "hide",       { buf = chat_buf })
  vim.api.nvim_set_option_value("modifiable", false,        { buf = chat_buf })
  vim.api.nvim_set_option_value("buftype",    "nofile",     { buf = chat_buf })
  -- Register dcode-chat as markdown for treesitter
  pcall(vim.treesitter.language.register, "markdown", "dcode-chat")
  -- Show welcome lines
  with_modifiable(function()
    vim.api.nvim_buf_set_lines(chat_buf, 0, -1, false, {
      "  dcode chat",
      "  i / <leader>da  — ask",
      "  q / <Esc>       — close",
      "  <leader>ds      — browse sessions",
      "",
    })
  end)
end

---@param opts table  { style, width, height }
function M.open(opts)
  opts = opts or {}
  local style = opts.style  or "float"
  local wfrac = opts.width  or 0.45
  local hfrac = opts.height or 0.80

  if win_valid() then
    vim.api.nvim_set_current_win(chat_win)
    return
  end

  ensure_buf()

  local win
  if style == "float" then
    local tw = vim.o.columns
    local th = vim.o.lines - vim.o.cmdheight - 2
    local w  = math.floor(tw * wfrac)
    local h  = math.floor(th * hfrac)
    win = vim.api.nvim_open_win(chat_buf, true, {
      relative  = "editor",
      width     = w,
      height    = h,
      row       = math.floor((th - h) / 2),
      col       = math.floor((tw - w) / 2),
      style     = "minimal",
      border    = "rounded",
      title     = " dcode ",
      title_pos = "center",
    })
  elseif style == "vsplit" then
    vim.cmd("vsplit")
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, chat_buf)
    vim.api.nvim_win_set_width(win, math.floor(vim.o.columns * wfrac))
  else
    vim.cmd("split")
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, chat_buf)
    vim.api.nvim_win_set_height(win, math.floor(vim.o.lines * hfrac))
  end

  chat_win = win

  vim.api.nvim_set_option_value("wrap",        true,  { win = win })
  vim.api.nvim_set_option_value("linebreak",   true,  { win = win })
  vim.api.nvim_set_option_value("number",      false, { win = win })
  vim.api.nvim_set_option_value("signcolumn",  "no",  { win = win })
  vim.api.nvim_set_option_value("cursorline",  false, { win = win })
  -- Suppress any background highlight bleed (code fences, visual, etc.)
  vim.api.nvim_set_option_value("winhighlight",
    "Normal:Normal,NormalFloat:Normal,FloatBorder:" .. HL.border ..
    ",CursorLine:Normal,Search:None,IncSearch:None",
    { win = win })

  -- Scroll to bottom on open
  local count = vim.api.nvim_buf_line_count(chat_buf)
  vim.api.nvim_win_set_cursor(win, { count, 0 })

  -- Buffer-local close / input keymaps
  local ko = { buffer = chat_buf, noremap = true, silent = true }
  vim.keymap.set("n", "q",     function() M.close() end, ko)
  vim.keymap.set("n", "<Esc>", function() M.close() end, ko)
  vim.keymap.set("n", "i",     function()
    vim.schedule(function() require("dcode.commands").open_input() end)
  end, ko)
  vim.keymap.set("n", "<CR>",  function()
    vim.schedule(function() require("dcode.commands").open_input() end)
  end, ko)
end

function M.close()
  if win_valid() then
    vim.api.nvim_win_close(chat_win, true)
  end
  chat_win = nil
  -- Also close the input window if open
  require("dcode.commands").close_input()
end

function M.toggle(opts)
  if win_valid() then
    M.close()
  else
    M.open(opts)
  end
end

-- ─── Chat rendering ───────────────────────────────────────────────────────────

local SEP = string.rep("─", 52)

--- Append a user message block.
---@param text string  Display text (clean, no code context)
function M.render_user(text)
  local lines = { "", "▶ You", SEP }
  for _, l in ipairs(vim.split(text, "\n", { plain = true })) do
    table.insert(lines, l)
  end
  table.insert(lines, "")
  buf_append_lines(lines)
end

--- Begin assistant reply. Resets stream state. Starts spinner.
function M.begin_assistant()
  -- Flush any orphaned stream buf from previous turn
  if stream.buf ~= "" and buf_valid() then
    with_modifiable(function()
      vim.api.nvim_buf_set_text(chat_buf, stream.last_line, stream.last_col, stream.last_line, stream.last_col, { stream.buf })
    end)
  end
  stream.buf    = ""
  stream.active = true

  -- Append header + empty streaming line
  buf_append_lines({ "◀ dcode", SEP, "" })

  if buf_valid() then
    local count = vim.api.nvim_buf_line_count(chat_buf)
    -- The empty "" we just appended is 1-indexed = count, 0-indexed = count-1
    stream.last_line = count - 1
    stream.last_col  = 0
  end

  spinner_start()
end

--- Flush the pending stream update (called by throttle timer and on done).
local function flush_stream()
  if not stream.active or not buf_valid() then return end
  with_modifiable(function()
    local text = stream.buf
    -- Split on newlines
    local parts = vim.split(text, "\n", { plain = true })
    if #parts == 1 then
      -- Still on same line — replace from last_col to current end
      local cur = vim.api.nvim_buf_get_lines(chat_buf, stream.last_line, stream.last_line + 1, false)[1] or ""
      vim.api.nvim_buf_set_text(
        chat_buf,
        stream.last_line, 0,
        stream.last_line, #cur,
        { parts[1] }
      )
    else
      -- Multiple lines: replace current line with first, append rest
      local cur = vim.api.nvim_buf_get_lines(chat_buf, stream.last_line, stream.last_line + 1, false)[1] or ""
      vim.api.nvim_buf_set_text(
        chat_buf,
        stream.last_line, 0,
        stream.last_line, #cur,
        parts
      )
      stream.last_line = stream.last_line + #parts - 1
      stream.last_col  = #parts[#parts]
    end
  end)
  -- Scroll if near bottom
  if win_valid() then
    local count   = vim.api.nvim_buf_line_count(chat_buf)
    local cur_row = vim.api.nvim_win_get_cursor(chat_win)[1]
    if cur_row >= count - 5 then
      vim.api.nvim_win_set_cursor(chat_win, { count, 0 })
    end
  end
  stream.pending = false
end

--- Accumulate streaming text from SSE chunks (50ms throttle).
---@param chunk string
function M.append_stream_text(chunk)
  if not stream.active then return end
  stream.buf = stream.buf .. chunk
  if stream.pending then return end
  stream.pending = true
  -- 50ms throttle — same as CopilotChat
  if not stream.timer then
    stream.timer = vim.loop.new_timer()
  end
  stream.timer:start(50, 0, vim.schedule_wrap(function()
    flush_stream()
  end))
end

--- Flush partial stream, then append a tool line.
---@param name   string
---@param detail string|nil
function M.render_tool(name, detail)
  flush_stream()
  local line = "  ⚙ " .. name
  if detail and detail ~= "" then
    line = line .. " — " .. detail:sub(1, 60)
  end
  buf_append_lines({ line })
  -- Reset stream anchor to new last line
  if buf_valid() then
    local count = vim.api.nvim_buf_line_count(chat_buf)
    buf_append_lines({ "" })
    stream.last_line = count  -- 0-indexed = count (since we just appended one empty)
    stream.last_col  = 0
    stream.buf = ""
  end
end

--- Flush partial stream, then append a thinking line.
---@param text string
function M.render_thinking(text)
  flush_stream()
  buf_append_lines({ "  ≋ " .. text:sub(1, 100) })
  if buf_valid() then
    local count = vim.api.nvim_buf_line_count(chat_buf)
    buf_append_lines({ "" })
    stream.last_line = count
    stream.last_col  = 0
    stream.buf = ""
  end
end

--- Finish assistant reply — flush buffer, stop spinner, append footer.
---@param cost   number|nil
---@param tokens table|nil  { input, output }
function M.end_assistant(cost, tokens)
  stream.active = false
  spinner_stop()

  -- Cancel throttle timer
  if stream.timer then
    stream.timer:stop()
    stream.timer:close()
    stream.timer = nil
  end

  -- Final flush
  flush_stream()
  stream.buf = ""

  -- Footer
  local footer = {}
  if tokens and ((tokens.input or 0) > 0 or (tokens.output or 0) > 0) then
    local s = string.format("  in:%d out:%d", tokens.input or 0, tokens.output or 0)
    if cost and cost > 0 then
      s = s .. string.format("  $%.5f", cost)
    end
    table.insert(footer, s)
  end
  table.insert(footer, "")
  buf_append_lines(footer)
end

--- Show error line in chat.
---@param msg string
function M.render_error(msg)
  stream.active = false
  spinner_stop()
  if stream.timer then stream.timer:stop(); stream.timer:close(); stream.timer = nil end
  stream.buf = ""
  buf_append_lines({ "", "  ✗ " .. msg, "" })
end

--- Update the floating window title.
---@param title string
function M.set_title(title)
  if win_valid() then
    pcall(vim.api.nvim_win_set_config, chat_win, {
      title     = " dcode — " .. title .. " ",
      title_pos = "center",
    })
  end
end

--- vim.notify wrapper.
function M.notify(msg, level)
  vim.notify("[dcode] " .. msg, level or vim.log.levels.INFO)
end

function M.is_open()
  return win_valid()
end

function M.bufnr()
  return chat_buf
end

--- Reset: clear buffer contents and session state (used by new_session).
function M.reset()
  stream.active = false
  stream.buf    = ""
  spinner_stop()
  if buf_valid() then
    with_modifiable(function()
      vim.api.nvim_buf_set_lines(chat_buf, 0, -1, false, {
        "  dcode chat — new session",
        "",
      })
    end)
    stream.last_line = 1
    stream.last_col  = 0
  end
end

return M
