-- GitHub-style code review interface backed by Claude terminal session.
-- Threads are session-only (not persisted). Transport: claude --resume <id> -p "..."
--
-- Each worktree tab (tab-local cwd via :tcd) gets its own Claude session,
-- threads, and panel, keyed by that cwd.

local M = {}

local state = {
  worktrees = {},   -- { [cwd] = { cwd, session_id, threads, active, panel_buf, panel_win } }
  extmarks  = {},   -- { [bufnr] = { {id, thread}, ... } }
  ns_id     = vim.api.nvim_create_namespace("claude_review"),
}

-- State for the worktree of the current tab.
local function current_wt()
  local cwd = vim.fn.getcwd()
  local wt  = state.worktrees[cwd]
  if not wt then
    wt = { cwd = cwd, session_id = nil, threads = {}, active = nil, panel_buf = nil, panel_win = nil }
    state.worktrees[cwd] = wt
  end
  return wt
end

local function index_of(wt, thread)
  for i, t in ipairs(wt.threads) do
    if t == thread then return i end
  end
end

-- ── Session discovery ────────────────────────────────────────────────────
-- Mirrors git-worktree.lua's JSONL-scanning approach.

local function find_session_id(cwd)
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

local function ensure_panel(wt)
  if wt.panel_buf and vim.api.nvim_buf_is_valid(wt.panel_buf)
    and wt.panel_win and vim.api.nvim_win_is_valid(wt.panel_win) then
    -- Floats belong to the tab they were opened in; a panel left in another
    -- tab with the same cwd stays valid but is invisible here.
    if vim.api.nvim_win_get_tabpage(wt.panel_win) == vim.api.nvim_get_current_tabpage() then
      return
    end
    vim.api.nvim_win_close(wt.panel_win, true)
  end

  wt.panel_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype",   "nofile", { buf = wt.panel_buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe",   { buf = wt.panel_buf })

  local total_w = vim.o.columns
  local total_h = vim.o.lines
  local width   = math.floor(total_w * 0.42)
  -- col: leave 1 cell gap so the right border doesn't overflow vim.o.columns
  local col     = total_w - width - 1
  -- height: vim.o.lines includes statusline + cmdline; subtract them plus border
  local height  = total_h - vim.o.cmdheight - 3

  wt.panel_win = vim.api.nvim_open_win(wt.panel_buf, false, {
    relative = "editor",
    row      = 1,
    col      = col,
    width    = width,
    height   = height,
    border   = "rounded",
    zindex   = 50,
  })
  -- Force Normal colors; NormalFloat may have invisible fg on some themes
  vim.api.nvim_set_option_value("winhighlight", "Normal:Normal,FloatBorder:FloatBorder", { win = wt.panel_win })

  vim.api.nvim_set_option_value("wrap",           true,  { win = wt.panel_win })
  vim.api.nvim_set_option_value("linebreak",      true,  { win = wt.panel_win })
  vim.api.nvim_set_option_value("number",         false, { win = wt.panel_win })
  vim.api.nvim_set_option_value("relativenumber", false, { win = wt.panel_win })
  vim.api.nvim_set_option_value("signcolumn",     "no",  { win = wt.panel_win })

  -- Bind the panel's keys to the worktree that opened it, so they keep working
  -- on that worktree even if this tab's cwd changes later.
  local buf = wt.panel_buf
  vim.keymap.set("n", "q", function() M.close_panel(wt) end,  { buffer = buf, desc = "Close review panel" })
  vim.keymap.set("n", "r", function() M.reply(wt) end,        { buffer = buf, desc = "Reply to thread" })
  vim.keymap.set("n", "n", function() M.navigate(1, wt) end,  { buffer = buf, desc = "Next thread" })
  vim.keymap.set("n", "p", function() M.navigate(-1, wt) end, { buffer = buf, desc = "Prev thread" })
end

local panel_ns = vim.api.nvim_create_namespace("claude_review_panel")

-- Show `thread` in wt's panel. The panel is (re)opened only when wt is the
-- current tab's worktree; a reply that arrives while another worktree's tab
-- is focused just updates wt's panel buffer, if it still exists.
local function render_panel(wt, thread)
  if not thread then return end
  wt.active = thread

  if wt == current_wt() then
    ensure_panel(wt)
  elseif not (wt.panel_buf and vim.api.nvim_buf_is_valid(wt.panel_buf)) then
    return
  end

  local lines  = {}
  local hls    = {}  -- { line_idx (0-based), col_s, col_e, group }

  local function hl(group, col_e)
    table.insert(hls, { #lines - 1, 0, col_e, group })
  end

  local header = string.format("  %s : %d\226\128\147%d", thread.rel, thread.start_line, thread.end_line)
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

  if #wt.threads > 1 then
    table.insert(lines, string.format("    Thread %d / %d", index_of(wt, thread) or 0, #wt.threads))
    hl("LineNr", -1)
  end

  vim.api.nvim_buf_set_lines(wt.panel_buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(wt.panel_buf, panel_ns, 0, -1)
  for _, h in ipairs(hls) do
    vim.api.nvim_buf_add_highlight(wt.panel_buf, panel_ns, h[4], h[1], h[2], h[3])
  end

  if wt.panel_win and vim.api.nvim_win_is_valid(wt.panel_win) then
    local shown = vim.api.nvim_win_get_buf(wt.panel_win)
    if shown ~= wt.panel_buf then
      vim.notify(
        string.format("[claude-review] BUG: panel_win %d shows buf %d, expected buf %d",
          wt.panel_win, shown, wt.panel_buf),
        vim.log.levels.ERROR
      )
      -- Fix: force the correct buffer into the window
      vim.api.nvim_win_set_buf(wt.panel_win, wt.panel_buf)
    end
    vim.api.nvim_win_set_cursor(wt.panel_win, { #lines, 0 })
  end
end

-- ── Extmarks ─────────────────────────────────────────────────────────────

local function update_extmark(bufnr, thread)
  state.extmarks[bufnr] = state.extmarks[bufnr] or {}

  for i, em in ipairs(state.extmarks[bufnr]) do
    if em.thread == thread then
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
  table.insert(state.extmarks[bufnr], { id = id, thread = thread })
end

-- ── Transport ────────────────────────────────────────────────────────────

local function run_claude(wt, prompt, on_response)
  local sid = wt.session_id
  if not sid then
    vim.notify("[claude-review] No Claude session found for this project", vim.log.levels.ERROR)
    on_response(nil)
    return
  end

  local chunks = {}
  -- Claude sessions are stored per project directory, so --resume must run in wt's cwd.
  vim.fn.jobstart({ "claude", "--resume", sid, "-p", prompt }, {
    cwd = wt.cwd,
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

local function get_diff(cwd, filepath)
  local result = vim.fn.system({ "git", "-C", cwd, "diff", "HEAD", "--", filepath })
  if vim.v.shell_error ~= 0 or result == "" then
    result = vim.fn.system({ "git", "-C", cwd, "diff", "--", filepath })
  end
  return result
end

local function build_first_prompt(wt, thread, question)
  local ft   = thread.filetype
  local code = table.concat(thread.code_lines, "\n")
  local diff = get_diff(wt.cwd, thread.file)

  local parts = {
    "[claude-review] Automated inline review request from Neovim. Answer the question directly; no meta-commentary needed.",
    "",
    string.format("File: %s, lines %d\226\128\147%d:", thread.rel, thread.start_line, thread.end_line),
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
  return string.format(
    "[claude-review] Follow-up on %s lines %d\226\128\147%d.\n\n%s",
    thread.rel, thread.start_line, thread.end_line, reply_text
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
  local wt         = current_wt()
  local start_line = vim.fn.line("'<")
  local end_line   = vim.fn.line("'>")
  local bufnr      = vim.api.nvim_get_current_buf()
  local filepath   = vim.api.nvim_buf_get_name(bufnr)
  local code_lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)

  open_input_panel("Review comment:", function(question)
    if not question or question == "" then return end

    -- Resolve session lazily at submit time so the panel always opens
    if not wt.session_id then
      wt.session_id = find_session_id(wt.cwd)
    end
    if not wt.session_id then
      vim.notify(
        "[claude-review] No Claude session found for: " .. wt.cwd
          .. "\n  Check :ClaudeReviewDebug for details.",
        vim.log.levels.ERROR
      )
      return
    end

    local thread = {
      file       = filepath,
      rel        = vim.fn.fnamemodify(filepath, ":."),
      filetype   = vim.api.nvim_get_option_value("filetype", { buf = bufnr }),
      start_line = start_line,
      end_line   = end_line,
      code_lines = code_lines,
      messages   = { { role = "user", content = question } },
      loading    = true,
    }
    table.insert(wt.threads, thread)

    update_extmark(bufnr, thread)
    render_panel(wt, thread)

    run_claude(wt, build_first_prompt(wt, thread, question), function(response)
      thread.loading = false
      if response then
        table.insert(thread.messages, { role = "assistant", content = response })
      else
        table.insert(thread.messages, { role = "assistant", content = "[Error: no response received]" })
      end
      if vim.api.nvim_buf_is_valid(bufnr) then update_extmark(bufnr, thread) end
      render_panel(wt, thread)
    end)
  end)
end

function M.reply(wt)
  wt           = wt or current_wt()
  local thread = wt.active
  if not thread then
    vim.notify("[claude-review] No active thread", vim.log.levels.WARN)
    return
  end

  open_input_panel("Reply:", function(reply_text)
    if not reply_text or reply_text == "" then return end

    table.insert(thread.messages, { role = "user", content = reply_text })
    thread.loading = true
    render_panel(wt, thread)

    run_claude(wt, build_reply_prompt(thread, reply_text), function(response)
      thread.loading = false
      table.insert(thread.messages, {
        role    = "assistant",
        content = response or "[Error: no response received]",
      })
      local bufnr = vim.fn.bufnr(thread.file)
      if bufnr ~= -1 then update_extmark(bufnr, thread) end
      render_panel(wt, thread)
    end)
  end)
end

local function focus_panel(wt, thread)
  render_panel(wt, thread)
  if wt.panel_win and vim.api.nvim_win_is_valid(wt.panel_win) then
    vim.api.nvim_set_current_win(wt.panel_win)
  end
end

function M.open_at_cursor()
  local wt          = current_wt()
  local cursor_line = vim.fn.line(".")
  local bufnr       = vim.api.nvim_get_current_buf()

  for _, em in ipairs(state.extmarks[bufnr] or {}) do
    local t = em.thread
    if index_of(wt, t) and cursor_line >= t.start_line and cursor_line <= t.end_line then
      focus_panel(wt, t)
      return
    end
  end

  if #wt.threads > 0 then
    focus_panel(wt, wt.threads[#wt.threads])
  else
    vim.notify("[claude-review] No review threads yet. Select lines and press <leader>rc.", vim.log.levels.INFO)
  end
end

function M.navigate(dir, wt)
  wt = wt or current_wt()
  if #wt.threads == 0 then return end
  local current  = (wt.active and index_of(wt, wt.active)) or 1
  local next_idx = ((current - 1 + dir) % #wt.threads) + 1
  local thread   = wt.threads[next_idx]
  render_panel(wt, thread)

  local bufnr = vim.fn.bufnr(thread.file)
  if bufnr ~= -1 then
    -- Only windows in this tab; the same file may be open in another worktree's tab.
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_buf(winid) == bufnr and winid ~= wt.panel_win then
        vim.api.nvim_win_set_cursor(winid, { thread.start_line, 0 })
        break
      end
    end
  end
end

function M.close_panel(wt)
  wt = wt or current_wt()
  if wt.panel_win and vim.api.nvim_win_is_valid(wt.panel_win) then
    vim.api.nvim_win_close(wt.panel_win, true)
  end
  wt.panel_win = nil
  wt.panel_buf = nil
end

function M.clear_threads()
  local wt       = current_wt()
  local bufnr    = vim.api.nvim_get_current_buf()
  local filepath = vim.api.nvim_buf_get_name(bufnr)

  -- Only this worktree's markers; the same buffer may also carry threads
  -- started from another worktree's tab.
  local kept = {}
  for _, em in ipairs(state.extmarks[bufnr] or {}) do
    if index_of(wt, em.thread) then
      vim.api.nvim_buf_del_extmark(bufnr, state.ns_id, em.id)
    else
      table.insert(kept, em)
    end
  end
  state.extmarks[bufnr] = kept

  local remaining = {}
  for _, t in ipairs(wt.threads) do
    if t.file ~= filepath then table.insert(remaining, t) end
  end
  wt.threads = remaining
  wt.active  = nil

  M.close_panel(wt)
  vim.notify("[claude-review] Threads cleared", vim.log.levels.INFO)
end

-- ── Setup ──────────────────────────────────────────────────────────────────

local did_setup = false

function M.setup(_)
  if did_setup then return end
  did_setup = true

  -- Debug command
  vim.api.nvim_create_user_command("ClaudeReviewDebug", function()
    local wt      = current_wt()
    local encoded = wt.cwd:gsub("[/.]", "-")
    local proj    = vim.fn.expand("~/.claude/projects/" .. encoded)
    local files   = vim.fn.glob(proj .. "/*.jsonl", false, true)
    local sid     = find_session_id(wt.cwd)

    local pbuf  = wt.panel_buf
    local pwin  = wt.panel_win
    local pbuf_valid = pbuf and vim.api.nvim_buf_is_valid(pbuf)
    local pwin_valid = pwin and vim.api.nvim_win_is_valid(pwin)
    local shown = pwin_valid and vim.api.nvim_win_get_buf(pwin) or -1
    local match = pbuf_valid and pwin_valid and (shown == pbuf)

    local lines = {
      "cwd:        " .. wt.cwd,
      "proj dir:   " .. proj,
      "jsonl:      " .. #files .. " file(s)",
      "session:    " .. (sid or "NOT FOUND") .. "  (in use: " .. (wt.session_id or "none yet") .. ")",
      "threads:    " .. #wt.threads,
      "panel_buf:  " .. tostring(pbuf) .. (pbuf_valid and " (valid)" or " (INVALID)"),
      "panel_win:  " .. tostring(pwin) .. (pwin_valid and " (valid)" or " (INVALID)"),
      "win shows:  buf " .. shown .. (match and "  ✓ match" or "  ✗ MISMATCH — text goes to wrong buffer"),
    }
    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
  end, {})

  -- Keymaps
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

return M
