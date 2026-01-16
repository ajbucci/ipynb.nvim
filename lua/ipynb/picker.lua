-- ipynb/picker.lua - Cell picker using vim.ui.select

local M = {}

---Jump to a cell using vim.ui.select
---Users can override vim.ui.select with telescope, fzf-lua, etc. via dressing.nvim
function M.jump_to_cell()
  local state = require('ipynb.state').get()
  if not state then
    vim.notify('No notebook open', vim.log.levels.WARN)
    return
  end

  if #state.cells == 0 then
    vim.notify('No cells in notebook', vim.log.levels.WARN)
    return
  end

  local cells = require('ipynb.cells')
  local items = {}

  for i, cell in ipairs(state.cells) do
    -- Get first non-empty line as preview
    local preview = ''
    for line in cell.source:gmatch('[^\n]+') do
      local trimmed = line:match('^%s*(.-)%s*$')
      if trimmed and trimmed ~= '' then
        preview = trimmed
        break
      end
    end

    -- Truncate long previews
    if #preview > 60 then
      preview = preview:sub(1, 57) .. '...'
    end

    -- Build display prefix based on cell type and state
    local prefix
    if cell.type == 'code' then
      if cell.execution_state == 'busy' then
        prefix = '[*]'
      elseif cell.execution_state == 'queued' then
        prefix = '[.]'
      elseif cell.execution_count then
        prefix = string.format('[%d]', cell.execution_count)
      else
        prefix = '[ ]'
      end
    else
      -- Markdown/raw cells show type indicator
      prefix = cell.type == 'markdown' and '[M]' or '[R]'
    end

    table.insert(items, {
      idx = i,
      cell = cell,
      prefix = prefix,
      preview = preview,
    })
  end

  vim.ui.select(items, {
    prompt = 'Jump to cell:',
    format_item = function(item)
      return string.format('%s %s', item.prefix, item.preview)
    end,
  }, function(choice)
    if not choice then
      return
    end

    -- Navigate to cell (first content line, after marker)
    local start_line = cells.get_cell_range(state, choice.idx)
    vim.api.nvim_win_set_cursor(0, { start_line + 2, 0 })
  end)
end

return M
