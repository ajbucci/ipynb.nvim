-- ipynb/lsp/rename.lua - LSP rename support
-- Intercepts textDocument/rename to apply edits to facade buffer

local M = {}

local util = require('ipynb.lsp.util')
local uri_mod = require('ipynb.lsp.uri')

---Handle textDocument/rename interception
---@param ctx BufferContext
---@param method string
---@param params table
---@param handler function
---@param client table
---@param req_bufnr number
---@return boolean handled, number|nil req_id
local function handle_rename(ctx, method, params, handler, client, req_bufnr)
  local state = ctx.state

  -- Only intercept for facade/edit buffers, NOT shadow buffer
  if ctx.is_shadow_buf then
    return false, nil
  end

  -- Rewrite params to point to shadow buffer
  params = util.rewrite_params(params, state, ctx.is_edit_buf, ctx.line_offset)

  -- Wrap handler to apply edits ourselves
  local orig_handler = handler
  handler = function(err, result, ctx_arg, config)
    if err then
      if orig_handler then
        orig_handler(err, result, ctx_arg, config)
      end
      return
    end

    if not result then
      if orig_handler then
        orig_handler(nil, nil, ctx_arg, config)
      end
      return
    end

    -- Apply workspace edit to facade buffer
    vim.schedule(function()
      M.apply_workspace_edit(state, result, ctx.is_edit_buf)
      -- Don't call orig_handler - we already applied edits and notified user
    end)
  end

  -- Make the request to shadow buffer through the original client.request
  local orig_request = rawget(client, '_orig_request') or client.request
  return true, select(2, orig_request(client, method, params, handler, state.shadow_buf))
end

---Apply a workspace edit from rename to the facade buffer
---@param state NotebookState
---@param workspace_edit table LSP WorkspaceEdit
---@param is_edit_buf boolean Whether the rename was triggered from edit buffer
function M.apply_workspace_edit(state, workspace_edit, is_edit_buf)
  local cells_mod = require('ipynb.cells')
  local shadow = require('ipynb.lsp.shadow')
  local diagnostics = require('ipynb.lsp.diagnostics')

  -- Extract all edits from workspace edit (we know they're for our notebook)
  local edits = {}

  if workspace_edit.changes then
    -- Map of URI -> TextEdit[]
    for _, uri_edits in pairs(workspace_edit.changes) do
      for _, edit in ipairs(uri_edits) do
        table.insert(edits, edit)
      end
    end
  elseif workspace_edit.documentChanges then
    -- Array of TextDocumentEdit
    for _, change in ipairs(workspace_edit.documentChanges) do
      for _, edit in ipairs(change.edits or {}) do
        table.insert(edits, edit)
      end
    end
  end

  if #edits == 0 then
    vim.notify('Rename: no changes to apply', vim.log.levels.INFO)
    return
  end

  local count = #edits

  -- Sort edits bottom-to-top to apply without offset issues
  table.sort(edits, function(a, b)
    if a.range.start.line == b.range.start.line then
      return a.range.start.character > b.range.start.character
    end
    return a.range.start.line > b.range.start.line
  end)

  -- Apply each edit individually to preserve extmarks on unaffected lines
  vim.bo[state.facade_buf].modifiable = true
  for _, edit in ipairs(edits) do
    local start_line = edit.range.start.line
    local end_line = edit.range['end'].line
    local start_char = edit.range.start.character
    local end_char = edit.range['end'].character

    -- Get the affected lines
    local lines = vim.api.nvim_buf_get_lines(state.facade_buf, start_line, end_line + 1, false)
    if #lines > 0 then
      -- Apply the edit to the lines
      local prefix = lines[1]:sub(1, start_char)
      local suffix = lines[#lines]:sub(end_char + 1)
      local new_text_lines = vim.split(edit.newText, '\n', { plain = true })

      -- Build replacement
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

      -- Replace just these lines
      pcall(vim.api.nvim_buf_set_lines, state.facade_buf, start_line, end_line + 1, false, replacement)
    end
  end
  vim.bo[state.facade_buf].modifiable = false

  -- Sync cell sources from facade
  cells_mod.sync_cells_from_facade(state)
  shadow.refresh_shadow(state)
  diagnostics.refresh_facade_diagnostics(state)

  -- Update edit buffer if we're in one
  if is_edit_buf and state.edit_state and state.edit_state.buf then
    local edit_buf = state.edit_state.buf
    if vim.api.nvim_buf_is_valid(edit_buf) then
      local cell_idx = state.edit_state.cell_idx
      local content_start, content_end = cells_mod.get_content_range(state, cell_idx)
      if content_start and content_end then
        local new_lines = vim.api.nvim_buf_get_lines(state.facade_buf, content_start, content_end + 1, false)
        vim.api.nvim_buf_set_lines(edit_buf, 0, -1, false, new_lines)
        state.edit_state.end_line = content_start + #new_lines - 1
      end
    end
  end

  vim.notify(string.format('Renamed %d occurrence%s', count, count == 1 and '' or 's'), vim.log.levels.INFO)
end

---Install the rename interceptor
function M.install()
  local request = require('ipynb.lsp.request')
  request.register_interceptor('textDocument/rename', handle_rename)
end

return M
