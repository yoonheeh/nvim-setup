return {
  {
    "lewis6991/gitsigns.nvim",
    config = function()
      require("gitsigns").setup({
        current_line_blame = true,
        current_line_blame_opts = {
          delay = 300,
        },
      })
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
