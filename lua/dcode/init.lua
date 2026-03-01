-- lua/dcode/init.lua
-- Plugin entry point. Call require("dcode").setup(opts) from your lazy.nvim spec.

local M = {}

---@class DcodeConfig
---@field server   { host: string, port: integer }
---@field window   { style: "float"|"vsplit"|"split", width: number, height: number }
---@field keymaps  { prefix: string, enabled: boolean }
---@field auto_start boolean  Start dcode serve automatically if not running

---@type DcodeConfig
M.config = {
  server = {
    host = "127.0.0.1",
    port = 4096,
  },
  window = {
    style  = "float",  -- "float" | "vsplit" | "split"
    width  = 0.45,     -- fraction of screen width
    height = 0.80,     -- fraction of screen height
  },
  keymaps = {
    prefix  = "<leader>d",
    enabled = true,
  },
  auto_start = false,  -- set true to run `dcode serve` automatically
}

local initialized = false

---@param opts DcodeConfig|nil
function M.setup(opts)
  if initialized then return end
  initialized = true

  -- Merge user options
  if opts then
    M.config = vim.tbl_deep_extend("force", M.config, opts)
  end

  -- Configure sub-modules
  require("dcode.client").setup(M.config.server)
  require("dcode.ui").setup_highlights()

  -- Register :Dcode* commands
  require("dcode.commands").register()

  -- Set up keymaps
  if M.config.keymaps.enabled then
    M._setup_keymaps()
  end

  -- Optionally auto-start dcode serve
  if M.config.auto_start then
    M._maybe_start_server()
  end
end

-- ─── Keymaps ─────────────────────────────────────────────────────────────────

function M._setup_keymaps()
  local p   = M.config.keymaps.prefix
  local map = function(mode, suffix, fn, desc)
    vim.keymap.set(mode, p .. suffix, fn, { desc = "dcode: " .. desc, silent = true })
  end

  local cmds = require("dcode.commands")
  local tele = require("dcode.telescope")

  -- Window
  map("n", "t", function() M.toggle() end,            "toggle chat window")
  map("n", "o", function() M.open() end,              "open chat window")

  -- Prompts (normal mode — uses full buffer as context)
  map("n", "a", function() cmds.ask() end,            "ask (buffer context)")
  map("n", "c", function() cmds.context_ask() end,    "ask with full file")
  map("n", "n", function() cmds.new_session() end,    "new session")

  -- Prompts (visual mode — uses selection)
  map("v", "e", function() cmds.explain() end,        "explain selection")
  map("v", "f", function() cmds.fix() end,            "fix selection")
  map("v", "r", function() cmds.review() end,         "review selection")
  map("v", "T", function() cmds.tests() end,          "generate tests")
  map("v", "d", function() cmds.docs() end,           "add docs/comments")

  -- Sessions & models
  map("n", "s", function() tele.sessions() end,       "browse sessions")
  map("n", "m", function() tele.models() end,         "switch model")
end

-- ─── Server auto-start ───────────────────────────────────────────────────────

function M._maybe_start_server()
  require("dcode.client").ping(function(alive)
    if alive then return end
    -- Not running — start it in the background
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
        vim.notify("[dcode] Failed to start dcode serve. Is dcode in your PATH?", vim.log.levels.ERROR)
      end)
    else
      -- Give it a moment then notify
      vim.defer_fn(function()
        require("dcode.client").ping(function(ok)
          if ok then
            vim.notify("[dcode] server started", vim.log.levels.INFO)
          else
            vim.notify("[dcode] server did not start in time. Run `dcode serve` manually.", vim.log.levels.WARN)
          end
        end)
      end, 1500)
    end
  end)
end

-- ─── Public API ──────────────────────────────────────────────────────────────

function M.open()
  require("dcode.ui").open(M.config.window)
end

function M.close()
  require("dcode.ui").close()
end

function M.toggle()
  require("dcode.ui").toggle(M.config.window)
end

--- Send a prompt programmatically (for scripting/other plugins).
---@param message string
---@param cb      fun(err: string|nil)|nil
function M.ask(message, cb)
  require("dcode.commands").ask(message)
  -- cb is called by the stream module; pass-through here is for API symmetry
end

return M
