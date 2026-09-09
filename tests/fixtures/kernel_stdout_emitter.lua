-- A real subprocess standing in for the Python bridge. No Jupyter dependency.
local function stream(cell_id, text)
  return vim.json.encode({
    type = 'output',
    cell_id = cell_id,
    output = { output_type = 'stream', name = 'stdout', text = text },
  })
end

local large = vim.json.encode({
  type = 'output',
  cell_id = 'image',
  output = {
    output_type = 'display_data',
    -- Synthetic base64 payload: this test checks transport, not PNG decoding.
    data = { ['image/png'] = string.rep('QUJD', 175000) },
    metadata = vim.empty_dict(),
  },
})

-- Write complete messages normally. The OS pipe and Neovim choose read sizes;
-- there are no explicit fragments, delays, or handshakes with the parent.
io.write(stream('before', 'before\n') .. '\n')
io.write(large .. '\n')
io.write(stream('after', 'after\n') .. '\n')
io.flush()
