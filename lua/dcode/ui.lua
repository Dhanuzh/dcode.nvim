-- lua/dcode/ui.lua
-- Sidebar UI: right-side vsplit (avante-style), persistent chat buffer,
-- embedded input pane always visible, agent/model statusline.

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
  h("DcodeAgentSel",  { fg = "#1a1b26", bg = "#7aa2f7", bold = true })
  h("DcodeAgentOff",  { fg = "#565f89" })
end

-- ─── Namespaces ──────────────────────────────────────────────────────────────

local ns_spin   = vim.api.nvim_create_namespace("dcode_spin")
local ns_agent  = vim.api.nvim_create_namespace("dcode_agent")

-- ─── State ───────────────────────────────────────────────────────────────────

local chat_buf   = nil  ---@type integer|nil
local result_win = nil  ---@type integer|nil
local input_win  = nil  ---@type integer|nil

local current_agent = "coder"
local current_model = ""
local current_title = ""

-- Streaming — simple accumulate-then-write model
local stream = {
  active  = false,
  buf     = "",   -- text accumulated since last flush
  row     = 0,    -- 0-based line where the next write begins
  pending = false,
}

local spin_id    = nil
local spin_idx   = 0
local spin_timer = nil
local SPIN = { "⠋","⠙","⠹","⠸","⠼","⠴","⠦","⠧","⠇","⠏" }

-- ─── Validity ────────────────────────────────────────────────────────────────

local function buf_ok()  return chat_buf   ~= nil and vim.api.nvim_buf_is_valid(chat_buf) end
local function rwin_ok() return result_win ~= nil and vim.api.nvim_win_is_valid(result_win) end

-- ─── Write helpers ───────────────────────────────────────────────────────────

local function with_mod(fn)
  if not buf_ok() then return end
  vim.api.nvim_set_option_value("modifiable", true,  { buf = chat_buf })
  local ok, err = pcall(fn)
  vim.api.nvim_set_option_value("modifiable", false, { buf = chat_buf })
  if not ok then vim.notify("[dcode] " .. tostring(err), vim.log.levels.ERROR) end
end

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

-- ─── Agent bar (extmarks on line 0) ──────────────────────────────────────────

local AGENTS = { "coder", "planner", "explorer" }

--- Redraw the agent selector bar on line 0 of the chat buffer using extmarks.
local function redraw_agent_bar()
  if not buf_ok() then return end
  vim.api.nvim_buf_clear_namespace(chat_buf, ns_agent, 0, 1)

  -- Build virt_text chunks: each agent with a space separator
  local chunks = {}
  for i, a in ipairs(AGENTS) do
    local hl = (a == current_agent) and "DcodeAgentSel" or "DcodeAgentOff"
    table.insert(chunks, { " " .. a .. " ", hl })
    if i < #AGENTS then
      table.insert(chunks, { "  ", "DcodeAgentOff" })
    end
  end
  -- Show on line 0 as a virtual line ABOVE the content
  vim.api.nvim_buf_set_extmark(chat_buf, ns_agent, 0, 0, {
    virt_lines       = { chunks },
    virt_lines_above = true,
  })
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
  with_mod(function()
    vim.api.nvim_buf_set_lines(chat_buf, 0, -1, false, { "" })
  end)
  redraw_agent_bar()
end

-- ─── Win options ─────────────────────────────────────────────────────────────

local function win_opts(win)
  local s = function(k, v) vim.api.nvim_set_option_value(k, v, { win = win }) end
  s("wrap",           true)
  s("linebreak",      true)
  s("number",         false)
  s("relativenumber", false)
  s("signcolumn",     "no")
  s("cursorline",     false)
  s("foldcolumn",     "0")
  s("winhighlight",
    "Normal:Normal,NormalFloat:Normal,FloatBorder:DcodeBorder," ..
    "CursorLine:Normal,Search:None,IncSearch:None," ..
    "StatusLine:DcodeBorder,StatusLineNC:DcodeBorder")
end

-- ─── Statuslines ─────────────────────────────────────────────────────────────

local function result_sl()
  local mdl = current_model ~= "" and (" · " .. current_model) or ""
  local ttl = current_title ~= "" and (" — " .. current_title:sub(1, 28)) or ""
  return "  dcode · " .. current_agent .. mdl .. ttl .. " "
end

local function input_sl()
  return "  ask  <C-s> send  ·  <Esc> back  ·  <Tab> cycle agent "
end

function M.update_statuslines()
  if rwin_ok() then
    vim.api.nvim_set_option_value("statusline", result_sl(), { win = result_win })
  end
  if input_win ~= nil and vim.api.nvim_win_is_valid(input_win) then
    vim.api.nvim_set_option_value("statusline", input_sl(), { win = input_win })
  end
end

-- ─── Public: update session / agent metadata ─────────────────────────────────

function M.set_session_info(agent, model, title)
  if agent and agent ~= "" then current_agent = agent end
  if model and model ~= "" then current_model = model end
  if title and title ~= "" then current_title = title end
  redraw_agent_bar()
  M.update_statuslines()
end

function M.set_agent(agent)
  current_agent = agent
  redraw_agent_bar()
  M.update_statuslines()
end

function M.set_title(title)
  current_title = title or ""
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
  local sw = w > 1 and math.floor(w) or math.floor(vim.o.columns * w)
  sw = math.max(sw, 32)

  local orig = vim.api.nvim_get_current_win()

  vim.cmd("vsplit")
  result_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(result_win, chat_buf)
  vim.cmd("wincmd L")
  vim.api.nvim_win_set_width(result_win, sw)

  win_opts(result_win)
  vim.api.nvim_set_option_value("statusline", result_sl(), { win = result_win })

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
  vim.keymap.set("n", "<Tab>", function()
    vim.schedule(function() require("dcode.commands").cycle_agent() end)
  end, ko)

  vim.api.nvim_set_current_win(orig)
end

function M.set_input_win(win)
  input_win = win
  if win ~= nil and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_option_value("statusline", input_sl(), { win = win })
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

function M.is_open()      return rwin_ok() end
function M.bufnr()        return chat_buf end
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
  stream.buf    = ""
  stream.active = true

  append({ "◀ dcode", SEP, "" })

  if buf_ok() then
    -- stream.row is 0-based. The empty "" line we just appended is the last line.
    stream.row = vim.api.nvim_buf_line_count(chat_buf) - 1
  end

  spin_start()
end

-- ─── Flush: write stream.buf to buffer from stream.row; reset buf ────────────
-- Called from the 50ms throttle timer AND directly from end_assistant/render_tool.
-- IMPORTANT: does NOT check stream.active — callers manage that.

local function do_flush()
  if not buf_ok() then return end
  if stream.buf == "" then stream.pending = false; return end

  with_mod(function()
    local text  = stream.buf
    stream.buf  = ""   -- reset BEFORE the write (re-entrancy safe)

    local parts = vim.split(text, "\n", { plain = true })

    -- Ensure enough lines exist in the buffer
    local n = vim.api.nvim_buf_line_count(chat_buf)
    local needed = stream.row + #parts  -- we need indices stream.row .. stream.row+#parts-1
    while n < needed do
      vim.api.nvim_buf_set_lines(chat_buf, n, n, false, { "" })
      n = n + 1
    end

    -- Write each part to its line
    for i, part in ipairs(parts) do
      local lnum = stream.row + i - 1  -- 0-based
      vim.api.nvim_buf_set_lines(chat_buf, lnum, lnum + 1, false, { part })
    end

    -- Advance stream.row to the line of the last part written.
    -- If text ended with \n, parts[#parts]=="" and the next write should go
    -- on that last (empty) line. Either way, row = row + #parts - 1.
    stream.row = stream.row + #parts - 1
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
  -- Always create a fresh one-shot timer (never reuse a closed handle)
  local t = vim.loop.new_timer()
  t:start(50, 0, vim.schedule_wrap(function()
    t:close()
    do_flush()
  end))
end

function M.render_tool(name, detail)
  do_flush()  -- flush any partial text first
  local line = "  ⚙ " .. name
  if detail and detail ~= "" then line = line .. " — " .. detail:sub(1, 60) end
  append({ line, "" })
  if buf_ok() then
    stream.row = vim.api.nvim_buf_line_count(chat_buf) - 1
    stream.buf = ""
  end
end

function M.render_thinking(text)
  do_flush()
  append({ "  ≋ " .. text:sub(1, 100), "" })
  if buf_ok() then
    stream.row = vim.api.nvim_buf_line_count(chat_buf) - 1
    stream.buf = ""
  end
end

function M.end_assistant(cost, tokens)
  -- Stop spinner first
  spin_stop()

  -- Final flush — do NOT guard on stream.active here
  do_flush()
  stream.active = false
  stream.buf    = ""

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
  spin_stop()
  do_flush()
  stream.active = false
  stream.buf    = ""
  append({ "", "  ✗ " .. msg, "" })
  scroll_bottom()
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
    redraw_agent_bar()
  end
  M.update_statuslines()
end

return M
