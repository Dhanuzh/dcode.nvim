-- lua/dcode/client.lua
-- HTTP client for the dcode HTTP API (dcode serve, port 4096 by default).
-- Uses vim.loop (libuv) for non-blocking TCP — no external dependencies.

local M = {}

---@class DcodeClientOpts
---@field host string
---@field port integer

---@type DcodeClientOpts
local defaults = { host = "127.0.0.1", port = 4096 }

local config = vim.tbl_extend("force", {}, defaults)

--- Configure the client (called once from init.lua)
---@param opts DcodeClientOpts
function M.setup(opts)
  config = vim.tbl_extend("force", defaults, opts or {})
end

--- Build a raw HTTP/1.1 request string.
---@param method string   e.g. "GET", "POST"
---@param path   string   e.g. "/session"
---@param body   string|nil  JSON body (or nil)
---@return string
local function build_request(method, path, body)
  local host = config.host .. ":" .. config.port
  local lines = {
    method .. " " .. path .. " HTTP/1.1",
    "Host: " .. host,
    "Accept: application/json",
    "Connection: close",
  }
  if body then
    table.insert(lines, "Content-Type: application/json")
    table.insert(lines, "Content-Length: " .. #body)
  end
  table.insert(lines, "")
  table.insert(lines, body or "")
  return table.concat(lines, "\r\n")
end

--- Parse HTTP response: split headers from body, return status code + body.
---@param raw string
---@return integer status, string body
local function parse_response(raw)
  local header_end = raw:find("\r\n\r\n", 1, true)
  if not header_end then
    return 0, raw
  end
  local headers = raw:sub(1, header_end - 1)
  local body = raw:sub(header_end + 4)
  local status = tonumber(headers:match("HTTP/%d%.%d (%d+)")) or 0
  return status, body
end

--- Synchronous-style request using a coroutine + libuv.
--- Yields until data arrives; meant to be called inside vim.schedule or a co.
---@param method string
---@param path   string
---@param payload table|nil  Lua table — will be JSON-encoded
---@param on_done fun(ok: boolean, data: table|string)
function M.request(method, path, payload, on_done)
  local body = payload and vim.fn.json_encode(payload) or nil
  local raw_req = build_request(method, path, body)

  local loop = vim.loop
  local tcp = loop.new_tcp()
  local chunks = {}

  tcp:connect(config.host, config.port, function(err)
    if err then
      vim.schedule(function()
        on_done(false, "connect error: " .. err)
      end)
      return
    end

    tcp:read_start(function(read_err, data)
      if read_err then
        tcp:close()
        vim.schedule(function()
          on_done(false, "read error: " .. read_err)
        end)
        return
      end
      if data then
        table.insert(chunks, data)
      else
        -- EOF
        tcp:close()
        local raw = table.concat(chunks)
        local status, resp_body = parse_response(raw)
        vim.schedule(function()
          if status >= 200 and status < 300 then
            local ok, decoded = pcall(vim.fn.json_decode, resp_body)
            on_done(true, ok and decoded or resp_body)
          else
            on_done(false, "HTTP " .. status .. ": " .. resp_body)
          end
        end)
      end
    end)

    tcp:write(raw_req)
  end)
end

--- Streaming request — calls on_chunk for every SSE "data:" line, on_done at end.
---@param path     string             e.g. "/session/abc123/prompt"
---@param payload  table              Request body
---@param on_chunk fun(event: table)  Called for each parsed SSE event
---@param on_done  fun(err: string|nil)
function M.stream(path, payload, on_chunk, on_done)
  local body = vim.fn.json_encode(payload)
  local raw_req = build_request("POST", path, body)
  -- Override Accept for SSE
  raw_req = raw_req:gsub("Accept: application/json", "Accept: text/event-stream")

  local loop = vim.loop
  local tcp = loop.new_tcp()
  local buf = ""
  local header_done = false

  tcp:connect(config.host, config.port, function(err)
    if err then
      vim.schedule(function()
        on_done("connect error: " .. err)
      end)
      return
    end

    tcp:read_start(function(read_err, data)
      if read_err then
        tcp:close()
        vim.schedule(function()
          on_done("read error: " .. read_err)
        end)
        return
      end

      if data then
        buf = buf .. data

        -- Skip HTTP headers on first pass
        if not header_done then
          local hdr_end = buf:find("\r\n\r\n", 1, true)
          if hdr_end then
            buf = buf:sub(hdr_end + 4)
            header_done = true
          else
            return
          end
        end

        -- Process complete SSE events (separated by blank line \n\n)
        while true do
          local event_end = buf:find("\n\n", 1, true)
          if not event_end then break end

          local event_block = buf:sub(1, event_end - 1)
          buf = buf:sub(event_end + 2)

          -- Extract data: lines
          for line in event_block:gmatch("[^\n]+") do
            local payload_str = line:match("^data: (.+)$")
            if payload_str then
              local ok, event = pcall(vim.fn.json_decode, payload_str)
              if ok and type(event) == "table" then
                vim.schedule(function()
                  on_chunk(event)
                end)
              end
            end
          end
        end
      else
        -- EOF
        tcp:close()
        vim.schedule(function()
          on_done(nil)
        end)
      end
    end)

    tcp:write(raw_req)
  end)
end

-- ─── Convenience wrappers ────────────────────────────────────────────────────

function M.get(path, cb)         M.request("GET",    path, nil, cb) end
function M.post(path, body, cb)  M.request("POST",   path, body, cb) end
function M.delete(path, cb)      M.request("DELETE", path, nil, cb) end
function M.put(path, body, cb)   M.request("PUT",    path, body, cb) end

--- Check if dcode serve is reachable.
---@param cb fun(alive: boolean)
function M.ping(cb)
  M.get("/health", function(ok, _)
    cb(ok)
  end)
end

return M
