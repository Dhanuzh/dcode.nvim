-- lua/dcode/commands.lua
-- User-facing commands: ask, explain, fix, review, tests, docs.
-- Input is handled via a small floating window above the chat window
-- (no vim.ui.input — modelled after CopilotChat / avante prompt_input).

local client  = require("dcode.client")
local ui      = require("dcode.ui")
local session = require("dcode.session")
local stream  = require("dcode.stream")

local M = {}

-- ─── Input window ────────────────────────────────────────────────────────────

local input_win = nil  ---@type integer|nil
local input_buf = nil  ---@type integer|nil
local input_cb  = nil  ---@type fun(text: string)|nil  called on submit

local function input_win_valid()
  return input_win ~= nil and vim.api.nvim_win_is_valid(input_win)
end

--- Close the floating input window without submitting.
function M.close_input()
  if input_win_valid() then
    vim.api.nvim_win_close(input_win, true)
  end
  input_win = nil
  input_buf = nil
  input_cb  = nil
end

--- Open a small floating input window.
--- Pressing <CR> or <C-s> submits; <Esc> or <C-c> cancels.
---@param prompt string   Label shown as the window title
---@param prefill string  Pre-fill text
---@param on_submit fun(text: string)
local function open_input_win(prompt, prefill, on_submit)
  if input_win_valid() then M.close_input() end

  local chat_buf = ui.bufnr()

  -- Determine position: below last line of chat win, or editor-relative
  local row, col, width
  local chat_win_id = nil
  -- Find the chat window
  for _, wid in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(wid) == chat_buf then
      chat_win_id = wid
      break
    end
  end

  if chat_win_id and vim.api.nvim_win_is_valid(chat_win_id) then
    local winfo = vim.api.nvim_win_get_config(chat_win_id)
    local pos   = vim.api.nvim_win_get_position(chat_win_id)
    width = vim.api.nvim_win_get_width(chat_win_id)
    local h   = vim.api.nvim_win_get_height(chat_win_id)
    row = pos[1] + h - 3   -- 3 lines from bottom of chat win
    col = pos[2]
    if winfo.relative and winfo.relative ~= "" then
      -- floating chat window: use same relative
      row = winfo.row + winfo.height - 3
      col = winfo.col
    end
  else
    width = math.floor(vim.o.columns * 0.45)
    row   = vim.o.lines - 5
    col   = math.floor((vim.o.columns - width) / 2)
  end

  -- Clamp
  row   = math.max(0, math.min(row, vim.o.lines - 5))
  width = math.max(20, width)

  input_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("bufhidden",  "wipe",     { buf = input_buf })
  vim.api.nvim_set_option_value("buftype",    "nofile",   { buf = input_buf })
  vim.api.nvim_set_option_value("filetype",   "dcode-input", { buf = input_buf })

  -- Pre-fill
  if prefill and prefill ~= "" then
    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { prefill })
  end

  input_win = vim.api.nvim_open_win(input_buf, true, {
    relative  = "editor",
    width     = width - 2,
    height    = 3,
    row       = row,
    col       = col + 1,
    style     = "minimal",
    border    = "rounded",
    title     = " " .. prompt .. " ",
    title_pos = "left",
  })

  vim.api.nvim_set_option_value("wrap",      true,  { win = input_win })
  vim.api.nvim_set_option_value("winhighlight",
    "Normal:Normal,FloatBorder:DcodeBorder", { win = input_win })

  input_cb = on_submit

  local function submit()
    if not input_buf or not vim.api.nvim_buf_is_valid(input_buf) then return end
    local lines = vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)
    local text  = vim.trim(table.concat(lines, "\n"))
    M.close_input()
    if text ~= "" and input_cb then
      input_cb(text)
    end
  end

  local ko = { buffer = input_buf, noremap = true, silent = true }
  vim.keymap.set("i", "<CR>",  submit,          ko)
  vim.keymap.set("i", "<C-s>", submit,          ko)
  vim.keymap.set("n", "<CR>",  submit,          ko)
  vim.keymap.set("n", "<C-s>", submit,          ko)
  vim.keymap.set({ "n","i" }, "<Esc>",   function() M.close_input() end, ko)
  vim.keymap.set({ "n","i" }, "<C-c>",   function() M.close_input() end, ko)

  -- Auto-close if focus leaves the input window
  vim.api.nvim_create_autocmd("WinLeave", {
    buffer  = input_buf,
    once    = true,
    callback= function()
      vim.schedule(function()
        if input_win_valid() then M.close_input() end
      end)
    end,
  })

  -- Start in insert mode at end of line
  vim.cmd("startinsert!")
end

-- ─── Session readiness ────────────────────────────────────────────────────────

--- Ensure server up + session exists, then call cb(session_id).
--- Resumes the most-recent session on first use per Neovim session;
--- subsequent calls reuse the already-set current_id.
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
      -- Resume latest or create new
      session.resume_or_create(nil, function(ok, id)
        if ok then cb(id) end
      end)
    end
  end)
end

-- ─── Context builder ─────────────────────────────────────────────────────────

---@param selection boolean  Use visual selection if true, else full buffer
---@return string  fenced context block (empty string if nothing)
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

--- Send a prompt to dcode. Shows display_text in UI, sends full_msg to API.
---@param full_msg    string
---@param display_text string
local function dispatch(full_msg, display_text)
  local cfg = require("dcode").config
  if not ui.is_open() then ui.open(cfg.window) end
  ensure_ready(function(sid)
    stream.run(sid, full_msg, display_text, function(err)
      if err then ui.notify("Error: " .. err, vim.log.levels.ERROR) end
    end)
  end)
end

-- ─── Public commands ─────────────────────────────────────────────────────────

--- Open the floating input window (bound to `i` in chat, and <leader>da).
function M.open_input()
  local cfg = require("dcode").config
  if not ui.is_open() then ui.open(cfg.window) end
  open_input_win("dcode  ask", "", function(text)
    dispatch(text, text)
  end)
end

--- Ask with the current buffer as additional context.
---@param prompt string|nil  If nil, opens input window
function M.ask(prompt)
  if prompt then
    local ctx  = get_context(false)
    local full = ctx ~= "" and (ctx .. "\n\n" .. prompt) or prompt
    dispatch(full, prompt)
  else
    M.open_input()
  end
end

--- Ask with full file context (explicit label in UI).
function M.context_ask()
  open_input_win("dcode  full file", "", function(text)
    local ctx  = get_context(false)
    local full = ctx ~= "" and (ctx .. "\n\n" .. text) or text
    local label = "[file] " .. text
    dispatch(full, label)
  end)
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

--- Start a brand-new session (clears chat, resets session ID).
function M.new_session()
  session.current_id = nil
  ui.reset()
  local cfg = require("dcode").config
  if not ui.is_open() then ui.open(cfg.window) end
  ensure_ready(function(_)
    ui.notify("New session ready", vim.log.levels.INFO)
  end)
end

--- Show available models as a notification.
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
