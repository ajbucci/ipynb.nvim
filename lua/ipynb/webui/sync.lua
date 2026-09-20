local M = {}

local state_mod = require('ipynb.state')
local cells_mod = require('ipynb.cells')

--- @return table? state of the current buffer, or nil
local function current_state()
  return state_mod.get(vim.api.nvim_get_current_buf())
end

--- Send the whole notebook (cells + metadata) to the browser
function M.sync_notebook()
  local st = current_state()
  if not st or not require('ipynb.webui').is_running() then
    return
  end

  -- Convert cells from {type = 'code'|'markdown'} to the webUI's expected
  -- {cell_type = 'code'|'markdown'} format. Preserve all other fields.
  -- Shallow copy is enough: only top-level keys are rewritten, and
  -- json.encode reads (never mutates) the nested source/outputs.
  local cells = {}
  for _, cell in ipairs(st.cells) do
    local copy = vim.tbl_extend('keep', {}, cell)
    copy.cell_type = copy.type
    copy.type = nil
    table.insert(cells, copy)
  end

  -- Build kernel info if connected
  local kernel_info = nil
  if st.kernel and st.kernel.connected then
    local kernel = require('ipynb.kernel')
    kernel_info = {
      connected = true,
      python_path = kernel.get_python_info(st.source_path),
    }
  end

  local data = {
    type = 'notebook_loaded',
    filename = st.source_path,
    cells = cells,
    metadata = st.metadata,
    kernel = kernel_info,
  }

  -- Broadcast to connected SSE clients
  local webui = require('ipynb.webui')
  webui.broadcast(vim.json.encode(data))
end

--- Send the ID of the cell where the cursor currently resides
function M.sync_cursor()
  local st = current_state()
  if not st or not require('ipynb.webui').is_running() then
    return
  end
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1] - 1
  local idx = cells_mod.get_cell_at_line(st, cursor_line)
  local cell = idx and st.cells[idx] or nil
  if not cell or not cell.id then
    return
  end
  local payload = vim.json.encode({
    type = 'cursor_moved',
    cell_id = cell.id,
  })
  local webui = require('ipynb.webui')
  webui.broadcast(payload)
end

return M
