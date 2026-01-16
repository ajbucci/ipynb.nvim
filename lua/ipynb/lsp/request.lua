-- ipynb/lsp/request.lua - Core LSP request proxying
-- Wraps vim.lsp.buf_request, buf_request_all, get_clients, etc.
-- Provides hook system for other modules to intercept specific methods

local M = {}

local util = require('ipynb.lsp.util')
local uri_mod = require('ipynb.lsp.uri')

-- Interceptors registered by other modules (e.g., format)
-- Key: LSP method name, Value: array of handler functions
local interceptors = {}

---Register an interceptor for a specific LSP method
---Handler signature: handler(ctx, method, params, orig_handler, client, req_bufnr) -> handled, req_id
---@param method string LSP method name (e.g., 'textDocument/formatting')
---@param handler function Interceptor function
function M.register_interceptor(method, handler)
  interceptors[method] = interceptors[method] or {}
  table.insert(interceptors[method], handler)
end

-- Track which clients we've already wrapped (to avoid double-wrapping)
local wrapped_clients = setmetatable({}, { __mode = 'k' })

---Wrap a client's methods to redirect buffer checks/requests to shadow buffer
---@param client table LSP client
---@param shadow_buf number Shadow buffer number
local function wrap_client(client, shadow_buf)
  if wrapped_clients[client] then
    return
  end
  wrapped_clients[client] = true

  local state_mod = require('ipynb.state')

  -- Wrap supports_method to redirect buffer checks to shadow buffer
  local orig_supports_method = client.supports_method
  client.supports_method = function(self_or_method, method_or_bufnr, bufnr_arg)
    local method, bufnr

    -- Detect calling convention (method style vs deprecated function style)
    if self_or_method == client or (type(self_or_method) == 'table' and getmetatable(self_or_method)) then
      method = method_or_bufnr
      bufnr = bufnr_arg
    else
      method = self_or_method
      bufnr = method_or_bufnr
    end

    -- Handle deprecated {bufnr = N} table form
    if type(bufnr) == 'table' then
      bufnr = bufnr.bufnr
    end

    -- Redirect edit/facade buffer checks to shadow buffer
    if bufnr then
      bufnr = util.resolve_bufnr(bufnr)
      local ctx = util.get_buffer_context(bufnr, state_mod)
      if ctx.state and ctx.state.shadow_buf == shadow_buf then
        bufnr = shadow_buf
      end
    end

    return orig_supports_method(client, method, bufnr)
  end

  -- Wrap client.request to intercept LSP requests
  local orig_request = client.request
  client.request = function(self, method, params, handler, req_bufnr)
    -- Resolve the buffer number
    local bufnr = util.resolve_bufnr(req_bufnr)
    local ctx = util.get_buffer_context(bufnr, state_mod)
    local state = ctx.state

    if state and state.shadow_buf and vim.api.nvim_buf_is_valid(state.shadow_buf) then
      -- Check for registered interceptors
      local handlers = interceptors[method]
      if handlers then
        for _, interceptor in ipairs(handlers) do
          local handled, req_id = interceptor(ctx, method, params, handler, self, req_bufnr)
          if handled then
            return handled, req_id
          end
        end
      end

      -- Rewrite params to point to shadow buffer
      params = util.rewrite_params(params, state, ctx.is_edit_buf, ctx.line_offset)

      -- Wrap handler to rewrite URIs in results back to facade
      if handler then
        local orig_handler = handler
        handler = function(err, result, ...)
          result = uri_mod.rewrite_result_uris(result, state, method)
          return orig_handler(err, result, ...)
        end
      end

      -- Make request to shadow buffer
      req_bufnr = state.shadow_buf
    end

    return orig_request(self, method, params, handler, req_bufnr)
  end
end

---Install the core LSP request wrappers
function M.install()
  local state_mod = require('ipynb.state')

  -- Store original functions
  local orig_buf_request = vim.lsp.buf_request
  local orig_buf_request_all = vim.lsp.buf_request_all
  local orig_get_clients = vim.lsp.get_clients
  local orig_make_position_params = vim.lsp.util.make_position_params
  local orig_make_text_document_params = vim.lsp.util.make_text_document_params
  local orig_buf_detach_client = vim.lsp.buf_detach_client

  -- Wrap buf_detach_client to suppress warnings for facade/edit buffers
  -- (plugins like VenvSelect try to detach from buffers that were never attached)
  vim.lsp.buf_detach_client = function(bufnr, client_id)
    bufnr = util.resolve_bufnr(bufnr)

    -- Silently ignore our custom URI scheme buffers - they never have LSP attached
    local buf_name = vim.api.nvim_buf_get_name(bufnr)
    if buf_name:match('^nb://') then
      return false
    end

    local ctx = util.get_buffer_context(bufnr, state_mod)
    -- Silently ignore detach for our facade/edit buffers (they're not really attached)
    if ctx.state and not ctx.is_shadow_buf then
      return false
    end

    return orig_buf_detach_client(bufnr, client_id)
  end

  -- Wrap make_position_params to handle edit/facade buffer -> shadow buffer URI translation
  -- This is called by vim.lsp.buf.* functions to build request params
  -- NOTE: Line translation is handled by buf_request/buf_request_all, not here (to avoid double-translation)
  vim.lsp.util.make_position_params = function(win, offset_encoding)
    local params = orig_make_position_params(win, offset_encoding)

    local bufnr = vim.api.nvim_win_get_buf(win or 0)

    -- Check edit buffer first (original behavior)
    local state = state_mod.get_from_edit_buf(bufnr)
    if state and state.edit_state and state.shadow_path then
      params = vim.deepcopy(params)
      params.textDocument.uri = vim.uri_from_fname(state.shadow_path)
      return params
    end

    -- Check facade buffer (new behavior for K in facade)
    state = state_mod.get_by_facade(bufnr)
    if state and state.shadow_path then
      params = vim.deepcopy(params)
      params.textDocument.uri = vim.uri_from_fname(state.shadow_path)
      return params
    end

    return params
  end

  -- Wrap make_text_document_params for edit/facade buffer -> shadow buffer translation
  vim.lsp.util.make_text_document_params = function(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local params = orig_make_text_document_params(bufnr)

    -- Check edit buffer first
    local state = state_mod.get_from_edit_buf(bufnr)
    if state and state.shadow_path then
      params.uri = vim.uri_from_fname(state.shadow_path)
      return params
    end

    -- Check facade buffer
    state = state_mod.get_by_facade(bufnr)
    if state and state.shadow_path then
      params.uri = vim.uri_from_fname(state.shadow_path)
      return params
    end

    return params
  end

  -- Wrap buf_request (core interception - all vim.lsp.buf.* functions use this)
  -- Handles facade, edit, and shadow buffers, proxying to shadow buffer
  vim.lsp.buf_request = function(bufnr, method, params, handler, on_unsupported)
    bufnr = util.resolve_bufnr(bufnr)
    local ctx = util.get_buffer_context(bufnr, state_mod)
    local state = ctx.state

    if state and state.shadow_buf and vim.api.nvim_buf_is_valid(state.shadow_buf) then
      params = util.rewrite_params(params, state, ctx.is_edit_buf, ctx.line_offset)

      -- Wrap handler to rewrite URIs back (no line translation - positions are absolute)
      local orig_handler = handler
      if handler then
        handler = function(err, result, hctx, config)
          result = uri_mod.rewrite_result_uris(result, state, method)
          if hctx then
            hctx = vim.deepcopy(hctx)
            hctx.bufnr = state.facade_buf
          end
          return orig_handler(err, result, hctx, config)
        end
      end

      local target_buf = ctx.is_shadow_buf and bufnr or state.shadow_buf
      return orig_buf_request(target_buf, method, params, handler, on_unsupported)
    end

    return orig_buf_request(bufnr, method, params, handler, on_unsupported)
  end

  -- Wrap buf_request_all (multi-client requests)
  -- Handles facade, edit, and shadow buffers
  vim.lsp.buf_request_all = function(bufnr, method, params, handler)
    bufnr = util.resolve_bufnr(bufnr)
    local ctx = util.get_buffer_context(bufnr, state_mod)
    local state = ctx.state

    if state and state.shadow_buf and vim.api.nvim_buf_is_valid(state.shadow_buf) then
      params = util.rewrite_params(params, state, ctx.is_edit_buf, ctx.line_offset)

      -- Wrap handler to rewrite URIs back
      local orig_handler = handler
      if handler then
        handler = function(results, hctx, config)
          for _, resp in pairs(results) do
            if resp.result then
              resp.result = uri_mod.rewrite_result_uris(resp.result, state, method)
            end
          end
          if hctx then
            hctx = vim.deepcopy(hctx)
            hctx.bufnr = state.facade_buf
          end
          return orig_handler(results, hctx, config)
        end
      end

      local target_buf = ctx.is_shadow_buf and bufnr or state.shadow_buf
      return orig_buf_request_all(target_buf, method, params, handler)
    end

    return orig_buf_request_all(bufnr, method, params, handler)
  end

  -- Wrap get_clients to redirect facade/edit buffer queries to shadow buffer
  -- Returns shadow buffer's clients so vim.lsp.buf.* functions work
  vim.lsp.get_clients = function(filter)
    filter = filter or {}
    local bufnr = filter.bufnr

    if bufnr then
      bufnr = util.resolve_bufnr(bufnr)
      local ctx = util.get_buffer_context(bufnr, state_mod)
      local state = ctx.state

      if state and state.shadow_buf and vim.api.nvim_buf_is_valid(state.shadow_buf) then
        -- Redirect to shadow buffer
        filter = vim.tbl_extend('force', filter, { bufnr = state.shadow_buf })
        local clients = orig_get_clients(filter)
        for _, client in ipairs(clients) do
          wrap_client(client, state.shadow_buf)
        end
        return clients
      end
    end

    return orig_get_clients(filter)
  end
end

return M
