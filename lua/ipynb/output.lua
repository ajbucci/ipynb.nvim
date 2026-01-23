-- ipynb/output.lua - Cell output rendering
-- Renders output as virtual lines (virt_lines extmarks)

local M = {}

local output_ns = vim.api.nvim_create_namespace('notebook_outputs')

---Convert Jupyter text to string (handles both string and array formats)
---@param text string|table|nil
---@return string
local function to_string(text)
  if type(text) == 'table' then
    return table.concat(text, '')
  end
  return text or ''
end

---Helper to add text/plain data as virtual lines (handles string or table)
---@param lines table[] Virtual lines array to append to
---@param text_plain string|table The text/plain data
---@param prefix string|nil Optional prefix for first line (e.g., "Out: ")
---@param hl string Highlight group
local function add_text_plain_lines(lines, text_plain, prefix, hl)
  local text = to_string(text_plain)

  -- Remove single trailing newline (output formatting), but preserve intentional blank lines
  if text:sub(-1) == '\n' then
    text = text:sub(1, -2)
  end

  -- Split by newlines
  local text_lines = vim.split(text, '\n', { plain = true })

  for i, line in ipairs(text_lines) do
    if i == 1 and prefix then
      table.insert(lines, { { prefix .. line, hl } })
    else
      table.insert(lines, { { line, hl } })
    end
  end
end

---Render a single output item as virtual line specs
---@param output table Output object
---@return table[] Virtual line specs
function M.render_output(output)
  local lines = {}
  local images_mod = require('ipynb.images')

  if output.output_type == 'stream' then
    local text = to_string(output.text)
    for line in text:gmatch('[^\n]+') do
      table.insert(lines, { { line, 'IpynbOutput' } })
    end
  elseif output.output_type == 'execute_result' then
    -- Check if this has image data
    local has_image = images_mod.get_image_data(output)

    if has_image then
      -- Image will be rendered by snacks.nvim if available, skip text here to avoid extmark conflict
      if not images_mod.is_available() then
        table.insert(lines, { { '[Image output - install snacks.nvim to view]', 'Comment' } })
      end
    else
      if output.data and output.data['text/plain'] then
        add_text_plain_lines(lines, output.data['text/plain'], 'Out: ', 'IpynbOutput')
      else
        table.insert(lines, { { 'Out: ' .. vim.inspect(output.data), 'IpynbOutput' } })
      end
    end
  elseif output.output_type == 'error' then
    local msg = (output.ename or 'Error') .. ': ' .. (output.evalue or 'Unknown error')
    table.insert(lines, { { msg, 'IpynbOutputError' } })
    -- Include traceback if available
    if output.traceback then
      for _, tb_line in ipairs(output.traceback) do
        -- Strip ANSI codes from traceback
        local clean = tb_line:gsub('\027%[[%d;]*m', '')
        table.insert(lines, { { clean, 'IpynbOutputError' } })
      end
    end
  elseif output.output_type == 'display_data' then
    -- Check if this has image data
    local has_image = images_mod.get_image_data(output)

    if has_image then
      -- Image will be rendered inline if snacks.nvim available
      if images_mod.is_available() then
        -- Show text/plain as caption above image (split by newlines)
        if output.data and output.data['text/plain'] then
          add_text_plain_lines(lines, output.data['text/plain'], nil, 'IpynbOutput')
        end
      else
        table.insert(lines, { { '[Image output - install snacks.nvim to view]', 'Comment' } })
      end
    else
      if output.data and output.data['text/plain'] then
        add_text_plain_lines(lines, output.data['text/plain'], nil, 'IpynbOutput')
      else
        table.insert(lines, { { '[Display]', 'IpynbOutput' } })
      end
    end
  end

  return lines
end

---Build plain text lines from cell outputs (for float buffer)
---@param cell table Cell with outputs
---@return string[] lines Plain text lines
function M.build_output_text(cell)
  local lines = {}
  local images_mod = require('ipynb.images')

  if not cell.outputs or #cell.outputs == 0 then
    return lines
  end

  for _, output in ipairs(cell.outputs) do
    if output.output_type == 'stream' then
      local text = to_string(output.text)
      for line in text:gmatch('[^\n]+') do
        table.insert(lines, line)
      end
    elseif output.output_type == 'execute_result' then
      local has_image = images_mod.get_image_data(output)
      if has_image and not images_mod.is_available() then
        table.insert(lines, '[Image output - install snacks.nvim to view]')
      elseif output.data and output.data['text/plain'] then
        local text = to_string(output.data['text/plain'])
        for i, line in ipairs(vim.split(text, '\n', { plain = true })) do
          if i == 1 then
            table.insert(lines, 'Out: ' .. line)
          else
            table.insert(lines, line)
          end
        end
      else
        local inspected = vim.inspect(output.data)
        for i, line in ipairs(vim.split(inspected, '\n', { plain = true })) do
          if i == 1 then
            table.insert(lines, 'Out: ' .. line)
          else
            table.insert(lines, line)
          end
        end
      end
    elseif output.output_type == 'error' then
      local ename = output.ename or 'Error'
      local evalue = output.evalue or 'Unknown error'
      -- Split error message by newlines
      for i, line in ipairs(vim.split(evalue, '\n', { plain = true })) do
        if i == 1 then
          table.insert(lines, ename .. ': ' .. line)
        else
          table.insert(lines, line)
        end
      end
      if output.traceback then
        for _, tb_line in ipairs(output.traceback) do
          local clean = tb_line:gsub('\027%[[%d;]*m', '')
          -- Traceback lines might also contain newlines
          for _, l in ipairs(vim.split(clean, '\n', { plain = true })) do
            table.insert(lines, l)
          end
        end
      end
    elseif output.output_type == 'display_data' then
      local has_image = images_mod.get_image_data(output)
      if has_image and not images_mod.is_available() then
        table.insert(lines, '[Image output - install snacks.nvim to view]')
      elseif output.data and output.data['text/plain'] then
        local text = to_string(output.data['text/plain'])
        for _, line in ipairs(vim.split(text, '\n', { plain = true })) do
          table.insert(lines, line)
        end
      else
        table.insert(lines, '[Display]')
      end
    end
  end

  return lines
end

---Render outputs for a cell as virtual lines with true text/image interleaving
---All outputs (text and images) are combined into a single extmark's virt_lines
---This guarantees correct ordering: text1 → img1 → text2 → img2 → etc.
---@param state NotebookState
---@param cell_idx number
---@param skip_image_render boolean|nil Unused, kept for API compatibility
function M.render_outputs(state, cell_idx, skip_image_render)
  local cell = state.cells[cell_idx]
  if not cell.outputs or #cell.outputs == 0 then
    return
  end

  local cells_mod = require('ipynb.cells')
  local images_mod = require('ipynb.images')
  local _, end_line = cells_mod.get_cell_range(state, cell_idx)

  -- Clear old extmark for this cell
  if cell.output_extmark then
    pcall(vim.api.nvim_buf_del_extmark, state.facade_buf, output_ns, cell.output_extmark)
    cell.output_extmark = nil
  end

  -- Clear existing images
  if cell.id then
    images_mod.clear_images(state, cell.id)
  end

  -- Build all virt_lines in order with true interleaving
  local virt_lines = {}
  local image_index = 0

  -- Output separator
  table.insert(virt_lines, { { '┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄', 'IpynbBorder' } })

  for _, output in ipairs(cell.outputs) do
    local has_image = images_mod.get_image_data(output)

    if has_image and images_mod.supports_placeholders() then
      -- Get image placeholder lines for true interleaving
      image_index = image_index + 1
      local img_lines, _ = images_mod.get_image_virt_lines(state, cell, output, image_index)
      if img_lines then
        for _, line in ipairs(img_lines) do
          table.insert(virt_lines, line)
        end
      else
        -- Fallback if image loading failed
        table.insert(virt_lines, { { '[Image failed to load]', 'Comment' } })
      end
    elseif has_image and images_mod.is_available() then
      -- Terminal doesn't support placeholders, show placeholder text
      table.insert(virt_lines, { { '[Image - placeholders not supported]', 'Comment' } })
    else
      -- Add text lines to virt_lines array
      local rendered = M.render_output(output)
      for _, line in ipairs(rendered) do
        table.insert(virt_lines, line)
      end
    end
  end

  -- Create single extmark with all virt_lines (text + images interleaved)
  -- Order is guaranteed by array order
  if #virt_lines > 0 then
    cell.output_extmark = vim.api.nvim_buf_set_extmark(state.facade_buf, output_ns, end_line, 0, {
      virt_lines = virt_lines,
      undo_restore = false,
      strict = false,
    })
  end
end

---Clear outputs for a cell
---@param state NotebookState
---@param cell_idx number
function M.clear_outputs(state, cell_idx)
  local cell = state.cells[cell_idx]
  if not cell then
    return
  end

  local images_mod = require('ipynb.images')

  -- Clear images first (using cell.id)
  if cell.id then
    images_mod.clear_images(state, cell.id)
  end

  -- Clear output extmark
  if cell.output_extmark then
    pcall(vim.api.nvim_buf_del_extmark, state.facade_buf, output_ns, cell.output_extmark)
    cell.output_extmark = nil
  end

  cell.outputs = {}
end

---Clear all outputs
---@param state NotebookState
function M.clear_all_outputs(state)
  local images_mod = require('ipynb.images')

  -- Clear all images first
  images_mod.clear_all_images(state)

  for i, _ in ipairs(state.cells) do
    M.clear_outputs(state, i)
  end
end

---Render all cell outputs
---@param state NotebookState
function M.render_all(state)
  -- Render each cell's outputs fully (including images) before moving to next cell
  -- This maintains correct text/image interleaving within each cell
  for i, cell in ipairs(state.cells) do
    if cell.type == 'code' and cell.outputs and #cell.outputs > 0 then
      M.render_outputs(state, i, false)  -- render images synchronously
    end
  end
end

---Open cell output in a floating buffer for copying/inspection
---@param state NotebookState
---@param cell_idx number|nil Cell index (nil = current cell)
function M.open_output_float(state, cell_idx)
  local cells_mod = require('ipynb.cells')

  -- Get current cell if not specified
  if not cell_idx then
    local cursor_line = vim.api.nvim_win_get_cursor(0)[1] - 1
    cell_idx = cells_mod.get_cell_at_line(state, cursor_line)
  end

  if not cell_idx then
    vim.notify('No cell at cursor', vim.log.levels.WARN)
    return
  end

  local cell = state.cells[cell_idx]
  if not cell then
    vim.notify('Cell not found', vim.log.levels.WARN)
    return
  end

  if not cell.outputs or #cell.outputs == 0 then
    vim.notify('No output for this cell', vim.log.levels.INFO)
    return
  end

  -- Build plain text output
  local lines = M.build_output_text(cell)
  if #lines == 0 then
    vim.notify('No text output for this cell', vim.log.levels.INFO)
    return
  end

  -- Create buffer for output
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  -- Buffer settings
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = 'notebook_output'

  -- Calculate float dimensions
  local width = math.min(100, math.floor(vim.o.columns * 0.8))
  local height = math.min(#lines + 2, math.floor(vim.o.lines * 0.7))

  -- Find max line width for better sizing
  local max_line_width = 0
  for _, line in ipairs(lines) do
    max_line_width = math.max(max_line_width, vim.fn.strdisplaywidth(line))
  end
  width = math.min(math.max(width, max_line_width + 4), vim.o.columns - 4)

  -- Center the float
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  -- Open float window
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    row = row,
    col = col,
    width = width,
    height = height,
    style = 'minimal',
    border = 'rounded',
    title = ' Cell Output [' .. cell_idx .. '] ',
    title_pos = 'center',
  })

  -- Window settings
  vim.wo[win].wrap = true
  vim.wo[win].cursorline = true
  vim.wo[win].number = true

  -- Keymaps for the output float
  local close = function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  local opts = { buffer = buf, silent = true, nowait = true }
  vim.keymap.set('n', 'q', close, opts)
  vim.keymap.set('n', '<Esc>', close, opts)
  vim.keymap.set('n', '<C-c>', close, opts)

  -- Yank all output
  vim.keymap.set('n', 'Y', function()
    local all_text = table.concat(lines, '\n')
    vim.fn.setreg('+', all_text)
    vim.fn.setreg('"', all_text)
    vim.notify('Output copied to clipboard', vim.log.levels.INFO)
  end, vim.tbl_extend('force', opts, { desc = 'Yank all output' }))
end

return M
