return {
  "bluz71/vim-moonfly-colors",
  name = "moonfly",
  lazy = false,    -- load during startup
  priority = 1000, -- load before other start plugins
  config = function()
    vim.cmd([[colorscheme moonfly]])
  end,
}
