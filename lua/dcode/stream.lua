-- lua/dcode/stream.lua
-- Drives an SSE streaming prompt request and routes events to the UI.

local client = require("dcode.client")
local ui     = require("dcode.ui")

local M = {}

-- ─── Debug logging ───────────────────────────────────────────────────────────
local _logfile = io.open("/tmp/dcode_debug.log", "a")
local function dbg(...)
  if _logfile then
    _logfile:write(table.concat(vim.tbl_map(tostring, {...}), " ") .. "\n")
    _logfile:flush()
  end
end

--- Stream a prompt to the dcode server and render events into the chat UI.
---@param session_id   string
---@param message      string   Full message sent to API (may include code context)
---@param display_text string   Clean text shown in chat (what the user typed)
---@param on_done      fun(err: string|nil)
function M.run(session_id, message, display_text, on_done)
  ui.render_user(display_text or message)
  ui.begin_assistant()

  local total_cost   = 0.0
  local total_tokens = { input = 0, output = 0 }
  local done_called  = false

  local function finish(err)
    if done_called then return end
    done_called = true
    if on_done then on_done(err) end
  end

  client.stream(
    "/session/" .. session_id .. "/prompt",
    { message = message },

    function(event)
      local t = event.type
      dbg("stream.run: on_chunk event.type=", t, "content=", tostring((event.content or ""):sub(1,40)))

      if t == "text" then
        ui.append_stream_text(event.content or "")

      elseif t == "thinking" then
        local line = (event.content or ""):gsub("\n", " "):sub(1, 100)
        if line ~= "" then ui.render_thinking(line) end

      elseif t == "tool_start" then
        ui.render_tool(event.tool_name or "?", event.content)

      elseif t == "tool_end" then
        -- no-op; tool_start already showed the name

      elseif t == "step_end" then
        if event.tokens then
          total_tokens.input  = total_tokens.input  + (event.tokens.input  or 0)
          total_tokens.output = total_tokens.output + (event.tokens.output or 0)
        end
        if event.cost then
          total_cost = total_cost + event.cost
        end

      elseif t == "retry" then
        ui.notify("Retrying (" .. (event.attempt or "?") .. "): " .. (event.content or ""), vim.log.levels.WARN)

      elseif t == "compaction" then
        ui.notify("Context compacted", vim.log.levels.INFO)

      elseif t == "error" then
        ui.render_error(event.content or "unknown error")
        finish(event.content)

      elseif t == "done" then
        ui.end_assistant(total_cost, total_tokens)
        finish(nil)
      end
    end,

    function(err)
      if err then
        ui.render_error(err)
        ui.end_assistant(0, nil)
        finish(err)
      else
        -- TCP closed without a "done" event — treat as done
        ui.end_assistant(total_cost, total_tokens)
        finish(nil)
      end
    end
  )
end

return M
