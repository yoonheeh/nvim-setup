-- Regression tests for the :OpenCode fullscreen float (lua/yoonhee/opencode.lua,
-- plenary busted style). Run with tests/run.sh. No tmux, no opencode binary,
-- no network: termopen is stubbed to run cheap real commands (`sleep 60` for
-- a live terminal, `true` for an instantly-exiting one) with the same opts,
-- so buftype and on_exit behave exactly like production.
local OC = require("yoonhee.opencode")
local T = OC._test

describe("opencode float lifecycle", function()
  local orig_termopen, orig_executable, orig_notify
  local jobs, notes, termopen_calls

  before_each(function()
    orig_termopen = vim.fn.termopen
    orig_executable = vim.fn.executable
    orig_notify = vim.notify
    jobs = {}
    notes = {}
    termopen_calls = 0
    vim.notify = function(msg, level, ...)
      table.insert(notes, { msg = msg, level = level })
    end
  end)

  after_each(function()
    vim.fn.termopen = orig_termopen
    vim.fn.executable = orig_executable
    vim.notify = orig_notify
    if OC.is_open() then OC.close() end
    for _, j in ipairs(jobs) do pcall(vim.fn.jobstop, j) end
    jobs = {}
    vim.wait(200) -- pump scheduled on_exit handlers so state settles
    local b = T.get_buf()
    if b and vim.api.nvim_buf_is_valid(b) then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end)

  -- Stub termopen with a long-lived real terminal; the passed opts (cwd,
  -- on_exit) are honoured, only the command is swapped out.
  local function stub_live_sleep()
    vim.fn.termopen = function(_, opts)
      termopen_calls = termopen_calls + 1
      local id = orig_termopen("sleep 60", opts)
      table.insert(jobs, id)
      return id
    end
  end

  it("opens a float whose buffer persists hidden (bufhidden=hide)", function()
    stub_live_sleep()
    OC.open("")
    assert.truthy(OC.is_open())
    local b = T.get_buf()
    assert.truthy(b and vim.api.nvim_buf_is_valid(b))
    assert.are.equal("hide", vim.api.nvim_get_option_value("bufhidden", { buf = b }))
    assert.are.equal("terminal", vim.api.nvim_get_option_value("buftype", { buf = b }))
  end)

  it("opening a file from the float keeps the terminal hidden", function()
    -- Mirrors telescope's file_edit (set_current_win(original_win_id) +
    -- :edit): from inside the float that is just :edit, so the file lands
    -- in the float window and the terminal is hidden, not wiped.
    stub_live_sleep()
    OC.open("")
    local termbuf = vim.api.nvim_get_current_buf()
    local win = T.get_win()

    local f = vim.fn.tempname()
    vim.fn.writefile({ "probe" }, f)
    vim.cmd("edit " .. vim.fn.fnameescape(f))

    assert.truthy(OC.is_open())
    assert.are.equal(win, vim.api.nvim_get_current_win())
    assert.are.same({ "probe" }, vim.api.nvim_buf_get_lines(0, 0, 1, false))
    assert.truthy(vim.api.nvim_buf_is_valid(termbuf))
    vim.fn.delete(f)
  end)

  it(":b# jumps between the file and OpenCode inside the float", function()
    stub_live_sleep()
    OC.open("")
    local termbuf = vim.api.nvim_get_current_buf()

    local f = vim.fn.tempname()
    vim.fn.writefile({ "probe" }, f)
    vim.cmd("edit " .. vim.fn.fnameescape(f))
    assert.are.equal(termbuf, vim.fn.bufnr("#"))

    vim.cmd("b#")
    assert.are.equal(termbuf, vim.api.nvim_get_current_buf())
    vim.cmd("b#")
    assert.are.same({ "probe" }, vim.api.nvim_buf_get_lines(0, 0, 1, false))
    vim.fn.delete(f)
  end)

  it("toggle while a file is shown in the float closes it, both buffers survive", function()
    stub_live_sleep()
    OC.open("")
    local termbuf = vim.api.nvim_get_current_buf()

    local f = vim.fn.tempname()
    vim.fn.writefile({ "probe" }, f)
    vim.cmd("edit " .. vim.fn.fnameescape(f))
    local filebuf = vim.api.nvim_get_current_buf()

    OC.open("") -- toggle closed
    assert.falsy(OC.is_open())
    assert.truthy(vim.api.nvim_buf_is_valid(termbuf))
    assert.truthy(vim.api.nvim_buf_is_valid(filebuf))

    OC.open("") -- back to the live terminal, no new job
    assert.are.equal(termbuf, vim.api.nvim_get_current_buf())
    assert.are.equal(1, termopen_calls)
    vim.fn.delete(f)
  end)

  it("reopening reuses the live terminal instead of spawning again", function()
    stub_live_sleep()
    OC.open("")
    local termbuf = vim.api.nvim_get_current_buf()
    assert.are.equal(1, termopen_calls)
    OC.open("") -- toggle closed; buffer must survive
    assert.falsy(OC.is_open())
    assert.truthy(vim.api.nvim_buf_is_valid(termbuf))
    OC.open("")
    assert.truthy(OC.is_open())
    assert.are.equal(termbuf, vim.api.nvim_get_current_buf())
    assert.are.equal(1, termopen_calls)
  end)

  it("no TelescopeFindPre auto-close is registered", function()
    -- The file must open inside the float (telescope's original_win_id, the
    -- same as claude-code.nvim) so that `#` is the terminal and :b# works.
    -- Detaching first would rebase `#` onto the buffer underneath instead.
    local ok = pcall(vim.api.nvim_get_autocmds, { group = "YoonheeOpenCodeTelescope", event = "User" })
    assert.is_false(ok)
  end)

  it("close() with no float open is a no-op", function()
    assert.falsy(OC.is_open())
    local ok = pcall(OC.close)
    assert.truthy(ok)
  end)
end)

describe("opencode float failure cases", function()
  local orig_termopen, orig_executable, orig_notify
  local jobs, notes

  before_each(function()
    orig_termopen = vim.fn.termopen
    orig_executable = vim.fn.executable
    orig_notify = vim.notify
    jobs = {}
    notes = {}
    vim.notify = function(msg, level, ...)
      table.insert(notes, { msg = msg, level = level })
    end
  end)

  after_each(function()
    vim.fn.termopen = orig_termopen
    vim.fn.executable = orig_executable
    vim.notify = orig_notify
    if OC.is_open() then OC.close() end
    for _, j in ipairs(jobs) do pcall(vim.fn.jobstop, j) end
    jobs = {}
    vim.wait(200) -- pump scheduled on_exit handlers so state settles
    local b = T.get_buf()
    if b and vim.api.nvim_buf_is_valid(b) then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end)

  local function notify_has(level, pattern)
    for _, n in ipairs(notes) do
      if n.level == level and tostring(n.msg):find(pattern) then return true end
    end
    return false
  end

  it("resolves the launcher script from the checkout, not stdpath(config)", function()
    -- The repo under test is not necessarily at ~/.config/nvim (CI checks
    -- out elsewhere). The executable check must hit <root>/scripts/..., so
    -- capture the probed path instead of hardcoding any location.
    local seen = {}
    vim.fn.executable = function(p) table.insert(seen, p); return 0 end
    OC.open("")
    assert.falsy(OC.is_open())
    local dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") -- tests/
    local root = vim.fn.fnamemodify(dir, ":h") -- <root>/
    assert.are.equal(1, #seen)
    assert.are.equal(root .. "/scripts/opencode-tmux.sh", seen[1])
  end)

  it("refuses to open when the launcher script is not executable", function()
    vim.fn.executable = function() return 0 end
    OC.open("")
    assert.falsy(OC.is_open())
    assert.is_nil(T.get_buf())
    assert.truthy(notify_has(vim.log.levels.ERROR, "not executable"))
  end)

  it("closes the float and errors when the terminal fails to start", function()
    vim.fn.termopen = function() return 0 end
    OC.open("")
    assert.falsy(OC.is_open())
    assert.truthy(notify_has(vim.log.levels.ERROR, "failed to start terminal"))
  end)

  it("a dead (non-terminal) leftover buffer is replaced, not reused", function()
    vim.fn.termopen = function() return 0 end
    OC.open("") -- leaves a scratch nofile buffer behind in M.buf
    local leftover = T.get_buf()
    assert.truthy(leftover and vim.api.nvim_buf_is_valid(leftover))
    assert.are.equal("nofile", vim.api.nvim_get_option_value("buftype", { buf = leftover }))

    local calls = 0
    vim.fn.termopen = function(_, opts)
      calls = calls + 1
      local id = orig_termopen("sleep 60", opts)
      table.insert(jobs, id)
      return id
    end
    OC.open("")
    assert.truthy(OC.is_open())
    assert.are.equal(1, calls)
    assert.is_false(vim.api.nvim_buf_is_valid(leftover))
    local fresh = T.get_buf()
    assert.truthy(fresh ~= leftover)
    assert.are.equal("terminal", vim.api.nvim_get_option_value("buftype", { buf = fresh }))
  end)

  it("an exited terminal wipes the dead buffer and the next open respawns", function()
    vim.fn.termopen = function(_, opts) return orig_termopen("true", opts) end
    OC.open("")
    assert.truthy(OC.is_open())
    local dead = T.get_buf()

    -- `true` exits at once; on_exit is vim.schedule'd, so wait for it.
    vim.wait(2000, function() return T.get_buf() == nil end)
    assert.falsy(OC.is_open())
    assert.is_nil(T.get_buf())
    assert.is_false(vim.api.nvim_buf_is_valid(dead))

    local calls = 0
    vim.fn.termopen = function(_, opts)
      calls = calls + 1
      local id = orig_termopen("sleep 60", opts)
      table.insert(jobs, id)
      return id
    end
    OC.open("")
    assert.truthy(OC.is_open())
    assert.are.equal(1, calls)
    local fresh = T.get_buf()
    assert.truthy(fresh ~= dead)
    assert.are.equal("terminal", vim.api.nvim_get_option_value("buftype", { buf = fresh }))
  end)
end)
