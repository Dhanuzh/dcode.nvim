-- lua/dcode/commands.lua
-- User-facing commands: ask, explain, fix, review, tests, docs.
-- Input is an embedded horizontal split BELOW the result window
-- (avante-style sidebar: no floating input window).

local client  = require("dcode.client")
local ui      = require("dcode.ui")
local session = require("dcode.session")
local stream  = require("dcode.stream")

local M = {}

-- ─── Input pane ──────────────────────────────────────────────────────────────
-- The input pane is a 3-line horizontal split opened below the result window.
-- It is persistent while the sidebar is open; pressing <Esc> unfocuses it
-- (returns to result window) but does NOT close it.

local input_win = nil  ---@type integer|nil
local input_buf = nil  ---@type integer|nil
-- Callback invoked on submit (captures current command's context):
local input_cb  = nil  ---@type fun(text: string)|nil

local function input_win_valid()
  return input_win ~= nil and vim.api.nvim_win_is_valid(input_win)
end

local function input_buf_valid()
  return input_buf ~= nil and vim.api.nvim_buf_is_valid(input_buf)
end

--- Close both panes of the input window and clear state.
function M.close_input()
  if input_win_valid() then
    pcall(vim.api.nvim_win_close, input_win, true)
  end
  input_win = nil
  -- Keep the buffer alive in case we reopen — wipe it below explicitly.
  if input_buf_valid() then
    pcall(vim.api.nvim_buf_delete, input_buf, { force = true })
  end
  input_buf = nil
  input_cb  = nil
  ui.set_input_win(nil)
end

--- Create (or reuse) the input buffer.
local function ensure_input_buf()
  if input_buf_valid() then return end
  input_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("bufhidden",  "hide",        { buf = input_buf })
  vim.api.nvim_set_option_value("buftype",    "nofile",      { buf = input_buf })
  vim.api.nvim_set_option_value("filetype",   "dcode-input", { buf = input_buf })
  vim.api.nvim_set_option_value("modifiable", true,          { buf = input_buf })
end

--- Open the embedded input pane below the result window.
--- Idempotent: if already open, just focuses it and sets cb.
---@param on_submit fun(text: string)
---@param prefill   string|nil
local function open_input_pane(on_submit, prefill)
  local rwin = ui.result_winid()
  if not rwin then return end  -- sidebar not open

  input_cb = on_submit

  -- If pane already exists just focus it
  if input_win_valid() then
    -- Clear old content, set new prefill
    if input_buf_valid() then
      vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { prefill or "" })
    end
    vim.api.nvim_set_current_win(input_win)
    vim.cmd("startinsert!")
    return
  end

  ensure_input_buf()

  -- Prefill
  if prefill and prefill ~= "" then
    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { prefill })
  else
    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "" })
  end

  -- Open a horizontal split below the result window
  vim.api.nvim_set_current_win(rwin)
  vim.cmd("belowright 3split")
  input_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(input_win, input_buf)

  -- Window options
  vim.api.nvim_set_option_value("wrap",       true,  { win = input_win })
  vim.api.nvim_set_option_value("number",     false, { win = input_win })
  vim.api.nvim_set_option_value("signcolumn", "no",  { win = input_win })
  vim.api.nvim_set_option_value("cursorline", false, { win = input_win })
  -- statusline shows a simple prompt label
  vim.api.nvim_set_option_value("statusline", " dcode  ask  <CR> submit  <Esc> back ", { win = input_win })
  vim.api.nvim_set_option_value("winhighlight",
    "Normal:Normal,NormalFloat:Normal,StatusLine:DcodeBorder,StatusLineNC:DcodeBorder",
    { win = input_win })

  -- Let ui.lua know about the input win so close() shuts both down
  ui.set_input_win(input_win)

  -- ── Keymaps ────────────────────────────────────────────────────────────────
  local ko = { buffer = input_buf, noremap = true, silent = true }

  local function submit()
    if not input_buf_valid() then return end
    local lines = vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)
    local text  = vim.trim(table.concat(lines, "\n"))
    -- Clear the input buffer for next use
    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "" })
    -- Return focus to the result window
    local rw = ui.result_winid()
    if rw then vim.api.nvim_set_current_win(rw) end
    if text ~= "" and input_cb then
      local cb = input_cb
      input_cb = nil
      cb(text)
    end
  end

  local function back_to_result()
    local rw = ui.result_winid()
    if rw then
      vim.api.nvim_set_current_win(rw)
    end
  end

  -- Submit: <CR> (normal) or <C-s> (insert or normal)
  vim.keymap.set("n", "<CR>",  submit, ko)
  vim.keymap.set("n", "<C-s>", submit, ko)
  vim.keymap.set("i", "<C-s>", submit, ko)
  -- NOTE: We intentionally do NOT bind <CR> in insert mode because users
  -- commonly want multi-line prompts. <C-s> submits from insert mode.
  -- <Esc> in insert: leave insert, stay in input pane (normal mode)
  -- <Esc> in normal: go back to result window
  vim.keymap.set("n", "<Esc>", back_to_result, ko)
  -- q in the input pane closes the whole sidebar
  vim.keymap.set("n", "q", function() ui.close() end, ko)

  -- Start in insert mode
  vim.cmd("startinsert!")
end

-- ─── Public: focus or open input (bound to `i`/<CR> in result window) ────────

function M.focus_or_open_input()
  local cfg = require("dcode").config
  if not ui.is_open() then ui.open(cfg.window) end
  open_input_pane(function(text)
    dispatch(text, text)
  end, "")
end

-- Keep old name as alias so lazy spec key `<leader>da` still works:
function M.open_input()
  M.focus_or_open_input()
end

-- ─── Session readiness ────────────────────────────────────────────────────────

---@param cb fun(session_id: string)
local function ensure_ready(cb)
  client.ping(function(alive)
    if not alive then
      ui.notify("dcode server not running. Start it with: dcode serve", vim.log.levels.ERROR)
      return
    end
    if session.current_id then
      cb(session.current_id)
    else
      session.resume_or_create(nil, function(ok, id)
        if ok then cb(id) end
      end)
    end
  end)
end

-- ─── Context builder ─────────────────────────────────────────────────────────

---@param selection boolean
---@return string
local function get_context(selection)
  local lines
  local ft    = vim.bo.filetype or ""
  local fname = vim.fn.expand("%:.")

  if selection then
    local s = vim.fn.getpos("'<")
    local e = vim.fn.getpos("'>")
    lines = vim.api.nvim_buf_get_lines(0, s[2] - 1, e[2], false)
    if lines[#lines] then
      lines[#lines] = lines[#lines]:sub(1, e[3])
    end
  else
    lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  end

  if #lines == 0 then return "" end
  return string.format("```%s\n-- file: %s\n%s\n```", ft, fname, table.concat(lines, "\n"))
end

-- ─── Core dispatch ────────────────────────────────────────────────────────────

--- Send prompt to dcode; open sidebar first if needed.
---@param full_msg     string
---@param display_text string
function dispatch(full_msg, display_text)
  local cfg = require("dcode").config
  if not ui.is_open() then ui.open(cfg.window) end
  ensure_ready(function(sid)
    stream.run(sid, full_msg, display_text, function(err)
      if err then ui.notify("Error: " .. err, vim.log.levels.ERROR) end
    end)
  end)
end

-- ─── Public commands ─────────────────────────────────────────────────────────

---@param prompt string|nil
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
        table.insert(lines, string.format("  %-22s %s", prov, mid))
      end
    end
    table.sort(lines)
    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
  end)
end

-- ─── :Dcode* user commands ────────────────────────────────────────────────────

function M.register()
  local function cmd(name, fn, desc, range)
    vim.api.nvim_create_user_command(name, fn, {
      desc  = desc,
      range = range or false,
      nargs = "?",
    })
  end

  cmd("DcodeToggle",   function()          require("dcode").toggle() end,              "Toggle dcode chat window")
  cmd("DcodeAsk",      function(a) M.ask(a.args ~= "" and a.args or nil) end,          "Ask dcode (buffer context)")
  cmd("DcodeExplain",  function() M.explain() end,     "Explain selection",   true)
  cmd("DcodeFix",      function() M.fix() end,         "Fix selection",       true)
  cmd("DcodeReview",   function() M.review() end,      "Review code",         true)
  cmd("DcodeTests",    function() M.tests() end,       "Generate tests",      true)
  cmd("DcodeDocs",     function() M.docs() end,        "Add documentation",   true)
  cmd("DcodeContext",  function() M.context_ask() end, "Ask with full file context")
  cmd("DcodeNew",      function() M.new_session() end, "Start a new dcode session")
  cmd("DcodeModels",   function() M.show_models() end, "List available models")
  cmd("DcodeSessions", function() require("dcode.telescope").sessions() end, "Browse sessions")
end

return M
