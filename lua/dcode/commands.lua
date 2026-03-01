-- lua/dcode/commands.lua
-- User-facing commands: ask, explain, fix, inline-edit, context injection.

local client  = require("dcode.client")
local ui      = require("dcode.ui")
local session = require("dcode.session")
local stream  = require("dcode.stream")

local M = {}

--- Ensure dcode serve is up and we have a session, then call cb(session_id).
--- Always creates a fresh session for the first prompt in this Neovim session.
---@param cb fun(session_id: string)
local function ensure_ready(cb)
  client.ping(function(alive)
    if not alive then
      ui.notify(
        "dcode server not running. Start it with: dcode serve",
        vim.log.levels.ERROR
      )
      return
    end
    if session.current_id then
      cb(session.current_id)
    else
      -- Always create a new session — don't silently resume an old one
      session.create(nil, function(ok, id)
        if ok then cb(id) end
      end)
    end
  end)
end

--- Build a context block from the current buffer (or visual selection).
---@param include_selection boolean  If true, use visual selection
---@return string  markdown-fenced context block
local function get_context(include_selection)
  local lines
  local ft = vim.bo.filetype or ""
  local fname = vim.fn.expand("%:.")

  if include_selection then
    -- Get the last visual selection
    local s = vim.fn.getpos("'<")
    local e = vim.fn.getpos("'>")
    lines = vim.api.nvim_buf_get_lines(0, s[2] - 1, e[2], false)
    -- Trim last line to column
    if lines[#lines] then
      lines[#lines] = lines[#lines]:sub(1, e[3])
    end
  else
    lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  end

  if #lines == 0 then return "" end

  local code = table.concat(lines, "\n")
  return string.format("```%s\n-- file: %s\n%s\n```", ft, fname, code)
end

--- Show a vim.ui.input prompt, collect text, then stream to dcode.
--- Opens the chat window first if not already open.
---@param prefill string|nil   Pre-fill text for the input
function M.prompt_input(prefill)
  local cfg = require("dcode").config
  if not ui.is_open() then
    ui.open(cfg.window)
  end

  vim.ui.input({ prompt = " dcode › ", default = prefill or "" }, function(input)
    if not input or input == "" then return end
    ensure_ready(function(session_id)
      -- Display only the user's typed text, not the context blob
      stream.run(session_id, input, input, function(err)
        if err then
          ui.notify("Stream error: " .. err, vim.log.levels.ERROR)
        end
      end)
    end)
  end)
end

--- Ask dcode something with the current buffer as context.
---@param prompt string|nil  If nil, ask via input prompt
function M.ask(prompt)
  if prompt then
    local ctx = get_context(false)
    local full = ctx ~= "" and (ctx .. "\n\n" .. prompt) or prompt
    local cfg = require("dcode").config
    if not ui.is_open() then ui.open(cfg.window) end
    ensure_ready(function(session_id)
      stream.run(session_id, full, prompt, function(err)
        if err then ui.notify("Error: " .. err, vim.log.levels.ERROR) end
      end)
    end)
  else
    M.prompt_input()
  end
end

--- Ask dcode to explain the current visual selection.
function M.explain()
  local ctx = get_context(true)
  if ctx == "" then
    ui.notify("Select some code first", vim.log.levels.WARN)
    return
  end
  local prompt = ctx .. "\n\nExplain this code clearly and concisely."
  local cfg = require("dcode").config
  if not ui.is_open() then ui.open(cfg.window) end
  ensure_ready(function(session_id)
    stream.run(session_id, prompt, "Explain selection", function(err)
      if err then ui.notify("Error: " .. err, vim.log.levels.ERROR) end
    end)
  end)
end

--- Ask dcode to fix the current visual selection.
function M.fix()
  local ctx = get_context(true)
  if ctx == "" then
    ui.notify("Select some code first", vim.log.levels.WARN)
    return
  end
  local prompt = ctx .. "\n\nFix any bugs or issues in this code. Return only the corrected code."
  local cfg = require("dcode").config
  if not ui.is_open() then ui.open(cfg.window) end
  ensure_ready(function(session_id)
    stream.run(session_id, prompt, "Fix selection", function(err)
      if err then ui.notify("Error: " .. err, vim.log.levels.ERROR) end
    end)
  end)
end

--- Ask dcode to review the visual selection.
function M.review()
  local ctx = get_context(true)
  if ctx == "" then ctx = get_context(false) end
  local prompt = ctx .. "\n\nReview this code for correctness, performance, and style. Be specific."
  local cfg = require("dcode").config
  if not ui.is_open() then ui.open(cfg.window) end
  ensure_ready(function(session_id)
    stream.run(session_id, prompt, "Review code", function(err)
      if err then ui.notify("Error: " .. err, vim.log.levels.ERROR) end
    end)
  end)
end

--- Ask dcode to generate tests for the visual selection.
function M.tests()
  local ctx = get_context(true)
  if ctx == "" then ctx = get_context(false) end
  local ft = vim.bo.filetype or ""
  local prompt = ctx .. "\n\nWrite comprehensive unit tests for this code in " .. ft .. "."
  local cfg = require("dcode").config
  if not ui.is_open() then ui.open(cfg.window) end
  ensure_ready(function(session_id)
    stream.run(session_id, prompt, "Generate tests (" .. ft .. ")", function(err)
      if err then ui.notify("Error: " .. err, vim.log.levels.ERROR) end
    end)
  end)
end

--- Ask dcode to add inline documentation to the selection.
function M.docs()
  local ctx = get_context(true)
  if ctx == "" then ctx = get_context(false) end
  local prompt = ctx .. "\n\nAdd clear inline documentation/comments to this code."
  local cfg = require("dcode").config
  if not ui.is_open() then ui.open(cfg.window) end
  ensure_ready(function(session_id)
    stream.run(session_id, prompt, "Add docs", function(err)
      if err then ui.notify("Error: " .. err, vim.log.levels.ERROR) end
    end)
  end)
end

--- Send entire current buffer as context with a custom prompt.
function M.context_ask()
  vim.ui.input({ prompt = " dcode (full file) › " }, function(input)
    if not input or input == "" then return end
    local ctx = get_context(false)
    local full = ctx ~= "" and (ctx .. "\n\n" .. input) or input
    local cfg = require("dcode").config
    if not ui.is_open() then ui.open(cfg.window) end
    ensure_ready(function(session_id)
      stream.run(session_id, full, input, function(err)
        if err then ui.notify("Error: " .. err, vim.log.levels.ERROR) end
      end)
    end)
  end)
end

--- Start a brand-new session.
function M.new_session()
  M.close_current_session()
  local cfg = require("dcode").config
  if not ui.is_open() then ui.open(cfg.window) end
  ensure_ready(function(_)
    ui.notify("New session ready", vim.log.levels.INFO)
  end)
end

--- Clear and reset the current session (fork a clean one).
function M.close_current_session()
  session.current_id = nil
  ui.set_title("dcode")
end

--- Fetch and display models from the running server.
function M.show_models()
  client.get("/model", function(ok, data)
    if not ok then
      ui.notify("Could not fetch models (is dcode serve running?)", vim.log.levels.WARN)
      return
    end
    local lines = { "Available models:", "" }
    if type(data) == "table" then
      for prov, info in pairs(data) do
        local model_id = type(info) == "table" and (info.id or info.ID or "?") or tostring(info)
        table.insert(lines, string.format("  %-22s %s", prov, model_id))
      end
    end
    table.sort(lines)
    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
  end)
end

--- Register all :Dcode* user commands.
function M.register()
  local function cmd(name, fn, desc, range)
    vim.api.nvim_create_user_command(name, fn, {
      desc  = desc,
      range = range or false,
      nargs = "?",
    })
  end

  cmd("DcodeToggle",     function() require("dcode").toggle() end,             "Toggle dcode chat window")
  cmd("DcodeAsk",        function(a) M.ask(a.args ~= "" and a.args or nil) end,"Ask dcode (with buffer context)")
  cmd("DcodeExplain",    function() M.explain() end,                           "Explain selection",        true)
  cmd("DcodeFix",        function() M.fix() end,                               "Fix selection",            true)
  cmd("DcodeReview",     function() M.review() end,                            "Review code",              true)
  cmd("DcodeTests",      function() M.tests() end,                             "Generate tests",           true)
  cmd("DcodeDocs",       function() M.docs() end,                              "Add documentation",        true)
  cmd("DcodeContext",    function() M.context_ask() end,                       "Ask with full file context")
  cmd("DcodeNew",        function() M.new_session() end,                       "Start a new dcode session")
  cmd("DcodeModels",     function() M.show_models() end,                       "List available models")
  cmd("DcodeSessions",   function() require("dcode.telescope").sessions() end, "Browse sessions (Telescope)")
end

return M
