#!/usr/bin/env bash
# Fresh-install test: starts this config on a machine with nothing installed
# and checks that Neovim sets everything up by itself.
#
# Copies the config into a temp dir and points Neovim's config/data/state/
# cache dirs (XDG_*_HOME) there, so the real ~/.local/share/nvim is untouched.
# Then, using tests/fresh_install_check.lua:
#   1. first start: lazy.nvim installs every plugin; each must be at its
#      lazy-lock.json commit
#   2. the config's ensure_installed parsers must all compile
#   3. a clean restart prints no errors, and sample files get treesitter
#      highlighting
# Any output containing "Error", "E<number>:" or "Failed" also fails a step.
# All steps run even after a failure; the script exits 1 if any failed.
#
# Needs network (GitHub), git, a C compiler, and Neovim 0.10 or 0.11
# (nvim-treesitter master does not support 0.12). Takes a few minutes.
# Usage: tests/fresh-install.sh   (NVIM=/path/to/nvim to pick a binary,
#                                  KEEP=1 to keep the temp dir for debugging)
set -euo pipefail

root="$(dirname "$(dirname "$(readlink -f "$0")")")"
nvim="${NVIM:-nvim}"
check="$root/tests/fresh_install_check.lua"

version="$("$nvim" --version | head -1)"
echo "Using $version"
case "$version" in
  "NVIM v0.10."*|"NVIM v0.11."*) ;;
  *) echo "FAIL: nvim-treesitter master supports Neovim 0.10 and 0.11 only" >&2; exit 1 ;;
esac

work="$(mktemp -d)"
if [ -n "${KEEP:-}" ]; then
  echo "Temp dir: $work"
else
  trap 'rm -rf "$work"' EXIT
fi

mkdir -p "$work/config"
cp -a "$root" "$work/config/nvim"
rm -rf "$work/config/nvim/.git"
export XDG_CONFIG_HOME="$work/config" XDG_DATA_HOME="$work/data" \
       XDG_STATE_HOME="$work/state" XDG_CACHE_HOME="$work/cache"

# Hard limit per nvim run, so a hung check can't stall the script.
limit=()
command -v timeout >/dev/null && limit=(timeout 900)

# Runs nvim headless with the user config, then the given check step.
# A step fails if nvim exits non-zero or prints anything that looks like an
# error. Later steps still run, so one run shows every symptom.
failed=()
run_step() {
  local step="$1"; shift
  local log="$work/$step.log"
  echo "== $step"
  local status=0
  FRESH_CHECK="$step" "${limit[@]}" "$nvim" --headless "$@" -c "luafile $check" \
    >"$log" 2>&1 || status=$?
  if [ "$status" -ne 0 ] || grep -qaE "Error|E[0-9]+:|Failed" "$log"; then
    tr '\r' '\n' <"$log" | grep -av "Downloading" | grep -v '^$' | tail -25 >&2
    echo "FAIL: '$step' (nvim exit $status; full log: $log, KEEP=1 keeps it)" >&2
    failed+=("$step")
  else
    echo "ok"
  fi
}

run_step plugins
run_step parsers
run_step files

if [ "${#failed[@]}" -gt 0 ]; then
  echo "FAIL: fresh install (${failed[*]})" >&2
  exit 1
fi
echo "PASS: fresh install"
