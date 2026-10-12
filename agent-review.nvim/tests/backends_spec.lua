-- Regression tests for agent-review.nvim backends (plenary busted style).
-- Run with tests/run.sh. No live model, daemon, or network: external calls
-- are stubbed, fixtures mirror real `opencode` output shapes.
local R = require("agent-review")
local T = R._test

describe("agent-review backends", function()
  after_each(function()
    vim.g.review_backend = nil
  end)

  it("registers claude and opencode with the required interface", function()
    for _, key in ipairs({ "claude", "opencode" }) do
      local b = T.backends[key]
      assert.truthy(b)
      assert.is_string(b.name)
      assert.is_function(b.find_session_id)
      assert.is_function(b.ask)
    end
    assert.is_function(T.backends.opencode.parse_text)
  end)

  it("defaults to claude and falls back on invalid values", function()
    assert.are.equal("claude", T.current_backend())
    vim.g.review_backend = "opencode"
    assert.are.equal("opencode", T.current_backend())
    vim.g.review_backend = "bogus"
    assert.are.equal("claude", T.current_backend())
  end)

  it(":ReviewBackend switches, keeps, and rejects", function()
    vim.cmd("ReviewBackend opencode")
    assert.are.equal("opencode", vim.g.review_backend)
    -- Invalid input surfaces an error and leaves the backend unchanged.
    local ok = pcall(vim.cmd, "ReviewBackend bogus")
    assert.is_false(ok)
    assert.are.equal("opencode", vim.g.review_backend)
    vim.cmd("ReviewBackend claude")
    assert.are.equal("claude", vim.g.review_backend)
  end)

  it(":AgentReviewDebug and :ClaudeReviewDebug alias both exist", function()
    assert.are.equal(2, vim.fn.exists(":AgentReviewDebug"))
    assert.are.equal(2, vim.fn.exists(":ClaudeReviewDebug"))
    assert.are.equal(2, vim.fn.exists(":ReviewBackend"))
  end)
end)

describe("opencode parse_text", function()
  local parse = T.backends.opencode.parse_text

  it("extracts text from a real run envelope, skipping framing", function()
    local data = {
      '{"type":"step_start","timestamp":1791807856877,"sessionID":"ses_x","part":{"type":"step-start"}}',
      '{"type":"text","timestamp":1791807857215,"sessionID":"ses_x","part":{"id":"prt_1","type":"text","text":"THIRD-OK"}}',
      '{"type":"step_finish","timestamp":1791807857235,"sessionID":"ses_x","part":{"type":"step-finish"}}',
      "",
    }
    assert.are.equal("THIRD-OK", parse(data))
  end)

  it("ignores tool parts, garbage lines, and blanks", function()
    local data = {
      '{"type":"text","part":{"type":"tool","name":"read"}}',
      "not json at all",
      "",
    }
    assert.is_nil(parse(data))
  end)

  it("joins multi-step replies with a blank line", function()
    local data = {
      '{"type":"text","part":{"type":"text","text":"A"}}',
      '{"type":"text","part":{"type":"text","text":"B"}}',
    }
    assert.are.equal("A\n\nB", parse(data))
  end)

  it("trims surrounding whitespace like the claude path", function()
    local data = { '{"type":"text","part":{"type":"text","text":"\\n  Hi\\n\\n"}}' }
    assert.are.equal("Hi", parse(data))
  end)
end)

describe("opencode session discovery", function()
  local real_executable, real_run
  local parse = T.backends.opencode.parse_session_list

  before_each(function()
    real_executable = vim.fn.executable
    real_run = T.backends.opencode.run_session_list
    vim.fn.executable = function() return 1 end
  end)

  after_each(function()
    vim.fn.executable = real_executable
    T.backends.opencode.run_session_list = real_run
  end)

  it("picks the newest session in the worktree cwd", function()
    local out = vim.json.encode({
      { id = "ses_old", directory = "/fake/proj", updated = 100 },
      { id = "ses_new", directory = "/fake/proj", updated = 200 },
      { id = "ses_other", directory = "/fake/elsewhere", updated = 300 },
    })
    assert.are.equal("ses_new", parse(out, "/fake/proj"))
  end)

  it("returns nil with no session in the cwd", function()
    local out = vim.json.encode({
      { id = "ses_other", directory = "/fake/elsewhere", updated = 300 },
    })
    assert.is_nil(parse(out, "/fake/proj"))
  end)

  it("returns nil on empty list or bad json", function()
    assert.is_nil(parse("[]", "/fake/proj"))
    assert.is_nil(parse("not json{{{", "/fake/proj"))
  end)

  it("find_session_id composes runner and parser", function()
    T.backends.opencode.run_session_list = function()
      return vim.json.encode({ { id = "ses_x", directory = "/fake/proj", updated = 1 } })
    end
    assert.are.equal("ses_x", T.backends.opencode.find_session_id("/fake/proj"))
    T.backends.opencode.run_session_list = function() return nil end
    assert.is_nil(T.backends.opencode.find_session_id("/fake/proj"))
  end)

  it("find_session_id returns nil when opencode is missing", function()
    vim.fn.executable = function() return 0 end
    assert.is_nil(T.backends.opencode.find_session_id("/fake/proj"))
  end)
end)

describe("claude session discovery", function()
  it("returns nil when the project has no sessions", function()
    -- No ~/.claude/projects/<encoded> dir can exist for this path.
    assert.is_nil(T.backends.claude.find_session_id("/fake/no-such-proj-xyz"))
  end)
end)

describe("session resolve and dispatch", function()
  local orig_finders, orig_asks

  before_each(function()
    orig_finders = {
      claude = T.backends.claude.find_session_id,
      opencode = T.backends.opencode.find_session_id,
    }
    orig_asks = {
      claude = T.backends.claude.ask,
      opencode = T.backends.opencode.ask,
    }
  end)

  after_each(function()
    T.backends.claude.find_session_id = orig_finders.claude
    T.backends.opencode.find_session_id = orig_finders.opencode
    T.backends.claude.ask = orig_asks.claude
    T.backends.opencode.ask = orig_asks.opencode
    vim.g.review_backend = nil
  end)

  it("caches one session id per backend", function()
    local calls = {}
    T.backends.claude.find_session_id = function()
      calls.claude = (calls.claude or 0) + 1
      return "c1"
    end
    T.backends.opencode.find_session_id = function()
      calls.opencode = (calls.opencode or 0) + 1
      return "o1"
    end

    local wt = { cwd = "/fake/proj", sessions = {} }
    local n1, s1 = T.resolve_session(wt)
    assert.are.equal("claude", n1)
    assert.are.equal("c1", s1)
    T.resolve_session(wt)
    assert.are.equal(1, calls.claude) -- second call served from cache

    vim.g.review_backend = "opencode"
    local n3, s3 = T.resolve_session(wt)
    assert.are.equal("opencode", n3)
    assert.are.equal("o1", s3)
    assert.are.equal("c1", wt.sessions.claude) -- claude entry untouched
    assert.are.equal(1, calls.opencode)
  end)

  it("dispatches ask to the active backend with the cached id", function()
    local got = {}
    T.backends.claude.ask = function(_, sid, prompt, on_response)
      got.claude = { sid, prompt }
      on_response("c-ok")
    end
    T.backends.opencode.ask = function(_, sid, prompt, on_response)
      got.opencode = { sid, prompt }
      on_response("o-ok")
    end

    local wt = { cwd = "/fake/proj", sessions = { claude = "c1", opencode = "o1" } }
    local res
    T.run_backend(wt, "hello", function(r) res = r end)
    assert.are.same({ "c1", "hello" }, got.claude)
    assert.are.equal("c-ok", res)

    vim.g.review_backend = "opencode"
    T.run_backend(wt, "hi", function(r) res = r end)
    assert.are.same({ "o1", "hi" }, got.opencode)
    assert.are.equal("o-ok", res)
  end)

  it("calls back nil when no session is cached", function()
    local res = "pending"
    T.run_backend({ cwd = "/fake/proj", sessions = {} }, "hi", function(r) res = r end)
    assert.is_nil(res)
  end)
end)
