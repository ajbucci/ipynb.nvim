-- ipynb/lsp/shadow.lua - Shadow buffer creation and management
-- Shadow buffer contains code cells only (markdown cells → blank lines)
-- LSP attaches to shadow buffer, positions are 1:1 with facade

local M = {}

---Get configured shadow-write debounce delay in ms
---@return number
local function get_shadow_debounce_ms()
  local cfg = require('ipynb.config').get()
  local shadow_cfg = (cfg and cfg.shadow) or {}
  local delay = tonumber(shadow_cfg.debounce_ms) or 400
  if delay < 0 then
    delay = 0
  end
  return math.floor(delay)
end

---Write current shadow buffer content to disk
---@param state NotebookState
---@return boolean
local function write_shadow_to_disk(state)
  if not state.shadow_path then
    state._shadow_write_pending = false
    return false
  end
  if not state.shadow_buf or not vim.api.nvim_buf_is_valid(state.shadow_buf) then
    state._shadow_write_pending = false
    return false
  end

  local lines = vim.api.nvim_buf_get_lines(state.shadow_buf, 0, -1, false)
  local ok = pcall(vim.fn.writefile, lines, state.shadow_path)
  state._shadow_write_pending = false
  if ok then
    vim.bo[state.shadow_buf].modified = false
  end
  return ok
end

---Stop a pending shadow-write timer without closing it
---@param state NotebookState
local function stop_shadow_write_timer(state)
  if not state then
    return
  end
  if state._shadow_write_timer then
    pcall(state._shadow_write_timer.stop, state._shadow_write_timer)
  end
end

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

  -- Create shadow file path for LSP to read (with appropriate extension)
  local shadow_path
  local shadow_cfg = require('ipynb.config').get().shadow
  if shadow_cfg and shadow_cfg.location == 'workspace' and state.facade_path then
    local root = vim.fn.fnamemodify(state.facade_path, ':p:h')
    local dir = vim.fs.joinpath(root, shadow_cfg.dir or '.ipynb.nvim')
    vim.fn.mkdir(dir, 'p')
    local filename = vim.fn.fnamemodify(state.facade_path, ':t')
    local stem = filename:gsub('%.ipynb$', '')
    shadow_path = vim.fs.joinpath(dir, stem .. '_shadow' .. ext)
  else
    shadow_path = vim.fn.tempname() .. '_shadow' .. ext
  end
  -- If a buffer with this name already exists (e.g., reopening notebook),
  -- wipe it to avoid E95 "Buffer with this name already exists".
  local existing = vim.fn.bufnr(shadow_path)
  if existing ~= -1 and vim.api.nvim_buf_is_valid(existing) then
    pcall(vim.api.nvim_buf_delete, existing, { force = true })
  end
  vim.api.nvim_buf_set_name(shadow_buf, shadow_path)

  -- Generate and set shadow content
  local shadow_lines = M.generate_shadow_lines(state)
  vim.api.nvim_buf_set_lines(shadow_buf, 0, -1, false, shadow_lines)

  -- Write to disk for LSP
  vim.fn.writefile(shadow_lines, shadow_path)
  state._shadow_write_pending = false

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

  -- When LSP attaches to shadow, emit LspAttach for facade/edit buffers
  -- so keymaps gated by LspAttach (e.g., LazyVim/which-key) are registered.
  local group = vim.api.nvim_create_augroup('ipynb_lsp_attach_' .. shadow_buf, { clear = true })
  vim.api.nvim_create_autocmd('LspAttach', {
    buffer = shadow_buf,
    group = group,
    callback = function(args)
      local client_id = args.data and args.data.client_id
      if not client_id then
        return
      end

      -- Avoid duplicate LspAttach emissions per buffer/client
      state._lsp_attach_emitted = state._lsp_attach_emitted or {}
      local function emit_for_buf(bufnr)
        if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
          return
        end
        state._lsp_attach_emitted[bufnr] = state._lsp_attach_emitted[bufnr] or {}
        if state._lsp_attach_emitted[bufnr][client_id] then
          return
        end
        -- Mark as attached so Snacks.util.lsp.on can see it
        local client = vim.lsp.get_client_by_id(client_id)
        if client and client.attached_buffers then
          client.attached_buffers[bufnr] = true
        end
        state._lsp_attach_emitted[bufnr][client_id] = true
        vim.api.nvim_exec_autocmds('LspAttach', {
          buffer = bufnr,
          data = { client_id = client_id },
        })
      end

      -- Emit LspAttach for facade buffer
      emit_for_buf(state.facade_buf)

      -- Edit buffers already fire LspAttach in edit.lua (see M.fire_lsp_attach).
    end,
  })

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

  -- Cancel pending debounced write before full refresh write.
  stop_shadow_write_timer(state)

  -- Update temp file for LSP
  vim.fn.writefile(shadow_lines, state.shadow_path)
  state._shadow_write_pending = false

  -- Clear modified to prevent save warnings
  vim.bo[state.shadow_buf].modified = false
end

---Schedule writing the shadow buffer to disk after a debounce delay.
---@param state NotebookState
---@param delay_ms number|nil
function M.schedule_shadow_write(state, delay_ms)
  if not state.shadow_path then
    return
  end
  if not state.shadow_buf or not vim.api.nvim_buf_is_valid(state.shadow_buf) then
    return
  end

  state._shadow_write_pending = true
  delay_ms = delay_ms or get_shadow_debounce_ms()
  if delay_ms <= 0 then
    write_shadow_to_disk(state)
    return
  end

  local timer = state._shadow_write_timer
  if not timer then
    timer = vim.uv.new_timer()
    if not timer then
      write_shadow_to_disk(state)
      return
    end
    state._shadow_write_timer = timer
  end

  stop_shadow_write_timer(state)
  local ok = pcall(timer.start, timer, delay_ms, 0, vim.schedule_wrap(function()
    if state._shadow_write_timer ~= timer then
      return
    end
    write_shadow_to_disk(state)
  end))
  if not ok then
    write_shadow_to_disk(state)
  end
end

---Force a pending shadow write to disk immediately.
---@param state NotebookState
function M.flush_shadow_write(state)
  if not state then
    return
  end
  stop_shadow_write_timer(state)
  if state._shadow_write_pending then
    write_shadow_to_disk(state)
  end
end

---Cleanup shadow-write timer for a notebook state.
---@param state NotebookState
function M.cleanup_shadow_write(state)
  if not state then
    return
  end
  stop_shadow_write_timer(state)
  if state._shadow_write_timer then
    pcall(state._shadow_write_timer.close, state._shadow_write_timer)
    state._shadow_write_timer = nil
  end
  state._shadow_write_pending = false
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

  -- Debounce disk writes; LSP still sees immediate in-memory buffer changes.
  M.schedule_shadow_write(state)

  -- Clear modified to prevent save warnings
  vim.bo[state.shadow_buf].modified = false
end

return M
