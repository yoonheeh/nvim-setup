#!/usr/bin/env bash
# Headless regression tests for agent-review.nvim (plenary busted harness).
# Usage: ./run.sh  (from any directory)
set -euo pipefail

dir="$(dirname "$(readlink -f "$0")")"
data_dir="$(nvim --headless --clean -u NONE --cmd "lua print(vim.fn.stdpath('data'))" +qa 2>&1 | tail -1)"
plenary="$data_dir/lazy/plenary.nvim"
if [ ! -d "$plenary" ]; then
  echo "plenary.nvim not found at $plenary (expected via the lazy.nvim setup)" >&2
  exit 1
fi

# The outer instance only hosts the harness; each spec file runs in a fresh
# child instance booted from minimal_init.lua (no user config, no network).
exec nvim --headless --noplugin -u NONE \
  --cmd "set rtp+=$plenary" \
  -c "runtime plugin/plenary.vim" \
  -c "PlenaryBustedDirectory $dir/ { minimal_init = '$dir/minimal_init.lua', sequential = true }"
