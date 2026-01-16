# Neovim Jupyter Notebook Plugin Architecture

## Overview

A modal Jupyter notebook editor for Neovim with partial LSP support.

### Design Principles

1. **Facade buffer as source of truth** - Single buffer in custom notebook format (user-facing view)
2. **Modal cell editing** - Floating window for editing, facade for navigation
3. **Shadow buffer for LSP** - Hidden buffer with code cells only (markdown → blank lines), LSP attaches here
4. **Line-synchronized** - Shadow and facade have identical line counts (1:1 position mapping)
5. **Lazy edit buffers** - Cell content loaded into float on demand

---

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              .ipynb File                                    │
└──────────────────────────────────┬──────────────────────────────────────────┘
                                   │
                         ┌─────────┴─────────┐
                         │     File I/O      │
                         │  ipynb ↔ jupytext │
                         └─────────┬─────────┘
                                   │
          ┌────────────────────────┴────────────────────────┐
          ▼                                                 ▼
┌───────────────────────────────────┐    ┌───────────────────────────────────┐
│    Facade Buffer (user-facing)    │    │   Shadow Buffer (LSP-facing)      │
│  ┌─────────────────────────────┐  │    │  ┌─────────────────────────────┐  │
│  │ # <<ipynb_nvim:markdown>>   │  │    │  │                             │  │
│  │ # # Notebook Title          │  │    │  │                             │  │
│  │ # Description here          │  │    │  │                             │  │
│  │ ════════════════════════════│  │    │  │                             │  │
│  │ # <<ipynb_nvim:code>>       │  │    │  │                             │  │
│  │ import numpy as np          │◄─┼────┼─►│ import numpy as np          │  │
│  │                             │  │    │  │                             │  │
│  │ def foo():                  │◄─┼────┼─►│ def foo():                  │  │
│  │     return 42               │◄─┼────┼─►│     return 42               │  │
│  │ ════════════════════════════│  │    │  │                             │  │
│  │ # <<ipynb_nvim:markdown>>   │  │    │  │                             │  │
│  │ # More docs                 │  │    │  │                             │  │
│  │ ════════════════════════════│  │    │  │                             │  │
│  │ # <<ipynb_nvim:code>>       │  │    │  │                             │  │
│  │ result = foo()              │◄─┼────┼─►│ result = foo()              │  │
│  └─────────────────────────────┘  │    │  └─────────────────────────────┘  │
│                                   │    │                                   │
│  • User sees this buffer          │    │  • Hidden buffer (not displayed)  │
│  • Markdown cells show content    │    │  • Markdown cells = blank lines   │
│  • Visual decorations/borders     │    │  • LSP attached here (any lang)   │
│  • Treesitter language injection  │    │  • Same line count as facade      │
└───────────────────────────────────┘    └───────────────────────────────────┘
          │                                          │
          │         ┌────────────────────────────────┘
          │         │
          ▼         ▼
    ┌───────────────────────┐
    │    LSP Proxy Layer    │
    │  • Requests: facade → shadow buffer (position unchanged)
    │  • Responses: shadow → facade buffer (position unchanged)
    │  • Diagnostics: filter markdown cells from display
    └───────────────────────┘
          │
          ├──────────────────────────────────┐
          ▼                                  ▼
    ┌─────────────┐                    ┌───────────┐
    │ Edit Float  │                    │  Kernel   │
    │ (code cell) │                    │ Execution │
    └─────────────┘                    └───────────┘
```

**Key insight:** Shadow buffer maintains 1:1 line mapping with facade. Line N in facade = Line N in shadow.
This eliminates position translation complexity - LSP positions work directly.

---

## Feasibility Summary (Verified with Neovim API)

| Component | Feasibility | Key API | Notes |
|-----------|-------------|---------|-------|
| Facade buffer | ✅ Verified | Original .ipynb path + `modifiable=false` | Keeps real path for plugin compatibility |
| Edit float with LSP context | ✅ Verified | `nvim_buf_attach` sync pattern | Sync edits to facade in real-time |
| Extmark cell tracking | ✅ Verified | `nvim_buf_set_extmark` with `right_gravity=false` | Handles 100+ cells efficiently |
| Cell visual borders | ✅ Verified | `virt_lines` extmarks | Full-width separator lines |
| Cell backgrounds | ✅ Verified | `line_hl_group` with `end_row` | Multi-line highlight ranges |
| Active cell highlight | ✅ Verified | Reuse extmark ID on `CursorMoved` | Single extmark that moves |
| Seamless float positioning | ✅ Verified | `relative='win'` + `bufpos` | Anchors to buffer position |
| Markdown highlighting | ✅ Verified | Custom tree-sitter grammar | Language injection for code/markdown cells |

---

## Module Structure

```
lua/ipynb/
├── init.lua           # Plugin entry, setup(), treesitter registration
├── config.lua         # User configuration, defaults
├── state.lua          # Notebook state management
├── io.lua             # File I/O (ipynb ↔ jupytext format)
├── facade.lua         # Facade buffer rendering, treesitter activation
├── cells.lua          # Cell boundary tracking (extmarks)
├── edit.lua           # Edit float management
├── lsp/               # LSP integration (modular)
│   ├── init.lua       # Public API, orchestrates submodules
│   ├── util.lua       # Shared helpers (resolve_bufnr, get_buffer_context)
│   ├── shadow.lua     # Shadow buffer creation and management
│   ├── uri.lua        # nb:// URI scheme, BufReadCmd, result rewriting
│   ├── request.lua    # Core request proxying, interceptor registry
│   ├── navigation.lua # Window/cursor redirection for edit float
│   ├── format.lua     # Cell formatting, vim.lsp.buf.format wrapper
│   ├── diagnostics.lua# Diagnostics forwarding to facade
│   └── completion.lua # Completion and edit buffer diagnostics
├── visuals.lua        # Cell decorations, borders, highlights
├── markdown.lua       # Minimal stub (treesitter handles highlighting)
├── keymaps.lua        # Keymap definitions
├── kernel.lua         # Jupyter kernel connection (per-notebook state)
├── output.lua         # Cell output rendering
├── images.lua         # Image output rendering (via snacks.nvim)
├── inspector.lua      # Variable inspector (Jupyter inspect protocol)
├── folding.lua        # Cell folding support
├── picker.lua         # Cell picker (vim.ui.select)
├── commands.lua       # User commands
├── health.lua         # Health check (:checkhealth ipynb)
└── debug.lua          # Debug utilities (check_treesitter, show_tree)

tree-sitter-ipynb/
├── grammar.js         # Tree-sitter grammar definition (language-agnostic cell parsing)
├── src/
│   ├── parser.c       # Generated parser
│   └── scanner.c      # External scanner for content/end detection
├── queries/ipynb/
│   ├── highlights.scm # Syntax highlighting queries
│   ├── injections.scm # Dynamic language injection via custom directive
│   └── folds.scm      # Folding queries (cell content only)
└── parser.so          # Local dev build (not shipped - auto-compiled via nvim-treesitter)

tests/
├── run_all.sh         # Test runner script (./tests/run_all.sh)
├── minimal_init.lua   # Minimal Neovim config for headless tests
├── helpers.lua        # Test helper functions
├── fixtures/          # Test notebook files (.ipynb)
├── test_cells.lua     # Cell boundary tracking tests
├── test_modified.lua  # Buffer modification detection tests
├── test_undo.lua      # Undo/redo functionality tests
├── test_lsp.lua       # LSP proxy and shadow buffer tests
├── test_treesitter.lua    # Treesitter parser tests
└── test_kernel_bridge.py  # Kernel bridge tests (Python)
```

---

### 1b. Cell Identity

Each cell has a unique `id` field generated at creation time:

```lua
-- Format: cell_<timestamp>_<counter>
cell.id = string.format('cell_%d_%d', vim.loop.now(), counter)
```

**Why unique IDs matter:**

- Images are stored in `state.images` keyed by `cell.id`
- When cells are moved/inserted/deleted, indices change but IDs persist
- `sync_cells_from_facade` matches cells by content to preserve IDs across undo
- Outputs, edit buffers, and extmarks stay associated with the correct cell
- Edit state tracks `cell_id` to find the correct cell after undo/redo

**ID lifecycle:**

- Generated when cell is created (`insert_cell`, `read_ipynb`)
- Preserved during `sync_cells_from_facade` by:
  1. First trying to match by content (exact source match)
  2. Falling back to position-based matching (same index, same type)
- New ID generated only if no matching old cell found

---

### 2. File I/O (`io.lua`)

**Notebook Format** (jupytext-inspired with explicit end markers):

```python
# <<ipynb_nvim:markdown>>
# Notebook Title
Some description with **bold** text
# <</ipynb_nvim>>
# <<ipynb_nvim:code>>
import numpy as np

def process(data):
    return data * 2
# <</ipynb_nvim>>
# <<ipynb_nvim:markdown>>
## Results Section
# <</ipynb_nvim>>
# <<ipynb_nvim:code>>
result = process(np.array([1, 2, 3]))
print(result)
# <</ipynb_nvim>>
```

**Format notes:**

- Cell start: `# <<ipynb_nvim:code>>` (code) or `# <<ipynb_nvim:markdown>>` / `# <<ipynb_nvim:raw>>`
- Cell end: `# <</ipynb_nvim>>` (custom marker)
- Markdown/raw cells: Content stored as-is (no `#` prefix on each line)
- Note: Traditional jupytext uses `#` prefix on markdown lines to keep the file valid Python.
  A future enhancement could add an optional flag to enable prefix commenting for compatibility.

**Key Functions:**

```lua
M.read_ipynb(path) -> cells[]
M.write_ipynb(path, cells[])
M.cells_to_jupytext(cells[]) -> lines[]
M.jupytext_to_cells(lines[]) -> cells[]
```

**Implementation Notes:**

- Parse .ipynb JSON using `vim.json.decode`
- Convert cell source arrays to strings
- Handle cell metadata preservation
- Track execution counts for code cells

---

### 3. Facade Buffer (`facade.lua`)

**Creation (keeps original .ipynb path for plugin compatibility):**

```lua
function M.create(state, buf)
  -- Use provided buffer (already named by :edit command)
  buf = buf or vim.api.nvim_create_buf(true, false)
  state.facade_buf = buf

  -- Keep original .ipynb path - ensures root detection, statusline, etc. work
  state.facade_path = state.source_path

  -- Convert cells to jupytext and populate
  local lines = require('ipynb.io').cells_to_jupytext(state.cells)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  -- Configure buffer
  vim.bo[buf].filetype = 'ipynb'  -- Custom filetype, LSP attaches to shadow buffer
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true

  return buf
end
```

**Update (when cell content changes):**

```lua
function M.update_region(state, start_line, end_line, new_lines)
  vim.schedule(function()
    vim.bo[state.facade_buf].modifiable = true
    vim.api.nvim_buf_set_lines(state.facade_buf, start_line, end_line, false, new_lines)
    vim.bo[state.facade_buf].modifiable = false
  end)
end
```

---

### 4. Cell Tracking (`cells.lua`)

**Extmark-based boundary tracking:**

```lua
function M.place_markers(state)
  local ns = state.namespace
  local line = 0

  for i, cell in ipairs(state.cells) do
    cell.extmark_id = vim.api.nvim_buf_set_extmark(state.facade_buf, ns, line, 0, {
      right_gravity = false,   -- Stays put when text inserted at position
      invalidate = true,       -- Mark invalid if cell deleted
      undo_restore = true,     -- Restore on undo
    })
    line = line + M.count_cell_lines(cell) + 1  -- +1 for # <<ipynb_nvim:code>> header
  end
end

function M.get_cell_at_line(state, target_line)
  -- Find cell whose start is at or before target_line
  local marks = vim.api.nvim_buf_get_extmarks(
    state.facade_buf, state.namespace,
    {target_line, 0}, 0,  -- Search backwards from target
    {limit = 1}
  )
  if #marks == 0 then return nil end

  local mark_id = marks[1][1]
  for i, cell in ipairs(state.cells) do
    if cell.extmark_id == mark_id then
      return i, cell
    end
  end
end

function M.get_cell_range(state, cell_idx)
  local cell = state.cells[cell_idx]
  local pos = vim.api.nvim_buf_get_extmark_by_id(
    state.facade_buf, state.namespace, cell.extmark_id, {}
  )
  local start_line = pos[1]

  -- Find next cell's start or end of buffer
  local end_line
  if cell_idx < #state.cells then
    local next_cell = state.cells[cell_idx + 1]
    local next_pos = vim.api.nvim_buf_get_extmark_by_id(
      state.facade_buf, state.namespace, next_cell.extmark_id, {}
    )
    end_line = next_pos[1] - 1
  else
    end_line = vim.api.nvim_buf_line_count(state.facade_buf) - 1
  end

  return start_line, end_line
end
```

---

### 5. Edit Float (`edit.lua`)

The edit float overlays directly on top of the cell content in the facade buffer,
creating a seamless editing experience. The float uses `relative='win'` with `bufpos`
to anchor precisely to the cell location.

**Opening the editor:**

```lua
function M.open(state, mode)
  local cells_mod = require('ipynb.cells')
  local cell_idx, cell = cells_mod.get_cell_at_line(state, cursor_line)

  -- Get cell content range (excludes start/end markers)
  local content_start, content_end = cells_mod.get_content_range(state, cell_idx)
  local lines = vim.api.nvim_buf_get_lines(state.facade_buf, content_start, content_end + 1, false)

  -- Get or create persistent edit buffer for this cell (preserves undo history)
  local buf = get_or_create_edit_buf(cell, lines)

  -- Open float as inline overlay anchored to cell position
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'win',
    win = parent_win,
    bufpos = { content_start, 0 },  -- Anchor to cell content start
    row = 0,
    col = 0,
    width = win_width,
    height = #lines,
    border = 'none',  -- Seamless overlay
    zindex = 50,
  })

  -- Store edit state
  state.edit_state = {
    buf = buf,
    win = win,
    parent_win = parent_win,
    cell_idx = cell_idx,
    start_line = content_start,
    end_line = content_end,
  }

  -- Setup real-time sync to facade and shadow buffers
  M.setup_sync(state, buf)
end
```

**Real-time sync:**

Sync uses autocommands rather than `nvim_buf_attach` for better control over undo granularity:

```lua
function M.setup_sync(state, buf)
  -- TextChangedI: sync during insert mode with undojoin for single undo entry
  vim.api.nvim_create_autocmd('TextChangedI', {
    buffer = buf,
    callback = function()
      local edit = state.edit_state
      local new_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

      -- Sync to shadow buffer for LSP (no undo implications)
      require('ipynb.lsp').sync_shadow_region(state, edit.start_line, edit.end_line + 1, new_lines, cell.type)

      -- Sync to facade with undojoin to merge into single undo entry
      if edit.insert_synced then
        pcall(vim.cmd, 'undojoin')
      end
      vim.api.nvim_buf_set_lines(state.facade_buf, edit.start_line, edit.end_line + 1, false, new_lines)
      edit.insert_synced = true

      -- Update window height if line count changed
      if line_count_changed then
        vim.api.nvim_win_set_height(edit.win, math.max(#new_lines, 1))
        vim.fn.winrestview({ topline = 1 })
        require('ipynb.cells').place_markers(state)
      end
    end,
  })

  -- InsertLeave: reset insert_synced flag for next insert session
  vim.api.nvim_create_autocmd('InsertLeave', {
    buffer = buf,
    callback = function()
      state.edit_state.insert_synced = false
    end,
  })
end
```

**Key design: Undo granularity**

- Each insert session (enter insert → leave insert) creates ONE undo entry
- `undojoin` merges all TextChangedI syncs within a session
- Normal mode changes (dd, p, etc.) each create their own undo entry

**Closing the editor:**

```lua
function M.close(state)
  if not state.edit_state then return end

  -- Update cell content in state
  local edit = state.edit_state
  local lines = vim.api.nvim_buf_get_lines(edit.buf, 0, -1, false)
  state.cells[edit.cell_idx].content = table.concat(lines, "\n")

  -- Close window (buffer auto-wiped)
  if vim.api.nvim_win_is_valid(edit.win) then
    vim.api.nvim_win_close(edit.win, true)
  end

  -- Detach LSP proxy
  require('ipynb.lsp').detach(state)

  state.edit_state = nil
end
```

---

### 6. Shadow Buffer & LSP (`lsp/`)

The LSP integration is split into focused modules, each managing its own proxy/wrapper:

```
lsp/
├── init.lua       # Public API, install_global_proxy() orchestration
├── util.lua       # Shared: resolve_bufnr, get_buffer_context, rewrite_params
├── shadow.lua     # Shadow buffer creation, generation, sync
├── uri.lua        # nb:// scheme, BufReadCmd, rewrite_result_uris
├── request.lua    # buf_request/get_clients wrappers, interceptor registry
├── navigation.lua # nvim_win_set_buf/cursor, vim._with, show_document wrappers
├── format.lua     # format_cell, format_all_cells, vim.lsp.buf.format wrapper
├── rename.lua     # textDocument/rename interceptor, workspace edit application
├── diagnostics.lua# DiagnosticChanged forwarding to facade
└── completion.lua # Edit float completion, diagnostics filtering
```

**Interceptor Registry (`request.lua`):**

Other modules can register interceptors for specific LSP methods:

```lua
-- In format.lua install():
local request = require('ipynb.lsp.request')
request.register_interceptor('textDocument/formatting', M.handle_document_format)
request.register_interceptor('textDocument/rangeFormatting', M.handle_range_format)
```

This keeps formatting logic in `format.lua` while generic request handling stays in `request.lua`.

The shadow buffer approach separates user-facing display from LSP analysis:

**Shadow Buffer Concept:**

```
Facade (user sees):              Shadow (LSP sees):
─────────────────────────────    ─────────────────────────────
1: # <<ipynb_nvim:markdown>>               1: (blank)
2: # Title                       2: (blank)
3: Description text              3: (blank)
4: # <</ipynb_nvim>>                         4: (blank)
5: # <<ipynb_nvim:code>>                          5: (blank)
6: import pandas as pd           6: import pandas as pd
7: df = pd.read_csv("x")         7: df = pd.read_csv("x")
8: # <</ipynb_nvim>>                         8: (blank)
9: # <<ipynb_nvim:markdown>>               9: (blank)
10: More docs                    10: (blank)
11: # <</ipynb_nvim>>                        11: (blank)
12: # <<ipynb_nvim:code>>                         12: (blank)
13: result = df.head()           13: result = df.head()
14: # <</ipynb_nvim>>                        14: (blank)
```

**Benefits:**

- LSP sees valid code only (no markdown syntax errors)
- Line numbers are 1:1 (no position translation needed)
- Facade can use markdown treesitter/highlighting for markdown cells
- Diagnostics from markdown cells are naturally excluded
- Supports multiple languages (Python, Julia, R, etc.) based on notebook metadata

**Shadow Buffer Creation:**

```lua
function M.create_shadow(state)
  -- Create hidden buffer with same line count as facade
  local shadow_buf = vim.api.nvim_create_buf(false, true)  -- unlisted, scratch

  -- Get language from notebook metadata (defaults to python)
  local lang, ext = get_language_info(state)  -- e.g., "julia", ".jl"

  -- Create temp file for LSP (with appropriate extension)
  local shadow_path = vim.fn.tempname() .. '_shadow' .. ext
  vim.api.nvim_buf_set_name(shadow_buf, shadow_path)

  -- Generate shadow content (code cells preserved, markdown → blank)
  local shadow_lines = M.generate_shadow_lines(state)
  vim.api.nvim_buf_set_lines(shadow_buf, 0, -1, false, shadow_lines)
  vim.fn.writefile(shadow_lines, shadow_path)

  -- Configure for LSP
  vim.bo[shadow_buf].filetype = lang
  vim.bo[shadow_buf].bufhidden = 'hide'

  state.shadow_buf = shadow_buf
  state.shadow_path = shadow_path
  state.shadow_lang = lang  -- Track for later use
  return shadow_buf
end

function M.generate_shadow_lines(state)
  local lines = {}
  for _, cell in ipairs(state.cells) do
    if cell.type == 'code' then
      -- Code cell: include marker and content
      table.insert(lines, '')  -- blank for # <<ipynb_nvim:code>> marker line
      for line in (cell.source .. '\n'):gmatch('([^\n]*)\n') do
        table.insert(lines, line)
      end
    else
      -- Markdown/raw cell: blank lines to preserve line count
      table.insert(lines, '')  -- for # <<ipynb_nvim:markdown>> marker
      local line_count = select(2, cell.source:gsub('\n', '\n')) + 1
      for _ = 1, line_count do
        table.insert(lines, '')
      end
    end
  end
  return lines
end
```

**Sync Shadow on Edit (code cells only):**

```lua
function M.sync_shadow_region(state, start_line, end_line, new_lines, cell_type)
  if cell_type ~= 'code' then
    -- Markdown edit: shadow just needs matching blank lines
    local blank_lines = {}
    for _ = 1, #new_lines do
      table.insert(blank_lines, '')
    end
    new_lines = blank_lines
  end

  vim.api.nvim_buf_set_lines(state.shadow_buf, start_line, end_line, false, new_lines)

  -- Update shadow file for LSP
  local all_lines = vim.api.nvim_buf_get_lines(state.shadow_buf, 0, -1, false)
  vim.fn.writefile(all_lines, state.shadow_path)
end
```

**LSP Request Proxying (facade → shadow):**

```lua
function M.setup_lsp_proxy(state)
  -- Override LSP handlers for facade buffer to use shadow buffer
  local facade_buf = state.facade_buf

  -- Intercept completion requests
  vim.lsp.handlers['textDocument/completion'] = function(err, result, ctx, config)
    -- Check if request was for facade, redirect to shadow
    if ctx.bufnr == facade_buf then
      ctx.bufnr = state.shadow_buf
    end
    return vim.lsp.handlers['textDocument/completion'](err, result, ctx, config)
  end
end

-- For gd, gr, K on facade buffer, make request to shadow buffer
function M.goto_definition(state)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line, col = cursor[1] - 1, cursor[2]

  -- Request goes to shadow buffer (same line/col)
  local params = {
    textDocument = { uri = vim.uri_from_fname(state.shadow_path) },
    position = { line = line, character = col },
  }

  vim.lsp.buf_request(state.shadow_buf, 'textDocument/definition', params, function(err, result)
    if result then
      -- Result positions map directly back to facade (1:1 lines)
      vim.lsp.util.jump_to_location(result[1], 'utf-8')
    end
  end)
end
```

**Diagnostics Display (filter markdown lines):**

```lua
function M.setup_diagnostics_filter(state)
  local diag_ns = vim.api.nvim_create_namespace('notebook_diagnostics')

  vim.api.nvim_create_autocmd('DiagnosticChanged', {
    buffer = state.shadow_buf,
    callback = function()
      -- Get diagnostics from shadow buffer
      local shadow_diags = vim.diagnostic.get(state.shadow_buf)

      -- Filter: only show diagnostics in code cells
      local filtered = {}
      for _, diag in ipairs(shadow_diags) do
        local cell_idx = require('ipynb.cells').get_cell_at_line(state, diag.lnum)
        if cell_idx then
          local cell = state.cells[cell_idx]
          if cell.type == 'code' then
            table.insert(filtered, diag)
          end
        end
      end

      -- Display on facade buffer (positions unchanged)
      vim.diagnostic.set(diag_ns, state.facade_buf, filtered)
    end
  })
end
```

**URI Scheme Strategy:**

LSP results contain URIs pointing to the shadow buffer, which must be rewritten to reference the facade. The strategy differs by method type:

```lua
-- Navigation methods (gd, gD, gi, gt): use file:// scheme
-- - Jumps directly to definition/declaration/implementation/type
-- - file:// lets bufadd() find existing facade buffer by path
-- - Result: cursor moves to target location in facade

-- Reference methods (gr, etc.): use custom nb:// scheme
-- - Shows list of locations in picker (fzf-lua, telescope)
-- - nb:// triggers BufReadCmd to render preview with facade content
-- - Result: picker shows notebook content, not raw JSON

local NAVIGATION_METHODS = {
  ['textDocument/definition'] = true,
  ['textDocument/declaration'] = true,
  ['textDocument/implementation'] = true,
  ['textDocument/typeDefinition'] = true,
}

local function rewrite_result_uris(result, state, method)
  -- Navigation methods → file:// (direct jump to facade)
  -- Other methods → nb:// (picker preview support)
  local facade_uri
  if method and NAVIGATION_METHODS[method] then
    facade_uri = vim.uri_from_fname(facade_abs)
  else
    facade_uri = 'nb://' .. facade_abs
  end
  -- ... recursively replace shadow URIs with facade URIs
end
```

**Edit Float LSP Navigation:**

When LSP navigation (gD, gi) is triggered from the edit float, the target location is in the facade buffer but the current window is the float. The solution wraps Neovim APIs to redirect:

```lua
-- Wrap nvim_win_set_buf: When LSP tries to set facade buffer in edit float window,
-- close the float and navigate in the facade window instead
vim.api.nvim_win_set_buf = function(win, buf)
  local target_state = state_mod.get_by_facade(buf)
  if target_state and target_state.edit_state then
    if target_state.edit_state.win == win then
      local parent_win = target_state.edit_state.parent_win
      redirected_wins[win] = parent_win  -- Track for cursor redirect
      require('ipynb.edit').close(target_state)
      return orig_win_set_buf(parent_win, buf)
    end
  end
  return orig_win_set_buf(win, buf)
end

-- Wrap nvim_win_set_cursor: Use redirected window for cursor positioning
vim.api.nvim_win_set_cursor = function(win, pos)
  local redirect_win = redirected_wins[win]
  if redirect_win and vim.api.nvim_win_is_valid(redirect_win) then
    return orig_win_set_cursor(redirect_win, pos)
  end
  return orig_win_set_cursor(win, pos)
end

-- Wrap vim._with: Handle window context for jumplist/tagstack operations
vim._with = function(context, func)
  if context and context.win then
    local redirect_win = redirected_wins[context.win]
    if redirect_win then
      redirected_wins[context.win] = nil  -- Clear after final use
      context = vim.tbl_extend('force', context, { win = redirect_win })
    end
  end
  return orig_with(context, func)
end
```

**client.request Wrapping:**

`vim.lsp.buf.definition()` and similar functions use `client:request()` directly, bypassing `buf_request`. We wrap the client's request method to intercept these:

```lua
client.request = function(self, method, params, handler, req_bufnr)
  local state = get_state_for_buffer(req_bufnr)
  if state then
    -- Rewrite params to point to shadow buffer
    params = rewrite_params(params, state)

    -- Wrap handler to rewrite URIs back to facade
    if handler then
      local orig_handler = handler
      handler = function(err, result, ...)
        result = rewrite_result_uris(result, state, method)
        return orig_handler(err, result, ...)
      end
    end

    req_bufnr = state.shadow_buf
  end
  return orig_request(self, method, params, handler, req_bufnr)
end
```

**nb:// Buffer Cleanup:**

Preview buffers created for pickers are cleaned up when returning to the facade buffer:

```lua
-- WinEnter autocmd on facade buffer (in facade.lua)
vim.api.nvim_create_autocmd('WinEnter', {
  buffer = buf,
  callback = function()
    lsp_mod.cleanup_preview_buffers(state)
  end,
})

-- cleanup_preview_buffers deletes any nb:// buffers for this notebook
function M.cleanup_preview_buffers(state)
  local facade_abs = vim.fn.fnamemodify(state.facade_path, ':p')
  vim.schedule(function()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      local name = vim.api.nvim_buf_get_name(buf)
      if M.is_facade_uri(name) and M.parse_facade_uri(name) == facade_abs then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end
  end)
end
```

This handles both picker selection and cancellation - in either case, focus returns to the facade window, triggering cleanup.

**LSP Range Formatting:**

Cell formatting uses LSP `textDocument/rangeFormatting` to format individual cells:

```lua
function M.format_cell(state, cell_idx, callback)
  -- Get cell content range (excludes start/end markers)
  local content_start, content_end = cells_mod.get_content_range(state, cell_idx)

  -- Build range formatting params
  local params = {
    textDocument = { uri = vim.uri_from_fname(state.shadow_path) },
    range = {
      start = { line = content_start, character = 0 },
      ['end'] = { line = content_end + 1, character = 0 },
    },
    options = { tabSize = 4, insertSpaces = true },
  }

  -- Request formatting from shadow buffer (LSP attached here)
  vim.lsp.buf_request(state.shadow_buf, 'textDocument/rangeFormatting', params,
    function(err, result)
      -- Translate LSP edits from shadow coordinates to cell-relative
      -- Apply edits to Lua table (not directly to buffer)
      -- Update cell.source, shadow buffer, facade buffer, and edit buffer
      -- Trim trailing blank lines per config
    end)
end
```

**vim.lsp.buf.format() Wrapping:**

The plugin wraps `vim.lsp.buf.format()` so users' existing format keybindings work seamlessly:

- On facade buffer: calls `format_all_cells` (formats all code cells)
- On edit buffer: calls `format_cell` for the current cell

This means any keybinding that calls `vim.lsp.buf.format()` (like `<leader>f` or conform.nvim) will automatically use the appropriate notebook formatting.

**Key design decisions:**

1. **Apply edits to Lua table first**: Instead of using `vim.lsp.util.apply_text_edits` directly on a buffer (which can cause side effects), we apply edits to a Lua table copy of the cell content, then update all buffers separately.

2. **Update edit_state.end_line**: When formatting changes line count, `edit_state.end_line` must be updated to prevent sync issues when exiting the edit float.

3. **Process bottom-to-top for format-all**: When formatting all cells, process from bottom to top to avoid line offset issues as earlier cells change size.

4. **Trim trailing blank lines**: Formatters often add trailing newlines. The `format.trailing_blank_lines` config option controls how many to keep (default: 0).

**LSP Rename (`rename.lua`):**

Rename (`textDocument/rename`) is fully supported:

```lua
function handle_rename(ctx, method, params, handler, client, req_bufnr)
  -- Intercept rename request from facade/edit buffer
  -- Proxy to shadow buffer, then apply edits line-by-line

  handler = function(err, result, ctx_arg, config)
    if result then
      vim.schedule(function()
        M.apply_workspace_edit(state, result, ctx.is_edit_buf)
      end)
    end
  end

  return true, orig_request(client, method, params, handler, state.shadow_buf)
end

function M.apply_workspace_edit(state, workspace_edit, is_edit_buf)
  -- Extract edits from WorkspaceEdit (changes or documentChanges)
  -- Sort bottom-to-top to avoid offset issues
  -- Apply each edit individually to preserve extmarks on unaffected lines

  vim.bo[state.facade_buf].modifiable = true
  for _, edit in ipairs(edits) do
    -- Get affected lines, apply edit, replace just those lines
    pcall(vim.api.nvim_buf_set_lines, state.facade_buf, start_line, end_line + 1, false, replacement)
  end
  vim.bo[state.facade_buf].modifiable = false

  -- Sync cell sources and shadow buffer
  cells_mod.sync_cells_from_facade(state)
  shadow.refresh_shadow(state)
end
```

**Key design decisions:**

1. **Line-by-line edits**: Apply each edit individually rather than replacing the entire buffer. This preserves extmarks (outputs, images) on unaffected lines.

2. **Sort bottom-to-top**: Process edits from bottom to top to avoid offset issues as earlier lines change.

3. **Update edit buffer**: If rename was triggered from edit float, sync the edit buffer content after applying edits.

**Not Supported - Code Actions:**

LSP code actions (`textDocument/codeAction`) are intentionally not supported because:

- Code actions can modify arbitrary ranges, potentially spanning cell boundaries
- Actions like "organize imports" may move code between cells unpredictably
- The complexity of safely handling cross-cell modifications is high
- Users can still run code actions manually in the shadow buffer if needed

**Not Yet Implemented:**

The following LSP features could be added in the future:

- `textDocument/documentSymbol` - document outline (used by symbol pickers)
- `textDocument/signatureHelp` - function signature hints while typing
- `textDocument/documentHighlight` - highlight other references of symbol under cursor
- `textDocument/inlayHint` - inline type hints (Neovim 0.10+)

These would follow the same proxy pattern: intercept request, redirect to shadow buffer, rewrite results.

---

### 7. Visual Rendering (`visuals.lua`)

**Highlight groups:**

```lua
function M.setup_highlights()
  local set_hl = vim.api.nvim_set_hl

  -- Cell backgrounds
  set_hl(0, 'NotebookCodeCell', { bg = '#1c1c2e' })
  set_hl(0, 'NotebookMarkdownCell', { bg = '#1e2e1e' })
  set_hl(0, 'NotebookRawCell', { bg = '#2e2e1e' })

  -- Active cell (higher priority overlay)
  set_hl(0, 'NotebookActiveCell', { bg = '#2a2a3e' })
  set_hl(0, 'NotebookActiveBorder', { fg = '#61afef', bold = true })

  -- Cell borders
  set_hl(0, 'NotebookCellBorder', { fg = '#3e4452' })

  -- Sign column indicators
  set_hl(0, 'NotebookCodeSign', { fg = '#61afef' })
  set_hl(0, 'NotebookMarkdownSign', { fg = '#98c379' })
  set_hl(0, 'NotebookRawSign', { fg = '#e5c07b' })

  -- Output
  set_hl(0, 'NotebookOutput', { fg = '#abb2bf', italic = true })
  set_hl(0, 'NotebookOutputError', { fg = '#e06c75' })
end
```

**Cell decoration (backgrounds, borders, signs):**

```lua
local cell_config = {
  code = { bg = 'NotebookCodeCell', sign = '󰌠', sign_hl = 'NotebookCodeSign' },
  markdown = { bg = 'NotebookMarkdownCell', sign = '󰍔', sign_hl = 'NotebookMarkdownSign' },
  raw = { bg = 'NotebookRawCell', sign = '󰈙', sign_hl = 'NotebookRawSign' },
}

function M.render_cell(state, cell_idx)
  local cell = state.cells[cell_idx]
  local start_line, end_line = require('ipynb.cells').get_cell_range(state, cell_idx)
  local cfg = cell_config[cell.type]
  local ns = state.namespace

  -- Background for entire cell
  cell.bg_extmark = vim.api.nvim_buf_set_extmark(state.facade_buf, ns, start_line, 0, {
    id = cell.bg_extmark,  -- Reuse ID if updating
    end_row = end_line,
    line_hl_group = cfg.bg,
    hl_eol = true,
    priority = 10,
  })

  -- Sign on first line
  cell.sign_extmark = vim.api.nvim_buf_set_extmark(state.facade_buf, ns, start_line, 0, {
    id = cell.sign_extmark,
    sign_text = cfg.sign,
    sign_hl_group = cfg.sign_hl,
  })

  -- Border below cell (except last cell)
  if cell_idx < #state.cells then
    cell.border_extmark = vim.api.nvim_buf_set_extmark(state.facade_buf, ns, end_line, 0, {
      id = cell.border_extmark,
      virt_lines = {{
        { string.rep('─', 80), 'NotebookCellBorder' }
      }},
    })
  end
end
```

**Active cell highlight (moves with cursor):**

```lua
local active_extmark_id = nil

function M.update_active_cell(state)
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1] - 1  -- 0-indexed
  local cell_idx = require('ipynb.cells').get_cell_at_line(state, cursor_line)

  if not cell_idx then return end

  local start_line, end_line = require('ipynb.cells').get_cell_range(state, cell_idx)

  -- Update single extmark (reuse ID to avoid accumulation)
  active_extmark_id = vim.api.nvim_buf_set_extmark(state.facade_buf, state.namespace, start_line, 0, {
    id = active_extmark_id,
    end_row = end_line,
    line_hl_group = 'NotebookActiveCell',
    hl_eol = true,
    priority = 20,  -- Higher than base cell background
  })
end

function M.setup_active_tracking(state)
  vim.api.nvim_create_autocmd({'CursorMoved', 'CursorMovedI'}, {
    buffer = state.facade_buf,
    callback = function()
      M.update_active_cell(state)
    end
  })
end
```

---

### 8. Syntax Highlighting (Tree-sitter Grammar)

Syntax highlighting is handled by a custom tree-sitter grammar (`tree-sitter-ipynb/`) with dynamic language injection.
The grammar parses notebook cell structure and uses a custom directive to inject the appropriate language
(Python, Julia, R, etc.) based on notebook metadata.

**Grammar structure (`grammar.js`):**

```javascript
module.exports = grammar({
  name: 'ipynb',
  externals: $ => [$.content_line, $.cell_end],
  rules: {
    notebook: $ => repeat(choice($.cell, $.blank_line)),
    blank_line: $ => /\n/,
    cell: $ => choice($.code_cell, $.markdown_cell, $.raw_cell),

    code_cell: $ => seq('# <<ipynb_nvim:code>>', '\n', optional($.cell_content), $.cell_end),
    markdown_cell: $ => seq('# <<ipynb_nvim:markdown>>', '\n', optional($.cell_content), $.cell_end),
    raw_cell: $ => seq('# <<ipynb_nvim:raw>>', '\n', optional($.cell_content), $.cell_end),
  },
});
```

**External scanner (`src/scanner.c`):**

- Handles `content_line`: any line that is NOT `# <</ipynb_nvim>>`
- Handles `cell_end`: matches `# <</ipynb_nvim>>` end marker
- Required because content lines would otherwise greedily consume end markers
- **Important:** Function names must match grammar name (e.g., `tree_sitter_ipynb_external_scanner_*`)

**Dynamic language injection:**

A custom tree-sitter directive reads the language from a buffer variable:

```lua
-- In init.lua (registered once during setup)
vim.treesitter.query.add_directive('inject-notebook-language!', function(match, pattern, source, pred, metadata)
  local bufnr = type(source) == 'number' and source or source:source()
  metadata['injection.language'] = vim.b[bufnr].ipynb_language or 'python'
end, { force = true })
```

**Injection queries (`queries/ipynb/injections.scm`):**

```scheme
; Inject code cell content using language from buffer variable
((code_cell
  (cell_content) @injection.content)
  (#inject-notebook-language!)
  (#set! injection.include-children))

; Inject Markdown into markdown cells
((markdown_cell
  (cell_content) @injection.content)
  (#set! injection.language "markdown")
  (#set! injection.include-children))

; Raw cells get no injection (plain text)
```

**Activation:**

```lua
-- In facade.lua, set language from metadata before starting treesitter:
vim.b[buf].ipynb_language = state.metadata.language_info.name or 'python'
vim.treesitter.start(buf, 'ipynb')
```

**Changing language at runtime:**

When `:NotebookSetKernel` is called, the buffer variable is updated and treesitter is restarted:

```lua
vim.b[buf].ipynb_language = new_language
vim.treesitter.stop(buf)
vim.treesitter.start(buf, 'ipynb')
```

**Benefits:**

- Single grammar supports Python, Julia, R, and other languages
- Language determined from notebook metadata at runtime
- Multiple notebooks with different languages can coexist
- Native tree-sitter highlighting with proper syntax awareness

**Building the parser:**

The parser is automatically compiled via nvim-treesitter on first plugin load. No manual steps required:

```lua
{
  "user/ipynb.nvim",
  dependencies = { "nvim-treesitter/nvim-treesitter" },
}
```

**Development: Regenerating the parser**

If you modify `grammar.js`, you must regenerate the C source files.

**Prerequisites:** Install tree-sitter CLI 0.26+ via your package manager:

```bash
# macOS
brew install tree-sitter

# Or via cargo (cross-platform)
cargo install tree-sitter-cli
```

**Regenerate and test:**

```bash
cd tree-sitter-ipynb

# Regenerate src/ files from grammar.js
tree-sitter generate

# (Optional) Test the grammar
tree-sitter test

# (Optional) Build locally for testing (not required for distribution)
tree-sitter build -o parser.so
```

Then in Neovim, run `:TSInstall! ipynb` to recompile, or restart Neovim (auto-compiles on load).

**Important:** The `src/` directory contains generated C code and must be committed to git. Users don't need tree-sitter-cli installed - nvim-treesitter compiles directly from `src/parser.c` and `src/scanner.c`.

**Note:** If you rename the grammar (change `name` in `grammar.js`), you must also update the function names in `src/scanner.c` to match (e.g., `tree_sitter_<name>_external_scanner_*`).

---

### 9. Keymaps (`keymaps.lua`)

**Key helpers:**

```lua
-- Offset from cell start line to first content line (skips header marker)
local CONTENT_LINE_OFFSET = 2

-- Get the cell at the current cursor position
local function get_cell_at_cursor(state)
  local cells_mod = require('ipynb.cells')
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1] - 1
  return cells_mod.get_cell_at_line(state, cursor_line)
end

-- Move cursor to the content area of a cell
local function move_cursor_to_cell(state, cell_idx)
  local cells_mod = require('ipynb.cells')
  local start_line = cells_mod.get_cell_range(state, cell_idx)
  vim.api.nvim_win_set_cursor(0, { start_line + CONTENT_LINE_OFFSET, 0 })
end
```

**Facade buffer (normal mode):**

```lua
function M.setup_facade_keymaps(state)
  local buf = state.facade_buf
  local opts = { buffer = buf, silent = true }
  local config = require('ipynb.config').get()
  local km = config.keymaps

  -- Shared callbacks to avoid duplication
  local execute_cell_cb = function() M.execute_cell(state) end
  local execute_and_next_cb = function() M.execute_and_next(state) end

  -- Cell navigation
  vim.keymap.set('n', km.next_cell, function() require('ipynb.cells').goto_next_cell(state) end, opts)
  vim.keymap.set('n', km.prev_cell, function() require('ipynb.cells').goto_prev_cell(state) end, opts)

  -- Enter edit mode (hardcoded keys)
  vim.keymap.set('n', 'i', function() require('ipynb.edit').open(state, 'i') end, opts)
  vim.keymap.set('n', 'a', function() require('ipynb.edit').open(state, 'a') end, opts)

  -- Cell operations
  vim.keymap.set('n', km.execute_cell, execute_cell_cb, opts)
  vim.keymap.set('n', km.menu_execute_cell, execute_cell_cb, opts)  -- Same callback, different key
  vim.keymap.set('n', km.move_cell_down, function() M.move_cell(state, 1) end, opts)
  vim.keymap.set('n', km.move_cell_up, function() M.move_cell(state, -1) end, opts)

  -- LSP (works via API-level interception in lsp.lua)
  -- User's existing LSP keymaps (gd, gr, K, etc.) work automatically

  -- Formatting: vim.lsp.buf.format() is wrapped to work with notebooks (see lsp/format.lua)
end

-- Move cell in a direction (unified function)
function M.move_cell(state, direction)
  local facade_mod = require('ipynb.facade')
  local cell_idx = get_cell_at_cursor(state)
  if cell_idx then
    local new_idx = facade_mod.move_cell(state, cell_idx, direction)
    if new_idx then
      move_cursor_to_cell(state, new_idx)
    end
  end
end
```

**Edit float keymaps:**

```lua
function M.setup_edit_keymaps(state)
  local buf = state.edit_state.buf
  local opts = { buffer = buf, silent = true }

  -- Exit edit mode (Esc only, q reserved for macros)
  vim.keymap.set('n', '<Esc>', function() require('ipynb.edit').close(state) end, opts)

  -- Execute current cell
  vim.keymap.set({'n', 'i'}, '<C-CR>', function() M.execute_cell(state) end, opts)
  vim.keymap.set({'n', 'i'}, '<S-CR>', function() M.execute_and_next(state) end, opts)

  -- Navigate to adjacent cells (close current, open next)
  vim.keymap.set('n', '<C-j>', function() M.edit_next_cell(state) end, opts)
  vim.keymap.set('n', '<C-k>', function() M.edit_prev_cell(state) end, opts)

  -- Formatting: vim.lsp.buf.format() is wrapped to work with notebooks (see lsp/format.lua)
end
```

---

### 10. Output Rendering (`output.lua`)

**Design: Virtual lines (not real buffer lines)**

Outputs are rendered as `virt_lines` extmarks, NOT as real buffer content. This is critical for:

- **Undo isolation**: Outputs don't pollute the undo tree
- **1:1 line mapping**: Shadow buffer stays synchronized with facade (no offset translation)
- **LSP correctness**: Diagnostic positions remain accurate

**Render outputs as virtual text below cells:**

```lua
local output_ns = vim.api.nvim_create_namespace('notebook_outputs')

function M.render_outputs(state, cell_idx)
  local cell = state.cells[cell_idx]
  if not cell.outputs or #cell.outputs == 0 then return end

  local _, end_line = require('ipynb.cells').get_cell_range(state, cell_idx)

  local virt_lines = {}

  -- Output separator
  table.insert(virt_lines, {{ '┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄', 'NotebookCellBorder' }})

  for _, output in ipairs(cell.outputs) do
    local rendered = M.render_output(output)
    for _, line in ipairs(rendered) do
      table.insert(virt_lines, line)
    end
  end

  cell.output_extmark = vim.api.nvim_buf_set_extmark(state.facade_buf, output_ns, end_line, 0, {
    id = cell.output_extmark,
    virt_lines = virt_lines,
  })
end

function M.render_output(output)
  local lines = {}

  if output.output_type == 'stream' then
    for line in output.text:gmatch('[^\n]+') do
      table.insert(lines, {{ line, 'NotebookOutput' }})
    end

  elseif output.output_type == 'execute_result' then
    local text = output.data['text/plain'] or vim.inspect(output.data)
    table.insert(lines, {{ 'Out: ' .. text, 'NotebookOutput' }})

  elseif output.output_type == 'error' then
    table.insert(lines, {{ output.ename .. ': ' .. output.evalue, 'NotebookOutputError' }})

  elseif output.output_type == 'display_data' then
    if output.data['image/png'] then
      -- Image rendered inline via images.lua if snacks.nvim available
      -- Falls back to placeholder text if not
    else
      table.insert(lines, {{ output.data['text/plain'] or '[Display]', 'NotebookOutput' }})
    end
  end

  return lines
end
```

**Output float for copying:**

Since virtual lines cannot be yanked directly, `go` keymap opens output in a floating buffer:

```lua
function M.open_output_float(state, cell_idx)
  local cell = state.cells[cell_idx]
  local lines = M.build_output_text(cell)  -- Plain text version

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = 'notebook_output'

  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width, height = height,
    border = 'rounded',
    title = ' Cell Output ',
  })

  -- Keymaps: q/Esc to close, Y to yank all
  vim.keymap.set('n', 'Y', function()
    vim.fn.setreg('+', table.concat(lines, '\n'))
    vim.notify('Output copied to clipboard')
  end, { buffer = buf })
end
```

---

### 11. Image Rendering (`images.lua`)

**Inline image rendering using snacks.nvim (optional dependency):**

Images are rendered inline within cell outputs using the Kitty Graphics Protocol (supported by kitty, ghostty, wezterm). The implementation uses vendored placeholder generation from snacks.nvim to enable true text/image interleaving.

**Key design decisions:**

1. **Unique cell IDs**: Each cell has a unique `id` field (e.g., `cell_1736418234567_1`). Images are stored in `state.images` keyed by `cell.id`, not by cell index. This ensures images stay associated with their cell even when cells are moved, inserted, or deleted.

2. **True interleaving via vendored placeholders**: Instead of using separate extmarks for text and images, we generate Kitty Graphics Protocol placeholder text ourselves and embed it directly in the `virt_lines` array alongside regular text. This guarantees correct ordering: text1 → img1 → text2 → img2 → etc.

3. **Single extmark with all content**: All cell output (separator, text lines, image placeholder lines) is combined into a single extmark's `virt_lines` array. Order is guaranteed by array order.

4. **Actual terminal cell dimensions**: Uses `Snacks.image.terminal.size()` to get real terminal cell dimensions for accurate pixel-to-cell conversion. This ensures the placeholder grid size matches what the terminal allocates.

5. **Snacks dimensions as source of truth**: We use `img.info.size` from snacks' converted image for dimensions. For SVGs, ImageMagick converts at 192 DPI which may differ from declared pt values. Using snacks' dimensions ensures the placeholder grid matches the actual image pixels, preventing placement misalignment. Images are scaled down proportionally to fit the terminal width.

**How Kitty Graphics Protocol placeholders work:**

The terminal renders images by replacing special Unicode placeholder characters with actual pixels:

- Placeholder character: `U+10EEEE`
- Row/column positions encoded as combining diacritics
- Image ID encoded in highlight group's `fg` color
- Placement ID encoded in highlight group's `sp` color

```lua
-- Vendored from snacks.nvim - generates placeholder grid
local function generate_placeholder_grid(img_id, placement_id, width, height)
  -- Create highlight group with IDs encoded in colors
  local hl_group = 'IpynbImage' .. placement_id
  vim.api.nvim_set_hl(0, hl_group, {
    fg = img_id,       -- Terminal uses this to identify image
    sp = placement_id, -- Terminal uses this to identify placement
    bg = 'none',
    nocombine = true,
  })

  local lines = {}
  for r = 1, height do
    local line = {}
    for c = 1, width do
      line[#line + 1] = PLACEHOLDER      -- U+10EEEE
      line[#line + 1] = positions[r]     -- Row diacritic
      line[#line + 1] = positions[c]     -- Column diacritic
    end
    lines[#lines + 1] = table.concat(line)
  end
  return lines, hl_group
end

-- Generate virt_lines entries for an image
function M.get_image_virt_lines(state, cell, output, image_index)
  -- 1. Decode image data and write to cache file
  -- 2. Create snacks Image object (handles loading/sending to terminal)
  -- 3. Send placement command via Kitty Graphics Protocol
  -- 4. Generate placeholder grid lines
  -- 5. Return as virt_lines entries for interleaving

  local img = get_or_create_image(path)  -- snacks handles terminal protocol

  Snacks.image.terminal.request({
    a = 'p', U = 1,
    i = img.id, p = placement_id,
    c = img_width, r = img_height,
  })

  local placeholder_lines, hl_group = generate_placeholder_grid(
    img.id, placement_id, img_width, img_height
  )

  local virt_line_entries = {}
  for _, line in ipairs(placeholder_lines) do
    table.insert(virt_line_entries, { { line, hl_group } })
  end
  return virt_line_entries, img_height
end
```

**Integration with output.lua:**

```lua
-- In render_outputs(): true interleaving in single virt_lines array
local virt_lines = {}
table.insert(virt_lines, { { '┄┄┄┄┄┄┄┄┄┄', 'IpynbBorder' } })  -- separator

for _, output in ipairs(cell.outputs) do
  local has_image = images_mod.get_image_data(output)

  if has_image and images_mod.supports_placeholders() then
    -- Get image placeholder lines for true interleaving
    local img_lines = images_mod.get_image_virt_lines(state, cell, output, idx)
    for _, line in ipairs(img_lines) do
      table.insert(virt_lines, line)  -- Image rows inserted in order
    end
  else
    -- Add text lines
    local rendered = M.render_output(output)
    for _, line in ipairs(rendered) do
      table.insert(virt_lines, line)
    end
  end
end

-- Single extmark with all content - order guaranteed by array order
cell.output_extmark = vim.api.nvim_buf_set_extmark(buf, ns, end_line, 0, {
  virt_lines = virt_lines,
})
```

**Key features:**

- True text/image interleaving (text1 → img1 → text2 → img2 works correctly)
- Gracefully degrades to placeholder text if snacks.nvim not installed or terminal lacks placeholder support
- Caches decoded images in `~/.cache/nvim/ipynb.nvim/`
- Supports PNG, JPEG, GIF, WebP, BMP, TIFF, HEIC, AVIF, SVG, and PDF formats
- SVG and PDF are converted to raster via ImageMagick (handled by snacks.nvim)
- Uses actual terminal cell dimensions for accurate sizing
- Images persist through cell moves, insertions, deletions (via unique cell IDs)
- Requires terminal with Kitty Graphics Protocol + Unicode placeholder support (kitty, ghostty)

---

### 12. Kernel Integration (`kernel.lua`)

**Design: Per-notebook kernel state**

Each notebook has its own independent kernel connection stored in `state.kernel`. This allows multiple notebooks to have separate kernel sessions running simultaneously.

```lua
---@class KernelState
---@field job_id number|nil Job handle for Python bridge process
---@field connected boolean Whether kernel is connected
---@field kernel_id string|nil Kernel ID from jupyter_client
---@field kernel_name string Kernel name (e.g., "python3", "julia-1.9")
---@field execution_state string Current state: "idle", "busy", "starting"
---@field pending_cells table<number, {cell_idx: number}> Cells waiting for execution
---@field callbacks table Async operation callbacks (complete, inspect, ping)

-- Kernel state is created per-notebook
function M.start_bridge(state, python_path)
  state.kernel = state.kernel or create_kernel_state()
  -- Start Python bridge process for this notebook
  -- Each notebook gets its own bridge process
end
```

**Architecture:**

```
┌─────────────────────────────────────────────────────────────────┐
│                      NotebookState                              │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │ kernel: KernelState                                         ││
│  │   ├─ job_id: Python bridge process handle                   ││
│  │   ├─ connected: true/false                                  ││
│  │   ├─ execution_state: "idle" | "busy"                       ││
│  │   ├─ pending_cells: { [cell_idx]: {...} }                   ││
│  │   └─ callbacks: { complete, inspect, ping }                 ││
│  └─────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────┘
         │
         │ JSON over stdin/stdout
         ▼
┌─────────────────────────────────────────────────────────────────┐
│                  kernel_bridge.py (per notebook)                │
│  ├─ Manages jupyter_client connection                           │
│  ├─ Handles execute, interrupt, restart, complete, inspect      │
│  └─ Communicates via JSON messages                              │
└─────────────────────────────────────────────────────────────────┘
         │
         │ ZMQ (Jupyter protocol)
         ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Jupyter Kernel (ipykernel, IJulia, etc.)     │
└─────────────────────────────────────────────────────────────────┘
```

**Key design decisions:**

1. **Per-notebook isolation**: Each notebook gets its own Python bridge process and kernel connection. This prevents cross-notebook interference and allows different notebooks to use different kernels.

2. **Python discovery**: The bridge Python is discovered in order: explicit path → config → venv (walks up from notebook) → system python3/python.

3. **Async callbacks**: Operations like completion and inspection use callbacks stored in `state.kernel.callbacks`. Request IDs prevent callback overwrites during rapid operations.

4. **Statusline integration**: `M.statusline(state)` returns both the status string and highlight state, enabling lualine color integration without module-level state.

**API (all functions take NotebookState as first parameter):**

```lua
M.connect(state, opts)           -- Start kernel for notebook
M.execute(state, cell_idx)       -- Execute a cell
M.interrupt(state)               -- Interrupt execution
M.restart(state, clear_outputs)  -- Restart kernel
M.shutdown(state)                -- Shutdown kernel
M.is_connected(state)            -- Check connection status
M.is_busy(state)                 -- Check if executing
M.complete(state, code, pos, cb) -- Request completion
M.inspect(state, code, pos, cb)  -- Request variable inspection
M.statusline(state)              -- Get statusline string and state
```

---

### 13. Variable Inspector (`inspector.lua`)

**Design: Language-agnostic inspection via Jupyter protocol**

The variable inspector uses Jupyter's `inspect_request` protocol to query variable information from the kernel. This approach is language-agnostic and works with any Jupyter kernel (Python, Julia, R, etc.).

**Jupyter inspect protocol (kernel_bridge.py):**

```python
def inspect(self, code: str, cursor_pos: int, detail_level: int = 0):
    """Request variable/object inspection using Jupyter's inspect_request protocol."""
    msg_id = self.kernel_client.inspect(code, cursor_pos, detail_level)
    # Wait for inspect_reply, parse ANSI-colored output into sections
    # Returns: signature, docstring, type, string_form, file, source, etc.
```

**How it works:**

1. Treesitter extracts identifier at cursor (handles attribute access like `plt.show`)
2. `kernel.inspect()` sends `inspect_request` to the Jupyter kernel
3. Python bridge parses IPython's ANSI-colored output into structured sections
4. Inspector displays results in a floating window with Tab navigation between sections

**ANSI parsing:**
IPython wraps section keys in red ANSI codes (`\x1b[31mKey:\x1b[39m`), making them easy to extract:

```python
# Find all keys wrapped in red ANSI codes
key_pattern = re.compile(r'\x1b\[31m([\w\s]+):\x1b\[39m')
matches = list(key_pattern.finditer(text))
# Value for each key is text between current match end and next match start
```

**Identifier detection:**

```lua
function M.get_identifier_at_cursor(state)
  -- Use treesitter on shadow buffer (1:1 line mapping)
  local parser = vim.treesitter.get_parser(state.shadow_buf, lang)
  local node = root:named_descendant_for_range(row, col, row, col)

  while node do
    if node:type() == 'identifier' then
      local parent = node:parent()
      -- Handle attribute access: cursor on "show" in "plt.show" returns "plt.show"
      -- But cursor on "plt" returns just "plt"
      if parent and parent:type() == 'attribute' then
        local attr_node = parent:field('attribute')[1]
        if attr_node and attr_node:id() == node:id() then
          return vim.treesitter.get_node_text(parent, state.shadow_buf), cell_idx
        end
      end
      return vim.treesitter.get_node_text(node, state.shadow_buf), cell_idx
    end
    node = node:parent()
  end
end
```

**Key features:**

1. **Inspect variable** (`<leader>kh`): Shows structured info with Tab navigation
   - Signature (with syntax highlighting)
   - Docstring (plain text)
   - Type, file, source, etc.
   - Sections displayed in Jupyter's order

2. **Inspect cell** (`<leader>kv`): Batch-inspects all identifiers in the cell using treesitter

3. **Auto-hover** (CursorHold): Automatically shows variable info when cursor rests on an identifier
   - Configurable via `variable_hover.enabled` (default: true)
   - Configurable delay via `variable_hover.delay` (default: 500ms)
   - Toggle with `<leader>kH`

**Configuration:**

```lua
require('ipynb').setup({
  variable_hover = {
    enabled = true,  -- Auto-show on CursorHold
    delay = 500,     -- Milliseconds before showing
  },
})
```

**Implementation notes:**

- Language-agnostic: works with Python, Julia, R, or any Jupyter kernel
- Uses unique request IDs to prevent callback overwrites during rapid hover changes
- Matches request/reply using `parent_header.msg_id` to avoid stale data
- Edit float z-index lowered to 40 (from 50) so inspector floats appear on top
- Section navigation: Tab/Shift-Tab or h/l to cycle through available sections
- Syntax highlighting only for signature/source sections; plain text for docstrings

---

## Implementation Phases

### Phase 1: Core Foundation ✓

- [x] File I/O (read/write .ipynb ↔ jupytext)
- [x] Notebook state management
- [x] Facade buffer creation (keeps original .ipynb path)
- [x] Extmark cell boundary tracking
- [x] Basic cell navigation keymaps

### Phase 2: Edit Float ✓

- [x] Float window creation/positioning
- [x] Real-time sync (edit → facade)
- [x] Proper close/save behavior
- [x] Edit mode keymaps

### Phase 3: LSP Integration ✓

- [x] Completion proxy (translate positions)
- [x] Diagnostics filtering for edit float
- [x] Hover/signature help in edit float

### Phase 4: Visual Polish ✓

- [x] Cell background highlighting
- [x] Cell border separators (virt_lines)
- [x] Active cell tracking
- [x] Sign column indicators
- [x] Markdown concealment

### Phase 5: Kernel Integration ✓

- [x] Kernel connection (jupyter_client via Python bridge)
- [x] Cell execution
- [x] Output capture and rendering
- [x] Execution state indicators

### Phase 6: Advanced Features

- [x] Cell folding
- [ ] Multi-cursor cell selection
- [x] Image output support (via snacks.nvim) - with unique cell IDs for persistence
- [x] Variable inspector - Jupyter inspect protocol, auto-hover
- [ ] Telescope integration (cell picker)

---

## Open Design Decisions

### 1. Edit Float Close Behavior

**Current design:** `<Esc>` in normal mode closes float

**Alternative:** Float stays open, explicit `q` or `:q` to close

**Recommendation:** Keep current design, but add `<C-s>` to save-without-close for users who want to preview changes.

### 2. Undo Scope (Resolved)

**Chosen:** Global undo (facade buffer history)

**Implementation:**

- Edit buffers have `undolevels=-1` (undo disabled in edit float)
- All changes sync to facade buffer, which maintains the undo history
- `u` and `<C-r>` in edit float trigger global undo/redo on facade
- After undo/redo, all edit buffers are refreshed from facade content

### 3. Multi-language Support (Implemented)

Notebooks can contain code in different languages. The plugin now supports multiple languages:

**Implemented features:**

- **Syntax highlighting**: Uses custom tree-sitter directive to inject language from `vim.b[buf].ipynb_language`
- **LSP support**: Shadow buffer uses language-specific file extension and filetype; triggers FileType autocmd so user's LSP config attaches automatically
- **Dynamic switching**: `:NotebookSetKernel julia-1.9` updates highlighting and recreates shadow buffer

**LSP works with any language** - the shadow buffer gets the correct filetype (python, julia, r, etc.) and file extension (.py, .jl, .r, etc.), then triggers the FileType autocmd. Whatever LSP the user has configured for that filetype will attach automatically.

**Note:** Kernel execution still uses the Python bridge with `jupyter_client`, which can execute any installed Jupyter kernel.

### 4. Keymaps

Keymaps are still under discussion. Since the facade buffer is non-modifiable, we have full control over all keys without needing `<leader>` prefixes.

**Goal:** Be intuitive for users coming from other notebook IDEs (Jupyter, VS Code, etc.)

Common notebook keybindings to consider:

- `<C-CR>` / `<S-CR>` for execute cell / execute and move
- `dd` for delete cell (no leader needed)
- `a` / `b` for insert cell above/below (Jupyter style)

---

## Dependencies

**Required:**

- Neovim 0.10+ (extmark features)
- [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter) (parser compilation)
- LSP server for your notebook language (pyright for Python, julials for Julia, etc.)
- `jupyter_client` Python package (for kernel execution)

**Optional:**

- nvim-cmp (completion integration)
- telescope.nvim (cell picker)
- nvim-web-devicons (language icons in cell borders)
- snacks.nvim (image rendering)
