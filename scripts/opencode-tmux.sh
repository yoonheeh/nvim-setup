#!/usr/bin/env bash
# Runs OpenCode inside a tmux session named after the current directory, so it
# keeps running when Neovim exits. Running this again in the same directory
# reconnects to that session instead of starting a new OpenCode.
#
# Used by :OpenCode (lua/yoonhee/opencode.lua); extra arguments are passed to
# opencode when a new session starts.
# The session name must match session_name() in lua/yoonhee/opencode_tmux.lua.
#
# Mirrors scripts/claude-tmux.sh, but on the private `nvim-opencode` server so
# Claude and OpenCode sessions are listed/killed independently.

tmux="$HOME/.local/bin/tmux"
[ -x "$tmux" ] || tmux=tmux
conf="$(dirname "$(readlink -f "$0")")/claude-tmux.conf"

dir=$(pwd -P)
name="opencode${dir//[^a-zA-Z0-9]/-}"

if "$tmux" -L nvim-opencode has-session -t "=$name" 2>/dev/null; then
  exec "$tmux" -L nvim-opencode -f "$conf" attach-session -t "=$name"
fi
exec "$tmux" -L nvim-opencode -f "$conf" new-session -s "$name" -c "$dir" opencode "$@"
