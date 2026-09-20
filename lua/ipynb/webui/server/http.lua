local uv = vim.uv
local M = {}

M.SSE_PATH = '/events'

local status_text = {
  [200] = 'OK',
  [404] = 'Not Found',
  [405] = 'Method Not Allowed',
}

function M.create_response(status, content_type, body)
  return table.concat({
    'HTTP/1.1 ' .. status .. ' ' .. status_text[status],
    'Content-Type: ' .. content_type,
    'Content-Length: ' .. #body,
    'Connection: close',
    '',
    body,
  }, '\r\n')
end

function M.create_sse_response()
  return table.concat({
    'HTTP/1.1 200 OK',
    'Content-Type: text/event-stream',
    'Cache-Control: no-cache',
    'Connection: keep-alive',
    '',
    '',
  }, '\r\n')
end

local mime_types = {
  html = 'text/html',
  js = 'application/javascript',
  css = 'text/css',
}

function M.handle_request(data, static_dir)
  local method, path = data:match('^(%w+)%s+([^%s?]+)')
  if not method or not path then
    return nil
  end
  if method ~= 'GET' then
    return M.create_response(405, 'text/plain', 'Method Not Allowed')
  end

  -- The SSE endpoint is handled separately by the app; never serve it as a file
  if path == M.SSE_PATH then
    return nil
  end

  for seg in path:gmatch('/([^/]+)') do
    if seg == '..' then
      return M.create_response(404, 'text/plain', 'Not Found')
    end
  end

  local file_path = path == '/' and '/index.html' or path

  local full_path = static_dir .. file_path
  local fd = uv.fs_open(full_path, 'r', 438)
  if not fd then
    return M.create_response(404, 'text/plain', 'Not Found')
  end

  local stat = uv.fs_fstat(fd)
  local body = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)

  local ext = file_path:match('%.([^.]+)$')
  local content_type = mime_types[ext] or 'text/plain'

  return M.create_response(200, content_type, body)
end

return M
