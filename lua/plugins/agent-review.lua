-- Local plugin: GitHub-style inline code review backed by an agent session
-- (Claude by default, OpenCode via :ReviewBackend).
-- Implementation lives in agent-review.nvim/lua/agent-review/init.lua.
return {
  dir = vim.fn.stdpath("config") .. "/agent-review.nvim",
  name = "agent-review",
  -- Load lazily the first time a review action is used.
  keys = {
    { "<leader>rc", mode = "v", desc = "Agent review: start thread on selection" },
    { "<leader>rt", desc = "Agent review: open thread at cursor" },
    { "<leader>rn", desc = "Agent review: next thread" },
    { "<leader>rp", desc = "Agent review: prev thread" },
    { "<leader>rx", desc = "Agent review: clear threads for buffer" },
  },
  cmd = { "AgentReviewDebug", "ClaudeReviewDebug", "ReviewBackend" },
  config = function()
    require("agent-review").setup()
  end,
}
