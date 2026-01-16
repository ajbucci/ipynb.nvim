-- Test script to verify treesitter parser is working
-- Run with: nvim -l tests/test_treesitter.lua

local script_path = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h')
local plugin_path = vim.fn.fnamemodify(script_path, ':h') -- Go up one level from tests/

-- Add to runtime path
vim.opt.rtp:prepend(plugin_path)
vim.opt.rtp:append(plugin_path .. '/tree-sitter-ipynb')

-- Register the language
vim.treesitter.language.register('ipynb', 'ipynb')

-- Try to load the parser (tree-sitter build outputs parser.so on all platforms)
local parser_path = plugin_path .. '/tree-sitter-ipynb/parser.so'
local ok, err = pcall(vim.treesitter.language.add, 'ipynb', { path = parser_path })

if not ok then
  print('Failed to load parser: ' .. tostring(err))
  vim.cmd('qa!')
end

print('Parser loaded successfully!')

-- Create a test buffer
local buf = vim.api.nvim_create_buf(false, true)
local test_content = [[
# <<ipynb_nvim:markdown>>
# Title
# <</ipynb_nvim>>

# <<ipynb_nvim:code>>
print("hello")
# <</ipynb_nvim>>
]]

vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(test_content, '\n'))
vim.bo[buf].filetype = 'ipynb'

-- Try to get the parser for the buffer
local parser = vim.treesitter.get_parser(buf, 'ipynb')
if not parser then
  print('Failed to get parser for buffer')
  vim.cmd('qa!')
end

local tree = parser:parse()[1]
local root = tree:root()

print('Tree root type: ' .. root:type())
print('Tree root child count: ' .. root:child_count())

-- Print the tree structure
local function print_tree(node, indent)
  indent = indent or 0
  local prefix = string.rep('  ', indent)
  print(prefix .. node:type() .. ' [' .. node:start() .. '-' .. node:end_() .. ']')
  for child in node:iter_children() do
    print_tree(child, indent + 1)
  end
end

print('\nParse tree:')
print_tree(root)

-- Check injection queries
print('\n\nChecking injection queries...')
local query_path = plugin_path .. '/tree-sitter-ipynb/queries/ipynb/injections.scm'
local query_content = vim.fn.readfile(query_path)
print('Injection query:')
for _, line in ipairs(query_content) do
  print('  ' .. line)
end

vim.cmd('qa!')