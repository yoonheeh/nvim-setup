-- Assorted lazy-loaded utility plugins.
return {
  {
    "nvim-neorg/neorg",
    -- lazy-load on filetype
    ft = "norg",
    -- automatically calls require("neorg").setup(opts)
    opts = {
      load = {
        ["core.defaults"] = {},
      },
    },
  },

  {
    "dstein64/vim-startuptime",
    -- lazy-load on a command
    cmd = "StartupTime",
    init = function()
      vim.g.startuptime_tries = 10
    end,
  },

  -- API plugin used by other plugins; load on demand.
  { "nvim-tree/nvim-web-devicons", lazy = true },

  -- UI niceties that can load after the initial screen.
  { "stevearc/dressing.nvim", event = "VeryLazy" },

  {
    "Wansmer/treesj",
    keys = {
      { "J", "<cmd>TSJToggle<cr>", desc = "Join Toggle" },
    },
    opts = { use_default_keymaps = false, max_join_length = 150 },
  },

  {
    "monaqa/dial.nvim",
    -- lazy-load on keys
    keys = { "<C-a>", { "<C-x>", mode = "n" } },
  },
}
