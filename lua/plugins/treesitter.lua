-- nvim-treesitter `main` branch (rewritten): no `configs` module anymore.
-- Highlighting comes from Neovim core (vim.treesitter.start), parsers via
-- require("nvim-treesitter").install(). This spec ports the old setup:
-- parser list, auto-install, html/size guards, markdown regex highlighting,
-- indent, and the custom templ parser.
return {
    {
    "nvim-treesitter/nvim-treesitter",
    branch = "main",
    lazy = false, -- upstream does not support lazy-loading
    build = ":TSUpdate",
    config = function()
        local ts = require("nvim-treesitter")

        -- Custom parser (was get_parser_configs().templ = ...).
        require("nvim-treesitter.parsers").templ = {
            install_info = {
                url = "https://github.com/vrischmann/tree-sitter-templ.git",
                files = {"src/parser.c", "src/scanner.c"},
                branch = "master",
            },
        }

        vim.treesitter.language.register("templ", "templ")

        -- Startup set mirrors the old ensure_installed; anything else
        -- (e.g. templ) installs on demand via the FileType autocmd below.
        local wanted = {
            "vimdoc", "javascript", "typescript", "c", "lua", "rust",
            "jsdoc", "bash", "python", "go",
        }

        -- Install parsers asynchronously (was sync_install = false).
        -- No-op for parsers already installed.
        ts.install(wanted)

        local group = vim.api.nvim_create_augroup("YoonheeTreesitter", { clear = true })
        vim.api.nvim_create_autocmd("FileType", {
            group = group,
            callback = function(args)
                local buf = args.buf
                local ft = vim.bo[buf].filetype
                if ft == "" then return end

                local ok, lang = pcall(vim.treesitter.language.get_lang, ft)
                lang = (ok and lang) or ft

                -- Automatically install missing parsers (was auto_install =
                -- true). Probes loadability so already-installed parsers
                -- highlight immediately, wherever they live on rtp.
                if not pcall(vim.treesitter.language.add, lang) then
                    ts.install({ lang })
                    return -- parser applies on next open, like before
                end

                -- Highlight guard (was highlight.disable): skip html and
                -- large files.
                if lang == "html" then return end
                local max_filesize = 100 * 1024 -- 100 KB
                local stat_ok, stats = pcall(vim.uv.fs_stat, vim.api.nvim_buf_get_name(buf))
                if stat_ok and stats and stats.size > max_filesize then
                    vim.notify(
                        "File larger than 100KB treesitter disabled for performance",
                        vim.log.levels.WARN,
                        {title = "Treesitter"}
                    )
                    return
                end

                -- Markdown keeps vim-regex highlighting alongside treesitter
                -- (was additional_vim_regex_highlighting = { "markdown" }).
                if ft == "markdown" and vim.bo[buf].syntax == "" then
                    vim.bo[buf].syntax = "markdown"
                end

                pcall(vim.treesitter.start, buf)

                -- Treesitter indent (was indent = { enable = true }).
                vim.bo[buf].indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"
            end,
        })
    end
    },

    {
        "nvim-treesitter/nvim-treesitter-context",
        after = "nvim-treesitter",
        config = function()
            require'treesitter-context'.setup{
                enable = true, -- Enable this plugin (Can be enabled/disabled later via commands)
                multiwindow = false, -- Enable multiwindow support.
                max_lines = 0, -- How many lines the window should span. Values <= 0 mean no limit.
                min_window_height = 0, -- Minimum editor window height to enable context. Values <= 0 mean no limit.
                line_numbers = true,
                multiline_threshold = 20, -- Maximum number of lines to show for a single context
                trim_scope = 'outer', -- Which context lines to discard if `max_lines` is exceeded. Choices: 'inner', 'outer'
                mode = 'cursor',  -- Line used to calculate context. Choices: 'cursor', 'topline'
                -- Separator between context and content. Should be a single character string, like '-'.
                -- When separator is set, the context will only show up when there are at least 2 lines above cursorline.
                separator = nil,
                zindex = 20, -- The Z-index of the context window
                on_attach = nil, -- (fun(buf: integer): boolean) return false to disable attaching
            }
        end
    }
}
