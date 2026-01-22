-- LSP proxy tests for Go (selectionRange)
-- Run with: nvim --headless -u tests/minimal_init.lua -l tests/test_lsp_go.lua
--
-- NOTE: Requires gopls to be configured via tests/minimal_init.lua

local h = require('tests.helpers')

print('')
print(string.rep('=', 60))
print('Running LSP Go tests')
print(string.rep('=', 60))
print('')

-- Helper: Wait for LSP to attach to shadow buffer
local function wait_for_lsp(timeout_ms)
  timeout_ms = timeout_ms or 10000
  local state = h.get_state()
  if not state or not state.shadow_buf then
    return false
  end

  local attached = vim.wait(timeout_ms, function()
    return #vim.lsp.get_clients({ bufnr = state.shadow_buf }) > 0
  end, 100)

  return attached
end

-- Helper: check if any client supports a method
local function lsp_supports_method(state, method)
  local clients = vim.lsp.get_clients({ bufnr = state.shadow_buf })
  for _, client in ipairs(clients) do
    if client.supports_method then
      local ok = client:supports_method(method, { bufnr = state.shadow_buf })
      if ok then
        return true
      end
      if client:supports_method(method) then
        return true
      end
    end
  end
  return false
end

-- Helper: Check if LSP is available
local function lsp_available()
  h.open_notebook('lsp_test_go.ipynb')
  local has_lsp = wait_for_lsp(5000)
  h.close_all_notebooks()
  return has_lsp
end

-- Check LSP availability once
local HAS_LSP = lsp_available()
if not HAS_LSP then
  print('  WARN: No Go LSP server found. gopls tests require:')
  print('        - gopls in PATH, OR')
  print('        - IPYNB_TEST_LSP_BIN set to gopls')
  print('')
  print(string.rep('=', 60))
  print('Results: 0 passed, 0 failed (gopls tests skipped)')
  print(string.rep('=', 60))
  vim.cmd('qa!')
end

--------------------------------------------------------------------------------
-- Test: Selection range handler uses facade buffer
--------------------------------------------------------------------------------
h.run_test('selection_range_facade_handler_go', function()
  h.open_notebook('lsp_test_go.ipynb')
  h.assert_true(wait_for_lsp(), 'LSP should attach')

  local state = h.get_state()
  if not lsp_supports_method(state, 'textDocument/selectionRange') then
    print('  SKIP: selectionRange not supported by gopls')
    return
  end

  -- Position cursor on "add"
  local cells_mod = require('ipynb.cells')
  local content_start, _ = cells_mod.get_content_range(state, 1)
  vim.api.nvim_win_set_cursor(0, { content_start + 3, 5 })

  local seen_bufnr = nil
  local got_result = false

  local function handler(err, result, ctx, config)
    if ctx and ctx.bufnr then
      seen_bufnr = ctx.bufnr
    end
    got_result = true
  end

  local params = vim.lsp.util.make_position_params()
  params.positions = { params.position }
  params.position = nil
  vim.lsp.buf_request(state.facade_buf, 'textDocument/selectionRange', params, handler)

  vim.wait(5000, function() return got_result end, 100)

  h.assert_true(got_result, 'Should get selectionRange response')
  h.assert_eq(seen_bufnr, state.facade_buf, 'Selection range should target facade buffer')
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
