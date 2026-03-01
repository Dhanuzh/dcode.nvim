-- lua/dcode/init.lua
-- Plugin entry point. Call require("dcode").setup(opts) from your lazy.nvim spec.

local M = {}

---@class DcodeConfig
---@field server     { host: string, port: integer }
---@field window     { style: "sidebar"|"float"|"vsplit"|"split", width: number, height: number }
---@field keymaps    { prefix: string, enabled: boolean }
---@field auto_start boolean

---@type DcodeConfig
M.config = {
  server     = { host = "127.0.0.1", port = 4096 },
  window     = { style = "sidebar", width = 0.40, height = 0.80 },
  keymaps    = { prefix = "<leader>d", enabled = true },
  auto_start = false,
}

-- did_setup: tracks whether side-effects (autocmds, keymaps, server check)
-- have been registered. Config merge always runs — safe to call setup() again.
local did_setup = false

---@param opts DcodeConfig|nil
function M.setup(opts)
  -- Always merge config so options can be changed on reload
  if opts then
    M.config = vim.tbl_deep_extend("force", M.config, opts)
  end

  -- Sub-module config (safe to call multiple times)
  require("dcode.client").setup(M.config.server)
  require("dcode.ui").setup_highlights()

  if did_setup then return end
  did_setup = true

  -- Register :Dcode* commands once
  require("dcode.commands").register()

  -- Internal keymaps (only if user didn't disable them in opts)
  if M.config.keymaps.enabled then
    M._setup_keymaps()
  end

  -- Optional: auto-start dcode serve
  if M.config.auto_start then
    M._maybe_start_server()
  end
end

-- ─── Keymaps (internal — only used when keymaps.enabled = true) ──────────────

function M._setup_keymaps()
  local p   = M.config.keymaps.prefix
  local map = function(mode, suffix, fn, desc)
    vim.keymap.set(mode, p .. suffix, fn, { desc = "dcode: " .. desc, silent = true })
  end
  local cmds = require("dcode.commands")
  local tele = require("dcode.telescope")

  map("n", "t", function() M.toggle() end,           "toggle chat window")
  map("n", "w", function() M.open() end,             "open chat window")
  map("n", "a", function() cmds.open_input() end,    "ask")
  map("n", "c", function() cmds.context_ask() end,   "ask with full file")
  map("n", "n", function() cmds.new_session() end,   "new session")
  map("v", "e", function() cmds.explain() end,       "explain selection")
  map("v", "f", function() cmds.fix() end,           "fix selection")
  map("v", "r", function() cmds.review() end,        "review selection")
  map("v", "T", function() cmds.tests() end,         "generate tests")
  map("v", "i", function() cmds.docs() end,          "add docs")
  map("n", "s", function() tele.sessions() end,      "browse sessions")
  map("n", "m", function() tele.models() end,        "switch model")
end

-- ─── Server auto-start ────────────────────────────────────────────────────────

function M._maybe_start_server()
  require("dcode.client").ping(function(alive)
    if alive then return end
    local job = vim.fn.jobstart({ "dcode", "serve" }, {
      detach    = true,
      on_stderr = function(_, data)
        if data and data[1] ~= "" then
          vim.schedule(function()
            vim.notify("[dcode] server: " .. table.concat(data, "\n"), vim.log.levels.DEBUG)
          end)
        end
      end,
    })
    if job <= 0 then
      vim.schedule(function()
        vim.notify("[dcode] Failed to start dcode serve — is dcode in your PATH?", vim.log.levels.ERROR)
      end)
    else
      vim.defer_fn(function()
        require("dcode.client").ping(function(ok)
          if ok then
            vim.notify("[dcode] server started", vim.log.levels.INFO)
          else
            vim.notify("[dcode] server did not start. Run `dcode serve` manually.", vim.log.levels.WARN)
          end
        end)
      end, 1500)
    end
  end)
end

-- ─── Public API ───────────────────────────────────────────────────────────────

function M.open()
  local was_open = require("dcode.ui").is_open()
  require("dcode.ui").open(M.config.window)
  -- Auto-open the input pane on first open
  if not was_open then
    vim.schedule(function()
      require("dcode.commands").after_open()
    end)
  end
end

function M.close()
  require("dcode.ui").close()
end

function M.toggle()
  if require("dcode.ui").is_open() then
    require("dcode.ui").close()
  else
    M.open()
  end
end

---@param message string
function M.ask(message)
  require("dcode.commands").ask(message)
end

return M
