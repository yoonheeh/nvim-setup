return {
  "greggh/claude-code.nvim",
  dependencies = {
    "nvim-lua/plenary.nvim", -- Required for git operations
  },
  config = function()
    require("claude-code").setup({
      -- Run Claude inside a tmux session so it survives Neovim exiting;
      -- reopening it in the same directory reconnects (scripts/claude-tmux.sh).
      command = vim.fn.shellescape(vim.fn.stdpath("config") .. "/scripts/claude-tmux.sh"),
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

    local claude_tmux = require("yoonhee.claude_tmux")
    vim.api.nvim_create_user_command("ClaudeSessions", claude_tmux.pick_and_kill,
      { desc = "Close a running Claude tmux session" })
  end
}
