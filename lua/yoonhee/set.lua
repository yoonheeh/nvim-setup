vim.opt.guicursor = ""

vim.opt.nu = true
vim.opt.relativenumber = true

vim.opt.tabstop = 2
vim.opt.softtabstop = 2
vim.opt.shiftwidth = 2
vim.opt.expandtab = true

vim.opt.smartindent = true

vim.opt.wrap = false

vim.opt.termguicolors = true

vim.opt.scrolloff = 8
vim.opt.signcolumn = "yes"
vim.opt.showmode = false

-- Use plain black background for terminal windows (no theme applied)
vim.api.nvim_set_hl(0, "TermNormal", { bg = "#000000", fg = "#ffffff" })
vim.api.nvim_create_autocmd("TermOpen", {
  callback = function()
    vim.wo.winhighlight = "Normal:TermNormal"
  end,
})
