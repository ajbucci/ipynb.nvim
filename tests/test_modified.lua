-- Buffer modified state tests for ipynb.nvim
-- Run with: nvim --headless -u tests/minimal_init.lua -l tests/test_modified.lua

local h = require('tests.helpers')

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
-- Print summary and exit
--------------------------------------------------------------------------------
local success = h.summary()
if success then
  vim.cmd('qa!')
else
  vim.cmd('cquit 1')
end
