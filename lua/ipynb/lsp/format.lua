-- ipynb/lsp/format.lua - Cell formatting
-- Wraps vim.lsp.buf.format, registers interceptors for formatting requests
-- Provides format_cell, format_all_cells, format_current_cell

local M = {}

local util = require('ipynb.lsp.util')

---Apply LSP text edits to a Lua table of lines (avoids buffer side effects)
---@param lines string[] Current lines (will be modified in place)
---@param edits table[] LSP TextEdit objects with range and newText
---@return string[] Modified lines
function M.apply_edits_to_lines(lines, edits)
  if not edits or #edits == 0 then
    return lines
  end

  -- Sort edits in reverse order to apply from bottom to top
  local sorted = vim.deepcopy(edits)
  table.sort(sorted, function(a, b)
    if a.range.start.line == b.range.start.line then
      return a.range.start.character > b.range.start.character
    end
    return a.range.start.line > b.range.start.line
  end)

  -- Apply each edit
  for _, edit in ipairs(sorted) do
    local start_line = edit.range.start.line
    local end_line = edit.range['end'].line
    local start_char = edit.range.start.character
    local end_char = edit.range['end'].character
    local new_text_lines = vim.split(edit.newText, '\n', { plain = true })

    if start_line >= 0 and start_line <= #lines then
      local prefix = ''
      local suffix = ''

      if lines[start_line + 1] then
        prefix = string.sub(lines[start_line + 1], 1, start_char)
      end
      if lines[end_line + 1] then
        suffix = string.sub(lines[end_line + 1], end_char + 1)
      end

      -- Build replacement lines
      local replacement = {}
      for i, text in ipairs(new_text_lines) do
        if i == 1 then
          text = prefix .. text
        end
        if i == #new_text_lines then
          text = text .. suffix
        end
        table.insert(replacement, text)
      end

      -- Remove old lines and insert new
      for _ = start_line, end_line do
        if lines[start_line + 1] then
          table.remove(lines, start_line + 1)
        end
      end
      for i, line in ipairs(replacement) do
        table.insert(lines, start_line + i, line)
      end
    end
  end

  return lines
end

---Handle textDocument/formatting interception
---@param ctx BufferContext
---@param _method string
---@param _params table
---@param handler function
---@param _client table
---@param _req_bufnr number
---@return boolean handled, number|nil req_id
local function handle_document_format(ctx, _method, _params, handler, _client, _req_bufnr)
  local state = ctx.state
  local format_config = require('ipynb.config').get().format

  -- Only intercept for facade/edit buffers when enabled, NOT shadow buffer
  if not format_config.enabled or ctx.is_shadow_buf or not state then
    return false, nil
  end

  -- Document formatting: format all cells (or just current cell if in edit float)
  vim.schedule(function()
    if ctx.is_edit_buf and state.edit_state then
      -- In edit float: format just this cell
      M.format_cell(state, state.edit_state.cell_idx, function()
        if handler then handler(nil, {}) end
      end)
    else
      -- In facade: format all cells
      M.format_all_cells(state, function()
        if handler then handler(nil, {}) end
      end)
    end
  end)
  return true, 1
end

---Handle textDocument/rangeFormatting interception
---@param ctx BufferContext
---@param method string
---@param params table
---@param handler function
---@param client vim.lsp.Client
---@param _req_bufnr number
---@return boolean handled, number|nil req_id
local function handle_range_format(ctx, method, params, handler, client, _req_bufnr)
  local state = ctx.state
  local format_config = require('ipynb.config').get().format

  -- Only intercept for facade/edit buffers when enabled, NOT shadow buffer
  if not format_config.enabled or ctx.is_shadow_buf or not state then
    return false, nil
  end

  if not params or not params.range then
    return false, nil
  end

  local cells_mod = require('ipynb.cells')

  -- Edit buffer: range is always within single cell (the one being edited)
  if ctx.is_edit_buf and state.edit_state then
    local cell = state.cells[state.edit_state.cell_idx]
    if not cell or cell.type ~= 'code' then
      vim.schedule(function()
        vim.notify('Can only format code cells', vim.log.levels.INFO)
        if handler then handler(nil, {}) end
      end)
      return true, 1
    end

    -- Pass through to shadow buffer, apply edits to edit buffer
    local rewritten_params = util.rewrite_params(params, state, ctx.is_edit_buf, ctx.line_offset)
    local orig_handler = handler
    local wrapped_handler = function(err, result, ...)
      if err or not result or #result == 0 then
        if orig_handler then orig_handler(err, result, ...) end
        return
      end

      -- Translate edits back to edit buffer coordinates and apply
      vim.schedule(function()
        local edit_state = state.edit_state
        if not edit_state then
          if orig_handler then orig_handler(nil, {}) end
          return
        end
        local edit_buf = edit_state.buf
        local offset = edit_state.start_line
        local translated = {}
        for _, edit in ipairs(result) do
          local e = vim.deepcopy(edit)
          e.range.start.line = e.range.start.line - offset
          e.range['end'].line = e.range['end'].line - offset
          table.insert(translated, e)
        end

        -- Apply edits to lines table, then set buffer
        -- (avoids apply_text_edits registering buffer with current window)
        if vim.api.nvim_buf_is_valid(edit_buf) and #translated > 0 then
          local lines = vim.api.nvim_buf_get_lines(edit_buf, 0, -1, false)
          M.apply_edits_to_lines(lines, translated)

          -- Check if edit session is still active (user might have closed float during format)
          -- If not active, skip sync since facade is non-modifiable
          if not state.edit_state or state.edit_state.buf ~= edit_buf then
            state.skip_sync = true
          end
          vim.api.nvim_buf_set_lines(edit_buf, 0, -1, false, lines)
          state.skip_sync = false
        end

        if orig_handler then orig_handler(nil, {}) end
      end)
    end

    -- Make the request to shadow buffer through the original client.request
    local orig_request = rawget(client, '_orig_request') or client.request
    return true, select(2, orig_request(client, method, rewritten_params, wrapped_handler, state.shadow_buf))
  end

  -- Facade buffer: check if range is within a single cell
  local start_line = params.range.start.line
  local end_line = params.range['end'].line

  local start_cell_idx = cells_mod.get_cell_at_line(state, start_line)
  local end_cell_idx = cells_mod.get_cell_at_line(state, end_line)

  if not start_cell_idx or not end_cell_idx then
    vim.schedule(function()
      vim.notify('Cannot format: selection outside cell content', vim.log.levels.WARN)
      if handler then handler(nil, {}) end
    end)
    return true, 1
  end

  if start_cell_idx ~= end_cell_idx then
    vim.schedule(function()
      vim.notify('Cannot format range across cell boundaries', vim.log.levels.WARN)
      if handler then handler(nil, {}) end
    end)
    return true, 1
  end

  -- Range is within single cell - check it's a code cell
  local cell = state.cells[start_cell_idx]
  if not cell or cell.type ~= 'code' then
    vim.schedule(function()
      vim.notify('Can only format code cells', vim.log.levels.INFO)
      if handler then handler(nil, {}) end
    end)
    return true, 1
  end

  -- Pass through to shadow buffer, but wrap handler to apply edits ourselves
  local rewritten_params = util.rewrite_params(params, state, ctx.is_edit_buf, ctx.line_offset)
  local orig_handler = handler
  local wrapped_handler = function(err, result, ...)
    if err or not result or #result == 0 then
      if orig_handler then orig_handler(err, result, ...) end
      return
    end

    -- Apply edits to facade buffer ourselves
    vim.schedule(function()
      if not state.facade_buf or not vim.api.nvim_buf_is_valid(state.facade_buf) then
        if orig_handler then orig_handler(nil, {}) end
        return
      end
      vim.bo[state.facade_buf].modifiable = true
      pcall(vim.lsp.util.apply_text_edits, result, state.facade_buf, 'utf-16')
      vim.bo[state.facade_buf].modifiable = false

      -- Sync changes
      cells_mod.sync_cells_from_facade(state)
      require('ipynb.lsp.shadow').refresh_shadow(state)
      cells_mod.place_markers(state)
      require('ipynb.visuals').render_all(state)
      require('ipynb.lsp.diagnostics').refresh_facade_diagnostics(state)

      if orig_handler then orig_handler(nil, {}) end -- Empty result, we applied
    end)
  end

  local orig_request = rawget(client, '_orig_request') or client.request
  return true, select(2, orig_request(client, method, rewritten_params, wrapped_handler, state.shadow_buf))
end

---Format a single cell using LSP range formatting
---@param state NotebookState
---@param cell_idx number
---@param callback function|nil Optional callback called after formatting completes
function M.format_cell(state, cell_idx, callback)
  local cells_mod = require('ipynb.cells')
  local shadow = require('ipynb.lsp.shadow')
  local diagnostics = require('ipynb.lsp.diagnostics')
  local cell = state.cells[cell_idx]

  -- Only format code cells
  if cell.type ~= 'code' then
    if callback then callback() end
    return
  end

  -- Check if LSP is available
  if not state.shadow_buf or not vim.api.nvim_buf_is_valid(state.shadow_buf) then
    vim.notify('No LSP available for formatting', vim.log.levels.WARN)
    if callback then callback() end
    return
  end

  local clients = vim.lsp.get_clients({ bufnr = state.shadow_buf })
  local has_formatter = false
  for _, lsp_client in ipairs(clients) do
    if lsp_client:supports_method('textDocument/rangeFormatting') then
      has_formatter = true
      break
    end
  end

  if not has_formatter then
    vim.notify('No LSP formatter available', vim.log.levels.WARN)
    if callback then callback() end
    return
  end

  -- Get cell content range
  local content_start, content_end = cells_mod.get_content_range(state, cell_idx)
  if not content_start or not content_end then
    if callback then callback() end
    return
  end

  -- Build formatting request params
  local params = {
    textDocument = { uri = vim.uri_from_fname(state.shadow_path) },
    range = {
      start = { line = content_start, character = 0 },
      ['end'] = { line = content_end + 1, character = 0 },
    },
    options = {
      tabSize = vim.bo[state.shadow_buf].tabstop or 4,
      insertSpaces = vim.bo[state.shadow_buf].expandtab,
    },
  }

  -- Request formatting from shadow buffer
  vim.lsp.buf_request(state.shadow_buf, 'textDocument/rangeFormatting', params,
    function(err, result)
      if err then
        vim.notify('Format error: ' .. tostring(err), vim.log.levels.ERROR)
        if callback then callback() end
        return
      end

      if not result or #result == 0 then
        -- No changes needed
        if callback then callback() end
        return
      end

      -- Re-fetch content range (might have changed if user edited while waiting)
      local current_start, current_end = cells_mod.get_content_range(state, cell_idx)
      if not current_start or not current_end then
        if callback then callback() end
        return
      end

      -- Translate coordinates: shadow buffer -> cell-relative (0-based)
      local translated = {}
      for _, edit in ipairs(result) do
        local e = vim.deepcopy(edit)
        e.range.start.line = e.range.start.line - content_start
        e.range['end'].line = e.range['end'].line - content_start
        -- Clamp to valid range (in case formatter returns out-of-range edits)
        if e.range.start.line >= 0 then
          table.insert(translated, e)
        end
      end

      if #translated > 0 then
        -- Get current cell content and apply edits
        local new_lines = vim.api.nvim_buf_get_lines(state.facade_buf, current_start, current_end + 1, false)
        M.apply_edits_to_lines(new_lines, translated)

        -- Trim trailing blank lines (formatters often add these, not useful in notebooks)
        local max_trailing = require('ipynb.config').get().format.trailing_blank_lines
        local trailing_count = 0
        for i = #new_lines, 1, -1 do
          if new_lines[i]:match('^%s*$') then
            trailing_count = trailing_count + 1
          else
            break
          end
        end
        local to_remove = math.max(0, trailing_count - max_trailing)
        for _ = 1, to_remove do
          if #new_lines > 1 then
            table.remove(new_lines)
          end
        end

        local new_count = #new_lines
        local old_count = current_end - current_start + 1
        local line_count_changed = old_count ~= new_count

        -- Update cell source
        cell.source = table.concat(new_lines, '\n')

        -- Update shadow buffer
        shadow.sync_shadow_region(state, current_start, current_end + 1, new_lines, cell.type)

        -- Update facade buffer (pcall to suppress LSP change tracking errors)
        -- Keep modifiable if edit session is active (edit.lua:281 keeps it modifiable during editing)
        local in_edit_session = state.edit_state ~= nil
        vim.bo[state.facade_buf].modifiable = true
        pcall(vim.api.nvim_buf_set_lines, state.facade_buf, current_start, current_end + 1, false, new_lines)
        if not in_edit_session then
          vim.bo[state.facade_buf].modifiable = false
        end

        -- Update edit buffer if it exists and is valid (for when formatting from edit float)
        -- Skip sync since we already updated facade above
        if cell.edit_buf and vim.api.nvim_buf_is_valid(cell.edit_buf) then
          state.skip_sync = true
          vim.api.nvim_buf_set_lines(cell.edit_buf, 0, -1, false, new_lines)
          state.skip_sync = false
          vim.bo[cell.edit_buf].modified = false
        end

        -- Update edit_state.end_line if we're editing this cell (critical for sync)
        if state.edit_state and state.edit_state.cell_idx == cell_idx then
          state.edit_state.end_line = current_start + new_count - 1
        end

        -- Refresh diagnostics
        diagnostics.refresh_facade_diagnostics(state)

        -- Update markers and visuals if line count changed
        if line_count_changed then
          cells_mod.place_markers(state)
          require('ipynb.visuals').render_all(state)

          -- Resize edit float window if we're in one
          if state.edit_state and state.edit_state.win and vim.api.nvim_win_is_valid(state.edit_state.win) then
            vim.api.nvim_win_set_height(state.edit_state.win, math.max(new_count, 1))
          end
        end
      end

      if callback then callback() end
    end)
end

---Format all code cells in the notebook
---Processes cells bottom-to-top to avoid line offset issues
---@param state NotebookState
---@param callback function|nil Optional callback called after all formatting completes
function M.format_all_cells(state, callback)
  local shadow = require('ipynb.lsp.shadow')

  -- Collect code cell indices in reverse order (bottom to top)
  local code_cells = {}
  for i = #state.cells, 1, -1 do
    if state.cells[i].type == 'code' then
      table.insert(code_cells, i)
    end
  end

  if #code_cells == 0 then
    vim.notify('No code cells to format', vim.log.levels.INFO)
    if callback then callback() end
    return
  end

  local formatted = 0

  local function format_next(idx)
    if idx > #code_cells then
      -- All done
      vim.notify(string.format('Formatted %d cell(s)', formatted), vim.log.levels.INFO)

      -- Final refresh
      shadow.refresh_shadow(state)
      require('ipynb.visuals').render_all(state)

      if callback then callback() end
      return
    end

    local cell_idx = code_cells[idx]
    M.format_cell(state, cell_idx, function()
      formatted = formatted + 1
      -- Process next cell
      format_next(idx + 1)
    end)
  end

  format_next(1)
end

---Format the cell at cursor position
---@param state NotebookState
function M.format_current_cell(state)
  local cells_mod = require('ipynb.cells')
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1] - 1
  local cell_idx, cell = cells_mod.get_cell_at_line(state, cursor_line)

  if not cell_idx or not cell then
    vim.notify('No cell at cursor', vim.log.levels.WARN)
    return
  end

  if cell.type ~= 'code' then
    vim.notify('Can only format code cells', vim.log.levels.INFO)
    return
  end

  M.format_cell(state, cell_idx, function()
    vim.notify('Cell formatted', vim.log.levels.INFO)
  end)
end

---Install the vim.lsp.buf.format wrapper and register interceptors
function M.install()
  local state_mod = require('ipynb.state')
  local request = require('ipynb.lsp.request')

  -- Store original format function
  local orig_buf_format = vim.lsp.buf.format

  -- Register interceptors for formatting methods
  request.register_interceptor('textDocument/formatting', handle_document_format)
  request.register_interceptor('textDocument/rangeFormatting', handle_range_format)

  -- Wrap vim.lsp.buf.format to use our cell formatting for notebooks
  -- On facade buffer: format all cells
  -- On edit buffer: format current cell
  -- Can be disabled with format.enabled = false in config
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.lsp.buf.format = function(opts)
    opts = opts or {}
    local bufnr = util.resolve_bufnr(opts.bufnr)
    local ctx = util.get_buffer_context(bufnr, state_mod)
    local state = ctx.state

    -- Check if notebook formatting is enabled
    local format_config = require('ipynb.config').get().format
    if state and format_config.enabled then
      if ctx.is_edit_buf and state.edit_state then
        -- In edit buffer: format current cell
        M.format_cell(state, state.edit_state.cell_idx, function()
          vim.notify('Cell formatted', vim.log.levels.INFO)
        end)
      else
        -- In facade buffer: format all cells
        M.format_all_cells(state)
      end
      return
    end

    -- Not a notebook buffer or formatting disabled, use original
    return orig_buf_format(opts)
  end
end

return M
