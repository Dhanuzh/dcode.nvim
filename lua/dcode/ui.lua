-- lua/dcode/ui.lua
-- Chat window: right-side vsplit sidebar (avante-style).
-- Two windows: result (top, read-only) + input (bottom, 3-line editable pane).
-- Persistent chat buffer (bufhidden=hide), nvim_buf_set_text streaming,
-- 50ms throttle, extmark spinner. No nui / no external deps.
-- Pattern credit: avante.nvim / CopilotChat.nvim

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

-- Persistent chat buffer (never wiped once created)
local chat_buf  = nil   ---@type integer|nil
-- Result window (top pane of sidebar)
local result_win = nil  ---@type integer|nil
-- Input window handle — owned by commands.lua but we need to track it here
-- so close() can shut both panes down. Set via M.set_input_win().
local input_win  = nil  ---@type integer|nil

-- Streaming state
local stream = {
  active     = false,
  buf        = "",          -- partial line accumulator
  last_line  = 0,           -- 0-based line of the partial cursor line
  last_col   = 0,
  timer      = nil,         -- throttle timer
  pending    = false,
}

local spinner_extmark_id = nil
local SPINNER_FRAMES = { "⠋","⠙","⠹","⠸","⠼","⠴","⠦","⠧","⠇","⠏" }
local spinner_idx    = 0
local spinner_timer  = nil

-- ─── Validity helpers ────────────────────────────────────────────────────────

local function buf_valid()
  return chat_buf ~= nil and vim.api.nvim_buf_is_valid(chat_buf)
end

local function result_win_valid()
  return result_win ~= nil and vim.api.nvim_win_is_valid(result_win)
end

-- ─── Buffer helpers ───────────────────────────────────────────────────────────

--- Set buf modifiable, run fn, restore to non-modifiable.
local function with_modifiable(fn)
  if not buf_valid() then return end
  vim.api.nvim_set_option_value("modifiable", true,  { buf = chat_buf })
  local ok, err = pcall(fn)
  vim.api.nvim_set_option_value("modifiable", false, { buf = chat_buf })
  if not ok then vim.notify("[dcode] ui error: " .. tostring(err), vim.log.levels.ERROR) end
end

--- Append lines to chat buffer. Auto-scroll if near bottom.
local function buf_append_lines(lines)
  if not buf_valid() then return end
  with_modifiable(function()
    local count = vim.api.nvim_buf_line_count(chat_buf)
    vim.api.nvim_buf_set_lines(chat_buf, count, count, false, lines)
  end)
  if result_win_valid() then
    local count   = vim.api.nvim_buf_line_count(chat_buf)
    local cur_row = vim.api.nvim_win_get_cursor(result_win)[1]
    if cur_row >= count - 3 then
      vim.api.nvim_win_set_cursor(result_win, { count, 0 })
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
  spinner_idx   = 0
  spinner_timer = vim.loop.new_timer()
  spinner_timer:start(0, 80, vim.schedule_wrap(function()
    if not buf_valid() then spinner_stop(); return end
    spinner_idx = (spinner_idx % #SPINNER_FRAMES) + 1
    local last  = math.max(0, vim.api.nvim_buf_line_count(chat_buf) - 1)
    spinner_extmark_id = vim.api.nvim_buf_set_extmark(chat_buf, ns_spinner, last, 0, {
      id            = spinner_extmark_id or nil,
      virt_text     = { { " " .. SPINNER_FRAMES[spinner_idx] .. " thinking…", HL.thinking } },
      virt_text_pos = "eol",
    })
  end))
end

-- ─── Buffer creation ──────────────────────────────────────────────────────────

local function ensure_buf()
  if buf_valid() then return end
  chat_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("filetype",   "dcode-chat", { buf = chat_buf })
  vim.api.nvim_set_option_value("bufhidden",  "hide",       { buf = chat_buf })
  vim.api.nvim_set_option_value("modifiable", false,        { buf = chat_buf })
  vim.api.nvim_set_option_value("buftype",    "nofile",     { buf = chat_buf })
  -- Register as markdown so treesitter highlights code blocks etc.
  pcall(vim.treesitter.language.register, "markdown", "dcode-chat")
  with_modifiable(function()
    vim.api.nvim_buf_set_lines(chat_buf, 0, -1, false, {
      "  dcode chat",
      "  i / <CR>      — ask",
      "  q / <Esc>     — close",
      "  <leader>ds    — browse sessions",
      "",
    })
  end)
end

-- ─── Window options helper ────────────────────────────────────────────────────

local function apply_win_opts(win)
  vim.api.nvim_set_option_value("wrap",       true,  { win = win })
  vim.api.nvim_set_option_value("linebreak",  true,  { win = win })
  vim.api.nvim_set_option_value("number",     false, { win = win })
  vim.api.nvim_set_option_value("signcolumn", "no",  { win = win })
  vim.api.nvim_set_option_value("cursorline", false, { win = win })
  vim.api.nvim_set_option_value("winhighlight",
    "Normal:Normal,NormalFloat:Normal,FloatBorder:DcodeBorder," ..
    "CursorLine:Normal,Search:None,IncSearch:None",
    { win = win })
end

-- ─── Sidebar open / close / toggle ───────────────────────────────────────────

---@param opts table  { width: number (fraction 0–1 or absolute columns) }
function M.open(opts)
  opts = opts or {}

  if result_win_valid() then
    -- Sidebar already open — focus the result window
    vim.api.nvim_set_current_win(result_win)
    return
  end

  ensure_buf()

  -- Compute sidebar width
  local width_frac = opts.width or 0.40
  local sidebar_w
  if width_frac > 1 then
    sidebar_w = math.floor(width_frac)
  else
    sidebar_w = math.floor(vim.o.columns * width_frac)
  end
  sidebar_w = math.max(sidebar_w, 30)

  -- Remember where focus was so we can restore it
  local orig_win = vim.api.nvim_get_current_win()

  -- Open vsplit, push it to the far right, assign the chat buffer
  vim.cmd("vsplit")
  result_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(result_win, chat_buf)
  vim.cmd("wincmd L")                          -- push to far right edge
  vim.api.nvim_win_set_width(result_win, sidebar_w)

  apply_win_opts(result_win)

  -- Scroll to bottom
  local count = vim.api.nvim_buf_line_count(chat_buf)
  vim.api.nvim_win_set_cursor(result_win, { count, 0 })

  -- Buffer-local keymaps for the result pane
  local ko = { buffer = chat_buf, noremap = true, silent = true }
  -- Close sidebar
  vim.keymap.set("n", "q",     function() M.close() end, ko)
  vim.keymap.set("n", "<Esc>", function() M.close() end, ko)
  -- Focus input pane (created lazily by commands.lua)
  vim.keymap.set("n", "i",  function()
    vim.schedule(function() require("dcode.commands").focus_or_open_input() end)
  end, ko)
  vim.keymap.set("n", "<CR>", function()
    vim.schedule(function() require("dcode.commands").focus_or_open_input() end)
  end, ko)

  -- Restore focus to the original window
  vim.api.nvim_set_current_win(orig_win)
end

--- Register the input window so close() can shut it down.
---@param win integer|nil
function M.set_input_win(win)
  input_win = win
end

function M.close()
  -- Close input pane first (if open)
  if input_win ~= nil and vim.api.nvim_win_is_valid(input_win) then
    pcall(vim.api.nvim_win_close, input_win, true)
  end
  input_win = nil

  -- Close result pane
  if result_win_valid() then
    pcall(vim.api.nvim_win_close, result_win, true)
  end
  result_win = nil
end

function M.toggle(opts)
  if result_win_valid() then
    M.close()
  else
    M.open(opts)
  end
end

function M.is_open()
  return result_win_valid()
end

function M.bufnr()
  return chat_buf
end

--- Return the result window id (nil if closed).
function M.result_winid()
  return result_win_valid() and result_win or nil
end

-- ─── Chat rendering ───────────────────────────────────────────────────────────

local SEP = string.rep("─", 52)

function M.render_user(text)
  local lines = { "", "▶ You", SEP }
  for _, l in ipairs(vim.split(text, "\n", { plain = true })) do
    table.insert(lines, l)
  end
  table.insert(lines, "")
  buf_append_lines(lines)
end

function M.begin_assistant()
  -- Flush any orphaned partial stream
  if stream.buf ~= "" and buf_valid() then
    with_modifiable(function()
      vim.api.nvim_buf_set_text(chat_buf,
        stream.last_line, stream.last_col,
        stream.last_line, stream.last_col,
        { stream.buf })
    end)
  end
  stream.buf    = ""
  stream.active = true

  buf_append_lines({ "◀ dcode", SEP, "" })

  if buf_valid() then
    local count      = vim.api.nvim_buf_line_count(chat_buf)
    stream.last_line = count - 1  -- 0-based
    stream.last_col  = 0
  end

  spinner_start()
end

local function flush_stream()
  if not stream.active or not buf_valid() then return end
  with_modifiable(function()
    local text  = stream.buf
    local parts = vim.split(text, "\n", { plain = true })
    if #parts == 1 then
      local cur = vim.api.nvim_buf_get_lines(chat_buf,
        stream.last_line, stream.last_line + 1, false)[1] or ""
      vim.api.nvim_buf_set_text(chat_buf,
        stream.last_line, 0,
        stream.last_line, #cur,
        { parts[1] })
    else
      local cur = vim.api.nvim_buf_get_lines(chat_buf,
        stream.last_line, stream.last_line + 1, false)[1] or ""
      vim.api.nvim_buf_set_text(chat_buf,
        stream.last_line, 0,
        stream.last_line, #cur,
        parts)
      stream.last_line = stream.last_line + #parts - 1
      stream.last_col  = #parts[#parts]
    end
  end)
  -- Auto-scroll result window if near bottom
  if result_win_valid() then
    local count   = vim.api.nvim_buf_line_count(chat_buf)
    local cur_row = vim.api.nvim_win_get_cursor(result_win)[1]
    if cur_row >= count - 5 then
      vim.api.nvim_win_set_cursor(result_win, { count, 0 })
    end
  end
  stream.pending = false
end

function M.append_stream_text(chunk)
  if not stream.active then return end
  stream.buf = stream.buf .. chunk
  if stream.pending then return end
  stream.pending = true
  if not stream.timer then
    stream.timer = vim.loop.new_timer()
  end
  stream.timer:start(50, 0, vim.schedule_wrap(function()
    flush_stream()
  end))
end

function M.render_tool(name, detail)
  flush_stream()
  local line = "  ⚙ " .. name
  if detail and detail ~= "" then
    line = line .. " — " .. detail:sub(1, 60)
  end
  buf_append_lines({ line })
  if buf_valid() then
    local count = vim.api.nvim_buf_line_count(chat_buf)
    buf_append_lines({ "" })
    stream.last_line = count
    stream.last_col  = 0
    stream.buf       = ""
  end
end

function M.render_thinking(text)
  flush_stream()
  buf_append_lines({ "  ≋ " .. text:sub(1, 100) })
  if buf_valid() then
    local count = vim.api.nvim_buf_line_count(chat_buf)
    buf_append_lines({ "" })
    stream.last_line = count
    stream.last_col  = 0
    stream.buf       = ""
  end
end

function M.end_assistant(cost, tokens)
  stream.active = false
  spinner_stop()

  if stream.timer then
    stream.timer:stop()
    stream.timer:close()
    stream.timer = nil
  end

  flush_stream()
  stream.buf = ""

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

function M.render_error(msg)
  stream.active = false
  spinner_stop()
  if stream.timer then stream.timer:stop(); stream.timer:close(); stream.timer = nil end
  stream.buf = ""
  buf_append_lines({ "", "  ✗ " .. msg, "" })
end

--- Update sidebar title (no-op for vsplit — vsplit has no title bar).
function M.set_title(_) end

function M.notify(msg, level)
  vim.notify("[dcode] " .. msg, level or vim.log.levels.INFO)
end

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
