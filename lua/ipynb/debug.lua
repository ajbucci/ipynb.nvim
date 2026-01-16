-- ipynb/debug.lua - Debug utilities for inspecting extmarks and highlighting

local M = {}

---Get all extmarks on a specific line across all namespaces
---@param buf number Buffer number
---@param line number 0-indexed line number
---@return table[] List of extmark info
function M.get_extmarks_on_line(buf, line)
  local results = {}

  -- Get all known namespaces
  local namespaces = {
    notebook_visuals = vim.api.nvim_create_namespace('notebook_visuals'),
    notebook_active = vim.api.nvim_create_namespace('notebook_active'),
    notebook_markdown_conceal = vim.api.nvim_create_namespace('notebook_markdown_conceal'),
    notebook_diagnostics = vim.api.nvim_create_namespace('notebook_diagnostics'),
    notebook_cells = vim.api.nvim_create_namespace('notebook_cells'),
  }

  for name, ns in pairs(namespaces) do
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, { line, 0 }, { line, -1 }, { details = true })
    for _, mark in ipairs(marks) do
      local id, row, col, details = mark[1], mark[2], mark[3], mark[4]
      table.insert(results, {
        namespace = name,
        id = id,
        row = row,
        col = col,
        details = details,
      })
    end
  end

  return results
end

---Format extmark info for display
---@param mark table Extmark info from get_extmarks_on_line
---@return string
local function format_extmark(mark)
  local parts = { string.format('  [%s] id=%d col=%d', mark.namespace, mark.id, mark.col) }

  local d = mark.details
  if d.hl_group then
    table.insert(parts, string.format('hl_group=%s', d.hl_group))
  end
  if d.line_hl_group then
    table.insert(parts, string.format('line_hl_group=%s', d.line_hl_group))
  end
  if d.virt_text then
    local vt_str = vim.inspect(d.virt_text):gsub('\n', ' ')
    table.insert(parts, string.format('virt_text=%s', vt_str))
  end
  if d.conceal then
    table.insert(parts, string.format('conceal=%q', d.conceal))
  end
  if d.sign_text then
    table.insert(parts, string.format('sign_text=%q', d.sign_text))
  end
  if d.priority then
    table.insert(parts, string.format('priority=%d', d.priority))
  end

  return table.concat(parts, ' ')
end

---Inspect a specific line and print extmark info
---@param line number 1-indexed line number (as shown in Neovim)
function M.inspect_line(line)
  local buf = vim.api.nvim_get_current_buf()
  local line_0 = line - 1 -- Convert to 0-indexed

  -- Get line content
  local lines = vim.api.nvim_buf_get_lines(buf, line_0, line_0 + 1, false)
  local content = lines[1] or ''

  print(string.format('=== Line %d: %q ===', line, content))

  -- Get extmarks
  local marks = M.get_extmarks_on_line(buf, line_0)

  if #marks == 0 then
    print('  (no extmarks)')
  else
    for _, mark in ipairs(marks) do
      print(format_extmark(mark))
    end
  end

  -- Check diagnostics separately (they use vim.diagnostic API)
  local diags = vim.diagnostic.get(buf, { lnum = line_0 })
  if #diags > 0 then
    print('  Diagnostics:')
    for _, diag in ipairs(diags) do
      print(string.format('    [%s] col=%d: %s', vim.diagnostic.severity[diag.severity], diag.col, diag.message))
    end
  end

  -- Check treesitter highlights on this line
  local ok, ts_highlights = pcall(function()
    return vim.treesitter.get_captures_at_pos(buf, line_0, 0)
  end)
  if ok and #ts_highlights > 0 then
    print('  Treesitter captures at col 0:')
    for _, cap in ipairs(ts_highlights) do
      print(string.format('    @%s', cap.capture))
    end
  end
end

---Run validation tests for specific lines
---@param tests table[] List of {line=N, expect={...}}
function M.validate(tests)
  local buf = vim.api.nvim_get_current_buf()
  local passed = 0
  local failed = 0

  for _, test in ipairs(tests) do
    local line_0 = test.line - 1
    local lines = vim.api.nvim_buf_get_lines(buf, line_0, line_0 + 1, false)
    local content = lines[1] or ''

    print(string.format('\n=== Testing Line %d: %q ===', test.line, content:sub(1, 40)))

    local marks = M.get_extmarks_on_line(buf, line_0)
    local diags = vim.diagnostic.get(buf, { lnum = line_0 })

    -- Check expected extmarks
    if test.expect.has_markdown_hl then
      local found = false
      for _, mark in ipairs(marks) do
        if mark.namespace == 'notebook_markdown_conceal' and mark.details.hl_group then
          found = true
          print(string.format('  PASS: has markdown highlight (%s)', mark.details.hl_group))
          break
        end
      end
      if not found then
        print('  FAIL: expected markdown highlight, not found')
        failed = failed + 1
      else
        passed = passed + 1
      end
    end

    if test.expect.has_cell_background then
      local found = false
      for _, mark in ipairs(marks) do
        if mark.details.line_hl_group and mark.details.line_hl_group:match('^Ipynb.*Cell$') then
          found = true
          print(string.format('  PASS: has cell background (%s)', mark.details.line_hl_group))
          break
        end
      end
      if not found then
        print('  FAIL: expected cell background highlight, not found')
        failed = failed + 1
      else
        passed = passed + 1
      end
    end

    if test.expect.has_diagnostics then
      if #diags > 0 then
        print(string.format('  PASS: has diagnostics (%d found)', #diags))
        passed = passed + 1
      else
        print('  FAIL: expected diagnostics, none found')
        failed = failed + 1
      end
    end

    if test.expect.no_diagnostics then
      if #diags == 0 then
        print('  PASS: no diagnostics (as expected)')
        passed = passed + 1
      else
        print(string.format('  FAIL: expected no diagnostics, found %d', #diags))
        failed = failed + 1
      end
    end

    if test.expect.has_sign then
      local found = false
      for _, mark in ipairs(marks) do
        if mark.details.sign_text then
          found = true
          print(string.format('  PASS: has sign (%q)', mark.details.sign_text))
          break
        end
      end
      if not found then
        print('  FAIL: expected sign, not found')
        failed = failed + 1
      else
        passed = passed + 1
      end
    end

    if test.expect.has_border then
      local found = false
      for _, mark in ipairs(marks) do
        if mark.details.virt_text then
          local vt = mark.details.virt_text
          if vt[1] and vt[1][1] and vt[1][1]:match('[╭╰]') then
            found = true
            print('  PASS: has border')
            break
          end
        end
      end
      if not found then
        print('  FAIL: expected border, not found')
        failed = failed + 1
      else
        passed = passed + 1
      end
    end
  end

  print(string.format('\n=== Results: %d passed, %d failed ===', passed, failed))
  return failed == 0
end

---Run the standard test suite for the current notebook
function M.run_tests()
  print('Running notebook extmark tests...\n')

  -- These are the tests the user specified
  M.validate({
    {
      line = 2,
      expect = {
        has_markdown_hl = true,
        has_cell_background = true,
        no_diagnostics = true,
      },
    },
    {
      line = 8,
      expect = {
        has_cell_background = true,
        has_diagnostics = true, -- "import np is not accessed"
        has_sign = true,
      },
    },
    {
      line = 15,
      expect = {
        has_cell_background = true,
        has_sign = true,
      },
    },
  })
end

---Quick dump of all extmarks on lines 1-20
function M.dump()
  for i = 1, 20 do
    M.inspect_line(i)
  end
end

---Check treesitter status for current buffer
function M.check_treesitter()
  local buf = vim.api.nvim_get_current_buf()
  local ft = vim.bo[buf].filetype

  print('Buffer: ' .. buf)
  print('Filetype: ' .. ft)

  -- Check if parser is available
  local ok, parser = pcall(vim.treesitter.get_parser, buf, 'ipynb')
  if not ok then
    print('Failed to get parser: ' .. tostring(parser))
    return
  end
  print('Parser: ' .. tostring(parser))

  -- Parse and show tree
  local tree = parser:parse()[1]
  if tree then
    local root = tree:root()
    print('Root type: ' .. root:type())
    print('Root child count: ' .. root:child_count())
  end

  -- Check injection queries
  print('\nChecking injection queries...')
  local query_ok, query = pcall(vim.treesitter.query.get, 'ipynb', 'injections')
  if not query_ok then
    print('Failed to get injection query: ' .. tostring(query))
  else
    print('Injection query loaded: ' .. tostring(query))
  end

  -- Check highlights query
  local hl_ok, hl_query = pcall(vim.treesitter.query.get, 'ipynb', 'highlights')
  if not hl_ok then
    print('Failed to get highlights query: ' .. tostring(hl_query))
  else
    print('Highlights query loaded: ' .. tostring(hl_query))
  end
end

---Start treesitter highlighting for current buffer
function M.start_highlight()
  local buf = vim.api.nvim_get_current_buf()
  vim.treesitter.start(buf, 'ipynb')
  print('Started treesitter highlighting for buffer ' .. buf)
end

---Show parse tree for current buffer
function M.show_tree()
  local buf = vim.api.nvim_get_current_buf()
  local ok, parser = pcall(vim.treesitter.get_parser, buf, 'ipynb')
  if not ok then
    print('Failed to get parser: ' .. tostring(parser))
    return
  end

  local tree = parser:parse()[1]
  local root = tree:root()

  local function print_node(node, indent)
    indent = indent or 0
    local prefix = string.rep('  ', indent)
    local start_row, start_col, end_row, end_col = node:range()
    print(string.format('%s%s [%d:%d - %d:%d]', prefix, node:type(), start_row, start_col, end_row, end_col))
    for child in node:iter_children() do
      print_node(child, indent + 1)
    end
  end

  print_node(root)
end

---Debug undo tree for a buffer
---@param buf number|nil Buffer number (default: current)
function M.undo_info(buf)
  buf = buf or vim.api.nvim_get_current_buf()

  vim.api.nvim_buf_call(buf, function()
    local ut = vim.fn.undotree()
    print(string.format('=== Undo Tree for buffer %d ===', buf))
    print(string.format('  seq_last: %d (total changes)', ut.seq_last))
    print(string.format('  seq_cur: %d (current position)', ut.seq_cur))
    print(string.format('  entries: %d', #ut.entries))
    print(string.format('  undolevels: %d (buffer-local)', vim.bo[buf].undolevels))
    print(string.format('  modified: %s', vim.bo[buf].modified and 'yes' or 'no'))
    print(string.format('  buftype: %q', vim.bo[buf].buftype))
    print(string.format('  bufhidden: %q', vim.bo[buf].bufhidden))

    if #ut.entries > 0 then
      print('  Recent entries:')
      for i = math.max(1, #ut.entries - 4), #ut.entries do
        local e = ut.entries[i]
        print(string.format('    [%d] seq=%d', i, e.seq))
      end
    end
  end)
end

---Debug edit buffer state
function M.edit_state()
  local state_mod = require('ipynb.state')
  local buf = vim.api.nvim_get_current_buf()

  -- Try to find state by facade buffer first
  local state = state_mod.get(buf)

  -- If not found, try to find from edit buffer
  if not state then
    state = state_mod.get_from_edit_buf(buf)
  end

  -- If still not found, list all known notebooks
  if not state then
    print('No notebook state found for current buffer ' .. buf)
    print('Known notebooks:')
    for facade_buf, s in pairs(state_mod.notebooks) do
      print(string.format('  facade_buf=%d, source=%s', facade_buf, s.source_path))
      if s.edit_state then
        print(string.format('    edit_buf=%d', s.edit_state.buf))
      end
    end
    return
  end

  print('=== Edit State ===')
  if state.edit_state then
    local e = state.edit_state
    print(string.format('  buf: %d (valid: %s)', e.buf, vim.api.nvim_buf_is_valid(e.buf) and 'yes' or 'no'))
    print(string.format('  win: %d (valid: %s)', e.win, vim.api.nvim_win_is_valid(e.win) and 'yes' or 'no'))
    print(string.format('  cell_idx: %d', e.cell_idx))
    print(string.format('  start_line: %d, end_line: %d', e.start_line, e.end_line))

    if vim.api.nvim_buf_is_valid(e.buf) then
      print(string.format('  sync_attached: %s', vim.b[e.buf].notebook_sync_attached and 'yes' or 'no'))
      print(string.format('  keymaps_set: %s', vim.b[e.buf].notebook_keymaps_set and 'yes' or 'no'))
      M.undo_info(e.buf)
    end
  else
    print('  (no active edit)')
  end

  print('\n=== Cell Buffers ===')
  for i, cell in ipairs(state.cells) do
    if cell.edit_buf then
      local valid = vim.api.nvim_buf_is_valid(cell.edit_buf)
      print(string.format('  Cell %d: buf=%d valid=%s', i, cell.edit_buf, valid and 'yes' or 'no'))
      if valid then
        M.undo_info(cell.edit_buf)
      end
    end
  end
end

return M