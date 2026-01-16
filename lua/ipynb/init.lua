-- ipynb.nvim - Modal Jupyter notebook editor (see :help ipynb)

local M = {}

local util = require('ipynb.util')

---Check if notebook parser is already available
---@return boolean
local function parser_available()
  local ok = pcall(vim.treesitter.language.inspect, 'ipynb')
  return ok
end

---Register custom directive for dynamic language injection
---This allows the injection query to read the language from a buffer variable
local function setup_injection_directive()
  vim.treesitter.query.add_directive('inject-notebook-language!', function(match, pattern, source, pred, metadata)
    local bufnr = type(source) == 'number' and source or source:source()
    -- Read language from buffer variable, default to python
    metadata['injection.language'] = vim.b[bufnr].ipynb_language or 'python'
  end, { force = true })
end

---Setup treesitter parser for notebook filetype
local function setup_treesitter()
  local plugin_root = util.get_plugin_root()
  local parser_dir = plugin_root .. '/tree-sitter-ipynb'

  -- Add queries to runtime path so treesitter can find them
  vim.opt.runtimepath:append(parser_dir)

  -- Register the filetype to language mapping
  vim.treesitter.language.register('ipynb', 'ipynb')

  -- Register custom directive for dynamic language injection
  setup_injection_directive()

  -- Check if parser is already compiled and available
  if parser_available() then
    return true
  end

  -- Register with nvim-treesitter for compilation
  local ok, parsers = pcall(require, 'nvim-treesitter.parsers')
  if not ok then
    vim.notify(
      '[ipynb.nvim] Treesitter parser not found. Install nvim-treesitter and run :TSInstall ipynb',
      vim.log.levels.WARN
    )
    return false
  end

  -- Register parser config with nvim-treesitter using local path
  -- Use recommended User TSUpdate autocmd pattern for persistence across updates
  vim.api.nvim_create_autocmd('User', {
    pattern = 'TSUpdate',
    callback = function()
      require('nvim-treesitter.parsers').ipynb = {
        install_info = {
          path = parser_dir,
        },
      }
    end,
  })

  -- Also register immediately for TSInstall to work now
  parsers.ipynb = {
    install_info = {
      path = parser_dir,
    },
  }

  -- Auto-install parser if not available
  vim.defer_fn(function()
    if not parser_available() then
      vim.notify('[ipynb.nvim] Compiling treesitter parser...', vim.log.levels.INFO)
      -- Use pcall in case nvim-treesitter API changes
      local install_ok, install_mod = pcall(require, 'nvim-treesitter.install')
      if install_ok and install_mod.ensure_installed then
        -- ensure_installed returns a function that takes language names
        install_mod.ensure_installed('ipynb')
      else
        -- Fallback to command
        vim.cmd('TSInstall! ipynb')
      end
    end
  end, 100)

  return false
end

---Setup the notebook plugin
---@param opts NotebookConfig|nil Configuration overrides (see :help ipynb-config)
function M.setup(opts)
  -- Setup configuration
  local config = require('ipynb.config')
  config.setup(opts)

  -- Setup treesitter parser (must be before highlights for proper TS integration)
  setup_treesitter()

  -- Setup highlights
  require('ipynb.visuals').setup_highlights()

  -- Register autocmds for .ipynb files
  vim.api.nvim_create_autocmd('BufReadCmd', {
    pattern = '*.ipynb',
    group = vim.api.nvim_create_augroup('NotebookRead', { clear = true }),
    callback = function(args)
      -- Skip custom URI schemes (e.g., nb://test.ipynb used for picker previews)
      if args.file:match('^%w+://') then
        return
      end
      require('ipynb.io').open_notebook(args.buf, args.file)
    end,
  })

  vim.api.nvim_create_autocmd('BufWriteCmd', {
    pattern = '*.ipynb',
    group = vim.api.nvim_create_augroup('NotebookWrite', { clear = true }),
    callback = function(args)
      require('ipynb.io').save_notebook(args.buf, args.file)
    end,
  })

  -- Setup user commands
  require('ipynb.commands').setup()
end

---Get current notebook state
---@return NotebookState|nil
function M.get_state()
  return require('ipynb.state').get()
end

---Get configuration
---@return NotebookConfig
function M.get_config()
  return require('ipynb.config').get()
end

return M
