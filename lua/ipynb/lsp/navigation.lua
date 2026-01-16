-- ipynb/lsp/navigation.lua - Window/cursor redirection for edit float navigation
-- When LSP navigates from edit float, redirect to facade window
-- Handles nvim_win_set_buf, nvim_win_set_cursor, vim._with, show_document

local M = {}

-- Track redirected windows (edit float win -> facade win)
local redirected_wins = {}

---Install the window/cursor redirection wrappers
function M.install()
  local state_mod = require('ipynb.state')
  local uri_mod = require('ipynb.lsp.uri')

  -- Store original functions
  local orig_win_set_buf = vim.api.nvim_win_set_buf
  local orig_win_set_cursor = vim.api.nvim_win_set_cursor
  local orig_with = vim._with
  local orig_show_document = vim.lsp.util.show_document

  -- Wrap nvim_win_set_buf to handle LSP navigation from edit floats
  -- When get_locations() tries to set the facade buffer in an edit float window,
  -- we close the edit float and navigate in the facade window instead
  vim.api.nvim_win_set_buf = function(win, buf)
    -- Check if target buffer is a facade buffer
    local target_state = state_mod.get_by_facade(buf)
    if target_state and target_state.edit_state then
      -- Check if target window is the edit float
      local edit = target_state.edit_state
      if edit.win == win then
        local parent_win = edit.parent_win

        -- Track the redirect so nvim_win_set_cursor can use the right window
        redirected_wins[win] = parent_win

        -- Close the edit float
        require('ipynb.edit').close(target_state)

        -- Use facade window instead
        if parent_win and vim.api.nvim_win_is_valid(parent_win) then
          return orig_win_set_buf(parent_win, buf)
        end
      end
    end

    return orig_win_set_buf(win, buf)
  end

  -- Wrap nvim_win_set_cursor to handle redirected windows
  vim.api.nvim_win_set_cursor = function(win, pos)
    -- Check if this window was redirected (edit float -> facade)
    local redirect_win = redirected_wins[win]
    if redirect_win then
      -- Don't clear yet - vim._with may also need it
      if vim.api.nvim_win_is_valid(redirect_win) then
        return orig_win_set_cursor(redirect_win, pos)
      end
      return -- Window invalid, skip cursor set
    end

    -- Check if window is invalid but we might have a redirect
    if not vim.api.nvim_win_is_valid(win) then
      return -- Silently ignore invalid windows
    end

    return orig_win_set_cursor(win, pos)
  end

  -- Wrap vim._with to handle redirected windows
  -- This is used by get_locations() to set jumplist/tagstack in window context
  vim._with = function(context, func)
    if context and context.win then
      local redirect_win = redirected_wins[context.win]
      if redirect_win then
        redirected_wins[context.win] = nil -- Clear after final use
        if vim.api.nvim_win_is_valid(redirect_win) then
          context = vim.tbl_extend('force', context, { win = redirect_win })
        else
          -- Window invalid, skip the _with call
          return
        end
      elseif not vim.api.nvim_win_is_valid(context.win) then
        -- Invalid window with no redirect, skip
        return
      end
    end
    return orig_with(context, func)
  end

  -- Wrap show_document to handle edit float context and shadow->facade translation
  -- When jumping to a location in edit buffer or shadow buffer, translate to facade
  -- and re-open edit float at the target location
  vim.lsp.util.show_document = function(location, offset_encoding, opts)
    opts = opts or {}
    local uri = location.uri or location.targetUri

    -- Skip custom handling for our nb:// URIs during preview
    -- fzf-lua calls show_document from preview windows - we should let it handle that normally
    -- Only intercept when we're actually navigating from our facade/edit buffers
    local current_win = vim.api.nvim_get_current_win()
    local current_buf = vim.api.nvim_get_current_buf()

    -- First, check if we're in our edit float - if so, we WANT custom handling
    -- to close the float and navigate to the facade
    local edit_state = state_mod.get_from_edit_buf(current_buf)
    local in_our_edit_float = edit_state and edit_state.edit_state and edit_state.edit_state.buf == current_buf

    -- Check if we're in a floating window (likely preview) - skip custom handling
    -- But NOT if we're in our own edit float
    local win_config = vim.api.nvim_win_get_config(current_win)
    if win_config.relative and win_config.relative ~= '' and not in_our_edit_float then
      -- We're in a floating window (preview), use default behavior
      -- But for our custom URI, we need BufReadCmd to handle it
      return orig_show_document(location, offset_encoding, opts)
    end

    -- Try to get state from current buffer (facade or edit buffer)
    local state = state_mod.get(current_buf) or edit_state

    -- If no state from current buffer, try to find it from the location URI
    if not state and uri then
      -- Check for our custom facade URI scheme first
      local facade_path = uri_mod.parse_facade_uri(uri)
      if facade_path then
        state = state_mod.get_by_path(facade_path)
      else
        -- Standard file:// URI
        local path = vim.uri_to_fname(uri)
        state = state_mod.get_by_path(path)
      end
    end

    -- Check if we're in an edit float and need to close it
    if state and state.edit_state and state.edit_state.buf == current_buf then
      local edit = state.edit_state
      local parent_win = edit.parent_win

      -- Close the edit float
      require('ipynb.edit').close(state)

      -- Ensure we're in the facade window
      if vim.api.nvim_win_is_valid(parent_win) then
        vim.api.nvim_set_current_win(parent_win)
      end
    end

    -- Helper to jump to facade and re-enter edit float
    local function jump_to_facade_and_edit(target_state, facade_line, col)
      -- Find facade window
      local facade_win = nil
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(win) == target_state.facade_buf then
          facade_win = win
          break
        end
      end

      if facade_win then
        vim.api.nvim_set_current_win(facade_win)
      else
        vim.api.nvim_set_current_buf(target_state.facade_buf)
      end

      vim.api.nvim_win_set_cursor(0, { facade_line, col })

      -- Re-enter edit float at the target location
      -- NOTE: Only do this if we were in an edit float before navigation
      -- If navigating from facade buffer, don't auto-open edit float
      local was_in_edit = target_state.edit_state ~= nil
      if was_in_edit then
        vim.schedule(function()
          pcall(function()
            local edit_mod = require('ipynb.edit')
            edit_mod.open(target_state)
          end)
        end)
      end

      return true
    end

    -- Check if location points to an edit buffer, shadow buffer, or facade
    -- (uri was already extracted above for state lookup)
    if uri and state then
      -- Handle our custom facade URI scheme
      local path = uri_mod.parse_facade_uri(uri) or vim.uri_to_fname(uri)

      -- Check if this is our custom facade URI - jump directly to facade
      if uri_mod.is_facade_uri(uri) then
        local range = location.range or location.targetSelectionRange or location.targetRange
        if range then
          local line = range.start.line + 1 -- LSP is 0-indexed
          return jump_to_facade_and_edit(state, line, range.start.character)
          -- nb:// buffer cleanup is handled by WinEnter autocmd on facade buffer
        end
      end

      -- Check if this is an edit buffer location (pattern: [notebook.ipynb:cell_xxx])
      local notebook_name, cell_id = path:match('%[([^:]+%.ipynb):([^%]]+)%]$')
      if notebook_name and cell_id then
        local state_notebook_name = state.source_path and vim.fn.fnamemodify(state.source_path, ':t')
        if state_notebook_name == notebook_name then
          -- Find the cell by ID and get its content start line
          local cells_mod = require('ipynb.cells')
          for cell_idx, cell in ipairs(state.cells) do
            if cell.id == cell_id then
              local content_start, _ = cells_mod.get_content_range(state, cell_idx)
              if content_start then
                local range = location.range or location.targetSelectionRange or location.targetRange
                if range then
                  local edit_line = range.start.line + 1 -- LSP 0-indexed to 1-indexed
                  local facade_line = content_start + edit_line
                  return jump_to_facade_and_edit(state, facade_line, range.start.character)
                end
              end
              break
            end
          end
        end
      end

      -- Check if location points to shadow buffer
      if state.shadow_path and path == state.shadow_path then
        local range = location.range or location.targetSelectionRange or location.targetRange
        if range then
          local line = range.start.line + 1 -- LSP is 0-indexed
          return jump_to_facade_and_edit(state, line, range.start.character)
        end
      end

      -- Check if location points to facade path (.ipynb file)
      -- This happens after rewrite_result_uris converts shadow URIs to facade URIs
      -- Normalize both paths for comparison (handle relative vs absolute)
      local facade_path_norm = state.facade_path and vim.fn.fnamemodify(state.facade_path, ':p')
      local normalized_path = vim.fn.fnamemodify(path, ':p')
      if facade_path_norm and normalized_path == facade_path_norm then
        local range = location.range or location.targetSelectionRange or location.targetRange
        if range then
          local line = range.start.line + 1 -- LSP is 0-indexed
          return jump_to_facade_and_edit(state, line, range.start.character)
        end
      end
    end

    return orig_show_document(location, offset_encoding, opts)
  end
end

return M
