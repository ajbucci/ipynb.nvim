-- Focused tests for cell output stream handling

local h = require('tests.helpers')
local output = require('ipynb.output')

print('=' .. string.rep('=', 59))
print('Running output stream tests')
print('=' .. string.rep('=', 59))

local function stream(name, text)
  return {
    output_type = 'stream',
    name = name,
    text = text,
  }
end

h.run_test('tqdm_updates_replace_the_current_line', function()
  local cell = { outputs = {} }
  local updates = {
    '\r  0%|          | 0/5 [00:00<?, ?it/s]',
    '\r 20%|██        | 1/5 [00:01<00:04, 1.00s/it]',
    '\r 40%|████      | 2/5 [00:02<00:03, 1.00s/it]',
    '\r 60%|██████    | 3/5 [00:03<00:02, 1.00s/it]',
    '\r 80%|████████  | 4/5 [00:04<00:01, 1.00s/it]',
    '\r100%|██████████| 5/5 [00:05<00:00, 1.00s/it]',
    '\r100%|██████████| 5/5 [00:05<00:00, 1.00s/it]',
    '\n',
  }

  for _, text in ipairs(updates) do
    output.append_output(cell, stream('stderr', text))
  end

  h.assert_eq(#cell.outputs, 1, 'Adjacent tqdm updates should be coalesced')
  h.assert_eq(
    cell.outputs[1].text,
    '100%|██████████| 5/5 [00:05<00:00, 1.00s/it]\n',
    'Only the final progress bar state should remain'
  )
  h.assert_true(not cell.outputs[1].text:find('\r', 1, true), 'Carriage returns should not remain')
end)

h.run_test('stream_updates_remain_visible_while_running', function()
  local cell = { outputs = {} }

  output.append_output(cell, stream('stderr', '\r  0%|          | 0/5'))
  h.assert_eq(cell.outputs[1].text, '  0%|          | 0/5')

  output.append_output(cell, stream('stderr', '\r 20%|██        | 1/5'))
  h.assert_eq(#cell.outputs, 1)
  h.assert_eq(cell.outputs[1].text, ' 20%|██        | 1/5')
end)

h.run_test('ordinary_stream_lines_are_preserved', function()
  local cell = { outputs = {} }

  output.append_output(cell, stream('stdout', 'before\n'))
  output.append_output(cell, stream('stdout', '\r0%'))
  output.append_output(cell, stream('stdout', '\r100%'))
  output.append_output(cell, stream('stdout', '\nafter\n'))

  h.assert_eq(#cell.outputs, 1)
  h.assert_eq(cell.outputs[1].text, 'before\n100%\nafter\n')
end)

h.run_test('carriage_return_cursor_is_preserved_across_chunks', function()
  local cell = { outputs = {} }

  output.append_output(cell, stream('stdout', 'abcdef'))
  output.append_output(cell, stream('stdout', '\r12'))
  output.append_output(cell, stream('stdout', '34'))

  h.assert_eq(cell.outputs[1].text, '1234ef')
end)

h.run_test('different_streams_and_rich_outputs_are_not_coalesced', function()
  local cell = { outputs = {} }

  output.append_output(cell, stream('stdout', 'out'))
  output.append_output(cell, stream('stderr', 'err'))
  output.append_output(cell, {
    output_type = 'execute_result',
    data = { ['text/plain'] = '42' },
  })
  output.append_output(cell, stream('stderr', 'later'))

  h.assert_eq(#cell.outputs, 4, 'Only adjacent streams with the same name should coalesce')
  h.assert_eq(cell.outputs[1].text, 'out')
  h.assert_eq(cell.outputs[2].text, 'err')
  h.assert_eq(cell.outputs[4].text, 'later')
end)

h.run_test('clear_outputs_resets_stream_cursor_state', function()
  local cell = { id = 'output-test', outputs = {} }
  local state = { cells = { cell } }

  output.append_output(cell, stream('stderr', '\r50%'))
  h.assert_true(cell._stream_state ~= nil)

  output.clear_outputs(state, 1)

  h.assert_eq(#cell.outputs, 0)
  h.assert_eq(cell._stream_state, nil)
end)

h.run_test('colorscheme_change_redraws_image_outputs', function()
  local images = require('ipynb.images')
  local supports, image_lines = images.supports_placeholders, images.get_image_virt_lines
  local drawn = 0
  images.supports_placeholders = function()
    return true
  end
  images.get_image_virt_lines = function()
    drawn = drawn + 1
    return { { { '[image]', 'Normal' } } }, 1
  end
  local ok, err = xpcall(function()
    h.close_all_notebooks()
    local path = vim.fn.tempname() .. '.ipynb'
    vim.fn.writefile({ vim.json.encode({
      nbformat = 4,
      nbformat_minor = 5,
      metadata = vim.empty_dict(),
      cells = { {
        cell_type = 'code',
        id = 'c1',
        metadata = vim.empty_dict(),
        execution_count = 1,
        source = { 'plot()' },
        outputs = { {
          output_type = 'display_data',
          metadata = vim.empty_dict(),
          data = { ['image/png'] = 'iVBORw0KGgo=', ['text/plain'] = { '<Figure>' } },
        } },
      } },
    }) }, path)
    h.open_notebook_path(path)
    local before = drawn
    h.assert_true(before > 0, 'The image should be drawn on open')

    -- A colorscheme clears the highlight groups placeholders are drawn with.
    vim.api.nvim_exec_autocmds('ColorScheme', {})
    h.assert_true(drawn > before, 'The image should be drawn again')
  end, debug.traceback)
  images.supports_placeholders, images.get_image_virt_lines = supports, image_lines
  assert(ok, err)
end)

local success = h.summary()
if success then
  vim.cmd('qa!')
else
  vim.cmd('cquit 1')
end
