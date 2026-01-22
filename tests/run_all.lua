-- Cross-platform test runner for ipynb.nvim

local function script_dir()
  return vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h')
end

local root = vim.fn.fnamemodify(script_dir(), ':h')
local tests_dir = script_dir()

local function join(a, b)
  if a:sub(-1) == '/' then
    return a .. b
  end
  return a .. '/' .. b
end

local function exe(name)
  return vim.fn.executable(name) == 1
end

local function is_windows()
  return vim.fn.has('win32') == 1
end

local function venv_bin(venv_dir, name)
  if is_windows() then
    return join(venv_dir, 'Scripts/' .. name .. '.exe')
  end
  return join(venv_dir, 'bin/' .. name)
end

local function ensure_env()
  local base = join(tests_dir, '.nvim-test')
  vim.env.XDG_DATA_HOME = vim.env.XDG_DATA_HOME or join(base, 'share')
  vim.env.XDG_STATE_HOME = vim.env.XDG_STATE_HOME or join(base, 'state')
  vim.env.XDG_CACHE_HOME = vim.env.XDG_CACHE_HOME or join(base, 'cache')
  vim.env.XDG_CONFIG_HOME = vim.env.XDG_CONFIG_HOME or join(base, 'config')
  vim.env.NVIM_APPNAME = vim.env.NVIM_APPNAME or 'ipynb-test'
end

local function app_data_dir()
  return join(vim.env.XDG_DATA_HOME, vim.env.NVIM_APPNAME)
end

local function lazy_path()
  return join(app_data_dir(), 'lazy/lazy.nvim')
end

local function bootstrap_lazy()
  if not exe('git') then
    print('WARN: git not found; skipping bootstrap')
    return false
  end

  local target = lazy_path()
  if vim.loop.fs_stat(target) then
    return true
  end

  vim.fn.mkdir(target, 'p')
  local result = vim.system({
    'git',
    'clone',
    '--filter=blob:none',
    'https://github.com/folke/lazy.nvim.git',
    '--branch=stable',
    target,
  }, { text = true }):wait()

  if result.code ~= 0 then
    print('WARN: failed to clone lazy.nvim')
    if result.stderr and result.stderr ~= '' then
      print(result.stderr)
    end
    return false
  end

  return true
end

local function bootstrap_plugins()
  local ok = bootstrap_lazy()
  if not ok then
    return false
  end

  local cmd = {
    'nvim',
    '--headless',
    '-u',
    join(tests_dir, 'bootstrap_init.lua'),
    '+qa',
  }
  local result = vim.system(cmd, {
    env = {
      XDG_DATA_HOME = vim.env.XDG_DATA_HOME,
      XDG_STATE_HOME = vim.env.XDG_STATE_HOME,
      XDG_CACHE_HOME = vim.env.XDG_CACHE_HOME,
      XDG_CONFIG_HOME = vim.env.XDG_CONFIG_HOME,
      NVIM_APPNAME = vim.env.NVIM_APPNAME,
    },
    text = true,
  }):wait()

  if result.code ~= 0 then
    print('WARN: plugin bootstrap failed')
    if result.stdout and result.stdout ~= '' then
      print(result.stdout)
    end
    if result.stderr and result.stderr ~= '' then
      print(result.stderr)
    end
    return false
  end

  return true
end

local function ensure_venv_lsp()
  if vim.env.IPYNB_TEST_SKIP_LSP_BOOTSTRAP == '1' then
    return
  end

  local venv_dir = join(tests_dir, '.nvim-test/venv')
  local py = exe('python3') and 'python3' or 'python'
  if not exe(py) then
    print('WARN: python not found; skipping LSP bootstrap')
    return
  end

  local venv_python = venv_bin(venv_dir, 'python')
  if not vim.loop.fs_stat(venv_python) then
    local res = vim.system({ py, '-m', 'venv', venv_dir }, { text = true }):wait()
    if res.code ~= 0 then
      print('WARN: failed to create venv')
      if res.stderr and res.stderr ~= '' then
        print(res.stderr)
      end
      return
    end
  end

  local pip = venv_bin(venv_dir, 'pip')
  if not vim.loop.fs_stat(pip) then
    print('WARN: pip not found in venv; skipping LSP bootstrap')
    return
  end

  local basedpyright = venv_bin(venv_dir, 'basedpyright-langserver')
  if not vim.loop.fs_stat(basedpyright) then
    vim.system({ pip, 'install', '--upgrade', 'pip' }, { text = true }):wait()
    vim.system({ pip, 'install', 'basedpyright' }, { text = true }):wait()
  end

  local ruff = venv_bin(venv_dir, 'ruff')
  if not vim.loop.fs_stat(ruff) then
    vim.system({ pip, 'install', 'ruff' }, { text = true }):wait()
  end

  if vim.loop.fs_stat(basedpyright) then
    vim.env.IPYNB_TEST_LSP_BIN = basedpyright
    vim.env.IPYNB_TEST_LSP_ARGS = '--stdio'
  end
end

local function ensure_gopls_lsp()
  if vim.env.IPYNB_TEST_SKIP_GOPLS_BOOTSTRAP == '1' then
    return
  end

  if exe('gopls') then
    vim.env.IPYNB_TEST_GOPLS_BIN = 'gopls'
    return
  end

  if exe('go') then
    print('Bootstrapping gopls via go install...')
    vim.system({ 'go', 'install', 'golang.org/x/tools/gopls@latest' }, { text = true }):wait()
    if exe('gopls') then
      vim.env.IPYNB_TEST_GOPLS_BIN = 'gopls'
      return
    end
  else
    print('WARN: go not found; skipping gopls bootstrap')
  end
end

local function run_test_file(test_file)
  local name = vim.fn.fnamemodify(test_file, ':t:r')
  print('>>> Running ' .. name .. '...')

  local cmd = {
    'nvim',
    '--headless',
    '-u',
    join(tests_dir, 'minimal_init.lua'),
    '-l',
    test_file,
  }

  local env = {
    PATH = vim.env.PATH,
    XDG_DATA_HOME = vim.env.XDG_DATA_HOME,
    XDG_STATE_HOME = vim.env.XDG_STATE_HOME,
    XDG_CACHE_HOME = vim.env.XDG_CACHE_HOME,
    XDG_CONFIG_HOME = vim.env.XDG_CONFIG_HOME,
    NVIM_APPNAME = vim.env.NVIM_APPNAME,
    IPYNB_TEST_SKIP_PARSER_SO = vim.env.IPYNB_TEST_SKIP_PARSER_SO,
  }

  -- Default LSP env (pyright/basedpyright)
  env.IPYNB_TEST_LSP_BIN = vim.env.IPYNB_TEST_LSP_BIN
  env.IPYNB_TEST_LSP_ARGS = vim.env.IPYNB_TEST_LSP_ARGS

  -- Override for gopls test file
  if test_file:match('test_lsp_go%.lua$') then
    env.IPYNB_TEST_LSP_SERVER = 'gopls'
    env.IPYNB_TEST_LSP_BIN = vim.env.IPYNB_TEST_GOPLS_BIN or env.IPYNB_TEST_LSP_BIN
    env.IPYNB_TEST_LSP_ARGS = nil
  end

  local stdout = vim.loop.new_pipe(false)
  local stderr = vim.loop.new_pipe(false)
  local exit_code = nil
  local exit_signal = nil

  local handle
  local env_list = {}
  for k, v in pairs(env) do
    if v and v ~= '' then
      table.insert(env_list, k .. '=' .. v)
    end
  end

  handle = vim.loop.spawn(cmd[1], {
    args = { unpack(cmd, 2) },
    stdio = { nil, stdout, stderr },
    env = env_list,
  }, function(code, signal)
    exit_code = code
    exit_signal = signal
    stdout:read_stop()
    stderr:read_stop()
    stdout:close()
    stderr:close()
    if handle then
      handle:close()
    end
  end)

  local stdout_buf = ''
  local stderr_buf = ''

  local function emit_lines(chunk, is_stderr)
    local cleaned = chunk:gsub('\r', ''):gsub('\t', '  ')
    local buf = is_stderr and stderr_buf or stdout_buf
    buf = buf .. cleaned

    local lines = {}
    local start = 1
    while true do
      local nl = buf:find('\n', start, true)
      if not nl then
        break
      end
      table.insert(lines, buf:sub(start, nl))
      start = nl + 1
    end
    buf = buf:sub(start)

    if is_stderr then
      stderr_buf = buf
    else
      stdout_buf = buf
    end

    if #lines > 0 then
      local out = table.concat(lines, '')
      vim.schedule(function()
        vim.api.nvim_out_write(out)
      end)
    end
  end

  local function on_read(_, data)
    if data then
      emit_lines(data, false)
    end
  end

  local function on_err(_, data)
    if data then
      emit_lines(data, true)
    end
  end

  stdout:read_start(on_read)
  stderr:read_start(on_err)

  vim.wait(300000, function()
    return exit_code ~= nil
  end, 100)

  if stdout_buf ~= '' then
    vim.schedule(function()
      vim.api.nvim_out_write(stdout_buf .. '\n')
    end)
  end
  if stderr_buf ~= '' then
    vim.schedule(function()
      vim.api.nvim_out_write(stderr_buf .. '\n')
    end)
  end

  if exit_code ~= 0 then
    if exit_signal ~= 0 and exit_signal ~= nil then
      print('Process exited with signal: ' .. tostring(exit_signal))
    end
    return false
  end
  return true
end

ensure_env()

if vim.env.IPYNB_TEST_SKIP_BOOTSTRAP ~= '1' then
  if vim.env.IPYNB_TEST_FORCE_BOOTSTRAP == '1' or not vim.loop.fs_stat(lazy_path()) then
    bootstrap_plugins()
  else
    print('Bootstrap already present; skipping. Set IPYNB_TEST_FORCE_BOOTSTRAP=1 to force.')
  end
end

ensure_venv_lsp()
ensure_gopls_lsp()

print('Running ipynb.nvim test suite')
print('==============================')
print('')

local total_failed = 0

local tests = {
  join(root, 'tests/test_cells.lua'),
  join(root, 'tests/test_modified.lua'),
  join(root, 'tests/test_undo.lua'),
  join(root, 'tests/test_io.lua'),
  join(root, 'tests/test_lsp.lua'),
  join(root, 'tests/test_lsp_go.lua'),
  join(root, 'tests/test_treesitter_autoinstall.lua'),
}

for _, test in ipairs(tests) do
  local ok = run_test_file(test)
  if not ok then
    total_failed = total_failed + 1
  end
end

print('')
print('==============================')
print('All test suites completed')

if total_failed > 0 then
  vim.cmd('cquit')
end
