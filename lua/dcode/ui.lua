-- lua/dcode/ui.lua
-- Sidebar UI: right-side vsplit (avante-style), persistent chat buffer,
-- embedded input pane, agent/model header bar, streaming with correct flush.

local M = {}

-- ─── Highlights ──────────────────────────────────────────────────────────────

function M.setup_highlights()
  local h = function(g, o) vim.api.nvim_set_hl(0, g, o) end
  h("DcodeBorder",    { fg = "#7aa2f7", bold = true })
  h("DcodeTitle",     { fg = "#bb9af7", bold = true })
  h("DcodeUser",      { fg = "#9ece6a", bold = true })
  h("DcodeAssistant", { fg = "#7dcfff", bold = true })
  h("DcodeTool",      { fg = "#e0af68", italic = true })
  h("DcodeThinking",  { fg = "#565f89", italic = true })
  h("DcodeCost",      { fg = "#565f89" })
  h("DcodeSeparator", { fg = "#3b4261" })
  h("DcodeStatusOk",  { fg = "#9ece6a" })
  h("DcodeStatusErr", { fg = "#f7768e" })
  h("DcodeAgent",     { fg = "#ff9e64", bold = true })
  h("DcodeAgentSel",  { fg = "#1a1b26", bg = "#7aa2f7", bold = true })
  h("DcodeHeader",    { fg = "#a9b1d6", bg = "NONE" })
end

-- ─── State ───────────────────────────────────────────────────────────────────

local ns_spin   = vim.api.nvim_create_namespace("dcode_spinner")
local ns_hl     = vim.api.nvim_create_namespace("dcode_hl")

local chat_buf   = nil  ---@type integer|nil   persistent chat content
local result_win = nil  ---@type integer|nil   top pane (read-only)
local input_win  = nil  ---@type integer|nil   bottom pane (editable) — set by commands.lua

-- Session info shown in statuslines
local current_agent = "coder"
local current_model = ""
local current_title = ""

-- Streaming state — intentionally simple: accumulate then flush-and-reset
local stream = {
  active   = false,
  buf      = "",     -- text accumulated since last flush
  row      = 0,      -- 0-based line where next text should go
  timer    = nil,
  pending  = false,
}

local spin_id    = nil
local spin_idx   = 0
local spin_timer = nil
local SPIN = { "⠋","⠙","⠹","⠸","⠼","⠴","⠦","⠧","⠇","⠏" }

-- ─── Validity ────────────────────────────────────────────────────────────────

local function buf_ok()   return chat_buf   ~= nil and vim.api.nvim_buf_is_valid(chat_buf) end
local function rwin_ok()  return result_win ~= nil and vim.api.nvim_win_is_valid(result_win) end

-- ─── Buffer write helpers ────────────────────────────────────────────────────

local function with_mod(fn)
  if not buf_ok() then return end
  vim.api.nvim_set_option_value("modifiable", true,  { buf = chat_buf })
  local ok, err = pcall(fn)
  vim.api.nvim_set_option_value("modifiable", false, { buf = chat_buf })
  if not ok then vim.notify("[dcode] " .. tostring(err), vim.log.levels.ERROR) end
end

--- Append lines; auto-scroll if cursor is near bottom.
local function append(lines)
  if not buf_ok() then return end
  with_mod(function()
    local n = vim.api.nvim_buf_line_count(chat_buf)
    vim.api.nvim_buf_set_lines(chat_buf, n, n, false, lines)
  end)
  if rwin_ok() then
    local n   = vim.api.nvim_buf_line_count(chat_buf)
    local cur = vim.api.nvim_win_get_cursor(result_win)[1]
    if cur >= n - 4 then
      vim.api.nvim_win_set_cursor(result_win, { n, 0 })
    end
  end
end

--- Scroll result window to last line unconditionally.
local function scroll_bottom()
  if rwin_ok() and buf_ok() then
    local n = vim.api.nvim_buf_line_count(chat_buf)
    vim.api.nvim_win_set_cursor(result_win, { n, 0 })
  end
end

-- ─── Spinner ─────────────────────────────────────────────────────────────────

local function spin_stop()
  if spin_timer then spin_timer:stop(); spin_timer:close(); spin_timer = nil end
  if buf_ok() and spin_id then
    pcall(vim.api.nvim_buf_del_extmark, chat_buf, ns_spin, spin_id)
    spin_id = nil
  end
end

local function spin_start()
  spin_stop()
  if not buf_ok() then return end
  spin_idx   = 0
  spin_timer = vim.loop.new_timer()
  spin_timer:start(0, 80, vim.schedule_wrap(function()
    if not buf_ok() then spin_stop(); return end
    spin_idx = (spin_idx % #SPIN) + 1
    local last = math.max(0, vim.api.nvim_buf_line_count(chat_buf) - 1)
    spin_id = vim.api.nvim_buf_set_extmark(chat_buf, ns_spin, last, 0, {
      id            = spin_id or nil,
      virt_text     = { { " " .. SPIN[spin_idx] .. " thinking…", "DcodeThinking" } },
      virt_text_pos = "eol",
    })
  end))
end

-- ─── Buffer creation ─────────────────────────────────────────────────────────

local function ensure_buf()
  if buf_ok() then return end
  chat_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("filetype",   "dcode-chat", { buf = chat_buf })
  vim.api.nvim_set_option_value("bufhidden",  "hide",       { buf = chat_buf })
  vim.api.nvim_set_option_value("modifiable", false,        { buf = chat_buf })
  vim.api.nvim_set_option_value("buftype",    "nofile",     { buf = chat_buf })
  pcall(vim.treesitter.language.register, "markdown", "dcode-chat")
  -- Initial welcome content is empty — header is shown via statusline
  with_mod(function()
    vim.api.nvim_buf_set_lines(chat_buf, 0, -1, false, { "" })
  end)
end

-- ─── Window option helper ────────────────────────────────────────────────────

local function win_opts(win)
  local set = function(k, v) vim.api.nvim_set_option_value(k, v, { win = win }) end
  set("wrap",        true)
  set("linebreak",   true)
  set("number",      false)
  set("relativenumber", false)
  set("signcolumn",  "no")
  set("cursorline",  false)
  set("foldcolumn",  "0")
  set("winhighlight",
    "Normal:Normal,NormalFloat:Normal,FloatBorder:DcodeBorder," ..
    "CursorLine:Normal,Search:None,IncSearch:None,StatusLine:DcodeBorder,StatusLineNC:DcodeBorder")
end

-- ─── Statusline builder ──────────────────────────────────────────────────────

--- Build the result-window statusline string showing agent + model.
local function result_statusline()
  local agent = current_agent ~= "" and current_agent or "coder"
  local model = current_model ~= "" and (" · " .. current_model) or ""
  local title = current_title ~= "" and (" — " .. current_title:sub(1, 30)) or ""
  return "  dcode · " .. agent .. model .. title .. " "
end

--- Build the input-window statusline.
local function input_statusline()
  return "  ask  <C-s> send · <Esc> back · q close "
end

function M.update_statuslines()
  if rwin_ok() then
    vim.api.nvim_set_option_value("statusline", result_statusline(), { win = result_win })
  end
  if input_win ~= nil and vim.api.nvim_win_is_valid(input_win) then
    vim.api.nvim_set_option_value("statusline", input_statusline(), { win = input_win })
  end
end

-- ─── Public: update session metadata ─────────────────────────────────────────

function M.set_session_info(agent, model, title)
  current_agent = agent or current_agent
  current_model = model or current_model
  current_title = title or current_title
  M.update_statuslines()
end

-- ─── Sidebar open / close / toggle ───────────────────────────────────────────

---@param opts table  { width?: number }
function M.open(opts)
  opts = opts or {}

  if rwin_ok() then
    vim.api.nvim_set_current_win(result_win)
    return
  end

  ensure_buf()

  local w = opts.width or 0.40
  local sidebar_w = w > 1 and math.floor(w) or math.floor(vim.o.columns * w)
  sidebar_w = math.max(sidebar_w, 32)

  local orig = vim.api.nvim_get_current_win()

  -- Open right-anchored vsplit
  vim.cmd("vsplit")
  result_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(result_win, chat_buf)
  vim.cmd("wincmd L")
  vim.api.nvim_win_set_width(result_win, sidebar_w)

  win_opts(result_win)
  vim.api.nvim_set_option_value("statusline", result_statusline(), { win = result_win })

  scroll_bottom()

  -- Keymaps in result pane
  local ko = { buffer = chat_buf, noremap = true, silent = true }
  vim.keymap.set("n", "q",     function() M.close() end, ko)
  vim.keymap.set("n", "<Esc>", function() M.close() end, ko)
  vim.keymap.set("n", "i",     function()
    vim.schedule(function() require("dcode.commands").focus_or_open_input() end)
  end, ko)
  vim.keymap.set("n", "<CR>", function()
    vim.schedule(function() require("dcode.commands").focus_or_open_input() end)
  end, ko)
  -- Tab cycles agent
  vim.keymap.set("n", "<Tab>", function()
    vim.schedule(function() require("dcode.commands").cycle_agent() end)
  end, ko)

  -- Restore original window focus; commands.lua will open the input pane and focus it
  vim.api.nvim_set_current_win(orig)
end

function M.set_input_win(win)
  input_win = win
  if win ~= nil and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_option_value("statusline", input_statusline(), { win = win })
  end
end

function M.close()
  if input_win ~= nil and vim.api.nvim_win_is_valid(input_win) then
    pcall(vim.api.nvim_win_close, input_win, true)
  end
  input_win = nil
  if rwin_ok() then
    pcall(vim.api.nvim_win_close, result_win, true)
  end
  result_win = nil
end

function M.toggle(opts)
  if rwin_ok() then M.close() else M.open(opts) end
end

function M.is_open()   return rwin_ok() end
function M.bufnr()     return chat_buf end
function M.result_winid() return rwin_ok() and result_win or nil end

-- ─── Chat rendering ───────────────────────────────────────────────────────────

local SEP = string.rep("─", 50)

function M.render_user(text)
  local lines = { "", "▶ You", SEP }
  for _, l in ipairs(vim.split(text, "\n", { plain = true })) do
    table.insert(lines, l)
  end
  table.insert(lines, "")
  append(lines)
end

function M.begin_assistant()
  -- If there was a previous partial stream that never got flushed, drop it
  stream.buf    = ""
  stream.active = true

  -- Append assistant header + one empty line for streaming to land on
  append({ "◀ dcode", SEP, "" })

  if buf_ok() then
    local n      = vim.api.nvim_buf_line_count(chat_buf)
    stream.row   = n - 1   -- 0-based index of the empty line we just appended
  end

  spin_start()
end

--- Flush all accumulated text in stream.buf onto the buffer starting at stream.row.
--- Resets stream.buf to "" and advances stream.row past any complete lines.
local function flush_stream()
  if not stream.active or not buf_ok() then return end
  if stream.buf == "" then stream.pending = false; return end

  with_mod(function()
    local text  = stream.buf
    local parts = vim.split(text, "\n", { plain = true })

    -- Replace from stream.row to stream.row+(#parts-1)
    -- First, ensure enough lines exist
    local n = vim.api.nvim_buf_line_count(chat_buf)
    while n <= stream.row + #parts - 1 do
      vim.api.nvim_buf_set_lines(chat_buf, n, n, false, { "" })
      n = n + 1
    end

    -- Set each part into its line
    for i, part in ipairs(parts) do
      local lnum = stream.row + i - 1  -- 0-based
      vim.api.nvim_buf_set_lines(chat_buf, lnum, lnum + 1, false, { part })
    end

    -- Advance stream.row to the last line written
    -- Only advance if there was a trailing newline (last part is "")
    if parts[#parts] == "" then
      -- The last chunk ended with \n — next text goes on the blank line
      stream.row = stream.row + #parts - 1
      -- Remove the accumulated prefix: keep only up to the last complete line
      stream.buf = ""
    else
      -- Mid-line: keep the last partial segment in buf for display,
      -- but reset so next flush replaces from stream.row (last written line)
      -- stream.row stays at the line where the incomplete text is
      stream.row = stream.row + #parts - 1
      stream.buf = ""
    end
  end)

  -- Auto-scroll
  if rwin_ok() then
    local n   = vim.api.nvim_buf_line_count(chat_buf)
    local cur = vim.api.nvim_win_get_cursor(result_win)[1]
    if cur >= n - 5 then
      vim.api.nvim_win_set_cursor(result_win, { n, 0 })
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
  -- Re-start the one-shot 50ms timer
  stream.timer:start(50, 0, vim.schedule_wrap(function()
    flush_stream()
  end))
end

function M.render_tool(name, detail)
  -- Final flush of any partial stream text first
  if stream.buf ~= "" then flush_stream() end
  local line = "  ⚙ " .. name
  if detail and detail ~= "" then line = line .. " — " .. detail:sub(1, 60) end
  append({ line, "" })
  if buf_ok() then
    stream.row = vim.api.nvim_buf_line_count(chat_buf) - 1
    stream.buf = ""
  end
end

function M.render_thinking(text)
  if stream.buf ~= "" then flush_stream() end
  append({ "  ≋ " .. text:sub(1, 100), "" })
  if buf_ok() then
    stream.row = vim.api.nvim_buf_line_count(chat_buf) - 1
    stream.buf = ""
  end
end

function M.end_assistant(cost, tokens)
  stream.active = false
  spin_stop()

  if stream.timer then
    stream.timer:stop()
    stream.timer:close()
    stream.timer = nil
  end

  -- Final flush
  if stream.buf ~= "" then flush_stream() end
  stream.buf = ""

  local footer = {}
  if tokens and ((tokens.input or 0) > 0 or (tokens.output or 0) > 0) then
    local s = string.format("  in:%d out:%d", tokens.input or 0, tokens.output or 0)
    if cost and cost > 0 then s = s .. string.format("  $%.5f", cost) end
    table.insert(footer, s)
  end
  table.insert(footer, "")
  append(footer)
  scroll_bottom()
end

function M.render_error(msg)
  stream.active = false
  spin_stop()
  if stream.timer then stream.timer:stop(); stream.timer:close(); stream.timer = nil end
  stream.buf = ""
  append({ "", "  ✗ " .. msg, "" })
  scroll_bottom()
end

function M.set_title(title)
  current_title = title or ""
  M.update_statuslines()
end

function M.notify(msg, level)
  vim.notify("[dcode] " .. msg, level or vim.log.levels.INFO)
end

function M.reset()
  stream.active = false
  stream.buf    = ""
  spin_stop()
  if buf_ok() then
    with_mod(function()
      vim.api.nvim_buf_set_lines(chat_buf, 0, -1, false, { "" })
    end)
    stream.row = 0
  end
  M.update_statuslines()
end

return M
