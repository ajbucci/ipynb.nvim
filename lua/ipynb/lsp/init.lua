-- ipynb/lsp/init.lua - LSP integration entry point
-- Orchestrates submodules, provides public API
--
-- API-level interception: wraps vim.lsp.buf_request, buf_request_all, get_clients
-- so ALL LSP operations work transparently regardless of user keymaps

local M = {}

-- Re-export submodules
local shadow = require('ipynb.lsp.shadow')
local uri = require('ipynb.lsp.uri')
local diagnostics = require('ipynb.lsp.diagnostics')
local completion = require('ipynb.lsp.completion')
local format = require('ipynb.lsp.format')
local rename = require('ipynb.lsp.rename')

-- Track if global proxy is installed
M._installed = false

-- Re-export URI functions
M.URI_SCHEME = uri.URI_SCHEME
M._uri_path_map = uri._uri_path_map
M.make_facade_uri = uri.make_facade_uri
M.parse_facade_uri = uri.parse_facade_uri
M.is_facade_uri = uri.is_facade_uri
M.cleanup_preview_buffers = uri.cleanup_preview_buffers

-- Re-export shadow functions
M.generate_shadow_lines = shadow.generate_shadow_lines
M.create_shadow = shadow.create_shadow
M.attach_lsp = shadow.attach_lsp
M.refresh_shadow = shadow.refresh_shadow
M.sync_shadow_region = shadow.sync_shadow_region

-- Re-export diagnostics functions
M.setup_diagnostics_proxy = diagnostics.setup_diagnostics_proxy
M.refresh_facade_diagnostics = diagnostics.refresh_facade_diagnostics

-- Re-export completion functions
M.request = completion.request
M.setup_completion = completion.setup_completion
M.setup_edit_diagnostics = completion.setup_edit_diagnostics
M.detach = completion.detach

-- Re-export format functions
M.format_cell = format.format_cell
M.format_all_cells = format.format_all_cells
M.format_current_cell = format.format_current_cell

---Install global LSP interception
---Wraps vim.lsp.buf_request, buf_request_all, get_clients, etc.
---to transparently redirect facade buffer requests to shadow buffer
function M.install_global_proxy()
  if M._installed then
    return
  end
  M._installed = true

  -- Install in order (some modules depend on others being ready)
  -- 1. URI scheme (BufReadCmd for nb://)
  uri.install()

  -- 2. Navigation (window/cursor redirection)
  require('ipynb.lsp.navigation').install()

  -- 3. Core request proxying
  require('ipynb.lsp.request').install()

  -- 4. Format wrapper + interceptors
  format.install()

  -- 5. Rename interceptor
  rename.install()
end

return M
