return {
  'akinsho/toggleterm.nvim',
  version = "*",
  keys = {
    {
      "<leader>t",
      function()
        local tabnr = vim.api.nvim_tabpage_get_number(0)
        local buf_dir = vim.fn.expand("%:p:h")
        if buf_dir == "" or vim.fn.isdirectory(buf_dir) == 0 then
          buf_dir = vim.fn.getcwd()
        end
        vim.cmd(tabnr .. "ToggleTerm dir=" .. vim.fn.fnameescape(buf_dir))
      end,
      desc = "Toggle tab-scoped terminal",
    },
    { "<Esc><Esc>", [[<C-\><C-n>]], mode = "t", desc = "Exit terminal mode" },
  },
  config = true,
};
