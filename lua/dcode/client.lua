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

--- Decode HTTP chunked transfer encoding.
--- Strips the hex-size\r\n ... \r\n wrappers, returns plain body bytes.
---@param s string
---@return string
local function decode_chunked(s)
  local out = {}
  local pos = 1
  while pos <= #s do
    -- Find the chunk-size line ending
    local nl = s:find("\r\n", pos, true)
    if not nl then break end
    local size_str = s:sub(pos, nl - 1)
    -- Strip any chunk extensions (;...)
    size_str = size_str:match("^([0-9a-fA-F]+)")
    if not size_str then break end
    local size = tonumber(size_str, 16)
    if not size or size == 0 then break end  -- last chunk
    local data_start = nl + 2
    local data_end   = data_start + size - 1
    if data_end > #s then break end  -- incomplete — shouldn't happen with our buffering
    table.insert(out, s:sub(data_start, data_end))
    pos = data_end + 3  -- skip trailing \r\n after chunk data
  end
  return table.concat(out)
end

--- Streaming request — calls on_chunk for every SSE "data:" line, on_done at end.
--- NOTE: all parsing happens inside vim.schedule (main loop) to avoid E5560.
---@param path     string             e.g. "/session/abc123/prompt"
---@param payload  table              Request body
---@param on_chunk fun(event: table)  Called for each parsed SSE event
---@param on_done  fun(err: string|nil)
function M.stream(path, payload, on_chunk, on_done)
  local body = vim.fn.json_encode(payload)
  local raw_req = build_request("POST", path, body)
  raw_req = raw_req:gsub("Accept: application/json", "Accept: text/event-stream")

  local tcp = vim.loop.new_tcp()
  -- raw_pending: new bytes that arrived since the last vim.schedule fired
  local raw_pending  = {}
  local header_buf   = ""   -- accumulates bytes until HTTP headers are complete
  local header_done  = false
  local chunked      = false
  local sse_buf      = ""   -- unprocessed SSE text (remainder between events)

  tcp:connect(config.host, config.port, function(err)
    if err then
      vim.schedule(function() on_done("connect error: " .. err) end)
      return
    end

    tcp:read_start(function(read_err, data)
      if read_err then
        tcp:close()
        vim.schedule(function() on_done("read error: " .. read_err) end)
        return
      end

      if data then
        -- Stash the raw bytes; process on the main loop (avoids E5560).
        table.insert(raw_pending, data)

        vim.schedule(function()
          if #raw_pending == 0 then return end
          local new_data = table.concat(raw_pending)
          raw_pending = {}

          -- ── Strip HTTP headers (once) ──────────────────────────────────
          if not header_done then
            header_buf = header_buf .. new_data
            local hdr_end = header_buf:find("\r\n\r\n", 1, true)
            if not hdr_end then return end  -- headers not yet complete
            local headers = header_buf:sub(1, hdr_end - 1)
            chunked = headers:lower():find("transfer%-encoding:%s*chunked") ~= nil
            new_data = header_buf:sub(hdr_end + 4)  -- body bytes after headers
            header_buf = ""
            header_done = true
          end

          -- ── Strip chunked framing from new_data only ───────────────────
          local plain = chunked and decode_chunked(new_data) or new_data
          sse_buf = sse_buf .. plain

          -- ── Dispatch complete SSE events (\n\n separated) ─────────────
          while true do
            local event_end = sse_buf:find("\n\n", 1, true)
            if not event_end then break end
            local block = sse_buf:sub(1, event_end - 1)
            sse_buf = sse_buf:sub(event_end + 2)

            for line in block:gmatch("[^\n]+") do
              local payload_str = line:match("^data:%s*(.+)$")
              if payload_str then
                local ok, event = pcall(vim.fn.json_decode, payload_str)
                if ok and type(event) == "table" then
                  on_chunk(event)
                end
              end
            end
          end
        end)

      else
        -- EOF
        tcp:close()
        vim.schedule(function() on_done(nil) end)
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
