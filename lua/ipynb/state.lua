-- ipynb/state.lua - Notebook state management

local M = {}

---@class Output
---@field output_type "stream" | "execute_result" | "error" | "display_data"
---@field text string|nil For stream output
---@field data table|nil For execute_result/display_data
---@field ename string|nil For error
---@field evalue string|nil For error
---@field traceback string[]|nil For error

---@class Cell
---@field id string Unique cell identifier
---@field type "code" | "markdown" | "raw"
---@field source string Cell content
---@field outputs Output[]|nil
---@field metadata table
---@field execution_count number|nil
---@field execution_state string|nil Current execution state: "idle", "busy", "queued"
---@field namespace_state table|nil Kernel namespace state for variable tracking
---@field extmark_id number|nil Tracks cell start line
---@field bg_extmark number|nil Background highlight extmark
---@field sign_extmark number|nil Sign column extmark
---@field border_extmark number|nil Border virtual line extmark
---@field top_border_extmark number|nil Top border underline extmark
---@field output_extmark number|nil Output virtual lines extmark
---@field edit_buf number|nil Persistent edit buffer for this cell

---@class EditState
---@field buf number Float buffer
---@field win number Float window
---@field parent_win number Parent window (facade window)
---@field cell_idx number Which cell is being edited
---@field cell_id string Cell ID for stability across undo
---@field start_line number Cell content start in facade (after cell marker)
---@field end_line number Cell content end in facade
---@field last_changedtick number|nil Track changedtick to detect spurious events
---@field insert_synced boolean|nil Whether insert mode changes have been synced

---@class NotebookState
---@field cells Cell[]
---@field facade_buf number
---@field facade_win number|nil
---@field facade_path string Original .ipynb file path (same as source_path)
---@field shadow_buf number|nil Hidden buffer for LSP (code cells only)
---@field shadow_path string|nil Temp .py file path for shadow buffer
---@field source_path string Original .ipynb path
---@field namespace number Extmark namespace
---@field edit_state EditState|nil
---@field kernel table|nil Kernel connection
---@field metadata table Notebook-level metadata
---@field images table|nil Image objects indexed by cell.id (string)
---@field skip_sync boolean|nil Temporarily skip sync during undo/redo

-- Store all notebook states, keyed by facade buffer
---@type table<number, NotebookState>
M.notebooks = {}

-- Counter for generating unique cell IDs
local cell_id_counter = 0

---Generate a unique cell ID
---@return string
function M.generate_cell_id()
  cell_id_counter = cell_id_counter + 1
  return string.format('cell_%d_%d', vim.loop.now(), cell_id_counter)
end

---Create a new notebook state
---@param source_path string Path to .ipynb file
---@return NotebookState
function M.create(source_path)
  local state = {
    cells = {},
    facade_buf = -1,
    facade_win = nil,
    facade_path = '',
    shadow_buf = nil,
    shadow_path = nil,
    source_path = source_path,
    namespace = vim.api.nvim_create_namespace('notebook_' .. source_path),
    edit_state = nil,
    kernel = nil,
    metadata = {},
    images = {},
  }
  return state
end

---Register a notebook state
---@param state NotebookState
function M.register(state)
  M.notebooks[state.facade_buf] = state
end

---Get notebook state for a buffer
---@param buf number|nil Buffer number (defaults to current)
---@return NotebookState|nil
function M.get(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  return M.notebooks[buf]
end

---Get notebook state by facade buffer (alias for get, used by LSP proxy)
---@param buf number Facade buffer number
---@return NotebookState|nil
function M.get_by_facade(buf)
  return M.notebooks[buf]
end

---Get notebook state by shadow buffer
---@param shadow_buf number Shadow buffer number
---@return NotebookState|nil
function M.get_by_shadow(shadow_buf)
  for _, state in pairs(M.notebooks) do
    if state.shadow_buf == shadow_buf then
      return state
    end
  end
  return nil
end

---Get notebook state from edit buffer
---@param edit_buf number Edit float buffer
---@return NotebookState|nil
function M.get_from_edit_buf(edit_buf)
  for _, state in pairs(M.notebooks) do
    if state.edit_state and state.edit_state.buf == edit_buf then
      return state
    end
  end
  return nil
end

---Get notebook state by any associated path (facade, shadow, or source)
---@param path string File path to check
---@return NotebookState|nil
function M.get_by_path(path)
  local normalized = vim.fn.fnamemodify(path, ':p')
  for _, state in pairs(M.notebooks) do
    -- Check facade/source path
    if state.facade_path then
      local facade_norm = vim.fn.fnamemodify(state.facade_path, ':p')
      if facade_norm == normalized then
        return state
      end
    end
    -- Check shadow path
    if state.shadow_path and state.shadow_path == path then
      return state
    end
  end
  return nil
end

---Remove notebook state
---@param buf number Facade buffer number
function M.remove(buf)
  local state = M.notebooks[buf]
  if state then
    -- Cleanup images
    local ok, images_mod = pcall(require, 'ipynb.images')
    if ok then
      images_mod.clear_all_images(state)
    end

    -- Cleanup fold cache
    local fold_ok, folding_mod = pcall(require, 'ipynb.folding')
    if fold_ok then
      folding_mod.clear_cache(buf)
    end

    -- Cleanup shadow buffer and temp file
    if state.shadow_buf and vim.api.nvim_buf_is_valid(state.shadow_buf) then
      vim.api.nvim_buf_delete(state.shadow_buf, { force = true })
    end
    if state.shadow_path and vim.fn.filereadable(state.shadow_path) == 1 then
      vim.fn.delete(state.shadow_path)
    end
    M.notebooks[buf] = nil
  end
end

---Insert a new cell
---@param state NotebookState
---@param after_idx number Insert after this cell (0 for beginning)
---@param cell_type "code" | "markdown" | "raw"
---@return number new_cell_idx
function M.insert_cell(state, after_idx, cell_type)
  local new_cell = {
    id = M.generate_cell_id(),
    type = cell_type,
    source = '',
    outputs = {},
    metadata = {},
    execution_count = nil,
  }
  table.insert(state.cells, after_idx + 1, new_cell)
  return after_idx + 1
end

---Delete a cell
---@param state NotebookState
---@param cell_idx number
function M.delete_cell(state, cell_idx)
  if #state.cells > 1 then
    -- Clear images for this specific cell (keyed by cell.id)
    local cell = state.cells[cell_idx]
    if cell and cell.id then
      local ok, images_mod = pcall(require, 'ipynb.images')
      if ok then
        images_mod.clear_images(state, cell.id)
      end
    end
    table.remove(state.cells, cell_idx)
  end
end

---Move a cell up or down
---@param state NotebookState
---@param cell_idx number
---@param direction -1 | 1 (-1 = up, 1 = down)
---@return number|nil new_idx
function M.move_cell(state, cell_idx, direction)
  local new_idx = cell_idx + direction
  if new_idx < 1 or new_idx > #state.cells then
    return nil
  end

  -- Images are keyed by cell.id, so no need to clear - just sync positions after
  local cell = state.cells[cell_idx]
  table.remove(state.cells, cell_idx)
  table.insert(state.cells, new_idx, cell)
  return new_idx
end

---Toggle cell type between code and markdown
---@param state NotebookState
---@param cell_idx number
function M.toggle_cell_type(state, cell_idx)
  local cell = state.cells[cell_idx]
  if cell then
    if cell.type == 'code' then
      cell.type = 'markdown'
      cell.outputs = nil
      cell.execution_count = nil
    else
      cell.type = 'code'
      cell.outputs = {}
    end
  end
end

---Set cell type explicitly
---@param state NotebookState
---@param cell_idx number
---@param cell_type "code" | "markdown" | "raw"
function M.set_cell_type(state, cell_idx, cell_type)
  local cell = state.cells[cell_idx]
  if cell then
    if cell.type == cell_type then
      return -- no change
    end
    cell.type = cell_type
    if cell_type == 'code' then
      cell.outputs = cell.outputs or {}
    else
      cell.outputs = nil
      cell.execution_count = nil
    end
  end
end

return M
