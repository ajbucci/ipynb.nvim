-- ipynb/lsp/util.lua - Shared LSP utilities
-- Helper functions used across LSP modules

local M = {}

---Resolve buffer number (handle 0 or nil = current buffer)
---@param bufnr number|nil
---@return number
function M.resolve_bufnr(bufnr)
  if bufnr == 0 or bufnr == nil then
    return vim.api.nvim_get_current_buf()
  end
  return bufnr
end

---@class BufferContext
---@field state NotebookState|nil
---@field is_edit_buf boolean
---@field is_shadow_buf boolean
---@field line_offset number Offset to translate edit buffer lines to shadow lines

---Lookup notebook state from any buffer type (facade, edit, or shadow)
---@param bufnr number Buffer number (already resolved)
---@param state_mod table The state module
---@return BufferContext
function M.get_buffer_context(bufnr, state_mod)
  local ctx = {
    state = nil,
    is_edit_buf = false,
    is_shadow_buf = false,
    line_offset = 0,
  }

  -- Ignore our custom URI scheme buffers - they're for picker preview only
  -- and should not be handled by our LSP proxy
  local buf_name = vim.api.nvim_buf_get_name(bufnr)
  if buf_name:match('^nb://') then
    return ctx
  end

  -- Check if it's a facade buffer
  ctx.state = state_mod.get_by_facade(bufnr)
  if ctx.state then
    return ctx
  end

  -- Check if it's an edit buffer
  ctx.state = state_mod.get_from_edit_buf(bufnr)
  if ctx.state and ctx.state.edit_state then
    ctx.is_edit_buf = true
    ctx.line_offset = ctx.state.edit_state.start_line
    return ctx
  end

  -- Check if it's a shadow buffer
  ctx.state = state_mod.get_by_shadow(bufnr)
  if ctx.state then
    ctx.is_shadow_buf = true
  end

  return ctx
end

---Apply line offset translation to params (position and range)
---@param params table LSP params (modified in place, should be a copy)
---@param line_offset number Offset to add to line numbers
function M.apply_line_offset(params, line_offset)
  if line_offset <= 0 then
    return
  end
  if params.position then
    params.position.line = params.position.line + line_offset
  end
  if params.range then
    params.range.start.line = params.range.start.line + line_offset
    params.range['end'].line = params.range['end'].line + line_offset
  end
end

---Rewrite params to point to shadow buffer (handles both table and function params)
---@param params table|function Original params
---@param state NotebookState
---@param is_edit_buf boolean
---@param line_offset number
---@return table|function Rewritten params
function M.rewrite_params(params, state, is_edit_buf, line_offset)
  if type(params) == 'table' then
    params = vim.deepcopy(params)
    if params.textDocument then
      params.textDocument.uri = vim.uri_from_fname(state.shadow_path)
    end
    if is_edit_buf then
      M.apply_line_offset(params, line_offset)
    end
    return params
  elseif type(params) == 'function' then
    local orig_params = params
    return function(client, buf)
      local p = orig_params(client, buf)
      if p then
        p = vim.deepcopy(p)
        if p.textDocument then
          p.textDocument.uri = vim.uri_from_fname(state.shadow_path)
        end
        if is_edit_buf then
          M.apply_line_offset(p, line_offset)
        end
      end
      return p
    end
  end
  return params
end

return M
