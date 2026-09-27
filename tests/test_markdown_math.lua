-- Math in markdown cells ($$ blocks and inline $...$), rendered in place of
-- its source.
-- Run: nvim --headless -u tests/minimal_init.lua -l tests/test_markdown_math.lua

local h = require('tests.helpers')
local config = require('ipynb.config')
local images = require('ipynb.images')
local latex = require('ipynb.latex')
local markdown_math = require('ipynb.markdown_math')

print(string.rep('=', 60))
print('Running markdown math tests')
print(string.rep('=', 60))

config.get().images.cache_dir = vim.fn.tempname()

local have_tools = latex.is_available()
if not have_tools then
  print('  (' .. table.concat(latex.tools, ', ') .. ' not all found: rendering tests are skipped)')
end

h.run_test('finds_display_blocks_and_inline_math', function()
  local source = table.concat({
    'Inline $a+b$ and mid-sentence $$x^2$$ render inline.', -- 0
    '',
    '$$\\int_0^1 x\\,dx$$', -- 2
    '',
    '$$', -- 4
    '\\sum_{n=1}^\\infty \\frac{1}{n^2}',
    '$$', -- 6
    '',
    '- item',
    '  $$ e^{i\\pi} + 1 = 0 $$', -- 9
    '',
    '```',
    '$$not math$$',
    '```',
    'Prices $5 and $10, spaced $ x $ and `$code$` are not math, but $x$.', -- 14
  }, '\n')
  local found = {}
  for _, block in ipairs(markdown_math.find_math(source)) do
    local kind = block.display and 'display' or 'inline'
    local text = block.text:gsub('\n', ' ')
    table.insert(found, ('%s %d:%d-%d:%d %s'):format(kind, block.first, block.first_col, block.last, block.last_col, text))
  end
  h.assert_eq(table.concat(found, '\n'), table.concat({
    'inline 0:7-0:12 $a+b$',
    'inline 0:30-0:37 $x^2$',
    'display 2:0-2:18 $$\\int_0^1 x\\,dx$$',
    'display 4:0-6:2 $$ \\sum_{n=1}^\\infty \\frac{1}{n^2} $$',
    'display 9:2-9:24 $$ e^{i\\pi} + 1 = 0 $$',
    'inline 14:63-14:66 $x$',
  }, '\n'))
end)

h.run_test('markdown_escapes_in_math_are_undone', function()
  -- Authors write \\* to keep * from starting emphasis; LaTeX has no such
  -- escape. An escaped backslash before * stays as it is.
  local blocks = markdown_math.find_math('Estimate $x^\\*$ and $y^{\\*}$.\n\n$$a \\\\* b = x^\\*$$')
  local texts = vim.tbl_map(function(block)
    return block.text
  end, blocks)
  h.assert_eq(table.concat(texts, ' | '), '$x^*$ | $y^{*}$ | $$a \\\\* b = x^*$$')
end)

-- The terminal image layer needs a graphics terminal: stand in with marker
-- rows, IMAGE_ROWS tall, so the tests see where each image row lands.
local IMAGE_ROWS = 3
local function with_fake_image_layer(fn)
  local supports, file_lines = images.supports_placeholders, images.get_file_virt_lines
  images.supports_placeholders = function()
    return true
  end
  images.get_file_virt_lines = function()
    local rows = {}
    for i = 1, IMAGE_ROWS do
      table.insert(rows, { { '[image row ' .. i .. ']', 'Normal' } })
    end
    return rows, IMAGE_ROWS
  end
  local ok, err = xpcall(fn, debug.traceback)
  images.supports_placeholders, images.get_file_virt_lines = supports, file_lines
  assert(ok, err)
end

---Open a notebook with the given markdown cells
---@param sources string[]
---@return NotebookState
local function open_markdown(sources)
  h.close_all_notebooks()
  local cells = {}
  for i, source in ipairs(sources) do
    table.insert(cells, { cell_type = 'markdown', id = 'm' .. i, metadata = vim.empty_dict(), source = { source } })
  end
  local path = vim.fn.tempname() .. '.ipynb'
  vim.fn.writefile({ vim.json.encode({ nbformat = 4, nbformat_minor = 5, metadata = vim.empty_dict(), cells = cells }) }, path)
  return h.open_notebook_path(path)
end

---What the math namespace draws on each buffer row, e.g. '12: conceal [image row 1]'
---@param state NotebookState
---@return string
local function drawn(state)
  local rows = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(state.facade_buf, markdown_math.ns, 0, -1, { details = true })) do
    local row, details, parts = mark[3] > 0 and (mark[2] .. ':' .. mark[3]) or mark[2], mark[4], {}
    if details.conceal_lines then
      table.insert(parts, 'hidden to ' .. details.end_row)
    elseif details.conceal then
      table.insert(parts, 'conceal')
    end
    for _, chunk in ipairs(details.virt_text or {}) do
      if chunk[1]:find('%S') then
        table.insert(parts, chunk[1])
      end
    end
    for _, line in ipairs(details.virt_lines or {}) do
      local text = {}
      for _, chunk in ipairs(line) do
        table.insert(text, chunk[1])
      end
      table.insert(parts, 'below: ' .. vim.trim(table.concat(text)))
    end
    table.insert(rows, row .. ': ' .. table.concat(parts, ' '))
  end
  return table.concat(rows, '\n')
end

---Wait until the math namespace draws something
local function wait_drawn(state, pattern)
  return vim.wait(20000, function()
    return drawn(state):find(pattern) ~= nil
  end, 10)
end

h.run_test('no_warning_about_missing_tools_without_math', function()
  package.loaded['ipynb.latex'] = nil
  local fresh = require('ipynb.latex')
  fresh.tools = { 'ipynb-missing-tool' }
  local notify = vim.notify
  local warnings = 0
  vim.notify = function(_, level)
    if level == vim.log.levels.WARN then
      warnings = warnings + 1
    end
  end
  local ok, err = xpcall(function()
    with_fake_image_layer(function()
      open_markdown({ '# No math here', 'Prices like $5 and $10 are not math.' })
      h.assert_eq(warnings, 0, 'A notebook without math should not warn')
      open_markdown({ 'Some $x$' })
      h.assert_eq(warnings, 1, 'Math that cannot render should warn')
    end)
  end, debug.traceback)
  vim.notify = notify
  package.loaded['ipynb.latex'] = latex
  assert(ok, err)
end)

h.run_test('display_math_replaces_its_source_lines', function()
  if not have_tools then
    return
  end
  with_fake_image_layer(function()
    -- Buffer rows: marker 0, 'One line:' 1, '' 2, block 3, '' 4, 'Three:' 5, block 6-8
    local state = open_markdown({ 'One line:\n\n$$x^2$$\n\nThree:\n$$\n\\frac{a}{b}\n$$' })
    h.assert_true(wait_drawn(state, 'hidden to 8'), 'The math should render')
    local rows = 'below: │ [image row 1] below: │ [image row 2] below: │ [image row 3]'
    h.assert_eq(drawn(state), table.concat({
      '2: ' .. rows,
      '3: hidden to 3',
      '5: ' .. rows,
      '6: hidden to 8',
    }, '\n'))
  end)
end)

h.run_test('adjacent_blocks_hang_in_order_from_the_line_above_both', function()
  if not have_tools then
    return
  end
  with_fake_image_layer(function()
    -- Tag each formula's image by the order it is first seen in.
    local order = {}
    images.get_file_virt_lines = function(_, _, path)
      if not order[path] then
        order[path] = vim.tbl_count(order) + 1
      end
      return { { { '[image ' .. order[path] .. ']', 'Normal' } } }, 1
    end
    -- The first block sits on the first content line: it hangs from the marker.
    local state = open_markdown({ '$$a$$\n$$b$$' })
    local expected = '0: below: │ [image 1] below: │ [image 2]\n1: hidden to 1\n2: hidden to 2'
    h.assert_true(wait_drawn(state, 'hidden to 2'), 'The math should render')
    h.assert_eq(drawn(state), expected)

    -- Redrawing the border, or rendering again, keeps the order and adds nothing.
    markdown_math.set_border_hl(state, 1, 'IpynbBorderHover')
    markdown_math.render_all(state)
    h.assert_true(wait_drawn(state, 'hidden to 2'), 'The math should render again')
    h.assert_eq(drawn(state), expected)
  end)
end)

h.run_test('cursor_steps_over_hidden_blocks', function()
  if not have_tools then
    return
  end
  with_fake_image_layer(function()
    -- Buffer rows: marker 0, 'Before' 1, block 2-4, 'After' 5
    local state = open_markdown({ 'Before\n$$\nx\n$$\nAfter' })
    h.assert_true(wait_drawn(state, 'hidden to 4'), 'The math should render')
    -- Headless nvim does not fire CursorMoved for fed keys: fire it by hand.
    local function move(keys)
      h.feedkeys(keys)
      vim.api.nvim_exec_autocmds('CursorMoved', { buffer = state.facade_buf })
    end
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = state.facade_buf })
    move('j')
    h.assert_eq(vim.api.nvim_win_get_cursor(0)[1], 6, 'j should step over the block')
    move('k')
    h.assert_eq(vim.api.nvim_win_get_cursor(0)[1], 2, 'k should step back over it')
  end)
end)

h.run_test('editing_a_cell_shows_its_source_until_it_closes', function()
  if not have_tools then
    return
  end
  with_fake_image_layer(function()
    -- Buffer rows: first cell's math on row 2, second cell's on row 7
    local state = open_markdown({ 'Text\n$$x$$', 'Other\n$$y$$' })
    h.assert_true(wait_drawn(state, '7: hidden'), 'Both cells should render')

    h.enter_cell(1)
    h.assert_eq(drawn(state):find('[12]: '), nil, 'The edited cell should show its source')
    h.assert_true(drawn(state):find('7: hidden', 1, true) ~= nil, 'Other cells stay rendered')

    h.exit_cell()
    h.assert_true(wait_drawn(state, '2: hidden'), 'Closing the float should render the cell again')
  end)
end)

h.run_test('cell_operations_keep_math_in_place', function()
  if not have_tools then
    return
  end
  with_fake_image_layer(function()
    local state = open_markdown({ '$$x$$' })
    h.assert_true(wait_drawn(state, '1: hidden'), 'The math should render')

    require('ipynb.facade').insert_cell(state, 0, 'markdown')
    -- The new empty cell takes rows 0-2 and a blank line; the math moves to row 5.
    h.assert_true(wait_drawn(state, '5: hidden'), 'The math should follow its cell')
    h.assert_eq(drawn(state):find('^[01]: '), nil, 'Nothing should be left at the old rows')
  end)
end)

h.run_test('inline_math_replaces_its_source_within_the_line', function()
  if not have_tools then
    return
  end
  with_fake_image_layer(function()
    -- Buffer row 1: 'Energy $E = mc^2$ and $$x$$ inline.'
    local state = open_markdown({ 'Energy $E = mc^2$ and $$x$$ inline, not $5.' })
    h.assert_true(wait_drawn(state, '1:22'), 'The math should render')
    h.assert_eq(drawn(state), '1:7: conceal [image row 1]\n1:22: conceal [image row 1]')
  end)
end)

h.run_test('colorscheme_change_renders_math_in_the_new_color', function()
  if not have_tools then
    return
  end
  with_fake_image_layer(function()
    local paths = {}
    images.get_file_virt_lines = function(_, _, path)
      table.insert(paths, path)
      return { { { '[image]', 'Normal' } } }, 1
    end
    local normal = vim.api.nvim_get_hl(0, { name = 'Normal' })
    local ok, err = xpcall(function()
      local state = open_markdown({ '$$x$$' })
      h.assert_true(wait_drawn(state, 'hidden to 1'), 'The math should render')
      local before = paths[#paths]

      -- A colorscheme clears the image highlights and changes the text color.
      vim.api.nvim_set_hl(0, 'Normal', { fg = '#123456', bg = normal.bg })
      vim.api.nvim_exec_autocmds('ColorScheme', {})
      h.assert_true(vim.wait(20000, function()
        return paths[#paths] ~= before
      end, 10), 'The math should render again in the new color')
    end, debug.traceback)
    vim.api.nvim_set_hl(0, 'Normal', normal)
    assert(ok, err)
  end)
end)

h.run_test('broken_math_keeps_its_source_and_shows_the_error', function()
  if not have_tools then
    return
  end
  with_fake_image_layer(function()
    local state = open_markdown({ 'Broken:\n$$\\frac{1}{$$\nTwo $\\undefined$ and $\\alsoundefined$, one $\\nope$.' })
    h.assert_true(wait_drawn(state, 'LaTeX error.*\n.*LaTeX error'), 'The errors should be shown')
    h.assert_eq(drawn(state), table.concat({
      '2: LaTeX error: File ended while scanning use of \\frac',
      '3: LaTeX error: Undefined control sequence (+2 more)',
    }, '\n'))
  end)
end)

if h.summary() then
  vim.cmd('qa!')
else
  vim.cmd('cquit 1')
end
