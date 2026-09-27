-- ipynb/markdown_math.lua - Render math in markdown cells as images
-- $$ blocks replace their source lines; inline math becomes a one-row image

local M = {}

local ns = vim.api.nvim_create_namespace('ipynb_markdown_math')
M.ns = ns

local query = nil ---@type vim.treesitter.Query|nil

-- $$ blocks hide their source lines with conceal_lines, new in Neovim 0.11
local hide_lines = vim.fn.has('nvim-0.11') == 1

---@class MathBlock
---@field display boolean A $$ block on its own lines (else inline math)
---@field first number First source line (0-based)
---@field last number Last source line (0-based)
---@field first_col number Byte column where the math starts on its first line
---@field last_col number Byte column where the math ends on its last line (exclusive)
---@field text string LaTeX to render, with its dollar delimiters

---Whether $...$ is math by pandoc's rules, as in Jupyter: no space inside the
---dollars and no digit after the closing one, so "$5 and $10" stays text
---@param text string
---@param after string Character following the closing dollar
---@return boolean
local function is_inline_math(text, after)
  return text:match('^%$[^%s$]') ~= nil and text:match('[^%s]%$$') ~= nil and not after:match('%d')
end

---Undo `\*`, which notebooks use to keep markdown from starting emphasis
---@param text string
---@return string
local function unescape_markdown(text)
  return (text:gsub('(\\+)%*', function(backslashes)
    if #backslashes % 2 == 1 then
      return backslashes:sub(2) .. '*'
    end
  end))
end

---Find the math of a markdown source: $$ blocks on their own lines, and
---single-line inline math. Math in code spans and fences is not math.
---@param source string
---@return MathBlock[] blocks In source order
function M.find_math(source)
  local ok, parser = pcall(vim.treesitter.get_string_parser, source, 'markdown')
  if not ok then
    return {}
  end
  parser:parse(true)
  query = query or vim.treesitter.query.parse('markdown_inline', '(latex_block) @math')

  local lines = vim.split(source, '\n', { plain = true })
  local blocks = {}
  parser:for_each_tree(function(tree, ltree)
    if ltree:lang() ~= 'markdown_inline' then
      return
    end
    for _, node in query:iter_captures(tree:root(), source) do
      local first, first_col, last, last_col = node:range()
      local text = vim.treesitter.get_node_text(node, source)
      local block = { first = first, last = last, first_col = first_col, last_col = last_col, text = text }
      local double = #text > 4 and text:match('^%$%$') and text:match('%$%$$')
      local own_lines = lines[first + 1]:sub(1, first_col):match('^%s*$')
        and lines[last + 1]:sub(last_col + 1):match('^%s*$')
      if double and own_lines then
        block.display = true
        table.insert(blocks, block)
      elseif first == last then
        block.display = false
        if double then
          block.text = '$' .. text:sub(3, -3) .. '$'
          table.insert(blocks, block)
        elseif is_inline_math(text, lines[last + 1]:sub(last_col + 1, last_col + 1)) then
          table.insert(blocks, block)
        end
      end
    end
  end)
  table.sort(blocks, function(a, b)
    return a.first < b.first or (a.first == b.first and a.first_col < b.first_col)
  end)
  for _, block in ipairs(blocks) do
    block.text = unescape_markdown(block.text)
  end
  return blocks
end

---Key a cell's math images are tracked under, apart from its output images
---@param cell Cell
---@return string
local function image_owner(cell)
  return cell.id .. ':math'
end

-- Border highlight of each cell, and its image rows drawn as virtual lines
local border_hls = setmetatable({}, { __mode = 'k' }) ---@type table<Cell, string>
local hanging = setmetatable({}, { __mode = 'k' }) ---@type table<Cell, table[]>

---Gutter chunks continuing a cell's left border (a sign) on a virtual line,
---or nil for a custom gutter layout
---@param buf number
---@param border_hl string
---@return table[]|nil chunks
local function border_gutter(buf, border_hl)
  local win = vim.fn.bufwinid(buf)
  if win == -1 then
    return nil
  end
  local wo = vim.wo[win]
  local fold_width = tonumber(wo.foldcolumn)
  if wo.statuscolumn ~= '' or not fold_width or wo.signcolumn == 'no' or wo.signcolumn:match('^number') then
    return nil
  end
  -- From the options, as textoff lags until the next redraw
  local sign_width = 2 * (tonumber(wo.signcolumn:match('^yes:(%d)')) or 1)
  local number_width = 0
  if wo.number or wo.relativenumber then
    local largest = wo.number and vim.api.nvim_buf_line_count(buf) or vim.api.nvim_win_get_height(win)
    number_width = math.max(wo.numberwidth, #tostring(largest) + 1)
  end
  return {
    { string.rep(' ', fold_width), 'FoldColumn' },
    { require('ipynb.visuals').borders.vertical, { 'SignColumn', border_hl } },
    { string.rep(' ', sign_width - 1), 'SignColumn' },
    { string.rep(' ', number_width), 'LineNr' },
  }
end

---Draw (or redraw) image rows hanging below a block, with the cell's border
---@param buf number
---@param entry { id: number, rows: { indent: table, row: table }[], applied: string|nil }
---@param border_hl string
local function draw_hanging(buf, entry, border_hl)
  local gutter = border_gutter(buf, border_hl)
  local key = vim.inspect(gutter)
  local pos = vim.api.nvim_buf_get_extmark_by_id(buf, ns, entry.id, {})
  if entry.applied == key or not pos[1] then
    return
  end
  local lines = {}
  for _, row in ipairs(entry.rows) do
    local line = vim.list_extend(vim.deepcopy(gutter or {}), { row.indent, row.row[1] })
    table.insert(lines, line)
  end
  vim.api.nvim_buf_set_extmark(buf, ns, pos[1], 0, {
    id = entry.id,
    virt_lines = lines,
    virt_lines_leftcol = gutter ~= nil,
  })
  entry.applied = key
end

---Match the border on a cell's hanging image rows to its left border
---@param state NotebookState
---@param cell_idx number
---@param border_hl string
function M.set_border_hl(state, cell_idx, border_hl)
  local cell = state.cells[cell_idx]
  if not cell then
    return
  end
  border_hls[cell] = border_hl
  for _, entry in ipairs(hanging[cell] or {}) do
    draw_hanging(state.facade_buf, entry, border_hl)
  end
end

---Hang image rows below a line, drawn with the cell's border
---@param buf number
---@param cell Cell
---@param row number
---@param indent table Chunk indenting the image
---@param image_rows table[] Placeholder rows, one virt_line entry each
local function hang(buf, cell, row, indent, image_rows)
  hanging[cell] = hanging[cell] or {}
  -- Blocks on the same line share one extmark to keep their order
  for _, entry in ipairs(hanging[cell]) do
    local pos = vim.api.nvim_buf_get_extmark_by_id(buf, ns, entry.id, {})
    if pos[1] == row then
      for _, image_row in ipairs(image_rows) do
        table.insert(entry.rows, { indent = indent, row = image_row })
      end
      entry.applied = nil
      return draw_hanging(buf, entry, border_hls[cell] or 'IpynbBorder')
    end
  end
  local entry = { id = vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {}), rows = {} }
  for _, image_row in ipairs(image_rows) do
    table.insert(entry.rows, { indent = indent, row = image_row })
  end
  table.insert(hanging[cell], entry)
  draw_hanging(buf, entry, border_hls[cell] or 'IpynbBorder')
end

---Show an image in place of the source lines [first_row, last_row]
---@param buf number
---@param cell Cell
---@param first_row number
---@param last_row number
---@param image_rows table[] Placeholder rows, one virt_line entry each
---@param anchor_row number Nearest line above the block that stays visible
local function place(buf, cell, first_row, last_row, image_rows, anchor_row)
  local lines = vim.api.nvim_buf_get_lines(buf, first_row, last_row + 1, false)
  local indent = { string.rep(' ', vim.fn.strdisplaywidth(lines[1]:match('^%s*'))) }
  -- Concealed text still counts for wrapping, so hide the lines and hang the
  -- image from the line above (virt_lines on hidden lines are hidden)
  vim.api.nvim_buf_set_extmark(buf, ns, first_row, 0, {
    end_row = last_row,
    end_col = #lines[#lines],
    conceal_lines = '',
  })
  hang(buf, cell, anchor_row, indent, image_rows)
end

---The hidden $$ block covering a row, if any
---@param buf number
---@param row number
---@return number|nil first, number|nil last
local function hidden_block_at(buf, row)
  local marks = vim.api.nvim_buf_get_extmarks(buf, ns, { row, 0 }, { row, -1 }, { details = true, overlap = true })
  for _, mark in ipairs(marks) do
    if mark[4].conceal_lines then
      return mark[2], mark[4].end_row
    end
  end
  return nil, nil
end

-- Buffers whose cursor already steps over hidden blocks
local stepping = {} ---@type table<number, boolean>

---Step the cursor over hidden blocks, like over a closed fold
---@param buf number
local function step_over_hidden_blocks(buf)
  if stepping[buf] then
    return
  end
  stepping[buf] = true
  local last_row = nil
  vim.api.nvim_create_autocmd('CursorMoved', {
    group = vim.api.nvim_create_augroup('IpynbMarkdownMath' .. buf, { clear = true }),
    buffer = buf,
    callback = function()
      local cursor = vim.api.nvim_win_get_cursor(0)
      local row, target = cursor[1] - 1, cursor[1] - 1
      local down = last_row == nil or row >= last_row
      for _ = 1, 100 do
        local first, last = hidden_block_at(buf, target)
        if not first then
          break
        end
        target = down and last + 1 or first - 1
      end
      if target ~= row then
        vim.api.nvim_win_set_cursor(0, { target + 1, 0 })
      end
      last_row = target
    end,
  })
end

---Show a one-row image in place of inline math
---@param buf number
---@param row number
---@param col number
---@param end_col number
---@param image_row table Placeholder row, as a virt_line entry
local function place_inline(buf, row, col, end_col, image_row)
  vim.api.nvim_buf_set_extmark(buf, ns, row, col, {
    end_col = end_col,
    conceal = '',
    virt_text = { image_row[1] },
    virt_text_pos = 'inline',
  })
end

---Remove a cell's rendered math, showing its source again
---@param state NotebookState
---@param cell_idx number
function M.clear_cell(state, cell_idx)
  local cell = state.cells[cell_idx]
  -- From the start marker, which a block on the first line hangs from
  local first, last = require('ipynb.cells').get_cell_range(state, cell_idx)
  if first and last then
    vim.api.nvim_buf_clear_namespace(state.facade_buf, ns, first, last)
  end
  if cell then
    hanging[cell] = nil
    if cell.id then
      require('ipynb.images').clear_images(state, image_owner(cell))
    end
  end
end

---Render the math of one markdown cell
---@param state NotebookState
---@param cell_idx number
function M.render_cell(state, cell_idx)
  local cell = state.cells[cell_idx]
  if not cell or not cell.id or not vim.api.nvim_buf_is_valid(state.facade_buf) then
    return
  end
  M.clear_cell(state, cell_idx)
  -- The source shows while the cell is being edited
  if cell.type ~= 'markdown' or (state.edit_state and state.edit_state.cell_id == cell.id) then
    return
  end

  local latex = require('ipynb.latex')
  local images = require('ipynb.images')
  local content_start = require('ipynb.cells').get_content_range(state, cell_idx)
  if not content_start or not images.supports_placeholders() then
    return
  end
  local blocks = M.find_math(cell.source)
  if #blocks == 0 or not latex.is_available() then
    return
  end

  -- Render the cell again, once, when pending images are ready
  local rerender_scheduled = false
  local function rerender()
    if rerender_scheduled then
      return
    end
    rerender_scheduled = true
    vim.schedule(function()
      for idx, other in ipairs(state.cells) do
        if other.id == cell.id then
          M.render_cell(state, idx)
          return
        end
      end
    end)
  end

  local buf = state.facade_buf
  step_over_hidden_blocks(buf)
  local errors = {} ---@type table<number, string[]> Errors by row
  local hidden = nil ---@type { last: number, anchor: number }|nil Last block hidden so far
  for _, block in ipairs(blocks) do
    local first_row, last_row = content_start + block.first, content_start + block.last
    if block.display and not hide_lines then
      goto continue
    end
    local path, err = latex.lookup(block.text, rerender, { hl = 'IpynbMarkdownMath', inline = not block.display })
    if path then
      local image_rows = images.get_file_virt_lines(state, image_owner(cell), path, rerender)
      if image_rows and block.display then
        -- A block right below a hidden one hangs from the same line
        local anchor = (hidden and hidden.last == first_row - 1) and hidden.anchor or first_row - 1
        place(buf, cell, first_row, last_row, image_rows, anchor)
        hidden = { last = last_row, anchor = anchor }
      elseif image_rows then
        place_inline(buf, first_row, block.first_col, block.last_col, image_rows[1])
      end
    elseif err then
      errors[first_row] = errors[first_row] or {}
      table.insert(errors[first_row], err)
    end
    ::continue::
  end

  -- One error message per line
  for row, messages in pairs(errors) do
    local text = 'LaTeX error: ' .. messages[1]
    if #messages > 1 then
      text = ('%s (+%d more)'):format(text, #messages - 1)
    end
    vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
      virt_text = { { text, 'IpynbOutputError' } },
      virt_text_pos = 'eol',
    })
  end
end

---Render the math of every markdown cell
---@param state NotebookState
function M.render_all(state)
  if not vim.api.nvim_buf_is_valid(state.facade_buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(state.facade_buf, ns, 0, -1)
  -- Including cells deleted or no longer markdown
  local images = require('ipynb.images')
  for owner in pairs(state.images or {}) do
    if owner:match(':math$') then
      images.clear_images(state, owner)
    end
  end
  for idx, cell in ipairs(state.cells) do
    if cell.type == 'markdown' then
      M.render_cell(state, idx)
    end
  end
end

return M
