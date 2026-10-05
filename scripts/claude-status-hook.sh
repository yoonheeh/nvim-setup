#!/usr/bin/env bash
# Claude Code hook: records each session's state so the <leader>gw worktree
# picker (lua/plugins/git-worktree.lua) can show it live.
#
# Writes ${XDG_STATE_HOME:-~/.local/state}/nvim-claude-status/<session_id>.json
# and removes it on SessionEnd. Registered in ~/.claude/settings.json.
#
# Always exits 0: a hook that fails (or exits 2) would interrupt Claude.

dir="${XDG_STATE_HOME:-$HOME/.local/state}/nvim-claude-status"
mkdir -p "$dir" 2>/dev/null || exit 0

input=$(cat)
sid=$(jq -r '.session_id // empty' <<<"$input" 2>/dev/null)
event=$(jq -r '.hook_event_name // empty' <<<"$input" 2>/dev/null)
[ -n "$sid" ] && [ -n "$event" ] || exit 0
file="$dir/$sid.json"

case "$event" in
  SessionStart)              state=done ;;
  UserPromptSubmit)          state=working ;;
  PreToolUse)                state=tool ;;
  PermissionRequest)         state=permission ;;
  PostToolUse|PostToolUseFailure|PermissionDenied|SubagentStop) state=working ;;
  Stop|StopFailure)          state=done ;;
  Notification)
    case "$(jq -r '.notification_type // empty' <<<"$input")" in
      permission_prompt) state=permission ;;
      idle_prompt)       state=done ;;
      *)                 exit 0 ;;
    esac ;;
  SessionEnd)                rm -f "$file"; exit 0 ;;
  *)                         exit 0 ;;
esac

# The picker checks this PID to drop sessions whose process died without
# SessionEnd (e.g. killed with nvim). Walk up to the nearest `claude` process.
pid=$PPID
for _ in 1 2 3 4 5 6; do
  [ "$(cat "/proc/$pid/comm" 2>/dev/null)" = claude ] && break
  pid=$(awk '{print $4}' "/proc/$pid/stat" 2>/dev/null) || break
  [ -n "$pid" ] && [ "$pid" -gt 1 ] || break
done
[ "$(cat "/proc/$pid/comm" 2>/dev/null)" = claude ] || pid=0

tmp="$file.$$"
jq -c --arg state "$state" --argjson pid "${pid:-0}" --argjson ts "$(date +%s)" \
  '{session_id, cwd, transcript_path, state: $state, tool: (.tool_name // null), pid: $pid, ts: $ts}' \
  <<<"$input" >"$tmp" 2>/dev/null && mv -f "$tmp" "$file"
rm -f "$tmp"
exit 0
