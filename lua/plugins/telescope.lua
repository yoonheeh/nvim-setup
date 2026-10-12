return {
    "nvim-telescope/telescope.nvim",

    tag = "0.1.5",

    dependencies = {
        "nvim-lua/plenary.nvim"
    },

    config = function()
        require('telescope').setup({})

        -- Compat: telescope (even master) still calls
        -- require("nvim-treesitter.parsers").ft_to_lang() and
        -- require("nvim-treesitter.configs").is_enabled(), both gone in
        -- nvim-treesitter `main` + Neovim 0.11/0.12 (ft_to_lang -> get_lang).
        -- Override the preview highlighter with a vim.treesitter.start-based
        -- version so <leader>pf etc. fall back cleanly instead of throwing
        -- "attempt to call field 'ft_to_lang' (a nil value)".
        do
            local ok, putils = pcall(require, "telescope.previewers.utils")
            if ok and putils.ts_highlighter then
                putils.ts_highlighter = function(bufnr, ft)
                    if not ft or ft == "" then return false end
                    if not vim.api.nvim_buf_is_valid(bufnr) then return false end
                    local lang_ok, lang = pcall(vim.treesitter.language.get_lang, ft)
                    local lang = (lang_ok and lang) or ft
                    -- No parser installed -> let caller fall back to regex.
                    if not pcall(vim.treesitter.language.add, lang) then
                        return false
                    end
                    if not pcall(vim.treesitter.start, bufnr, lang) then
                        return false
                    end
                    return true
                end
            end
            -- Same dead API is used by current_buffer_fuzzy_find
            -- (builtin/__files.lua). A tiny shim keeps that path from
            -- erroring too; it just maps ft -> lang via core.
            local parsers_ok, parsers = pcall(require, "nvim-treesitter.parsers")
            if parsers_ok and type(parsers) == "table" and not parsers.ft_to_lang then
                parsers.ft_to_lang = function(ft)
                    local lang_ok, lang = pcall(vim.treesitter.language.get_lang, ft)
                    return (lang_ok and lang) or ft
                end
            end
        end

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
