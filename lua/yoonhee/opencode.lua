-- :OpenCode launcher. Opens scripts/opencode-tmux.sh in a fullscreen float,
-- mirroring :ClaudeCode (greggh/claude-code.nvim, 100%x100% float, border none).
-- The tmux session survives Neovim exits; reopening in the same directory
-- reconnects instead of starting a new OpenCode.

local M = {}

local win = nil
local buf = nil

local function is_valid_win()
  return win and vim.api.nvim_win_is_valid(win)
end

local function close()
  if is_valid_win() then
    vim.api.nvim_win_close(win, true)
  end
  win, buf = nil, nil
end

--- Open (or toggle closed) the OpenCode float.
---@param args string extra args passed to `opencode` when a new session starts
function M.open(args)
  if is_valid_win() then
    close()
    return
  end

  local script = vim.fn.stdpath("config") .. "/scripts/opencode-tmux.sh"
  if vim.fn.executable(script) == 0 then
    vim.notify("[opencode] script not executable: " .. script, vim.log.levels.ERROR)
    return
  end

  local cwd = vim.fn.getcwd() -- respects tab-local :tcd (worktree tabs)
  local cmd = vim.fn.shellescape(script) .. ((args and args ~= "") and (" " .. args) or "")

  buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  vim.api.nvim_set_option_value("buflisted", false, { buf = buf })
  vim.b[buf].opencode_float = true

  local width = vim.o.columns
  local height = vim.o.lines - vim.o.cmdheight - 1
  if height < 1 then height = 1 end

  win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = 0,
    col = 0,
    width = width,
    height = height,
    border = "none",
    style = "minimal",
  })

  local job = vim.fn.termopen(cmd, {
    cwd = cwd,
    on_exit = function()
      vim.schedule(function()
        -- opencode quit -> session ended; drop the now-dead float
        if not is_valid_win() then
          win, buf = nil, nil
          return
        end
        close()
      end)
    end,
  })
  if job <= 0 then
    vim.notify("[opencode] failed to start terminal", vim.log.levels.ERROR)
    close()
    return
  end

  -- Exit terminal-mode with Esc Esc (toggleterm defines this only for its own
  -- floats, so set it buffer-locally here too).
  vim.keymap.set("t", "<Esc><Esc>", [[<C-\><C-n>]], { buffer = buf, desc = "Exit terminal mode" })

  vim.cmd("startinsert")

  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      -- Closing the float detaches the tmux client; the server session lives on.
      win, buf = nil, nil
    end,
  })
end

function M.setup()
  vim.api.nvim_create_user_command("OpenCode", function(opts)
    M.open(opts.args)
  end, { nargs = "*", desc = "Open OpenCode in a fullscreen float (tmux-backed, per-directory)" })

  vim.api.nvim_create_user_command("OpenCodeSessions", function()
    require("yoonhee.opencode_tmux").pick_and_kill()
  end, { desc = "Close a running OpenCode tmux session" })
end

return M
