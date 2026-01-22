-- Minimal init.lua for headless testing
-- Run tests with: nvim --headless -u tests/minimal_init.lua -l tests/test_undo.lua

-- Determine plugin path from this file's location
local script_path = debug.getinfo(1, 'S').source:sub(2)
local tests_dir = vim.fn.fnamemodify(script_path, ':p:h')
local plugin_dir = vim.fn.fnamemodify(tests_dir, ':h')

-- Add plugin to runtimepath
vim.opt.rtp:prepend(plugin_dir)

-- Add tree-sitter-ipynb for parser
vim.opt.rtp:append(plugin_dir .. '/tree-sitter-ipynb')

-- Optionally append extra runtime paths (useful for isolated test appnames)
if vim.env.IPYNB_TEST_EXTRA_RTP and vim.env.IPYNB_TEST_EXTRA_RTP ~= '' then
  for _, entry in ipairs(vim.split(vim.env.IPYNB_TEST_EXTRA_RTP, ',', { trimempty = true })) do
    vim.opt.rtp:append(entry)
  end
end

-- Optionally reuse a real packpath and load its start packages
if vim.env.IPYNB_TEST_REAL_PACKPATH and vim.env.IPYNB_TEST_REAL_PACKPATH ~= '' then
  vim.o.packpath = vim.o.packpath .. ',' .. vim.env.IPYNB_TEST_REAL_PACKPATH
  for _, base in ipairs(vim.split(vim.env.IPYNB_TEST_REAL_PACKPATH, ',', { trimempty = true })) do
    local start_dirs = vim.fn.glob(base .. '/pack/*/start/*', true, true)
    for _, dir in ipairs(start_dirs) do
      vim.opt.rtp:append(dir)
    end
  end
end

-- Add lazy.nvim plugins if available (for LSP tests)
local data_home = vim.fn.stdpath('data')
if vim.env.IPYNB_TEST_REAL_DATA_HOME and vim.env.IPYNB_TEST_REAL_DATA_HOME ~= '' then
  data_home = vim.env.IPYNB_TEST_REAL_DATA_HOME
end
local lazy_path = data_home .. '/lazy'
if vim.fn.isdirectory(lazy_path) == 1 then
  -- Add nvim-treesitter
  local ts_path = lazy_path .. '/nvim-treesitter'
  if vim.fn.isdirectory(ts_path) == 1 then
    vim.opt.rtp:append(ts_path)
  end

  -- Add lspconfig
  local lspconfig_path = lazy_path .. '/nvim-lspconfig'
  if vim.fn.isdirectory(lspconfig_path) == 1 then
    vim.opt.rtp:append(lspconfig_path)
  end
  -- Add mason for finding LSP binaries
  local mason_path = lazy_path .. '/mason.nvim'
  if vim.fn.isdirectory(mason_path) == 1 then
    vim.opt.rtp:append(mason_path)
  end
end

-- Minimal settings for testing
vim.o.swapfile = false
vim.o.backup = false
vim.o.writebackup = false
vim.o.undofile = false
vim.o.hidden = true

-- Set fillchars to prevent errors when ftplugin tries to append
vim.o.fillchars = 'eob: '

-- Needed for window options to work
vim.o.foldenable = true
vim.o.foldmethod = 'manual'

-- Load the plugin
require('ipynb').setup()

-- Setup basedpyright LSP if available (for LSP tests)
local has_lspconfig, lspconfig = pcall(require, 'lspconfig')
if has_lspconfig then
  local cmd = nil
  local lsp_bin = vim.env.IPYNB_TEST_LSP_BIN
  local lsp_args = vim.env.IPYNB_TEST_LSP_ARGS

  if lsp_bin and lsp_bin ~= '' and vim.fn.executable(lsp_bin) == 1 then
    cmd = { lsp_bin }
    if lsp_args and lsp_args ~= '' then
      for _, arg in ipairs(vim.split(lsp_args, ' ', { trimempty = true })) do
        table.insert(cmd, arg)
      end
    end
    lspconfig.basedpyright.setup({ cmd = cmd })
  else
    if vim.fn.executable('basedpyright-langserver') == 1 then
      lspconfig.basedpyright.setup({})
    elseif vim.fn.executable('pyright-langserver') == 1 then
      lspconfig.pyright.setup({})
    end
  end

  -- Optional ruff LSP for formatting (ruff binary)
  local venv_ruff = plugin_dir .. '/tests/.nvim-test/venv/bin/ruff'
  if vim.fn.executable(venv_ruff) == 1 then
    if lspconfig.ruff then
      lspconfig.ruff.setup({ cmd = { venv_ruff, 'server' } })
    end
  elseif vim.fn.executable('ruff') == 1 then
    if lspconfig.ruff then
      lspconfig.ruff.setup({ cmd = { 'ruff', 'server' } })
    end
  end
end

-- Register treesitter parser (skip if requested by tests)
if vim.env.IPYNB_TEST_SKIP_PARSER_SO ~= '1' then
  local parser_path = plugin_dir .. '/tree-sitter-ipynb/parser.so'
  if vim.fn.filereadable(parser_path) == 1 then
    pcall(vim.treesitter.language.add, 'ipynb', { path = parser_path })
  end
end
