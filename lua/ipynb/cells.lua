-- ipynb/cells.lua - Cell boundary tracking using extmarks

local M = {}

---Count the number of lines in a cell's facade representation
---@param cell Cell
---@return number content_lines (not including markers)
function M.count_cell_lines(cell)
  if cell.source == '' then
    return 1 -- Empty cell has one empty line
  end
  local lines = 0
  for _ in (cell.source .. '\n'):gmatch('[^\n]*\n') do
    lines = lines + 1
  end
  return lines
end

---Get total lines a cell takes in facade (including markers)
---@param cell Cell
---@return number
function M.total_cell_lines(cell)
  -- start marker + content + end marker = 2 + content_lines
  return 2 + M.count_cell_lines(cell)
end

---Place extmarks at cell boundaries
---@param state NotebookState
function M.place_markers(state)
  local ns = state.namespace
  local buf = state.facade_buf

  -- Clear existing markers
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

  local line = 0

  for i, cell in ipairs(state.cells) do
    -- Place extmark at cell start marker line
    cell.extmark_id = vim.api.nvim_buf_set_extmark(buf, ns, line, 0, {
      right_gravity = false,
      invalidate = true,
      undo_restore = true,
    })

    -- Calculate next cell start:
    -- start marker (1) + content + end marker (1) + blank separator (1, except last)
    local cell_lines = M.total_cell_lines(cell)
    if i < #state.cells then
      cell_lines = cell_lines + 1 -- blank line separator
    end
    line = line + cell_lines
  end
end

---Get cell index at a specific line
---@param state NotebookState
---@param target_line number 0-indexed line number
---@return number|nil cell_idx, Cell|nil cell
function M.get_cell_at_line(state, target_line)
  local ns = state.namespace
  local buf = state.facade_buf

  -- Find the cell whose start is at or before target_line
  -- by searching backwards from target_line
  local marks = vim.api.nvim_buf_get_extmarks(
    buf,
    ns,
    { target_line, 0 },
    0, -- Search backwards to line 0
    { limit = 1 }
  )

  if #marks == 0 then
    return nil, nil
  end

  local mark_id = marks[1][1]

  for i, cell in ipairs(state.cells) do
    if cell.extmark_id == mark_id then
      return i, cell
    end
  end

  return nil, nil
end

---Get the full line range for a cell (0-indexed, inclusive)
---Includes start marker, content, and end marker
---@param state NotebookState
---@param cell_idx number
---@return number|nil start_line, number|nil end_line
function M.get_cell_range(state, cell_idx)
  local ns = state.namespace
  local buf = state.facade_buf
  local cell = state.cells[cell_idx]

  if not cell or not cell.extmark_id then
    return nil, nil
  end

  local pos = vim.api.nvim_buf_get_extmark_by_id(buf, ns, cell.extmark_id, {})
  local start_line = pos[1]

  -- Check if extmark was found
  if not start_line then
    return nil, nil
  end

  -- End line is start + total_cell_lines - 1 (for 0-indexing)
  local end_line = start_line + M.total_cell_lines(cell) - 1

  return start_line, end_line
end

---Get content line range (excluding start and end markers)
---@param state NotebookState
---@param cell_idx number
---@return number|nil content_start, number|nil content_end
function M.get_content_range(state, cell_idx)
  local start_line, end_line = M.get_cell_range(state, cell_idx)
  if not start_line or not end_line then
    return nil, nil
  end
  -- Content is between start marker (+1) and end marker (-1)
  return start_line + 1, end_line - 1
end

---Sync cells from facade buffer back to state
---@param state NotebookState
function M.sync_cells_from_facade(state)
  local buf = state.facade_buf
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local io_mod = require('ipynb.io')
  local state_mod = require('ipynb.state')
  local new_cells = io_mod.jupytext_to_cells(lines)

  -- Build lookup of old cells by source content for matching after undo
  -- This handles cases where cell order changes (move, undo of add/delete)
  local old_cells_by_source = {}
  for _, cell in ipairs(state.cells) do
    local key = cell.type .. ':' .. cell.source
    if not old_cells_by_source[key] then
      old_cells_by_source[key] = {}
    end
    table.insert(old_cells_by_source[key], cell)
  end

  -- Store execution data by cell ID so they persist even when content changes
  -- This is critical for undo - we want outputs to survive content changes
  local cell_data_by_id = {}
  for _, cell in ipairs(state.cells) do
    if cell.id and cell.type == 'code' then
      cell_data_by_id[cell.id] = {
        outputs = cell.outputs,
        execution_count = cell.execution_count,
        namespace_state = cell.namespace_state,
        execution_state = cell.execution_state,
      }
    end
  end

  -- Preserve id, metadata, outputs, edit buffers, and extmarks from matching old cells
  for i, new_cell in ipairs(new_cells) do
    local key = new_cell.type .. ':' .. new_cell.source
    local matches = old_cells_by_source[key]

    if matches and #matches > 0 then
      -- Take first matching cell (handles duplicate content by FIFO)
      local old_cell = table.remove(matches, 1)
      new_cell.id = old_cell.id  -- Preserve unique ID
      new_cell.metadata = old_cell.metadata
      new_cell.edit_buf = old_cell.edit_buf
      if new_cell.type == 'code' and old_cell.type == 'code' then
        new_cell.outputs = old_cell.outputs
        new_cell.execution_count = old_cell.execution_count
        new_cell.namespace_state = old_cell.namespace_state
        new_cell.execution_state = old_cell.execution_state
        new_cell.output_extmark = old_cell.output_extmark
      end
    else
      -- No content match - try to preserve identity by position
      -- This helps with undo when content changes
      local old_cell = state.cells[i]
      if old_cell and old_cell.id and old_cell.type == new_cell.type then
        -- Same position, same type - preserve identity
        new_cell.id = old_cell.id
        new_cell.edit_buf = old_cell.edit_buf
        new_cell.metadata = old_cell.metadata
        -- Preserve execution data if this is a code cell
        if new_cell.type == 'code' then
          local data = cell_data_by_id[old_cell.id]
          if data then
            new_cell.outputs = data.outputs
            new_cell.execution_count = data.execution_count
            new_cell.namespace_state = data.namespace_state
            new_cell.execution_state = data.execution_state
          end
          new_cell.output_extmark = old_cell.output_extmark
        end
      else
        -- New cell with no match - generate a new ID
        new_cell.id = state_mod.generate_cell_id()
      end
    end
  end

  state.cells = new_cells
end

---Update cell boundaries after facade buffer changes
---@param state NotebookState
function M.refresh_markers(state)
  -- Re-parse and re-place markers
  M.sync_cells_from_facade(state)
  M.place_markers(state)
end

---Navigate to a cell by direction
---@param state NotebookState
---@param direction number 1 for next, -1 for previous
---@return boolean success
local function goto_cell(state, direction)
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1] - 1 -- 0-indexed
  local current_idx = M.get_cell_at_line(state, cursor_line)
  local target_idx = current_idx and current_idx + direction

  if target_idx and target_idx >= 1 and target_idx <= #state.cells then
    local start_line = M.get_cell_range(state, target_idx)
    vim.api.nvim_win_set_cursor(0, { start_line + 2, 0 }) -- +2: 1-indexed + skip marker
    return true
  end
  return false
end

---Navigate to next cell
---@param state NotebookState
---@return boolean success
function M.goto_next_cell(state)
  return goto_cell(state, 1)
end

---Navigate to previous cell
---@param state NotebookState
---@return boolean success
function M.goto_prev_cell(state)
  return goto_cell(state, -1)
end

return M
