-- ftplugin/ipynb.lua - Filetype settings for notebook buffers
-- Note: Treesitter highlighting is started by facade.lua using the ipynb grammar

-- Window settings - custom folding for cell content
vim.wo.foldmethod = "expr"
vim.wo.foldexpr = 'v:lua.require("ipynb.folding").foldexpr()'
vim.wo.foldtext = 'v:lua.require("ipynb.folding").foldtext()'
vim.wo.foldenable = true
vim.wo.foldlevel = 99 -- Start all unfolded
vim.opt_local.fillchars:append({ fold = " " }) -- Clean fold fill

