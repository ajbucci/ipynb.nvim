-- ipynb/health.lua - Health check for :checkhealth notebook

local M = {}

local health = vim.health
local util = require('ipynb.util')

---Check Neovim version
local function check_neovim()
  health.start('Neovim')

  local version = vim.version()
  local version_str = string.format('%d.%d.%d', version.major, version.minor, version.patch)

  if version.major > 0 or (version.major == 0 and version.minor >= 10) then
    health.ok('Neovim version ' .. version_str .. ' (>= 0.10 required)')
  else
    health.error('Neovim version ' .. version_str .. ' is too old', {
      'ipynb.nvim requires Neovim 0.10 or later',
      'Upgrade Neovim: https://github.com/neovim/neovim/releases',
    })
  end
end

---Check treesitter and parser
local function check_treesitter()
  health.start('Tree-sitter')

  -- Check nvim-treesitter
  local ts_ok = pcall(require, 'nvim-treesitter')
  if ts_ok then
    health.ok('nvim-treesitter is installed')
  else
    health.error('nvim-treesitter is not installed', {
      'Install nvim-treesitter: https://github.com/nvim-treesitter/nvim-treesitter',
    })
    return
  end

  -- Check ipynb parser
  local parser_ok = pcall(vim.treesitter.language.inspect, 'ipynb')
  if parser_ok then
    health.ok('ipynb tree-sitter parser is installed')
  else
    -- Check if parser source exists
    local plugin_root = util.get_plugin_root()
    local parser_dir = plugin_root .. '/tree-sitter-ipynb'
    local grammar_exists = vim.fn.filereadable(parser_dir .. '/grammar.js') == 1

    if grammar_exists then
      health.warn('ipynb tree-sitter parser not compiled', {
        'Parser should auto-compile on first load',
        'Try restarting Neovim or run :TSInstall! ipynb manually',
      })
    else
      health.error('ipynb tree-sitter parser source not found', {
        'The tree-sitter-ipynb directory is missing from the plugin',
        'Try reinstalling the plugin',
      })
    end
  end

  health.info('Install tree-sitter parsers for your notebook languages (e.g., :TSInstall python markdown julia r)')
end

---Check Python and kernel bridge
local function check_python()
  health.start('Python & Kernel')

  -- Check kernel bridge script
  local plugin_root = util.get_plugin_root()
  local bridge_path = plugin_root .. '/python/kernel_bridge.py'
  if vim.fn.filereadable(bridge_path) == 1 then
    health.ok('kernel_bridge.py found')
  else
    health.error('kernel_bridge.py not found', {
      'Expected at: ' .. bridge_path,
      'Try reinstalling the plugin',
    })
  end

  -- Check for Python
  local python_path = vim.fn.exepath('python3')
  if python_path == '' then
    python_path = vim.fn.exepath('python')
  end

  if python_path ~= '' then
    health.ok('Python found: ' .. python_path)
  else
    health.warn('Python not found in PATH', {
      'Set kernel.python_path in your config to specify Python location',
    })
  end

  health.info('Kernel execution requires jupyter_client (pip install jupyter_client)')
end

---Check optional dependencies
local function check_optional()
  health.start('Optional dependencies')

  -- nvim-web-devicons for language icons
  local devicons_ok = pcall(require, 'nvim-web-devicons')
  if devicons_ok then
    health.ok('nvim-web-devicons installed (language icons in cell borders)')
  else
    health.info('nvim-web-devicons not installed (optional, for language icons)')
  end

  -- snacks.nvim for images
  local snacks_ok, Snacks = pcall(require, 'snacks')
  if snacks_ok then
    local has_image = Snacks.image and Snacks.image.placement
    if has_image then
      -- Check terminal support
      local terminal_supported = true
      if Snacks.image.supports_terminal then
        terminal_supported = Snacks.image.supports_terminal()
      end

      if terminal_supported then
        health.ok('snacks.nvim image support available')
      else
        health.info('snacks.nvim installed but terminal does not support images (requires kitty graphics protocol)')
      end
    else
      health.info('snacks.nvim installed but image module not available')
    end
  else
    health.info('snacks.nvim not installed (optional, for inline images)')
  end
end

---Check plugin configuration
local function check_config()
  health.start('Configuration')

  local config_ok, config = pcall(require, 'ipynb.config')
  if not config_ok then
    health.error('Failed to load notebook.config module')
    return
  end

  local cfg = config.get()
  if cfg then
    health.ok('Configuration loaded')

    -- Check custom python path if set
    local custom_python = cfg.kernel and cfg.kernel.python_path
    if custom_python then
      if vim.fn.executable(custom_python) == 1 then
        health.ok('kernel.python_path: ' .. custom_python)
      else
        health.error('kernel.python_path not executable: ' .. custom_python)
      end
    end
  else
    health.warn('Configuration not initialized', {
      'Call require("ipynb").setup() in your config',
    })
  end
end

---Main health check function
function M.check()
  check_neovim()
  check_treesitter()
  check_python()
  check_optional()
  check_config()
end

return M
