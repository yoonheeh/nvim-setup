return {
    "nvim-telescope/telescope.nvim",

    tag = "0.1.5",

    dependencies = {
        "nvim-lua/plenary.nvim"
    },

    config = function()
        require('telescope').setup({})

        local builtin = require('telescope.builtin')
        vim.keymap.set('n', '<leader>pf', builtin.find_files, {})
        vim.keymap.set('n', '<C-p>', builtin.git_files, {})
        vim.keymap.set('n', '<leader>pws', function()
            local word = vim.fn.expand("<cword>")
            builtin.grep_string({ search = word })
        end)
        vim.keymap.set('n', '<leader>pWs', function()
            local word = vim.fn.expand("<cWORD>")
            builtin.grep_string({ search = word })
        end)
        vim.keymap.set('n', '<leader>ps', function()
            builtin.grep_string({ search = vim.fn.input("Grep > ") })
        end)
        vim.keymap.set('n', '<leader>vh', builtin.help_tags, {})
        vim.keymap.set('n', '<leader>pg', builtin.live_grep, {})
        vim.keymap.set('n', '<leader>pb', builtin.buffers, {})
        vim.keymap.set('n', '<leader>gs', builtin.git_status, { desc = "Git: status picker" })
        vim.keymap.set('n', '<leader>km', builtin.keymaps,    { desc = "Search keymaps" })

        -- Files changed relative to a branch (default: origin/devel)
        local function branch_diff(branch)
            branch = branch or "origin/devel"
            local files = vim.fn.systemlist({ "git", "diff", "--name-only", branch })
            if vim.v.shell_error ~= 0 or #files == 0 then
                vim.notify("No changed files vs " .. branch, vim.log.levels.INFO)
                return
            end

            local pickers    = require("telescope.pickers")
            local finders    = require("telescope.finders")
            local conf       = require("telescope.config").values
            local make_entry = require("telescope.make_entry")
            local previewers = require("telescope.previewers")

            pickers.new({}, {
                prompt_title = "Changed vs " .. branch,
                finder = finders.new_table({
                    results     = files,
                    entry_maker = make_entry.gen_from_file(),
                }),
                sorter    = conf.file_sorter({}),
                previewer = previewers.new_termopen_previewer({
                    get_command = function(entry)
                        return { "git", "diff", branch, "--", entry.value }
                    end,
                }),
            }):find()
        end

        vim.keymap.set('n', '<leader>gD', function() branch_diff() end,
            { desc = "Git: diff vs origin/devel" })

        vim.api.nvim_create_user_command('BranchDiff', function(opts)
            branch_diff(opts.args ~= "" and opts.args or nil)
        end, { nargs = "?", desc = "Browse files changed vs branch (default: origin/devel)" })
    end
}
