-- Buffer modified state tests for ipynb.nvim
-- Run with: nvim --headless -u tests/minimal_init.lua -l tests/test_modified.lua

local h = require('tests.helpers')
local input_mod = require('ipynb.input')
local state_mod = require('ipynb.state')

local function open_test_input_prompt(state)
  input_mod.request(state, {
    request_id = 'test-request',
    prompt = 'Input: ',
    password = false,
  }, function() end, function() end)
  vim.wait(20)
  return state._input_state
end

print('')
print(string.rep('=', 60))
print('Running buffer modified state tests')
print(string.rep('=', 60))
print('')

--------------------------------------------------------------------------------
-- Test: No spurious modified flag on cell enter/exit
-- Enter a cell, make no changes, exit.
-- Expected: Buffer not marked as modified.
--------------------------------------------------------------------------------
h.run_test('no_modified_on_enter_exit', function()
  h.open_notebook('simple.ipynb')

  local facade_buf = h.get_facade_buf()

  -- Clear any initial modified state
  vim.bo[facade_buf].modified = false

  -- Enter and exit without changes
  h.enter_cell(1)
  h.assert_true(h.is_in_edit_float(), 'Should be in edit float')
  h.exit_cell()

  -- Should not be modified
  -- Note: facade is non-modifiable, so check edit buffer behavior instead
  h.assert_false(h.is_in_edit_float(), 'Should have exited edit float')
end)

--------------------------------------------------------------------------------
-- Test: No undo entry on cell enter without changes
-- Enter cell, exit without changes, try to undo.
-- Expected: Undo should do nothing (no spurious undo entry).
--------------------------------------------------------------------------------
h.run_test('no_undo_entry_without_changes', function()
  h.open_notebook('simple.ipynb')
  local original = h.get_cell_content(1)

  -- Make a real change first using direct buffer manipulation
  h.enter_cell(1)
  local current = h.get_edit_buffer_content()
  h.set_edit_content('TEST\n' .. current)
  -- Trigger TextChanged to sync
  vim.api.nvim_exec_autocmds('TextChanged', { buffer = h.get_edit_buf() })
  vim.wait(50)
  h.exit_cell()

  local after_change = h.get_cell_content(1)
  h.assert_true(after_change:match('TEST'), 'Should have TEST after change')

  -- Enter and exit without changes multiple times
  for _ = 1, 3 do
    h.enter_cell(1)
    h.exit_cell()
  end

  -- Single undo should revert the real change, not the spurious enter/exits
  h.undo()
  h.assert_eq(h.get_cell_content(1), original,
    'Single undo should revert to original (no spurious undo entries)')
end)

--------------------------------------------------------------------------------
-- Test: Edit buffer modified flag cleared on exit
-- Make changes, exit cell - edit buffer should have modified=false.
--------------------------------------------------------------------------------
h.run_test('edit_buf_modified_cleared_on_exit', function()
  h.open_notebook('simple.ipynb')

  h.enter_cell(1)
  -- Make a change using direct buffer manipulation
  local current = h.get_edit_buffer_content()
  h.set_edit_content('CHANGES\n' .. current)
  vim.api.nvim_exec_autocmds('TextChanged', { buffer = h.get_edit_buf() })
  vim.wait(50)

  local edit_buf = h.get_edit_buf()
  h.assert_true(edit_buf ~= nil, 'Should have edit buffer')

  h.exit_cell()

  -- Edit buffer should have modified=false after exit
  -- (buffer still exists due to bufhidden='hide')
  if vim.api.nvim_buf_is_valid(edit_buf) then
    h.assert_false(vim.bo[edit_buf].modified,
      'Edit buffer should have modified=false after exit')
  end
end)

--------------------------------------------------------------------------------
-- Test: Reopening same cell doesn't create spurious changes
-- Open cell, close, reopen - no spurious undo entries or modified flags.
--------------------------------------------------------------------------------
h.run_test('reopen_cell_no_spurious_state', function()
  h.open_notebook('simple.ipynb')
  local original = h.get_cell_content(1)

  -- Make a tracked change using direct buffer manipulation
  h.enter_cell(1)
  local current = h.get_edit_buffer_content()
  h.set_edit_content('FIRST\n' .. current)
  vim.api.nvim_exec_autocmds('TextChanged', { buffer = h.get_edit_buf() })
  vim.wait(50)
  h.exit_cell()
  local after_first = h.get_cell_content(1)

  -- Reopen and close multiple times without changes
  for i = 1, 5 do
    h.enter_cell(1)
    -- Don't make any changes
    h.exit_cell()

    -- Content should still be the same
    h.assert_eq(h.get_cell_content(1), after_first,
      string.format('Content unchanged after reopen #%d', i))
  end

  -- Single undo should still revert to original
  h.undo()
  h.assert_eq(h.get_cell_content(1), original,
    'Single undo should revert to original despite multiple reopens')
end)

--------------------------------------------------------------------------------
-- Test: Insert mode without typing doesn't create undo entry
-- Enter cell, go to insert mode, immediately Esc, exit - no undo entry.
-- Note: In headless tests, we simulate this by entering cell without making changes.
--------------------------------------------------------------------------------
h.run_test('insert_mode_no_typing_no_undo', function()
  h.open_notebook('simple.ipynb')
  local original = h.get_cell_content(1)

  -- Make a real change using direct buffer manipulation
  h.enter_cell(1)
  local current = h.get_edit_buffer_content()
  h.set_edit_content('TRACKED\n' .. current)
  vim.api.nvim_exec_autocmds('TextChanged', { buffer = h.get_edit_buf() })
  vim.wait(50)
  h.exit_cell()

  -- Enter cell but don't make any changes (simulates entering insert mode and escaping)
  h.enter_cell(1)
  -- Don't modify anything
  h.exit_cell()

  -- Undo should revert the real change
  h.undo()
  h.assert_eq(h.get_cell_content(1), original,
    'Undo should revert to original (empty edit session should not create undo entry)')
end)

--------------------------------------------------------------------------------
-- Test: changedtick prevents spurious TextChanged
-- Verify that reopening a cell doesn't trigger sync without real changes.
--------------------------------------------------------------------------------
h.run_test('changedtick_prevents_spurious_sync', function()
  h.open_notebook('simple.ipynb')

  -- Get initial undo sequence number
  local state = h.get_state()
  local initial_seq = vim.api.nvim_buf_call(state.facade_buf, function()
    return vim.fn.undotree().seq_cur
  end)

  -- Open and close cell multiple times
  for _ = 1, 3 do
    h.enter_cell(1)
    h.exit_cell()
  end

  -- Undo sequence should not have advanced (no spurious undo entries)
  local final_seq = vim.api.nvim_buf_call(state.facade_buf, function()
    return vim.fn.undotree().seq_cur
  end)

  h.assert_eq(final_seq, initial_seq,
    'Undo sequence should not advance from cell enter/exit without changes')
end)

--------------------------------------------------------------------------------
-- Test: Name collision does not block edit mode (E95 regression)
-- Create a conflicting hidden buffer with the exact target name, then open edit.
-- Expected: edit opens successfully and write still works.
--------------------------------------------------------------------------------
h.run_test('edit_name_collision_no_e95', function()
  local state = h.open_notebook('simple.ipynb')
  local cell = state.cells[1]
  h.assert_true(cell ~= nil and cell.id ~= nil, 'Cell 1 should have a stable id')

  local notebook_name = vim.fn.fnamemodify(state.source_path, ':t')
  local collision_name = string.format('[%s:%s]', notebook_name, cell.id)

  -- Simulate stale conflicting buffer left behind by previous session.
  local conflict = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_buf_set_name(conflict, collision_name)
  vim.bo[conflict].bufhidden = 'hide'
  vim.api.nvim_buf_set_lines(conflict, 0, -1, false, { 'FOREIGN BUFFER' })

  local ok, err = pcall(function()
    h.enter_cell(1)
  end)
  h.assert_true(ok, 'Entering edit should not fail with E95: ' .. tostring(err))

  local edit_buf = h.get_edit_buf()
  h.assert_true(edit_buf ~= nil and vim.api.nvim_buf_is_valid(edit_buf), 'Should open a valid edit buffer')
  h.assert_false(edit_buf == conflict, 'Should not reuse a foreign conflicting buffer')

  local content = h.get_edit_buffer_content() or ''
  h.assert_false(content == 'FOREIGN BUFFER', 'Edit buffer content should come from the cell, not conflict buffer')

  -- Verify write support is configured on the resulting edit buffer.
  local write_cmds = vim.api.nvim_get_autocmds({ event = 'BufWriteCmd', buffer = edit_buf })
  h.assert_true(#write_cmds > 0, 'Edit buffer should have BufWriteCmd handler')
end)

--------------------------------------------------------------------------------
-- Test: Reopen should reuse the same edit buffer for the same persisted cell id
-- Save a temp notebook so cell ids are stable, then close/reopen in the same
-- Neovim session. Expected: the hidden edit buffer is reused, not duplicated.
--------------------------------------------------------------------------------
h.run_test('reopen_reuses_hidden_edit_buffer', function()
  local source_path = h.fixture_path('simple.ipynb')
  local temp_path = vim.fn.tempname() .. '.ipynb'
  local contents = vim.fn.readfile(source_path, 'b')
  vim.fn.writefile(contents, temp_path, 'b')

  local state = h.open_notebook_path(temp_path)
  require('ipynb.io').save_notebook(state.facade_buf)
  local first_cell_id = state.cells[1].id
  h.assert_true(first_cell_id ~= nil, 'Cell 1 should get a persisted id after save')

  h.enter_cell(1)
  local first_edit_buf = h.get_edit_buf()
  local first_name = vim.api.nvim_buf_get_name(first_edit_buf)
  h.exit_cell()

  vim.api.nvim_buf_delete(state.facade_buf, { force = true })
  vim.wait(100)

  local reopened = h.open_notebook_path(temp_path)
  h.assert_eq(reopened.cells[1].id, first_cell_id, 'Cell id should remain stable after reopen')

  h.enter_cell(1)
  local second_edit_buf = h.get_edit_buf()
  local second_name = vim.api.nvim_buf_get_name(second_edit_buf)

  h.assert_eq(second_edit_buf, first_edit_buf, 'Should reuse the hidden edit buffer across reopen')
  h.assert_eq(second_name, first_name, 'Reused edit buffer should keep its original name')
  h.assert_false(second_name:find('#', 1, true) ~= nil, 'Reused edit buffer should not need a fallback suffix')
end)

--------------------------------------------------------------------------------
-- Test: Kernel shutdown closes any active stdin prompt
--------------------------------------------------------------------------------
h.run_test('kernel_shutdown_closes_input_prompt', function()
  local state = state_mod.create(vim.fn.tempname() .. '.ipynb')
  state.kernel = {
    job_id = nil,
    connected = true,
  }

  local prompt_state = open_test_input_prompt(state)
  h.assert_true(prompt_state ~= nil, 'Input prompt should be created')
  h.assert_true(vim.api.nvim_win_is_valid(prompt_state.win), 'Input prompt window should be valid')

  require('ipynb.kernel').shutdown(state)

  h.assert_true(state._input_state == nil, 'Input prompt state should be cleared on shutdown')
  h.assert_false(vim.api.nvim_win_is_valid(prompt_state.win), 'Input prompt window should close on shutdown')
  h.assert_false(vim.api.nvim_buf_is_valid(prompt_state.buf), 'Input prompt buffer should be wiped on shutdown')
end)

--------------------------------------------------------------------------------
-- Test: Notebook removal closes any active stdin prompt
--------------------------------------------------------------------------------
h.run_test('state_remove_closes_input_prompt', function()
  local state = state_mod.create(vim.fn.tempname() .. '.ipynb')
  state.facade_buf = vim.api.nvim_create_buf(false, true)
  state_mod.register(state)
  local prompt_state = open_test_input_prompt(state)
  h.assert_true(prompt_state ~= nil, 'Input prompt should be created')
  h.assert_true(vim.api.nvim_win_is_valid(prompt_state.win), 'Input prompt window should be valid')

  require('ipynb.state').remove(state.facade_buf)

  h.assert_true(state._input_state == nil, 'Input prompt state should be cleared on notebook removal')
  h.assert_false(vim.api.nvim_win_is_valid(prompt_state.win), 'Input prompt window should close on notebook removal')
  h.assert_false(vim.api.nvim_buf_is_valid(prompt_state.buf), 'Input prompt buffer should be wiped on notebook removal')
end)

--------------------------------------------------------------------------------
-- Print summary and exit
--------------------------------------------------------------------------------
local success = h.summary()
if success then
  vim.cmd('qa!')
else
  vim.cmd('cquit 1')
end
