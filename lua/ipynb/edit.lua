-- ipynb/edit.lua - Edit float management

local M = {}

---Set lines on facade buffer, suppressing LSP change tracking errors
---LSP change tracking fails because facade isn't registered with the shadow buffer's LSP clients
---@param buf number Facade buffer
---@param start_line number 0-indexed start line
---@param end_line number 0-indexed end line (exclusive)
---@param lines string[] New lines
local function set_facade_lines(buf, start_line, end_line, lines)
  -- Suppress LSP change tracking errors by wrapping in pcall
  -- The error occurs because get_clients returns shadow clients for facade,
  -- but change tracking expects facade to be registered with those clients
  local ok, err = pcall(vim.api.nvim_buf_set_lines, buf, start_line, end_line, false, lines)
  if not ok and err and not err:match('_changetracking') then
    -- Re-raise non-change-tracking errors
    error(err)
  end
end

---Fire LspAttach autocmd for edit buffer so user's keymaps work
---We set client.attached_buffers so buf_is_attached() returns true for keymaps.
---To prevent change tracking errors, we also install a handler to suppress them.
---@param state NotebookState
---@param edit_buf number
function M.fire_lsp_attach(state, edit_buf)
  if not state.shadow_buf or not vim.api.nvim_buf_is_valid(state.shadow_buf) then
    return
  end

  -- Get clients attached to shadow buffer and fire LspAttach for each
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = state.shadow_buf })) do
    -- Mark as attached so buf_is_attached() returns true (needed for keymaps)
    client.attached_buffers[edit_buf] = true

    -- Fire LspAttach autocmd to trigger user's keymap setup (LazyVim/Snacks)
    vim.api.nvim_exec_autocmds('LspAttach', {
      buffer = edit_buf,
      modeline = false,
      data = { client_id = client.id },
    })
  end
end

-- Track edit buffers to suppress change tracking errors
M._edit_buffers = {}

---Mark a buffer as an edit buffer (suppresses change tracking errors)
---@param edit_buf number
function M.register_edit_buffer(edit_buf)
  M._edit_buffers[edit_buf] = true
end

---Unmark a buffer as an edit buffer
---@param edit_buf number
function M.unregister_edit_buffer(edit_buf)
  M._edit_buffers[edit_buf] = nil
end

-- Install change tracking error suppression (called once)
local _changetracking_wrapped = false
local function install_changetracking_wrapper()
  if _changetracking_wrapped then
    return
  end
  _changetracking_wrapped = true

  -- Wrap the on_bytes handler that LSP sets up
  -- We intercept at the point where changes are sent
  local ct = vim.lsp._changetracking
  if ct and ct.send_changes then
    local orig_send_changes = ct.send_changes
    ---@diagnostic disable-next-line: duplicate-set-field
    ct.send_changes = function(bufnr, ...)
      -- Skip change tracking for our edit buffers
      if M._edit_buffers[bufnr] then
        return
      end
      return orig_send_changes(bufnr, ...)
    end
  end
end

-- Install wrapper when module loads
install_changetracking_wrapper()

---Update edit window height and reset view
---@param edit table The edit_state table
---@param line_count number Number of lines
local function update_edit_window_height(edit, line_count)
  if vim.api.nvim_win_is_valid(edit.win) then
    vim.api.nvim_win_set_height(edit.win, math.max(line_count, 1))
    vim.api.nvim_win_call(edit.win, function()
      vim.fn.winrestview({ topline = 1 })
    end)
  end
end

---Get or create edit buffer for a cell
---@param cell Cell
---@param lines string[]
---@return number buf
local function get_or_create_edit_buf(cell, lines)
  -- Reuse existing buffer if valid (preserves undo history)
  if cell.edit_buf and vim.api.nvim_buf_is_valid(cell.edit_buf) then
    -- Refresh content from facade (may have changed via undo/redo)
    local current = vim.api.nvim_buf_get_lines(cell.edit_buf, 0, -1, false)
    if table.concat(current, '\n') ~= table.concat(lines, '\n') then
      vim.api.nvim_buf_set_lines(cell.edit_buf, 0, -1, false, lines)
      vim.bo[cell.edit_buf].modified = false
    end
    return cell.edit_buf
  end

  -- Create new buffer (unlisted, not scratch - we'll set buftype manually)
  local buf = vim.api.nvim_create_buf(false, false)

  -- Register as edit buffer to suppress change tracking errors
  M.register_edit_buffer(buf)

  -- Use language from notebook metadata for code cells (stored in facade buffer variable)
  local lang = 'python' -- default
  local state = require('ipynb.state').get()
  if cell.type == 'code' then
    if state and state.facade_buf then
      lang = vim.b[state.facade_buf].ipynb_language or 'python'
    end
  else
    lang = 'markdown'
  end

  -- Give buffer a name (required for :w to work with acwrite)
  local notebook_name = state and state.source_path and vim.fn.fnamemodify(state.source_path, ':t') or 'notebook'
  vim.api.nvim_buf_set_name(buf, string.format('[%s:%s]', notebook_name, cell.id or 'cell'))

  vim.bo[buf].bufhidden = 'hide' -- Keep buffer when window closes
  -- Use 'acwrite' so :w triggers BufWriteCmd instead of E382 error
  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].swapfile = false

  -- Set filetype to enable user's FileType autocmds (for LSP keymaps like gr, gd)
  -- Our buffer name pattern [notebook.ipynb:cell_id] doesn't match lspconfig's
  -- bufname_valid() check, so LSP won't try to attach directly
  -- Our get_clients/buf_request wrappers proxy LSP requests to the shadow buffer
  vim.bo[buf].filetype = lang

  -- Also start treesitter explicitly in case filetype autocmd doesn't
  pcall(vim.treesitter.start, buf, lang)

  -- Store the language for reference (used by our LSP wrappers)
  vim.b[buf].ipynb_edit_lang = lang

  -- Setup BufWriteCmd to save the notebook when :w is used in edit buffer
  vim.api.nvim_create_autocmd('BufWriteCmd', {
    buffer = buf,
    callback = function(args)
      -- Use get_from_edit_buf since we're in the edit buffer, not facade
      local current_state = require('ipynb.state').get_from_edit_buf(args.buf)
      if current_state then
        require('ipynb.io').save_notebook(current_state.facade_buf)
        -- Clear modified flag on the edit buffer too
        vim.bo[args.buf].modified = false
      end
    end,
  })

  -- Enable undo in edit buffers for natural undo behavior while typing
  -- Facade undo syncs at natural break points (InsertLeave, etc.)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false

  -- Store in cell for reuse
  cell.edit_buf = buf
  return buf
end

---Open edit float for current cell
---@param state NotebookState
---@param mode string|nil "append" to position cursor at end
function M.open(state, mode)
  local cells_mod = require('ipynb.cells')
  local config = require('ipynb.config').get()

  -- Get current window (facade window)
  local parent_win = vim.api.nvim_get_current_win()

  -- Get current cursor position in facade (1-indexed)
  local facade_cursor = vim.api.nvim_win_get_cursor(0)
  local cursor_line = facade_cursor[1] - 1  -- 0-indexed
  local cursor_col = facade_cursor[2]

  local cell_idx, cell = cells_mod.get_cell_at_line(state, cursor_line)

  if not cell_idx or not cell then
    vim.notify('No cell at cursor', vim.log.levels.WARN)
    return
  end

  -- Close existing edit float if open (but keep buffer)
  if state.edit_state then
    M.close(state)
  end

  -- Get cell content range
  local content_start, content_end = cells_mod.get_content_range(state, cell_idx)
  if not content_start or not content_end then
    vim.notify('Could not get cell content range', vim.log.levels.WARN)
    return
  end

  -- Get lines from facade buffer (content only, no markers)
  local lines = vim.api.nvim_buf_get_lines(state.facade_buf, content_start, content_end + 1, false)

  -- Get or create edit buffer for this cell
  local buf = get_or_create_edit_buf(cell, lines)

  -- Get window dimensions for precise overlay
  local win_width = vim.api.nvim_win_get_width(parent_win)
  local wininfo = vim.fn.getwininfo(parent_win)[1]
  local textoff = wininfo.textoff -- sign column + line numbers + fold column

  -- Height matches the cell content exactly
  local height = math.max(#lines, 1)

  -- Calculate position and width based on line number setting
  local float_col, float_width
  if config.float.show_line_numbers then
    -- Cover entire window including gutter
    float_col = -textoff
    float_width = win_width
  else
    -- Cover just the text area
    float_col = 0
    float_width = win_width - textoff
  end

  -- Open float anchored to cell position in buffer
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'win',
    win = parent_win,
    bufpos = { content_start, 0 }, -- 0-indexed line where content starts
    row = 0,
    col = float_col,
    width = float_width,
    height = height,
    anchor = 'NW',
    border = 'none', -- No border for seamless overlay
    zindex = 40,  -- Lower than default (50) so LSP floats appear on top
  })

  -- Copy window settings from parent to match appearance
  if config.float.show_line_numbers then
    vim.wo[win].number = vim.wo[parent_win].number
    vim.wo[win].relativenumber = vim.wo[parent_win].relativenumber
    vim.wo[win].numberwidth = vim.wo[parent_win].numberwidth
    vim.wo[win].signcolumn = vim.wo[parent_win].signcolumn
  else
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = 'no'
  end

  -- Store edit state (track by cell_id for stability across undo)
  state.edit_state = {
    buf = buf,
    win = win,
    parent_win = parent_win,
    cell_idx = cell_idx,
    cell_id = cell.id,  -- Track by ID for stability across undo
    start_line = content_start,
    end_line = content_end,
    last_changedtick = vim.api.nvim_buf_get_changedtick(buf),  -- Track for spurious TextChangedI detection
  }

  -- Re-render visuals to show active border (must be after edit_state is set)
  local visuals = require('ipynb.visuals')
  visuals.render_all(state)

  -- Keep facade modifiable during edit session (avoids undo chain breaks from toggling)
  vim.bo[state.facade_buf].modifiable = true

  -- Setup real-time sync (once per buffer to preserve undo tracking state)
  if not vim.b[buf].notebook_sync_attached then
    M.setup_sync(state, buf)
    vim.b[buf].notebook_sync_attached = true
  end

  -- Setup cursor sync (uses augroup with clear=true, safe to call repeatedly)
  M.setup_cursor_sync(state)

  -- Setup keymaps (once per buffer)
  if not vim.b[buf].notebook_keymaps_set then
    M.setup_edit_keymaps(state)
    vim.b[buf].notebook_keymaps_set = true
  end

  -- Fire LspAttach for code cells so user's LSP keymaps (gr, gd, K, etc.) get set up
  -- This is needed because user's keymaps are typically set in LspAttach callbacks,
  -- not FileType callbacks. Setting filetype alone isn't enough.
  if cell.type == 'code' and not vim.b[buf].notebook_lsp_attach_fired then
    vim.b[buf].notebook_lsp_attach_fired = true
    M.fire_lsp_attach(state, buf)
  end

  -- Setup LSP completion and diagnostics for code cells
  local lsp_mod = require('ipynb.lsp')
  lsp_mod.setup_completion(state)
  lsp_mod.setup_edit_diagnostics(state)

  -- Calculate relative position within cell content
  local relative_line = cursor_line - content_start + 1  -- 1-indexed for nvim_win_set_cursor
  local max_line = vim.api.nvim_buf_line_count(buf)

  -- Clamp to valid range
  if relative_line < 1 then
    relative_line = 1
  elseif relative_line > max_line then
    relative_line = max_line
  end

  -- Get the line length to clamp column
  local line_content = vim.api.nvim_buf_get_lines(buf, relative_line - 1, relative_line, false)[1] or ''
  local max_col = #line_content
  local target_col = math.min(cursor_col, max_col)

  -- Position cursor and enter appropriate mode
  vim.api.nvim_win_set_cursor(state.edit_state.win, { relative_line, target_col })

  if mode == 'i' then
    -- insert at cursor
    vim.cmd('startinsert')
  elseif mode == 'a' then
    -- append after cursor
    vim.cmd('normal! l')
    vim.cmd('startinsert')
  elseif mode == 'A' then
    -- append at end of line
    vim.cmd('startinsert!')
  elseif mode == 'I' then
    -- insert at beginning of line (first non-blank)
    vim.cmd('normal! ^')
    vim.cmd('startinsert')
  elseif mode == 'o' then
    -- open line below
    vim.cmd('normal! o')
  elseif mode == 'O' then
    -- open line above
    vim.cmd('normal! O')
  end
  -- mode == nil: stay in normal mode at cursor position
end

---Setup real-time sync from edit buffer to facade and shadow
---Facade sync happens on InsertLeave for natural undo granularity (one undo per insert session)
---Shadow sync happens on every change for LSP responsiveness
---@param state NotebookState
---@param buf number The edit buffer to attach to
function M.setup_sync(state, buf)
  local group = vim.api.nvim_create_augroup('NotebookSync_' .. buf, { clear = true })

  --- Helper to sync facade and update visuals
  --- Called from InsertLeave and TextChanged; facade is modifiable during edit session
  local function sync_facade()
    if not vim.api.nvim_buf_is_valid(state.facade_buf) then
      return
    end

    local edit = state.edit_state
    if not edit then return end

    local new_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local new_count = #new_lines
    local old_line_count = edit.end_line - edit.start_line + 1
    local line_count_changed = old_line_count ~= new_count

    -- Sync to facade (one undo entry per call)
    set_facade_lines(state.facade_buf, edit.start_line, edit.end_line + 1, new_lines)

    -- Re-show diagnostics (nvim_buf_set_lines clears extmarks on modified lines)
    require('ipynb.lsp').refresh_facade_diagnostics(state)

    -- Update edit state
    edit.end_line = edit.start_line + new_count - 1

    -- Refresh markers and visuals if line count changed
    if line_count_changed then
      require('ipynb.cells').place_markers(state)
      require('ipynb.visuals').render_all(state)

      local images_mod = require('ipynb.images')
      if images_mod.is_available() then
        images_mod.sync_positions(state)
      end

      update_edit_window_height(edit, new_count)
    end
  end

  -- Sync shadow buffer and facade on every change during insert mode
  vim.api.nvim_create_autocmd('TextChangedI', {
    group = group,
    buffer = buf,
    callback = function()
      if state.skip_sync or not state.edit_state or state.edit_state.buf ~= buf then
        return
      end

      local edit = state.edit_state --[[@as EditState]]
      local cell = state.cells[edit.cell_idx]
      if not cell then return end

      -- Check changedtick to avoid spurious TextChangedI on insert mode entry
      local current_tick = vim.api.nvim_buf_get_changedtick(buf)
      if edit.last_changedtick and current_tick == edit.last_changedtick then
        return
      end
      edit.last_changedtick = current_tick

      local new_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local new_count = #new_lines
      local old_line_count = edit.end_line - edit.start_line + 1
      local line_count_changed = old_line_count ~= new_count

      -- Update shadow buffer for LSP
      require('ipynb.lsp').sync_shadow_region(state, edit.start_line, edit.end_line + 1, new_lines, cell.type)

      -- Update cell source in state
      cell.source = table.concat(new_lines, '\n')

      -- Sync to facade buffer (so other cells shift and line numbers update)
      -- Use undojoin to merge all changes during insert into one undo entry
      if edit.insert_synced then
        pcall(vim.cmd.undojoin)
      end
      set_facade_lines(state.facade_buf, edit.start_line, edit.end_line + 1, new_lines)
      edit.insert_synced = true

      -- Re-show diagnostics (nvim_buf_set_lines clears extmarks on modified lines)
      require('ipynb.lsp').refresh_facade_diagnostics(state)

      -- Update end_line before any other operations
      edit.end_line = edit.start_line + new_count - 1

      -- Update window height and markers if line count changed
      if line_count_changed then
        update_edit_window_height(edit, new_count)
        require('ipynb.cells').place_markers(state)
      end
    end,
  })

  -- Sync facade on InsertLeave and reset insert_synced flag
  vim.api.nvim_create_autocmd('InsertLeave', {
    group = group,
    buffer = buf,
    callback = function()
      if state.skip_sync or not state.edit_state or state.edit_state.buf ~= buf then
        return
      end
      local edit = state.edit_state --[[@as EditState]]
      -- Only sync if TextChangedI actually fired (insert_synced == true means changes were made)
      local had_changes = edit.insert_synced
      -- Reset flag so next insert session gets fresh undo entry
      edit.insert_synced = false
      if had_changes then
        sync_facade()
      end
    end,
  })

  -- Also sync facade on TextChanged (normal mode changes like dd, p, etc.)
  vim.api.nvim_create_autocmd('TextChanged', {
    group = group,
    buffer = buf,
    callback = function()
      if state.skip_sync or not state.edit_state or state.edit_state.buf ~= buf then
        return
      end

      local edit = state.edit_state --[[@as EditState]]
      local cell = state.cells[edit.cell_idx]
      if not cell then return end

      -- Check changedtick to avoid spurious TextChanged on buffer refresh (e.g., reopening cell)
      local current_tick = vim.api.nvim_buf_get_changedtick(buf)
      if edit.last_changedtick and current_tick == edit.last_changedtick then
        return
      end
      edit.last_changedtick = current_tick

      local new_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

      -- Update shadow for LSP
      require('ipynb.lsp').sync_shadow_region(state, edit.start_line, edit.end_line + 1, new_lines, cell.type)
      cell.source = table.concat(new_lines, '\n')

      -- Sync facade
      sync_facade()
    end,
  })
end

---Setup cursor sync from edit buffer to facade
---@param state NotebookState
function M.setup_cursor_sync(state)
  local edit = state.edit_state
  if not edit then return end

  -- Use buffer-specific augroup with clear=true to prevent accumulation
  local group_name = 'NotebookCursorSync_' .. edit.buf
  local group = vim.api.nvim_create_augroup(group_name, { clear = true })

  vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI' }, {
    group = group,
    buffer = edit.buf,
    callback = function()
      -- Use current edit_state for fresh window/position references
      if not state.edit_state then
        return
      end
      local current_edit = state.edit_state --[[@as EditState]]
      if not vim.api.nvim_win_is_valid(current_edit.parent_win) then
        return
      end
      if not vim.api.nvim_win_is_valid(current_edit.win) then
        return
      end

      -- Get cursor position in edit buffer (1-indexed)
      local edit_cursor = vim.api.nvim_win_get_cursor(current_edit.win)
      local edit_line = edit_cursor[1]
      local edit_col = edit_cursor[2]

      -- Translate to facade position
      local facade_line = current_edit.start_line + edit_line -- start_line is 0-indexed, edit_line is 1-indexed

      -- Update facade cursor without changing focus
      vim.api.nvim_win_set_cursor(current_edit.parent_win, { facade_line, edit_col })
    end,
  })
end

---Setup keymaps for edit float
---@param state NotebookState
function M.setup_edit_keymaps(state)
  if not state.edit_state then return end
  local buf = state.edit_state.buf
  local opts = { buffer = buf, silent = true }
  local config = require('ipynb.config').get()
  local km = config.keymaps

  -- Exit edit mode (Esc only, q reserved for macros)
  vim.keymap.set('n', '<Esc>', function()
    M.close(state)
  end, vim.tbl_extend('force', opts, { desc = 'Close edit float' }))

  -- Navigate to adjacent cells
  vim.keymap.set('n', '<C-j>', function()
    M.edit_next_cell(state)
  end, vim.tbl_extend('force', opts, { desc = 'Edit next cell' }))

  vim.keymap.set('n', '<C-k>', function()
    M.edit_prev_cell(state)
  end, vim.tbl_extend('force', opts, { desc = 'Edit previous cell' }))

  -- Global undo/redo (operates on facade buffer)
  vim.keymap.set('n', 'u', function()
    M.global_undo(state)
  end, vim.tbl_extend('force', opts, { desc = 'Global undo' }))

  vim.keymap.set('n', '<C-r>', function()
    M.global_redo(state)
  end, vim.tbl_extend('force', opts, { desc = 'Global redo' }))

  -- Execute cell and stay in edit mode
  vim.keymap.set({ 'n', 'i' }, '<C-CR>', function()
    local edit = state.edit_state
    if not edit then return end
    local cell = state.cells[edit.cell_idx]
    if cell and cell.type == 'code' then
      require('ipynb.kernel').execute(state, edit.cell_idx)
    end
  end, vim.tbl_extend('force', opts, { desc = 'Execute cell (stay in edit)' }))

  -- Execute cell and move to next (close float)
  local function execute_and_next()
    local edit = state.edit_state
    if not edit then return end
    local cell_idx = edit.cell_idx
    local cell = state.cells[cell_idx]

    -- Exit insert mode if needed
    if vim.fn.mode() == 'i' then
      vim.cmd('stopinsert')
    end

    -- Execute if code cell
    if cell and cell.type == 'code' then
      require('ipynb.kernel').execute(state, cell_idx)
    end

    -- Close float and move to next cell
    M.close(state)
    if cell_idx < #state.cells then
      require('ipynb.cells').goto_next_cell(state)
    end
  end

  vim.keymap.set({ 'n', 'i' }, '<S-CR>', execute_and_next,
    vim.tbl_extend('force', opts, { desc = 'Execute cell, move next' }))

  -- Fallback for terminals without <S-CR> support
  vim.keymap.set('n', km.menu_execute_and_next, execute_and_next,
    vim.tbl_extend('force', opts, { desc = 'Execute cell, move next' }))

  -- Execute cell (stay in edit) - menu key version
  vim.keymap.set('n', km.menu_execute_cell, function()
    local edit = state.edit_state
    if not edit then return end
    local cell = state.cells[edit.cell_idx]
    if cell and cell.type == 'code' then
      require('ipynb.kernel').execute(state, edit.cell_idx)
    end
  end, vim.tbl_extend('force', opts, { desc = 'Execute cell' }))

  -- Cell operations (close edit, perform action)
  vim.keymap.set('n', km.add_cell_above, function()
    M.close(state)
    require('ipynb.keymaps').add_cell_above(state)
  end, vim.tbl_extend('force', opts, { desc = 'Cell add above' }))

  vim.keymap.set('n', km.add_cell_below, function()
    M.close(state)
    require('ipynb.keymaps').add_cell_below(state)
  end, vim.tbl_extend('force', opts, { desc = 'Cell add below' }))

  vim.keymap.set('n', km.make_markdown, function()
    local edit = state.edit_state
    if edit then
      require('ipynb.facade').set_cell_type(state, edit.cell_idx, 'markdown')
    end
  end, vim.tbl_extend('force', opts, { desc = 'Cell type: markdown' }))

  vim.keymap.set('n', km.make_code, function()
    local edit = state.edit_state
    if edit then
      require('ipynb.facade').set_cell_type(state, edit.cell_idx, 'code')
    end
  end, vim.tbl_extend('force', opts, { desc = 'Cell type: code' }))

  vim.keymap.set('n', km.make_raw, function()
    local edit = state.edit_state
    if edit then
      require('ipynb.facade').set_cell_type(state, edit.cell_idx, 'raw')
    end
  end, vim.tbl_extend('force', opts, { desc = 'Cell type: raw' }))

  -- Output operations
  vim.keymap.set('n', km.open_output, function()
    require('ipynb.output').open_output_float(state)
  end, vim.tbl_extend('force', opts, { desc = 'Output open' }))

  vim.keymap.set('n', km.clear_output, function()
    local edit = state.edit_state
    if edit then
      require('ipynb.output').clear_outputs(state, edit.cell_idx)
    end
  end, vim.tbl_extend('force', opts, { desc = 'Output clear' }))

  vim.keymap.set('n', km.clear_all_outputs, function()
    require('ipynb.keymaps').clear_all_outputs(state)
  end, vim.tbl_extend('force', opts, { desc = 'Output clear all' }))

  -- Kernel operations
  vim.keymap.set('n', km.kernel_interrupt, function()
    require('ipynb.kernel').interrupt(state)
  end, vim.tbl_extend('force', opts, { desc = 'Kernel interrupt' }))

  vim.keymap.set('n', km.kernel_restart, function()
    require('ipynb.kernel').restart(state, true)
  end, vim.tbl_extend('force', opts, { desc = 'Kernel restart' }))

  vim.keymap.set('n', km.kernel_start, function()
    require('ipynb.kernel').connect(state, {})
  end, vim.tbl_extend('force', opts, { desc = 'Kernel start' }))

  vim.keymap.set('n', km.kernel_shutdown, function()
    require('ipynb.kernel').shutdown(state)
  end, vim.tbl_extend('force', opts, { desc = 'Kernel shutdown' }))

  vim.keymap.set('n', km.kernel_info, function()
    require('ipynb.keymaps').kernel_info(state)
  end, vim.tbl_extend('force', opts, { desc = 'Kernel info' }))

  -- Jump to cell (closes edit, opens picker)
  vim.keymap.set('n', km.jump_to_cell, function()
    M.close(state)
    require('ipynb.picker').jump_to_cell()
  end, vim.tbl_extend('force', opts, { desc = 'Jump to cell' }))

  -- Inspector (also available in edit mode)
  vim.keymap.set('n', km.variable_inspect, function()
    require('ipynb.inspector').show_variable_at_cursor(state)
  end, vim.tbl_extend('force', opts, { desc = 'Inspect variable' }))

  vim.keymap.set('n', km.cell_variables, function()
    require('ipynb.inspector').show_cell_variables(state)
  end, vim.tbl_extend('force', opts, { desc = 'Inspect cell' }))

  vim.keymap.set('n', km.toggle_auto_hover, function()
    require('ipynb.inspector').toggle_auto_hover()
  end, vim.tbl_extend('force', opts, { desc = 'Inspect auto-hover toggle' }))

  -- Setup auto-hover on CursorHold for edit buffer
  require('ipynb.inspector').setup_auto_hover(state, buf)

  -- NOTE: No custom LSP keymaps here. User's keymaps (gd, gr, K, etc.) work
  -- transparently through the LSP proxy in lsp.lua which wraps:
  -- - vim.lsp.util.make_position_params (rewrites URI and line offset)
  -- - vim.lsp.get_clients (returns shadow buffer's clients)
  -- - vim.lsp.buf_request (redirects to shadow buffer)
end

---Perform global undo or redo on facade buffer and refresh edit buffer
---@param state NotebookState
---@param cmd "undo"|"redo" The command to execute
local function global_undo_redo(state, cmd)
  if not vim.api.nvim_buf_is_valid(state.facade_buf) then
    return
  end

  -- Check undo state before to see if anything changes
  local seq_before = vim.api.nvim_buf_call(state.facade_buf, function()
    return vim.fn.undotree().seq_cur
  end)

  -- Perform undo/redo on facade buffer
  -- Facade is kept modifiable during edit session (open/close handle that)
  local was_modifiable = vim.bo[state.facade_buf].modifiable
  if not was_modifiable then
    vim.bo[state.facade_buf].modifiable = true
  end

  vim.api.nvim_buf_call(state.facade_buf, function()
    vim.cmd('silent! ' .. cmd)
  end)

  if not was_modifiable then
    vim.bo[state.facade_buf].modifiable = false
  end

  -- Check if undo/redo actually changed anything
  local seq_after = vim.api.nvim_buf_call(state.facade_buf, function()
    return vim.fn.undotree().seq_cur
  end)
  if seq_before == seq_after then
    return
  end

  -- Sync cells from updated facade and re-place markers
  local cells_mod = require('ipynb.cells')
  cells_mod.sync_cells_from_facade(state)
  cells_mod.place_markers(state)

  -- Refresh the active edit buffer directly from facade
  state.skip_sync = true
  if state.edit_state and vim.api.nvim_buf_is_valid(state.edit_state.buf) then
    local target_cell_id = state.edit_state.cell_id
    for i, cell in ipairs(state.cells) do
      if cell.id == target_cell_id then
        local content_start, content_end = cells_mod.get_content_range(state, i)
        if content_start and content_end then
          local lines = vim.api.nvim_buf_get_lines(state.facade_buf, content_start, content_end + 1, false)
          vim.api.nvim_buf_set_lines(state.edit_state.buf, 0, -1, false, lines)

          cell.edit_buf = state.edit_state.buf
          state.edit_state.cell_idx = i
          state.edit_state.start_line = content_start
          state.edit_state.end_line = content_end

          update_edit_window_height(state.edit_state, #lines)
        end
        break
      end
    end
  end
  state.skip_sync = false

  -- Update shadow buffer
  local lsp_mod = require('ipynb.lsp')
  lsp_mod.refresh_shadow(state)

  -- Defer visual and output updates to avoid signcols race condition
  vim.schedule(function()
    local visuals = require('ipynb.visuals')
    visuals.render_all(state)

    local output_mod = require('ipynb.output')
    output_mod.render_all(state)

    local images_mod = require('ipynb.images')
    if images_mod.is_available() then
      images_mod.sync_positions(state)
    end
  end)
end

---Perform global undo on facade buffer and refresh edit buffer
---@param state NotebookState
function M.global_undo(state)
  global_undo_redo(state, 'undo')
end

---Perform global redo on facade buffer and refresh edit buffer
---@param state NotebookState
function M.global_redo(state)
  global_undo_redo(state, 'redo')
end

---Close edit float
---@param state NotebookState
function M.close(state)
  if not state.edit_state then
    return
  end

  local edit = state.edit_state --[[@as EditState]]
  local cell = state.cells[edit.cell_idx]

  -- Update cell content in state
  if cell and vim.api.nvim_buf_is_valid(edit.buf) then
    local lines = vim.api.nvim_buf_get_lines(edit.buf, 0, -1, false)
    cell.source = table.concat(lines, '\n')
    -- Clear modified flag - content is synced to facade
    vim.bo[edit.buf].modified = false
  end

  -- Close window (buffer persists due to bufhidden='hide')
  if vim.api.nvim_win_is_valid(edit.win) then
    vim.api.nvim_win_close(edit.win, true)
  end

  -- Restore facade to non-modifiable
  vim.bo[state.facade_buf].modifiable = false

  state.edit_state = nil

  -- Refresh facade markers and visuals
  local cells_mod = require('ipynb.cells')
  cells_mod.refresh_markers(state)

  local visuals = require('ipynb.visuals')
  visuals.render_all(state)

  -- Refresh diagnostics on facade
  require('ipynb.lsp').refresh_facade_diagnostics(state)

  -- Return focus to facade buffer
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == state.facade_buf then
      vim.api.nvim_set_current_win(win)
      break
    end
  end
end

---Edit adjacent cell (next or previous)
---@param state NotebookState
---@param direction number 1 for next, -1 for previous
local function edit_adjacent_cell(state, direction)
  if not state.edit_state then
    return
  end

  local target_idx = state.edit_state.cell_idx + direction
  local valid = (direction > 0 and target_idx <= #state.cells) or (direction < 0 and target_idx >= 1)

  if valid then
    M.close(state)
    local cells_mod = require('ipynb.cells')
    local start_line = cells_mod.get_cell_range(state, target_idx)
    vim.api.nvim_win_set_cursor(0, { start_line + 2, 0 })
    vim.schedule(function()
      M.open(state)
    end)
  end
end

---Edit next cell
---@param state NotebookState
function M.edit_next_cell(state)
  edit_adjacent_cell(state, 1)
end

---Edit previous cell
---@param state NotebookState
function M.edit_prev_cell(state)
  edit_adjacent_cell(state, -1)
end

return M
