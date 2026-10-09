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

-- winhighlight for the panel and the comment box: the editor's own background
-- everywhere, including the border. Many themes (moonfly included) give
-- FloatBorder/FloatTitle/FloatFooter a grey background, which draws a band
-- around the window; keep only FloatBorder's colour for the border lines.
local function float_winhighlight()
  local border = vim.api.nvim_get_hl(0, { name = "FloatBorder", link = false })
  vim.api.nvim_set_hl(0, "ClaudeReviewBorder", { fg = border.fg })
  return "Normal:Normal,FloatBorder:ClaudeReviewBorder,FloatTitle:Title,FloatFooter:Comment"
end

local function panel_is_float(wt)
  return vim.api.nvim_win_get_config(wt.panel_win).relative ~= ""
end

local function ensure_panel(wt)
  if wt.panel_buf and vim.api.nvim_buf_is_valid(wt.panel_buf)
    and wt.panel_win and vim.api.nvim_win_is_valid(wt.panel_win) then
    -- Windows belong to the tab they were opened in; a panel left in another
    -- tab with the same cwd stays valid but is invisible here.
    if vim.api.nvim_win_get_tabpage(wt.panel_win) == vim.api.nvim_get_current_tabpage() then
      return
    end
    pcall(vim.api.nvim_win_close, wt.panel_win, true)
  end

  wt.panel_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype",   "nofile", { buf = wt.panel_buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe",   { buf = wt.panel_buf })
  vim.b[wt.panel_buf].claude_review = true
  -- Thread text is written as markdown; render-markdown.nvim draws it. Its
  -- per-buffer settings are fixed the first time it sees the buffer, so pass
  -- them before setting the filetype:
  --   debounce = 0     its update limiter otherwise drops redraws that come
  --                    within 100 ms of another (opening the panel, writing
  --                    the question, a fast answer), leaving raw markdown
  --   anti_conceal off the panel is read-only, so don't show raw markdown on
  --                    the cursor line
  local ok, rm = pcall(require, "render-markdown")
  if ok and type(rm.render) == "function" then
    rm.render({ buf = wt.panel_buf, config = { debounce = 0, anti_conceal = { enabled = false } } })
  end
  vim.api.nvim_set_option_value("filetype",  "markdown", { buf = wt.panel_buf })

  local total_w = vim.o.columns
  local total_h = vim.o.lines
  local width   = math.floor(total_w * 0.42)

  -- Normally the panel is a real split on the far right, so your own splits
  -- share the remaining width instead of being covered. When the file is open
  -- inside a floating window (the full-screen Claude Code window), a split
  -- would sit underneath that float, so use a float on top instead.
  local cur = vim.api.nvim_get_current_win()
  local from_float = vim.api.nvim_win_get_config(cur).relative ~= ""
    and not vim.b[vim.api.nvim_win_get_buf(cur)].claude_review

  if from_float then
    -- col: leave 1 cell gap so the right border doesn't overflow vim.o.columns
    local col    = total_w - width - 1
    -- height: vim.o.lines includes statusline + cmdline; subtract them plus border
    local height = total_h - vim.o.cmdheight - 3
    wt.panel_win = vim.api.nvim_open_win(wt.panel_buf, false, {
      relative = "editor",
      row      = 1,
      col      = col,
      width    = width,
      height   = height,
      border   = "rounded",
      -- Above default floats (50), e.g. the Claude Code window, which may be
      -- showing the file under review. Popups like Telescope also use 50; see
      -- the WinEnter autocmd in setup, which hides the panel while one is focused.
      zindex   = 51,
    })
  else
    -- win = -1: split the whole tab, not the current window, so the panel is
    -- always the rightmost column.
    wt.panel_win = vim.api.nvim_open_win(wt.panel_buf, false, { split = "right", win = -1, width = width })
    vim.api.nvim_set_option_value("winfixwidth", true, { win = wt.panel_win })
  end
  -- Force Normal colors; NormalFloat may have invisible fg on some themes
  vim.api.nvim_set_option_value("winhighlight", float_winhighlight(), { win = wt.panel_win })

  vim.api.nvim_set_option_value("wrap",           true,  { win = wt.panel_win })
  vim.api.nvim_set_option_value("linebreak",      true,  { win = wt.panel_win })
  vim.api.nvim_set_option_value("number",         false, { win = wt.panel_win })
  vim.api.nvim_set_option_value("relativenumber", false, { win = wt.panel_win })
  vim.api.nvim_set_option_value("signcolumn",     "no",  { win = wt.panel_win })
  vim.api.nvim_set_option_value("fillchars",      "eob: ", { win = wt.panel_win })

  -- Bind the panel's keys to the worktree that opened it, so they keep working
  -- on that worktree even if this tab's cwd changes later.
  local buf = wt.panel_buf
  vim.keymap.set("n", "q", function() M.close_panel(wt) end,  { buffer = buf, desc = "Close review panel" })
  vim.keymap.set("n", "r", function() M.reply(wt) end,        { buffer = buf, desc = "Reply to thread" })
  vim.keymap.set("n", "n", function() M.navigate(1, wt) end,  { buffer = buf, desc = "Next thread" })
  vim.keymap.set("n", "p", function() M.navigate(-1, wt) end, { buffer = buf, desc = "Prev thread" })
end

-- Ask render-markdown.nvim to redraw `buf`. It only redraws on editor events
-- (cursor moves, typing), and the panel is written from code while the cursor
-- is elsewhere, so nothing would trigger it. (The panel buffer has its update
-- limiter turned off, see ensure_panel, so this request is never dropped.)
local function redraw_markdown(buf)
  local ok, rm = pcall(require, "render-markdown")
  if ok and type(rm.render) == "function" then
    rm.render({ buf = buf })
  end
end

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

  -- The panel buffer is markdown: the reviewed lines as a code block, then
  -- one heading per message with the message text as-is.
  local lines = {}
  local function add(text)
    vim.list_extend(lines, vim.split(text, "\n", { plain = true }))
  end

  add("```" .. (thread.filetype or ""))
  add(table.concat(thread.code_lines, "\n"))
  add("```")

  for _, msg in ipairs(thread.messages) do
    add("")
    -- Different heading levels so render-markdown gives each speaker its own colour and icon.
    add(msg.role == "user" and "### You" or "## Claude")
    add("")
    add(msg.content)
  end

  if thread.loading then
    add("")
    add("*\226\143\179 Claude is thinking\226\128\166*")
  end

  vim.api.nvim_buf_set_lines(wt.panel_buf, 0, -1, false, lines)
  redraw_markdown(wt.panel_buf)

  -- File, line range, keys and thread position go in the border (floating
  -- panel) or the window's top bar (split panel), not in the text.
  if wt.panel_win and vim.api.nvim_win_is_valid(wt.panel_win) then
    local title = string.format(" %s : %d\226\128\147%d ", thread.rel, thread.start_line, thread.end_line)
    local keys  = " r reply \194\183 n/p threads \194\183 q close "
    if #wt.threads > 1 then
      keys = keys .. string.format("\194\183 %d/%d ", index_of(wt, thread) or 0, #wt.threads)
    end
    if panel_is_float(wt) then
      vim.api.nvim_win_set_config(wt.panel_win, {
        title      = title,
        title_pos  = "center",
        footer     = keys,
        footer_pos = "center",
      })
    else
      vim.api.nvim_set_option_value("winbar",
        "%#Title#" .. title:gsub("%%", "%%%%") .. "%*%=%#Comment#" .. keys .. "%*",
        { win = wt.panel_win })
    end
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

  local output = {}
  -- Claude sessions are stored per project directory, so --resume must run in wt's cwd.
  vim.fn.jobstart({ "claude", "--resume", sid, "-p", prompt }, {
    cwd = wt.cwd,
    -- Buffered: `data` arrives once, as the full output split on newlines.
    -- Blank lines are kept; they separate markdown paragraphs.
    stdout_buffered = true,
    on_stdout = function(_, data)
      output = data
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        if code ~= 0 then
          vim.notify("[claude-review] claude exited " .. code, vim.log.levels.WARN)
          on_response(nil)
        else
          on_response(table.concat(output, "\n"):gsub("^%s+", ""):gsub("%s+$", ""))
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
-- A comment box that opens directly under the lines being discussed, like
-- GitHub's inline comments. The lines stay highlighted while you type.

local input_counter = 0
local input_ns      = vim.api.nvim_create_namespace("claude_review_input")

local INPUT_MIN_H = 2
local INPUT_MAX_H = 12

-- A window in this tab showing `bufnr`, other than the review panel.
-- Prefers the current window, then normal windows, then floating ones (the
-- file may be open inside the full-screen Claude Code float).
local function code_win_for(bufnr, panel_win)
  local cur = vim.api.nvim_get_current_win()
  if cur ~= panel_win and vim.api.nvim_win_get_buf(cur) == bufnr then return cur end
  local float
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if win ~= panel_win and vim.api.nvim_win_get_buf(win) == bufnr then
      if vim.api.nvim_win_get_config(win).relative == "" then return win end
      float = float or win
    end
  end
  return float
end

-- opts:
--   title        border title, e.g. " 💬 algo.lua : 3–7 "
--   placeholder  grey hint shown while the box is empty
--   bufnr, start_line, end_line   the lines being discussed (1-based)
--   panel_win    the review panel, if open, so the box can stop short of it
--   dock         put the box at the bottom of the review panel (chat-style)
--                instead of under the code; used for replies
--   on_submit    called with the text
local function open_input_panel(opts)
  input_counter = input_counter + 1
  local input_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype",   "nofile", { buf = input_buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe",   { buf = input_buf })
  vim.api.nvim_buf_set_name(input_buf, "claude-review-input-" .. input_counter)
  vim.b[input_buf].claude_review = true

  local footer = " \226\143\142 send \194\183 Alt-\226\143\142 newline \194\183 Esc Esc cancel "
  local panel_valid = opts.panel_win and vim.api.nvim_win_is_valid(opts.panel_win)
    and vim.api.nvim_win_get_tabpage(opts.panel_win) == vim.api.nvim_get_current_tabpage()

  local win_opts
  local code_win = opts.bufnr and code_win_for(opts.bufnr, opts.panel_win)
  local docked     = opts.dock and panel_valid
  -- A split panel gets the box as a real split below it, in the same column;
  -- a floating panel gets a float laid over its bottom (it shrinks to make room).
  local dock_split = docked and vim.api.nvim_win_get_config(opts.panel_win).relative == ""
  local panel_cfg, panel_h0, panel_winbar
  if dock_split then
    -- The panel's key hints (r reply, n/p, q) don't apply while typing; keep
    -- only its title, the part of the winbar before the right-align mark.
    panel_winbar = vim.wo[opts.panel_win].winbar
    vim.wo[opts.panel_win].winbar = panel_winbar:match("^(.-)%%=") or panel_winbar
  elseif docked then
    -- Take the bottom of the panel: the panel shrinks by the box's height
    -- (see `dock` below) and the box sits in the freed space, same width.
    panel_cfg = vim.api.nvim_win_get_config(opts.panel_win)
    panel_h0  = panel_cfg.height
    -- The panel's key hints (r reply, n/p, q) don't apply while typing; hide them.
    vim.api.nvim_win_set_config(opts.panel_win, { footer = "" })
    win_opts  = {
      relative = "editor",
      row      = panel_cfg.row + panel_h0 - INPUT_MIN_H,
      col      = panel_cfg.col,
      width    = panel_cfg.width,
    }
  elseif code_win then
    -- Keep the box inside the code window's text area and left of the panel.
    local info       = vim.fn.getwininfo(code_win)[1]
    local text_left  = info.wincol - 1 + info.textoff          -- 0-based screen column
    local right      = info.wincol - 1 + info.width
    if panel_valid then
      right = math.min(right, vim.api.nvim_win_get_position(opts.panel_win)[2] - 1)
    end
    local width = math.max(math.min(right - text_left - 2, 100), 30)

    -- Scroll so there is room for the box under the last line.
    local room_needed = INPUT_MIN_H + 2
    vim.api.nvim_win_call(code_win, function()
      local last_row = vim.fn.screenpos(code_win, opts.end_line, 1).row
      local win_bottom = info.winrow - 1 + info.height
      if last_row == 0 or last_row + room_needed > win_bottom then
        vim.fn.winrestview({ topline = math.max(1, opts.end_line - info.height + room_needed + 1) })
      end
    end)

    win_opts = {
      relative = "win",
      win      = code_win,
      bufpos   = { opts.end_line - 1, 0 },
      row      = 1,
      col      = 0,
      width    = width,
    }
  else
    -- The file isn't open in this tab: centre the box near the bottom.
    local width = math.floor(vim.o.columns * 0.56)
    win_opts = {
      relative = "editor",
      row      = vim.o.lines - INPUT_MIN_H - vim.o.cmdheight - 4,
      col      = math.floor((vim.o.columns - width) / 2),
      width    = width,
    }
  end

  -- Highlight the discussed lines while the box is open, if they're on screen.
  if code_win then
    for l = opts.start_line, opts.end_line do
      vim.api.nvim_buf_set_extmark(opts.bufnr, input_ns, l - 1, 0, { line_hl_group = "Visual" })
    end
  end

  local input_win
  if dock_split then
    input_win = vim.api.nvim_open_win(input_buf, true, { split = "below", win = opts.panel_win, height = INPUT_MIN_H })
    -- No border on a split: title and keys go in its top bar instead.
    vim.api.nvim_set_option_value("winbar",
      "%#Title#" .. opts.title .. "%*%=%#Comment#" .. footer .. "%*", { win = input_win })
    for name, value in pairs({ number = false, relativenumber = false, signcolumn = "no",
                               fillchars = "eob: ", winfixheight = true }) do
      vim.api.nvim_set_option_value(name, value, { win = input_win })
    end
  else
    win_opts = vim.tbl_extend("force", win_opts, {
      height     = INPUT_MIN_H,
      style      = "minimal",
      border     = "rounded",
      title      = opts.title,
      title_pos  = "left",
      footer     = footer,
      footer_pos = "right",
      zindex     = 55,
    })
    input_win = vim.api.nvim_open_win(input_buf, true, win_opts)
    vim.api.nvim_set_option_value("winhighlight", float_winhighlight(), { win = input_win })
  end
  vim.api.nvim_set_option_value("wrap",      true, { win = input_win })
  vim.api.nvim_set_option_value("linebreak", true, { win = input_win })
  vim.cmd("startinsert")

  -- Blank virtual lines under the discussed lines, as tall as the box, so the
  -- box pushes the code below it down instead of covering it.
  local spacer_id
  local function make_room(h)
    if docked or not (code_win and vim.api.nvim_buf_is_valid(opts.bufnr)) then return end
    local blank = {}
    for _ = 1, h + 2 do table.insert(blank, { { "", "Normal" } }) end  -- +2 for the border
    spacer_id = vim.api.nvim_buf_set_extmark(opts.bufnr, input_ns, opts.end_line - 1, 0, {
      id         = spacer_id,
      virt_lines = blank,
    })
  end

  -- Docked: shrink the panel so panel + box fill the panel's original space,
  -- and keep the panel scrolled to its last line (the latest message).
  local function dock(h)
    if not (docked and vim.api.nvim_win_is_valid(opts.panel_win)) then return end
    local last = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(opts.panel_win))
    if dock_split then
      -- The column already shares its height between panel and box.
      vim.api.nvim_win_set_cursor(opts.panel_win, { last, 0 })
      return
    end
    local panel_h = math.max(panel_h0 - (h + 2), 3)  -- +2 for the box's border
    vim.api.nvim_win_set_height(opts.panel_win, panel_h)
    vim.api.nvim_win_set_config(input_win, {
      relative = "editor",
      row      = panel_cfg.row + panel_h + 2,  -- below the panel's bottom border
      col      = panel_cfg.col,
    })
    vim.api.nvim_win_set_cursor(opts.panel_win, { last, 0 })
  end

  -- Placeholder while empty, and grow the box with its text.
  local hint_ns = vim.api.nvim_create_namespace("claude_review_input_hint")
  local function refresh()
    if not vim.api.nvim_win_is_valid(input_win) then return end
    vim.api.nvim_buf_clear_namespace(input_buf, hint_ns, 0, -1)
    local lines = vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)
    if #lines == 1 and lines[1] == "" then
      vim.api.nvim_buf_set_extmark(input_buf, hint_ns, 0, 0, {
        virt_text     = { { opts.placeholder, "Comment" } },
        virt_text_pos = "overlay",
      })
    end
    local h = vim.api.nvim_win_text_height(input_win, {}).all
    h = math.max(INPUT_MIN_H, math.min(INPUT_MAX_H, h))
    -- A window's height includes its top bar (winbar), which the split box has.
    local win_h = h + vim.fn.getwininfo(input_win)[1].winbar
    if win_h ~= vim.api.nvim_win_get_height(input_win) then
      vim.api.nvim_win_set_height(input_win, win_h)
    end
    make_room(h)
    dock(h)
  end
  refresh()
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, { buffer = input_buf, callback = refresh })

  -- However the box closes (send, cancel, :q), drop the line highlight.
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern  = tostring(input_win),
    once     = true,
    callback = function()
      if opts.bufnr and vim.api.nvim_buf_is_valid(opts.bufnr) then
        vim.api.nvim_buf_clear_namespace(opts.bufnr, input_ns, 0, -1)
      end
      if dock_split and vim.api.nvim_win_is_valid(opts.panel_win) then
        vim.wo[opts.panel_win].winbar = panel_winbar
      elseif docked and vim.api.nvim_win_is_valid(opts.panel_win) then
        vim.api.nvim_win_set_height(opts.panel_win, panel_h0)
        vim.api.nvim_win_set_config(opts.panel_win, { footer = panel_cfg.footer, footer_pos = panel_cfg.footer_pos })
      end
    end,
  })
  local function close()
    if vim.api.nvim_win_is_valid(input_win) then vim.api.nvim_win_close(input_win, true) end
  end

  local function submit()
    local lines = vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)
    local text  = table.concat(lines, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
    vim.cmd("stopinsert")
    close()
    -- schedule so nvim_open_win in ensure_panel runs after the float is fully torn down
    if text ~= "" then vim.schedule(function() opts.on_submit(text) end) end
  end
  local map = function(mode, lhs, fn) vim.keymap.set(mode, lhs, fn, { buffer = input_buf, nowait = true }) end
  map("i", "<CR>",   submit)
  map("n", "<CR>",   submit)
  map("i", "<C-s>",  submit)
  map("n", "<C-s>",  submit)
  -- Plain (non-recursive) <CR>, i.e. a real newline.
  map("i", "<S-CR>", "<CR>")
  map("i", "<M-CR>", "<CR>")
  map("n", "<Esc>",  close)
  map("n", "q",      close)
end

-- ── Public actions ────────────────────────────────────────────────────────

function M.start_thread()
  local wt         = current_wt()
  local start_line = vim.fn.line("'<")
  local end_line   = vim.fn.line("'>")
  local bufnr      = vim.api.nvim_get_current_buf()
  local filepath   = vim.api.nvim_buf_get_name(bufnr)
  local code_lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)

  local rel = vim.fn.fnamemodify(filepath, ":.")
  open_input_panel({
    title       = string.format(" \240\159\146\172 %s : %d\226\128\147%d ", rel, start_line, end_line),
    placeholder = "Ask Claude about these lines\226\128\166",
    bufnr       = bufnr,
    start_line  = start_line,
    end_line    = end_line,
    panel_win   = wt.panel_win,
    on_submit   = function(question)
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
    end,
  })
end

function M.reply(wt)
  wt           = wt or current_wt()
  local thread = wt.active
  if not thread then
    vim.notify("[claude-review] No active thread", vim.log.levels.WARN)
    return
  end

  local bufnr = vim.fn.bufnr(thread.file)
  open_input_panel({
    title       = " \226\134\169 Reply ",
    placeholder = "Reply to Claude\226\128\166",
    bufnr       = bufnr ~= -1 and bufnr or nil,
    start_line  = thread.start_line,
    end_line    = thread.end_line,
    panel_win   = wt.panel_win,
    dock        = true,
    on_submit   = function(reply_text)
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
        local buf = vim.fn.bufnr(thread.file)
        if buf ~= -1 then update_extmark(buf, thread) end
        render_panel(wt, thread)
      end)
    end,
  })
end

local function focus_panel(wt, thread)
  render_panel(wt, thread)
  if wt.panel_win and vim.api.nvim_win_is_valid(wt.panel_win) then
    if panel_is_float(wt) then vim.api.nvim_win_set_config(wt.panel_win, { hide = false }) end
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

  -- A floating panel (used when the file is inside the Claude Code float)
  -- sits above default floats so that float doesn't cover it. That would also put it above popups like
  -- Telescope, so hide it while focus is in a floating window that isn't
  -- showing a file (Telescope prompt, Claude terminal), and show it again
  -- once focus is back on a file.
  local function update_panel_visibility(force_hide)
    local win  = vim.api.nvim_get_current_win()
    local buf  = vim.api.nvim_win_get_buf(win)
    local hide = force_hide or (vim.api.nvim_win_get_config(win).relative ~= ""
      and vim.bo[buf].buftype ~= ""
      and not vim.b[buf].claude_review)
    local tab = vim.api.nvim_get_current_tabpage()
    for _, wt in pairs(state.worktrees) do
      local pw = wt.panel_win
      if pw and vim.api.nvim_win_is_valid(pw) and vim.api.nvim_win_get_tabpage(pw) == tab
        and panel_is_float(wt) and vim.api.nvim_win_get_config(pw).hide ~= hide then
        vim.api.nvim_win_set_config(pw, { hide = hide })
      end
    end
  end

  local vis_group = vim.api.nvim_create_augroup("ClaudeReviewPanelVisibility", { clear = true })
  vim.api.nvim_create_autocmd("WinEnter", {
    group    = vis_group,
    callback = function() update_panel_visibility(false) end,
  })
  -- Telescope opens and leaves its windows with autocmds off (plenary popup
  -- uses noautocmd), so WinEnter never fires for it. It does announce itself,
  -- and its windows closing still fires WinClosed; re-check after that.
  vim.api.nvim_create_autocmd("User", {
    group    = vis_group,
    pattern  = "TelescopeFindPre",
    callback = function() update_panel_visibility(true) end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group    = vis_group,
    callback = function() vim.schedule(function() update_panel_visibility(false) end) end,
  })

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
