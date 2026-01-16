-- ipynb/lsp/diagnostics.lua - Diagnostics forwarding
-- Forwards diagnostics from shadow buffer to facade buffer
-- Filters out diagnostics from markdown/raw cells

local M = {}

-- Namespace for diagnostics displayed on facade buffer
M.diag_ns = vim.api.nvim_create_namespace('notebook_diagnostics')

-- Configure diagnostic display for our namespace (ensure it's visible)
vim.diagnostic.config({
  virtual_text = true,
  signs = true,
  underline = true,
  update_in_insert = false,
}, M.diag_ns)

-- Guard to prevent re-entry during diagnostic proxy
local diag_proxy_running = false

---Setup diagnostics forwarding from shadow to facade
---@param state NotebookState
function M.setup_diagnostics_proxy(state)
  vim.api.nvim_create_autocmd('DiagnosticChanged', {
    buffer = state.shadow_buf,
    callback = function()
      if not state.shadow_buf or not vim.api.nvim_buf_is_valid(state.shadow_buf) then
        return true -- detach
      end
      if not state.facade_buf or not vim.api.nvim_buf_is_valid(state.facade_buf) then
        return true -- detach
      end

      -- Schedule to avoid timing issues with extmark placement
      vim.schedule(function()
        -- Guard against re-entry
        if diag_proxy_running then
          return
        end
        diag_proxy_running = true

        if not vim.api.nvim_buf_is_valid(state.shadow_buf) or not vim.api.nvim_buf_is_valid(state.facade_buf) then
          diag_proxy_running = false
          return
        end

        -- Get diagnostics from shadow buffer
        local shadow_diags = vim.diagnostic.get(state.shadow_buf)

        -- Filter: only show diagnostics from code cells
        local cells_mod = require('ipynb.cells')
        local filtered = {}

        for _, diag in ipairs(shadow_diags) do
          local cell_idx = cells_mod.get_cell_at_line(state, diag.lnum)
          if cell_idx then
            local cell = state.cells[cell_idx]
            if cell and cell.type == 'code' then
              local translated = vim.deepcopy(diag)
              translated.bufnr = nil
              table.insert(filtered, translated)
            end
          end
        end

        -- Display on facade buffer
        vim.diagnostic.set(M.diag_ns, state.facade_buf, filtered)
        vim.diagnostic.show(M.diag_ns, state.facade_buf)

        diag_proxy_running = false
      end)
    end,
  })
end

---Refresh facade diagnostics (call after facade buffer modifications)
---@param state NotebookState
function M.refresh_facade_diagnostics(state)
  if not state.shadow_buf or not vim.api.nvim_buf_is_valid(state.shadow_buf) then
    return
  end
  if not state.facade_buf or not vim.api.nvim_buf_is_valid(state.facade_buf) then
    return
  end

  -- Get diagnostics from shadow buffer
  local shadow_diags = vim.diagnostic.get(state.shadow_buf)

  -- Filter: only show diagnostics from code cells
  local cells_mod = require('ipynb.cells')
  local filtered = {}

  for _, diag in ipairs(shadow_diags) do
    local cell_idx = cells_mod.get_cell_at_line(state, diag.lnum)
    if cell_idx then
      local cell = state.cells[cell_idx]
      if cell and cell.type == 'code' then
        local translated = vim.deepcopy(diag)
        translated.bufnr = nil
        table.insert(filtered, translated)
      end
    end
  end

  -- Display on facade buffer
  vim.diagnostic.set(M.diag_ns, state.facade_buf, filtered)
  vim.diagnostic.show(M.diag_ns, state.facade_buf)
end

return M
