-- ipynb/commands.lua - User commands (see :help ipynb-commands)

local M = {}

local kernel = require('ipynb.kernel')

---Validate kernel exists in Jupyter and set it
---Warns if Jupyter can't be located or kernel doesn't exist
---@param state NotebookState
---@param kernel_name string
local function validate_and_set_kernel(state, kernel_name)
  kernel.list_kernels(state.source_path, function(kernels, err)
    if err then
      vim.notify(
        string.format("Warning: unable to validate kernel '%s': %s", kernel_name, err),
        vim.log.levels.WARN
      )
      kernel.set_kernel_name(state, kernel_name)
      return
    end

    local found = false
    for _, k in ipairs(kernels) do
      if k.name == kernel_name then
        found = true
        break
      end
    end

    if not found then
      local available = {}
      for _, k in ipairs(kernels) do
        table.insert(available, k.name)
      end
      vim.notify(
        string.format(
          "Warning: kernel '%s' not found in Jupyter.\nAvailable: %s",
          kernel_name,
          #available > 0 and table.concat(available, ', ') or '(none)'
        ),
        vim.log.levels.WARN
      )
    end

    kernel.set_kernel_name(state, kernel_name)
  end)
end

---Format kernel info for display
---@param state NotebookState
---@return string[]
local function format_kernel_info(state)
  local info = kernel.get_info(state)

  local lines = {
    'Kernelspec: ' .. info.kernelspec,
    'Python: ' .. (info.python_path or 'not found') .. ' (' .. info.python_source .. ')',
    '',
    'Connected: ' .. tostring(info.connected),
    'State: ' .. info.execution_state,
  }

  if info.running_kernel then
    table.insert(lines, 'Running kernel: ' .. info.running_kernel)
  end

  return lines
end

---Setup buffer-local commands for a notebook
---@param state NotebookState
function M.setup_buffer(state)
  local buf = state.facade_buf
  local facade = require('ipynb.facade')
  local keymaps = require('ipynb.keymaps')
  local kernel = require('ipynb.kernel')
  local cells = require('ipynb.cells')
  local output = require('ipynb.output')
  local folding = require('ipynb.folding')
  local picker = require('ipynb.picker')
  local lsp = require('ipynb.lsp')
  local io_mod = require('ipynb.io')

  -- Helper to get current cell index
  local function get_current_cell_idx()
    local cursor_line = vim.api.nvim_win_get_cursor(0)[1] - 1
    local cell_idx = cells.get_cell_at_line(state, cursor_line)
    return cell_idx
  end

  -- Save
  vim.api.nvim_buf_create_user_command(buf, 'NotebookSave', function()
    io_mod.save_notebook(buf, nil)
  end, { desc = 'Save notebook' })

  -- Cell insertion
  vim.api.nvim_buf_create_user_command(buf, 'NotebookInsertCellBelow', function()
    keymaps.add_cell_below(state)
  end, { desc = 'Insert cell below current' })

  vim.api.nvim_buf_create_user_command(buf, 'NotebookInsertCellAbove', function()
    keymaps.add_cell_above(state)
  end, { desc = 'Insert cell above current' })

  -- Cell deletion (uses facade.delete_cell directly)
  vim.api.nvim_buf_create_user_command(buf, 'NotebookDeleteCell', function()
    if #state.cells <= 1 then
      vim.notify('Cannot delete the only cell', vim.log.levels.WARN)
      return
    end
    local cell_idx = get_current_cell_idx()
    if cell_idx then
      facade.delete_cell(state, cell_idx)
    end
  end, { desc = 'Delete current cell' })

  -- Cell type changes
  vim.api.nvim_buf_create_user_command(buf, 'NotebookMakeCode', function()
    keymaps.set_cell_type(state, 'code')
  end, { desc = 'Make cell code type' })

  vim.api.nvim_buf_create_user_command(buf, 'NotebookMakeMarkdown', function()
    keymaps.set_cell_type(state, 'markdown')
  end, { desc = 'Make cell markdown type' })

  vim.api.nvim_buf_create_user_command(buf, 'NotebookMakeRaw', function()
    keymaps.set_cell_type(state, 'raw')
  end, { desc = 'Make cell raw type' })

  vim.api.nvim_buf_create_user_command(buf, 'NotebookToggleCellType', function()
    local cell_idx = get_current_cell_idx()
    if cell_idx then
      local cell = state.cells[cell_idx]
      local new_type = cell.type == 'code' and 'markdown' or 'code'
      keymaps.set_cell_type(state, new_type)
    end
  end, { desc = 'Toggle cell type (code/markdown)' })

  -- Cell movement
  vim.api.nvim_buf_create_user_command(buf, 'NotebookMoveCellUp', function()
    keymaps.move_cell(state, -1)
  end, { desc = 'Move cell up' })

  vim.api.nvim_buf_create_user_command(buf, 'NotebookMoveCellDown', function()
    keymaps.move_cell(state, 1)
  end, { desc = 'Move cell down' })

  -- Cell cut/paste
  vim.api.nvim_buf_create_user_command(buf, 'NotebookCutCell', function()
    keymaps.cut_cell(state)
  end, { desc = 'Cut cell to register' })

  vim.api.nvim_buf_create_user_command(buf, 'NotebookPasteCellBelow', function()
    keymaps.paste_cell(state, 'below')
  end, { desc = 'Paste cell below' })

  vim.api.nvim_buf_create_user_command(buf, 'NotebookPasteCellAbove', function()
    keymaps.paste_cell(state, 'above')
  end, { desc = 'Paste cell above' })

  -- Execution
  vim.api.nvim_buf_create_user_command(buf, 'NotebookExecuteCell', function()
    keymaps.execute_cell(state)
  end, { desc = 'Execute current cell' })

  vim.api.nvim_buf_create_user_command(buf, 'NotebookExecuteAndNext', function()
    keymaps.execute_and_next(state)
  end, { desc = 'Execute cell and move to next' })

  vim.api.nvim_buf_create_user_command(buf, 'NotebookExecuteAllBelow', function()
    keymaps.execute_all_below(state)
  end, { desc = 'Execute all cells from current to end' })

  -- Kernel commands
  vim.api.nvim_buf_create_user_command(buf, 'NotebookKernelStart', function(opts)
    local python_path = opts.args ~= '' and opts.args or nil
    kernel.connect(state, { python_path = python_path })
  end, {
    desc = 'Start Jupyter kernel',
    nargs = '?',
    complete = 'file',
  })

  vim.api.nvim_buf_create_user_command(buf, 'NotebookKernelConnect', function(opts)
    if opts.args == '' then
      vim.notify('Connection file required', vim.log.levels.ERROR)
      return
    end
    kernel.connect(state, { connection_file = opts.args })
  end, {
    desc = 'Connect to existing Jupyter kernel',
    nargs = 1,
    complete = 'file',
  })

  vim.api.nvim_buf_create_user_command(buf, 'NotebookKernelInterrupt', function()
    kernel.interrupt(state)
  end, { desc = 'Interrupt kernel execution' })

  vim.api.nvim_buf_create_user_command(buf, 'NotebookKernelRestart', function()
    kernel.restart(state, true)
  end, { desc = 'Restart kernel (clears outputs)' })

  vim.api.nvim_buf_create_user_command(buf, 'NotebookKernelShutdown', function()
    kernel.shutdown(state)
  end, { desc = 'Shutdown kernel' })

  vim.api.nvim_buf_create_user_command(buf, 'NotebookKernelStatus', function()
    local lines = { 'Kernel Status:', '' }
    for _, line in ipairs(format_kernel_info(state)) do
      table.insert(lines, '  ' .. line)
    end
    vim.notify(table.concat(lines, '\n'), vim.log.levels.INFO)
  end, { desc = 'Show kernel status' })

  vim.api.nvim_buf_create_user_command(buf, 'NotebookSetKernel', function(opts)
    if opts.args == '' then
      vim.notify('Kernel name required (e.g., python3, conda-ml)', vim.log.levels.ERROR)
      return
    end
    validate_and_set_kernel(state, opts.args)
  end, {
    desc = 'Set kernel name in notebook metadata',
    nargs = 1,
  })

  -- Output commands
  vim.api.nvim_buf_create_user_command(buf, 'NotebookOutput', function()
    output.open_output_float(state)
  end, { desc = 'Open cell output in floating buffer' })

  vim.api.nvim_buf_create_user_command(buf, 'NotebookClearOutput', function()
    keymaps.clear_output(state)
  end, { desc = 'Clear current cell output' })

  vim.api.nvim_buf_create_user_command(buf, 'NotebookClearAllOutputs', function()
    keymaps.clear_all_outputs(state)
  end, { desc = 'Clear all outputs' })

  -- Info command
  vim.api.nvim_buf_create_user_command(buf, 'NotebookInfo', function()
    local cursor_line = vim.api.nvim_win_get_cursor(0)[1] - 1
    local cell_idx, cell = cells.get_cell_at_line(state, cursor_line)

    local info = {
      'Notebook: ' .. state.source_path,
      'Shadow buffer: ' .. (state.shadow_path or 'none'),
      'Total cells: ' .. #state.cells,
      '',
    }

    -- Add kernel info
    for _, line in ipairs(format_kernel_info(state)) do
      table.insert(info, line)
    end

    table.insert(info, '')

    if cell_idx and cell then
      local start_line, end_line = cells.get_cell_range(state, cell_idx)
      table.insert(info, 'Current cell: ' .. cell_idx)
      table.insert(info, 'Cell type: ' .. cell.type)
      table.insert(info, 'Lines: ' .. (start_line + 1) .. '-' .. (end_line + 1))
      if cell.execution_count then
        table.insert(info, 'Execution count: ' .. cell.execution_count)
      end
      if cell.execution_state and cell.execution_state ~= 'idle' then
        table.insert(info, 'Execution state: ' .. cell.execution_state)
      end
    end

    vim.notify(table.concat(info, '\n'), vim.log.levels.INFO)
  end, { desc = 'Show notebook info' })

  -- Folding commands
  vim.api.nvim_buf_create_user_command(buf, 'NotebookFoldCell', function()
    folding.toggle_cell_fold(state)
  end, { desc = 'Toggle fold for current cell' })

  vim.api.nvim_buf_create_user_command(buf, 'NotebookFoldAll', function()
    folding.fold_all_cells(state, 'close')
  end, { desc = 'Fold all cells' })

  vim.api.nvim_buf_create_user_command(buf, 'NotebookUnfoldAll', function()
    folding.fold_all_cells(state, 'open')
  end, { desc = 'Unfold all cells' })

  -- Picker command
  vim.api.nvim_buf_create_user_command(buf, 'NotebookJumpToCell', function()
    picker.jump_to_cell()
  end, { desc = 'Jump to cell (picker)' })

  -- Inspector commands
  local inspector = require('ipynb.inspector')

  vim.api.nvim_buf_create_user_command(buf, 'NotebookInspect', function()
    inspector.show_variable_at_cursor(state)
  end, { desc = 'Inspect variable at cursor' })

  vim.api.nvim_buf_create_user_command(buf, 'NotebookInspectCell', function()
    inspector.show_cell_variables(state)
  end, { desc = 'Show all variables in cell' })

  vim.api.nvim_buf_create_user_command(buf, 'NotebookToggleAutoHover', function()
    inspector.toggle_auto_hover()
  end, { desc = 'Toggle auto-hover on CursorHold' })

  -- Formatting commands
  vim.api.nvim_buf_create_user_command(buf, 'NotebookFormatCell', function()
    lsp.format_current_cell(state)
  end, { desc = 'Format current cell' })

  vim.api.nvim_buf_create_user_command(buf, 'NotebookFormatAll', function()
    lsp.format_all_cells(state)
  end, { desc = 'Format all code cells' })

  -- Debug command
  vim.api.nvim_buf_create_user_command(buf, 'NotebookDebug', function()
    print('State:', vim.inspect(state))
  end, { desc = 'Debug notebook state' })
end

---Setup global commands (called once during plugin setup)
function M.setup()
  -- NotebookCreate - available globally to create new notebooks
  vim.api.nvim_create_user_command('NotebookCreate', function(opts)
    local path = opts.fargs[1] or ''
    local kernel_name = opts.fargs[2]

    if path == '' then
      -- Default to untitled.ipynb in current directory
      local cwd = vim.fn.getcwd()
      local base = 'untitled'
      local ext = '.ipynb'
      path = cwd .. '/' .. base .. ext

      -- Find unique name if file exists
      local counter = 1
      while vim.fn.filereadable(path) == 1 do
        path = cwd .. '/' .. base .. counter .. ext
        counter = counter + 1
      end
    end

    -- Ensure .ipynb extension
    if not path:match('%.ipynb$') then
      path = path .. '.ipynb'
    end

    -- Open the new notebook (io.lua handles creation)
    vim.cmd.edit(path)

    -- Set kernel if specified (must be done after notebook is loaded)
    if kernel_name then
      vim.schedule(function()
        local state = require('ipynb.state').get()
        if state then
          validate_and_set_kernel(state, kernel_name)
        end
      end)
    end
  end, {
    desc = 'Create a new Jupyter notebook',
    nargs = '*',
    complete = 'file',
  })

  -- NotebookListKernels - query jupyter for available kernelspecs
  vim.api.nvim_create_user_command('NotebookListKernels', function()
    -- Use current notebook path if available for Python discovery
    local state = require('ipynb.state').get()
    local notebook_path = state and state.source_path or nil

    kernel.list_kernels(notebook_path, function(kernels, err)
      if err then
        vim.notify('Failed to list kernels: ' .. err, vim.log.levels.ERROR)
        return
      end

      local lines = { 'Available Jupyter kernels:', '' }
      for _, k in ipairs(kernels) do
        local lang = k.language or '?'
        table.insert(lines, string.format('  %s (%s) - %s', k.name, lang, k.display_name))
      end

      if #kernels == 0 then
        table.insert(lines, '  (none found)')
      end

      vim.notify(table.concat(lines, '\n'), vim.log.levels.INFO)
    end)
  end, { desc = 'List available Jupyter kernels' })
end

return M
