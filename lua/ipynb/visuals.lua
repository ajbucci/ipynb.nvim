-- ipynb/visuals.lua - Cell decorations with rounded borders

local M = {}

local visual_ns = vim.api.nvim_create_namespace('notebook_visuals')

-- Throttle state for active cell updates (per-buffer)
local throttle_state = {}
local THROTTLE_MS = 50

---Create throttled function for a specific buffer
---@param buf number Buffer handle
---@param fn function Function to throttle
---@return function throttled_fn
local function create_throttle(buf, fn)
  throttle_state[buf] = throttle_state[buf] or {
    last_update = 0,
    pending_timer = nil,
  }

  return function(...)
    local args = { ... }
    local state = throttle_state[buf]
    local now = vim.uv.now()

    -- Cancel any pending trailing update
    if state.pending_timer then
      vim.fn.timer_stop(state.pending_timer)
      state.pending_timer = nil
    end

    if now - state.last_update >= THROTTLE_MS then
      -- Enough time passed, fire immediately
      state.last_update = now
      fn(unpack(args))
    else
      -- Too soon, schedule trailing update
      local remaining = THROTTLE_MS - (now - state.last_update)
      state.pending_timer = vim.fn.timer_start(remaining, function()
        state.pending_timer = nil
        state.last_update = vim.uv.now()
        vim.schedule(function()
          fn(unpack(args))
        end)
      end)
    end
  end
end

---Clean up throttle state for a buffer
---@param buf number Buffer handle
local function cleanup_throttle(buf)
  local state = throttle_state[buf]
  if state and state.pending_timer then
    vim.fn.timer_stop(state.pending_timer)
  end
  throttle_state[buf] = nil
end

---Get the visible line range in current window
---@return number first_line 0-indexed first visible line
---@return number last_line 0-indexed last visible line
local function get_visible_range()
  -- line('w0') and line('w$') return 1-indexed lines
  local first = vim.fn.line('w0') - 1
  local last = vim.fn.line('w$') - 1
  return first, last
end

---Get indices of cells that are visible in the current viewport
---@param state NotebookState
---@return number[] cell_indices List of visible cell indices
local function get_visible_cells(state)
  local cells_mod = require('ipynb.cells')
  local first_visible, last_visible = get_visible_range()

  local visible = {}
  for i, _ in ipairs(state.cells) do
    local start_line, end_line = cells_mod.get_cell_range(state, i)
    if start_line and end_line then
      -- Cell is visible if any part of it overlaps with viewport
      if end_line >= first_visible and start_line <= last_visible then
        table.insert(visible, i)
      end
      -- Optimization: stop checking once we're past the viewport
      if start_line > last_visible then
        break
      end
    end
  end

  return visible
end

-- Border characters
local borders = {
  top_left = '╭',
  top_right = '╮',
  bottom_left = '╰',
  bottom_right = '╯',
  horizontal = '─',
  vertical = '│',
}

-- Try to load nvim-web-devicons for language icons
local devicons_ok, devicons = pcall(require, 'nvim-web-devicons')

---Get icon for a language (uses nvim-web-devicons if available)
---@param language string
---@return string|nil icon
function M.get_language_icon(language)
  if devicons_ok then
    local icon = devicons.get_icon_by_filetype(language)
    if icon then
      return icon
    end
  end
  -- Fallback: no icon, just show language name
  return nil
end

-- Cell type icons (only used if devicons unavailable)
local cell_icons = {
  markdown = devicons_ok and (devicons.get_icon_by_filetype('markdown') or '.md') or '.md',
  raw = devicons_ok and '󰦨' or '',  -- nf-md-raw (U+F09A8)
}

-- Execution state icons (with ASCII fallbacks if no nerd font)
local exec_icons = {
  busy = devicons_ok and '󰦖' or '*',     -- Spinner/running
  queued = devicons_ok and '󰔟' or '~',   -- Clock/waiting
  idle = '',                              -- No icon when idle
}

-- Action icons for border hints (with Unicode fallbacks)
local action_icons = {
  execute = devicons_ok and '󰐊' or '▶',  -- U+25B6 play symbol
  execute_next = (devicons_ok and '󰐊' or '▶') .. '↓',  -- play with down arrow
  add = (devicons_ok and '󰐕' or '+') .. '↓',  -- plus with down arrow
  inspect = devicons_ok and '󰍉' or '?',
  power = '⏻',  -- U+23FB power symbol (standard Unicode)
}

---Get "convert to" icon with arrow
---@param target "markdown"|"code"
---@param language string|nil Language for code cells
---@return string
local function get_convert_icon(target, language)
  if target == 'markdown' then
    return '→' .. cell_icons.markdown
  else
    local lang_icon = language and M.get_language_icon(language)
    return '→' .. (lang_icon or (devicons_ok and '' or '<>'))
  end
end

---Format keymap string for display
---@param keymap_str string Raw keymap like "<leader>kb" or "<S-CR>"
---@return string Formatted for display
local function format_keymap(keymap_str)
  local result = keymap_str

  -- Replace <leader> with actual leader key
  local leader = vim.g.mapleader or '\\'
  local display_leader = leader == ' ' and '␣' or leader
  result = result:gsub('<[lL]eader>', display_leader)

  -- Format special keys
  result = result:gsub('<[sS]%-', 'S-')
  result = result:gsub('<[cC]%-', 'C-')
  result = result:gsub('<[mM]%-', 'M-')
  result = result:gsub('<CR>', '⏎')
  result = result:gsub('[<>]', '')

  return result
end

-- Cell actions for border hints (per cell type)
-- top_hint: type conversion (shown on top border after label)
-- bottom_left: execute + inspect (left-aligned with 4 space margin)
-- bottom_right: add cell below (right-aligned with 4 space margin)
local cell_actions = {
  code = {
    top_hint = { config_key = 'make_markdown', icon_key = 'to_markdown' },
    bottom_left = {
      { config_key = 'menu_execute_cell', icon_key = 'execute' },
      { config_key = 'menu_execute_and_next', icon_key = 'execute_next' },
      { config_key = 'open_output', icon_key = 'inspect', condition = 'has_output' },
    },
    bottom_right = { config_key = 'add_cell_below', icon_key = 'add' },
  },
  markdown = {
    top_hint = { config_key = 'make_code', icon_key = 'to_code' },
    bottom_left = {},
    bottom_right = { config_key = 'add_cell_below', icon_key = 'add' },
  },
  raw = {
    top_hint = { config_key = 'make_code', icon_key = 'to_code' },
    bottom_left = {},
    bottom_right = { config_key = 'add_cell_below', icon_key = 'add' },
  },
}

---Build a single hint from action definition
---@param action table Action definition with config_key and icon_key
---@param language string|nil Language for code cells
---@param config table Plugin config
---@return table|nil hint {icon, key} or nil
local function build_single_hint(action, language, config)
  local keymap = config.keymaps[action.config_key]
  if not keymap then
    return nil
  end

  local icon
  if action.icon_key == 'to_markdown' then
    icon = get_convert_icon('markdown')
  elseif action.icon_key == 'to_code' then
    icon = get_convert_icon('code', language)
  else
    icon = action_icons[action.icon_key]
  end

  return { icon = icon, key = format_keymap(keymap) }
end

---Build action hints for a cell (structured for layout)
---@param state NotebookState
---@param cell table Cell data
---@param cell_type string
---@param language string|nil
---@param config table Plugin config
---@return table hints { top_hint, bottom_left, bottom_right }
local function build_action_hints(state, cell, cell_type, language, config)
  local actions = cell_actions[cell_type]
  if not actions then
    return { top_hint = nil, bottom_left = {}, bottom_right = nil }
  end

  -- Check kernel state for code cells
  local kernel_connected = false
  if cell_type == 'code' then
    local kernel_ok, kernel = pcall(require, 'ipynb.kernel')
    if kernel_ok then
      kernel_connected = kernel.is_connected(state)
    end
  end

  local result = {
    top_hint = nil,
    bottom_left = {},
    bottom_right = nil,
  }

  -- Top hint (type conversion)
  if actions.top_hint then
    result.top_hint = build_single_hint(actions.top_hint, language, config)
  end

  -- Bottom left (execute + inspect)
  for _, action in ipairs(actions.bottom_left or {}) do
    -- Check condition (e.g., has_output)
    if action.condition == 'has_output' then
      if not cell.outputs or #cell.outputs == 0 then
        goto continue
      end
    end

    -- Swap execute for kernel_start if kernel not connected (only show power once)
    local effective_action = action
    if not kernel_connected then
      if action.config_key == 'menu_execute_cell' then
        effective_action = { config_key = 'kernel_start', icon_key = 'power' }
      elseif action.config_key == 'menu_execute_and_next' then
        goto continue  -- Skip execute_next when kernel not connected
      end
    end

    local hint = build_single_hint(effective_action, language, config)
    if hint then
      table.insert(result.bottom_left, hint)
    end

    ::continue::
  end

  -- Bottom right (add cell)
  if actions.bottom_right then
    result.bottom_right = build_single_hint(actions.bottom_right, language, config)
  end

  return result
end

---Setup highlight groups by linking to user-configured groups
---@param hl_config table|nil Highlight configuration (group names to link to)
function M.setup_highlights(hl_config)
  hl_config = hl_config or require('ipynb.config').get().highlights
  local set_hl = vim.api.nvim_set_hl

  -- Borders
  set_hl(0, 'IpynbBorder', { link = hl_config.border, default = true })
  set_hl(0, 'IpynbBorderHover', { link = hl_config.border_hover, default = true })
  set_hl(0, 'IpynbBorderActive', { link = hl_config.border_active, default = true })

  -- Output and status
  set_hl(0, 'IpynbExecCount', { link = hl_config.exec_count, default = true })
  set_hl(0, 'IpynbOutput', { link = hl_config.output, default = true })
  set_hl(0, 'IpynbOutputError', { link = hl_config.output_error, default = true })
  set_hl(0, 'IpynbExecuting', { link = hl_config.executing, default = true })
  set_hl(0, 'IpynbQueued', { link = hl_config.queued, default = true })

  -- Action hints
  set_hl(0, 'IpynbHint', { link = hl_config.hint, default = true })
end

---Get the visible text width for the current window
---@param win number|nil Window handle (nil for current)
---@return number
local function get_text_width(win)
  win = win or vim.api.nvim_get_current_win()
  local width = vim.api.nvim_win_get_width(win)
  local wininfo = vim.fn.getwininfo(win)[1]
  if wininfo then
    width = width - wininfo.textoff
  end
  return width
end

---Get display width of a string (handles multi-byte chars)
---@param str string
---@return number
local function display_width(str)
  return vim.fn.strdisplaywidth(str)
end

---Build top border string and highlight segments
---@param cell_type string
---@param execution_count number|nil
---@param execution_state string|nil
---@param width number
---@param border_hl string Border highlight group
---@param language string|nil Language for code cells
---@param top_hint table|nil Optional type conversion hint {icon, key}
---@return table[] Virtual text segments
local function build_top_border(cell_type, execution_count, execution_state, width, border_hl, language, top_hint)
  local icon = cell_icons[cell_type]
  local label_text = cell_type

  -- Use language-specific icon and label for code cells
  if cell_type == 'code' and language then
    icon = M.get_language_icon(language)
    label_text = language
  end

  -- Format label with or without icon
  local label = icon and string.format(' %s %s ', icon, label_text) or string.format(' %s ', label_text)

  -- Build hint string if provided (3 border chars touching bracket)
  local hint_prefix = ''
  local hint_text = ''
  if top_hint then
    hint_prefix = string.rep(borders.horizontal, 3)
    hint_text = string.format('[%s %s]', top_hint.icon, top_hint.key)
  end

  -- Build right side: execution state and/or count with border touching brackets
  local right_parts = {}
  local right_str = ''

  -- Add execution state indicator for code cells
  if cell_type == 'code' and execution_state and execution_state ~= 'idle' then
    local state_icon = exec_icons[execution_state] or ''
    if state_icon ~= '' then
      local state_str = '[' .. state_icon .. ']'
      right_str = right_str .. state_str .. borders.horizontal
      table.insert(right_parts, {
        text = state_str,
        hl = execution_state == 'busy' and 'IpynbExecuting' or 'IpynbQueued',
      })
      table.insert(right_parts, { text = borders.horizontal, hl = border_hl })
    end
  end

  -- Add execution count for code cells
  if cell_type == 'code' and execution_count and execution_count ~= vim.NIL then
    local count_str = string.format('[%d]', execution_count)
    right_str = right_str .. count_str .. borders.horizontal
    table.insert(right_parts, { text = count_str, hl = 'IpynbExecCount' })
    table.insert(right_parts, { text = borders.horizontal, hl = border_hl })
  end

  local left = borders.top_left
  local right = borders.top_right

  -- Calculate fill width using display width for proper unicode handling
  local used_width = display_width(left) + display_width(label) + display_width(hint_prefix) + display_width(hint_text) + display_width(right_str) + display_width(right)
  local fill_width = width - used_width
  if fill_width < 0 then fill_width = 0 end

  local fill = string.rep(borders.horizontal, fill_width)

  -- Build segments for virtual text
  local segments = {
    { left .. label, border_hl },
  }

  -- Add hint if provided (prefix in border color, text in hint color)
  if top_hint and fill_width >= 0 then
    table.insert(segments, { hint_prefix, border_hl })
    table.insert(segments, { hint_text, 'IpynbHint' })
  end

  table.insert(segments, { fill, border_hl })

  -- Add right parts with their highlights
  for _, part in ipairs(right_parts) do
    table.insert(segments, { part.text, part.hl })
  end

  table.insert(segments, { right, border_hl })

  return segments
end

---Build bottom border with action hints
---Layout: ╰──── [󰐊 ␣kx]  [󰍉 ␣ko] ──────────────── [󰐕 ␣kb] ────╯
---        4 space margin, left hints, fill, right hint, 4 space margin
---@param width number
---@param border_hl string
---@param hints table|nil Structured hints { bottom_left = {}, bottom_right = {} }
---@return table[] Virtual text segments
local function build_bottom_border_with_hints(width, border_hl, hints)
  local left = borders.bottom_left
  local right = borders.bottom_right
  local left_margin_size = 3
  local right_margin_size = 4

  -- Check if we have any hints to show
  local has_left = hints and hints.bottom_left and #hints.bottom_left > 0
  local has_right = hints and hints.bottom_right

  if not has_left and not has_right then
    -- Simple border, no hints
    local fill_width = width - display_width(left) - display_width(right)
    if fill_width < 0 then fill_width = 0 end
    local fill = string.rep(borders.horizontal, fill_width)
    return { { left .. fill .. right, border_hl } }
  end

  -- Build left hints as segments: [󰐊 ␣kx]──[󰍉 ␣ko] (2-char separator in border color)
  local left_segments = {}
  local left_width = 0
  local separator = string.rep(borders.horizontal, 2)
  if has_left then
    for i, hint in ipairs(hints.bottom_left) do
      if i > 1 then
        -- Add 2-char separator in border color
        table.insert(left_segments, { separator, border_hl })
        left_width = left_width + display_width(separator)
      end
      local hint_str = string.format('[%s %s]', hint.icon, hint.key)
      table.insert(left_segments, { hint_str, 'IpynbHint' })
      left_width = left_width + display_width(hint_str)
    end
  end

  -- Build right hint string: [󰐕 ␣kb]
  local right_str = ''
  if has_right then
    right_str = string.format('[%s %s]', hints.bottom_right.icon, hints.bottom_right.key)
  end

  -- Calculate fill width
  -- Layout: left_corner + margin + left_hints + fill + right_hint + margin + right_corner
  local left_margin = string.rep(borders.horizontal, left_margin_size)
  local right_margin = string.rep(borders.horizontal, right_margin_size)
  local used_width = display_width(left) + display_width(left_margin) + left_width
    + display_width(right_str) + display_width(right_margin) + display_width(right)
  local fill_width = width - used_width
  if fill_width < 0 then fill_width = 0 end

  -- Don't show hints if not enough space
  if fill_width < 2 then
    local simple_fill = width - display_width(left) - display_width(right)
    if simple_fill < 0 then simple_fill = 0 end
    return { { left .. string.rep(borders.horizontal, simple_fill) .. right, border_hl } }
  end

  local fill = string.rep(borders.horizontal, fill_width)

  -- Build segments
  local segments = {
    { left .. left_margin, border_hl },
  }

  -- Add left hint segments
  for _, seg in ipairs(left_segments) do
    table.insert(segments, seg)
  end

  table.insert(segments, { fill, border_hl })

  if has_right then
    table.insert(segments, { right_str, 'IpynbHint' })
  end

  table.insert(segments, { right_margin .. right, border_hl })

  return segments
end

---Render visual decorations for a single cell
---@param state NotebookState
---@param cell_idx number
---@param is_active boolean
---@param target_buf number|nil Optional target buffer (defaults to state.facade_buf)
function M.render_cell(state, cell_idx, is_active, target_buf)
  local cell = state.cells[cell_idx]
  local cells_mod = require('ipynb.cells')
  local start_line, end_line = cells_mod.get_cell_range(state, cell_idx)

  -- Skip if cell range is invalid
  if not start_line or not end_line then
    return
  end

  local content_start, content_end = cells_mod.get_content_range(state, cell_idx)
  if not content_start or not content_end then
    return
  end

  local buf = target_buf or state.facade_buf

  -- Validate line numbers are within buffer bounds
  local line_count = vim.api.nvim_buf_line_count(buf)
  if end_line >= line_count or content_end >= line_count then
    return
  end

  local width = get_text_width()

  -- Choose highlights based on state:
  -- - Inactive: cursor not on this cell
  -- - Hover: cursor on cell but not editing
  -- - Active: editing this cell in float
  local border_hl = 'IpynbBorder'
  if is_active then
    local is_editing = state.edit_state and state.edit_state.cell_idx == cell_idx
    border_hl = is_editing and 'IpynbBorderActive' or 'IpynbBorderHover'
  end

  -- Helper to safely get line length
  local function get_line_length(line_nr)
    local lines = vim.api.nvim_buf_get_lines(buf, line_nr, line_nr + 1, false)
    return lines[1] and #lines[1] or 0
  end

  -- Determine if we should show action hints
  local language = vim.b[buf].ipynb_language
  local config = require('ipynb.config').get()
  local hints_config = config.border_hints
  local hints = nil

  if is_active and hints_config.enabled then
    local is_editing = state.edit_state and state.edit_state.cell_idx == cell_idx
    local show_hints = (is_editing and hints_config.show_on_edit)
      or (not is_editing and hints_config.show_on_hover)

    if show_hints then
      hints = build_action_hints(state, cell, cell.type, language, config)
    end
  end

  -- Conceal and replace start marker line with top border
  -- Priority 150 = higher than treesitter (100) to override syntax highlighting
  local top_hint = hints and hints.top_hint or nil
  local top_border_segments = build_top_border(
    cell.type, cell.execution_count, cell.execution_state, width, border_hl, language, top_hint
  )
  vim.api.nvim_buf_set_extmark(buf, visual_ns, start_line, 0, {
    end_row = start_line,
    end_col = get_line_length(start_line),
    conceal = '',
    priority = 150,
  })
  vim.api.nvim_buf_set_extmark(buf, visual_ns, start_line, 0, {
    virt_text = top_border_segments,
    virt_text_pos = 'overlay',
    priority = 150,
  })

  -- Conceal and replace end marker line with bottom border
  local bottom_border_segments = build_bottom_border_with_hints(width, border_hl, hints)
  vim.api.nvim_buf_set_extmark(buf, visual_ns, end_line, 0, {
    end_row = end_line,
    end_col = get_line_length(end_line),
    conceal = '',
    priority = 150,
  })
  vim.api.nvim_buf_set_extmark(buf, visual_ns, end_line, 0, {
    virt_text = bottom_border_segments,
    virt_text_pos = 'overlay',
    priority = 150,
  })

  -- Left border on content lines using sign column
  for line = content_start, content_end do
    vim.api.nvim_buf_set_extmark(buf, visual_ns, line, 0, {
      sign_text = borders.vertical,
      sign_hl_group = border_hl,
    })
  end
end

---Clear extmarks for specific cells only
---@param buf number Buffer handle
---@param state NotebookState
---@param cell_indices number[] Cell indices to clear
local function clear_cells_extmarks(buf, state, cell_indices)
  local cells_mod = require('ipynb.cells')
  for _, idx in ipairs(cell_indices) do
    local start_line, end_line = cells_mod.get_cell_range(state, idx)
    if start_line and end_line then
      vim.api.nvim_buf_clear_namespace(buf, visual_ns, start_line, end_line + 1)
    end
  end
end

---Render all cells (full re-render, used for initial load and structural changes)
---@param state NotebookState
---@param cell_indices number[]|nil Optional list of cell indices to render (nil = all)
function M.render_all(state, cell_indices)
  local buf = state.facade_buf
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  -- Find active cell (hover or editing)
  local active_idx = nil
  if state.edit_state then
    -- Editing: the cell being edited is active
    active_idx = state.edit_state.cell_idx
  else
    -- Not editing: cell under cursor is active (hover)
    local win = vim.api.nvim_get_current_win()
    if vim.api.nvim_win_get_buf(win) == buf then
      local cursor_line = vim.api.nvim_win_get_cursor(win)[1] - 1
      active_idx = require('ipynb.cells').get_cell_at_line(state, cursor_line)
    end
  end

  if cell_indices then
    -- Selective render: only clear and render specified cells
    clear_cells_extmarks(buf, state, cell_indices)
    for _, i in ipairs(cell_indices) do
      if state.cells[i] then
        M.render_cell(state, i, i == active_idx)
      end
    end
  else
    -- Full render: clear everything and render all
    vim.api.nvim_buf_clear_namespace(buf, visual_ns, 0, -1)

    for i, _ in ipairs(state.cells) do
      M.render_cell(state, i, i == active_idx)
    end
  end
end

---Render only visible cells (viewport-based, used for scroll/cursor updates)
---@param state NotebookState
function M.render_visible(state)
  local buf = state.facade_buf
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  -- Don't update while in edit mode
  if state.edit_state then
    return
  end

  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(win) ~= buf then
    return
  end

  local visible_cells = get_visible_cells(state)
  if #visible_cells == 0 then
    return
  end

  M.render_all(state, visible_cells)
end

---Setup autocmd for active cell tracking (call once during buffer setup)
---@param state NotebookState
function M.setup_active_tracking(state)
  local buf = state.facade_buf

  -- Remove existing autocmds for this buffer
  pcall(vim.api.nvim_del_augroup_by_name, 'NotebookActive' .. buf)

  local group = vim.api.nvim_create_augroup('NotebookActive' .. buf, { clear = true })

  -- Create throttled version of render_visible for this buffer
  local throttled_render = create_throttle(buf, function()
    M.render_visible(state)
  end)

  -- CursorMoved fires on every cursor movement (including during scroll)
  -- WinScrolled fires when scrolling without cursor movement (<C-e>, <C-y>, mouse)
  vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI', 'WinScrolled' }, {
    group = group,
    buffer = buf,
    callback = function()
      throttled_render()
    end,
  })

  -- Re-render on window resize to update border widths (not throttled)
  vim.api.nvim_create_autocmd('WinResized', {
    group = group,
    callback = function()
      if not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      local state_mod = require('ipynb.state')
      local current_state = state_mod.get(buf)
      if current_state and current_state.cells and #current_state.cells > 0 then
        -- Full re-render on resize since border widths change
        M.render_all(current_state)
      end
    end,
  })

  -- Cleanup throttle state when buffer is deleted
  vim.api.nvim_create_autocmd('BufDelete', {
    group = group,
    buffer = buf,
    callback = function()
      cleanup_throttle(buf)
    end,
  })
end

---Clear visual decorations
---@param state NotebookState
function M.clear(state)
  vim.api.nvim_buf_clear_namespace(state.facade_buf, visual_ns, 0, -1)
end

return M
