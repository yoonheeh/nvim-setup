-- Helpers for the tmux sessions that scripts/opencode-tmux.sh runs OpenCode in.
-- Each directory gets one session on the private `nvim-opencode` tmux server.
-- Mirrors lua/yoonhee/claude_tmux.lua; kept separate so Claude and OpenCode
-- sessions are listed/killed independently.

local M = {}

local SOCKET = "nvim-opencode"
local TMUX = vim.fn.expand("~/.local/bin/tmux")
if vim.fn.executable(TMUX) == 0 then TMUX = "tmux" end

local function tmux(args)
  local out = vim.fn.systemlist(vim.list_extend({ TMUX, "-L", SOCKET }, args))
  return vim.v.shell_error == 0, out
end

-- Must match the name built in scripts/opencode-tmux.sh.
function M.session_name(dir)
  local real = vim.uv.fs_realpath(dir) or dir
  return "opencode" .. real:gsub("[^%w]", "-")
end

-- List of { name, attached, path } for every running OpenCode session.
function M.list()
  local ok, out = tmux({ "list-sessions", "-F", "#{session_name}\t#{session_attached}\t#{pane_current_path}" })
  if not ok then return {} end -- no server running
  local sessions = {}
  for _, line in ipairs(out) do
    local name, attached, path = line:match("^(.-)\t(%d+)\t(.*)$")
    if name then
      table.insert(sessions, { name = name, attached = tonumber(attached) > 0, path = path })
    end
  end
  return sessions
end

function M.kill(name)
  return (tmux({ "kill-session", "-t", "=" .. name }))
end

-- :OpenCodeSessions — pick a running OpenCode session and close it.
function M.pick_and_kill()
  local sessions = M.list()
  if #sessions == 0 then
    vim.notify("No OpenCode tmux sessions running", vim.log.levels.INFO)
    return
  end
  vim.ui.select(sessions, {
    prompt = "Close OpenCode session",
    format_item = function(s)
      return vim.fn.fnamemodify(s.path, ":~") .. (s.attached and "  (open in a terminal)" or "")
    end,
  }, function(s)
    if not s then return end
    local answer = vim.fn.input("Close OpenCode in " .. vim.fn.fnamemodify(s.path, ":~") .. "? [y/n]: ")
    if answer:lower():sub(1, 1) ~= "y" then return end
    if M.kill(s.name) then
      vim.notify("Closed " .. s.name, vim.log.levels.INFO)
    else
      vim.notify("Could not close " .. s.name, vim.log.levels.ERROR)
    end
  end)
end

return M
