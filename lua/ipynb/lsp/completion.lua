-- ipynb/lsp/completion.lua - Completion and edit buffer diagnostics
-- Setup completion for edit float (proxy to shadow buffer)
-- Setup diagnostics filtering for edit float

local M = {}

---Make an LSP request to the shadow buffer and return results
---Positions are 1:1 so no translation needed
---@param state NotebookState
---@param method string LSP method name
---@param params table LSP request params
---@param callback function Callback for results
function M.request(state, method, params, callback)
  if not state.shadow_buf or not vim.api.nvim_buf_is_valid(state.shadow_buf) then
    callback('Shadow buffer not available', nil)
    return
  end

  -- Update textDocument URI to point to shadow file
  if params.textDocument then
    params.textDocument.uri = vim.uri_from_fname(state.shadow_path)
  end

  vim.lsp.buf_request(state.shadow_buf, method, params, function(err, result, ctx, config)
    callback(err, result, ctx, config)
  end)
end

---Setup completion for edit float (proxy to shadow buffer)
---@param state NotebookState
function M.setup_completion(state)
  if not state.edit_state then
    return
  end

  local edit = state.edit_state
  local cell = state.cells[edit.cell_idx]

  -- Only setup completion for code cells
  if cell.type ~= 'code' then
    return
  end

  -- Manual completion trigger
  vim.keymap.set('i', '<C-Space>', function()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local edit_line, edit_col = cursor[1] - 1, cursor[2]

    -- Translate to facade/shadow coordinates (1:1)
    local shadow_line = edit.start_line + edit_line

    local params = {
      textDocument = { uri = vim.uri_from_fname(state.shadow_path) },
      position = { line = shadow_line, character = edit_col },
    }

    M.request(state, 'textDocument/completion', params, function(err, result)
      if err or not result then
        return
      end

      -- Convert completion items
      local items = result.items or result
      local completions = {}
      for _, item in ipairs(items) do
        table.insert(completions, {
          word = item.insertText or item.label,
          abbr = item.label,
          kind = vim.lsp.protocol.CompletionItemKind[item.kind] or '',
          menu = item.detail or '',
        })
      end

      if #completions > 0 then
        vim.fn.complete(edit_col + 1, completions)
      end
    end)
  end, { buffer = edit.buf, desc = 'Trigger completion (via shadow)' })
end

---Setup diagnostics for edit float (filter to current cell)
---@param state NotebookState
function M.setup_edit_diagnostics(state)
  if not state.edit_state then
    return
  end

  local edit = state.edit_state
  local cell = state.cells[edit.cell_idx]
  local edit_diag_ns = vim.api.nvim_create_namespace('notebook_edit_diagnostics')

  -- Only setup for code cells
  if cell.type ~= 'code' then
    return
  end

  -- Watch for diagnostic changes on shadow buffer
  vim.api.nvim_create_autocmd('DiagnosticChanged', {
    buffer = state.shadow_buf,
    callback = function()
      if not state.edit_state or state.edit_state.buf ~= edit.buf then
        return true -- detach
      end
      if not vim.api.nvim_buf_is_valid(edit.buf) then
        return true -- detach
      end

      -- Get diagnostics from shadow buffer
      local shadow_diags = vim.diagnostic.get(state.shadow_buf)
      local edit_diags = {}

      for _, diag in ipairs(shadow_diags) do
        -- Check if diagnostic is within current cell's content range
        if diag.lnum >= edit.start_line and diag.lnum <= edit.end_line then
          -- Translate to edit buffer coordinates
          local translated = vim.deepcopy(diag)
          translated.lnum = diag.lnum - edit.start_line
          if diag.end_lnum then
            translated.end_lnum = diag.end_lnum - edit.start_line
          end
          table.insert(edit_diags, translated)
        end
      end

      -- Display on edit buffer
      vim.diagnostic.set(edit_diag_ns, edit.buf, edit_diags)
    end,
  })

  -- Trigger initial diagnostic refresh
  vim.schedule(function()
    vim.api.nvim_exec_autocmds('DiagnosticChanged', { buffer = state.shadow_buf })
  end)
end

---Detach LSP proxy (called when edit float closes)
---@param state NotebookState
function M.detach(state)
  -- Nothing to explicitly detach - autocmds will self-detach
  -- when they detect invalid buffers
end

return M
