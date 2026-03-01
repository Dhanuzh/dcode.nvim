-- lua/dcode/stream.lua
-- Drives an SSE streaming prompt request and routes events to the UI.

local client = require("dcode.client")
local ui     = require("dcode.ui")

local M = {}

--- Run a prompt against the given session, streaming the response into the UI.
---@param session_id string
---@param message    string
---@param on_done    fun(err: string|nil)  called when stream ends
function M.run(session_id, message, on_done)
  -- Show the user's message immediately
  ui.render_user(message)
  ui.begin_assistant()

  local total_cost   = 0.0
  local total_tokens = { input = 0, output = 0 }

  client.stream(
    "/session/" .. session_id .. "/prompt",
    { message = message },

    -- on_chunk: called for each SSE event
    function(event)
      local t = event.type

      if t == "text" then
        ui.append_stream_text(event.content or "")

      elseif t == "thinking" then
        -- Trim long reasoning lines
        local line = (event.content or ""):gsub("\n", " "):sub(1, 100)
        if line ~= "" then
          ui.render_thinking(line)
        end

      elseif t == "tool_start" then
        ui.render_tool(event.tool_name or "?", event.content)

      elseif t == "tool_end" then
        -- nothing extra needed; tool_start already showed the name

      elseif t == "step_end" then
        if event.tokens then
          total_tokens.input  = total_tokens.input  + (event.tokens.input  or 0)
          total_tokens.output = total_tokens.output + (event.tokens.output or 0)
        end
        if event.cost then
          total_cost = total_cost + event.cost
        end

      elseif t == "retry" then
        ui.notify("Retrying (attempt " .. (event.attempt or "?") .. "): " .. (event.content or ""), vim.log.levels.WARN)

      elseif t == "compaction" then
        ui.notify("Context compacted: " .. (event.content or ""), vim.log.levels.INFO)

      elseif t == "error" then
        ui.render_error(event.content or "unknown error")
        if on_done then on_done(event.content) end

      elseif t == "done" then
        ui.end_assistant(total_cost, total_tokens)
        if on_done then on_done(nil) end
      end
    end,

    -- on_done: called on TCP close / error
    function(err)
      if err then
        ui.render_error(err)
        ui.end_assistant(0, nil)
        if on_done then on_done(err) end
      end
      -- If no error, the "done" event above already called on_done
    end
  )
end

return M
