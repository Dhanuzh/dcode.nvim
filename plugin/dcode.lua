-- plugin/dcode.lua
-- Loaded automatically by Neovim when the plugin is on the runtimepath.
-- Does NOT call setup() — the user must call require("dcode").setup() in their
-- lazy.nvim config. This file just guards against double-loading.

if vim.g.dcode_loaded then return end
vim.g.dcode_loaded = true

-- Minimum Neovim version check
if vim.fn.has("nvim-0.9") == 0 then
  vim.notify(
    "[dcode.nvim] Neovim 0.9+ is required. Please upgrade.",
    vim.log.levels.ERROR
  )
  return
end
