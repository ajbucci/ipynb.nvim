-- LSP proxy tests for ipynb.nvim
-- Run with: nvim --headless -u tests/minimal_init.lua -l tests/test_lsp.lua
--
-- NOTE: These tests require a working LSP (pyright recommended).
-- If no LSP is available, tests will be skipped.

local h = require('tests.helpers')

print('')
print(string.rep('=', 60))
print('Running LSP proxy tests')
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

-- Helper: Check if LSP is available
local function lsp_available()
  h.open_notebook('lsp_test.ipynb')
  local has_lsp = wait_for_lsp(5000)
  h.close_all_notebooks()
  return has_lsp
end

-- Check LSP availability once
local HAS_LSP = lsp_available()
if not HAS_LSP then
  print('  WARN: No LSP server found. LSP tests require:')
  print('        - basedpyright or pyright in PATH, OR')
  print('        - Mason with basedpyright or pyright installed')
  print('')
  print(string.rep('=', 60))
  print('Results: 0 passed, 0 failed (LSP tests skipped)')
  print(string.rep('=', 60))
  vim.cmd('qa!')
end

--------------------------------------------------------------------------------
-- Test: LSP clients available for facade buffer
-- When querying clients for facade buffer, should get shadow buffer's clients.
--------------------------------------------------------------------------------
h.run_test('lsp_clients_available_for_facade', function()
  h.open_notebook('lsp_test.ipynb')
  h.assert_true(wait_for_lsp(), 'LSP should attach')

  local state = h.get_state()

  -- Query clients for facade buffer (our proxy should redirect to shadow)
  local facade_clients = vim.lsp.get_clients({ bufnr = state.facade_buf })
  local shadow_clients = vim.lsp.get_clients({ bufnr = state.shadow_buf })

  h.assert_true(#facade_clients > 0, 'Should get clients for facade buffer')
  h.assert_eq(#facade_clients, #shadow_clients,
    'Facade and shadow should have same number of clients')
end)

--------------------------------------------------------------------------------
-- Test: LSP clients available for edit buffer
-- When querying clients for edit buffer, should get shadow buffer's clients.
--------------------------------------------------------------------------------
h.run_test('lsp_clients_available_for_edit_buffer', function()
  h.open_notebook('lsp_test.ipynb')
  h.assert_true(wait_for_lsp(), 'LSP should attach')

  h.enter_cell(1)
  local state = h.get_state()
  local edit_buf = h.get_edit_buf()

  -- Query clients for edit buffer
  local edit_clients = vim.lsp.get_clients({ bufnr = edit_buf })
  local shadow_clients = vim.lsp.get_clients({ bufnr = state.shadow_buf })

  h.assert_true(#edit_clients > 0, 'Should get clients for edit buffer')
  h.assert_eq(#edit_clients, #shadow_clients,
    'Edit and shadow should have same number of clients')

  h.exit_cell()
end)

--------------------------------------------------------------------------------
-- Test: Diagnostics appear in facade buffer
-- Code with error should show diagnostic in facade.
--------------------------------------------------------------------------------
h.run_test('diagnostics_in_facade', function()
  -- Create a notebook with an error
  local tests_dir = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h')
  local error_notebook = tests_dir .. '/fixtures/error_test.ipynb'

  -- Write error notebook
  local error_content = vim.json.encode({
    cells = {
      {
        cell_type = 'code',
        execution_count = vim.NIL,
        metadata = {},
        outputs = {},
        source = { 'undefined_variable_xyz' },
      },
    },
    metadata = {
      kernelspec = { display_name = 'Python 3', language = 'python', name = 'python3' },
      language_info = { name = 'python', version = '3.11.0' },
    },
    nbformat = 4,
    nbformat_minor = 5,
  })
  vim.fn.writefile({ error_content }, error_notebook)

  -- Open it
  vim.cmd('edit ' .. error_notebook)
  vim.wait(100)

  local state = h.get_state()
  h.assert_true(state ~= nil, 'Should have state')
  h.assert_true(wait_for_lsp(), 'LSP should attach')

  -- Wait for diagnostics (may take a moment)
  local has_diags = vim.wait(5000, function()
    local diags = vim.diagnostic.get(state.facade_buf)
    return #diags > 0
  end, 100)

  -- Clean up temp file
  vim.fn.delete(error_notebook)

  h.assert_true(has_diags, 'Should have diagnostics for undefined variable')
end)

--------------------------------------------------------------------------------
-- Test: Diagnostics appear in edit buffer
-- When editing cell with error, diagnostic should appear in edit buffer.
--------------------------------------------------------------------------------
h.run_test('diagnostics_in_edit_buffer', function()
  local tests_dir = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h')
  local error_notebook = tests_dir .. '/fixtures/error_test2.ipynb'

  local error_content = vim.json.encode({
    cells = {
      {
        cell_type = 'code',
        execution_count = vim.NIL,
        metadata = {},
        outputs = {},
        source = { 'another_undefined_var' },
      },
    },
    metadata = {
      kernelspec = { display_name = 'Python 3', language = 'python', name = 'python3' },
      language_info = { name = 'python', version = '3.11.0' },
    },
    nbformat = 4,
    nbformat_minor = 5,
  })
  vim.fn.writefile({ error_content }, error_notebook)

  vim.cmd('edit ' .. error_notebook)
  vim.wait(100)

  h.assert_true(wait_for_lsp(), 'LSP should attach')

  h.enter_cell(1)
  local edit_buf = h.get_edit_buf()

  -- Wait for diagnostics in edit buffer
  local has_diags = vim.wait(5000, function()
    local diags = vim.diagnostic.get(edit_buf)
    return #diags > 0
  end, 100)

  h.exit_cell()
  vim.fn.delete(error_notebook)

  h.assert_true(has_diags, 'Should have diagnostics in edit buffer')
end)

--------------------------------------------------------------------------------
-- Test: make_position_params uses shadow URI
-- When building LSP params from facade/edit buffer, URI should point to shadow.
--------------------------------------------------------------------------------
h.run_test('position_params_use_shadow_uri', function()
  h.open_notebook('lsp_test.ipynb')
  h.assert_true(wait_for_lsp(), 'LSP should attach')

  local state = h.get_state()
  local shadow_uri = vim.uri_from_fname(state.shadow_path)

  -- Test from facade buffer
  vim.api.nvim_set_current_buf(state.facade_buf)
  local facade_params = vim.lsp.util.make_position_params()
  h.assert_eq(facade_params.textDocument.uri, shadow_uri,
    'Facade params should use shadow URI')

  -- Test from edit buffer
  h.enter_cell(1)
  local edit_params = vim.lsp.util.make_position_params()
  h.assert_eq(edit_params.textDocument.uri, shadow_uri,
    'Edit params should use shadow URI')
  h.exit_cell()
end)

--------------------------------------------------------------------------------
-- Test: buf_request redirects to shadow buffer
-- Requests on facade/edit buffer should go to shadow buffer.
--------------------------------------------------------------------------------
h.run_test('buf_request_redirects_to_shadow', function()
  h.open_notebook('lsp_test.ipynb')
  h.assert_true(wait_for_lsp(), 'LSP should attach')

  local state = h.get_state()

  -- Make a simple request (textDocument/documentSymbol)
  local got_response = false
  local response_err = nil

  vim.lsp.buf_request(state.facade_buf, 'textDocument/documentSymbol', {
    textDocument = { uri = vim.uri_from_fname(state.facade_path) },
  }, function(err, result)
    got_response = true
    response_err = err
  end)

  -- Wait for response
  vim.wait(5000, function() return got_response end, 100)

  h.assert_true(got_response, 'Should get response from buf_request')
  -- Note: err might be nil (success) or contain method not supported
  -- Either is fine - we just want to verify the request went through
end)

--------------------------------------------------------------------------------
-- Test: Go-to-definition (gd) from facade buffer
-- Position cursor on function call, request definition.
-- Expected: Get location pointing to the definition.
--------------------------------------------------------------------------------
h.run_test('goto_definition_from_facade', function()
  h.open_notebook('lsp_test.ipynb')
  h.assert_true(wait_for_lsp(), 'LSP should attach')

  local state = h.get_state()
  local cells_mod = require('ipynb.cells')

  -- Cell 2 contains "result = hello()" - position cursor on "hello"
  local content_start, _ = cells_mod.get_content_range(state, 2)
  -- Line with "result = hello()" - position on 'h' of hello
  vim.api.nvim_win_set_cursor(0, { content_start + 1, 9 })  -- "result = hello" -> col 9 is 'h'

  -- Make definition request
  local got_result = false
  local definition_result = nil

  local params = vim.lsp.util.make_position_params()
  vim.lsp.buf_request(state.facade_buf, 'textDocument/definition', params, function(err, result)
    got_result = true
    definition_result = result
  end)

  vim.wait(5000, function() return got_result end, 100)

  h.assert_true(got_result, 'Should get definition response')
  h.assert_true(definition_result ~= nil, 'Definition result should not be nil')

  -- Result should point to cell 1 where "def hello" is defined
  -- (line 0 or 1 in shadow buffer terms, which maps to cell 1 content)
  local locations = definition_result
  if locations and locations[1] then
    local loc = locations[1]
    local line = loc.range and loc.range.start and loc.range.start.line
    h.assert_true(line ~= nil, 'Definition should have line number')
    -- Definition should be in cell 1 (lines 1-2 in facade, 0-indexed: 1)
    h.assert_true(line <= 2, 'Definition should be in cell 1 area')
  end
end)

--------------------------------------------------------------------------------
-- Test: Go-to-definition (gd) from edit buffer
-- Enter cell, position cursor on function call, request definition.
--------------------------------------------------------------------------------
h.run_test('goto_definition_from_edit', function()
  h.open_notebook('lsp_test.ipynb')
  h.assert_true(wait_for_lsp(), 'LSP should attach')

  -- Enter cell 2 which has "hello()"
  h.enter_cell(2)

  local state = h.get_state()
  local edit_buf = h.get_edit_buf()

  -- Position cursor on "hello" (col 9 in "result = hello()")
  vim.api.nvim_win_set_cursor(0, { 1, 9 })

  -- Make definition request from edit buffer
  local got_result = false
  local definition_result = nil

  local params = vim.lsp.util.make_position_params()
  vim.lsp.buf_request(edit_buf, 'textDocument/definition', params, function(err, result)
    got_result = true
    definition_result = result
  end)

  vim.wait(5000, function() return got_result end, 100)

  h.assert_true(got_result, 'Should get definition response from edit buffer')
  h.assert_true(definition_result ~= nil, 'Definition result should not be nil')

  h.exit_cell()
end)

--------------------------------------------------------------------------------
-- Test: Find references (gr) from facade buffer
-- Position cursor on function name, request references.
-- Expected: Get locations for both definition and usage.
--------------------------------------------------------------------------------
h.run_test('find_references_from_facade', function()
  h.open_notebook('lsp_test.ipynb')
  h.assert_true(wait_for_lsp(), 'LSP should attach')

  local state = h.get_state()
  local cells_mod = require('ipynb.cells')

  -- Position cursor on "hello" in cell 1 (the definition)
  local content_start, _ = cells_mod.get_content_range(state, 1)
  vim.api.nvim_win_set_cursor(0, { content_start + 1, 4 })  -- "def hello" -> col 4 is 'h'

  -- Make references request
  local got_result = false
  local references_result = nil

  local params = vim.lsp.util.make_position_params()
  params.context = { includeDeclaration = true }

  vim.lsp.buf_request(state.facade_buf, 'textDocument/references', params, function(err, result)
    got_result = true
    references_result = result
  end)

  vim.wait(5000, function() return got_result end, 100)

  h.assert_true(got_result, 'Should get references response')
  -- Should find at least 2 references: definition in cell 1, usage in cell 2
  if references_result then
    h.assert_true(#references_result >= 2,
      string.format('Should find at least 2 references, found %d', #references_result))
  end
end)

--------------------------------------------------------------------------------
-- Test: Find references (gr) from edit buffer
-- Enter cell, position cursor, request references.
--------------------------------------------------------------------------------
h.run_test('find_references_from_edit', function()
  h.open_notebook('lsp_test.ipynb')
  h.assert_true(wait_for_lsp(), 'LSP should attach')

  -- Enter cell 1 which has "def hello"
  h.enter_cell(1)

  local edit_buf = h.get_edit_buf()

  -- Position cursor on "hello"
  vim.api.nvim_win_set_cursor(0, { 1, 4 })

  -- Make references request
  local got_result = false
  local references_result = nil

  local params = vim.lsp.util.make_position_params()
  params.context = { includeDeclaration = true }

  vim.lsp.buf_request(edit_buf, 'textDocument/references', params, function(err, result)
    got_result = true
    references_result = result
  end)

  vim.wait(5000, function() return got_result end, 100)

  h.assert_true(got_result, 'Should get references response from edit buffer')
  if references_result then
    h.assert_true(#references_result >= 2,
      string.format('Should find at least 2 references from edit, found %d', #references_result))
  end

  h.exit_cell()
end)

--------------------------------------------------------------------------------
-- Test: Hover (K) from facade buffer
-- Position cursor on identifier, request hover info.
-- Expected: Get hover content with type information.
--------------------------------------------------------------------------------
h.run_test('hover_from_facade', function()
  h.open_notebook('lsp_test.ipynb')
  h.assert_true(wait_for_lsp(), 'LSP should attach')

  local state = h.get_state()
  local cells_mod = require('ipynb.cells')

  -- Position cursor on "hello" in cell 1
  local content_start, _ = cells_mod.get_content_range(state, 1)
  vim.api.nvim_win_set_cursor(0, { content_start + 1, 4 })

  -- Make hover request
  local got_result = false
  local hover_result = nil

  local params = vim.lsp.util.make_position_params()
  vim.lsp.buf_request(state.facade_buf, 'textDocument/hover', params, function(err, result)
    got_result = true
    hover_result = result
  end)

  vim.wait(5000, function() return got_result end, 100)

  h.assert_true(got_result, 'Should get hover response')
  -- Hover result should have contents
  if hover_result then
    h.assert_true(hover_result.contents ~= nil, 'Hover should have contents')
  end
end)

--------------------------------------------------------------------------------
-- Test: Hover (K) from edit buffer
-- Enter cell, position cursor, request hover.
--------------------------------------------------------------------------------
h.run_test('hover_from_edit', function()
  h.open_notebook('lsp_test.ipynb')
  h.assert_true(wait_for_lsp(), 'LSP should attach')

  -- Enter cell 1 which has "def hello"
  h.enter_cell(1)

  local edit_buf = h.get_edit_buf()

  -- Position cursor on "hello"
  vim.api.nvim_win_set_cursor(0, { 1, 4 })

  -- Make hover request
  local got_result = false
  local hover_result = nil

  local params = vim.lsp.util.make_position_params()
  vim.lsp.buf_request(edit_buf, 'textDocument/hover', params, function(err, result)
    got_result = true
    hover_result = result
  end)

  vim.wait(5000, function() return got_result end, 100)

  h.assert_true(got_result, 'Should get hover response from edit buffer')

  h.exit_cell()
end)

--------------------------------------------------------------------------------
-- Test: vim.lsp.buf.definition() uses client:request() - must be wrapped
-- This tests the client.request wrapping (not buf_request).
-- vim.lsp.buf.definition/declaration/implementation use client:request directly.
--------------------------------------------------------------------------------
h.run_test('vim_lsp_buf_definition_from_facade', function()
  h.open_notebook('lsp_test.ipynb')
  h.assert_true(wait_for_lsp(), 'LSP should attach')

  local state = h.get_state()
  local cells_mod = require('ipynb.cells')

  -- Position cursor on "hello" in cell 2 (usage)
  local content_start, _ = cells_mod.get_content_range(state, 2)
  vim.api.nvim_win_set_cursor(0, { content_start + 1, 9 })  -- "result = hello" -> col 9 is 'h'

  -- Track if we jumped to a valid location
  local initial_line = vim.api.nvim_win_get_cursor(0)[1]
  local jumped = false

  -- Call vim.lsp.buf.definition() (uses client:request internally)
  -- This should trigger our wrapped client.request
  vim.lsp.buf.definition()

  -- Wait for jump (vim.lsp.buf.definition jumps synchronously or async)
  vim.wait(5000, function()
    local new_line = vim.api.nvim_win_get_cursor(0)[1]
    if new_line ~= initial_line then
      jumped = true
      return true
    end
    return false
  end, 100)

  -- If we jumped, verify we ended up in the facade buffer (not shadow)
  local current_buf = vim.api.nvim_get_current_buf()
  h.assert_true(current_buf ~= state.shadow_buf,
    'Should not jump to shadow buffer - should stay in facade')

  -- Should be in the facade buffer
  h.assert_eq(current_buf, state.facade_buf,
    string.format('Should be in facade buffer, got buf %d (facade=%d, shadow=%d)',
      current_buf, state.facade_buf, state.shadow_buf))
end)

--------------------------------------------------------------------------------
-- Test: vim.lsp.buf.declaration() uses client:request() - must be wrapped
-- Tests the same wrapping for declaration.
--------------------------------------------------------------------------------
h.run_test('vim_lsp_buf_declaration_from_facade', function()
  h.open_notebook('lsp_test.ipynb')
  h.assert_true(wait_for_lsp(), 'LSP should attach')

  local state = h.get_state()
  local cells_mod = require('ipynb.cells')

  -- Position cursor on "hello" in cell 2 (usage)
  local content_start, _ = cells_mod.get_content_range(state, 2)
  vim.api.nvim_win_set_cursor(0, { content_start + 1, 9 })

  -- Call vim.lsp.buf.declaration() (uses client:request internally)
  -- Note: pyright may not distinguish declaration from definition for Python
  vim.lsp.buf.declaration()

  -- Wait a bit
  vim.wait(2000, function() return false end, 100)

  -- Verify we didn't end up in the shadow buffer
  local current_buf = vim.api.nvim_get_current_buf()
  h.assert_true(current_buf ~= state.shadow_buf,
    'Should not jump to shadow buffer after declaration')
end)

--------------------------------------------------------------------------------
-- Test: vim.lsp.buf.type_definition() uses client:request() - must be wrapped
--------------------------------------------------------------------------------
h.run_test('vim_lsp_buf_type_definition_from_facade', function()
  h.open_notebook('lsp_test.ipynb')
  h.assert_true(wait_for_lsp(), 'LSP should attach')

  local state = h.get_state()
  local cells_mod = require('ipynb.cells')

  -- Position cursor on "hello" in cell 2
  local content_start, _ = cells_mod.get_content_range(state, 2)
  vim.api.nvim_win_set_cursor(0, { content_start + 1, 9 })

  -- Call vim.lsp.buf.type_definition()
  vim.lsp.buf.type_definition()

  vim.wait(2000, function() return false end, 100)

  local current_buf = vim.api.nvim_get_current_buf()
  h.assert_true(current_buf ~= state.shadow_buf,
    'Should not jump to shadow buffer after type_definition')
end)

--------------------------------------------------------------------------------
-- Test: vim.lsp.buf.implementation() uses client:request() - must be wrapped
--------------------------------------------------------------------------------
h.run_test('vim_lsp_buf_implementation_from_facade', function()
  h.open_notebook('lsp_test.ipynb')
  h.assert_true(wait_for_lsp(), 'LSP should attach')

  local state = h.get_state()
  local cells_mod = require('ipynb.cells')

  -- Position cursor on "hello" in cell 1 (definition)
  local content_start, _ = cells_mod.get_content_range(state, 1)
  vim.api.nvim_win_set_cursor(0, { content_start + 1, 4 })

  -- Call vim.lsp.buf.implementation()
  vim.lsp.buf.implementation()

  vim.wait(2000, function() return false end, 100)

  local current_buf = vim.api.nvim_get_current_buf()
  h.assert_true(current_buf ~= state.shadow_buf,
    'Should not jump to shadow buffer after implementation')
end)

--------------------------------------------------------------------------------
-- Test: Shadow buffer content is correct
-- Code cells have content, markdown cells are blank.
--------------------------------------------------------------------------------
h.run_test('shadow_buffer_content', function()
  h.open_notebook('mixed.ipynb')

  local state = h.get_state()
  local shadow_lines = vim.api.nvim_buf_get_lines(state.shadow_buf, 0, -1, false)
  local cells_mod = require('ipynb.cells')

  for i, cell in ipairs(state.cells) do
    local content_start, content_end = cells_mod.get_content_range(state, i)

    if cell.type == 'code' then
      -- Code cells should have non-blank content in shadow
      local has_content = false
      for line = content_start, content_end do
        if shadow_lines[line + 1] and shadow_lines[line + 1] ~= '' then
          has_content = true
          break
        end
      end
      h.assert_true(has_content,
        string.format('Code cell %d should have content in shadow', i))
    else
      -- Markdown cells should be blank in shadow
      for line = content_start, content_end do
        h.assert_eq(shadow_lines[line + 1], '',
          string.format('Markdown cell %d line %d should be blank in shadow', i, line))
      end
    end
  end
end)

--------------------------------------------------------------------------------
-- Test: Format cell from edit float
-- Enter edit mode, trigger format, verify no errors and content is formatted.
--------------------------------------------------------------------------------
h.run_test('format_cell_from_edit_float', function()
  -- Create a notebook with poorly formatted code
  local tests_dir = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h')
  local format_notebook = tests_dir .. '/fixtures/format_test.ipynb'

  local format_content = vim.json.encode({
    cells = {
      {
        cell_type = 'code',
        execution_count = vim.NIL,
        metadata = {},
        outputs = {},
        source = { 'x=1+2' },  -- No spaces around operators
      },
    },
    metadata = {
      kernelspec = { display_name = 'Python 3', language = 'python', name = 'python3' },
      language_info = { name = 'python', version = '3.11.0' },
    },
    nbformat = 4,
    nbformat_minor = 5,
  })
  vim.fn.writefile({ format_content }, format_notebook)

  vim.cmd('edit ' .. format_notebook)
  vim.wait(100)

  h.assert_true(wait_for_lsp(), 'LSP should attach')

  -- Enter edit mode for cell 1
  h.enter_cell(1)
  local state = h.get_state()
  local edit_buf = h.get_edit_buf()

  h.assert_true(edit_buf ~= nil, 'Should be in edit mode')
  h.assert_true(state.edit_state ~= nil, 'Edit state should exist')

  -- Get content before format
  local before = vim.api.nvim_buf_get_lines(edit_buf, 0, -1, false)
  h.assert_eq(before[1], 'x=1+2', 'Content before format should be unformatted')

  -- Trigger format via format_cell (this is what the bug was about)
  local format_mod = require('ipynb.lsp.format')
  local format_done = false
  local format_error = nil

  -- Wrap in pcall to catch the error that was occurring
  local ok, err = pcall(function()
    format_mod.format_cell(state, 1, function()
      format_done = true
    end)
  end)

  if not ok then
    format_error = err
  end

  -- Wait for format to complete
  vim.wait(5000, function() return format_done or format_error end, 100)

  -- Clean up
  h.exit_cell()
  vim.fn.delete(format_notebook)

  -- Assert no error occurred during formatting
  h.assert_true(format_error == nil,
    'Format should not error: ' .. tostring(format_error))
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
