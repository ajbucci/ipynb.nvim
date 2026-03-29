-- Focused tests for shadow file write behavior

local h = require('tests.helpers')

print('=' .. string.rep('=', 59))
print('Running shadow write tests')
print('=' .. string.rep('=', 59))

h.run_test('shadow_write_is_debounced', function()
  h.open_notebook('mixed.ipynb')
  local state = h.get_state()
  local cells_mod = require('ipynb.cells')
  local shadow = require('ipynb.lsp.shadow')

  local cfg = require('ipynb.config').get()
  local prev_delay = cfg.shadow.debounce_ms
  cfg.shadow.debounce_ms = 400

  local content_start, content_end = cells_mod.get_content_range(state, 1)
  h.assert_true(content_start ~= nil and content_end ~= nil, 'Cell content range should exist')

  local before_disk = vim.fn.readfile(state.shadow_path)
  local probe = '__debounce_probe__'
  shadow.sync_shadow_region(state, content_start, content_end + 1, { probe }, 'code')

  -- Shadow buffer should update immediately (for LSP responsiveness).
  local in_memory = vim.api.nvim_buf_get_lines(state.shadow_buf, content_start, content_start + 1, false)[1]
  h.assert_eq(in_memory, probe, 'Shadow buffer should update immediately')

  -- Shadow file should not update immediately (debounced disk write).
  local immediate_disk = vim.fn.readfile(state.shadow_path)
  h.assert_eq(table.concat(immediate_disk, '\n'), table.concat(before_disk, '\n'),
    'Shadow file should not be written immediately')

  local wrote = vim.wait(1500, function()
    local lines = vim.fn.readfile(state.shadow_path)
    return lines[content_start + 1] == probe
  end, 50)
  h.assert_true(wrote, 'Debounced shadow write should flush to disk')

  cfg.shadow.debounce_ms = prev_delay
end)

h.run_test('flush_shadow_write_forces_disk_sync', function()
  h.open_notebook('mixed.ipynb')
  local state = h.get_state()
  local cells_mod = require('ipynb.cells')
  local shadow = require('ipynb.lsp.shadow')

  local cfg = require('ipynb.config').get()
  local prev_delay = cfg.shadow.debounce_ms
  cfg.shadow.debounce_ms = 400

  local content_start, content_end = cells_mod.get_content_range(state, 1)
  h.assert_true(content_start ~= nil and content_end ~= nil, 'Cell content range should exist')

  local probe = '__flush_probe__'
  shadow.sync_shadow_region(state, content_start, content_end + 1, { probe }, 'code')
  shadow.flush_shadow_write(state)

  local disk_lines = vim.fn.readfile(state.shadow_path)
  h.assert_eq(disk_lines[content_start + 1], probe, 'Flush should write pending shadow changes immediately')

  cfg.shadow.debounce_ms = prev_delay
end)

local success = h.summary()
if success then
  vim.cmd('qa!')
else
  vim.cmd('cquit 1')
end
