return {
  dir = "/home/yoonhee/developments/neovim-plugin/agent-dashboard.nvim",
  config = function()
    require("agent-dashboard").setup()
  end,
  keys = {
    { "<leader>ad", "<cmd>AgentDashboard<cr>", desc = "Agent Dashboard" },
  },
}
