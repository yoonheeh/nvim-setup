local CLAUDE_ICONS = { working = "⏳", asking = "❓", done = "✅", none = "  " }

local function claude_running_cwds()
  local set = {}
  for _, proc in ipairs(vim.fn.glob("/proc/[0-9]*", false, true)) do
    local ok, comm = pcall(vim.fn.readfile, proc .. "/comm", "", 1)
    if ok and comm[1] == "claude" then
      local cwd = vim.uv.fs_readlink(proc .. "/cwd")
      if cwd then set[cwd:gsub("/$", "")] = true end
    end
  end
  return set
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

local function claude_state_for(worktree_path, running_set)
  if not running_set[worktree_path:gsub("/$", "")] then return "none" end
  local proj = vim.fn.expand("~/.claude/projects/" .. worktree_path:gsub("[/.]", "-"))
  local newest, newest_mtime = nil, 0
  for _, f in ipairs(vim.fn.glob(proj .. "/*.jsonl", false, true)) do
    local st = vim.uv.fs_stat(f)
    if st and st.mtime.sec > newest_mtime then newest, newest_mtime = f, st.mtime.sec end
  end
  if not newest then return "working" end
  local lines = read_tail_lines(newest)
  for i = #lines, 1, -1 do
    local ok, msg = pcall(vim.json.decode, lines[i])
    if ok and (msg.type == "assistant" or msg.type == "user") then
      if msg.type == "assistant" then
        local sr = msg.message and msg.message.stop_reason
        if sr == "end_turn" or sr == "stop_sequence" or sr == "max_tokens" then return "done" end
        if sr == "tool_use" then return "asking" end
      end
      return "working"
    end
  end
  return "working"
end

local function switch_to_worktree_tab(path)
  local abs_path = vim.fn.fnamemodify(path, ":p"):gsub("/$", "")

  -- Check if a tab already exists for this worktree
  for _, tabnr in ipairs(vim.api.nvim_list_tabpages()) do
    local tab_cwd = vim.fn.getcwd(-1, vim.api.nvim_tabpage_get_number(tabnr)):gsub("/$", "")
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
        local utils = require("telescope.utils")

        -- Build tab info: path -> list of window details
        local tab_windows = {}
        for _, tabnr in ipairs(vim.api.nvim_list_tabpages()) do
          local tabnr_num = vim.api.nvim_tabpage_get_number(tabnr)
          local tab_cwd = vim.fn.getcwd(-1, tabnr_num):gsub("/$", "")
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

        local output = utils.get_os_command_output({ "git", "worktree", "list" })
        local running = claude_running_cwds()
        local results = {}
        for _, line in ipairs(output) do
          local fields = vim.split(string.gsub(line, "%s+", " "), " ")
          if fields[2] ~= "(bare)" then
            local path = fields[1]
            local branch = (fields[3] or ""):gsub("[%[%]]", "")
            local wins = tab_windows[path:gsub("/$", "")]
            local claude = claude_state_for(path, running)
            table.insert(results, { path = path, branch = branch, windows = wins, claude = claude })
          end
        end

        local worktree_previewer = previewers.new_buffer_previewer({
          title = "Tab Windows",
          define_preview = function(self, entry)
            local bufnr = self.state.bufnr
            local lines = {}
            local highlights = {}

            table.insert(lines, "  Branch: " .. entry.ordinal)
            table.insert(highlights, { line = #lines - 1, col = 2, end_col = 9, hl = "TelescopeResultsIdentifier" })
            table.insert(lines, "  Path:   " .. entry.value)
            table.insert(highlights, { line = #lines - 1, col = 2, end_col = 8, hl = "TelescopeResultsIdentifier" })
            table.insert(lines, "  Claude: " .. entry.claude)
            table.insert(highlights, { line = #lines - 1, col = 2, end_col = 9, hl = "TelescopeResultsIdentifier" })
            table.insert(lines, "")

            local wins = entry.windows
            if not wins or #wins == 0 then
              table.insert(lines, "  No open tab")
              table.insert(highlights, { line = #lines - 1, col = 2, end_col = 15, hl = "TelescopeResultsComment" })
            else
              table.insert(lines, "  Open Windows (" .. #wins .. ")")
              table.insert(highlights, { line = #lines - 1, col = 2, end_col = #lines[#lines], hl = "TelescopeResultsIdentifier" })
              table.insert(lines, "")
              for i, win in ipairs(wins) do
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
              vim.api.nvim_buf_add_highlight(bufnr, -1, hl.hl, hl.line, hl.col, hl.end_col)
            end
          end,
        })

        pickers.new({}, {
          prompt_title = "Worktrees",
          previewer = worktree_previewer,
          finder = finders.new_table({
            results = results,
            entry_maker = function(entry)
              return {
                value = entry.path,
                ordinal = entry.branch,
                windows = entry.windows,
                claude = entry.claude,
                display = CLAUDE_ICONS[entry.claude] .. " " .. entry.branch,
              }
            end,
          }),
          sorter = conf.generic_sorter({}),
          attach_mappings = function(prompt_bufnr, map)
            actions.select_default:replace(function()
              local selection = action_state.get_selected_entry()
              actions.close(prompt_bufnr)
              if selection then
                switch_to_worktree_tab(selection.value)
              end
            end)

            local delete_worktree = function()
              local selection = action_state.get_selected_entry()
              if not selection then return end
              local confirmed = vim.fn.input("Delete worktree " .. selection.ordinal .. "? [y/n]: ")
              if confirmed:lower():sub(1, 1) ~= "y" then
                print(" Cancelled")
                return
              end
              actions.close(prompt_bufnr)
              vim.fn.system({ "git", "worktree", "remove", selection.value })
              if vim.v.shell_error ~= 0 then
                local force = vim.fn.input("Remove failed. Force delete? [y/n]: ")
                if force:lower():sub(1, 1) == "y" then
                  vim.fn.system({ "git", "worktree", "remove", "--force", selection.value })
                end
              end
              local delete_branch = vim.fn.input("Also delete branch " .. selection.ordinal .. "? [y/n]: ")
              if delete_branch:lower():sub(1, 1) == "y" then
                vim.fn.system({ "git", "branch", "-D", selection.ordinal })
                print(" Branch deleted")
              end
            end

            map("i", "<m-d>", delete_worktree)
            map("n", "<m-d>", delete_worktree)
            return true
          end,
        }):find()
      end,
      desc = "Switch worktree (tab-per-worktree)",
    },
    { "<leader>gc", function() require("telescope").extensions.git_worktree.create_git_worktree() end, desc = "Create worktree" },
  },
}
