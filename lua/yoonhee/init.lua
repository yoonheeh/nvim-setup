vim.g.mapleader = " "
vim.g.maplocalleader = "\\"

require("yoonhee.set")
require("yoonhee.remap")
require("yoonhee.lazy_init")
require("yoonhee.opencode").setup()
require("yoonhee.float_split").setup()
