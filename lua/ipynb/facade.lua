-- ipynb/facade.lua - Facade buffer rendering

local M = {}

---Set lines on facade buffer, suppressing LSP change tracking errors
---LSP change tracking fails because facade isn't registered with the shadow buffer's LSP clients
---@param buf number Facade buffer
---@param start_line number 0-indexed start line
---@param end_line number 0-indexed end line (exclusive)
---@param lines string[] New lines
local function set_facade_lines(buf, start_line, end_line, lines)
  local ok, err = pcall(vim.api.nvim_buf_set_lines, buf, start_line, end_line, false, lines)
  if not ok and err and not err:match('_changetracking') then
    error(err)
  end
end

---Create and configure the facade buffer
---@param state NotebookState
---@param buf number|nil Existing buffer to use, or nil to create new
---@return number buf
function M.create(state, buf)
  -- Use provided buffer or create new one
  buf = buf or vim.api.nvim_create_buf(true, false)
  state.facade_buf = buf

  -- Keep original .ipynb path for buffer name (set by :edit command)
  -- This ensures root detection, statusline, and other plugins work correctly
  state.facade_path = state.source_path

  -- Convert cells to jupytext format
  local io_mod = require('ipynb.io')
  local lines = io_mod.cells_to_jupytext(state.cells)

  -- Ensure buffer is modifiable before populating (might be reused)
  vim.bo[buf].modifiable = true

  -- Populate buffer with undo history cleared
  -- Setting undolevels=-1 before the change prevents it from being undoable
  local old_undolevels = vim.bo[buf].undolevels
  vim.bo[buf].undolevels = -1
  set_facade_lines(buf, 0, -1, lines)
  vim.bo[buf].undolevels = old_undolevels
  vim.bo[buf].modified = false

  -- Configure buffer options
  -- NOTE: filetype is NOT python - we don't want LSP to attach to facade
  -- LSP attaches to shadow buffer instead
  vim.bo[buf].filetype = 'ipynb' -- Custom filetype, no LSP
  vim.bo[buf].modifiable = false -- User can't directly edit
  -- Don't set readonly - it causes warnings on :w even with BufWriteCmd handler
  -- modifiable=false is sufficient to prevent edits
  vim.bo[buf].buftype = '' -- Normal buffer (not scratch)
  vim.bo[buf].swapfile = false

  -- Store state reference in buffer variable
  vim.b[buf].notebook_facade = true

  -- Set language for injection directive (read from notebook metadata)
  -- The custom directive #inject-notebook-language! reads this to determine code cell language
  local lang = 'python' -- default
  if state.metadata and state.metadata.language_info and state.metadata.language_info.name then
    lang = state.metadata.language_info.name
  end
  vim.b[buf].ipynb_language = lang

  -- Start treesitter highlighting for the notebook grammar
  -- This enables syntax highlighting via our custom parser and injection queries
  vim.treesitter.start(buf, 'ipynb')

  -- Create shadow buffer for LSP (also installs global LSP proxy)
  local lsp_mod = require('ipynb.lsp')
  lsp_mod.create_shadow(state)

  -- Setup window options when buffer is displayed
  vim.api.nvim_create_autocmd('BufWinEnter', {
    buffer = buf,
    callback = function()
      local win = vim.api.nvim_get_current_win()
      -- Enable concealment for rounded borders
      vim.wo[win].conceallevel = 2
      vim.wo[win].concealcursor = 'nc' -- Conceal in normal and command mode
      -- Ensure sign column is visible for diagnostics
      vim.wo[win].signcolumn = 'auto'
    end,
  })

  -- Cleanup orphaned nb:// preview buffers when returning to facade
  -- (e.g., after picker closes without selection)
  -- Uses WinEnter because BufWinEnter only fires for new windows, not when
  -- focus returns to an existing window after a floating picker closes
  vim.api.nvim_create_autocmd('WinEnter', {
    buffer = buf,
    callback = function()
      lsp_mod.cleanup_preview_buffers(state)
    end,
  })

  -- Setup cleanup autocmd
  vim.api.nvim_create_autocmd('BufUnload', {
    buffer = buf,
    callback = function()
      require('ipynb.state').remove(buf)
    end,
  })

  return buf
end

---Refresh the entire facade buffer from state
---@param state NotebookState
function M.refresh(state)
  local buf = state.facade_buf
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local io_mod = require('ipynb.io')
  local lines = io_mod.cells_to_jupytext(state.cells)

  vim.bo[buf].modifiable = true
  set_facade_lines(buf, 0, -1, lines)
  -- Only lock facade if not in edit buffer
  if not state.edit_state then
    vim.bo[buf].modifiable = false
  end

  -- Refresh shadow buffer for LSP
  local lsp_mod = require('ipynb.lsp')
  lsp_mod.refresh_shadow(state)

  -- Refresh markers and visuals
  local cells_mod = require('ipynb.cells')
  cells_mod.place_markers(state)

  local visuals = require('ipynb.visuals')
  visuals.render_all(state)

  -- Re-render outputs (includes recreating images)
  local output_mod = require('ipynb.output')
  output_mod.render_all(state)
end

---Insert a cell into the facade buffer and refresh
---@param state NotebookState
---@param after_idx number Insert after this cell (0 for beginning)
---@param cell_type "code" | "markdown" | "raw"
---@return number new_cell_idx
function M.insert_cell(state, after_idx, cell_type)
  local state_mod = require('ipynb.state')
  local new_idx = state_mod.insert_cell(state, after_idx, cell_type)
  M.refresh(state)
  return new_idx
end

---Delete a cell from the facade buffer and refresh
---@param state NotebookState
---@param cell_idx number
function M.delete_cell(state, cell_idx)
  local state_mod = require('ipynb.state')
  state_mod.delete_cell(state, cell_idx)
  M.refresh(state)
end

---Move a cell and refresh
---@param state NotebookState
---@param cell_idx number
---@param direction -1 | 1
---@return number|nil new_idx
function M.move_cell(state, cell_idx, direction)
  local state_mod = require('ipynb.state')
  local new_idx = state_mod.move_cell(state, cell_idx, direction)
  if new_idx then
    M.refresh(state)
  end
  return new_idx
end

---Set cell type explicitly and refresh
---@param state NotebookState
---@param cell_idx number
---@param cell_type "code" | "markdown" | "raw"
function M.set_cell_type(state, cell_idx, cell_type)
  local state_mod = require('ipynb.state')
  state_mod.set_cell_type(state, cell_idx, cell_type)
  M.refresh(state)
end

return M
