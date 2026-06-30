-- Local plugin: GitHub-style inline code review backed by a Claude session.
-- Implementation lives in claude-review.nvim/lua/claude-review/init.lua.
return {
  dir = vim.fn.stdpath("config") .. "/claude-review.nvim",
  name = "claude-review",
  -- Load lazily the first time a review action is used.
  keys = {
    { "<leader>rc", mode = "v", desc = "Claude review: start thread on selection" },
    { "<leader>rt", desc = "Claude review: open thread at cursor" },
    { "<leader>rn", desc = "Claude review: next thread" },
    { "<leader>rp", desc = "Claude review: prev thread" },
    { "<leader>rx", desc = "Claude review: clear threads for buffer" },
  },
  cmd = "ClaudeReviewDebug",
  config = function()
    require("claude-review").setup()
  end,
}
