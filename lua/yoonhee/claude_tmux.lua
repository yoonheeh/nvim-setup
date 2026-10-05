-- Helpers for the tmux sessions that scripts/claude-tmux.sh runs Claude in.
-- Each directory gets one session on the private `nvim-claude` tmux server.

local M = {}

local SOCKET = "nvim-claude"
local TMUX = vim.fn.expand("~/.local/bin/tmux")
if vim.fn.executable(TMUX) == 0 then TMUX = "tmux" end

local function tmux(args)
  local out = vim.fn.systemlist(vim.list_extend({ TMUX, "-L", SOCKET }, args))
  return vim.v.shell_error == 0, out
end

-- Must match the name built in scripts/claude-tmux.sh.
function M.session_name(dir)
  local real = vim.uv.fs_realpath(dir) or dir
  return "claude" .. real:gsub("[^%w]", "-")
end

-- List of { name, attached, path } for every running Claude session.
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

-- :ClaudeSessions — pick a running Claude session and close it.
function M.pick_and_kill()
  local sessions = M.list()
  if #sessions == 0 then
    vim.notify("No Claude tmux sessions running", vim.log.levels.INFO)
    return
  end
  vim.ui.select(sessions, {
    prompt = "Close Claude session",
    format_item = function(s)
      return vim.fn.fnamemodify(s.path, ":~") .. (s.attached and "  (open in a terminal)" or "")
    end,
  }, function(s)
    if not s then return end
    local answer = vim.fn.input("Close Claude in " .. vim.fn.fnamemodify(s.path, ":~") .. "? [y/n]: ")
    if answer:lower():sub(1, 1) ~= "y" then return end
    if M.kill(s.name) then
      vim.notify("Closed " .. s.name, vim.log.levels.INFO)
    else
      vim.notify("Could not close " .. s.name, vim.log.levels.ERROR)
    end
  end)
end

return M
