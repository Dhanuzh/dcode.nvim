-- lua/dcode/ui.lua
-- All UI: floating chat window, sidebar, input prompt, highlights.

local M = {}

-- ─── Highlight groups ────────────────────────────────────────────────────────

local hl = {
  border    = "DcodeBorder",
  title     = "DcodeTitle",
  user      = "DcodeUser",
  assistant = "DcodeAssistant",
  tool      = "DcodeTool",
  thinking  = "DcodeThinking",
  cost      = "DcodeCost",
  separator = "DcodeSeparator",
  status_ok = "DcodeStatusOk",
  status_err= "DcodeStatusErr",
}

function M.setup_highlights()
  local function hi(group, opts)
    vim.api.nvim_set_hl(0, group, opts)
  end
  hi(hl.border,    { fg = "#7aa2f7", bold = true })
  hi(hl.title,     { fg = "#bb9af7", bold = true })
  hi(hl.user,      { fg = "#9ece6a", bold = true })
  hi(hl.assistant, { fg = "#7dcfff", bold = true })
  hi(hl.tool,      { fg = "#e0af68", italic = true })
  hi(hl.thinking,  { fg = "#565f89", italic = true })
  hi(hl.cost,      { fg = "#565f89" })
  hi(hl.separator, { fg = "#3b4261" })
  hi(hl.status_ok, { fg = "#9ece6a" })
  hi(hl.status_err,{ fg = "#f7768e" })
  -- Suppress markdown code-fence background highlight bleed in the chat window
  -- (set via winhighlight per-window in open())
end

-- ─── State ───────────────────────────────────────────────────────────────────

---@class DcodeWindow
---@field buf  integer
---@field win  integer
---@field lines string[]

local chat_win = nil  ---@type DcodeWindow|nil
local state = {
  session_id   = nil,  ---@type string|nil
  session_title= "dcode",
  streaming    = false,
  stream_start_line = 0,  -- line index where current assistant reply starts
  status       = "",
}

-- ─── Buffer helpers ───────────────────────────────────────────────────────────

--- Set a buffer option compatibly across Nvim versions.
local function buf_set(buf, name, value)
  if vim.fn.has("nvim-0.10") == 1 then
    vim.api.nvim_set_option_value(name, value, { buf = buf })
  else
    vim.api.nvim_buf_set_option(buf, name, value)  -- luacheck: ignore
  end
end

--- Set a window option compatibly across Nvim versions.
local function win_set(win, name, value)
  if vim.fn.has("nvim-0.10") == 1 then
    vim.api.nvim_set_option_value(name, value, { win = win })
  else
    vim.api.nvim_win_set_option(win, name, value)  -- luacheck: ignore
  end
end

--- Append lines to the chat buffer (always modifiable).
---@param lines string[]
local function buf_append(lines)
  if not chat_win or not vim.api.nvim_buf_is_valid(chat_win.buf) then return end
  buf_set(chat_win.buf, "modifiable", true)
  local last = vim.api.nvim_buf_line_count(chat_win.buf)
  vim.api.nvim_buf_set_lines(chat_win.buf, last, last, false, lines)
  buf_set(chat_win.buf, "modifiable", false)
  -- Scroll to bottom if window is valid
  if vim.api.nvim_win_is_valid(chat_win.win) then
    local new_last = vim.api.nvim_buf_line_count(chat_win.buf)
    vim.api.nvim_win_set_cursor(chat_win.win, { new_last, 0 })
  end
end

--- Replace the last N lines of the chat buffer.
---@param n     integer  number of lines to replace
---@param lines string[]
local function buf_replace_tail(n, lines)
  if not chat_win or not vim.api.nvim_buf_is_valid(chat_win.buf) then return end
  buf_set(chat_win.buf, "modifiable", true)
  local last = vim.api.nvim_buf_line_count(chat_win.buf)
  vim.api.nvim_buf_set_lines(chat_win.buf, last - n, last, false, lines)
  buf_set(chat_win.buf, "modifiable", false)
  if vim.api.nvim_win_is_valid(chat_win.win) then
    local new_last = vim.api.nvim_buf_line_count(chat_win.buf)
    vim.api.nvim_win_set_cursor(chat_win.win, { new_last, 0 })
  end
end

-- ─── Window creation ─────────────────────────────────────────────────────────

---@class DcodeWindowOpts
---@field style  "float"|"vsplit"|"split"
---@field width  number   0–1 fraction of screen width (for float/vsplit)
---@field height number   0–1 fraction of screen height (for float/split)

--- Open (or focus) the chat window.
---@param opts DcodeWindowOpts
function M.open(opts)
  opts = opts or {}
  local style  = opts.style  or "float"
  local wfrac  = opts.width  or 0.45
  local hfrac  = opts.height or 0.80

  -- If already open, just focus it
  if chat_win and vim.api.nvim_win_is_valid(chat_win.win) then
    vim.api.nvim_set_current_win(chat_win.win)
    return
  end

  -- Re-use existing buffer if valid, otherwise create fresh
  local buf
  if chat_win and vim.api.nvim_buf_is_valid(chat_win.buf) then
    buf = chat_win.buf
    -- Clear stale content from previous session
    buf_set(buf, "modifiable", true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
    buf_set(buf, "modifiable", false)
  else
    buf = vim.api.nvim_create_buf(false, true)
    -- Use plain text — not markdown — to avoid syntax hl painting
    -- code-fence backgrounds (the teal bleed in the screenshot)
    buf_set(buf, "filetype", "")
    buf_set(buf, "modifiable", false)
    buf_set(buf, "bufhidden", "hide")
  end

  local win
  if style == "float" then
    local total_w = vim.o.columns
    local total_h = vim.o.lines - vim.o.cmdheight - 2
    local w = math.floor(total_w * wfrac)
    local h = math.floor(total_h * hfrac)
    local row = math.floor((total_h - h) / 2)
    local col = math.floor((total_w - w) / 2)

    win = vim.api.nvim_open_win(buf, true, {
      relative = "editor",
      width    = w,
      height   = h,
      row      = row,
      col      = col,
      style    = "minimal",
      border   = "rounded",
      title    = " dcode — " .. state.session_title .. " ",
      title_pos= "center",
    })
  elseif style == "vsplit" then
    local w = math.floor(vim.o.columns * wfrac)
    vim.cmd("vsplit")
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    vim.api.nvim_win_set_width(win, w)
  else -- split (horizontal)
    local h = math.floor(vim.o.lines * hfrac)
    vim.cmd("split")
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    vim.api.nvim_win_set_height(win, h)
  end

  win_set(win, "wrap", true)
  win_set(win, "linebreak", true)
  win_set(win, "number", false)
  win_set(win, "signcolumn", "no")
  win_set(win, "cursorline", false)
  -- Suppress ALL syntax-driven bg highlights inside the chat window:
  -- Normal, NormalFloat, Search, Visual, CursorLine all map to plain Normal
  win_set(win, "winhighlight",
    "Normal:Normal,NormalFloat:Normal,FloatBorder:" .. hl.border ..
    ",Search:Normal,IncSearch:Normal,Visual:Visual,CursorLine:Normal" ..
    ",markdownCode:Normal,markdownCodeBlock:Normal"
  )

  -- Close / input keymaps inside the chat window
  local kopts = { buffer = buf, noremap = true, silent = true }
  vim.keymap.set("n", "q",     function() M.close() end, kopts)
  vim.keymap.set("n", "<Esc>", function() M.close() end, kopts)
  vim.keymap.set("n", "i",     function()
    -- Open the input prompt instead of inserting into the read-only buffer
    vim.schedule(function() require("dcode.commands").prompt_input() end)
  end, kopts)

  chat_win = { buf = buf, win = win, lines = {} }

  -- Show welcome header
  buf_set(buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "  dcode chat",
    "  Press i or <leader>da to ask",
    "  Press q / <Esc> to close",
    "  Press <leader>ds to browse sessions",
    "",
  })
  buf_set(buf, "modifiable", false)
end

--- Close the chat window (keeps buffer alive for next open).
function M.close()
  if chat_win and vim.api.nvim_win_is_valid(chat_win.win) then
    vim.api.nvim_win_close(chat_win.win, true)
  end
  -- Keep chat_win.buf alive but mark win as closed
  if chat_win then
    chat_win = { buf = chat_win.buf, win = -1, lines = chat_win.lines }
  end
end

--- Toggle the chat window.
---@param opts DcodeWindowOpts
function M.toggle(opts)
  if chat_win and vim.api.nvim_win_is_valid(chat_win.win) then
    M.close()
  else
    M.open(opts)
  end
end

-- ─── Chat rendering ──────────────────────────────────────────────────────────

local separator = string.rep("─", 50)

--- Render a user message in the chat buffer.
---@param text string
function M.render_user(text)
  local lines = {
    "",
    "▶ You",
    separator,
  }
  for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
    table.insert(lines, line)
  end
  table.insert(lines, "")
  buf_append(lines)
end

--- Begin an assistant reply block (before streaming starts).
function M.begin_assistant()
  state.streaming = true
  stream_buf = ""  -- reset on every new reply
  local lines = {
    "◀ dcode",
    separator,
    "",  -- streaming cursor line
  }
  buf_append(lines)
  -- Remember where this reply starts so we can update it in-place
  if chat_win and vim.api.nvim_buf_is_valid(chat_win.buf) then
    state.stream_start_line = vim.api.nvim_buf_line_count(chat_win.buf)
  end
end

--- Accumulate text during streaming — updates the last line in-place.
local stream_buf = ""
function M.append_stream_text(chunk)
  if not state.streaming then return end
  stream_buf = stream_buf .. chunk
  -- Split on newlines; the last element may be partial
  local parts = vim.split(stream_buf, "\n", { plain = true })
  if #parts > 1 then
    -- Complete lines: append all but last
    local complete = {}
    for i = 1, #parts - 1 do
      table.insert(complete, parts[i])
    end
    stream_buf = parts[#parts]
    buf_replace_tail(1, complete)
    buf_append({ stream_buf })
  else
    buf_replace_tail(1, { stream_buf })
  end
end

--- Append a tool-use notification line.
---@param tool_name string
---@param detail    string|nil
function M.render_tool(tool_name, detail)
  local line = "  ⚙ " .. tool_name
  if detail and detail ~= "" then
    line = line .. " — " .. detail:sub(1, 60)
  end
  buf_append({ line })
end

--- Append a thinking/reasoning line.
---@param text string
function M.render_thinking(text)
  buf_append({ "  ≋ " .. text:sub(1, 80) })
end

--- Finish an assistant reply block.
---@param cost   number|nil
---@param tokens table|nil  {input, output}
function M.end_assistant(cost, tokens)
  state.streaming = false
  -- Flush any remaining stream buffer
  if stream_buf ~= "" then
    buf_replace_tail(1, { stream_buf })
    stream_buf = ""
  end
  -- Append cost/token footer
  if cost and cost > 0 or (tokens and (tokens.input or 0) > 0) then
    local parts = {}
    if tokens then
      table.insert(parts, string.format("in: %d  out: %d", tokens.input or 0, tokens.output or 0))
    end
    if cost and cost > 0 then
      table.insert(parts, string.format("$%.5f", cost))
    end
    buf_append({ "  " .. table.concat(parts, "  ·  "), "" })
  else
    buf_append({ "" })
  end
end

--- Show an error line in the chat buffer.
---@param msg string
function M.render_error(msg)
  state.streaming = false
  stream_buf = ""
  buf_append({ "", "✗ Error: " .. msg, "" })
end

--- Set the window title (updates session name).
---@param title string
function M.set_title(title)
  state.session_title = title
  if chat_win and vim.api.nvim_win_is_valid(chat_win.win) then
    -- Floating window: update config
    pcall(vim.api.nvim_win_set_config, chat_win.win, {
      title     = " dcode — " .. title .. " ",
      title_pos = "center",
    })
  end
end

--- Show a transient status notification (uses vim.notify).
---@param msg  string
---@param level integer  vim.log.levels.*
function M.notify(msg, level)
  vim.notify("[dcode] " .. msg, level or vim.log.levels.INFO)
end

--- Is the chat window currently open?
---@return boolean
function M.is_open()
  return chat_win ~= nil
    and chat_win.win ~= -1
    and vim.api.nvim_win_is_valid(chat_win.win)
end

--- Get the chat buffer number (for highlights etc.)
---@return integer|nil
function M.bufnr()
  return chat_win and chat_win.buf or nil
end

return M
