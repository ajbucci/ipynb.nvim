# Contributing to ipynb.nvim

Thanks for your interest in contributing!

## Quick Start

1. Read the architecture overview:
   - `doc/ARCHITECTURE.md`
2. Skim the README:
   - `README.md`
3. Make changes in `lua/` and `python/`.

## Repo Layout

- `lua/` — Lua plugin implementation
- `python/` — Python bridge + inspectors
- `tree-sitter-ipynb/` — treesitter grammar
- `tests/` — headless Neovim test suite

## Development Setup

- Neovim 0.10+
  - `nvim-treesitter` for tree-sitter support
  - `image.nvim` for image rendering and colorized inspect
- a language server (e.g. basedpyright/pyright, julials, r_language_server)
- Python 3.x (for kernel bridge + tests that touch Python)
  - `jupyter_client`, `nbformat` (we recommend installing via `uv` and the project's `pyproject.toml`)

## Running Tests

From the repo root:

```sh
./tests/run_all.sh
```

Notes:

- The test runner bootstraps a minimal Neovim + plugins into a temp XDG dir.
- It will create a small Python venv for LSP tests (basedpyright + ruff) if available.
- Set `IPYNB_TEST_SKIP_BOOTSTRAP=1` to skip lazy.nvim bootstrapping.
- Set `IPYNB_TEST_SKIP_LSP_BOOTSTRAP=1` to skip Python venv/LSP setup.

## Change Guidelines

- Favor incremental, well-tested changes over big refactors.
- Add/extend tests in `tests/` when behavior changes.

## Pull Requests

When opening a PR, please include:

- A short description of the change and motivation
- How you tested (command + platform)
- Screenshots or GIFs if the change is visual

PRs will only be reviewed after all tests pass.
