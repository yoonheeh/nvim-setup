-- Minimal init for headless regression tests of the user config (lua/yoonhee/*).
-- Loads only the module under test plus plenary's busted harness: no
-- lazy.nvim, no network, no full user config.
-- Used as `minimal_init` by PlenaryBustedDirectory (see tests/run.sh).
local tests_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")
-- NB: apply :h separately (fnamemodify(":p:h") misbehaves on long paths).
local config_dir = vim.fn.fnamemodify(tests_dir, ":h") -- ~/.config/nvim/
vim.opt.rtp:append(config_dir)

local plenary_dir = vim.fn.stdpath("data") .. "/lazy/plenary.nvim"
assert(vim.fn.isdirectory(plenary_dir) == 1,
  "plenary.nvim not found at " .. plenary_dir .. " (required for the test harness)")
vim.opt.rtp:append(plenary_dir)
vim.cmd("runtime plugin/plenary.vim")

require("yoonhee.opencode").setup()
