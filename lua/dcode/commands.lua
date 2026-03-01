-- lua/dcode/commands.lua
-- User-facing commands. Input is a persistent embedded pane below the result
-- window (avante-style sidebar). Opens automatically when the sidebar opens.

local client  = require("dcode.client")
local ui      = require("dcode.ui")
local session = require("dcode.session")
local stream  = require("dcode.stream")

local M = {}

-- ─── Agent state ─────────────────────────────────────────────────────────────

-- Primary agents exposed in the sidebar (subagents are internal)
local AGENTS = { "coder", "planner", "explorer" }
local current_agent = "coder"

function M.get_agent() return current_agent end

--- Cycle to next agent and update statusline.
function M.cycle_agent()
  local idx = 1
  for i, a in ipairs(AGENTS) do
    if a == current_agent then idx = i; break end
  end
  idx = (idx % #AGENTS) + 1
  current_agent = AGENTS[idx]
  ui.set_agent(current_agent)
  ui.notify("Agent → " .. current_agent, vim.log.levels.INFO)
end

--- Set agent explicitly.
---@param agent string
function M.set_agent(agent)
  current_agent = agent
  ui.set_agent(current_agent)
end

-- ─── Input pane ──────────────────────────────────────────────────────────────

local input_win = nil  ---@type integer|nil
local input_buf = nil  ---@type integer|nil
local input_cb  = nil  ---@type fun(text: string)|nil

local function iwin_ok() return input_win ~= nil and vim.api.nvim_win_is_valid(input_win) end
local function ibuf_ok() return input_buf ~= nil and vim.api.nvim_buf_is_valid(input_buf) end

function M.close_input()
  if iwin_ok() then pcall(vim.api.nvim_win_close, input_win, true) end
  input_win = nil
  if ibuf_ok() then pcall(vim.api.nvim_buf_delete, input_buf, { force = true }) end
  input_buf = nil
  input_cb  = nil
  ui.set_input_win(nil)
end

local function ensure_input_buf()
  if ibuf_ok() then return end
  input_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("bufhidden",  "hide",        { buf = input_buf })
  vim.api.nvim_set_option_value("buftype",    "nofile",      { buf = input_buf })
  vim.api.nvim_set_option_value("filetype",   "dcode-input", { buf = input_buf })
  vim.api.nvim_set_option_value("modifiable", true,          { buf = input_buf })
end

--- Open (or reuse) the input pane. Called by M.open() and M.focus_or_open_input().
--- After opening, focus is placed in the input pane (insert mode).
---@param on_submit fun(text: string)|nil   if nil, uses current input_cb
---@param prefill   string|nil
local function open_input_pane(on_submit, prefill)
  local rwin = ui.result_winid()
  if not rwin then return end

  if on_submit then input_cb = on_submit end

  if iwin_ok() then
    -- Already open: just focus and set prefill
    if ibuf_ok() and prefill then
      vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { prefill })
    end
    vim.api.nvim_set_current_win(input_win)
    vim.cmd("startinsert!")
    return
  end

  ensure_input_buf()

  vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { prefill or "" })

  -- Open 3-line horizontal split below result window
  vim.api.nvim_set_current_win(rwin)
  vim.cmd("belowright 3split")
  input_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(input_win, input_buf)

  -- Window appearance
  local set = function(k, v) vim.api.nvim_set_option_value(k, v, { win = input_win }) end
  set("wrap",           true)
  set("number",         false)
  set("relativenumber", false)
  set("signcolumn",     "no")
  set("cursorline",     false)
  set("foldcolumn",     "0")
  set("winhighlight",
    "Normal:Normal,NormalFloat:Normal," ..
    "StatusLine:DcodeBorder,StatusLineNC:DcodeBorder")

  ui.set_input_win(input_win)

  -- ── Keymaps ────────────────────────────────────────────────────────────────
  local ko = { buffer = input_buf, noremap = true, silent = true }

  local function submit()
    if not ibuf_ok() then return end
    local lines = vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)
    local text  = vim.trim(table.concat(lines, "\n"))
    -- Clear input for next use
    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "" })
    -- Return focus to result window
    local rw = ui.result_winid()
    if rw then vim.api.nvim_set_current_win(rw) end
    -- Stop insert mode before dispatch
    vim.cmd("stopinsert")
    if text ~= "" and input_cb then
      local cb = input_cb
      -- Reset cb so a new one can be set next time
      input_cb = function(t) dispatch(t, t) end
      cb(text)
    end
  end

  local function back_to_result()
    local rw = ui.result_winid()
    if rw then
      vim.cmd("stopinsert")
      vim.api.nvim_set_current_win(rw)
    end
  end

  -- <C-s> submits from insert or normal mode
  vim.keymap.set("i", "<C-s>", submit, ko)
  vim.keymap.set("n", "<C-s>", submit, ko)
  -- <CR> in normal submits; in insert adds newline (multi-line support)
  vim.keymap.set("n", "<CR>",  submit, ko)
  -- <Esc> in insert: go to normal; <Esc> in normal: back to result
  vim.keymap.set("n", "<Esc>", back_to_result, ko)
  -- q closes whole sidebar
  vim.keymap.set("n", "q", function() ui.close() end, ko)
  -- Tab cycles agent from input pane too
  vim.keymap.set("n", "<Tab>", function() M.cycle_agent() end, ko)

  vim.cmd("startinsert!")
end

-- ─── Public input API ────────────────────────────────────────────────────────

--- Focus input pane if open, else open it. Used by `i`/<CR> in result window.
function M.focus_or_open_input()
  local cfg = require("dcode").config
  if not ui.is_open() then ui.open(cfg.window) end
  -- Set/refresh the submit callback
  input_cb = function(text) dispatch(text, text) end
  open_input_pane(nil, nil)
end

--- Alias kept for lazy.nvim key binding `<leader>da`
function M.open_input()
  M.focus_or_open_input()
end

-- ─── Session readiness ────────────────────────────────────────────────────────

---@param cb fun(session_id: string)
local function ensure_ready(cb)
  client.ping(function(alive)
    if not alive then
      ui.notify("dcode server not running — start with: dcode serve", vim.log.levels.ERROR)
      return
    end
    if session.current_id then
      cb(session.current_id)
    else
      session.resume_or_create({ agent = current_agent }, function(ok, id)
        if ok then cb(id) end
      end)
    end
  end)
end

-- ─── Context builder ─────────────────────────────────────────────────────────

local function get_context(selection)
  local lines
  local ft    = vim.bo.filetype or ""
  local fname = vim.fn.expand("%:.")

  if selection then
    local s = vim.fn.getpos("'<")
    local e = vim.fn.getpos("'>")
    lines = vim.api.nvim_buf_get_lines(0, s[2] - 1, e[2], false)
    if lines[#lines] then lines[#lines] = lines[#lines]:sub(1, e[3]) end
  else
    lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  end

  if #lines == 0 then return "" end
  return string.format("```%s\n-- file: %s\n%s\n```", ft, fname, table.concat(lines, "\n"))
end

-- ─── Core dispatch ────────────────────────────────────────────────────────────

function dispatch(full_msg, display_text)
  local cfg = require("dcode").config
  if not ui.is_open() then
    ui.open(cfg.window)
    -- open_input_pane will be called by open() → see M.open() below
  end
  ensure_ready(function(sid)
    stream.run(sid, full_msg, display_text, function(err)
      if err then ui.notify("Error: " .. err, vim.log.levels.ERROR) end
    end)
  end)
end

-- ─── Public commands ─────────────────────────────────────────────────────────

function M.ask(prompt)
  if prompt then
    local ctx  = get_context(false)
    local full = ctx ~= "" and (ctx .. "\n\n" .. prompt) or prompt
    dispatch(full, prompt)
  else
    M.open_input()
  end
end

function M.context_ask()
  local cfg = require("dcode").config
  if not ui.is_open() then ui.open(cfg.window) end
  open_input_pane(function(text)
    local ctx  = get_context(false)
    local full = ctx ~= "" and (ctx .. "\n\n" .. text) or text
    dispatch(full, "[file] " .. text)
  end, "")
end

function M.explain()
  local ctx = get_context(true)
  if ctx == "" then ui.notify("Select some code first", vim.log.levels.WARN); return end
  dispatch(ctx .. "\n\nExplain this code clearly and concisely.", "Explain selection")
end

function M.fix()
  local ctx = get_context(true)
  if ctx == "" then ui.notify("Select some code first", vim.log.levels.WARN); return end
  dispatch(ctx .. "\n\nFix any bugs or issues. Return only the corrected code.", "Fix selection")
end

function M.review()
  local ctx = get_context(true)
  if ctx == "" then ctx = get_context(false) end
  dispatch(ctx .. "\n\nReview for correctness, performance, and style. Be specific.", "Review code")
end

function M.tests()
  local ctx = get_context(true)
  if ctx == "" then ctx = get_context(false) end
  local ft = vim.bo.filetype or ""
  dispatch(ctx .. "\n\nWrite comprehensive unit tests in " .. ft .. ".", "Generate tests (" .. ft .. ")")
end

function M.docs()
  local ctx = get_context(true)
  if ctx == "" then ctx = get_context(false) end
  dispatch(ctx .. "\n\nAdd clear inline documentation/comments.", "Add docs")
end

function M.new_session()
  session.current_id = nil
  ui.reset()
  local cfg = require("dcode").config
  if not ui.is_open() then ui.open(cfg.window) end
  ensure_ready(function(_)
    ui.notify("New session ready", vim.log.levels.INFO)
  end)
end

function M.show_models()
  client.get("/model", function(ok, data)
    if not ok then
      ui.notify("Could not fetch models (is dcode serve running?)", vim.log.levels.WARN)
      return
    end
    local lines = { "Available models:", "" }
    if type(data) == "table" then
      for prov, info in pairs(data) do
        local mid = type(info) == "table" and (info.id or info.ID or "?") or tostring(info)
        table.insert(lines, string.format("  %-24s %s", prov, mid))
      end
    end
    table.sort(lines)
    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
  end)
end

-- ─── :Dcode* user commands ────────────────────────────────────────────────────

function M.register()
  local function cmd(name, fn, desc, range)
    vim.api.nvim_create_user_command(name, fn, { desc = desc, range = range or false, nargs = "?" })
  end
  cmd("DcodeToggle",   function()   require("dcode").toggle() end,                     "Toggle dcode sidebar")
  cmd("DcodeAsk",      function(a)  M.ask(a.args ~= "" and a.args or nil) end,         "Ask dcode")
  cmd("DcodeExplain",  function()   M.explain() end,    "Explain selection", true)
  cmd("DcodeFix",      function()   M.fix() end,        "Fix selection",     true)
  cmd("DcodeReview",   function()   M.review() end,     "Review code",       true)
  cmd("DcodeTests",    function()   M.tests() end,      "Generate tests",    true)
  cmd("DcodeDocs",     function()   M.docs() end,       "Add documentation", true)
  cmd("DcodeContext",  function()   M.context_ask() end,"Ask with full file context")
  cmd("DcodeNew",      function()   M.new_session() end,"Start a new session")
  cmd("DcodeModels",   function()   M.show_models() end,"List available models")
  cmd("DcodeSessions", function()   require("dcode.telescope").sessions() end, "Browse sessions")
end

-- ─── Open hook (called from ui.open after windows are created) ────────────────

--- Called by init.lua's M.open() after ui.open() to auto-open the input pane.
function M.after_open()
  input_cb = function(text) dispatch(text, text) end
  open_input_pane(nil, nil)
end

return M
