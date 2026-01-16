-- ipynb/images.lua - Image output rendering using snacks.nvim
-- Uses vendored placeholder generation for true text/image interleaving in virt_lines

local M = {}

--------------------------------------------------------------------------------
-- Type definitions for snacks.nvim (for LuaLS)
--------------------------------------------------------------------------------

---@class snacks.Image.Size
---@field width number
---@field height number

---@class snacks.Image.Info
---@field size snacks.Image.Size

---@class snacks.Image
---@field id number Image ID for terminal protocol
---@field info snacks.Image.Info|nil Image metadata (available after ready)
---@field ready fun(self: snacks.Image): boolean Check if image is ready
---@field failed fun(self: snacks.Image): boolean Check if image failed to load

--------------------------------------------------------------------------------

-- Namespace for our image extmarks (separate from snacks)
local ns = vim.api.nvim_create_namespace('ipynb_images')
M.ns = ns

--------------------------------------------------------------------------------
-- Vendored from snacks.nvim for placeholder generation
-- This allows us to generate image placeholder text for use in our own virt_lines
--------------------------------------------------------------------------------

-- Unicode placeholder character used by Kitty Graphics Protocol
local PLACEHOLDER = vim.fn.nr2char(0x10EEEE)

-- Diacritics used to encode row/column positions in placeholder cells
-- stylua: ignore
local diacritics = vim.split("0305,030D,030E,0310,0312,033D,033E,033F,0346,034A,034B,034C,0350,0351,0352,0357,035B,0363,0364,0365,0366,0367,0368,0369,036A,036B,036C,036D,036E,036F,0483,0484,0485,0486,0487,0592,0593,0594,0595,0597,0598,0599,059C,059D,059E,059F,05A0,05A1,05A8,05A9,05AB,05AC,05AF,05C4,0610,0611,0612,0613,0614,0615,0616,0617,0657,0658,0659,065A,065B,065D,065E,06D6,06D7,06D8,06D9,06DA,06DB,06DC,06DF,06E0,06E1,06E2,06E4,06E7,06E8,06EB,06EC,0730,0732,0733,0735,0736,073A,073D,073F,0740,0741,0743,0745,0747,0749,074A,07EB,07EC,07ED,07EE,07EF,07F0,07F1,07F3,0816,0817,0818,0819,081B,081C,081D,081E,081F,0820,0821,0822,0823,0825,0826,0827,0829,082A,082B,082C,082D,0951,0953,0954,0F82,0F83,0F86,0F87,135D,135E,135F,17DD,193A,1A17,1A75,1A76,1A77,1A78,1A79,1A7A,1A7B,1A7C,1B6B,1B6D,1B6E,1B6F,1B70,1B71,1B72,1B73,1CD0,1CD1,1CD2,1CDA,1CDB,1CE0,1DC0,1DC1,1DC3,1DC4,1DC5,1DC6,1DC7,1DC8,1DC9,1DCB,1DCC,1DD1,1DD2,1DD3,1DD4,1DD5,1DD6,1DD7,1DD8,1DD9,1DDA,1DDB,1DDC,1DDD,1DDE,1DDF,1DE0,1DE1,1DE2,1DE3,1DE4,1DE5,1DE6,1DFE,20D0,20D1,20D4,20D5,20D6,20D7,20DB,20DC,20E1,20E7,20E9,20F0,2CEF,2CF0,2CF1,2DE0,2DE1,2DE2,2DE3,2DE4,2DE5,2DE6,2DE7,2DE8,2DE9,2DEA,2DEB,2DEC,2DED,2DEE,2DEF,2DF0,2DF1,2DF2,2DF3,2DF4,2DF5,2DF6,2DF7,2DF8,2DF9,2DFA,2DFB,2DFC,2DFD,2DFE,2DFF,A66F,A67C,A67D,A6F0,A6F1,A8E0,A8E1,A8E2,A8E3,A8E4,A8E5,A8E6,A8E7,A8E8,A8E9,A8EA,A8EB,A8EC,A8ED,A8EE,A8EF,A8F0,A8F1,AAB0,AAB2,AAB3,AAB7,AAB8,AABE,AABF,AAC1,FE20,FE21,FE22,FE23,FE24,FE25,FE26,10A0F,10A38,1D185,1D186,1D187,1D188,1D189,1D1AA,1D1AB,1D1AC,1D1AD,1D242,1D243,1D244", ",")

-- Lazy-load diacritic characters
---@type table<number, string>
local positions = {}
setmetatable(positions, {
  __index = function(_, k)
    positions[k] = vim.fn.nr2char(tonumber(diacritics[k], 16))
    return positions[k]
  end,
})

-- Counter for generating unique placement IDs
local placement_id_counter = 100

---Generate a unique placement ID
---@return number
local function next_placement_id()
  placement_id_counter = placement_id_counter + 1
  return placement_id_counter
end

---Generate placeholder grid lines for an image
---@param img_id number The snacks Image ID
---@param placement_id number The placement ID
---@param width number Width in terminal cells
---@param height number Height in terminal cells
---@return string[] lines Array of placeholder strings (one per row)
---@return string hl_group The highlight group name to use
local function generate_placeholder_grid(img_id, placement_id, width, height)
  -- Create highlight group with image/placement IDs encoded in colors
  local hl_group = 'IpynbImage' .. placement_id
  vim.api.nvim_set_hl(0, hl_group, {
    fg = img_id,
    sp = placement_id,
    bg = 'none',
    nocombine = true,
  })

  local lines = {}
  local max_pos = #diacritics
  height = math.min(height, max_pos)
  width = math.min(width, max_pos)

  for r = 1, height do
    local line = {}
    for c = 1, width do
      -- Each cell: placeholder char + row diacritic + column diacritic
      line[#line + 1] = PLACEHOLDER
      line[#line + 1] = positions[r]
      line[#line + 1] = positions[c]
    end
    lines[#lines + 1] = table.concat(line)
  end

  return lines, hl_group
end

--------------------------------------------------------------------------------
-- End vendored code
--------------------------------------------------------------------------------

-- Supported image MIME types (mapped to file extensions)
local MIME_EXTENSIONS = {
  ['image/png'] = 'png',
  ['image/jpeg'] = 'jpg',
  ['image/gif'] = 'gif',
  ['image/webp'] = 'webp',
  ['image/bmp'] = 'bmp',
  ['image/tiff'] = 'tiff',
  ['image/heic'] = 'heic',
  ['image/avif'] = 'avif',
  ['image/svg+xml'] = 'svg',
  ['application/pdf'] = 'pdf',
}

-- MIME types that are stored as text (not base64) in Jupyter outputs
local TEXT_MIME_TYPES = {
  ['image/svg+xml'] = true,
}

-- Cache for snacks.nvim availability check
local snacks_available = nil

---Convert pixel dimensions to terminal cells
---@param width_px number|nil Width in pixels
---@param height_px number|nil Height in pixels
---@return number|nil width Width in terminal cells
---@return number|nil height Height in terminal cells
local function pixels_to_cells(width_px, height_px)
  if not width_px and not height_px then
    return nil, nil
  end

  -- Get actual terminal cell dimensions from snacks
  local cell_width, cell_height = 8, 16
  local ok, Snacks = pcall(require, 'snacks')
  if ok and Snacks.image and Snacks.image.terminal then
    local term_size = Snacks.image.terminal.size()
    if term_size then
      cell_width = term_size.cell_width or cell_width
      cell_height = term_size.cell_height or cell_height
    end
  end

  local width_cells, height_cells
  if width_px then
    width_cells = math.ceil(width_px / cell_width)
  end
  if height_px then
    height_cells = math.ceil(height_px / cell_height)
  end

  return width_cells, height_cells
end

--------------------------------------------------------------------------------
-- File I/O helpers
--------------------------------------------------------------------------------

---Get the cache directory for images
---@return string
local function get_cache_dir()
  local config = require('ipynb.config').get()
  local dir = config.images and config.images.cache_dir
    or (vim.fn.stdpath('cache') .. '/ipynb.nvim')
  vim.fn.mkdir(dir, 'p')
  return dir
end

---Decode base64 data
---@param data string Base64 encoded data
---@return string|nil decoded Binary data or nil on failure
local function base64_decode(data)
  if vim.base64 and vim.base64.decode then
    local ok, decoded = pcall(vim.base64.decode, data)
    if ok then
      return decoded
    end
  end
  return nil
end

---Write binary data to file using libuv
---@param path string File path
---@param data string Binary data
---@return boolean success
local function write_binary_file(path, data)
  local uv = vim.uv or vim.loop
  local fd = uv.fs_open(path, 'w', 438) -- 0666 permissions
  if not fd then
    return false
  end

  local ok_write = uv.fs_write(fd, data, 0)
  uv.fs_close(fd)
  return ok_write ~= nil
end

-- Storage for snacks Image objects (keep them alive for the terminal protocol)
local image_cache = {} ---@type table<string, snacks.Image>

---Get or create a snacks Image object for a file path
---@param path string Path to image file
---@return snacks.Image|nil
local function get_or_create_image(path)
  if image_cache[path] then
    return image_cache[path]
  end

  local ok, Snacks = pcall(require, 'snacks')
  if not ok then
    return nil
  end

  local img = Snacks.image.image.new(path)
  if img then
    image_cache[path] = img
  end
  return img
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

---Check if snacks.nvim image module is available
---@return boolean
function M.is_available()
  local config = require('ipynb.config').get()
  if config.images and config.images.enabled == false then
    return false
  end

  if snacks_available == true then
    return true
  end

  local ok, Snacks = pcall(require, 'snacks')
  if not ok then
    return false
  end

  if not Snacks.image or not Snacks.image.placement then
    return false
  end

  if Snacks.image.supports_terminal and not Snacks.image.supports_terminal() then
    return false
  end

  snacks_available = true
  return true
end

---Check if terminal supports Unicode placeholders (required for virt_lines images)
---@return boolean
function M.supports_placeholders()
  if not M.is_available() then
    return false
  end
  local Snacks = require('snacks')
  local env = Snacks.image.terminal.env()
  return env.placeholders == true
end

---Check if output has any image data
---@param output table Output object
---@return boolean has_image
---@return string|nil mime_type
---@return string|nil image_data (base64 or raw text depending on mime type)
---@return boolean is_text Whether the data is raw text (not base64 encoded)
function M.get_image_data(output)
  if output.output_type ~= 'execute_result' and output.output_type ~= 'display_data' then
    return false, nil, nil, false
  end

  local data = output.data
  if not data then
    return false, nil, nil, false
  end

  for mime, _ in pairs(MIME_EXTENSIONS) do
    if data[mime] then
      local image_data = data[mime]
      if type(image_data) == 'table' then
        image_data = table.concat(image_data, '')
      end
      local is_text = TEXT_MIME_TYPES[mime] or false
      return true, mime, image_data, is_text
    end
  end

  return false, nil, nil, false
end

---Generate virt_lines entries for an image output
---@param state NotebookState
---@param cell table Cell object
---@param output table Output object containing image data
---@param image_index number Index of this image (1-based, for cache filename)
---@return table[]|nil virt_line_entries Array of virt_line entries, or nil if failed
---@return number height Height of the image in terminal rows
function M.get_image_virt_lines(state, cell, output, image_index)
  if not M.supports_placeholders() then
    return nil, 0
  end

  local has_image, mime, image_data, is_text = M.get_image_data(output)
  if not has_image or not mime or not image_data then
    return nil, 0
  end

  local Snacks = require('snacks')
  local cell_id = cell.id
  if not cell_id then
    return nil, 0
  end

  -- Decode/get file content
  local file_content
  if is_text then
    file_content = image_data
  else
    file_content = base64_decode(image_data)
  end

  if not file_content then
    return nil, 0
  end

  -- Write to cache file
  local cache_dir = get_cache_dir()
  local ext = MIME_EXTENSIONS[mime] or 'png'
  local filename = string.format('%s-%d.%s', cell_id, image_index, ext)
  local path = cache_dir .. '/' .. filename

  if not write_binary_file(path, file_content) then
    return nil, 0
  end

  -- Get or create snacks Image (handles sending image data to terminal)
  local img = get_or_create_image(path)
  if not img then
    return nil, 0
  end

  -- Wait for image to be ready (it may need conversion)
  local ready = vim.wait(500, function()
    return img:ready() or img:failed()
  end, 10)

  if not ready or img:failed() then
    return nil, 0
  end

  -- Get dimensions from snacks' converted image
  local native_width_px, native_height_px
  if img.info and img.info.size then
    native_width_px = img.info.size.width
    native_height_px = img.info.size.height
  end
  if not native_width_px or not native_height_px then
    return nil, 0
  end
  local native_width_cells, native_height_cells = pixels_to_cells(native_width_px, native_height_px)

  -- Get config for size limits
  local config = require('ipynb.config').get()
  local img_config = config.images or {}
  local wininfo = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1]
  local text_width = vim.api.nvim_win_get_width(0) - (wininfo and wininfo.textoff or 0) - 2
  local max_img_height = img_config.max_height or (vim.api.nvim_win_get_height(0) - vim.wo.scrolloff - 1)

  -- Calculate scaled dimensions
  local img_width = native_width_cells or text_width
  local img_height = native_height_cells or max_img_height

  if native_width_cells and native_height_cells and native_width_cells > text_width then
    local scale = text_width / native_width_cells
    img_width = text_width
    img_height = math.floor(native_height_cells * scale + 0.5)
  end

  if img_height > max_img_height then
    local scale = max_img_height / img_height
    img_height = max_img_height
    img_width = math.floor(img_width * scale + 0.5)
  end

  img_width = math.max(1, img_width)
  img_height = math.max(1, img_height)

  -- Generate unique placement ID
  local placement_id = next_placement_id()

  -- Send placement command to terminal
  Snacks.image.terminal.request({
    a = 'p',
    U = 1,
    i = img.id,
    p = placement_id,
    C = 1,
    c = img_width,
    r = img_height,
  })

  -- Generate placeholder grid lines
  local placeholder_lines, hl_group = generate_placeholder_grid(img.id, placement_id, img_width, img_height)

  -- Convert to virt_lines format
  local virt_line_entries = {}
  for _, line in ipairs(placeholder_lines) do
    table.insert(virt_line_entries, { { line, hl_group } })
  end

  -- Track for cleanup
  state.images = state.images or {}
  state.images[cell_id] = state.images[cell_id] or {}
  table.insert(state.images[cell_id], {
    img = img,
    placement_id = placement_id,
    path = path,
  })

  return virt_line_entries, img_height
end

---Clear images for a cell
---@param state NotebookState
---@param cell_id string Unique cell ID
function M.clear_images(state, cell_id)
  if not state.images or not state.images[cell_id] then
    return
  end

  local ok, Snacks = pcall(require, 'snacks')
  if ok and Snacks.image and Snacks.image.terminal then
    for _, entry in ipairs(state.images[cell_id]) do
      if entry.img and entry.placement_id then
        pcall(Snacks.image.terminal.request, {
          a = 'd',
          d = 'i',
          i = entry.img.id,
          p = entry.placement_id,
        })
      end
    end
  end

  state.images[cell_id] = nil
end

---Clear all images
---@param state NotebookState
function M.clear_all_images(state)
  if not state.images then
    return
  end

  for cell_id, _ in pairs(state.images) do
    M.clear_images(state, cell_id)
  end

  state.images = {}
end

---Sync image positions (no-op, placeholders move with extmarks automatically)
---@param state NotebookState
function M.sync_positions(state)
  _ = state
end

return M
