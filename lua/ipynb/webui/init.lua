local M = {}

local App = require('ipynb.webui.server.app')
local sync_mod = require('ipynb.webui.sync')

-- Setup autocommands to keep the browser in sync with the current buffer
local function set_autocmds()
  local group = vim.api.nvim_create_augroup('IpynbWebUI', { clear = true })
  local pattern = '*.ipynb'

  vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI' }, {
    group = group,
    pattern = pattern,
    callback = function()
      sync_mod.sync_cursor()
    end,
  })

  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
    group = group,
    pattern = pattern,
    callback = function()
      sync_mod.sync_notebook()
    end,
  })
end

function M.start(port)
  local state = require('ipynb.state').get()
  if not state then
    vim.notify('No notebook loaded', vim.log.levels.ERROR)
    return
  end

  set_autocmds()

  if M.app then
    M.stop()
  end

  port = port or 8080
  local plugin_dir = vim.fn.fnamemodify(debug.getinfo(1).source:sub(2), ':h')
  M.app = App.create_app({
    port = port,
    static_dir = plugin_dir .. '/client',
  })
  M.app:start()

  vim.ui.open('http://127.0.0.1:' .. port)
end

function M.stop()
  if M.app then
    M.app:stop()
    M.app = nil
  end
  vim.api.nvim_del_augroup_by_name('IpynbWebUI', { force = true })
end

function M.is_running()
  return M.app ~= nil
end

function M.broadcast(json)
  if M.app then
    M.app:broadcast(json)
  end
end

return M
