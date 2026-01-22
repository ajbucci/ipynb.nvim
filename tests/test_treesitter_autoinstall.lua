-- Test auto-compilation of ipynb treesitter parser
-- Runs a nested Neovim instance with an isolated appname and cleans up after.

local script_path = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h')
local plugin_dir = vim.fn.fnamemodify(script_path, ':h') -- Go up one level from tests/

local check_script = table.concat({
  "local ok = pcall(require, 'nvim-treesitter')",
  "if not ok then print('SKIP: nvim-treesitter not installed'); vim.cmd('qa!'); return end",
  "local function parser_ready()",
  "  local ok_parser = pcall(vim.treesitter.language.inspect, 'ipynb')",
  "  return ok_parser",
  "end",
  "local ok_parser = vim.wait(8000, parser_ready, 200)",
  "print('IPYNB_AUTOINSTALL_OK=' .. tostring(ok_parser))",
  "if not ok_parser then vim.cmd('cquit') end",
  "vim.cmd('qa!')",
}, '\n')

local tmp_dir = vim.fn.tempname() .. '_ipynb_ts'
vim.fn.mkdir(tmp_dir, 'p')
local check_path = tmp_dir .. '/check_autoinstall.lua'
vim.fn.writefile(vim.split(check_script, '\n'), check_path)

local cmd = {
  'nvim',
  '--headless',
  '-u',
  plugin_dir .. '/tests/minimal_init.lua',
  '-l',
  check_path,
}

local result = vim.system(cmd, {
  env = {
    IPYNB_TEST_SKIP_PARSER_SO = '1',
  },
  text = true,
}):wait()

local output = {}
if result.stdout and result.stdout ~= '' then
  for _, line in ipairs(vim.split(result.stdout, '\n', { trimempty = true })) do
    table.insert(output, line)
  end
end
if result.stderr and result.stderr ~= '' then
  for _, line in ipairs(vim.split(result.stderr, '\n', { trimempty = true })) do
    table.insert(output, line)
  end
end

pcall(vim.fn.delete, tmp_dir, 'rf')

for _, line in ipairs(output) do
  if line:find('SKIP:') then
    print(line)
    vim.cmd('qa!')
  end
end

local ok_line = nil
for _, line in ipairs(output) do
  if line:match('^IPYNB_AUTOINSTALL_OK=') then
    ok_line = line
    break
  end
end

if ok_line ~= 'IPYNB_AUTOINSTALL_OK=true' then
  print('Auto-install failed or did not run. Output:')
  for _, line in ipairs(output) do
    print(line)
  end
  vim.cmd('cquit')
end

print('Auto-install succeeded.')
vim.cmd('qa!')
