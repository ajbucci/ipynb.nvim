-- ipynb/lsp/shadow.lua - Shadow buffer creation and management
-- Shadow buffer contains code cells only (markdown cells → blank lines)
-- LSP attaches to shadow buffer, positions are 1:1 with facade

local M = {}

---Get language info from notebook metadata
---@param state NotebookState
---@return string language (e.g., "python", "julia", "r")
---@return string extension (e.g., ".py", ".jl", ".r")
local function get_language_info(state)
  local lang = 'python' -- default
  if state.metadata and state.metadata.language_info and state.metadata.language_info.name then
    lang = state.metadata.language_info.name
  end

  -- Map language to file extension
  local ext_map = {
    python = '.py',
    julia = '.jl',
    r = '.r',
    ruby = '.rb',
    rust = '.rs',
    go = '.go',
    javascript = '.js',
    typescript = '.ts',
    lua = '.lua',
    scala = '.scala',
    kotlin = '.kt',
    java = '.java',
    cpp = '.cpp',
    c = '.c',
  }

  local ext = ext_map[lang] or ('.' .. lang)
  return lang, ext
end

---Generate shadow buffer content from cells
---Code cells: actual content, Markdown/raw cells: blank lines
---Maintains exact 1:1 line mapping with facade buffer
---@param state NotebookState
---@return string[]
function M.generate_shadow_lines(state)
  local shadow_lines = {}

  -- Mirror the facade structure exactly:
  -- For each cell: optional blank (if not first), start marker, content, end marker
  for i, cell in ipairs(state.cells) do
    -- Blank line before cell (except first)
    if i > 1 then
      table.insert(shadow_lines, '')
    end

    -- Start marker line: always blank in shadow
    table.insert(shadow_lines, '')

    -- Content lines
    local source_lines = vim.split(cell.source, '\n', { plain = true })
    for _, src_line in ipairs(source_lines) do
      if cell.type == 'code' then
        -- Code cell: keep the actual code
        table.insert(shadow_lines, src_line)
      else
        -- Markdown/raw cell: blank line
        table.insert(shadow_lines, '')
      end
    end

    -- End marker line: always blank in shadow
    table.insert(shadow_lines, '')
  end

  return shadow_lines
end

---Create the shadow buffer for LSP
---@param state NotebookState
---@return number shadow_buf
function M.create_shadow(state)
  -- Ensure global proxy is installed
  require('ipynb.lsp').install_global_proxy()

  -- Create unlisted buffer (NOT scratch - scratch sets buftype=nofile which blocks LSP)
  local shadow_buf = vim.api.nvim_create_buf(false, false)

  -- Get language from notebook metadata
  local lang, ext = get_language_info(state)

  -- Create temp file for LSP to read (with appropriate extension)
  local shadow_path = vim.fn.tempname() .. '_shadow' .. ext
  vim.api.nvim_buf_set_name(shadow_buf, shadow_path)

  -- Generate and set shadow content
  local shadow_lines = M.generate_shadow_lines(state)
  vim.api.nvim_buf_set_lines(shadow_buf, 0, -1, false, shadow_lines)

  -- Write to disk for LSP
  vim.fn.writefile(shadow_lines, shadow_path)

  -- Configure for LSP (don't set buftype - need it to be normal for LSP to attach)
  vim.bo[shadow_buf].filetype = lang
  vim.bo[shadow_buf].bufhidden = 'hide'
  vim.bo[shadow_buf].swapfile = false
  vim.bo[shadow_buf].buflisted = false -- Keep unlisted but allow LSP
  vim.bo[shadow_buf].modified = false  -- Prevent save warnings

  -- Store in state
  state.shadow_buf = shadow_buf
  state.shadow_path = shadow_path
  state.shadow_lang = lang -- Track language for later use

  -- Attach LSP to shadow buffer
  M.attach_lsp(state)

  -- Setup diagnostics forwarding
  require('ipynb.lsp.diagnostics').setup_diagnostics_proxy(state)

  return shadow_buf
end

---Attach LSP to shadow buffer based on its filetype
---@param state NotebookState
function M.attach_lsp(state)
  -- Wait for next event loop to ensure buffer is fully ready
  vim.schedule(function()
    if not state.shadow_buf or not vim.api.nvim_buf_is_valid(state.shadow_buf) then
      return
    end

    -- Trigger FileType autocmd to let user's LSP config (lspconfig, etc.) attach
    -- Must run in buffer context so plugins that check current buffer work correctly
    vim.api.nvim_buf_call(state.shadow_buf, function()
      vim.api.nvim_exec_autocmds('FileType', {
        buffer = state.shadow_buf,
        modeline = false,
      })
    end)
  end)
end

---Refresh the entire shadow buffer from state
---@param state NotebookState
function M.refresh_shadow(state)
  if not state.shadow_buf or not vim.api.nvim_buf_is_valid(state.shadow_buf) then
    return
  end

  local shadow_lines = M.generate_shadow_lines(state)
  vim.api.nvim_buf_set_lines(state.shadow_buf, 0, -1, false, shadow_lines)

  -- Update temp file for LSP
  vim.fn.writefile(shadow_lines, state.shadow_path)

  -- Clear modified to prevent save warnings
  vim.bo[state.shadow_buf].modified = false
end

---Sync a region of the shadow buffer after an edit
---@param state NotebookState
---@param start_line number 0-indexed start line in facade
---@param old_end_line number 0-indexed old end line (exclusive)
---@param new_lines string[] New content lines
---@param cell_type "code"|"markdown"|"raw" Type of cell being edited
function M.sync_shadow_region(state, start_line, old_end_line, new_lines, cell_type)
  if not state.shadow_buf or not vim.api.nvim_buf_is_valid(state.shadow_buf) then
    return
  end

  local shadow_lines
  if cell_type == 'code' then
    -- Code cell: copy actual content
    shadow_lines = new_lines
  else
    -- Markdown/raw cell: use blank lines to preserve line count
    shadow_lines = {}
    for _ = 1, #new_lines do
      table.insert(shadow_lines, '')
    end
  end

  vim.api.nvim_buf_set_lines(state.shadow_buf, start_line, old_end_line, false, shadow_lines)

  -- Update temp file for LSP
  local all_lines = vim.api.nvim_buf_get_lines(state.shadow_buf, 0, -1, false)
  vim.fn.writefile(all_lines, state.shadow_path)

  -- Clear modified to prevent save warnings
  vim.bo[state.shadow_buf].modified = false
end

return M
