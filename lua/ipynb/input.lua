-- ipynb/input.lua - Kernel stdin input UI

local M = {}

local function leave_insert_mode()
  local mode = vim.api.nvim_get_mode().mode
  local head = mode:sub(1, 1)
  if head == "i" or head == "R" then
    pcall(vim.cmd, "stopinsert")
  end
end

---@param prompt string|nil
---@return string
local function normalize_prompt(prompt)
  local p = prompt or "Input: "
  p = p:gsub("\r", "")
  p = p:gsub("\n", " ")
  if p == "" then
    p = "Input: "
  end
  return p
end

---@param state NotebookState
local function close_state_prompt(state)
  if not state or not state._input_state then
    return
  end

  leave_insert_mode()

  local prompt_state = state._input_state
  state._input_state = nil

  if prompt_state.win and vim.api.nvim_win_is_valid(prompt_state.win) then
    pcall(vim.api.nvim_win_close, prompt_state.win, true)
  end
  if prompt_state.buf and vim.api.nvim_buf_is_valid(prompt_state.buf) then
    pcall(vim.api.nvim_buf_delete, prompt_state.buf, { force = true })
  end

  if prompt_state.parent_win and vim.api.nvim_win_is_valid(prompt_state.parent_win) then
    pcall(vim.api.nvim_set_current_win, prompt_state.parent_win)
  end
end

---Close the currently active kernel input prompt, if any.
---@param state NotebookState
function M.close(state)
  close_state_prompt(state)
end

---Open a prompt for kernel stdin input.
---@param state NotebookState
---@param request table { request_id: string, prompt: string|nil, password: boolean|nil }
---@param on_submit fun(value: string)
---@param on_cancel fun()|nil
function M.request(state, request, on_submit, on_cancel)
  close_state_prompt(state)

  local prompt = normalize_prompt(request and request.prompt or nil)
  local is_password = request and request.password == true

  if is_password then
    local ok, value = pcall(vim.fn.inputsecret, prompt)
    if ok then
      on_submit(value or "")
    else
      if on_cancel then
        on_cancel()
      end
    end
    return
  end

  local parent_win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)

  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })

  local min_width = 24
  local max_width = math.max(min_width, math.floor(vim.o.columns * 0.65))
  local prompt_width = vim.fn.strdisplaywidth(prompt)
  local width = math.max(min_width, math.min(max_width, prompt_width + 8))
  local row = math.max(0, math.floor((vim.o.lines - 1) / 2) - 1)
  local col = math.max(0, math.floor((vim.o.columns - width) / 2))

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = 1,
    style = "minimal",
    border = "rounded",
    title = " " .. prompt .. " ",
    title_pos = "left",
    zindex = 45,
  })

  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = false

  state._input_state = {
    buf = buf,
    win = win,
    parent_win = parent_win,
    request_id = request and request.request_id or nil,
  }

  local done = false

  local function finish_cancel()
    if done then
      return
    end
    done = true
    close_state_prompt(state)
    if on_cancel then
      on_cancel()
    end
  end

  local function finish_submit()
    if done then
      return
    end
    done = true
    local line = ""
    if vim.api.nvim_buf_is_valid(buf) then
      line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
    end
    close_state_prompt(state)
    on_submit(line)
  end

  local group = vim.api.nvim_create_augroup("IpynbInput_" .. tostring(buf), { clear = true })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(ev)
      if tonumber(ev.match) == win then
        finish_cancel()
      end
    end,
  })

  local opts = { buffer = buf, silent = true, nowait = true }
  vim.keymap.set({ "n", "i" }, "<CR>", finish_submit, opts)
  vim.keymap.set({ "n", "i" }, "<C-c>", finish_cancel, opts)
  vim.keymap.set({ "n", "i" }, "<Esc>", finish_cancel, opts)
  vim.keymap.set("n", "q", finish_cancel, opts)

  vim.cmd("startinsert")
end

return M
