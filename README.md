# 📘 `ipynb.nvim`

A modal Jupyter notebook editor for Neovim.

> [!IMPORTANT]
> `ipynb.nvim` is currently in **alpha**. There *will* be bugs!

<img width="752" height="517" alt="Screenshot From 2026-01-17 01-28-38" src="https://github.com/user-attachments/assets/6784bcce-ab98-4f5a-9383-567e252276bc" />

## ✨ Features

- Edit `.ipynb` files as actual notebooks with isolated cell buffers
- Cell outputs render inline as virtual lines (open in float to copy)
- Inline image rendering (PNG, JPEG, SVG, etc.)
- Variable inspector with auto-hover (uses Jupyter inspect protocol)
- Partial language server support (diagnostics, completion, go to definition, rename)
- Multi-language support (Python, Julia, R, and more)
- Treesitter highlighting with dynamic language injection

## 🧩 How It Works

The plugin uses a modal editing approach:

- **Navigation buffer**: A read-only view of your notebook for navigation between cells
- **Cell buffers**: When you edit a cell, changes happen in an isolated buffer that overlays the cell
- **Shadow buffer**: A hidden buffer containing only code cells, used for LSP communication

This architecture attempts to strike a balance between isolated cells and a natural Vim editing experience.

## ⚡️ Requirements

- Neovim 0.10+
- [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter)
- Python 3.x with `jupyter_client` (for kernel execution)

***Optional (but highly recommended):***

- [nvim-lspconfig](https://github.com/neovim/nvim-lspconfig) for LSP support (completion, diagnostics, etc.)
- [nvim-web-devicons](https://github.com/nvim-tree/nvim-web-devicons) for language icons in cell borders
- [snacks.nvim](https://github.com/folke/snacks.nvim) for inline image rendering
  - a terminal that fully supports the kitty graphics protocol (e.g., kitty, Ghostty)
  - ImageMagick required to display non-PNG image formats

Run `:checkhealth ipynb` to verify your setup.

## 📦 Installation

### lazy.nvim

```lua
{
  "ajbucci/ipynb.nvim",
  dependencies = {
    "nvim-treesitter/nvim-treesitter",
    "neovim/nvim-lspconfig",
    -- "nvim-tree/nvim-web-devicons", -- optional, for language icons
    -- "folke/snacks.nvim", -- optional, for inline images
  },
  opts = {},
}
```

The treesitter parser is automatically compiled on first load.

### Manual

1. Add the plugin to your runtime path
2. Call `require("ipynb").setup()` (parser auto-compiles on first load)

## 🚀 Usage

### 1. Open a notebook

  ```sh
  nvim notebook.ipynb
  ```

  ```vim
  -- or from in neovim:
  :e notebook.ipynb
  -- or
  :NotebookCreate notebook.ipynb 
  ```

### 2. Edit a cell

- Place your cursor anywhere on a cell (you can quickly navigate using `]]` (next) and `[[` (previous), though any vim motions will work)
- Press `i` (INSERT) or `<CR>` (NORMAL) to enter edit mode for the current cell
- Press `<Esc>` to exit edit mode and return to navigation mode

### 3. Start a kernel

- Start a Jupyter kernel with `:NotebookKernelStart` (default keymap: `<leader>ks`)

### 4. Execute a cell

- Execute a cell with `:NotebookExecuteCell` (default keymap: `<leader>kx`)

### 5. View outputs

- Outputs render inline as virtual lines below the cell
- Use `:NotebookOutput` (default keymap: `<leader>ko`) to open the output in a floating window for easy copying

### 6. Inspect variables

- Place your cursor on a variable and inspect it using `:NotebookInspect` (default keymap: `<leader>kh`)
- Inspect all variables in cell using `:NotebookInspectCell` (default keymap: `<leader>kv`)

## 🐍 Python Environment *(for Jupyter kernels)*

When starting a kernel, the plugin looks for Python in this order:

1. **Path argument** passed to `:NotebookKernelStart`
2. **`kernel.python_path`** in config
3. **Virtual environment** found by walking up from the notebook's directory, checking for `.venv`, `venv`, `.virtualenv`, or `env`
4. **System Python** (`python3` or `python` in PATH)

```vim
" Use a specific Python for this session
:NotebookKernelStart /path/to/venv/bin/python

" Or configure a default in setup
```

```lua
require("ipynb").setup({
  kernel = {
    python_path = "/path/to/your/venv/bin/python",
  },
})
```

## 🗂️ Multi-Language Support

> [!WARNING]
> `R.nvim` is unsupported! Please disable it when using this plugin.

The plugin reads the language from notebook metadata and automatically configures:

- **Syntax highlighting** via tree-sitter language injection
- **LSP** by setting the shadow buffer's filetype (triggers your LSP config)
- **Kernel execution** via `jupyter_client` (supports any installed Jupyter kernel)

The default language when creating a new notebook is Python. You can specify a kernel when creating:

```vim
:NotebookCreate mynotebook julia-1.10
:NotebookCreate analysis ir          " R kernel
```

Or change an existing notebook's kernel with `:NotebookSetKernel`:

```vim
:NotebookSetKernel julia-1.12
:NotebookSetKernel ir           " R kernel
:NotebookSetKernel python3
```

This updates the notebook metadata and re-attaches the appropriate LSP.

**Requirements per language:**

- Install the Jupyter kernel (e.g., `IJulia` for Julia, `IRkernel` for R)
- Install an LSP server (e.g., `julials`, `r_language_server`)
- Configure the LSP in your Neovim setup

## ⚙️ Configuration

`ipynb.nvim` is highly configurable. Expand to see the default configuration below.

<details><summary>Default Options</summary>

<!-- config:start -->
```lua
require("ipynb").setup({
  keymaps = {
    -- Navigation (navigation buffer)
    next_cell = "]]",              -- jump to next cell
    prev_cell = "[[",              -- jump to previous cell
    -- Navigation (navigation and edit buffers)
    jump_to_cell = "<leader>kj",   -- open cell picker
    -- Cell operations (navigation buffer)
    cut_cell = "dd",               -- cut cell to register
    paste_cell_below = "p",        -- paste cell below
    paste_cell_above = "P",        -- paste cell above
    move_cell_down = "<M-j>",      -- move cell down
    move_cell_up = "<M-k>",        -- move cell up
    -- Cell operations (navigation and edit buffers)
    add_cell_above = "<leader>ka", -- insert cell above
    add_cell_below = "<leader>kb", -- insert cell below
    make_markdown = "<leader>km",  -- convert to markdown cell
    make_code = "<leader>ky",      -- convert to code cell
    make_raw = "<leader>kr",       -- convert to raw cell
    fold_toggle = "<leader>kf",    -- toggle cell fold
    -- Execution (navigation and edit buffers)
    execute_cell = "<C-CR>",            -- execute cell, stay
    execute_and_next = "<S-CR>",        -- execute cell, move to next
    execute_and_insert = "<M-CR>",      -- execute cell, insert new below
    execute_all_below = nil,            -- execute current and all below (unmapped)
    menu_execute_cell = "<leader>kx",   -- execute cell (menu, if <C-CR> conflicts)
    menu_execute_and_next = "<leader>kX", -- execute and next (menu, if <S-CR> conflicts)
    -- Output (navigation and edit buffers)
    open_output = "<leader>ko",      -- open cell output in float (for copying)
    clear_output = "<leader>kc",     -- clear current cell output
    clear_all_outputs = "<leader>kC", -- clear all outputs
    -- Kernel (navigation and edit buffers)
    interrupt_kernel = "<C-c>",      -- interrupt execution
    kernel_interrupt = "<leader>ki", -- interrupt (menu)
    kernel_restart = "<leader>k0",   -- restart kernel
    kernel_start = "<leader>ks",     -- start kernel
    kernel_shutdown = "<leader>kS",  -- shutdown kernel
    kernel_info = "<leader>kn",      -- show kernel info
    -- Inspector (navigation and edit buffers)
    variable_inspect = "<leader>kh", -- inspect variable at cursor
    cell_variables = "<leader>kv",   -- show all variables in cell
    toggle_auto_hover = "<leader>kH", -- toggle auto-hover on CursorHold
    -- Note: i, a, I, A, o, O, <CR> enter edit mode; <Esc> exits
    -- Note: u, <C-r> perform global undo/redo across cells in both navigation and edit modes
    -- Note: <C-j>/<C-k> navigate cells while editing
    -- Note: LSP commands (go to definition, references, hover, etc.) are proxied
  },
  -- Highlight groups for various notebook elements
  highlights = {
    -- For notebook
    border = "Comment",           -- Cell border
    border_hover = "Special",     -- Cell border when cursor on cell
    border_active = "Number",     -- Cell border when editing
    exec_count = "Number",        -- Execution count [N]
    output = "Comment",           -- Output text
    hint = "Comment",             -- Cell action keymap hints
    -- For statusline
    output_error = "DiagnosticError",
    executing = "DiagnosticWarn", -- Executing indicator
    queued = "DiagnosticHint",    -- Queued indicator
  },
  -- Cell border action keymap hints
  border_hints = {
    enabled = true,        -- Show action hints on active cell border
    show_on_hover = true,  -- Show hints in navigation mode
    show_on_edit = true,   -- Show hints in edit mode
  },
  kernel = {
    auto_connect = false,  -- Auto-connect to kernel on notebook open
    show_status = true,    -- Show kernel status in statusline
    python_path = nil,     -- Custom Python path (otherwise auto-discovered)
  },
  images = {
    enabled = true,
    cache_dir = vim.fn.stdpath("cache") .. "/ipynb.nvim",
    max_width = nil,   -- nil = window width minus sign/number columns
    max_height = nil,  -- nil = window height minus scrolloff minus 1
  },
  inspector = {
    -- Keymaps while in cell variable inspector float window
    close = { "q", "<Esc>" },   -- Keys to close inspector window
    inspect = { "K", "<CR>" },  -- Keys to inspect variable under cursor
    -- Auto-hover inspect configuration
    auto_hover = {
      enabled = false,  -- Auto-show variable hover on CursorHold
      delay = 500,     -- Milliseconds before showing hover
    },
  },
  -- Cell folding configuration
  folding = {
    hide_output = false,  -- Hide output when folded (includes cell end marker in fold)
  },
  -- LSP formatting configuration -- vim.lsp.buf.format() integration
  format = {
    enabled = true,  -- Wrap vim.lsp.buf.format() to work with notebooks
    -- Each cell is formatted as an individual document
    -- with some formatters adding trailing blank lines.
    -- This option control how many blank lines to keep:
    trailing_blank_lines = 0,  -- # trailing blank lines to keep per cell when formatted
  },
})
```
<!-- config:end -->

</details>

## ⌨️ Commands

| Command | Description | Config | Default Keymap |
|---------|-------------|--------|---------|
| `:NotebookCreate [path] [kernel]` | Create new notebook | | |
| `:NotebookSave` | Save notebook | | |
| `:NotebookInfo` | Show notebook and cell info | | |
| `:NotebookJumpToCell` | Open cell picker | `jump_to_cell` | `<leader>kj` |
| `:NotebookInsertCellBelow` | Insert cell below | `add_cell_below` | `<leader>kb` |
| `:NotebookInsertCellAbove` | Insert cell above | `add_cell_above` | `<leader>ka` |
| `:NotebookDeleteCell` | Delete current cell | | |
| `:NotebookCutCell` | Cut cell to register | `cut_cell` | `dd` |
| `:NotebookPasteCellBelow` | Paste cell below | `paste_cell_below` | `p` |
| `:NotebookPasteCellAbove` | Paste cell above | `paste_cell_above` | `P` |
| `:NotebookMoveCellUp` | Move cell up | `move_cell_up` | `<M-k>` |
| `:NotebookMoveCellDown` | Move cell down | `move_cell_down` | `<M-j>` |
| `:NotebookToggleCellType` | Toggle code/markdown | | |
| `:NotebookMakeMarkdown` | Convert to markdown | `make_markdown` | `<leader>km` |
| `:NotebookMakeCode` | Convert to code | `make_code` | `<leader>ky` |
| `:NotebookMakeRaw` | Convert to raw | `make_raw` | `<leader>kr` |
| `:NotebookExecuteCell` | Execute cell, stay | `execute_cell` | `<C-CR>` |
| `:NotebookExecuteAndNext` | Execute cell, move next | `execute_and_next` | `<S-CR>` |
| `:NotebookExecuteAllBelow` | Execute current and below | `execute_all_below` | (unmapped) |
| `:NotebookOutput` | Open output in float | `open_output` | `<leader>ko` |
| `:NotebookClearOutput` | Clear cell output | `clear_output` | `<leader>kc` |
| `:NotebookClearAllOutputs` | Clear all outputs | `clear_all_outputs` | `<leader>kC` |
| `:NotebookFoldCell` | Toggle cell fold | `fold_toggle` | `<leader>kf` |
| `:NotebookFoldAll` | Fold all cells | | |
| `:NotebookUnfoldAll` | Unfold all cells | | |
| `:NotebookFormatCell` | Format cell via LSP | | |
| `:NotebookFormatAll` | Format all code cells | | |
| `:NotebookKernelStart [path]` | Start kernel | `kernel_start` | `<leader>ks` |
| `:NotebookKernelConnect <file>` | Connect to kernel | | |
| `:NotebookSetKernel <name>` | Set kernelspec | | |
| `:NotebookListKernels` | List available Jupyter kernels | | |
| `:NotebookKernelInterrupt` | Interrupt execution | `interrupt_kernel` | `<C-c>` |
| `:NotebookKernelRestart` | Restart kernel | `kernel_restart` | `<leader>k0` |
| `:NotebookKernelShutdown` | Shutdown kernel | `kernel_shutdown` | `<leader>kS` |
| `:NotebookKernelStatus` | Show kernel status | `kernel_info` | `<leader>kn` |
| `:NotebookInspect` | Inspect variable at cursor | `variable_inspect` | `<leader>kh` |
| `:NotebookInspectCell` | Show all cell variables | `cell_variables` | `<leader>kv` |
| `:NotebookToggleAutoHover` | Toggle auto-hover | `toggle_auto_hover` | `<leader>kH` |

Note: `vim.lsp.buf.format()` is wrapped to work with notebooks automatically.
Disable with `format.enabled = false`.

## 🚥 Statusline

The plugin provides a statusline component showing kernel status. Add it to your statusline (e.g., lualine):

```lua
-- lualine example
require("lualine").setup({
  sections = {
    lualine_x = {
      {
        require("ipynb.kernel").statusline,
        cond = require("ipynb.kernel").statusline_visible,
        color = require("ipynb.kernel").statusline_color,
      },
    },
  },
})
```

Shows language icon (from nvim-web-devicons) + status with theme-aware colors:

- `IDLE` (green, from `DiagnosticOk`)
- `BUSY` (yellow, from `DiagnosticWarn`)
- `DISC` (red, from `DiagnosticError`)

Disable with `kernel.show_status = false` in setup.

## 🩺 Troubleshooting

**Health check**

Run `:checkhealth ipynb` to verify all dependencies are properly configured.

**Parser not found**

The parser should auto-compile on first load. If it fails:

- Ensure nvim-treesitter is installed
- Run `:TSInstall! ipynb` to manually compile

**No LSP**

Ensure you have a language server installed for the notebook's language.
Check `:LspInfo` while in the notebook to see attached clients.

**Kernel won't start**

Check `:NotebookKernelStatus` for the Python path being used.
Ensure `jupyter_client` is installed: `pip install jupyter_client`
For non-Python kernels, ensure the kernel is installed (e.g., IJulia, IRkernel).

**Images not showing**

Requires snacks.nvim and a terminal which fully supports the kitty graphics protocol (kitty, Ghostty). For tmux, set `allow-passthrough=on`.

## 🗺️ Roadmap

✅ **Working:**

- [x] Read/write .ipynb files
- [x] Cell navigation and editing
- [x] Kernel execution and output capture
- [x] Inline image rendering
- [x] Variable inspector (Jupyter inspect protocol, auto-hover)
- [x] Partial LSP support (diagnostics, completion, hover, definition, references, rename, formatting)
- [x] Multi-language support (Python, Julia, R, etc.)
- [x] Cell folding
- [x] Cell formatting via LSP (`:NotebookFormatCell`, `:NotebookFormatAll`, or `vim.lsp.buf.format()`)
- [x] Health check (`:checkhealth ipynb`)

🕒 **Not Yet Implemented:**

- Document symbols (`textDocument/documentSymbol`) - outline/symbol pickers
- Signature help (`textDocument/signatureHelp`) - function signature hints
- Document highlight (`textDocument/documentHighlight`) - highlight symbol references
- Inlay hints (`textDocument/inlayHint`) - inline type hints

🚫 **Not Supported:**

- Code actions (`textDocument/codeAction`) - code actions can modify arbitrary ranges potentially spanning cell boundaries, making them unsafe for notebooks
