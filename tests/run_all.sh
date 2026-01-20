#!/bin/bash
# Run all ipynb.nvim tests
# Usage: ./tests/run_all.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PLUGIN_DIR"

echo "Running ipynb.nvim test suite"
echo "=============================="
echo ""

# Track overall results
TOTAL_PASSED=0
TOTAL_FAILED=0

run_test_file() {
  local test_file="$1"
  local test_name="$(basename "$test_file" .lua)"

  echo ">>> Running $test_name..."
  if nvim --headless -u tests/minimal_init.lua -l "$test_file" 2>&1; then
    echo ""
  else
    TOTAL_FAILED=$((TOTAL_FAILED + 1))
  fi
}

# Run each test file
run_test_file "tests/test_cells.lua"
run_test_file "tests/test_modified.lua"
run_test_file "tests/test_undo.lua"
run_test_file "tests/test_io.lua"

# LSP tests - will skip gracefully if no LSP server available
run_test_file "tests/test_lsp.lua"

echo ""
echo "=============================="
echo "All test suites completed"
