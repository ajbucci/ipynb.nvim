-- ipynb/lsp/uri.lua - Custom URI scheme handling
-- Provides nb:// URI scheme for picker previews and result rewriting

local M = {}

-- Custom URI scheme for notebook facade buffers
-- Used so pickers (fzf-lua, telescope) show facade content instead of raw JSON
-- Short scheme name so line numbers are visible in picker
M.URI_SCHEME = 'nb'

-- Map from filename to full path for URI resolution
M._uri_path_map = {}

-- Methods that navigate directly to a location (should use file:// to find facade buffer)
local NAVIGATION_METHODS = {
  ['textDocument/definition'] = true,
  ['textDocument/declaration'] = true,
  ['textDocument/implementation'] = true,
  ['textDocument/typeDefinition'] = true,
}

---Create a custom URI for a notebook facade
---@param path string Absolute path to the .ipynb file
---@return string URI like "nb://notebook.ipynb"
function M.make_facade_uri(path)
  -- Normalize to absolute path
  local abs_path = vim.fn.fnamemodify(path, ':p')
  local filename = vim.fn.fnamemodify(abs_path, ':t')

  -- Store mapping for later resolution
  M._uri_path_map[filename] = abs_path

  return M.URI_SCHEME .. '://' .. filename
end

---Parse a facade URI back to a path
---@param uri string URI like "nb://notebook.ipynb"
---@return string|nil path Path if valid facade URI, nil otherwise
function M.parse_facade_uri(uri)
  local prefix = M.URI_SCHEME .. '://'
  if uri:sub(1, #prefix) == prefix then
    local filename = uri:sub(#prefix + 1)
    -- Look up full path from our map
    if M._uri_path_map[filename] then
      return M._uri_path_map[filename]
    end
    -- Fallback: search through open notebooks by filename
    local state_mod = require('ipynb.state')
    for _, state in pairs(state_mod.notebooks or {}) do
      if state.facade_path then
        local state_filename = vim.fn.fnamemodify(state.facade_path, ':t')
        if state_filename == filename then
          -- Found it, cache for future lookups
          local abs_path = vim.fn.fnamemodify(state.facade_path, ':p')
          M._uri_path_map[filename] = abs_path
          return abs_path
        end
      end
    end
    return filename
  end
  return nil
end

---Check if a URI is a facade URI
---@param uri string
---@return boolean
function M.is_facade_uri(uri)
  return uri:sub(1, #M.URI_SCHEME + 3) == M.URI_SCHEME .. '://'
end

---Cleanup orphaned nb:// preview buffers for a notebook
---Called when returning to facade buffer (after picker closes, cancel or select)
---@param state NotebookState
function M.cleanup_preview_buffers(state)
  if not state.facade_path then
    return
  end
  local facade_abs = vim.fn.fnamemodify(state.facade_path, ':p')
  vim.schedule(function()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) then
        local name = vim.api.nvim_buf_get_name(buf)
        if M.is_facade_uri(name) then
          local parsed_path = M.parse_facade_uri(name)
          if parsed_path == facade_abs then
            pcall(vim.api.nvim_buf_delete, buf, { force = true })
          end
        end
      end
    end
  end)
end

---Recursively rewrite URIs in LSP results from shadow to facade
---@param result any LSP result (can be table, array, or primitive)
---@param state NotebookState
---@param method string|nil LSP method name (to determine URI scheme)
---@return any
function M.rewrite_result_uris(result, state, method)
  if not result or type(result) ~= 'table' then
    return result
  end

  local shadow_uri = vim.uri_from_fname(state.shadow_path)
  local facade_abs = vim.fn.fnamemodify(state.facade_path, ':p')

  -- Navigation methods (gd, gD, gi, gt) use file:// so bufadd finds existing facade buffer
  -- Other methods (gr references, etc.) use nb:// so pickers show facade content
  local facade_uri
  if method and NAVIGATION_METHODS[method] then
    facade_uri = vim.uri_from_fname(facade_abs)
  else
    facade_uri = M.make_facade_uri(facade_abs)
  end

  -- Deep copy to avoid mutating original
  result = vim.deepcopy(result)

  local function rewrite(obj)
    if type(obj) ~= 'table' then
      return
    end

    -- Rewrite common URI fields
    if obj.uri == shadow_uri then
      obj.uri = facade_uri
    end
    if obj.targetUri == shadow_uri then
      obj.targetUri = facade_uri
    end

    -- Recurse into nested tables/arrays
    for _, v in pairs(obj) do
      rewrite(v)
    end
  end

  rewrite(result)
  return result
end

---Install the BufReadCmd autocmd for nb:// URIs
---This enables pickers to preview facade content
function M.install()
  local state_mod = require('ipynb.state')

  vim.api.nvim_create_autocmd('BufReadCmd', {
    pattern = M.URI_SCHEME .. '://*',
    callback = function(args)
      local path = M.parse_facade_uri(args.match)
      if not path then
        return
      end

      -- Find the notebook state for this path
      local state = state_mod.get_by_path(path)

      -- Set up the nb:// buffer for preview
      vim.bo[args.buf].buftype = 'nofile'
      vim.bo[args.buf].buflisted = false
      vim.bo[args.buf].modifiable = true

      -- Copy lines from facade buffer (needed for picker line display)
      if state and state.facade_buf and vim.api.nvim_buf_is_valid(state.facade_buf) then
        local lines = vim.api.nvim_buf_get_lines(state.facade_buf, 0, -1, false)
        if #lines > 0 then
          vim.api.nvim_buf_set_lines(args.buf, 0, -1, false, lines)
        end

        -- Set filetype for treesitter highlighting
        vim.b[args.buf].ipynb_language = state.shadow_lang or 'python' ---@diagnostic disable-line: undefined-field
        vim.bo[args.buf].filetype = 'ipynb'

        -- Apply cell boundary extmarks (reuse same rendering as facade)
        local visuals = require('ipynb.visuals')
        for cell_idx = 1, #state.cells do
          visuals.render_cell(state, cell_idx, false, args.buf)
        end
      end

      vim.bo[args.buf].modifiable = false
      vim.bo[args.buf].bufhidden = 'wipe' -- Wipe when hidden (after redirect)
    end,
  })
end

return M
