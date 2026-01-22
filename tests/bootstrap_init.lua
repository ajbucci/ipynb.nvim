-- Bootstrap init for installing test dependencies via lazy.nvim

local script_path = debug.getinfo(1, 'S').source:sub(2)
local tests_dir = vim.fn.fnamemodify(script_path, ':p:h')
local plugin_dir = vim.fn.fnamemodify(tests_dir, ':h')

local lazypath = vim.fn.stdpath('data') .. '/lazy/lazy.nvim'
if not vim.loop.fs_stat(lazypath) then
  vim.notify('lazy.nvim not found; bootstrap_nvim.sh should install it first', vim.log.levels.ERROR)
  vim.cmd('cquit')
end

vim.opt.rtp:prepend(lazypath)

require('lazy').setup({
  {
    'nvim-treesitter/nvim-treesitter',
    build = ':TSUpdate',
  },
  'neovim/nvim-lspconfig',
}, {
  root = vim.fn.stdpath('data') .. '/lazy',
  defaults = { lazy = true },
  install = { missing = true },
  change_detection = { enabled = false },
  checker = { enabled = false },
})

-- Ensure our plugin is on the runtimepath so :TSUpdate can see parser sources.
vim.opt.rtp:prepend(plugin_dir)

-- Kick off install/sync.
require('lazy').sync({ wait = true })

vim.cmd('qa!')
