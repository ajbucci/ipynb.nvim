-- ipynb/kernel.lua - Jupyter kernel connection via Python bridge
-- Each notebook has its own kernel state and bridge process

local M = {}

---@class KernelState
---@field job_id number|nil Job handle for Python bridge
---@field connected boolean Whether kernel is connected
---@field kernel_id string|nil Kernel ID
---@field kernel_name string Kernel name (e.g., "python3")
---@field execution_state string Current state: "idle", "busy", "starting"
---@field pending_cells table<string, {cell_idx: number}> Cells waiting for execution
---@field callbacks table Async operation callbacks

---Create a new kernel state for a notebook
---@return KernelState
local function create_kernel_state()
  return {
    job_id = nil,
    connected = false,
    kernel_id = nil,
    kernel_name = "python3",
    execution_state = "idle",
    pending_cells = {},
    callbacks = {
      complete = nil,
      inspect = {},
      ping = nil,
      is_alive = nil,
    },
  }
end

-- Get the path to the Python bridge script
local function get_bridge_path()
  local source = debug.getinfo(1, "S").source:sub(2)
  local plugin_dir = vim.fn.fnamemodify(source, ":h:h:h")
  return plugin_dir .. "/python/kernel_bridge.py"
end

---Send a command to the Python bridge for a notebook
---@param state NotebookState
---@param cmd table Command to send
---@return boolean success
local function send_command(state, cmd)
  if not state.kernel or not state.kernel.job_id then
    vim.notify("Kernel bridge not running", vim.log.levels.ERROR)
    return false
  end

  local json = vim.json.encode(cmd)
  vim.fn.chansend(state.kernel.job_id, json .. "\n")
  return true
end

---Update a cell field and re-render visuals
---@param state NotebookState
---@param cell_idx number
---@param field string
---@param value any
local function update_cell_field(state, cell_idx, field, value)
  vim.schedule(function()
    if state and state.cells and state.cells[cell_idx] then
      state.cells[cell_idx][field] = value
      require("ipynb.visuals").render_all(state)
    end
  end)
end

---Set the notebook language (updates metadata, treesitter, and LSP)
---@param state NotebookState
---@param lang string Language name (e.g., "python", "julia", "r")
local function set_language(state, lang)
  -- Update language_info metadata
  if not state.metadata then
    state.metadata = {}
  end
  if not state.metadata.language_info then
    state.metadata.language_info = { name = lang }
  else
    state.metadata.language_info.name = lang
  end

  -- Also update kernelspec.language if present
  if state.metadata.kernelspec then
    state.metadata.kernelspec.language = lang
  end

  -- Update treesitter injection
  local buf = state.facade_buf
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.b[buf].ipynb_language = lang
    vim.treesitter.stop(buf)
    vim.treesitter.start(buf, 'ipynb')
  end

  -- Update shadow buffer filetype if language changed (triggers LSP reattach)
  if state.shadow_buf and vim.api.nvim_buf_is_valid(state.shadow_buf) then
    local old_lang = state.shadow_lang
    if old_lang ~= lang then
      -- Changing filetype detaches old LSP servers
      vim.bo[state.shadow_buf].filetype = lang
      state.shadow_lang = lang

      -- Trigger FileType to let new LSP attach
      vim.api.nvim_buf_call(state.shadow_buf, function()
        vim.api.nvim_exec_autocmds('FileType', {
          buffer = state.shadow_buf,
          modeline = false,
        })
      end)
    end
  end
end

---Handle a message from the Python bridge
---@param state NotebookState
---@param msg table Parsed JSON message
local function handle_message(state, msg)
  local msg_type = msg.type
  local kernel = state.kernel
  if not kernel then
    return
  end

  if msg_type == "ready" then
    vim.schedule(function()
      vim.notify("Kernel bridge ready", vim.log.levels.INFO)
    end)

  elseif msg_type == "kernel_started" then
    kernel.connected = true
    kernel.kernel_id = msg.kernel_id
    kernel.kernel_name = msg.kernel_name
    kernel.execution_state = "idle"

    -- Update language from kernelspec if provided and different
    if msg.language then
      local lang = msg.language:lower()  -- treesitter needs lowercase
      local current_lang = state.metadata
        and state.metadata.language_info
        and state.metadata.language_info.name
      if current_lang ~= lang then
        vim.schedule(function()
          set_language(state, lang)
          vim.notify('Language updated from kernel: ' .. lang, vim.log.levels.INFO)
        end)
      end
    end

    vim.schedule(function()
      vim.notify("Kernel started: " .. msg.kernel_name, vim.log.levels.INFO)
    end)

  elseif msg_type == "kernel_connected" then
    kernel.connected = true
    kernel.execution_state = "idle"
    vim.schedule(function()
      vim.notify("Connected to kernel", vim.log.levels.INFO)
    end)

  elseif msg_type == "status" then
    kernel.execution_state = msg.state or "idle"
    if msg.cell_idx and type(msg.cell_idx) == "number" then
      update_cell_field(state, msg.cell_idx, "execution_state", msg.state)
      if msg.state == "idle" then
        kernel.pending_cells[msg.cell_idx] = nil
      end
    end

  elseif msg_type == "execute_input" then
    if msg.cell_idx and msg.execution_count then
      update_cell_field(state, msg.cell_idx, "execution_count", msg.execution_count)
    end

  elseif msg_type == "output" then
    if msg.cell_idx and msg.output then
      vim.schedule(function()
        if state.cells and state.cells[msg.cell_idx] then
          local cell = state.cells[msg.cell_idx]
          cell.outputs = cell.outputs or {}
          table.insert(cell.outputs, msg.output)
          require("ipynb.output").render_outputs(state, msg.cell_idx)
        end
      end)
    end

  elseif msg_type == "interrupted" then
    kernel.execution_state = "idle"
    kernel.pending_cells = {}
    vim.schedule(function()
      vim.notify("Kernel interrupted", vim.log.levels.INFO)
    end)

  elseif msg_type == "restarted" then
    kernel.execution_state = "idle"
    kernel.pending_cells = {}
    vim.schedule(function()
      vim.notify("Kernel restarted", vim.log.levels.INFO)
    end)

  elseif msg_type == "shutdown" then
    kernel.connected = false
    kernel.execution_state = "idle"
    kernel.pending_cells = {}

  elseif msg_type == "error" then
    vim.schedule(function()
      vim.notify("Kernel error: " .. (msg.error or "Unknown error"), vim.log.levels.ERROR)
    end)

  elseif msg_type == "is_alive" then
    if kernel.callbacks.is_alive then
      kernel.callbacks.is_alive(msg.alive)
      kernel.callbacks.is_alive = nil
    end

  elseif msg_type == "complete_reply" then
    if kernel.callbacks.complete then
      kernel.callbacks.complete(msg)
      kernel.callbacks.complete = nil
    end

  elseif msg_type == "inspect_reply" then
    local request_id = msg.request_id
    if request_id and kernel.callbacks.inspect[request_id] then
      kernel.callbacks.inspect[request_id](msg)
      kernel.callbacks.inspect[request_id] = nil
    end

  elseif msg_type == "pong" then
    if kernel.callbacks.ping then
      kernel.callbacks.ping()
      kernel.callbacks.ping = nil
    end
  end
end

---Find a virtual environment python by walking up the directory tree
---@param start_path string Path to start searching from
---@return string|nil python_path
local function find_venv_python(start_path)
  local venv_names = { ".venv", "venv", ".virtualenv", "env" }
  local dir = vim.fn.fnamemodify(start_path, ":p:h")

  while dir ~= "/" and dir ~= "" and dir ~= "." do
    for _, name in ipairs(venv_names) do
      local python = dir .. "/" .. name .. "/bin/python"
      if vim.fn.executable(python) == 1 then
        return python
      end
    end
    local parent = vim.fn.fnamemodify(dir, ":h")
    if parent == dir then
      break
    end
    dir = parent
  end

  return nil
end

---Discover Python executable to use
---@param notebook_path string|nil Path to notebook (for venv discovery)
---@param explicit_path string|nil Explicit python path (highest priority)
---@return string|nil python_path
---@return string source Description of where Python was found
local function discover_python(notebook_path, explicit_path)
  if explicit_path and explicit_path ~= "" then
    return explicit_path, "explicit"
  end

  local config = require("ipynb.config").get()
  if config.kernel and config.kernel.python_path then
    return config.kernel.python_path, "config"
  end

  if notebook_path then
    local venv = find_venv_python(notebook_path)
    if venv then
      return venv, "venv"
    end
  end

  local py3 = vim.fn.exepath("python3")
  if py3 ~= "" then
    return py3, "system"
  end

  local py = vim.fn.exepath("python")
  if py ~= "" then
    return py, "system"
  end

  return nil, "not found"
end

---Get the Python that would be used for a notebook (for display purposes)
---@param notebook_path string Path to the notebook file
---@return string|nil python_path
---@return string source Description of where Python was found
function M.get_python_info(notebook_path)
  return discover_python(notebook_path, nil)
end

---Start the Python bridge process for a notebook
---@param state NotebookState
---@param python_path string|nil Explicit python path (highest priority)
---@return boolean success
function M.start_bridge(state, python_path)
  if state.kernel and state.kernel.job_id then
    return true -- Already running for this notebook
  end

  state.kernel = state.kernel or create_kernel_state()

  local bridge_path = get_bridge_path()
  if vim.fn.filereadable(bridge_path) ~= 1 then
    vim.notify("Kernel bridge script not found: " .. bridge_path, vim.log.levels.ERROR)
    return false
  end

  local python, source = discover_python(state.source_path, python_path)
  if not python then
    vim.notify("Python not found. Install Python or set kernel.python_path in config.", vim.log.levels.ERROR)
    return false
  end

  vim.notify("Using Python: " .. python .. " (" .. source .. ")", vim.log.levels.INFO)

  local cmd = { python, bridge_path }

  local job_id = vim.fn.jobstart(cmd, {
    on_stdout = function(_, data, _)
      for _, line in ipairs(data) do
        if line and line ~= "" then
          local ok, msg = pcall(vim.json.decode, line)
          if ok and msg then
            handle_message(state, msg)
          end
        end
      end
    end,
    on_stderr = function(_, data, _)
      for _, line in ipairs(data) do
        if line and line ~= "" then
          vim.schedule(function()
            vim.notify("Kernel bridge stderr: " .. line, vim.log.levels.WARN)
          end)
        end
      end
    end,
    on_exit = function(_, code, _)
      if state.kernel then
        state.kernel.job_id = nil
        state.kernel.connected = false
      end
      vim.schedule(function()
        if code ~= 0 then
          vim.notify("Kernel bridge exited with code " .. code, vim.log.levels.WARN)
        end
      end)
    end,
    stdout_buffered = false,
    stderr_buffered = false,
  })

  if job_id <= 0 then
    vim.notify("Failed to start kernel bridge", vim.log.levels.ERROR)
    return false
  end

  state.kernel.job_id = job_id
  return true
end

---Get the kernel name from notebook metadata
---@param state NotebookState
---@return string kernel_name
function M.get_kernel_name(state)
  if state.metadata and state.metadata.kernelspec and state.metadata.kernelspec.name then
    return state.metadata.kernelspec.name
  end
  return "python3"
end

---Map kernel name to language name for treesitter injection
---@param kernel_name string Kernel name (e.g., "python3", "julia-1.9")
---@return string language name for treesitter (e.g., "python", "julia")
local function kernel_to_language(kernel_name)
  if kernel_name:match('^python') then
    return 'python'
  elseif kernel_name:match('^julia') then
    return 'julia'
  elseif kernel_name:match('^ir') or kernel_name:match('^r') then
    return 'r'
  else
    return kernel_name:lower()
  end
end

---Set the kernel name in notebook metadata
---@param state NotebookState
---@param kernel_name string Kernel name (e.g., "python3", "conda-ml")
function M.set_kernel_name(state, kernel_name)
  local lang = kernel_to_language(kernel_name)

  -- Update kernelspec metadata
  if not state.metadata then
    state.metadata = require('ipynb.io').default_metadata(kernel_name)
  elseif not state.metadata.kernelspec then
    state.metadata.kernelspec = {
      display_name = kernel_name,
      language = lang,
      name = kernel_name,
    }
  else
    state.metadata.kernelspec.name = kernel_name
    if state.metadata.kernelspec.display_name == 'Python 3' or
       state.metadata.kernelspec.display_name:match('^python') then
      state.metadata.kernelspec.display_name = kernel_name
    end
  end

  -- Update language (metadata, treesitter, LSP)
  set_language(state, lang)

  -- Refresh visuals to update cell borders with new language
  require('ipynb.visuals').render_all(state)

  vim.notify('Kernel set to: ' .. kernel_name .. ' (language: ' .. lang .. ')', vim.log.levels.INFO)
end

---Connect to a Jupyter kernel
---@param state NotebookState
---@param opts table|nil Options: connection_file, python_path
---@return boolean success
function M.connect(state, opts)
  opts = opts or {}

  if state.kernel and state.kernel.connected then
    vim.notify('Kernel already running. Use :NotebookKernelRestart to restart.', vim.log.levels.WARN)
    return true
  end

  if not M.start_bridge(state, opts.python_path) then
    return false
  end

  local kernel_name = M.get_kernel_name(state)

  vim.defer_fn(function()
    if opts.connection_file then
      send_command(state, {
        action = "connect",
        connection_file = opts.connection_file,
      })
    else
      send_command(state, {
        action = "start",
        kernel_name = kernel_name,
      })
    end
  end, 100)

  return true
end

---Disconnect from kernel
---@param state NotebookState
function M.disconnect(state)
  if state.kernel and state.kernel.job_id then
    send_command(state, { action = "shutdown" })
  end
end

---Execute a code cell
---@param state NotebookState
---@param cell_idx number
---@return boolean success
function M.execute(state, cell_idx)
  if not state.kernel or not state.kernel.connected then
    vim.notify("No kernel connected. Use :NotebookKernelStart", vim.log.levels.WARN)
    return false
  end

  local cell = state.cells[cell_idx]
  if not cell or cell.type ~= "code" then
    return false
  end

  require("ipynb.output").clear_outputs(state, cell_idx)

  cell.execution_state = "busy"
  state.kernel.pending_cells[cell_idx] = { cell_idx = cell_idx }

  require("ipynb.visuals").render_all(state)

  return send_command(state, {
    action = "execute",
    code = cell.source,
    cell_idx = cell_idx,
  })
end

---Execute all cells from current to end
---@param state NotebookState
---@param start_idx number|nil Start cell index (defaults to current cell)
function M.execute_all_below(state, start_idx)
  local cells_mod = require("ipynb.cells")

  if not start_idx then
    local cursor_line = vim.api.nvim_win_get_cursor(0)[1] - 1
    start_idx = cells_mod.get_cell_at_line(state, cursor_line) or 1
  end

  local to_execute = {}
  for i = start_idx, #state.cells do
    if state.cells[i].type == "code" then
      table.insert(to_execute, i)
    end
  end

  for _, idx in ipairs(to_execute) do
    M.execute(state, idx)
  end
end

---Interrupt kernel execution
---@param state NotebookState
function M.interrupt(state)
  if state.kernel and state.kernel.job_id then
    send_command(state, { action = "interrupt" })
  end
end

---Restart kernel
---@param state NotebookState
---@param clear_outputs boolean|nil Clear all outputs on restart
function M.restart(state, clear_outputs)
  if state.kernel and state.kernel.job_id then
    if clear_outputs then
      require("ipynb.output").clear_all_outputs(state)
      for _, cell in ipairs(state.cells) do
        cell.execution_count = nil
      end
      require("ipynb.visuals").render_all(state)
    end
    send_command(state, { action = "restart" })
  end
end

---Shutdown kernel
---@param state NotebookState
function M.shutdown(state)
  if state.kernel and state.kernel.job_id then
    send_command(state, { action = "shutdown" })
    vim.fn.jobstop(state.kernel.job_id)
    state.kernel.job_id = nil
  end
  if state.kernel then
    state.kernel.connected = false
  end
end

---Check if kernel is connected for a notebook
---@param state NotebookState
---@return boolean
function M.is_connected(state)
  return state.kernel and state.kernel.connected or false
end

---Check if kernel is busy for a notebook
---@param state NotebookState
---@return boolean
function M.is_busy(state)
  return state.kernel and state.kernel.execution_state == "busy" or false
end

---Get kernel state for a notebook
---@param state NotebookState
---@return KernelState|nil
function M.get_state(state)
  return state.kernel
end

---@class KernelInfo
---@field kernelspec string Kernel name from metadata
---@field python_path string|nil Python path for bridge
---@field python_source string Source of python discovery
---@field connected boolean Whether kernel is connected
---@field execution_state string Current state: "idle", "busy", "starting", "not started"
---@field running_kernel string|nil Name of running kernel

---Get kernel info for display (used by commands and keymaps)
---@param state NotebookState
---@return KernelInfo
function M.get_info(state)
  local kernel_state = state.kernel
  local python_path, python_source = discover_python(state.source_path, nil)

  return {
    kernelspec = M.get_kernel_name(state),
    python_path = python_path,
    python_source = python_source,
    connected = kernel_state and kernel_state.connected or false,
    execution_state = kernel_state and kernel_state.execution_state or 'not started',
    running_kernel = kernel_state and kernel_state.connected and kernel_state.kernel_name or nil,
  }
end

---Get statusline component for kernel status
---@param state NotebookState|nil
---@return string status Status string for statusline
---@return string hl_state State for highlight: "disconnected", "busy", "ready"
function M.statusline(state)
  local config = require('ipynb.config').get()
  if not config.kernel.show_status then
    return '', 'disconnected'
  end

  if not state then
    state = require('ipynb.state').get()
  end
  if not state then
    return '', 'disconnected'
  end

  local lang = state.shadow_lang or 'python' ---@diagnostic disable-line: undefined-field
  local icon = require('ipynb.visuals').get_language_icon(lang) or '󰌠'

  if state.kernel and state.kernel.connected then
    if state.kernel.execution_state == 'busy' then
      return icon .. ' BUSY', 'busy'
    else
      return icon .. ' IDLE', 'ready'
    end
  else
    return icon .. ' DISC', 'disconnected'
  end
end

---Get highlight group for statusline state (for lualine color option)
---@param hl_state string|nil State: "disconnected", "busy", "ready". If nil, auto-detects from current buffer.
---@return table color Lualine color table with fg from highlight group
function M.statusline_color(hl_state)
  if not hl_state then
    local _, state = M.statusline()
    hl_state = state
  end
  local hl_map = {
    disconnected = 'DiagnosticError',
    busy = 'DiagnosticWarn',
    ready = 'DiagnosticOk',
  }
  local hl_group = hl_map[hl_state] or 'Comment'

  local hl = vim.api.nvim_get_hl(0, { name = hl_group, link = false })
  if hl.fg then
    return { fg = string.format('#%06x', hl.fg) }
  end

  return {}
end

---Check if statusline component should be shown (for lualine cond)
---@return boolean
function M.statusline_visible()
  local config = require('ipynb.config').get()
  if not config.kernel.show_status then
    return false
  end
  return require('ipynb.state').get() ~= nil
end

---Request code completion from kernel
---@param state NotebookState
---@param code string Code to complete
---@param cursor_pos number Cursor position in code
---@param callback function Callback with completion results
function M.complete(state, code, cursor_pos, callback)
  if not state.kernel or not state.kernel.connected then
    callback(nil)
    return
  end

  state.kernel.callbacks.complete = callback
  send_command(state, {
    action = "complete",
    code = code,
    cursor_pos = cursor_pos,
  })
end

---Request variable/object inspection from kernel (language-agnostic)
---@param state NotebookState
---@param code string Code/identifier to inspect
---@param cursor_pos number|nil Cursor position (defaults to end of code)
---@param callback function Callback with inspect result
---@param request_id string|nil Optional request ID (auto-generated if not provided)
function M.inspect(state, code, cursor_pos, callback, request_id)
  if not state.kernel or not state.kernel.connected then
    callback({ found = false, data = {}, metadata = {} })
    return
  end

  cursor_pos = cursor_pos or #code
  request_id = request_id or (code .. "_" .. tostring(vim.loop.hrtime()))

  state.kernel.callbacks.inspect[request_id] = callback

  send_command(state, {
    action = "inspect",
    code = code,
    cursor_pos = cursor_pos,
    detail_level = 0,
    request_id = request_id,
  })
end

---Inspect multiple identifiers and collect results
---@param state NotebookState
---@param identifiers string[] List of identifiers to inspect
---@param callback function Callback with results
---@param timeout number|nil Timeout in ms (default 5000)
function M.inspect_batch(state, identifiers, callback, timeout)
  if not state.kernel or not state.kernel.connected then
    callback({})
    return
  end

  if #identifiers == 0 then
    callback({})
    return
  end

  timeout = timeout or 5000
  local results = {}
  local pending = #identifiers
  local completed = false

  local timer = vim.uv.new_timer()
  if timer then
    timer:start(timeout, 0, vim.schedule_wrap(function()
      if not completed then
        completed = true
        timer:stop()
        timer:close()
        callback(results)
      end
    end))
  end

  for _, ident in ipairs(identifiers) do
    local request_id = ident .. "_" .. vim.loop.hrtime()
    M.inspect(state, ident, #ident, function(reply)
      if completed then return end

      results[ident] = {
        found = reply.found,
        sections = reply.sections or {},
        data = reply.data or {},
        metadata = reply.metadata or {},
      }

      pending = pending - 1
      if pending == 0 then
        completed = true
        if timer then
          timer:stop()
          timer:close()
        end
        callback(results)
      end
    end, request_id)
  end
end

---Ping the kernel bridge to check responsiveness
---@param state NotebookState
---@param callback function Callback on pong
function M.ping(state, callback)
  if not state.kernel or not state.kernel.job_id then
    callback(false)
    return
  end

  state.kernel.callbacks.ping = function()
    callback(true)
  end

  vim.defer_fn(function()
    if state.kernel and state.kernel.callbacks.ping then
      state.kernel.callbacks.ping = nil
      callback(false)
    end
  end, 2000)

  send_command(state, { action = "ping" })
end

---List available Jupyter kernels
---@param notebook_path string|nil Path to notebook (for Python discovery)
---@param callback fun(kernels: table[]|nil, error: string|nil) Called with results
function M.list_kernels(notebook_path, callback)
  local python, source = discover_python(notebook_path, nil)
  if not python then
    callback(nil, 'Python not found in PATH or venv')
    return
  end

  local cmd = { python, '-m', 'jupyter', 'kernelspec', 'list', '--json' }

  vim.system(
    cmd,
    { text = true },
    function(result)
      vim.schedule(function()
        if result.code ~= 0 then
          local stderr = result.stderr or ''
          -- Trim and get first line of stderr for cleaner message
          stderr = stderr:gsub('^%s+', ''):gsub('%s+$', '')
          local first_line = stderr:match('^[^\n]*') or ''
          callback(nil, string.format(
            'jupyter command failed (python: %s [%s], exit: %d): %s',
            python, source, result.code, first_line
          ))
          return
        end

        local ok, data = pcall(vim.json.decode, result.stdout)
        if not ok or not data.kernelspecs then
          callback(nil, string.format(
            'Failed to parse kernel list (python: %s [%s])',
            python, source
          ))
          return
        end

        local kernels = {}
        for name, spec in pairs(data.kernelspecs) do
          table.insert(kernels, {
            name = name,
            display_name = spec.spec and spec.spec.display_name or name,
            language = spec.spec and spec.spec.language or nil,
          })
        end

        table.sort(kernels, function(a, b) return a.name < b.name end)
        callback(kernels, nil)
      end)
    end
  )
end

return M
