return {
  "greggh/claude-code.nvim",
  dependencies = {
    "nvim-lua/plenary.nvim", -- Required for git operations
  },
  config = function()
    require("claude-code").setup({
      window = {
        position = "float",
        float = {
          width    = "100%",
          height   = "100%",
          border   = "none",
          relative = "editor",
        },
      },
      git = {
        use_git_root = false,
      },
    })
  end
}
