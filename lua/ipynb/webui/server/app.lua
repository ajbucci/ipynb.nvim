local uv = vim.uv
local M = {}
local http = require('ipynb.webui.server.http')

-- Heartbeat interval for SSE keep-alive
local PING_INTERVAL_MS = 15000

local App = {}
App.__index = App

function M.create_app(opts)
  local obj = {
    port = opts.port,
    static_dir = opts.static_dir,
    server = nil,
    clients = {},
    ping_timer = nil,
  }
  setmetatable(obj, App)
  return obj
end

function App:start()
  self.server = uv.new_tcp()
  self.server:bind('127.0.0.1', self.port)
  self.server:listen(128, function(err)
    if err then
      print('Server error: ' .. err)
      return
    end

    local client = uv.new_tcp()
    self.server:accept(client)

    local buffer = ''
    local stream_opened = false

    client:read_start(function(err, data)
      if err then
        self:close_client(client)
        return
      end

      if data then
        buffer = buffer .. data

        if stream_opened then
          return
        end

        -- Wait for the full request head before deciding how to respond
        local is_complete = buffer:find('\r\n\r\n', 1, true)
        if not is_complete then
          return
        end

        local method, path = buffer:match('^(%w+)%s+([^%s?]+)')
        if method == 'GET' and path == http.SSE_PATH then
          local resp = http.create_sse_response()
          client:write(resp, function()
            self:add_client(client)
          end)
          stream_opened = true
          buffer = ''
          return
        end

        -- Static files: respond and close the connection
        local resp = http.handle_request(buffer, self.static_dir)
        client:read_stop()
        if resp then
          client:write(resp, function()
            client:close()
          end)
        else
          client:close()
        end
        buffer = ''
      else
        self:close_client(client)
      end
    end)
  end)

  self.ping_timer = uv.new_timer()
  self.ping_timer:start(PING_INTERVAL_MS, PING_INTERVAL_MS, function()
    self:broadcast_ping()
  end)

  print('Internal server started on http://127.0.0.1:' .. self.port)
end

function App:add_client(client)
  table.insert(self.clients, client)

  -- Send the initial snapshot to the newly connected client
  vim.schedule(function()
    local sync_mod = require('ipynb.webui.sync')
    sync_mod.sync_notebook()
    sync_mod.sync_cursor()
  end)
end

function App:close_client(client)
  client:read_stop()
  client:close()
  self:remove_client(client)
end

function App:remove_client(client)
  for i, c in ipairs(self.clients) do
    if c == client then
      table.remove(self.clients, i)
      break
    end
  end
end

function App:broadcast(data)
  -- vim.json.encode escapes newlines, so the payload is always a single "data:" line
  local event = 'data: ' .. data .. '\n\n'
  for _, client in ipairs(self.clients) do
    if not client:is_closing() then
      client:write(event)
    end
  end
end

-- SSE comment line is ignored by EventSource but keeps the connection alive
function App:broadcast_ping()
  local ping = ': ping\n\n'
  for _, client in ipairs(self.clients) do
    if not client:is_closing() then
      client:write(ping)
    end
  end
end

function App:stop()
  if self.ping_timer then
    self.ping_timer:stop()
    self.ping_timer:close()
    self.ping_timer = nil
  end
  if self.server then
    self.server:close()
  end
  for _, client in ipairs(self.clients) do
    client:read_stop()
    client:close()
  end
  self.clients = {}
end

return M
