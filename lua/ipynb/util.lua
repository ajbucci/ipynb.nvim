-- ipynb/util.lua - Shared utility functions

local M = {}

---Get the plugin's root directory
---@return string
function M.get_plugin_root()
  local source = debug.getinfo(1, 'S').source:sub(2)
  return vim.fn.fnamemodify(source, ':h:h:h')
end

return M
