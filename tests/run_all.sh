#!/bin/sh
# Cross-platform wrapper for the Lua test runner

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PLUGIN_DIR" || exit 1

exec nvim --headless -l tests/run_all.lua
