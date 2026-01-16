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

-- Add lazy.nvim plugins if available (for LSP tests)
local lazy_path = vim.fn.stdpath('data') .. '/lazy'
if vim.fn.isdirectory(lazy_path) == 1 then
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

-- Add Mason bin to PATH for LSP binaries (cross-platform)
local has_mason, mason = pcall(require, 'mason')
if has_mason then
  mason.setup()
  -- Mason adds its bin dir to PATH when setup() is called
end

-- Load the plugin
require('ipynb').setup()

-- Setup basedpyright LSP if available (for LSP tests)
local has_lspconfig, lspconfig = pcall(require, 'lspconfig')
if has_lspconfig then
  local mason_packages = vim.fn.stdpath('data') .. '/mason/packages'
  local cmd = nil

  -- Check basedpyright first, then pyright (via Mason)
  for _, pkg_name in ipairs({ 'basedpyright', 'pyright' }) do
    local bin_path = mason_packages .. '/' .. pkg_name .. '/node_modules/.bin/' .. pkg_name .. '-langserver'
    if vim.fn.executable(bin_path) == 1 then
      cmd = { bin_path, '--stdio' }
      if pkg_name == 'basedpyright' then
        lspconfig.basedpyright.setup({ cmd = cmd })
      else
        lspconfig.pyright.setup({ cmd = cmd })
      end
      break
    end
  end

  -- Fallback: check if already in PATH
  if not cmd then
    if vim.fn.executable('basedpyright-langserver') == 1 then
      lspconfig.basedpyright.setup({})
    elseif vim.fn.executable('pyright-langserver') == 1 then
      lspconfig.pyright.setup({})
    end
  end
end

-- Register treesitter parser
local parser_path = plugin_dir .. '/tree-sitter-ipynb/parser.so'
if vim.fn.filereadable(parser_path) == 1 then
  pcall(vim.treesitter.language.add, 'ipynb', { path = parser_path })
end
