return {
  {
    "lewis6991/gitsigns.nvim",
    config = function()
      local gs = require("gitsigns")
      gs.setup({
        current_line_blame = true,
        current_line_blame_opts = {
          delay = 300,
        },
      })

      vim.keymap.set("n", "<leader>gh", gs.toggle_linehl,    { desc = "Git: toggle line highlights" })
      vim.keymap.set("n", "<leader>gd", gs.toggle_word_diff, { desc = "Git: toggle word diff" })
    end,
  },
  {
    "nvim-lualine/lualine.nvim",
    dependencies = { "nvim-tree/nvim-web-devicons", "lewis6991/gitsigns.nvim" },
    config = function()
      require("lualine").setup({
        sections = {
          lualine_b = { "branch" },
          lualine_c = {
            "filename",
            {
              function()
                return vim.b.gitsigns_blame_line or ""
              end,
              cond = function()
                return vim.b.gitsigns_blame_line ~= nil
              end,
            },
          },
        },
      })
    end,
  },
}
