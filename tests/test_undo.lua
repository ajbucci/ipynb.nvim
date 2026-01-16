-- Undo behavior tests for ipynb.nvim
-- Run with: nvim --headless -u tests/minimal_init.lua -l tests/test_undo.lua

local h = require('tests.helpers')

print('')
print(string.rep('=', 60))
print('Running undo behavior tests')
print(string.rep('=', 60))
print('')

--- Helper to make a change to the current cell
---@param prefix string Text to prepend to cell content
local function make_change(prefix)
  local current = h.get_edit_buffer_content()
  h.set_edit_content(prefix .. '\n' .. current)
  vim.api.nvim_exec_autocmds('TextChanged', { buffer = h.get_edit_buf() })
  vim.wait(50)
end

--------------------------------------------------------------------------------
-- Test 1.1: Single Edit Session Undo
-- Enter cell, make changes, exit, undo once
-- Expected: Changes revert in one undo
--------------------------------------------------------------------------------
h.run_test('single_insert_session_undo', function()
  h.open_notebook('simple.ipynb')
  local original = h.get_cell_content(1)

  -- Enter cell and make changes
  h.enter_cell(1)
  h.assert_true(h.is_in_edit_float(), 'Should be in edit float')

  -- Make changes using direct buffer manipulation
  make_change('AAA BBB CCC')

  -- Verify content changed
  local modified = h.get_cell_content(1)
  h.assert_true(modified ~= original, 'Content should be modified after edit')
  h.assert_true(modified:match('AAA'), 'Should contain AAA')
  h.assert_true(modified:match('BBB'), 'Should contain BBB')
  h.assert_true(modified:match('CCC'), 'Should contain CCC')

  h.exit_cell()

  -- Single undo should revert changes
  h.undo()
  local after_undo = h.get_cell_content(1)
  h.assert_eq(after_undo, original, 'Single undo should revert edit session')
end)

--------------------------------------------------------------------------------
-- Test 1.2: Multi-Cell Edit Undo Chain
-- Edit cell A, exit. Edit cell B, exit. Edit cell A again, exit.
-- Undo three times - each should revert one edit session in reverse order.
--------------------------------------------------------------------------------
h.run_test('multi_cell_undo_chain', function()
  h.open_notebook('simple.ipynb')

  local original_a = h.get_cell_content(1)
  local original_b = h.get_cell_content(2)

  -- Edit cell 1 (A)
  h.enter_cell(1)
  make_change('AAA')
  h.exit_cell()
  local after_edit_a1 = h.get_cell_content(1)
  h.assert_true(after_edit_a1:match('AAA'), 'Cell 1 should have AAA')

  -- Edit cell 2 (B)
  h.enter_cell(2)
  make_change('BBB')
  h.exit_cell()
  local after_edit_b = h.get_cell_content(2)
  h.assert_true(after_edit_b:match('BBB'), 'Cell 2 should have BBB')

  -- Edit cell 1 again
  h.enter_cell(1)
  make_change('CCC')
  h.exit_cell()
  local after_edit_a2 = h.get_cell_content(1)
  h.assert_true(after_edit_a2:match('CCC'), 'Cell 1 should have CCC')

  -- Undo 1: should revert cell 1's second edit (CCC)
  h.undo()
  h.assert_eq(h.get_cell_content(1), after_edit_a1, 'Undo 1: Cell 1 back to first edit')
  h.assert_eq(h.get_cell_content(2), after_edit_b, 'Undo 1: Cell 2 unchanged')

  -- Undo 2: should revert cell 2's edit (BBB)
  h.undo()
  h.assert_eq(h.get_cell_content(1), after_edit_a1, 'Undo 2: Cell 1 unchanged')
  h.assert_eq(h.get_cell_content(2), original_b, 'Undo 2: Cell 2 back to original')

  -- Undo 3: should revert cell 1's first edit (AAA)
  h.undo()
  h.assert_eq(h.get_cell_content(1), original_a, 'Undo 3: Cell 1 back to original')
  h.assert_eq(h.get_cell_content(2), original_b, 'Undo 3: Cell 2 still original')
end)

--------------------------------------------------------------------------------
-- Test 1.3: Undo Within Edit Float
-- Enter cell, make changes, undo while still in float.
-- Expected: Edit buffer reflects original content after undo.
--------------------------------------------------------------------------------
h.run_test('undo_within_edit_float', function()
  h.open_notebook('simple.ipynb')
  local original = h.get_cell_content(1)

  h.enter_cell(1)
  make_change('NEW CONTENT')

  -- Still in edit float
  h.assert_true(h.is_in_edit_float(), 'Should still be in edit float')

  -- Verify change happened
  local modified = h.get_cell_content(1)
  h.assert_true(modified:match('NEW CONTENT'), 'Should have new content')

  -- Undo while in edit float (uses global_undo)
  h.undo()

  -- Edit buffer should now show original content
  local edit_content = h.get_edit_buffer_content()
  h.assert_eq(edit_content, original, 'Edit buffer should reflect undo')

  -- Cell state should also be original
  h.assert_eq(h.get_cell_content(1), original, 'Cell state should reflect undo')
end)

--------------------------------------------------------------------------------
-- Test 1.4: Redo After Undo
-- Make changes, undo, redo.
-- Expected: Content is restored after redo.
--------------------------------------------------------------------------------
h.run_test('undo_redo_cycle', function()
  h.open_notebook('simple.ipynb')
  local original = h.get_cell_content(1)

  h.enter_cell(1)
  make_change('REDO TEST')
  h.exit_cell()

  local modified = h.get_cell_content(1)
  h.assert_true(modified:match('REDO TEST'), 'Should have modified content')

  h.undo()
  h.assert_eq(h.get_cell_content(1), original, 'After undo: should be original')

  h.redo()
  h.assert_eq(h.get_cell_content(1), modified, 'After redo: should be modified')
end)

--------------------------------------------------------------------------------
-- Test 1.5: Multiple Undo/Redo Cycles
-- Make multiple changes, undo all, redo all.
--------------------------------------------------------------------------------
h.run_test('multiple_undo_redo_cycles', function()
  h.open_notebook('simple.ipynb')
  local original = h.get_cell_content(1)

  -- Make 3 separate changes
  h.enter_cell(1)
  make_change('ONE')
  h.exit_cell()
  local state1 = h.get_cell_content(1)

  h.enter_cell(1)
  make_change('TWO')
  h.exit_cell()
  local state2 = h.get_cell_content(1)

  h.enter_cell(1)
  make_change('THREE')
  h.exit_cell()
  local state3 = h.get_cell_content(1)

  -- Undo all
  h.undo()
  h.assert_eq(h.get_cell_content(1), state2, 'Undo to state2')
  h.undo()
  h.assert_eq(h.get_cell_content(1), state1, 'Undo to state1')
  h.undo()
  h.assert_eq(h.get_cell_content(1), original, 'Undo to original')

  -- Redo all
  h.redo()
  h.assert_eq(h.get_cell_content(1), state1, 'Redo to state1')
  h.redo()
  h.assert_eq(h.get_cell_content(1), state2, 'Redo to state2')
  h.redo()
  h.assert_eq(h.get_cell_content(1), state3, 'Redo to state3')
end)

--------------------------------------------------------------------------------
-- Test 1.6: Undo Across Different Cells
-- Edit different cells, verify undo only affects correct cell.
--------------------------------------------------------------------------------
h.run_test('undo_isolation_between_cells', function()
  h.open_notebook('three_cells.ipynb')

  local orig1 = h.get_cell_content(1)
  local orig2 = h.get_cell_content(2)
  local orig3 = h.get_cell_content(3)

  -- Modify only cell 2
  h.enter_cell(2)
  make_change('MODIFIED')
  h.exit_cell()

  -- Verify only cell 2 changed
  h.assert_eq(h.get_cell_content(1), orig1, 'Cell 1 should be unchanged')
  h.assert_true(h.get_cell_content(2):match('MODIFIED'), 'Cell 2 should be modified')
  h.assert_eq(h.get_cell_content(3), orig3, 'Cell 3 should be unchanged')

  -- Undo
  h.undo()

  -- All cells should be original
  h.assert_eq(h.get_cell_content(1), orig1, 'Cell 1 still original after undo')
  h.assert_eq(h.get_cell_content(2), orig2, 'Cell 2 back to original after undo')
  h.assert_eq(h.get_cell_content(3), orig3, 'Cell 3 still original after undo')
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
