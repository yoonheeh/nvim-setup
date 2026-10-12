-- Minimal init for headless regression tests. Loads only the plugin under
-- test plus plenary's busted harness: no lazy.nvim, no network, no user config.
-- Used as `minimal_init` by PlenaryBustedDirectory (see tests/run.sh).
local tests_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")
-- NB: apply :h separately (fnamemodify(":p:h") misbehaves on long paths).
local plugin_dir = vim.fn.fnamemodify(tests_dir, ":h") -- agent-review.nvim/
vim.opt.rtp:append(plugin_dir)

local plenary_dir = vim.fn.stdpath("data") .. "/lazy/plenary.nvim"
assert(vim.fn.isdirectory(plenary_dir) == 1,
  "plenary.nvim not found at " .. plenary_dir .. " (required for the test harness)")
vim.opt.rtp:append(plenary_dir)
vim.cmd("runtime plugin/plenary.vim")

require("agent-review").setup()
