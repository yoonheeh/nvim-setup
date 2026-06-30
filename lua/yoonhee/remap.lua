-- mapleader is set in lazy_init.lua before lazy.nvim loads.

-- allow copy to clipboard
-- next greatest remap ever : asbjornHaland
vim.keymap.set({ "n", "v" }, "<leader>y", [["+y]])
vim.keymap.set("n", "<leader>Y", [["+Y]])
vim.keymap.set({ "n", "v" }, "<leader>p", [["+p]])
vim.keymap.set("n", "<leader>P", [["+P]])

vim.keymap.set("n", "<leader>ns", function()
  local dir = vim.fn.expand("~/notes/scratch")
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/" .. os.date("%Y-%m-%d-%H%M%S") .. ".mdx"
  vim.cmd("edit " .. vim.fn.fnameescape(path))
end, { desc = "New mdx scratch pad" })
