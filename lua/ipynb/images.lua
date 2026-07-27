-- ipynb/images.lua - Image output rendering using image.nvim
-- Uses image.nvim for dimension reading and image object lifecycle,
-- with direct Kitty Graphics Protocol commands for terminal transmission.
-- Uses vendored placeholder generation for true text/image interleaving in virt_lines.

local M = {}

--------------------------------------------------------------------------------
-- Type definitions for image.nvim (for LuaLS)
--------------------------------------------------------------------------------

---@class ImageNvim
---@field id string Image string ID
---@field internal_id number Image ID for terminal protocol (Kitty image ID)
---@field image_width number Pixel width
---@field image_height number Pixel height
---@field path string File path
---@field source_format string|nil Original image format (png, jpeg, etc.)
---@field clear fun(self: ImageNvim, shallow?: boolean)

--------------------------------------------------------------------------------

-- Namespace for our image extmarks (separate from image.nvim)
local ns = vim.api.nvim_create_namespace("ipynb_images")
M.ns = ns

--------------------------------------------------------------------------------
-- Vendored Kitty Graphics Protocol placeholder generation
-- This allows us to generate image placeholder text for use in our own virt_lines
--------------------------------------------------------------------------------

-- Unicode placeholder character used by Kitty Graphics Protocol
local PLACEHOLDER = vim.fn.nr2char(0x10EEEE)

-- Diacritics used to encode row/column positions in placeholder cells
-- stylua: ignore
local diacritics = vim.split("0305,030D,030E,0310,0312,033D,033E,033F,0346,034A,034B,034C,0350,0351,0352,0357,035B,0363,0364,0365,0366,0367,0368,0369,036A,036B,036C,036D,036E,036F,0483,0484,0485,0486,0487,0592,0593,0594,0595,0597,0598,0599,059C,059D,059E,059F,05A0,05A1,05A8,05A9,05AB,05AC,05AF,05C4,0610,0611,0612,0613,0614,0615,0616,0617,0657,0658,0659,065A,065B,065D,065E,06D6,06D7,06D8,06D9,06DA,06DB,06DC,06DF,06E0,06E1,06E2,06E4,06E7,06E8,06EB,06EC,0730,0732,0733,0735,0736,073A,073D,073F,0740,0741,0743,0745,0747,0749,074A,07EB,07EC,07ED,07EE,07EF,07F0,07F1,07F3,0816,0817,0818,0819,081B,081C,081D,081E,081F,0820,0821,0822,0823,0825,0826,0827,0829,082A,082B,082C,082D,0951,0953,0954,0F82,0F83,0F86,0F87,135D,135E,135F,17DD,193A,1A17,1A75,1A76,1A77,1A78,1A79,1A7A,1A7B,1A7C,1B6B,1B6D,1B6E,1B6F,1B70,1B71,1B72,1B73,1CD0,1CD1,1CD2,1CDA,1CDB,1CE0,1DC0,1DC1,1DC3,1DC4,1DC5,1DC6,1DC7,1DC8,1DC9,1DCB,1DCC,1DD1,1DD2,1DD3,1DD4,1DD5,1DD6,1DD7,1DD8,1DD9,1DDA,1DDB,1DDC,1DDD,1DDE,1DDF,1DE0,1DE1,1DE2,1DE3,1DE4,1DE5,1DE6,1DFE,20D0,20D1,20D4,20D5,20D6,20D7,20DB,20DC,20E1,20E7,20E9,20F0,2CEF,2CF0,2CF1,2DE0,2DE1,2DE2,2DE3,2DE4,2DE5,2DE6,2DE7,2DE8,2DE9,2DEA,2DEB,2DEC,2DED,2DEE,2DEF,2DF0,2DF1,2DF2,2DF3,2DF4,2DF5,2DF6,2DF7,2DF8,2DF9,2DFA,2DFB,2DFC,2DFD,2DFF,A66F,A67C,A67D,A6F0,A6F1,A8E0,A8E1,A8E2,A8E3,A8E4,A8E5,A8E6,A8E7,A8E8,A8E9,A8EA,A8EB,A8EC,A8ED,A8EE,A8EF,A8F0,A8F1,AAB0,AAB2,AAB3,AAB7,AAB8,AABE,AABF,AAC1,FE20,FE21,FE22,FE23,FE24,FE25,FE26,10A0F,10A38,1D185,1D186,1D187,1D188,1D189,1D1AA,1D1AB,1D1AC,1D1AD,1D242,1D243,1D244", ",")

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
---@param img_id number The Kitty image ID
---@param placement_id number The placement ID
---@param width number Width in terminal cells
---@param height number Height in terminal cells
---@return string[] lines Array of placeholder strings (one per row)
---@return string hl_group The highlight group name to use
local function generate_placeholder_grid(img_id, placement_id, width, height)
	-- Create highlight group with image/placement IDs encoded in colors
	local hl_group = "IpynbImage" .. placement_id
	vim.api.nvim_set_hl(0, hl_group, {
		fg = img_id,
		sp = placement_id,
		bg = "none",
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
	["image/png"] = "png",
	["image/jpeg"] = "jpg",
	["image/gif"] = "gif",
	["image/webp"] = "webp",
	["image/bmp"] = "bmp",
	["image/tiff"] = "tiff",
	["image/heic"] = "heic",
	["image/avif"] = "avif",
	["image/svg+xml"] = "svg",
	["application/pdf"] = "pdf",
}

-- MIME types that are stored as text (not base64) in Jupyter outputs
local TEXT_MIME_TYPES = {
	["image/svg+xml"] = true,
}

-- Cache for image.nvim availability check
local image_available = nil

---Convert pixel dimensions to terminal cells
---@param width_px number|nil Width in pixels
---@param height_px number|nil Height in pixels
---@return number|nil width Width in terminal cells
---@return number|nil height Height in terminal cells
local function pixels_to_cells(width_px, height_px)
	if not width_px and not height_px then
		return nil, nil
	end

	-- Get actual terminal cell dimensions from image.nvim if available
	local cell_width, cell_height = 8, 16
	local ok, term = pcall(require, "image.utils.term")
	if ok and term and term.get_size then
		local term_size = term.get_size()
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
	local config = require("ipynb.config").get()
	local dir = config.images and config.images.cache_dir or (vim.fn.stdpath("cache") .. "/ipynb.nvim")
	vim.fn.mkdir(dir, "p")
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
	local fd = uv.fs_open(path, "w", 438) -- 0666 permissions
	if not fd then
		return false
	end

	local ok_write = uv.fs_write(fd, data, 0)
	uv.fs_close(fd)
	return ok_write ~= nil
end

--------------------------------------------------------------------------------
-- Kitty Graphics Protocol helpers
--------------------------------------------------------------------------------

---Send a raw Kitty protocol escape sequence to the terminal (with tmux wrapping)
---@param payload string Kitty graphics protocol payload (without outer escape wrapper)
local function send_kitty_command(payload)
	if vim.env.TMUX or vim.env.TMUX_PANE then
		payload = "\x1bPtmux;\x1b" .. payload:gsub("\x1b", "\x1b\x1b") .. "\x1b\\"
	end
	io.stdout:write(payload)
	io.stdout:flush()
end

---Transmit image file data to the terminal via Kitty direct (base64) method.
---Reads the file, base64-encodes it, and sends in chunks.
---@param img_id number Kitty image ID
---@param file_path string Absolute path to image file on disk
local function send_transmit_request(img_id, file_path)
	local f = io.open(file_path, "rb")
	if not f then
		return
	end
	local data = f:read("*a")
	f:close()
	if not data or #data == 0 then
		return
	end

	local b64 = vim.base64.encode(data)
	local chunk_size = 4096
	local total_chunks = math.ceil(#b64 / chunk_size)

	for i = 1, total_chunks do
		local start = (i - 1) * chunk_size + 1
		local finish = math.min(i * chunk_size, #b64)
		local chunk = b64:sub(start, finish)
		local m = i < total_chunks and 1 or 0
		local payload = string.format("\x1b_Ga=t,f=100,i=%d,t=d,m=%d,q=2;%s\x1b\\", img_id, m, chunk)
		send_kitty_command(payload)
	end
end

---Send Kitty placement command (display with Unicode placeholders)
---@param img_id number Kitty image ID
---@param placement_id number Placement ID
---@param width number Width in terminal cells
---@param height number Height in terminal cells
local function send_placement_request(img_id, placement_id, width, height)
	local payload = string.format(
		"\x1b_Ga=p,U=1,i=%d,p=%d,C=1,c=%d,r=%d,q=2\x1b\\",
		img_id,
		placement_id,
		width,
		height
	)
	send_kitty_command(payload)
end

---Send Kitty delete placement command
---@param img_id number Kitty image ID
---@param placement_id number Placement ID
local function send_clear_placement_request(img_id, placement_id)
	local payload = string.format("\x1b_Ga=d,d=i,i=%d,p=%d\x1b\\", img_id, placement_id)
	send_kitty_command(payload)
end

---Convert a non-PNG image file to PNG using ImageMagick (required by Kitty protocol)
---@param path string Input file path
---@return string|nil png_path Path to PNG file (same as input if already PNG, converted path otherwise)
local function ensure_png(path)
	-- Check if already PNG by reading magic bytes
	local f = io.open(path, "rb")
	if not f then
		return nil
	end
	local header = f:read(8)
	f:close()
	if header and #header >= 4 and header:byte(1) == 0x89 and header:byte(2) == 0x50 and header:byte(3) == 0x4E
		and header:byte(4) == 0x47
	then
		return path -- Already PNG
	end

	-- Convert to PNG via ImageMagick
	local output_path = path .. ".png"
	-- Try 'magick' (ImageMagick 7+) first, then 'convert' (ImageMagick 6)
	for _, cmd_name in ipairs({ "magick", "convert" }) do
		local cmd = string.format("%s '%s' '%s' 2>/dev/null", cmd_name, path, output_path)
		os.execute(cmd)
		-- Verify the output file was created
		local check = io.open(output_path, "rb")
		if check then
			check:close()
			return output_path
		end
	end
	return nil
end

--------------------------------------------------------------------------------
-- image.nvim Image object cache
--------------------------------------------------------------------------------

-- Storage for image.nvim Image objects (used for dimension reading and lifecycle)
local image_cache = {} ---@type table<string, ImageNvim>

---Get or create an image.nvim Image object for a file path.
---The Image provides pixel dimensions and a unique internal_id for Kitty protocol.
---@param path string Path to image file
---@return ImageNvim|nil
local function get_or_create_image(path)
	if image_cache[path] then
		return image_cache[path]
	end

	local ok, image_api = pcall(require, "image")
	if not ok or type(image_api.from_file) ~= "function" then
		return nil
	end

	-- from_file reads dimensions via processor; requires setup() to have been called.
	-- Pass id=path for deduplication so the same file reuses the existing Image.
	local ok_from, img = pcall(image_api.from_file, path, { id = path })
	if ok_from and img then
		image_cache[path] = img
		return img
	end
	return nil
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

---Check if image.nvim module is available and functional
---@return boolean
function M.is_available()
	local config = require("ipynb.config").get()
	if config.images and config.images.enabled == false then
		return false
	end

	if image_available == true then
		return true
	end

	local ok, image_api = pcall(require, "image")
	if not ok or not image_api then
		return false
	end

	-- Verify image.nvim is actually set up by probing from_file.
	-- from_file throws if setup() hasn't been called.
	local probe_ok = pcall(image_api.from_file, "/dev/null")
	if not probe_ok then
		-- setup() hasn't been called; try to initialize with defaults.
		-- Safe because the user's own setup() (if any) will re-initialize later.
		pcall(image_api.setup, {})
	end

	image_available = true
	return true
end

---Check if terminal supports Unicode placeholders (required for virt_lines images)
---@return boolean
function M.supports_placeholders()
	return M.is_available()
end

---Check if output has any image data
---@param output table Output object
---@return boolean has_image
---@return string|nil mime_type
---@return string|nil image_data (base64 or raw text depending on mime type)
---@return boolean is_text Whether the data is raw text (not base64 encoded)
function M.get_image_data(output)
	if output.output_type ~= "execute_result" and output.output_type ~= "display_data" then
		return false, nil, nil, false
	end

	local data = output.data
	if not data then
		return false, nil, nil, false
	end

	for mime, _ in pairs(MIME_EXTENSIONS) do
		if data[mime] then
			local image_data = data[mime]
			if type(image_data) == "table" then
				image_data = table.concat(image_data, "")
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
	local ext = MIME_EXTENSIONS[mime] or "png"
	local data_hash = vim.fn.sha256(image_data):sub(1, 12)
	local filename = string.format("%s-%d-%s.%s", cell_id, image_index, data_hash, ext)
	local path = cache_dir .. "/" .. filename

	if not write_binary_file(path, file_content) then
		return nil, 0
	end

	-- File content may have changed between executions for the same cell/image index.
	-- Drop cached object so we reload fresh metadata from disk.
	if image_cache[path] then
		pcall(image_cache[path].clear, image_cache[path])
		image_cache[path] = nil
	end

	-- Get or create image.nvim Image object (for dimensions and Kitty image ID)
	local img = get_or_create_image(path)
	if not img then
		return nil, 0
	end

	-- Get dimensions from image.nvim Image
	local native_width_px = img.image_width
	local native_height_px = img.image_height
	if not native_width_px or not native_height_px or native_width_px <= 0 or native_height_px <= 0 then
		return nil, 0
	end

	local native_width_cells, native_height_cells = pixels_to_cells(native_width_px, native_height_px)

	-- Get config for size limits
	local config = require("ipynb.config").get()
	local img_config = config.images or {}

	-- Padding constants for image sizing
	local width_padding = 2 -- horizontal margin to avoid overflow
	local height_padding = 1 -- vertical margin to guarantee cursor landing with image fully visible

	-- Find facade window to get stable dimensions (avoids resize when undo triggered from edit float)
	local facade_win = nil
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_get_buf(win) == state.facade_buf then
			facade_win = win
			break
		end
	end

	local text_width, max_img_height
	if facade_win then
		local wininfo = vim.fn.getwininfo(facade_win)[1]
		text_width = vim.api.nvim_win_get_width(facade_win) - (wininfo and wininfo.textoff or 0) - width_padding
		max_img_height = img_config.max_height
			or (vim.api.nvim_win_get_height(facade_win) - vim.wo[facade_win].scrolloff - height_padding)
	else
		-- Fallback to terminal size if facade window not found
		text_width = vim.o.columns - width_padding
		max_img_height = img_config.max_height or (vim.o.lines - height_padding)
	end

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

	-- Ensure image is PNG for Kitty protocol (only f=100/PNG is standard)
	local transmit_path = ensure_png(path)
	if not transmit_path then
		return nil, 0
	end

	-- Transmit image data to terminal via Kitty file reference.
	-- NOTE: We do NOT call img:render() because that triggers image.nvim's own
	-- display pipeline which sends a conflicting placement command.
	local internal_id = img.internal_id or 1
	send_transmit_request(internal_id, transmit_path)

	-- Generate unique placement ID and send placement command
	local placement_id = next_placement_id()
	send_placement_request(internal_id, placement_id, img_width, img_height)

	-- Generate placeholder grid lines (encodes image_id + placement_id in highlight)
	local placeholder_lines, hl_group = generate_placeholder_grid(internal_id, placement_id, img_width, img_height)

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
		png_path = transmit_path ~= path and transmit_path or nil,
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

	for _, entry in ipairs(state.images[cell_id]) do
		-- Clear image.nvim Image from terminal and registry
		if entry.img then
			pcall(entry.img.clear, entry.img)
		end
		-- Remove from our local cache
		if entry.path and image_cache[entry.path] then
			image_cache[entry.path] = nil
		end
		-- Delete converted PNG if we created one
		if entry.png_path then
			pcall(vim.fn.delete, entry.png_path)
		end
		-- Delete the original cache file
		if entry.path then
			pcall(vim.fn.delete, entry.path)
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
