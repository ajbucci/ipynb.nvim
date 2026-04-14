-- Cell boundary tests for ipynb.nvim
-- Run with: nvim --headless -u tests/minimal_init.lua -l tests/test_cells.lua

local h = require('tests.helpers')

print('')
print(string.rep('=', 60))
print('Running cell boundary tests')
print(string.rep('=', 60))
print('')

--------------------------------------------------------------------------------
-- Test: Extmark positions after single cell edit
-- Edit cell 2 of 3, adding lines.
-- Expected: All cell boundaries remain correct.
--------------------------------------------------------------------------------
h.run_test('cell_boundaries_after_edit', function()
  h.open_notebook('three_cells.ipynb')

  local initial_ranges = h.get_all_cell_ranges()
  h.assert_eq(#initial_ranges, 3, 'Should have 3 cells')

  -- Record initial values
  local cell1_end = initial_ranges[1]['end']
  local cell2_start = initial_ranges[2].start
  local cell2_end = initial_ranges[2]['end']
  local cell3_start = initial_ranges[3].start
  local cell3_end = initial_ranges[3]['end']

  -- Add a line to cell 2 using direct buffer manipulation
  h.enter_cell(2)
  h.append_line_to_edit('new line')
  h.exit_cell()

  local updated_ranges = h.get_all_cell_ranges()

  -- Cell 1 should be unchanged
  h.assert_eq(updated_ranges[1].start, initial_ranges[1].start, 'Cell 1 start unchanged')
  h.assert_eq(updated_ranges[1]['end'], cell1_end, 'Cell 1 end unchanged')

  -- Cell 2 start should be unchanged, end should be 1 line later
  h.assert_eq(updated_ranges[2].start, cell2_start, 'Cell 2 start unchanged')
  h.assert_eq(updated_ranges[2]['end'], cell2_end + 1, 'Cell 2 end shifted by 1')

  -- Cell 3 should be shifted down by 1
  h.assert_eq(updated_ranges[3].start, cell3_start + 1, 'Cell 3 start shifted by 1')
  h.assert_eq(updated_ranges[3]['end'], cell3_end + 1, 'Cell 3 end shifted by 1')
end)

--------------------------------------------------------------------------------
-- Test: get_cell_at_line accuracy
-- Query cell index at various line positions.
-- Expected: Correct cell index for each position.
--------------------------------------------------------------------------------
h.run_test('get_cell_at_line_accuracy', function()
  h.open_notebook('three_cells.ipynb')

  local state = h.get_state()
  local cells_mod = require('ipynb.cells')
  local ranges = h.get_all_cell_ranges()

  -- Test at each cell's content region
  for i, range in ipairs(ranges) do
    -- Test at content start
    local idx_at_start = cells_mod.get_cell_at_line(state, range.content_start)
    h.assert_eq(idx_at_start, i, string.format('Cell %d content_start should map to cell %d', i, i))

    -- Test at content end
    local idx_at_end = cells_mod.get_cell_at_line(state, range.content_end)
    h.assert_eq(idx_at_end, i, string.format('Cell %d content_end should map to cell %d', i, i))

    -- Test at cell start marker
    local idx_at_marker = cells_mod.get_cell_at_line(state, range.start)
    h.assert_eq(idx_at_marker, i, string.format('Cell %d start marker should map to cell %d', i, i))
  end
end)

--------------------------------------------------------------------------------
-- Test: Content range vs full range
-- Get content range excludes markers.
-- Expected: Content range is 2 lines smaller than full range.
--------------------------------------------------------------------------------
h.run_test('content_vs_full_range', function()
  h.open_notebook('simple.ipynb')

  local cells_mod = require('ipynb.cells')
  local state = h.get_state()

  for i = 1, #state.cells do
    local full_start, full_end = cells_mod.get_cell_range(state, i)
    local content_start, content_end = cells_mod.get_content_range(state, i)

    h.assert_eq(content_start, full_start + 1,
      string.format('Cell %d: content starts after start marker', i))
    h.assert_eq(content_end, full_end - 1,
      string.format('Cell %d: content ends before end marker', i))
  end
end)

--------------------------------------------------------------------------------
-- Test: Cell boundaries preserved through edit + undo
-- Make edit, undo, verify boundaries match original.
--------------------------------------------------------------------------------
h.run_test('boundaries_preserved_through_undo', function()
  h.open_notebook('three_cells.ipynb')

  local initial_ranges = h.get_all_cell_ranges()
  local state = h.get_state()
  local initial_count = #state.cells

  -- Make an edit to cell 2
  h.enter_cell(2)
  h.append_line_to_edit('extra line')
  h.exit_cell()

  -- Verify cell count unchanged (just content changed)
  state = h.get_state()
  h.assert_eq(#state.cells, initial_count, 'Cell count should be unchanged after edit')

  -- Undo the edit
  h.undo()
  vim.wait(50)

  -- Should still have same number of cells
  state = h.get_state()
  h.assert_eq(#state.cells, initial_count, 'Cell count should be unchanged after undo')

  -- Verify ranges are restored
  local restored_ranges = h.get_all_cell_ranges()
  h.assert_eq(#restored_ranges, #initial_ranges, 'Should have same number of cell ranges')

  -- Check each range matches original
  for i, orig in ipairs(initial_ranges) do
    h.assert_eq(restored_ranges[i].start, orig.start,
      string.format('Cell %d start should be restored', i))
    h.assert_eq(restored_ranges[i]['end'], orig['end'],
      string.format('Cell %d end should be restored', i))
  end
end)

--------------------------------------------------------------------------------
-- Test: Shadow and facade line changes are in sync
-- After edits, shadow and facade change by the same amount.
-- Note: Facade may have trailing blank line that shadow doesn't have.
--------------------------------------------------------------------------------
h.run_test('shadow_facade_line_sync', function()
  h.open_notebook('simple.ipynb')

  -- Record initial state
  local initial_facade = h.get_facade_line_count()
  local initial_shadow = h.get_shadow_line_count()

  -- After adding lines - both should grow by same amount
  h.enter_cell(1)

  local facade_before = h.get_facade_line_count()
  local shadow_before = h.get_shadow_line_count()

  -- Add 2 lines using direct buffer manipulation
  h.append_line_to_edit('new line 1')
  h.append_line_to_edit('new line 2')

  local facade_after = h.get_facade_line_count()
  local shadow_after = h.get_shadow_line_count()

  local facade_growth = facade_after - facade_before
  local shadow_growth = shadow_after - shadow_before

  h.assert_eq(facade_growth, shadow_growth,
    string.format('Adding lines: facade grew by %d, shadow grew by %d', facade_growth, shadow_growth))

  h.exit_cell()

  -- After edit session, verify both buffers changed consistently
  local final_facade = h.get_facade_line_count()
  local final_shadow = h.get_shadow_line_count()

  h.assert_eq(final_facade - initial_facade, final_shadow - initial_shadow,
    'Total change should be same for facade and shadow')
end)

--------------------------------------------------------------------------------
-- Test: Edit overlay height tracks wrapped display height
-- With wrap enabled, a single logical line can occupy multiple screen rows.
-- Expected: the edit float grows to fully cover the wrapped facade content.
--------------------------------------------------------------------------------
h.run_test('edit_overlay_matches_wrapped_height', function()
  if not vim.api.nvim_win_text_height then
    return
  end

  h.open_notebook('mixed.ipynb')
  vim.wo[0].wrap = true

  h.enter_cell(3)

  local state = h.get_state()
  local edit = state.edit_state
  local long_line = table.concat({
    'This is a very long markdown line that should wrap several times in the',
    'facade window so the edit overlay has to account for rendered screen rows,',
    'not just the underlying buffer line count.',
  }, ' ')

  vim.api.nvim_buf_set_lines(edit.buf, 0, -1, false, { long_line })
  vim.api.nvim_exec_autocmds('TextChanged', { buffer = edit.buf })
  vim.wait(50)

  state = h.get_state()
  edit = state.edit_state

  local facade_height = vim.api.nvim_win_text_height(edit.parent_win, {
    start_row = edit.start_line,
    end_row = edit.end_line,
  }).all
  local edit_height = vim.api.nvim_win_get_height(edit.win)

  h.assert_true(vim.wo[edit.win].wrap, 'Edit overlay should inherit wrap from the facade window')
  h.assert_true(facade_height > 1, 'Fixture line should wrap to multiple screen rows')
  h.assert_eq(edit_height, facade_height,
    string.format('Edit overlay height (%d) should match wrapped facade height (%d)', edit_height, facade_height))
end)

--------------------------------------------------------------------------------
-- Test: Edit overlay width tracks parent window resizing
-- Creating a split shrinks the parent notebook window.
-- Expected: the overlay width updates instead of spilling into the neighbor.
--------------------------------------------------------------------------------
h.run_test('edit_overlay_resizes_with_parent_window', function()
  h.open_notebook('mixed.ipynb')
  h.enter_cell(1)

  local state = h.get_state()
  local facade_buf = state.facade_buf
  local edit = state.edit_state
  local initial_width = vim.api.nvim_win_get_config(edit.win).width

  vim.api.nvim_set_current_win(edit.parent_win)
  vim.cmd('vsplit')
  vim.wait(50)

  state = require('ipynb.state').get_by_facade(facade_buf)
  edit = state.edit_state

  local parent_width = vim.api.nvim_win_get_width(edit.parent_win)
  local textoff = (vim.fn.getwininfo(edit.parent_win)[1] or {}).textoff or 0
  local expected_width = math.max(parent_width - textoff, 1)
  local edit_width = vim.api.nvim_win_get_config(edit.win).width

  h.assert_true(parent_width < initial_width, 'Parent window should shrink after creating a split')
  h.assert_eq(edit_width, expected_width,
    string.format('Edit overlay width (%d) should match parent text width (%d)', edit_width, expected_width))
end)

--------------------------------------------------------------------------------
-- Test: Edit overlay closes if the parent window switches to another buffer
-- Opening another file in the same window should not leave the notebook cell visible.
-- Expected: the edit float closes as soon as the parent window stops showing the facade.
--------------------------------------------------------------------------------
h.run_test('edit_overlay_closes_on_parent_buffer_switch', function()
  h.open_notebook('mixed.ipynb')
  h.enter_cell(1)

  local state = h.get_state()
  local facade_buf = state.facade_buf
  local edit = state.edit_state

  local foreign = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_lines(foreign, 0, -1, false, { 'a,b,c', '1,2,3' })
  vim.bo[foreign].filetype = 'csv'
  vim.api.nvim_win_set_buf(edit.parent_win, foreign)
  vim.wait(50)

  state = require('ipynb.state').get_by_facade(facade_buf)
  h.assert_true(state ~= nil, 'Notebook state should persist while the facade buffer is hidden')
  h.assert_true(state.edit_state == nil, 'Edit state should close when the parent window switches away')
  h.assert_false(vim.api.nvim_win_is_valid(edit.win), 'Edit float should close when the parent window switches away')
end)

--------------------------------------------------------------------------------
-- Test: Cell count matches facade parsing
-- Number of cells in state matches what jupytext_to_cells would return.
--------------------------------------------------------------------------------
h.run_test('cell_count_consistency', function()
  h.open_notebook('mixed.ipynb')

  local state = h.get_state()
  local io_mod = require('ipynb.io')

  -- Get lines from facade
  local lines = vim.api.nvim_buf_get_lines(state.facade_buf, 0, -1, false)

  -- Parse them again
  local parsed_cells = io_mod.jupytext_to_cells(lines)

  h.assert_eq(#state.cells, #parsed_cells,
    'State cells count should match re-parsed cells count')
end)

--------------------------------------------------------------------------------
-- Test: Mixed cell types have correct boundaries
-- Markdown and code cells both tracked correctly.
--------------------------------------------------------------------------------
h.run_test('mixed_cell_type_boundaries', function()
  h.open_notebook('mixed.ipynb')

  local state = h.get_state()
  local cells_mod = require('ipynb.cells')

  -- Verify each cell has valid boundaries
  for i, cell in ipairs(state.cells) do
    local start_line, end_line = cells_mod.get_cell_range(state, i)
    local content_start, content_end = cells_mod.get_content_range(state, i)

    h.assert_true(start_line ~= nil, string.format('Cell %d should have start_line', i))
    h.assert_true(end_line ~= nil, string.format('Cell %d should have end_line', i))
    h.assert_true(start_line < end_line,
      string.format('Cell %d: start (%d) should be before end (%d)', i, start_line, end_line))
    h.assert_true(content_start >= start_line,
      string.format('Cell %d: content_start should be >= start', i))
    h.assert_true(content_end <= end_line,
      string.format('Cell %d: content_end should be <= end', i))
  end

  -- Verify cell types
  h.assert_eq(state.cells[1].type, 'markdown', 'Cell 1 should be markdown')
  h.assert_eq(state.cells[2].type, 'code', 'Cell 2 should be code')
  h.assert_eq(state.cells[3].type, 'markdown', 'Cell 3 should be markdown')
  h.assert_eq(state.cells[4].type, 'code', 'Cell 4 should be code')
end)

--------------------------------------------------------------------------------
-- Print summary and exit
--------------------------------------------------------------------------------
local success = h.summary()
if success then
  vim.cmd('qa!')
else
  -- Exit with error code
  vim.cmd('cquit 1')
end
