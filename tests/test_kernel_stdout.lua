-- Exercise the real job pipe and production stdout handler without Jupyter.
-- Run: nvim --headless -u tests/minimal_init.lua -l tests/test_kernel_stdout.lua

local h = require('tests.helpers')
local kernel = require('ipynb.kernel')
local output = require('ipynb.output')
local tests_dir = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h')

print(string.rep('=', 60))
print('Running kernel stdout tests')
print(string.rep('=', 60))

h.run_test('large_image_survives_natural_pipe_chunking', function()
  local state = {
    cells = {
      { id = 'before', outputs = {} },
      { id = 'image', outputs = {} },
      { id = 'after', outputs = {} },
    },
  }
  local jobstart = vim.fn.jobstart
  local render_outputs = output.render_outputs
  local job_id, exit_code
  local callbacks = 0
  local partial_callbacks = 0
  local rendered = {}
  local ok, err = xpcall(function()
    -- Keep output routing and storage real; bypass terminal image rendering.
    output.render_outputs = function(_, idx)
      rendered[#rendered + 1] = idx
    end
    vim.fn.jobstart = function(_, opts)
      local on_stdout, on_exit = opts.on_stdout, opts.on_exit
      opts.on_stdout = function(id, data, event)
        -- Observe the real read boundaries before the handler mutates data.
        if #data > 1 or (data[1] and data[1] ~= '') then
          callbacks = callbacks + 1
        end
        if data[#data] and data[#data] ~= '' then
          partial_callbacks = partial_callbacks + 1
        end
        on_stdout(id, data, event)
      end
      opts.on_exit = function(id, code, event)
        exit_code = code
        on_exit(id, code, event)
      end
      -- Only substitute the command, preserving the production job options.
      job_id = jobstart({
        vim.v.progpath, '--headless', '-u', 'NONE', '-i', 'NONE',
        '-l', tests_dir .. '/fixtures/kernel_stdout_emitter.lua',
      }, opts)
      return job_id
    end

    assert(kernel.start_bridge(state, vim.v.progpath), 'Bridge job should start')
    assert(vim.wait(10000, function()
      return exit_code ~= nil
    end, 10), 'Emitter timed out')
    -- Drain the scheduled output handlers after the process exits.
    assert(vim.wait(1000, function()
      return #state.cells[3].outputs == 1
    end, 10), 'Trailing output should arrive')
    h.assert_eq(exit_code, 0, 'Emitter should exit successfully')
    print(string.format(
      '  Pipe delivered %d data callbacks; %d ended mid-message',
      callbacks,
      partial_callbacks
    ))
    h.assert_true(partial_callbacks > 0, 'Expected the large message to fragment naturally on this platform')
    h.assert_eq(#state.cells[1].outputs, 1, 'Leading output should arrive once')
    h.assert_eq(state.cells[1].outputs[1].text, 'before\n')
    h.assert_eq(state.cells[3].outputs[1].text, 'after\n')
    h.assert_eq(#state.cells[2].outputs, 1, '700 KB image was lost across stdout callbacks')
    h.assert_eq(
      state.cells[2].outputs[1].data['image/png'],
      string.rep('QUJD', 175000),
      'Image payload should arrive intact'
    )
    h.assert_eq(table.concat(rendered, ','), '1,2,3', 'Outputs should render once, in order')
  end, debug.traceback)

  vim.fn.jobstart = jobstart
  if job_id and job_id > 0 and exit_code == nil then
    vim.fn.jobstop(job_id)
    vim.fn.jobwait({ job_id }, 1000)
  end
  output.render_outputs = render_outputs
  assert(ok, err)
end)

if h.summary() then
  vim.cmd('qa!')
else
  vim.cmd('cquit 1')
end
