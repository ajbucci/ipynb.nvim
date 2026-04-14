-- Test helper functions for ipynb.nvim
local M = {}

-- Track test results
M.results = {
	passed = 0,
	failed = 0,
	errors = {},
}

---Run a single test with error handling
---@param name string Test name
---@param fn function Test function
function M.run_test(name, fn)
	-- Reset state between tests
	M.close_all_notebooks()

	local ok, err = pcall(fn)
	if ok then
		print("  PASS: " .. name)
		M.results.passed = M.results.passed + 1
	else
		print("  FAIL: " .. name)
		print("        " .. tostring(err))
		M.results.failed = M.results.failed + 1
		table.insert(M.results.errors, { name = name, error = err })
	end
end

---Print final test summary
function M.summary()
	print("")
	print(string.rep("=", 60))
	print(string.format("Results: %d passed, %d failed", M.results.passed, M.results.failed))
	print(string.rep("=", 60))

	if M.results.failed > 0 then
		print("")
		print("Failures:")
		for _, e in ipairs(M.results.errors) do
			print("  - " .. e.name .. ": " .. tostring(e.error))
		end
	end

	return M.results.failed == 0
end

---Close all notebook buffers and clear state
function M.close_all_notebooks()
	local state_mod = require("ipynb.state")
	local facade_bufs = {}

	-- Close any edit floats first and collect live notebook buffers for cleanup.
	for facade_buf, state in pairs(state_mod.notebooks or {}) do
		if state.edit_state and vim.api.nvim_win_is_valid(state.edit_state.win) then
			pcall(vim.api.nvim_win_close, state.edit_state.win, true)
		end
		table.insert(facade_bufs, facade_buf)
	end

	-- Stop LSP clients before deleting buffers so async diagnostics don't target
	-- buffers that were force-deleted by the test harness.
	for _, client in ipairs(vim.lsp.get_clients()) do
		pcall(client.stop, client, true)
	end
	vim.wait(500, function()
		return #vim.lsp.get_clients() == 0
	end, 20)

	-- Delete notebook facade buffers first. Their BufUnload handlers will clean up
	-- shadow buffers, temp files, images, and state entries.
	for _, buf in ipairs(facade_bufs) do
		if vim.api.nvim_buf_is_valid(buf) then
			pcall(vim.api.nvim_buf_delete, buf, { force = true })
		end
	end

	-- Delete any remaining scratch/preview buffers left behind by the test.
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(buf) then
			pcall(vim.api.nvim_buf_delete, buf, { force = true })
		end
	end

	-- Clear any stale state if a test bypassed the normal BufUnload path.
	state_mod.notebooks = {}

	-- Clear cached facade buffer
	M._facade_buf = nil

	-- Small delay for cleanup
	vim.wait(10)
end

local function tests_dir()
	return vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
end

---Get full path to a notebook fixture
---@param path string Path relative to tests/fixtures/
---@return string
function M.fixture_path(path)
	return tests_dir() .. "/fixtures/" .. path
end

---Open a notebook file by full path
---@param full_path string Absolute or relative notebook path
---@return NotebookState
function M.open_notebook_path(full_path)
	vim.cmd("edit " .. vim.fn.fnameescape(full_path))
	vim.wait(100) -- Allow plugin to fully initialize

	local state = require("ipynb.state").get()
	assert(state, "Notebook state should exist after opening")
	assert(state.facade_buf, "Facade buffer should exist")
	assert(#state.cells > 0, "Should have cells")

	return state
end

---Open a notebook fixture
---@param path string Path to notebook (relative to tests/fixtures/)
---@return NotebookState
function M.open_notebook(path)
	return M.open_notebook_path(M.fixture_path(path))
end

-- Track facade buffer for state lookups
M._facade_buf = nil

---Get the current notebook state
---Works from facade, edit buffer, or shadow buffer
---@return NotebookState|nil
function M.get_state()
	local state_mod = require("ipynb.state")

	-- Try current buffer first
	local state = state_mod.get()
	if state then
		M._facade_buf = state.facade_buf
		return state
	end

	-- Try from edit buffer
	state = state_mod.get_from_edit_buf(vim.api.nvim_get_current_buf())
	if state then
		M._facade_buf = state.facade_buf
		return state
	end

	-- Try cached facade buffer
	if M._facade_buf and vim.api.nvim_buf_is_valid(M._facade_buf) then
		state = state_mod.get_by_facade(M._facade_buf)
		if state then
			return state
		end
	end

	return nil
end

---Get content of a specific cell
---@param cell_idx number 1-indexed cell number
---@return string
function M.get_cell_content(cell_idx)
	local state = M.get_state()
	assert(state, "No notebook state")
	assert(state.cells[cell_idx], "Cell " .. cell_idx .. " does not exist")
	return state.cells[cell_idx].source
end

---Enter edit mode for a cell (opens edit float)
---@param cell_idx number 1-indexed cell number
function M.enter_cell(cell_idx)
	local state = M.get_state()
	local cells_mod = require("ipynb.cells")

	assert(state, "No notebook state")

	-- Store facade buffer for later lookups (before buffer changes)
	M._facade_buf = state.facade_buf

	-- Position cursor in the cell content
	local content_start, _ = cells_mod.get_content_range(state, cell_idx)
	assert(content_start, "Could not get content range for cell " .. cell_idx)

	-- Move cursor to cell content (1-indexed for nvim_win_set_cursor)
	vim.api.nvim_win_set_cursor(0, { content_start + 1, 0 })

	-- Trigger edit mode
	local edit_mod = require("ipynb.edit")
	edit_mod.open(state)

	-- Wait a bit for the edit float to be set up
	vim.wait(100)

	-- Re-fetch state (works from edit buffer now)
	state = M.get_state()
	assert(state and state.edit_state, "Should be in edit mode after enter_cell")
end

---Exit edit mode (close edit float)
function M.exit_cell()
	local state = M.get_state()
	if state and state.edit_state then
		require("ipynb.edit").close(state)
		vim.wait(50)
	end
end

---Check if currently in edit float
---@return boolean
function M.is_in_edit_float()
	local state = M.get_state()
	return state ~= nil and state.edit_state ~= nil
end

---Get the edit buffer (when in edit mode)
---@return number|nil
function M.get_edit_buf()
	local state = M.get_state()
	return state and state.edit_state and state.edit_state.buf
end

---Get content of edit buffer
---@return string|nil
function M.get_edit_buffer_content()
	local buf = M.get_edit_buf()
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return nil
	end
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	return table.concat(lines, "\n")
end

---Feed keys to Neovim (with proper escaping)
---Uses 'mtx' flags: remap=true, typed=true, execute immediately
---@param keys string Keys to feed (can include special keys like <Esc>)
function M.feedkeys(keys)
	local escaped = vim.api.nvim_replace_termcodes(keys, true, false, true)
	vim.api.nvim_feedkeys(escaped, "mtx", false)
	-- Process pending input
	vim.cmd("redraw")
	vim.wait(20)
end
function M.insert_text_and_esc(text, ins_cmd)
	local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
	vim.api.nvim_feedkeys(ins_cmd, "mt", false)
	vim.api.nvim_feedkeys(text, "mt", false)
	vim.api.nvim_feedkeys(esc, "mtx", false)
	-- Trigger sync to facade (simulates what happens on TextChanged)
	vim.api.nvim_exec_autocmds("TextChanged", { buffer = M.get_edit_buf() })
	vim.wait(50)
end

---Directly modify the edit buffer content (more reliable in headless mode)
---@param new_content string New content for the cell
function M.set_edit_content(new_content)
	local buf = M.get_edit_buf()
	if not buf then
		error("Not in edit mode")
	end
	local lines = vim.split(new_content, "\n", { plain = true })
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.wait(50)
end

---Append a line to the edit buffer (more reliable in headless mode)
---@param line string Line to append
function M.append_line_to_edit(line)
	local buf = M.get_edit_buf()
	if not buf then
		error("Not in edit mode")
	end
	local current = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	table.insert(current, line)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, current)
	-- Trigger TextChanged to sync
	vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
	vim.wait(50)
end

---Perform undo (works in both facade and edit float)
function M.undo()
	local state = M.get_state()
	if state and state.edit_state then
		-- In edit float, use global undo
		require("ipynb.edit").global_undo(state)
	else
		-- In facade, use regular undo
		vim.bo[state.facade_buf].modifiable = true
		vim.api.nvim_buf_call(state.facade_buf, function()
			vim.cmd("silent! undo")
		end)
		vim.bo[state.facade_buf].modifiable = false

		-- Sync state after undo
		local cells_mod = require("ipynb.cells")
		cells_mod.sync_cells_from_facade(state)
		cells_mod.place_markers(state)
		require("ipynb.lsp").refresh_shadow(state)
	end
	vim.wait(50)
end

---Perform redo (works in both facade and edit float)
function M.redo()
	local state = M.get_state()
	if state and state.edit_state then
		require("ipynb.edit").global_redo(state)
	else
		vim.bo[state.facade_buf].modifiable = true
		vim.api.nvim_buf_call(state.facade_buf, function()
			vim.cmd("silent! redo")
		end)
		vim.bo[state.facade_buf].modifiable = false

		local cells_mod = require("ipynb.cells")
		cells_mod.sync_cells_from_facade(state)
		cells_mod.place_markers(state)
		require("ipynb.lsp").refresh_shadow(state)
	end
	vim.wait(50)
end

---Get facade buffer
---@return number|nil
function M.get_facade_buf()
	local state = M.get_state()
	return state and state.facade_buf
end

---Get all cell ranges
---@return table[]
function M.get_all_cell_ranges()
	local state = M.get_state()
	if not state then
		return {}
	end

	local cells_mod = require("ipynb.cells")
	local ranges = {}

	for i = 1, #state.cells do
		local s, e = cells_mod.get_cell_range(state, i)
		local cs, ce = cells_mod.get_content_range(state, i)
		ranges[i] = {
			start = s,
			["end"] = e,
			content_start = cs,
			content_end = ce,
		}
	end

	return ranges
end

---Get line count of facade buffer
---@return number
function M.get_facade_line_count()
	local buf = M.get_facade_buf()
	if not buf then
		return 0
	end
	return vim.api.nvim_buf_line_count(buf)
end

---Get line count of shadow buffer
---@return number
function M.get_shadow_line_count()
	local state = M.get_state()
	if not state or not state.shadow_buf then
		return 0
	end
	return vim.api.nvim_buf_line_count(state.shadow_buf)
end

---Assert two values are equal
---@param actual any
---@param expected any
---@param msg string|nil
function M.assert_eq(actual, expected, msg)
	if actual ~= expected then
		local err = string.format("Expected %s but got %s", vim.inspect(expected), vim.inspect(actual))
		if msg then
			err = msg .. ": " .. err
		end
		error(err)
	end
end

---Assert condition is true
---@param condition any
---@param msg string|nil
function M.assert_true(condition, msg)
	if not condition then
		error(msg or "Assertion failed: expected truthy value")
	end
end

---Assert condition is false
---@param condition any
---@param msg string|nil
function M.assert_false(condition, msg)
	if condition then
		error(msg or "Assertion failed: expected falsy value")
	end
end

return M
