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

local function is_valid_buf()
  return buf and vim.api.nvim_buf_is_valid(buf)
end

-- The terminal buffer outlives the float (bufhidden=hide, like
-- claude-code.nvim), so :b# can jump back to OpenCode after opening a file.
-- Only the window is dropped on close; the buffer is dropped when its
-- terminal job exits.
local function close()
  if is_valid_win() then
    vim.api.nvim_win_close(win, true)
  end
  win = nil
end

--- True while the fullscreen float is showing.
function M.is_open()
  return is_valid_win()
end

--- Detach the tmux client and drop the float. The server session lives on.
function M.close()
  close()
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

  -- Reuse the live terminal buffer when there is one (it survived the float
  -- being closed); otherwise start fresh. A leftover non-terminal buffer
  -- (dead job) is replaced.
  local reuse = is_valid_buf()
    and vim.api.nvim_get_option_value("buftype", { buf = buf }) == "terminal"
  if not reuse then
    if is_valid_buf() then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
    vim.api.nvim_set_option_value("bufhidden", "hide", { buf = buf })
    vim.api.nvim_set_option_value("buflisted", false, { buf = buf })
    vim.b[buf].opencode_float = true
  end

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

  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      -- Closing the float detaches the tmux client; the server session lives
      -- on and the terminal buffer is kept so :b# can jump back to it.
      win = nil
    end,
  })

  if reuse then
    vim.cmd("startinsert")
    return
  end

  local job = vim.fn.termopen(cmd, {
    cwd = cwd,
    on_exit = function()
      vim.schedule(function()
        -- opencode quit -> tmux session ended; the terminal buffer is dead,
        -- so drop it too (a fresh one is created on next open).
        local dead = buf
        close()
        buf = nil
        if dead and vim.api.nvim_buf_is_valid(dead) then
          pcall(vim.api.nvim_buf_delete, dead, { force = true })
        end
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

end

function M.setup()
  vim.api.nvim_create_user_command("OpenCode", function(opts)
    M.open(opts.args)
  end, { nargs = "*", desc = "Open OpenCode in a fullscreen float (tmux-backed, per-directory)" })

  vim.api.nvim_create_user_command("OpenCodeSessions", function()
    require("yoonhee.opencode_tmux").pick_and_kill()
  end, { desc = "Close a running OpenCode tmux session" })

  -- Deliberately no TelescopeFindPre auto-close here: telescope opens the
  -- file in the window that was current before the picker (original_win_id),
  -- i.e. inside this float — the same as claude-code.nvim. The hidden
  -- terminal survives (bufhidden=hide), so :b# toggles file <-> OpenCode.
  -- Detaching first would rebase `#` onto the buffer underneath instead.
end

-- Test seam for headless regression tests (see tests/opencode_spec.lua).
-- Mirrors agent-review.nvim's M._test: committed specs use only the public
-- API plus these read-only internals, never debug.getupvalue hacks.
M._test = {
  get_buf = function() return buf end,
  get_win = function() return win end,
  is_valid_buf = is_valid_buf,
}

return M
