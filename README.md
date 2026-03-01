# dcode.nvim

Neovim plugin for [dcode](https://github.com/Dhanuzh/dcode) — AI-powered coding agent with 20+ providers.

Streams responses live into a floating window or sidebar, supports visual-selection commands, Telescope session/model pickers, and zero external Lua dependencies.

---

## Requirements

- Neovim 0.9+
- [dcode](https://github.com/Dhanuzh/dcode) installed and on your `PATH`
- `dcode serve` running (or set `auto_start = true` in config)
- [Telescope](https://github.com/nvim-telescope/telescope.nvim) (optional — falls back to `vim.ui.select`)

---

## Installation

### lazy.nvim (recommended)

```lua
{
  "Dhanuzh/dcode.nvim",
  dependencies = {
    -- optional but recommended
    "nvim-telescope/telescope.nvim",
  },
  config = function()
    require("dcode").setup({
      -- all options shown with their defaults:
      server = {
        host = "127.0.0.1",
        port = 4096,
      },
      window = {
        style  = "float",   -- "float" | "vsplit" | "split"
        width  = 0.45,      -- fraction of screen width  (float/vsplit)
        height = 0.80,      -- fraction of screen height (float/split)
      },
      keymaps = {
        prefix  = "<leader>d",
        enabled = true,
      },
      auto_start = false,   -- set true to run `dcode serve` automatically
    })
  end,
}
```

---

## Usage

### Step 1 — start the dcode server

```bash
dcode serve
```

Or set `auto_start = true` and the plugin handles it.

### Step 2 — use the keymaps

| Keymap | Mode | Action |
|---|---|---|
| `<leader>dt` | n | Toggle chat window |
| `<leader>do` | n | Open chat window |
| `<leader>da` | n | Ask (sends full buffer as context) |
| `<leader>dc` | n | Ask with full file context (prompt input) |
| `<leader>dn` | n | New session |
| `<leader>ds` | n | Browse sessions (Telescope) |
| `<leader>dm` | n | Switch model (Telescope) |
| `<leader>de` | v | Explain selection |
| `<leader>df` | v | Fix selection |
| `<leader>dr` | v | Review selection |
| `<leader>dT` | v | Generate tests for selection |
| `<leader>dd` | v | Add docs/comments to selection |

Inside the chat window:

| Key | Action |
|---|---|
| `i` | Open input prompt |
| `q` / `<Esc>` | Close window |

### Step 3 — use commands

```vim
:DcodeToggle           " open/close chat
:DcodeAsk fix the bug  " ask with inline text
:DcodeExplain          " explain visual selection
:DcodeFix              " fix visual selection
:DcodeReview           " review visual selection
:DcodeTests            " generate tests for selection
:DcodeDocs             " add docs to selection
:DcodeContext          " prompt with full file as context
:DcodeNew              " start a new session
:DcodeModels           " list all models
:DcodeSessions         " browse sessions (Telescope)
```

---

## How it works

```
Neovim                dcode server (localhost:4096)
  │                          │
  │  POST /session           │  (on first use — create or resume)
  │─────────────────────────>│
  │                          │
  │  POST /session/{id}/prompt  (SSE stream)
  │─────────────────────────>│
  │                          │
  │  data: {"type":"text","content":"Hello"}
  │<─────────────────────────│   streamed token by token
  │  data: {"type":"tool_start","tool_name":"bash"}
  │<─────────────────────────│
  │  data: {"type":"done"}
  │<─────────────────────────│
```

- **No subprocess spawning per request** — talks to the persistent `dcode serve` HTTP server over libuv TCP
- **SSE streaming** — tokens appear in the floating window as they arrive
- **Session persistence** — all conversations are saved by dcode; you can resume them with `<leader>ds`

---

## Configuration examples

### Sidebar layout

```lua
require("dcode").setup({
  window = { style = "vsplit", width = 0.40 },
})
```

### Auto-start server

```lua
require("dcode").setup({
  auto_start = true,
})
```

### Custom prefix

```lua
require("dcode").setup({
  keymaps = { prefix = "<leader>ai" },
})
```

### Disable built-in keymaps (define your own)

```lua
require("dcode").setup({
  keymaps = { enabled = false },
})

local d = require("dcode")
local c = require("dcode.commands")
vim.keymap.set("n", "<C-g>", d.toggle,        { desc = "dcode: toggle" })
vim.keymap.set("v", "<C-e>", c.explain,       { desc = "dcode: explain" })
vim.keymap.set("v", "<C-f>", c.fix,           { desc = "dcode: fix" })
```

---

## File structure

```
dcode.nvim/
├── plugin/
│   └── dcode.lua          # Auto-loaded guard (no setup here)
└── lua/
    └── dcode/
        ├── init.lua        # setup(), keymaps, public API
        ├── client.lua      # libuv TCP HTTP client + SSE streaming
        ├── ui.lua          # floating window, chat rendering, highlights
        ├── stream.lua      # SSE event router → UI
        ├── session.lua     # session create/resume/list/delete/fork
        ├── commands.lua    # ask/explain/fix/review/tests/docs + :Dcode* cmds
        └── telescope.lua   # Telescope pickers for sessions and models
```

---

## License

MIT
