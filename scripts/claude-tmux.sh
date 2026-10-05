#!/usr/bin/env bash
# Runs Claude inside a tmux session named after the current directory, so it
# keeps running when Neovim exits. Running this again in the same directory
# reconnects to that session instead of starting a new Claude.
#
# Used as claude-code.nvim's `command` (lua/plugins/claude-code.lua); extra
# arguments (e.g. --continue) are passed to claude when a new session starts.
# The session name must match session_name() in lua/yoonhee/claude_tmux.lua.

tmux="$HOME/.local/bin/tmux"
[ -x "$tmux" ] || tmux=tmux
conf="$(dirname "$(readlink -f "$0")")/claude-tmux.conf"

dir=$(pwd -P)
name="claude${dir//[^a-zA-Z0-9]/-}"

if "$tmux" -L nvim-claude has-session -t "=$name" 2>/dev/null; then
  exec "$tmux" -L nvim-claude -f "$conf" attach-session -t "=$name"
fi
exec "$tmux" -L nvim-claude -f "$conf" new-session -s "$name" -c "$dir" claude "$@"
