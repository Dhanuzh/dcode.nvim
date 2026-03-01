-- lua/dcode/session.lua
-- Session lifecycle: create, resume, list, delete.

local client = require("dcode.client")
local ui     = require("dcode.ui")

local M = {}

---@type string|nil  active session ID
M.current_id = nil

--- Create a new dcode session.
---@param opts table|nil   { agent?, model?, provider? }
---@param cb   fun(ok: boolean, session_id: string|nil)
function M.create(opts, cb)
  local payload = opts or {}
  client.post("/session", payload, function(ok, data)
    if ok and type(data) == "table" and data.id then
      M.current_id = data.id
      ui.set_session_info(data.agent, data.model, data.title)
      ui.notify("Session created: " .. data.id, vim.log.levels.INFO)
      if cb then cb(true, data.id) end
    else
      local err = type(data) == "string" and data or "failed to create session"
      ui.notify(err, vim.log.levels.ERROR)
      if cb then cb(false, nil) end
    end
  end)
end

--- Resume the most-recent session, or create one if none exist.
---@param opts table|nil   { agent?, model?, provider? }
---@param cb   fun(ok: boolean, session_id: string|nil)
function M.resume_or_create(opts, cb)
  client.get("/session", function(ok, data)
    if ok and type(data) == "table" and #data > 0 then
      local latest = data[1]
      M.current_id = latest.id
      ui.set_session_info(latest.agent, latest.model, latest.title)
      ui.notify("Resumed: " .. (latest.title or latest.id), vim.log.levels.INFO)
      if cb then cb(true, latest.id) end
    else
      M.create(opts, cb)
    end
  end)
end

--- List all sessions, call cb with the array.
---@param cb fun(ok: boolean, sessions: table[])
function M.list(cb)
  client.get("/session", function(ok, data)
    if ok and type(data) == "table" then
      cb(true, data)
    else
      cb(false, {})
    end
  end)
end

--- Delete a session by ID.
---@param session_id string
---@param cb         fun(ok: boolean)
function M.delete(session_id, cb)
  client.delete("/session/" .. session_id, function(ok, _)
    if ok then
      if M.current_id == session_id then
        M.current_id = nil
        ui.set_session_info(nil, nil, "dcode")
      end
      ui.notify("Session deleted: " .. session_id, vim.log.levels.INFO)
    else
      ui.notify("Failed to delete session", vim.log.levels.ERROR)
    end
    if cb then cb(ok) end
  end)
end

--- Fork the current session at the latest message.
---@param cb fun(ok: boolean, new_id: string|nil)
function M.fork(cb)
  if not M.current_id then
    ui.notify("No active session to fork", vim.log.levels.WARN)
    if cb then cb(false, nil) end
    return
  end
  client.post("/session/" .. M.current_id .. "/fork", {}, function(ok, data)
    if ok and type(data) == "table" and data.id then
      M.current_id = data.id
      ui.set_session_info(data.agent, data.model, (data.title or data.id) .. " (fork)")
      ui.notify("Forked → " .. data.id, vim.log.levels.INFO)
      if cb then cb(true, data.id) end
    else
      ui.notify("Fork failed", vim.log.levels.ERROR)
      if cb then cb(false, nil) end
    end
  end)
end

--- Get messages for current session.
---@param cb fun(ok: boolean, messages: table[])
function M.messages(cb)
  if not M.current_id then
    if cb then cb(false, {}) end
    return
  end
  client.get("/session/" .. M.current_id .. "/messages", function(ok, data)
    if cb then cb(ok, ok and data or {}) end
  end)
end

return M
