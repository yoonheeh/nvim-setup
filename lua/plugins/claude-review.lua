-- GitHub-style code review interface backed by Claude terminal session.
-- Threads are session-only (not persisted). Transport: claude --resume <id> -p "..."

local function setup()
  local state = {
    session_id = nil,
    threads    = {},
    extmarks   = {},   -- { [bufnr] = { {id, thread_idx}, ... } }
    ns_id      = vim.api.nvim_create_namespace("claude_review"),
    panel_buf  = nil,
    panel_win  = nil,
    active_idx = nil,
  }

  -- ── Session discovery ────────────────────────────────────────────────────
  -- Mirrors git-worktree.lua's JSONL-scanning approach.

  local function find_session_id()
    local cwd     = vim.fn.getcwd()
    local encoded = cwd:gsub("[/.]", "-")
    local proj    = vim.fn.expand("~/.claude/projects/" .. encoded)

    local newest, newest_mtime = nil, 0
    for _, f in ipairs(vim.fn.glob(proj .. "/*.jsonl", false, true)) do
      local st = vim.uv.fs_stat(f)
      if st and st.mtime.sec > newest_mtime then
        newest, newest_mtime = f, st.mtime.sec
      end
    end
    if not newest then return nil end
    return vim.fn.fnamemodify(newest, ":t:r")  -- UUID, no extension
  end

  -- ── Panel ────────────────────────────────────────────────────────────────

  local M = {}

  local function ensure_panel()
    if state.panel_buf and vim.api.nvim_buf_is_valid(state.panel_buf)
      and state.panel_win and vim.api.nvim_win_is_valid(state.panel_win) then
      return
    end

    state.panel_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value("buftype",   "nofile", { buf = state.panel_buf })
    vim.api.nvim_set_option_value("bufhidden", "wipe",   { buf = state.panel_buf })

    local total_w = vim.o.columns
    local total_h = vim.o.lines
    local width   = math.floor(total_w * 0.42)
    -- col: leave 1 cell gap so the right border doesn't overflow vim.o.columns
    local col     = total_w - width - 1
    -- height: vim.o.lines includes statusline + cmdline; subtract them plus border
    local height  = total_h - vim.o.cmdheight - 3

    state.panel_win = vim.api.nvim_open_win(state.panel_buf, false, {
      relative = "editor",
      row      = 1,
      col      = col,
      width    = width,
      height   = height,
      border   = "rounded",
      zindex   = 50,
    })
    -- Force Normal colors; NormalFloat may have invisible fg on some themes
    vim.api.nvim_set_option_value("winhighlight", "Normal:Normal,FloatBorder:FloatBorder", { win = state.panel_win })

    vim.api.nvim_set_option_value("wrap",           true,  { win = state.panel_win })
    vim.api.nvim_set_option_value("linebreak",      true,  { win = state.panel_win })
    vim.api.nvim_set_option_value("number",         false, { win = state.panel_win })
    vim.api.nvim_set_option_value("relativenumber", false, { win = state.panel_win })
    vim.api.nvim_set_option_value("signcolumn",     "no",  { win = state.panel_win })

    local buf = state.panel_buf
    vim.keymap.set("n", "q", function() M.close_panel() end,  { buffer = buf, desc = "Close review panel" })
    vim.keymap.set("n", "r", function() M.reply() end,        { buffer = buf, desc = "Reply to thread" })
    vim.keymap.set("n", "n", function() M.navigate(1) end,    { buffer = buf, desc = "Next thread" })
    vim.keymap.set("n", "p", function() M.navigate(-1) end,   { buffer = buf, desc = "Prev thread" })
  end

  local panel_ns = vim.api.nvim_create_namespace("claude_review_panel")

  local function render_panel(thread_idx)
    state.active_idx = thread_idx
    ensure_panel()

    local thread = state.threads[thread_idx]
    if not thread then return end

    local lines  = {}
    local hls    = {}  -- { line_idx (0-based), col_s, col_e, group }

    local function hl(group, col_e)
      table.insert(hls, { #lines - 1, 0, col_e, group })
    end

    local rel    = vim.fn.fnamemodify(thread.file, ":.")
    local header = string.format("  %s : %d\226\128\147%d", rel, thread.start_line, thread.end_line)
    table.insert(lines, header)
    hl("Title", #header)
    table.insert(lines, string.rep("\226\148\128", 60))
    table.insert(lines, "")

    for _, msg in ipairs(thread.messages) do
      if msg.role == "user" then
        table.insert(lines, "You:")
        hl("Statement", 4)
      else
        table.insert(lines, "Claude:")
        hl("Special", 7)
      end
      for _, ln in ipairs(vim.split(msg.content, "\n", { plain = true })) do
        table.insert(lines, "  " .. ln)
      end
      table.insert(lines, "")
    end

    if thread.loading then
      table.insert(lines, "  \226\143\179 thinking\226\128\166")
      hl("Comment", -1)
      table.insert(lines, "")
    end

    local footer = "\226\148\128\226\148\128\226\148\128 [r] reply  [n/p] threads  [q] close \226\148\128\226\148\128\226\148\128"
    table.insert(lines, footer)
    hl("Comment", -1)

    if #state.threads > 1 then
      table.insert(lines, string.format("    Thread %d / %d", thread_idx, #state.threads))
      hl("LineNr", -1)
    end

    vim.api.nvim_buf_set_lines(state.panel_buf, 0, -1, false, lines)
    vim.api.nvim_buf_clear_namespace(state.panel_buf, panel_ns, 0, -1)
    for _, h in ipairs(hls) do
      vim.api.nvim_buf_add_highlight(state.panel_buf, panel_ns, h[4], h[1], h[2], h[3])
    end

    if state.panel_win and vim.api.nvim_win_is_valid(state.panel_win) then
      local shown = vim.api.nvim_win_get_buf(state.panel_win)
      if shown ~= state.panel_buf then
        vim.notify(
          string.format("[claude-review] BUG: panel_win %d shows buf %d, expected buf %d",
            state.panel_win, shown, state.panel_buf),
          vim.log.levels.ERROR
        )
        -- Fix: force the correct buffer into the window
        vim.api.nvim_win_set_buf(state.panel_win, state.panel_buf)
      end
      vim.api.nvim_win_set_cursor(state.panel_win, { #lines, 0 })
    end
  end

  -- ── Extmarks ─────────────────────────────────────────────────────────────

  local function update_extmark(bufnr, thread_idx)
    local thread = state.threads[thread_idx]
    if not thread then return end

    state.extmarks[bufnr] = state.extmarks[bufnr] or {}

    for i, em in ipairs(state.extmarks[bufnr]) do
      if em.thread_idx == thread_idx then
        vim.api.nvim_buf_del_extmark(bufnr, state.ns_id, em.id)
        table.remove(state.extmarks[bufnr], i)
        break
      end
    end

    local n     = #thread.messages
    local label = n == 1
      and "  💭 1 comment"
      or  string.format("  💭 %d comments", n)
    local id = vim.api.nvim_buf_set_extmark(bufnr, state.ns_id, thread.start_line - 1, 0, {
      virt_text     = { { label, "Comment" } },
      virt_text_pos = "eol",
    })
    table.insert(state.extmarks[bufnr], { id = id, thread_idx = thread_idx })
  end

  -- ── Transport ────────────────────────────────────────────────────────────

  local function run_claude(prompt, on_response)
    local sid = state.session_id
    if not sid then
      vim.notify("[claude-review] No Claude session found for this project", vim.log.levels.ERROR)
      on_response(nil)
      return
    end

    local chunks = {}
    vim.fn.jobstart({ "claude", "--resume", sid, "-p", prompt }, {
      stdout_buffered = false,
      on_stdout = function(_, data)
        for _, chunk in ipairs(data) do
          if chunk ~= "" then table.insert(chunks, chunk) end
        end
      end,
      on_exit = function(_, code)
        vim.schedule(function()
          if code ~= 0 then
            vim.notify("[claude-review] claude exited " .. code, vim.log.levels.WARN)
            on_response(nil)
          else
            on_response(table.concat(chunks, "\n"):gsub("^%s+", ""):gsub("%s+$", ""))
          end
        end)
      end,
    })
  end

  -- ── Prompt builders ───────────────────────────────────────────────────────

  local function get_diff(filepath)
    local rel    = vim.fn.fnamemodify(filepath, ":.")
    local result = vim.fn.system({ "git", "diff", "HEAD", "--", rel })
    if vim.v.shell_error ~= 0 or result == "" then
      result = vim.fn.system({ "git", "diff", "--", rel })
    end
    return result
  end

  local function build_first_prompt(thread, question)
    local ft   = vim.api.nvim_get_option_value("filetype", { buf = 0 })
    local rel  = vim.fn.fnamemodify(thread.file, ":.")
    local code = table.concat(thread.code_lines, "\n")
    local diff = get_diff(thread.file)

    local parts = {
      "[claude-review] Automated inline review request from Neovim. Answer the question directly; no meta-commentary needed.",
      "",
      string.format("File: %s, lines %d\226\128\147%d:", rel, thread.start_line, thread.end_line),
      "```" .. (ft ~= "" and ft or ""),
      code,
      "```",
    }

    if diff ~= "" then
      vim.list_extend(parts, { "", "Git diff for this file:", "```diff", diff, "```" })
    end

    vim.list_extend(parts, { "", question })
    return table.concat(parts, "\n")
  end

  local function build_reply_prompt(thread, reply_text)
    local rel = vim.fn.fnamemodify(thread.file, ":.")
    return string.format(
      "[claude-review] Follow-up on %s lines %d\226\128\147%d.\n\n%s",
      rel, thread.start_line, thread.end_line, reply_text
    )
  end

  -- ── Input panel ──────────────────────────────────────────────────────────

  local input_counter = 0

  local function open_input_panel(prompt, on_submit)
    input_counter = input_counter + 1
    local input_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value("buftype",   "nofile", { buf = input_buf })
    vim.api.nvim_set_option_value("bufhidden", "wipe",   { buf = input_buf })
    vim.api.nvim_buf_set_name(input_buf, "claude-review-input-" .. input_counter)

    local total_h = vim.o.lines
    local total_w = vim.o.columns
    local height  = math.floor(total_h * 0.25)
    local width   = math.floor(total_w * 0.56)
    local row     = total_h - height - vim.o.cmdheight - 2
    local col     = math.floor((total_w - width) / 2)

    local input_win = vim.api.nvim_open_win(input_buf, true, {
      relative = "editor",
      row      = row,
      col      = col,
      width    = width,
      height   = height,
      style    = "minimal",
      border   = "rounded",
      zindex   = 55,
    })

    vim.api.nvim_set_option_value("number",         false, { win = input_win })
    vim.api.nvim_set_option_value("relativenumber", false, { win = input_win })
    vim.api.nvim_set_option_value("signcolumn",     "no",  { win = input_win })
    vim.api.nvim_set_option_value("wrap",           true,  { win = input_win })

    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "-- " .. prompt .. "  (Enter: submit  Esc: cancel) --", "" })
    local hdr_ns = vim.api.nvim_create_namespace("cr_input_hdr")
    vim.api.nvim_buf_add_highlight(input_buf, hdr_ns, "Comment", 0, 0, -1)
    vim.api.nvim_win_set_cursor(input_win, { 2, 0 })
    vim.cmd("startinsert")

    local function submit()
      local lines = vim.api.nvim_buf_get_lines(input_buf, 1, -1, false)
      local text  = table.concat(lines, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
      vim.api.nvim_win_close(input_win, true)
      -- schedule so nvim_open_win in ensure_panel runs after the float is fully torn down
      if text ~= "" then vim.schedule(function() on_submit(text) end) end
    end

    vim.keymap.set("n", "<CR>",  submit,                                              { buffer = input_buf, nowait = true })
    vim.keymap.set("i", "<C-s>", function() vim.cmd("stopinsert") vim.schedule(submit) end, { buffer = input_buf, nowait = true })
    vim.keymap.set("n", "<Esc>", function() vim.api.nvim_win_close(input_win, true) end,    { buffer = input_buf, nowait = true })
  end

  -- ── Public actions ────────────────────────────────────────────────────────

  function M.start_thread()
    local start_line = vim.fn.line("'<")
    local end_line   = vim.fn.line("'>")
    local bufnr      = vim.api.nvim_get_current_buf()
    local filepath   = vim.api.nvim_buf_get_name(bufnr)
    local code_lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)

    open_input_panel("Review comment:", function(question)
      if not question or question == "" then return end

      -- Resolve session lazily at submit time so the panel always opens
      if not state.session_id then
        state.session_id = find_session_id()
      end
      if not state.session_id then
        vim.notify(
          "[claude-review] No Claude session found for: " .. vim.fn.getcwd()
            .. "\n  Check :ClaudeReviewDebug for details.",
          vim.log.levels.ERROR
        )
        return
      end

      local thread = {
        file       = filepath,
        start_line = start_line,
        end_line   = end_line,
        code_lines = code_lines,
        messages   = { { role = "user", content = question } },
        loading    = true,
      }
      table.insert(state.threads, thread)
      local idx = #state.threads

      update_extmark(bufnr, idx)
      render_panel(idx)

      run_claude(build_first_prompt(thread, question), function(response)
        thread.loading = false
        if response then
          table.insert(thread.messages, { role = "assistant", content = response })
          update_extmark(bufnr, idx)
        else
          table.insert(thread.messages, { role = "assistant", content = "[Error: no response received]" })
        end
        render_panel(idx)
      end)
    end)
  end

  function M.reply()
    local idx = state.active_idx
    if not idx then
      vim.notify("[claude-review] No active thread", vim.log.levels.WARN)
      return
    end
    local thread = state.threads[idx]
    if not thread then return end

    open_input_panel("Reply:", function(reply_text)
      if not reply_text or reply_text == "" then return end

      table.insert(thread.messages, { role = "user", content = reply_text })
      thread.loading = true
      render_panel(idx)

      run_claude(build_reply_prompt(thread, reply_text), function(response)
        thread.loading = false
        table.insert(thread.messages, {
          role    = "assistant",
          content = response or "[Error: no response received]",
        })
        local bufnr = vim.fn.bufnr(thread.file)
        if bufnr ~= -1 then update_extmark(bufnr, idx) end
        render_panel(idx)
      end)
    end)
  end

  function M.open_at_cursor()
    local cursor_line = vim.fn.line(".")
    local bufnr       = vim.api.nvim_get_current_buf()

    for _, em in ipairs(state.extmarks[bufnr] or {}) do
      local t = state.threads[em.thread_idx]
      if t and cursor_line >= t.start_line and cursor_line <= t.end_line then
        ensure_panel()
        render_panel(em.thread_idx)
        if state.panel_win and vim.api.nvim_win_is_valid(state.panel_win) then
          vim.api.nvim_set_current_win(state.panel_win)
        end
        return
      end
    end

    if #state.threads > 0 then
      ensure_panel()
      render_panel(#state.threads)
      if state.panel_win and vim.api.nvim_win_is_valid(state.panel_win) then
        vim.api.nvim_set_current_win(state.panel_win)
      end
    else
      vim.notify("[claude-review] No review threads yet. Select lines and press <leader>rc.", vim.log.levels.INFO)
    end
  end

  function M.navigate(dir)
    if #state.threads == 0 then return end
    local current  = state.active_idx or 1
    local next_idx = ((current - 1 + dir) % #state.threads) + 1
    render_panel(next_idx)

    local thread = state.threads[next_idx]
    local bufnr  = vim.fn.bufnr(thread.file)
    if bufnr ~= -1 then
      for _, winid in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(winid) == bufnr and winid ~= state.panel_win then
          vim.api.nvim_win_set_cursor(winid, { thread.start_line, 0 })
          break
        end
      end
    end
  end

  function M.close_panel()
    if state.panel_win and vim.api.nvim_win_is_valid(state.panel_win) then
      vim.api.nvim_win_close(state.panel_win, true)
    end
    state.panel_win = nil
    state.panel_buf = nil
  end

  function M.clear_threads()
    local bufnr    = vim.api.nvim_get_current_buf()
    local filepath = vim.api.nvim_buf_get_name(bufnr)

    for _, em in ipairs(state.extmarks[bufnr] or {}) do
      vim.api.nvim_buf_del_extmark(bufnr, state.ns_id, em.id)
    end
    state.extmarks[bufnr] = {}

    local remaining = {}
    for _, t in ipairs(state.threads) do
      if t.file ~= filepath then table.insert(remaining, t) end
    end
    state.threads  = remaining
    state.active_idx = nil

    M.close_panel()
    vim.notify("[claude-review] Threads cleared", vim.log.levels.INFO)
  end

  -- ── Debug ────────────────────────────────────────────────────────────────

  vim.api.nvim_create_user_command("ClaudeReviewDebug", function()
    local cwd     = vim.fn.getcwd()
    local encoded = cwd:gsub("[/.]", "-")
    local proj    = vim.fn.expand("~/.claude/projects/" .. encoded)
    local files   = vim.fn.glob(proj .. "/*.jsonl", false, true)
    local sid     = find_session_id()

    local pbuf  = state.panel_buf
    local pwin  = state.panel_win
    local pbuf_valid = pbuf and vim.api.nvim_buf_is_valid(pbuf)
    local pwin_valid = pwin and vim.api.nvim_win_is_valid(pwin)
    local shown = pwin_valid and vim.api.nvim_win_get_buf(pwin) or -1
    local match = pbuf_valid and pwin_valid and (shown == pbuf)

    local lines = {
      "cwd:        " .. cwd,
      "proj dir:   " .. proj,
      "jsonl:      " .. #files .. " file(s)",
      "session:    " .. (sid or "NOT FOUND"),
      "threads:    " .. #state.threads,
      "panel_buf:  " .. tostring(pbuf) .. (pbuf_valid and " (valid)" or " (INVALID)"),
      "panel_win:  " .. tostring(pwin) .. (pwin_valid and " (valid)" or " (INVALID)"),
      "win shows:  buf " .. shown .. (match and "  ✓ match" or "  ✗ MISMATCH — text goes to wrong buffer"),
    }
    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
  end, {})

  -- ── Keymaps ───────────────────────────────────────────────────────────────

  vim.keymap.set("v", "<leader>rc", function()
    -- Exit visual so '< '> marks are set, then call start_thread
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
    vim.schedule(M.start_thread)
  end, { desc = "Claude review: start thread on selection" })

  vim.keymap.set("n", "<leader>rt", M.open_at_cursor,  { desc = "Claude review: open thread at cursor" })
  vim.keymap.set("n", "<leader>rn", function() M.navigate(1)  end, { desc = "Claude review: next thread" })
  vim.keymap.set("n", "<leader>rp", function() M.navigate(-1) end, { desc = "Claude review: prev thread" })
  vim.keymap.set("n", "<leader>rx", M.clear_threads,   { desc = "Claude review: clear threads for buffer" })

  -- Clean up extmarks when a buffer is deleted
  vim.api.nvim_create_autocmd("BufDelete", {
    group    = vim.api.nvim_create_augroup("ClaudeReview", { clear = true }),
    callback = function(ev)
      local bufnr = ev.buf
      for _, em in ipairs(state.extmarks[bufnr] or {}) do
        pcall(vim.api.nvim_buf_del_extmark, bufnr, state.ns_id, em.id)
      end
      state.extmarks[bufnr] = nil
    end,
  })
end

setup()
return {}
