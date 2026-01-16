-- ipynb/keymaps.lua - Keymap setup (see ipynb.config for keymap configuration)

local M = {}

-- Cell register for cut/paste operations
local cell_register = nil

-- Offset from cell start line to first content line (skips header marker)
local CONTENT_LINE_OFFSET = 2

---Get the cell at the current cursor position
---@param state NotebookState
---@return number|nil cell_idx
---@return table|nil cell
local function get_cell_at_cursor(state)
  local cells_mod = require('ipynb.cells')
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1] - 1
  return cells_mod.get_cell_at_line(state, cursor_line)
end

---Move cursor to the content area of a cell
---@param state NotebookState
---@param cell_idx number
local function move_cursor_to_cell(state, cell_idx)
  local cells_mod = require('ipynb.cells')
  local start_line = cells_mod.get_cell_range(state, cell_idx)
  vim.api.nvim_win_set_cursor(0, { start_line + CONTENT_LINE_OFFSET, 0 })
end

---Register keymaps with which-key for discoverability (if available)
local function register_which_key()
  local wk_ok, wk = pcall(require, 'which-key')
  if not wk_ok then
    return
  end

  local config = require('ipynb.config').get()
  local km = config.keymaps

  -- Register with consistent naming (Category + action) for easy scanning
  wk.add({
    { "<leader>k", group = "notebook", icon = "󰠮" },
    -- Cell operations
    { km.add_cell_above, desc = "Cell add above", icon = "󰐕" },
    { km.add_cell_below, desc = "Cell add below", icon = "󰐕" },
    { km.make_code, desc = "Cell type: code", icon = "" },
    { km.make_markdown, desc = "Cell type: markdown", icon = "󰽛" },
    { km.make_raw, desc = "Cell type: raw", icon = "󰦨" },
    { km.cell_variables, desc = "Inspect cell", icon = "󰀫" },
    -- Execute
    { km.menu_execute_cell, desc = "Execute cell", icon = "󰐊" },
    { km.menu_execute_and_next, desc = "Execute + next", icon = "󰐊" },
    -- Kernel
    { km.kernel_info, desc = "Kernel info", icon = "󰋼" },
    { km.kernel_interrupt, desc = "Kernel interrupt", icon = "󰜺" },
    { km.kernel_restart, desc = "Kernel restart", icon = "󰜉" },
    { km.kernel_shutdown, desc = "Kernel shutdown", icon = "⏻" },
    { km.kernel_start, desc = "Kernel start", icon = "⏻" },
    -- Output
    { km.clear_output, desc = "Output clear", icon = "󰁮" },
    { km.clear_all_outputs, desc = "Output clear all", icon = "󰁮" },
    { km.open_output, desc = "Output open", icon = "󰍉" },
    -- Inspector
    {
      km.toggle_auto_hover,
      desc = function()
        local enabled = require('ipynb.inspector').is_auto_hover_enabled()
        return enabled and "Inspect auto-hover (on)" or "Inspect auto-hover (off)"
      end,
      icon = function()
        local enabled = require('ipynb.inspector').is_auto_hover_enabled()
        return enabled and { icon = "󰔡", color = "green" } or { icon = "󰨙", color = "grey" }
      end,
    },
    { km.variable_inspect, desc = "Inspect variable", icon = "󰀫" },
    -- Folding
    { km.fold_toggle, desc = "Fold toggle cell", icon = "󰡍" },
    -- Picker
    { km.jump_to_cell, desc = "Jump to cell", icon = "󰆿" },
  })
end

---Helper to set a keymap only if the key is configured (non-nil, non-empty)
---@param mode string|string[]
---@param key string|nil
---@param callback function
---@param opts table
local function set_keymap_if_configured(mode, key, callback, opts)
  if key and key ~= '' then
    vim.keymap.set(mode, key, callback, opts)
  end
end

---Setup keymaps for facade buffer (normal mode navigation)
---@param state NotebookState
function M.setup_facade_keymaps(state)
  local buf = state.facade_buf
  local opts = { buffer = buf, silent = true }
  local config = require('ipynb.config').get()
  local km = config.keymaps

  -- Shared callbacks to avoid duplication
  local execute_cell_cb = function() M.execute_cell(state) end
  local execute_and_next_cb = function() M.execute_and_next(state) end
  local interrupt_kernel_cb = function() M.interrupt_kernel(state) end

  -- Cell navigation
  vim.keymap.set('n', km.next_cell, function()
    require('ipynb.cells').goto_next_cell(state)
  end, vim.tbl_extend('force', opts, { desc = 'Next cell' }))

  vim.keymap.set('n', km.prev_cell, function()
    require('ipynb.cells').goto_prev_cell(state)
  end, vim.tbl_extend('force', opts, { desc = 'Previous cell' }))

  -- Enter edit mode - hardcoded keys (these are blocked by modifiable=false anyway)
  vim.keymap.set('n', '<CR>', function()
    require('ipynb.edit').open(state)
  end, vim.tbl_extend('force', opts, { desc = 'Edit cell (normal mode)' }))

  vim.keymap.set('n', 'i', function()
    require('ipynb.edit').open(state, 'i')
  end, vim.tbl_extend('force', opts, { desc = 'Edit cell (insert)' }))

  vim.keymap.set('n', 'I', function()
    require('ipynb.edit').open(state, 'I')
  end, vim.tbl_extend('force', opts, { desc = 'Edit cell (insert at line start)' }))

  vim.keymap.set('n', 'a', function()
    require('ipynb.edit').open(state, 'a')
  end, vim.tbl_extend('force', opts, { desc = 'Edit cell (append)' }))

  vim.keymap.set('n', 'A', function()
    require('ipynb.edit').open(state, 'A')
  end, vim.tbl_extend('force', opts, { desc = 'Edit cell (append at line end)' }))

  vim.keymap.set('n', 'o', function()
    require('ipynb.edit').open(state, 'o')
  end, vim.tbl_extend('force', opts, { desc = 'Edit cell (open line below)' }))

  vim.keymap.set('n', 'O', function()
    require('ipynb.edit').open(state, 'O')
  end, vim.tbl_extend('force', opts, { desc = 'Edit cell (open line above)' }))

  -- Cell cut/paste
  vim.keymap.set('n', km.cut_cell, function()
    M.cut_cell(state)
  end, vim.tbl_extend('force', opts, { desc = 'Cell cut' }))

  vim.keymap.set('n', km.paste_cell_below, function()
    M.paste_cell(state, 'below')
  end, vim.tbl_extend('force', opts, { desc = 'Cell paste below' }))

  vim.keymap.set('n', km.paste_cell_above, function()
    M.paste_cell(state, 'above')
  end, vim.tbl_extend('force', opts, { desc = 'Cell paste above' }))

  -- Cell movement
  vim.keymap.set('n', km.move_cell_down, function()
    M.move_cell(state, 1)
  end, vim.tbl_extend('force', opts, { desc = 'Cell move down' }))

  vim.keymap.set('n', km.move_cell_up, function()
    M.move_cell(state, -1)
  end, vim.tbl_extend('force', opts, { desc = 'Cell move up' }))

  -- Execution (direct keys) - use shared callbacks
  vim.keymap.set('n', km.execute_cell, execute_cell_cb,
    vim.tbl_extend('force', opts, { desc = 'Execute cell' }))

  vim.keymap.set('n', km.execute_and_next, execute_and_next_cb,
    vim.tbl_extend('force', opts, { desc = 'Execute + next' }))

  vim.keymap.set('n', km.execute_and_insert, function()
    M.execute_and_insert(state)
  end, vim.tbl_extend('force', opts, { desc = 'Execute + insert below' }))

  vim.keymap.set('n', km.interrupt_kernel, interrupt_kernel_cb,
    vim.tbl_extend('force', opts, { desc = 'Kernel interrupt' }))

  -- <leader>k menu - notebook operations
  vim.keymap.set('n', km.add_cell_above, function()
    M.add_cell_above(state)
  end, vim.tbl_extend('force', opts, { desc = 'Cell add above' }))

  vim.keymap.set('n', km.add_cell_below, function()
    M.add_cell_below(state)
  end, vim.tbl_extend('force', opts, { desc = 'Cell add below' }))

  vim.keymap.set('n', km.make_markdown, function()
    M.set_cell_type(state, 'markdown')
  end, vim.tbl_extend('force', opts, { desc = 'Cell type: markdown' }))

  vim.keymap.set('n', km.make_code, function()
    M.set_cell_type(state, 'code')
  end, vim.tbl_extend('force', opts, { desc = 'Cell type: code' }))

  vim.keymap.set('n', km.make_raw, function()
    M.set_cell_type(state, 'raw')
  end, vim.tbl_extend('force', opts, { desc = 'Cell type: raw' }))

  vim.keymap.set('n', km.open_output, function()
    require('ipynb.output').open_output_float(state)
  end, vim.tbl_extend('force', opts, { desc = 'Output open' }))

  vim.keymap.set('n', km.clear_output, function()
    M.clear_output(state)
  end, vim.tbl_extend('force', opts, { desc = 'Output clear' }))

  vim.keymap.set('n', km.clear_all_outputs, function()
    M.clear_all_outputs(state)
  end, vim.tbl_extend('force', opts, { desc = 'Output clear all' }))

  -- Menu execute keys - use shared callbacks
  vim.keymap.set('n', km.menu_execute_cell, execute_cell_cb,
    vim.tbl_extend('force', opts, { desc = 'Execute cell' }))

  vim.keymap.set('n', km.menu_execute_and_next, execute_and_next_cb,
    vim.tbl_extend('force', opts, { desc = 'Execute + next' }))

  -- Execute all below (only if configured)
  set_keymap_if_configured('n', km.execute_all_below, function()
    M.execute_all_below(state)
  end, vim.tbl_extend('force', opts, { desc = 'Execute all below' }))

  vim.keymap.set('n', km.kernel_interrupt, interrupt_kernel_cb,
    vim.tbl_extend('force', opts, { desc = 'Kernel interrupt' }))

  vim.keymap.set('n', km.kernel_restart, function()
    M.restart_kernel(state)
  end, vim.tbl_extend('force', opts, { desc = 'Kernel restart' }))

  vim.keymap.set('n', km.kernel_start, function()
    M.start_kernel(state)
  end, vim.tbl_extend('force', opts, { desc = 'Kernel start' }))

  vim.keymap.set('n', km.kernel_shutdown, function()
    M.shutdown_kernel(state)
  end, vim.tbl_extend('force', opts, { desc = 'Kernel shutdown' }))

  vim.keymap.set('n', km.kernel_info, function()
    M.kernel_info(state)
  end, vim.tbl_extend('force', opts, { desc = 'Kernel info' }))

  -- Global undo/redo (operates on facade buffer)
  vim.keymap.set('n', 'u', function()
    require('ipynb.edit').global_undo(state)
  end, vim.tbl_extend('force', opts, { desc = 'Global undo' }))

  vim.keymap.set('n', '<C-r>', function()
    require('ipynb.edit').global_redo(state)
  end, vim.tbl_extend('force', opts, { desc = 'Global redo' }))

  -- Inspector
  vim.keymap.set('n', km.variable_inspect, function()
    require('ipynb.inspector').show_variable_at_cursor(state)
  end, vim.tbl_extend('force', opts, { desc = 'Inspect variable' }))

  vim.keymap.set('n', km.cell_variables, function()
    require('ipynb.inspector').show_cell_variables(state)
  end, vim.tbl_extend('force', opts, { desc = 'Inspect cell' }))

  vim.keymap.set('n', km.toggle_auto_hover, function()
    require('ipynb.inspector').toggle_auto_hover()
  end, vim.tbl_extend('force', opts, { desc = 'Inspect auto-hover toggle' }))

  -- Setup auto-hover on CursorHold for inspector
  require('ipynb.inspector').setup_auto_hover(state, buf)

  -- Cell folding
  vim.keymap.set('n', km.fold_toggle, function()
    require('ipynb.folding').toggle_cell_fold(state)
  end, vim.tbl_extend('force', opts, { desc = 'Fold toggle cell' }))

  -- Picker
  vim.keymap.set('n', km.jump_to_cell, function()
    require('ipynb.picker').jump_to_cell()
  end, vim.tbl_extend('force', opts, { desc = 'Jump to cell' }))

  -- LSP works transparently via API-level interception in lsp.lua
  -- Formatting: vim.lsp.buf.format() is wrapped to work with notebooks (see lsp.lua)
  -- User's existing LSP keymaps (gd, gr, K, etc.) work automatically

  -- Catch any insert mode attempts (modifiable=false handles the rest)
  vim.api.nvim_create_autocmd('InsertEnter', {
    buffer = buf,
    callback = function()
      vim.cmd('stopinsert')
      vim.notify('Press i, a, o, or <CR> to edit cell', vim.log.levels.INFO)
    end,
    desc = 'Prevent insert mode in notebook facade',
  })

  -- Register with which-key for discoverability (if available)
  register_which_key()
end

---Cut current cell to register
---@param state NotebookState
function M.cut_cell(state)
  if #state.cells <= 1 then
    vim.notify('Cannot cut the only cell', vim.log.levels.WARN)
    return
  end

  local cells_mod = require('ipynb.cells')
  local facade_mod = require('ipynb.facade')

  local cell_idx, cell = get_cell_at_cursor(state)

  if cell_idx and cell then
    -- Save to register (deep copy)
    cell_register = {
      type = cell.type,
      source = cell.source,
      outputs = cell.outputs and vim.deepcopy(cell.outputs) or nil,
      execution_count = cell.execution_count,
    }

    facade_mod.delete_cell(state, cell_idx)

    -- Move cursor to next cell (or previous if at end)
    local target_idx = math.min(cell_idx, #state.cells)
    move_cursor_to_cell(state, target_idx)

    vim.notify('Cell cut', vim.log.levels.INFO)
  end
end

---Paste cell from register
---@param state NotebookState
---@param position "above" | "below"
function M.paste_cell(state, position)
  if not cell_register then
    vim.notify('No cell in register', vim.log.levels.WARN)
    return
  end

  local facade_mod = require('ipynb.facade')

  local cell_idx = get_cell_at_cursor(state) or #state.cells

  local insert_after = position == 'below' and cell_idx or cell_idx - 1
  local new_idx = facade_mod.insert_cell(state, insert_after, cell_register.type)

  -- Copy content from register
  local new_cell = state.cells[new_idx]
  new_cell.source = cell_register.source
  if cell_register.outputs then
    new_cell.outputs = vim.deepcopy(cell_register.outputs)
  end

  -- Refresh to show pasted content
  facade_mod.refresh(state)

  -- Move cursor to pasted cell
  move_cursor_to_cell(state, new_idx)
end

---Add a new cell above current
---@param state NotebookState
function M.add_cell_above(state)
  local facade_mod = require('ipynb.facade')

  local cell_idx = get_cell_at_cursor(state) or 1

  local new_idx = facade_mod.insert_cell(state, cell_idx - 1, 'code')

  -- Move cursor to new cell and enter edit mode
  move_cursor_to_cell(state, new_idx)

  vim.schedule(function()
    require('ipynb.edit').open(state)
  end)
end

---Add a new cell below current
---@param state NotebookState
function M.add_cell_below(state)
  local facade_mod = require('ipynb.facade')

  local cell_idx = get_cell_at_cursor(state) or #state.cells

  local new_idx = facade_mod.insert_cell(state, cell_idx, 'code')

  -- Move cursor to new cell and enter edit mode
  move_cursor_to_cell(state, new_idx)

  vim.schedule(function()
    require('ipynb.edit').open(state)
  end)
end

---Set cell type
---@param state NotebookState
---@param cell_type "code" | "markdown" | "raw"
function M.set_cell_type(state, cell_type)
  local facade_mod = require('ipynb.facade')

  local cell_idx = get_cell_at_cursor(state)

  if cell_idx then
    facade_mod.set_cell_type(state, cell_idx, cell_type)
  end
end

---Move cell in a direction
---@param state NotebookState
---@param direction number 1 for down, -1 for up
function M.move_cell(state, direction)
  local facade_mod = require('ipynb.facade')

  local cell_idx = get_cell_at_cursor(state)

  if cell_idx then
    local new_idx = facade_mod.move_cell(state, cell_idx, direction)
    if new_idx then
      move_cursor_to_cell(state, new_idx)
    end
  end
end

---Execute current cell (stay in place)
---@param state NotebookState
function M.execute_cell(state)
  local kernel = require('ipynb.kernel')

  local cell_idx, cell = get_cell_at_cursor(state)

  if cell and cell.type == 'code' then
    kernel.execute(state, cell_idx)
  end
end

---Execute current cell and move to next
---@param state NotebookState
function M.execute_and_next(state)
  local cells_mod = require('ipynb.cells')
  local kernel = require('ipynb.kernel')

  local cell_idx, cell = get_cell_at_cursor(state)

  if cell and cell.type == 'code' then
    kernel.execute(state, cell_idx)
    -- Only move to next cell if we executed (and not at end)
    if cell_idx < #state.cells then
      cells_mod.goto_next_cell(state)
    end
  end
end

---Execute current cell and insert new cell below
---@param state NotebookState
function M.execute_and_insert(state)
  local kernel = require('ipynb.kernel')

  local cell_idx, cell = get_cell_at_cursor(state)

  if cell and cell.type == 'code' then
    kernel.execute(state, cell_idx)
  end

  -- Insert new cell below and edit
  M.add_cell_below(state)
end

---Execute all cells from current to end
---@param state NotebookState
function M.execute_all_below(state)
  local kernel = require('ipynb.kernel')
  kernel.execute_all_below(state)
end

---Interrupt kernel
---@param state NotebookState
function M.interrupt_kernel(state)
  local kernel = require('ipynb.kernel')
  kernel.interrupt(state)
end

---Restart kernel
---@param state NotebookState
function M.restart_kernel(state)
  local kernel = require('ipynb.kernel')
  kernel.restart(state, true) -- Clear outputs on restart
end

---Start kernel
---@param state NotebookState
function M.start_kernel(state)
  local kernel = require('ipynb.kernel')
  kernel.connect(state, {})
end

---Shutdown kernel
---@param state NotebookState
function M.shutdown_kernel(state)
  local kernel = require('ipynb.kernel')
  kernel.shutdown(state)
end

---Show kernel info
---@param state NotebookState
function M.kernel_info(state)
  local kernel = require('ipynb.kernel')
  local info = kernel.get_info(state)

  local lines = {
    'Kernel Info:',
    '  Kernelspec: ' .. info.kernelspec,
    '  Python: ' .. (info.python_path or 'not found') .. ' (' .. info.python_source .. ')',
    '  Connected: ' .. tostring(info.connected),
    '  State: ' .. info.execution_state,
  }

  if info.running_kernel then
    table.insert(lines, '  Running kernel: ' .. info.running_kernel)
  end

  vim.notify(table.concat(lines, '\n'), vim.log.levels.INFO)
end

---Clear output for current cell
---@param state NotebookState
function M.clear_output(state)
  local output_mod = require('ipynb.output')

  local cell_idx = get_cell_at_cursor(state)

  if cell_idx then
    output_mod.clear_outputs(state, cell_idx)
  end
end

---Clear all outputs
---@param state NotebookState
function M.clear_all_outputs(state)
  local output_mod = require('ipynb.output')
  output_mod.clear_all_outputs(state)

  -- Clear execution counts
  for _, cell in ipairs(state.cells) do
    cell.execution_count = nil
  end

  -- Re-render visuals
  local visuals = require('ipynb.visuals')
  visuals.render_all(state)
end

return M
