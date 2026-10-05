-- ── Claude status ───────────────────────────────────────────────────────────
-- scripts/claude-status-hook.sh (registered as a Claude Code hook in
-- ~/.claude/settings.json) writes one JSON file per session into STATUS_DIR.
-- Sessions started before the hook was installed have no file; for those we
-- fall back to guessing from the tail of the session transcript.

local STATUS_DIR = (vim.env.XDG_STATE_HOME or vim.fn.expand("~/.local/state")) .. "/nvim-claude-status"

local CLAUDE = {
  permission = { icon = "❓", label = "waiting for your approval" },
  tool       = { icon = "🔧", label = "running a tool" },
  working    = { icon = "⏳", label = "working" },
  done       = { icon = "✅", label = "done / idle" },
  none       = { icon = "  ", label = "not running" },
}
-- When several sessions share a worktree, show the one that most needs you.
local PRIORITY = { permission = 4, tool = 3, working = 2, done = 1, none = 0 }

local function strip_slash(path)
  return (path:gsub("/$", ""))
end

-- { [pid] = cwd } for every process named `claude`.
local function claude_processes()
  local procs = {}
  for _, proc in ipairs(vim.fn.glob("/proc/[0-9]*", false, true)) do
    local ok, comm = pcall(vim.fn.readfile, proc .. "/comm", "", 1)
    if ok and comm[1] == "claude" then
      local cwd = vim.uv.fs_readlink(proc .. "/cwd")
      if cwd then procs[tonumber(proc:match("%d+$"))] = strip_slash(cwd) end
    end
  end
  return procs
end

local function read_tail_lines(path)
  local fd = vim.uv.fs_open(path, "r", 438)
  if not fd then return {} end
  local st = vim.uv.fs_fstat(fd)
  local off = math.max(0, st.size - 65536)
  local chunk = vim.uv.fs_read(fd, st.size - off, off) or ""
  vim.uv.fs_close(fd)
  local lines = {}
  for line in chunk:gmatch("[^\n]+") do table.insert(lines, line) end
  return lines
end

-- Last user/assistant entry of a session transcript (.jsonl), decoded.
local function last_turn_entry(transcript)
  local lines = read_tail_lines(transcript)
  for i = #lines, 1, -1 do
    local ok, msg = pcall(vim.json.decode, lines[i])
    if ok and type(msg) == "table" and (msg.type == "assistant" or msg.type == "user") then
      return msg
    end
  end
end

-- Esc in Claude fires no hook; the transcript gets "[Request interrupted by user…]".
local function is_interrupt(entry)
  if not entry or entry.type ~= "user" or not entry.message then return false end
  local content = entry.message.content
  if type(content) == "string" then return content:find("^%[Request interrupted by user") ~= nil end
  if type(content) == "table" then
    for _, part in ipairs(content) do
      if type(part) == "table" and type(part.text) == "string"
        and part.text:find("^%[Request interrupted by user") then
        return true
      end
    end
  end
  return false
end

-- Fallback for sessions without a status file. A pending tool call can't be
-- told apart from a permission prompt here, so it shows as "tool".
local function guess_from_transcript(cwd)
  local proj = vim.fn.expand("~/.claude/projects/" .. cwd:gsub("[/.]", "-"))
  local newest, newest_mtime = nil, 0
  for _, f in ipairs(vim.fn.glob(proj .. "/*.jsonl", false, true)) do
    local st = vim.uv.fs_stat(f)
    if st and st.mtime.sec > newest_mtime then newest, newest_mtime = f, st.mtime.sec end
  end
  if not newest then return "working" end
  local msg = last_turn_entry(newest)
  if not msg then return "working" end
  if is_interrupt(msg) then return "done" end
  if msg.type == "assistant" then
    local sr = msg.message and msg.message.stop_reason
    if sr == "end_turn" or sr == "stop_sequence" or sr == "max_tokens" then return "done" end
    if sr == "tool_use" then return "tool" end
  end
  return "working"
end

-- List of { cwd, state, tool } for every live Claude session.
local function claude_sessions()
  local procs = claude_processes()
  local running_cwds = {}
  for _, cwd in pairs(procs) do running_cwds[cwd] = true end

  local sessions, covered = {}, {}
  for _, f in ipairs(vim.fn.glob(STATUS_DIR .. "/*.json", false, true)) do
    local ok, s = pcall(function() return vim.json.decode(table.concat(vim.fn.readfile(f), "\n")) end)
    if ok and type(s) == "table" and type(s.cwd) == "string" then
      local cwd = strip_slash(s.cwd)
      local pid = type(s.pid) == "number" and s.pid > 0 and s.pid or nil
      local alive
      if pid then
        alive = procs[pid] ~= nil
      else
        alive = running_cwds[cwd] ~= nil
      end
      if not alive then
        os.remove(f) -- process died without SessionEnd (e.g. killed with nvim)
      else
        local state = s.state
        if state ~= "done" and type(s.transcript_path) == "string"
          and is_interrupt(last_turn_entry(s.transcript_path)) then
          state = "done"
        end
        table.insert(sessions, { cwd = cwd, state = state, tool = s.tool ~= vim.NIL and s.tool or nil })
        covered[pid or cwd] = true
      end
    end
  end

  for pid, cwd in pairs(procs) do
    if not covered[pid] and not covered[cwd] then
      table.insert(sessions, { cwd = cwd, state = guess_from_transcript(cwd) })
    end
  end
  return sessions
end

-- { [worktree_path] = { state, tool } }. A session belongs to the worktree
-- with the longest path containing its cwd, so Claude started in a
-- subdirectory still counts.
local function claude_status_by_worktree(worktree_paths)
  local status = {}
  for _, s in ipairs(claude_sessions()) do
    local best
    for _, wt in ipairs(worktree_paths) do
      if (s.cwd == wt or vim.startswith(s.cwd, wt .. "/")) and (not best or #wt > #best) then
        best = wt
      end
    end
    if best then
      local cur = status[best]
      if not cur or PRIORITY[s.state] > PRIORITY[cur.state] then
        status[best] = { state = s.state, tool = s.tool }
      end
    end
  end
  return status
end

-- ── Worktrees ───────────────────────────────────────────────────────────────

-- Parses `git worktree list --porcelain` (handles spaces in paths, detached
-- HEAD, bare and prunable worktrees).
local function list_worktrees()
  local out = vim.fn.systemlist({ "git", "worktree", "list", "--porcelain" })
  if vim.v.shell_error ~= 0 then return {} end
  local worktrees, cur = {}, nil
  for _, line in ipairs(out) do
    local key, val = line:match("^(%S+) ?(.*)$")
    if key == "worktree" then
      cur = { path = strip_slash(val) }
      table.insert(worktrees, cur)
    elseif cur and key == "HEAD" then
      cur.head = val
    elseif cur and key == "branch" then
      cur.branch = val:gsub("^refs/heads/", "")
    elseif cur and key == "detached" then
      cur.detached = true
    elseif cur and key == "bare" then
      cur.bare = true
    elseif cur and key == "prunable" then
      cur.prunable = true
    end
  end
  local result = {}
  for _, wt in ipairs(worktrees) do
    if not wt.bare then
      wt.name = wt.branch or ("(detached " .. (wt.head or ""):sub(1, 7) .. ")")
      table.insert(result, wt)
    end
  end
  return result
end

local function switch_to_worktree_tab(path)
  local abs_path = strip_slash(vim.fn.fnamemodify(path, ":p"))

  -- Check if a tab already exists for this worktree
  for _, tabnr in ipairs(vim.api.nvim_list_tabpages()) do
    local tab_cwd = strip_slash(vim.fn.getcwd(-1, vim.api.nvim_tabpage_get_number(tabnr)))
    if tab_cwd == abs_path then
      vim.api.nvim_set_current_tabpage(tabnr)
      require("lualine.components.branch.git_branch").find_git_dir()
      require("lualine").refresh()
      return
    end
  end

  -- No existing tab — create a new one
  vim.cmd("tabnew")
  vim.cmd("tcd " .. vim.fn.fnameescape(abs_path))
  vim.cmd("edit .")
  require("lualine.components.branch.git_branch").find_git_dir()
  require("lualine").refresh()
end

return {
  "polarmutex/git-worktree.nvim",
  version = "^2",
  dependencies = { "nvim-telescope/telescope.nvim" },
  init = function()
    vim.g.git_worktree = {
      change_directory_command = "tcd",
    }
  end,
  config = function()
    require("telescope").load_extension("git_worktree")
  end,
  keys = {
    {
      "<leader>gw",
      function()
        local pickers = require("telescope.pickers")
        local finders = require("telescope.finders")
        local actions = require("telescope.actions")
        local action_state = require("telescope.actions.state")
        local previewers = require("telescope.previewers")
        local conf = require("telescope.config").values

        -- Build tab info: path -> list of window details
        local tab_windows = {}
        for _, tabnr in ipairs(vim.api.nvim_list_tabpages()) do
          local tabnr_num = vim.api.nvim_tabpage_get_number(tabnr)
          local tab_cwd = strip_slash(vim.fn.getcwd(-1, tabnr_num))
          local wins = {}
          for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(tabnr)) do
            local bufnr = vim.api.nvim_win_get_buf(winid)
            local name = vim.api.nvim_buf_get_name(bufnr)
            local bt = vim.api.nvim_get_option_value("buftype", { buf = bufnr })
            local ft = vim.api.nvim_get_option_value("filetype", { buf = bufnr })
            local modified = vim.api.nvim_get_option_value("modified", { buf = bufnr })
            if bt == "terminal" then
              table.insert(wins, { type = "terminal", name = "Terminal", modified = false })
            elseif name ~= "" then
              local rel = name:gsub("^" .. vim.pesc(tab_cwd) .. "/", "")
              table.insert(wins, { type = ft ~= "" and ft or "file", name = rel, modified = modified })
            end
          end
          tab_windows[tab_cwd] = wins
        end

        local worktrees = list_worktrees()
        local paths = vim.tbl_map(function(wt) return wt.path end, worktrees)
        local status = claude_status_by_worktree(paths)

        local function make_finder()
          return finders.new_table({
            results = worktrees,
            entry_maker = function(wt)
              local st = status[wt.path] or { state = "none" }
              return {
                value = wt.path,
                ordinal = wt.name,
                worktree = wt,
                windows = tab_windows[wt.path],
                claude = st,
                display = CLAUDE[st.state].icon .. " " .. wt.name .. (wt.prunable and "  [missing]" or ""),
              }
            end,
          })
        end

        local preview_ns = vim.api.nvim_create_namespace("git_worktree_preview")
        local worktree_previewer = previewers.new_buffer_previewer({
          title = "Tab Windows",
          define_preview = function(self, entry)
            local bufnr = self.state.bufnr
            local lines = {}
            local highlights = {}

            local claude = CLAUDE[entry.claude.state].label
            if entry.claude.tool then claude = claude .. " (" .. entry.claude.tool .. ")" end

            table.insert(lines, "  Branch: " .. entry.ordinal)
            table.insert(highlights, { line = #lines - 1, col = 2, end_col = 9, hl = "TelescopeResultsIdentifier" })
            table.insert(lines, "  Path:   " .. entry.value)
            table.insert(highlights, { line = #lines - 1, col = 2, end_col = 8, hl = "TelescopeResultsIdentifier" })
            table.insert(lines, "  Claude: " .. claude)
            table.insert(highlights, { line = #lines - 1, col = 2, end_col = 9, hl = "TelescopeResultsIdentifier" })
            if entry.worktree.prunable then
              table.insert(lines, "  Directory is missing; run `git worktree prune`")
              table.insert(highlights, { line = #lines - 1, col = 2, end_col = #lines[#lines], hl = "WarningMsg" })
            end
            table.insert(lines, "")

            local wins = entry.windows
            if not wins or #wins == 0 then
              table.insert(lines, "  No open tab")
              table.insert(highlights, { line = #lines - 1, col = 2, end_col = 13, hl = "TelescopeResultsComment" })
            else
              table.insert(lines, "  Open Windows (" .. #wins .. ")")
              table.insert(highlights, { line = #lines - 1, col = 2, end_col = #lines[#lines], hl = "TelescopeResultsIdentifier" })
              table.insert(lines, "")
              for _, win in ipairs(wins) do
                local icon, hl_icon
                if win.type == "terminal" then
                  icon = ">"
                  hl_icon = "TelescopeResultsSpecialComment"
                else
                  icon = "#"
                  hl_icon = "TelescopeResultsNumber"
                end
                local mod = win.modified and " [+]" or ""
                local line = "  " .. icon .. " " .. win.name .. mod
                table.insert(lines, line)
                table.insert(highlights, { line = #lines - 1, col = 2, end_col = 3, hl = hl_icon })
                if win.modified then
                  table.insert(highlights, { line = #lines - 1, col = #line - 3, end_col = #line, hl = "WarningMsg" })
                end
              end
            end

            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
            for _, hl in ipairs(highlights) do
              vim.api.nvim_buf_set_extmark(bufnr, preview_ns, hl.line, hl.col, { end_col = hl.end_col, hl_group = hl.hl })
            end
          end,
        })

        local picker = pickers.new({}, {
          prompt_title = "Worktrees",
          previewer = worktree_previewer,
          finder = make_finder(),
          sorter = conf.generic_sorter({}),
          attach_mappings = function(prompt_bufnr, map)
            actions.select_default:replace(function()
              local selection = action_state.get_selected_entry()
              if selection and selection.worktree.prunable then
                vim.notify("Worktree directory is missing: " .. selection.value, vim.log.levels.WARN)
                return
              end
              actions.close(prompt_bufnr)
              if selection then
                switch_to_worktree_tab(selection.value)
              end
            end)

            local delete_worktree = function()
              local selection = action_state.get_selected_entry()
              if not selection then return end
              local wt = selection.worktree
              local confirmed = vim.fn.input("Delete worktree " .. wt.name .. "? [y/n]: ")
              if confirmed:lower():sub(1, 1) ~= "y" then
                print(" Cancelled")
                return
              end
              actions.close(prompt_bufnr)
              vim.fn.system({ "git", "worktree", "remove", wt.path })
              if vim.v.shell_error ~= 0 then
                local force = vim.fn.input("Remove failed. Force delete? [y/n]: ")
                if force:lower():sub(1, 1) ~= "y" then return end
                vim.fn.system({ "git", "worktree", "remove", "--force", wt.path })
                if vim.v.shell_error ~= 0 then
                  vim.notify("Could not remove worktree " .. wt.path, vim.log.levels.ERROR)
                  return
                end
              end
              if not wt.branch then return end -- detached HEAD: no branch to delete
              local delete_branch = vim.fn.input("Also delete branch " .. wt.branch .. "? [y/n]: ")
              if delete_branch:lower():sub(1, 1) == "y" then
                vim.fn.system({ "git", "branch", "-D", wt.branch })
                print(" Branch deleted")
              end
            end

            map("i", "<m-d>", delete_worktree)
            map("n", "<m-d>", delete_worktree)
            return true
          end,
        })

        -- Live Claude status: re-check every second while the picker is open,
        -- and rebuild the list only when a state changed, keeping the selection.
        local restore_path
        picker:register_completion_callback(function(p)
          if not restore_path then return end
          local path = restore_path
          restore_path = nil
          local index = 0
          for entry in p.manager:iter() do
            index = index + 1
            if entry.value == path then
              p:set_selection(p:get_row(index))
              return
            end
          end
        end)

        local timer = vim.uv.new_timer()
        timer:start(1000, 1000, vim.schedule_wrap(function()
          if not vim.api.nvim_buf_is_valid(picker.prompt_bufnr or -1) then
            if not timer:is_closing() then timer:stop(); timer:close() end
            return
          end
          local new_status = claude_status_by_worktree(paths)
          if vim.deep_equal(new_status, status) then return end
          status = new_status
          local selection = picker:get_selection()
          restore_path = selection and selection.value
          picker:refresh(make_finder(), { reset_prompt = false })
        end))

        picker:find()
      end,
      desc = "Switch worktree (tab-per-worktree)",
    },
    { "<leader>gc", function() require("telescope").extensions.git_worktree.create_git_worktree() end, desc = "Create worktree" },
  },
}
