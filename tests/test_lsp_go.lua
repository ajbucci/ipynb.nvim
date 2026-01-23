-- LSP proxy tests for Go (selectionRange)
-- Run with: nvim --headless -u tests/minimal_init.lua -l tests/test_lsp_go.lua
--
-- NOTE: Requires gopls to be configured via tests/minimal_init.lua

local h = require('tests.helpers')
require('ipynb').setup({ shadow = { location = 'workspace', dir = 'ipynb.nvim' } })

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
-- Test: Call hierarchy (incoming/outgoing) from facade buffer
--------------------------------------------------------------------------------
h.run_test('call_hierarchy_facade_go', function()
  h.open_notebook('lsp_test_go.ipynb')
  h.assert_true(wait_for_lsp(), 'LSP should attach')

  local state = h.get_state()
  if not lsp_supports_method(state, 'textDocument/prepareCallHierarchy') then
    print('  SKIP: prepareCallHierarchy not supported by gopls')
    return
  end

  -- Position cursor on "add" in function definition (for incoming calls)
  local cells_mod = require('ipynb.cells')
  local content_start, content_end = cells_mod.get_content_range(state, 1)
  local lines = vim.api.nvim_buf_get_lines(state.facade_buf, content_start, content_end + 1, false)
  local add_line = nil
  local add_col = nil
  local main_line = nil
  local main_col = nil
  for i, line in ipairs(lines) do
    local col_add = line:find('func add', 1, true)
    if col_add then
      local name_col = line:find('add', col_add, true)
      add_line = content_start + (i - 1) + 1
      add_col = (name_col or col_add) - 1
    end
    local col_main = line:find('func main', 1, true)
    if col_main then
      local name_col = line:find('main', col_main, true)
      main_line = content_start + (i - 1) + 1
      main_col = (name_col or col_main) - 1
    end
  end
  h.assert_true(add_line ~= nil, 'Should find add() definition')
  h.assert_true(main_line ~= nil, 'Should find main() definition')

  -- Prepare call hierarchy on add (incoming should include main)
  vim.api.nvim_win_set_cursor(0, { add_line, add_col })

  local got_prepare = false
  local prepare_items = nil
  local prepare_ctx_buf = nil
  local prepare_err = nil

  local clients = vim.lsp.get_clients({ bufnr = state.shadow_buf })
  h.assert_true(#clients > 0, 'Should have LSP clients for shadow buffer')
  local params = vim.lsp.util.make_position_params(0, clients[1].offset_encoding)
  vim.lsp.buf_request(state.facade_buf, 'textDocument/prepareCallHierarchy', params, function(err, result, ctx)
    got_prepare = true
    prepare_items = result
    prepare_ctx_buf = ctx and ctx.bufnr
    prepare_err = err
  end)

  vim.wait(5000, function() return got_prepare end, 100)
  h.assert_true(got_prepare, 'Should get prepareCallHierarchy response')
  if not prepare_items then
    print('  DEBUG: prepareCallHierarchy(add) err=' .. tostring(prepare_err))
    print('  DEBUG: prepareCallHierarchy(add) ctx_buf=' .. tostring(prepare_ctx_buf))
    print('  DEBUG: shadow_path=' .. tostring(state.shadow_path))
  end
  h.assert_true(prepare_items ~= nil, 'prepareCallHierarchy result should not be nil')
  h.assert_eq(prepare_ctx_buf, state.facade_buf, 'prepareCallHierarchy should target facade buffer')

  if not prepare_items or not prepare_items[1] then
    print('  SKIP: prepareCallHierarchy returned no items')
    return
  end

  -- Incoming calls for add
  local got_incoming = false
  local incoming_result = nil
  local incoming_ctx_buf = nil
  vim.lsp.buf_request(state.facade_buf, 'callHierarchy/incomingCalls', { item = prepare_items[1] }, function(err, result, ctx)
    got_incoming = true
    incoming_result = result
    incoming_ctx_buf = ctx and ctx.bufnr
  end)
  vim.wait(5000, function() return got_incoming end, 100)
  h.assert_true(got_incoming, 'Should get incomingCalls response')
  h.assert_eq(incoming_ctx_buf, state.facade_buf, 'incomingCalls should target facade buffer')
  h.assert_true(incoming_result ~= nil and #incoming_result > 0, 'incomingCalls should not be empty')

  -- Prepare call hierarchy on main (outgoing should include add)
  vim.api.nvim_win_set_cursor(0, { main_line, main_col })
  local got_prepare_main = false
  local prepare_main_items = nil
  local prepare_main_ctx_buf = nil
  local prepare_main_err = nil
  local params_main = vim.lsp.util.make_position_params(0, clients[1].offset_encoding)
  vim.lsp.buf_request(state.facade_buf, 'textDocument/prepareCallHierarchy', params_main, function(err, result, ctx)
    got_prepare_main = true
    prepare_main_items = result
    prepare_main_ctx_buf = ctx and ctx.bufnr
    prepare_main_err = err
  end)
  vim.wait(5000, function() return got_prepare_main end, 100)
  h.assert_true(got_prepare_main, 'Should get prepareCallHierarchy response (main)')
  if not prepare_main_items then
    print('  DEBUG: prepareCallHierarchy(main) err=' .. tostring(prepare_main_err))
    print('  DEBUG: prepareCallHierarchy(main) ctx_buf=' .. tostring(prepare_main_ctx_buf))
    print('  DEBUG: shadow_path=' .. tostring(state.shadow_path))
  end
  h.assert_true(prepare_main_items ~= nil, 'prepareCallHierarchy result should not be nil (main)')
  h.assert_eq(prepare_main_ctx_buf, state.facade_buf, 'prepareCallHierarchy (main) should target facade buffer')
  h.assert_true(prepare_main_items and prepare_main_items[1], 'prepareCallHierarchy should return item for main')

  local got_outgoing = false
  local outgoing_result = nil
  local outgoing_ctx_buf = nil
  vim.lsp.buf_request(state.facade_buf, 'callHierarchy/outgoingCalls', { item = prepare_main_items[1] }, function(err, result, ctx)
    got_outgoing = true
    outgoing_result = result
    outgoing_ctx_buf = ctx and ctx.bufnr
  end)
  vim.wait(5000, function() return got_outgoing end, 100)
  h.assert_true(got_outgoing, 'Should get outgoingCalls response')
  h.assert_eq(outgoing_ctx_buf, state.facade_buf, 'outgoingCalls should target facade buffer')
  h.assert_true(outgoing_result ~= nil and #outgoing_result > 0, 'outgoingCalls should not be empty')
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
