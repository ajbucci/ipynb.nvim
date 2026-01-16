-- ipynb/io.lua - File I/O (ipynb ↔ jupytext conversion)

local M = {}

local state_mod = require('ipynb.state')

---Create default metadata for a new notebook
---@param kernel_name string|nil Kernel name (default: "python3")
---@return table metadata
function M.default_metadata(kernel_name)
  kernel_name = kernel_name or 'python3'
  return {
    kernelspec = {
      display_name = 'Python 3',
      language = 'python',
      name = kernel_name,
    },
    language_info = {
      name = 'python',
    },
    nbformat = 4,
    nbformat_minor = 5,
  }
end

---Create a default empty notebook structure
---@param kernel_name string|nil Kernel name (default: "python3")
---@return Cell[], table metadata
function M.create_empty_notebook(kernel_name)
  local cells = {
    {
      id = state_mod.generate_cell_id(),
      type = 'code',
      source = '',
      metadata = {},
      outputs = {},
    },
  }
  return cells, M.default_metadata(kernel_name)
end

---Parse a .ipynb JSON file into cells
---@param path string Path to .ipynb file
---@return Cell[], table metadata
function M.read_ipynb(path)
  local content = vim.fn.readfile(path)
  local json_str = table.concat(content, '\n')

  local ok, notebook = pcall(vim.json.decode, json_str)
  if not ok then
    error('Failed to parse notebook JSON: ' .. tostring(notebook))
  end

  local cells = {}
  for _, nb_cell in ipairs(notebook.cells or {}) do
    -- Source can be string or array of strings
    -- Trailing \n on last element means trailing blank line - preserve it
    local source = nb_cell.source
    if type(source) == 'table' then
      source = table.concat(source, '')
    end

    local cell = {
      id = state_mod.generate_cell_id(),
      type = nb_cell.cell_type or 'code',
      source = source,
      metadata = nb_cell.metadata or {},
      outputs = nb_cell.outputs,
      execution_count = nb_cell.execution_count,
    }
    table.insert(cells, cell)
  end

  -- Extract notebook metadata (with defaults for missing fields)
  local default = M.default_metadata()
  local nb_meta = notebook.metadata or {}
  local metadata = {
    kernelspec = nb_meta.kernelspec or default.kernelspec,
    language_info = nb_meta.language_info or default.language_info,
    nbformat = notebook.nbformat or default.nbformat,
    nbformat_minor = notebook.nbformat_minor or default.nbformat_minor,
  }

  return cells, metadata
end

---Write cells back to .ipynb format
---@param path string Path to write to
---@param cells Cell[]
---@param metadata table|nil Notebook metadata
function M.write_ipynb(path, cells, metadata)
  local nb_cells = {}
  for _, cell in ipairs(cells) do
    -- Split source into array of lines (ipynb format)
    local source_lines = {}
    for line in (cell.source .. '\n'):gmatch('([^\n]*)\n') do
      table.insert(source_lines, line .. '\n')
    end
    -- Remove trailing newline from last line
    if #source_lines > 0 then
      source_lines[#source_lines] = source_lines[#source_lines]:gsub('\n$', '')
    end

    local nb_cell = {
      cell_type = cell.type,
      source = source_lines,
      metadata = cell.metadata or {},
    }

    if cell.type == 'code' then
      nb_cell.outputs = cell.outputs or {}
      nb_cell.execution_count = cell.execution_count
    end

    table.insert(nb_cells, nb_cell)
  end

  local default = M.default_metadata()
  local notebook = {
    cells = nb_cells,
    metadata = {
      kernelspec = metadata and metadata.kernelspec or default.kernelspec,
      language_info = metadata and metadata.language_info or default.language_info,
    },
    nbformat = metadata and metadata.nbformat or default.nbformat,
    nbformat_minor = metadata and metadata.nbformat_minor or default.nbformat_minor,
  }

  local json_str = vim.json.encode(notebook)
  -- Pretty format JSON for readability
  json_str = M.pretty_json(json_str)

  vim.fn.writefile(vim.split(json_str, '\n'), path)
end

---Convert cells to facade format with explicit start/end delimiters
---Uses custom format: # <<ipynb_nvim:code>>, # <<ipynb_nvim:markdown>>, # <<ipynb_nvim:raw>>
---End marker: # <</ipynb_nvim>>
---@param cells Cell[]
---@return string[]
function M.cells_to_jupytext(cells)
  local lines = {}

  for i, cell in ipairs(cells) do
    -- Add blank line between cells (except before first)
    if i > 1 then
      table.insert(lines, '')
    end

    -- Cell start marker
    table.insert(lines, '# <<ipynb_nvim:' .. cell.type .. '>>')

    -- Cell content (no prefix needed - we have explicit end markers)
    local source_lines = vim.split(cell.source, '\n', { plain = true })
    for _, line in ipairs(source_lines) do
      table.insert(lines, line)
    end

    -- Cell end marker
    table.insert(lines, '# <</ipynb_nvim>>')
  end

  -- Add trailing blank line so last cell output can be scrolled into view
  table.insert(lines, '')

  return lines
end

---Parse facade format back into cells
---Custom format: # <<ipynb_nvim:code>>, # <<ipynb_nvim:markdown>>, # <<ipynb_nvim:raw>>
---End marker: # <</ipynb_nvim>>
---@param lines string[]
---@return Cell[]
function M.jupytext_to_cells(lines)
  local cells = {}
  local current_cell = nil
  local content_lines = {}

  local function save_current_cell()
    if current_cell then
      -- Join content lines - trailing newline represents a blank last line
      current_cell.source = table.concat(content_lines, '\n')
      table.insert(cells, current_cell)
    end
  end

  for _, line in ipairs(lines) do
    -- Check for cell start marker: # <<ipynb_nvim:type>>
    local cell_type = line:match('^# <<ipynb_nvim:(%w+)>>$')

    -- Check for cell end marker: # <</ipynb_nvim>>
    local is_end = line:match('^# <</ipynb_nvim>>$')

    if cell_type then
      -- Save previous cell if any
      save_current_cell()

      -- Start new cell
      current_cell = {
        type = cell_type,
        source = '',
        metadata = {},
        outputs = cell_type == 'code' and {} or nil,
      }
      content_lines = {}
    elseif is_end then
      -- End current cell
      save_current_cell()
      current_cell = nil
      content_lines = {}
    elseif current_cell then
      table.insert(content_lines, line)
    end
  end

  -- Save last cell if not properly closed
  save_current_cell()

  return cells
end

---Open a notebook file (or create new if doesn't exist)
---@param buf number Buffer to populate
---@param path string Path to .ipynb file
function M.open_notebook(buf, path)
  local cells, metadata

  -- Check if file exists
  if vim.fn.filereadable(path) == 1 then
    -- Read existing notebook
    cells, metadata = M.read_ipynb(path)
  else
    -- Create new empty notebook
    cells, metadata = M.create_empty_notebook()
    vim.notify('New notebook: ' .. vim.fn.fnamemodify(path, ':t'), vim.log.levels.INFO)
  end

  -- Create state
  local state = state_mod.create(path)
  state.cells = cells
  state.metadata = metadata

  -- Create facade buffer
  local facade = require('ipynb.facade')
  facade.create(state, buf)

  -- Register state
  state_mod.register(state)

  -- Setup cells and visuals
  local cells_mod = require('ipynb.cells')
  cells_mod.place_markers(state)

  local visuals = require('ipynb.visuals')
  visuals.render_all(state)

  -- Setup active cell tracking (throttled, once per buffer)
  visuals.setup_active_tracking(state)

  -- Render existing outputs (including images)
  local output = require('ipynb.output')
  output.render_all(state)

  -- Setup keymaps
  local keymaps = require('ipynb.keymaps')
  keymaps.setup_facade_keymaps(state)

  -- Setup buffer-local commands
  local commands = require('ipynb.commands')
  commands.setup_buffer(state)
end

---Save a notebook file
---@param buf number Buffer number
---@param path string|nil Path to save to (defaults to source_path)
function M.save_notebook(buf, path)
  local state = state_mod.get(buf)
  if not state then
    vim.notify('No notebook state found for buffer', vim.log.levels.ERROR)
    return
  end

  path = path or state.source_path

  -- Sync cells from facade buffer
  local cells_mod = require('ipynb.cells')
  cells_mod.sync_cells_from_facade(state)
  cells_mod.place_markers(state)  -- Refresh extmarks after sync

  -- Write to file
  M.write_ipynb(path, state.cells, state.metadata)

  -- Mark buffer as saved
  vim.bo[buf].modified = false

  vim.notify('Saved notebook: ' .. path, vim.log.levels.INFO)
end

---Simple JSON pretty printer
---@param json_str string
---@return string
function M.pretty_json(json_str)
  local indent = 0
  local result = {}
  local in_string = false
  local escape_next = false

  for i = 1, #json_str do
    local char = json_str:sub(i, i)

    if escape_next then
      table.insert(result, char)
      escape_next = false
    elseif char == '\\' and in_string then
      table.insert(result, char)
      escape_next = true
    elseif char == '"' then
      table.insert(result, char)
      in_string = not in_string
    elseif not in_string then
      if char == '{' or char == '[' then
        indent = indent + 1
        table.insert(result, char)
        table.insert(result, '\n')
        table.insert(result, string.rep(' ', indent * 2))
      elseif char == '}' or char == ']' then
        indent = indent - 1
        table.insert(result, '\n')
        table.insert(result, string.rep(' ', indent * 2))
        table.insert(result, char)
      elseif char == ',' then
        table.insert(result, char)
        table.insert(result, '\n')
        table.insert(result, string.rep(' ', indent * 2))
      elseif char == ':' then
        table.insert(result, char)
        table.insert(result, ' ')
      elseif char ~= ' ' and char ~= '\n' and char ~= '\t' then
        table.insert(result, char)
      end
    else
      table.insert(result, char)
    end
  end

  return table.concat(result)
end

return M
