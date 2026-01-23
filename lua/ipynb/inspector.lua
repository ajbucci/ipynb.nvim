-- ipynb/inspector.lua - Variable inspector using Jupyter inspect protocol
-- Language-agnostic: works with any Jupyter kernel (Python, Julia, R, etc.)

local M = {}

-- Track current hover window for auto-close
local hover_win = nil
local hover_timer = nil
local auto_hover_enabled = nil -- nil = use config, true/false = override

local function maybe_colorize_buf(buf, force)
	if not force then
		return
	end
	local ok, Snacks = pcall(require, "snacks")
	if not ok or not Snacks.terminal or type(Snacks.terminal.colorize) ~= "function" then
		return
	end
	local was_modifiable = vim.bo[buf].modifiable
	vim.bo[buf].modifiable = true
	pcall(vim.api.nvim_buf_call, buf, function()
		Snacks.terminal.colorize()
	end)
	-- Snacks.terminal.colorize installs a TextChanged autocmd that forces cursor to last line
	pcall(vim.api.nvim_clear_autocmds, { buffer = buf, event = "TextChanged" })
	vim.bo[buf].modifiable = was_modifiable
end

local function apply_raw_or_clean(buf, sections)
	if sections._raw ~= true then
		return
	end
	local ok, Snacks = pcall(require, "snacks")
	if not ok or not Snacks.terminal or type(Snacks.terminal.colorize) ~= "function" then
		if sections._clean and type(sections._clean) == "string" then
			local lines = vim.split(sections._clean, "\n", { plain = true })
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		end
	else
		maybe_colorize_buf(buf, true)
	end
end

---Get the identifier at cursor using treesitter on shadow buffer
---@param state NotebookState
---@return string|nil identifier, number|nil cell_idx
function M.get_identifier_at_cursor(state)
	if not state.shadow_buf or not vim.api.nvim_buf_is_valid(state.shadow_buf) then
		return nil, nil
	end

	-- Get cursor position (1-indexed to 0-indexed)
	local cursor = vim.api.nvim_win_get_cursor(0)
	local row = cursor[1] - 1 -- 0-indexed
	local col = cursor[2]

	local cell_idx
	local cell

	-- Check if we're in an edit float - need to translate coordinates
	if state.edit_state and vim.api.nvim_get_current_buf() == state.edit_state.buf then
		-- In edit float: translate edit buffer position to facade/shadow position
		-- edit buffer line 1 = facade line (start_line + 1) in 1-indexed
		-- so edit buffer line N (0-indexed: N-1) = facade line start_line + N - 1 (0-indexed)
		row = state.edit_state.start_line + row
		cell_idx = state.edit_state.cell_idx
		cell = state.cells[cell_idx]
	else
		-- In facade buffer: use line directly
		local cells_mod = require("ipynb.cells")
		cell_idx = cells_mod.get_cell_at_line(state, row)
		if not cell_idx then
			return nil, nil
		end
		cell = state.cells[cell_idx]
	end

	if not cell or cell.type ~= "code" then
		return nil, cell_idx
	end

	-- Use treesitter on shadow buffer (1:1 line mapping)
	local lang = state.shadow_lang or "python"
	local parser = vim.treesitter.get_parser(state.shadow_buf, lang)
	if not parser then
		return nil, cell_idx
	end

	local ok, tree = pcall(function()
		return parser:parse()[1]
	end)
	if not ok or not tree then
		return nil, cell_idx
	end

	local root = tree:root()

	-- Get the node at cursor position
	local node = root:named_descendant_for_range(row, col, row, col)
	if not node then
		return nil, cell_idx
	end

	-- Walk up to find identifier or attribute access (e.g., plt.show)
	while node do
		local node_type = node:type()
		if node_type == "identifier" then
			local parent = node:parent()
			-- Check if this identifier is the "attribute" part of an attribute access
			-- e.g., in `plt.show`, if cursor is on `show`, return `plt.show`
			-- but if cursor is on `plt`, just return `plt`
			if parent and parent:type() == "attribute" then
				local attr_node = parent:field("attribute")[1]
				if attr_node and attr_node:id() == node:id() then
					-- Cursor is on the attribute part (e.g., "show" in "plt.show")
					local text = vim.treesitter.get_node_text(parent, state.shadow_buf)
					return text, cell_idx
				end
			end
			-- Cursor is on a standalone identifier or the object part of an attribute
			local text = vim.treesitter.get_node_text(node, state.shadow_buf)
			return text, cell_idx
		elseif node_type == "attribute" then
			-- Cursor directly on attribute node (e.g., on the dot)
			local text = vim.treesitter.get_node_text(node, state.shadow_buf)
			return text, cell_idx
		end
		node = node:parent()
	end

	return nil, cell_idx
end

---Get all unique identifiers in a cell using treesitter
---@param state NotebookState
---@param cell_idx number Cell index
---@return string[] identifiers List of unique identifiers
function M.get_cell_identifiers(state, cell_idx)
	if not state.shadow_buf or not vim.api.nvim_buf_is_valid(state.shadow_buf) then
		return {}
	end

	local cell = state.cells[cell_idx]
	if not cell or cell.type ~= "code" then
		return {}
	end

	-- Get cell line range
	local cells_mod = require("ipynb.cells")
	local content_start, content_end = cells_mod.get_content_range(state, cell_idx)
	if not content_start or not content_end then
		return {}
	end

	local lang = state.shadow_lang or "python"
	local parser = vim.treesitter.get_parser(state.shadow_buf, lang)
	if not parser then
		return {}
	end

	local ok, tree = pcall(function()
		return parser:parse()[1]
	end)
	if not ok or not tree then
		return {}
	end

	-- Query for all identifiers
	local query_ok, query = pcall(vim.treesitter.query.parse, lang, "(identifier) @id")
	if not query_ok or not query then
		return {}
	end

	local seen = {}
	local identifiers = {}

	-- Iterate through captures in cell range
	for _, node in query:iter_captures(tree:root(), state.shadow_buf, content_start, content_end + 1) do
		local text = vim.treesitter.get_node_text(node, state.shadow_buf)
		if text and type(text) == "string" and not seen[text] then
			seen[text] = true
			table.insert(identifiers, text)
		end
	end

	return identifiers
end

---Show variable value at cursor in floating window (uses Jupyter inspect)
---@param state NotebookState
function M.show_variable_at_cursor(state)
	local kernel = require("ipynb.kernel")

	local identifier, cell_idx = M.get_identifier_at_cursor(state)

	if not cell_idx then
		vim.notify("Cursor not in a cell", vim.log.levels.WARN)
		return
	end

	local cell = state.cells[cell_idx]

	if not identifier then
		if cell.type ~= "code" then
			vim.notify("Not a code cell", vim.log.levels.INFO)
		else
			vim.notify("No identifier at cursor", vim.log.levels.INFO)
		end
		return
	end

	-- Check kernel connection
	if not kernel.is_connected(state) then
		vim.notify("Kernel not connected", vim.log.levels.INFO)
		return
	end

	-- Use Jupyter inspect protocol (language-agnostic)
	kernel.inspect(state, identifier, #identifier, function(reply)
		vim.schedule(function()
			if not reply.found then
				vim.notify(string.format("'%s': not found", identifier), vim.log.levels.INFO)
				return
			end

			-- Show inspect data in float with section navigation
			M.show_inspect_float(identifier, reply.sections or {}, state.shadow_lang)
		end)
	end)
end

---Show all variables for current cell (uses Jupyter inspect on all identifiers)
---@param state NotebookState
function M.show_cell_variables(state)
	local kernel = require("ipynb.kernel")
	local cells_mod = require("ipynb.cells")
	local cursor_line = vim.api.nvim_win_get_cursor(0)[1] - 1
	local cell_idx = cells_mod.get_cell_at_line(state, cursor_line)

	if not cell_idx then
		vim.notify("No cell at cursor", vim.log.levels.WARN)
		return
	end

	local cell = state.cells[cell_idx]

	if cell.type ~= "code" then
		vim.notify("Not a code cell", vim.log.levels.INFO)
		return
	end

	if not kernel.is_connected(state) then
		vim.notify("Kernel not connected", vim.log.levels.INFO)
		return
	end

	-- Get all identifiers in the cell using treesitter
	local identifiers = M.get_cell_identifiers(state, cell_idx)

	if #identifiers == 0 then
		vim.notify("No identifiers in cell", vim.log.levels.INFO)
		return
	end

	vim.notify(string.format("Inspecting %d identifiers...", #identifiers), vim.log.levels.INFO)

	-- Inspect all identifiers
	kernel.inspect_batch(state, identifiers, function(results)
		vim.schedule(function()
			-- Build display lines from inspect results
			local lines = {}
			local found_vars = {} -- Store for hover lookup

			-- Sort identifiers alphabetically
			local sorted_idents = vim.tbl_keys(results)
			table.sort(sorted_idents)

			for _, ident in ipairs(sorted_idents) do
				local info = results[ident]
				if info.found then
					local sections = info.sections or {}
					local type_str = sections.type or "?"
					local value_str = sections.string_form or "..."
					-- Truncate long values (take first line only)
					local first_line = value_str:match("^([^\n]*)") or value_str
					if #first_line > 60 then
						first_line = first_line:sub(1, 57) .. "..."
					end
					table.insert(lines, string.format("%s: %s = %s", ident, type_str, first_line))
					found_vars[ident] = sections
				end
			end

			if #lines == 0 then
				vim.notify("No defined variables found", vim.log.levels.INFO)
				return
			end

			M.show_variables_float(lines, cell_idx, found_vars, state.shadow_lang)
		end)
	end)
end

---Show Jupyter inspect result in a floating window with section navigation
---@param name string Variable name
---@param sections table Parsed sections from inspect (type, string_form, docstring, etc.)
---@param lang string|nil Language for syntax highlighting (default: python)
function M.show_inspect_float(name, sections, lang)
	sections = sections or {}

	-- Normalize vim.NIL (from JSON null) to nil to avoid userdata issues
	for key, value in pairs(sections) do
		if value == vim.NIL then
			sections[key] = nil
		end
	end
	local var_type = sections.type

	local available = {}

	if lang == "python" then
		local function add_section(key, label, content)
			if content and content ~= "" then
				sections[key] = content
				table.insert(available, { key = key, label = label })
			end
		end

		local has_value = sections.string_form and sections.string_form ~= ""
		add_section("string_form", "Value", sections.string_form)

		local signature = sections.definition or sections.init_definition or sections.call_def
		add_section("signature", "Signature", signature)

		local doc = sections.docstring
			or sections.init_docstring
			or sections.class_docstring
			or sections.call_docstring

		local meta_lines = {}
		if sections.type_name then
			table.insert(meta_lines, "Type: " .. tostring(sections.type_name))
		end
		if sections.namespace then
			table.insert(meta_lines, "Namespace: " .. tostring(sections.namespace))
		end
		if sections.length then
			table.insert(meta_lines, "Length: " .. tostring(sections.length))
		end
		if sections.file then
			table.insert(meta_lines, "File: " .. tostring(sections.file))
		end
		local meta_content = #meta_lines > 0 and table.concat(meta_lines, "\n") or nil
		if has_value then
			add_section("metadata", "Metadata", meta_content)
			add_section("docstring", "Docstring", doc)
		else
			add_section("docstring", "Docstring", doc)
			add_section("metadata", "Metadata", meta_content)
		end
	else
		-- Labels for display
		local section_labels = {
			string_form = "Value",
			docstring = "Docstring",
			signature = "Signature",
			file = "File",
			source = "Source",
			init_docstring = "Init",
			class_docstring = "Class",
			length = "Length",
		}

		-- Use order from Jupyter (via _order key) or fall back to default
		local section_order = sections._order or { "string_form", "docstring", "signature", "file", "source" }

		-- Build list of available sections (in Jupyter's order)
		-- Skip 'type' since it's shown in the header
		for _, key in ipairs(section_order) do
			if key ~= "_order" and key ~= "type" and sections[key] and sections[key] ~= "" then
				table.insert(available, { key = key, label = section_labels[key] or key })
			end
		end
	end

	if #available == 0 then
		vim.notify("No inspect data available", vim.log.levels.INFO)
		return
	end

	local current_idx = 1
	local buf = nil
	local win = nil
	local fixed_width = nil

	-- Forward declarations
	local update_content, next_section, prev_section, close

	update_content = function()
		local section = available[current_idx]
		local content = sections[section.key] or ""
		if type(content) ~= "string" then
			content = tostring(content)
		end
		local lines = vim.split(content, "\n", { plain = true })

		-- Create a fresh buffer each time to avoid syntax state issues
		local old_buf = buf
		buf = vim.api.nvim_create_buf(false, true)
		vim.bo[buf].buftype = "nofile"
		vim.bo[buf].bufhidden = "wipe"
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.bo[buf].modifiable = false
		apply_raw_or_clean(buf, sections)

		-- Only use syntax highlighting for signature/source sections
		if section.key == "signature" or section.key == "source" then
			local ft = lang or "python"
			vim.bo[buf].filetype = ft
			pcall(vim.treesitter.start, buf, ft)
		elseif section.key == "docstring" then
			for i = 0, #lines - 1 do
				pcall(vim.api.nvim_buf_add_highlight, buf, -1, "@string.documentation", i, 0, -1)
			end
		elseif section.key == "metadata" then
			for i, line in ipairs(lines) do
				local colon = line:find(":")
				if colon then
					pcall(vim.api.nvim_buf_add_highlight, buf, -1, "Title", i - 1, 0, colon)
				end
			end
		end

		-- Build title with type and section indicator
		local title_parts = { name }
		if var_type then
			table.insert(title_parts, var_type)
		end
		local title = " " .. table.concat(title_parts, ": ") .. " "

		-- Build footer with section nav hint
		local footer = #available > 1
				and string.format(" [%d/%d] %s | Tab: next ", current_idx, #available, section.label)
			or string.format(" %s ", section.label)

		if not fixed_width then
			local max_line_width = 0
			for _, item in ipairs(available) do
				local sec_content = sections[item.key] or ""
				if type(sec_content) ~= "string" then
					sec_content = tostring(sec_content)
				end
				local sec_lines = vim.split(sec_content, "\n", { plain = true })
				for _, line in ipairs(sec_lines) do
					max_line_width = math.max(max_line_width, vim.fn.strdisplaywidth(line))
				end
			end
			local footer_candidates = {}
			if #available > 1 then
				for i, item in ipairs(available) do
					table.insert(footer_candidates, string.format(" [%d/%d] %s | Tab: next ", i, #available, item.label))
				end
			else
				table.insert(footer_candidates, string.format(" %s ", available[1].label))
			end
			local max_footer = 0
			for _, f in ipairs(footer_candidates) do
				max_footer = math.max(max_footer, #f)
			end
			fixed_width = math.min(math.max(max_line_width + 2, #title + 2, max_footer + 2, 20), 80)
		end

		local width = fixed_width
		local height = math.min(#lines, 20)

		if win and vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_set_buf(win, buf)
			vim.api.nvim_win_set_config(win, {
				width = width,
				height = height,
				title = title,
				footer = footer,
			})
		else
			win = vim.api.nvim_open_win(buf, true, {
				relative = "cursor",
				row = 1,
				col = 0,
				width = width,
				height = height,
				style = "minimal",
				border = "rounded",
				title = title,
				title_pos = "center",
				footer = footer,
				footer_pos = "center",
				zindex = 41,
			})
		end

		-- Clean up old buffer
		if old_buf and vim.api.nvim_buf_is_valid(old_buf) then
			vim.api.nvim_buf_delete(old_buf, { force = true })
		end

		-- Re-bind keymaps to new buffer
		local opts = { buffer = buf, silent = true, nowait = true }
		vim.keymap.set("n", "<Tab>", next_section, opts)
		vim.keymap.set("n", "<S-Tab>", prev_section, opts)
		vim.keymap.set("n", "l", next_section, opts)
		vim.keymap.set("n", "h", prev_section, opts)
		vim.keymap.set("n", "q", close, opts)
		vim.keymap.set("n", "<Esc>", close, opts)
	end

	next_section = function()
		if #available > 1 then
			current_idx = current_idx % #available + 1
			update_content()
		end
	end

	prev_section = function()
		if #available > 1 then
			current_idx = (current_idx - 2) % #available + 1
			update_content()
		end
	end

	close = function()
		if win and vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end

	update_content()
end

---Show all variables in a floating window
---@param lines string[] Lines to display
---@param cell_idx number Cell index for title
---@param var_data table<string, table>|nil Variable data for hover (identifier -> inspect mime-bundle)
---@param lang string|nil Language for syntax highlighting (default: python)
function M.show_variables_float(lines, cell_idx, var_data, lang)
	-- Get config for footer text
	local config = require("ipynb.config").get()
	local inspector_keys = config.inspector or {}
	local close_keys = inspector_keys.close or { "q", "<Esc>" }
	local inspect_keys = inspector_keys.inspect or { "K", "<CR>" }

	-- Normalize to arrays
	if type(close_keys) == "string" then
		close_keys = { close_keys }
	end
	if type(inspect_keys) == "string" then
		inspect_keys = { inspect_keys }
	end

	-- Build footer text from config
	local close_hint = close_keys[1] or "q"
	local inspect_hint = inspect_keys[1] or "K"
	local footer = var_data and string.format(" %s: inspect  %s: close ", inspect_hint, close_hint)
		or string.format(" %s: close ", close_hint)

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].filetype = lang or "python"
	vim.bo[buf].modifiable = false

	-- Calculate dimensions
	local max_width = 0
	for _, line in ipairs(lines) do
		max_width = math.max(max_width, vim.fn.strdisplaywidth(line))
	end
	local width = math.min(math.max(max_width + 4, 30), 100)
	local height = math.min(#lines + 2, math.floor(vim.o.lines * 0.6))

	-- Center the float
	local row = math.floor((vim.o.lines - height) / 2)
	local col = math.floor((vim.o.columns - width) / 2)

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		row = row,
		col = col,
		width = width,
		height = height,
		style = "minimal",
		border = "rounded",
		title = string.format(" Cell [%d] Variables ", cell_idx),
		title_pos = "center",
		footer = footer,
		footer_pos = "center",
	})

	vim.wo[win].wrap = true
	vim.wo[win].cursorline = true

	local opts = { buffer = buf, silent = true, nowait = true }
	local close = function()
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end

	for _, key in ipairs(close_keys) do
		vim.keymap.set("n", key, close, opts)
	end

	-- Hover to show full variable details with section navigation
	if var_data then
		local show_var_hover = function()
			local line = vim.api.nvim_get_current_line()
			-- Parse variable name from line format: "name: type = value"
			local var_name = line:match("^([^:]+):")
			if var_name and var_data[var_name] then
				M.show_inspect_float(var_name, var_data[var_name], lang)
			end
		end
		for _, key in ipairs(inspect_keys) do
			vim.keymap.set("n", key, show_var_hover, opts)
		end
	end
end

---Check if auto-hover is currently enabled
---@return boolean
function M.is_auto_hover_enabled()
	if auto_hover_enabled ~= nil then
		return auto_hover_enabled
	end
	local config = require("ipynb.config").get()
	local auto_hover = config.inspector and config.inspector.auto_hover
	return auto_hover and auto_hover.enabled
end

---Toggle auto-hover on/off
---@return boolean new_state
function M.toggle_auto_hover()
	local currently_enabled = M.is_auto_hover_enabled()
	auto_hover_enabled = not currently_enabled
	M.close_hover() -- Close any open hover
	local state_str = auto_hover_enabled and "enabled" or "disabled"
	vim.notify("Variable auto-hover " .. state_str, vim.log.levels.INFO)
	return auto_hover_enabled
end

---Cancel any pending hover timer
local function cancel_hover_timer()
	if hover_timer then
		hover_timer:stop()
		hover_timer:close()
		hover_timer = nil
	end
end

---Close any open hover window
function M.close_hover()
	cancel_hover_timer()
	if hover_win and vim.api.nvim_win_is_valid(hover_win) then
		vim.api.nvim_win_close(hover_win, true)
	end
	hover_win = nil
end

---Show hover for identifier at cursor (silent version for auto-hover)
---Uses Jupyter inspect protocol asynchronously
---@param state NotebookState
function M.show_hover_silent(state)
	local kernel = require("ipynb.kernel")

	local identifier, cell_idx = M.get_identifier_at_cursor(state)

	if not cell_idx or not identifier then
		return
	end

	if not kernel.is_connected(state) then
		return
	end

	-- Use Jupyter inspect protocol
	kernel.inspect(state, identifier, #identifier, function(reply)
		vim.schedule(function()
			if not reply.found then
				return
			end

			local sections = reply.sections or {}
			-- For auto-hover, just show the string_form (value)
			local text = sections.string_form or sections.docstring or ""
			if text == "" then
				return
			end

			-- Close existing hover first
			M.close_hover()

			local lines = vim.split(text, "\n", { plain = true })

			local buf = vim.api.nvim_create_buf(false, true)
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
			vim.bo[buf].buftype = "nofile"
			vim.bo[buf].bufhidden = "wipe"
			vim.bo[buf].modifiable = false
			apply_raw_or_clean(buf, sections)

			local max_width = 0
			for _, line in ipairs(lines) do
				max_width = math.max(max_width, vim.fn.strdisplaywidth(line))
			end
			local title = sections.type and string.format(" %s: %s ", identifier, sections.type)
				or string.format(" %s ", identifier)
			local width = math.min(math.max(max_width + 2, #title + 2, 20), 80)
			local height = math.min(#lines, 20)

			hover_win = vim.api.nvim_open_win(buf, false, {
				relative = "cursor",
				row = 1,
				col = 0,
				width = width,
				height = height,
				style = "minimal",
				border = "rounded",
				title = title,
				title_pos = "center",
				zindex = 41,
				focusable = false,
			})
		end)
	end)
end

---Setup auto-hover on CursorHold for a buffer
---@param state NotebookState
---@param buf number Buffer to attach to
function M.setup_auto_hover(state, buf)
	local config = require("ipynb.config").get()
	local auto_hover = config.inspector and config.inspector.auto_hover
	local delay = (auto_hover and auto_hover.delay) or 500
	local group = vim.api.nvim_create_augroup("NotebookVarHover_" .. buf, { clear = true })

	-- Close hover and cancel timer on cursor move
	vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "InsertEnter", "BufLeave" }, {
		group = group,
		buffer = buf,
		callback = function()
			M.close_hover()
		end,
	})

	-- Start debounce timer on CursorHold
	vim.api.nvim_create_autocmd("CursorHold", {
		group = group,
		buffer = buf,
		callback = function()
			-- Check if auto-hover is enabled (can be toggled at runtime)
			if not M.is_auto_hover_enabled() then
				return
			end
			-- Don't show if already showing or in insert mode
			if hover_win and vim.api.nvim_win_is_valid(hover_win) then
				return
			end
			if vim.fn.mode() ~= "n" then
				return
			end

			-- Cancel any existing timer
			cancel_hover_timer()

			-- Start new debounce timer
			hover_timer = vim.uv.new_timer()
			hover_timer:start(
				delay,
				0,
				vim.schedule_wrap(function()
					-- Double-check we're still in normal mode, enabled, and no hover is showing
					if
						M.is_auto_hover_enabled()
						and vim.fn.mode() == "n"
						and not (hover_win and vim.api.nvim_win_is_valid(hover_win))
					then
						M.show_hover_silent(state)
					end
					cancel_hover_timer()
				end)
			)
		end,
	})
end

return M
