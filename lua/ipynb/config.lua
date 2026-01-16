-- ipynb/config.lua - Configuration (see :help ipynb-config)

local M = {}

---@class NotebookConfig
---@field float FloatConfig
---@field keymaps KeymapConfig
---@field highlights HighlightConfig
---@field border_hints BorderHintsConfig
---@field kernel KernelConfig
---@field images ImageConfig
---@field inspector InspectorConfig
---@field folding FoldingConfig
---@field format FormatConfig

---@class FloatConfig
---@field width number Window width as fraction of screen (0-1) - used for centered mode
---@field height number Window height as fraction of screen (0-1) - used for centered mode
---@field border string Border style - used for centered mode
---@field overlay boolean If true, float overlays cell inline; if false, centered popup
---@field show_line_numbers boolean Show line numbers in overlay mode

---@class KeymapConfig
--- Direct facade keys (high-frequency operations)
---@field next_cell string Jump to next cell (default: ']]')
---@field prev_cell string Jump to previous cell (default: '[[')
---@field cut_cell string Cut cell to register (default: 'dd')
---@field paste_cell_below string Paste cell below (default: 'p')
---@field paste_cell_above string Paste cell above (default: 'P')
---@field move_cell_down string Move cell down (default: '<M-j>')
---@field move_cell_up string Move cell up (default: '<M-k>')
---@field execute_cell string Execute cell, stay (default: '<C-CR>')
---@field execute_and_next string Execute cell, move next (default: '<S-CR>')
---@field execute_and_insert string Execute cell, insert below (default: '<M-CR>')
---@field interrupt_kernel string Interrupt kernel (default: '<C-c>')
--- <leader>k menu (notebook operations)
---@field jump_to_cell string Open cell picker (default: '<leader>kj')
---@field add_cell_above string Add cell above (default: '<leader>ka')
---@field add_cell_below string Add cell below (default: '<leader>kb')
---@field make_markdown string Make cell markdown (default: '<leader>km')
---@field make_code string Make cell code (default: '<leader>ky')
---@field make_raw string Make cell raw (default: '<leader>kr')
---@field open_output string Open output in float (default: '<leader>ko')
---@field clear_output string Clear cell output (default: '<leader>kc')
---@field clear_all_outputs string Clear all outputs (default: '<leader>kC')
---@field fold_toggle string Toggle cell fold (default: '<leader>kf')
---@field menu_execute_cell string Execute cell (menu) (default: '<leader>kx')
---@field menu_execute_and_next string Execute cell, move next (menu) (default: '<leader>kX')
---@field execute_all_below string|nil Execute all cells from current to end (default: nil, unmapped)
---@field kernel_interrupt string Interrupt kernel (menu) (default: '<leader>ki')
---@field kernel_restart string Restart kernel (default: '<leader>k0')
---@field kernel_start string Start kernel (default: '<leader>ks')
---@field kernel_shutdown string Shutdown kernel (default: '<leader>kS')
---@field kernel_info string Show kernel info (default: '<leader>kn')
--- Inspector
---@field variable_inspect string Inspect variable at cursor (default: '<leader>kh')
---@field cell_variables string Inspect all cell variables (default: '<leader>kv')
---@field toggle_auto_hover string Toggle inspect auto-hover (default: '<leader>kH')

---@class FoldingConfig
---@field hide_output boolean Include end marker in fold to hide output (default: false)

---@class FormatConfig
---@field enabled boolean Wrap vim.lsp.buf.format() to work with notebooks (default: true)
---@field trailing_blank_lines number Max trailing blank lines to keep after formatting (default: 0)

---@class HighlightConfig Highlight groups to link to (use existing groups or define your own)
---@field border string Cell border color (default: 'Comment')
---@field border_hover string Hover cell border - cursor on cell (default: 'Special')
---@field border_active string Active cell border - editing in float (default: 'Number')
---@field exec_count string Execution count [N] (default: 'Number')
---@field output string Output text (default: 'Comment')
---@field output_error string Error output (default: 'DiagnosticError')
---@field executing string Executing indicator (default: 'DiagnosticWarn')
---@field queued string Queued indicator (default: 'DiagnosticHint')
---@field hint string Action hints on active cell border (default: 'Comment')

---@class BorderHintsConfig
---@field enabled boolean Show action hints on active cell border (default: true)
---@field show_on_hover boolean Show hints when cursor is on cell (default: true)
---@field show_on_edit boolean Show hints when editing in float (default: false)

---@class KernelConfig
---@field auto_connect boolean Auto-connect to kernel on notebook open
---@field show_status boolean Show kernel status in statusline
---@field python_path string|nil Custom Python path for kernel bridge

---@class ImageConfig
---@field enabled boolean Enable image rendering (requires snacks.nvim)
---@field cache_dir string Directory to cache decoded images
---@field max_width number|nil Maximum image width in terminal columns (nil = window width minus sign/number columns)
---@field max_height number|nil Maximum image height in terminal rows (nil = window height minus scrolloff minus 1)

---@class InspectorConfig
---@field close string|string[] Keys to close inspector window (default: {'q', '<Esc>'})
---@field inspect string|string[] Keys to inspect variable under cursor (default: {'K', '<CR>'})
---@field auto_hover AutoHoverConfig Auto-hover settings

---@class AutoHoverConfig
---@field enabled boolean Enable auto-hover on CursorHold (default: true)
---@field delay number Delay in milliseconds before showing hover (default: 500)

---@type NotebookConfig
M.defaults = {
	float = {
		width = 0.9,
		height = 0.7,
		border = "rounded",
		overlay = true, -- true = inline overlay, false = centered popup
		show_line_numbers = false, -- line numbers in overlay mode (facade numbers visible behind)
	},
	--- TODO: make <leader>-_<prefix>_ key configurable?
	keymaps = {
		-- Direct facade keys (high-frequency)
		next_cell = "]]",
		prev_cell = "[[",
		jump_to_cell = "<leader>kj",
		cut_cell = "dd",
		paste_cell_below = "p",
		paste_cell_above = "P",
		move_cell_down = "<M-j>",
		move_cell_up = "<M-k>",
		execute_cell = "<C-CR>",
		execute_and_next = "<S-CR>",
		execute_and_insert = "<M-CR>",
		interrupt_kernel = "<C-c>",
		-- <leader>k menu (notebook operations)
		add_cell_above = "<leader>ka",
		add_cell_below = "<leader>kb",
		make_markdown = "<leader>km",
		make_code = "<leader>ky",
		make_raw = "<leader>kr",
		open_output = "<leader>ko",
		clear_output = "<leader>kc",
		clear_all_outputs = "<leader>kC",
		menu_execute_cell = "<leader>kx",
		menu_execute_and_next = "<leader>kX",
		execute_all_below = nil, -- Unmapped by default; set to e.g. '<leader>kA' to enable
		kernel_interrupt = "<leader>ki",
		kernel_restart = "<leader>k0",
		kernel_start = "<leader>ks",
		kernel_shutdown = "<leader>kS",
		kernel_info = "<leader>kn",
		fold_toggle = "<leader>kf",
		variable_inspect = "<leader>kh",
		cell_variables = "<leader>kv",
		toggle_auto_hover = "<leader>kH",
		-- Note: i, a, I, A, o, O, <CR> are hardcoded for edit mode entry
		-- Note: LSP keymaps (gd, gr, K, etc.) work via API interception in lsp.lua
	},
	highlights = {
		border = "Comment",
		border_hover = "Special",
		border_active = "Number",
		exec_count = "Number",
		output = "Comment",
		output_error = "DiagnosticError",
		executing = "DiagnosticWarn",
		queued = "DiagnosticHint",
		hint = "Comment",
	},
	border_hints = {
		enabled = true,
		show_on_hover = true,
		show_on_edit = true,
	},
	kernel = {
		auto_connect = false,
		show_status = true,
		python_path = nil, -- Custom Python path (otherwise auto-discovered)
	},
	images = {
		enabled = true,
		cache_dir = vim.fn.stdpath("cache") .. "/ipynb.nvim",
		max_width = nil, -- nil = window width minus sign/number columns
		max_height = nil, -- nil = window height minus scrolloff minus 1
	},
	inspector = {
		close = { "q", "<Esc>" }, -- Keys to close inspector window
		inspect = { "K", "<CR>" }, -- Keys to inspect variable under cursor
		auto_hover = {
			enabled = false, -- Auto-show variable hover on CursorHold
			delay = 500, -- Delay in milliseconds before showing hover
		},
	},
	folding = {
		hide_output = false, -- Include end marker in fold to hide output when folded
	},
	format = {
		enabled = true, -- Wrap vim.lsp.buf.format() to work with notebooks
		trailing_blank_lines = 0, -- Max trailing blank lines to keep after formatting
	},
}

-- Current configuration (populated by setup)
---@type NotebookConfig
M.config = vim.deepcopy(M.defaults)

---Setup configuration with user overrides
---@param opts NotebookConfig|nil
function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", M.defaults, opts or {})
end

---Get current configuration
---@return NotebookConfig
function M.get()
	return M.config
end

return M
