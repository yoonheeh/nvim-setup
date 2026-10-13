-- Checks run inside Neovim by tests/fresh-install.sh, after the full user
-- config has started. FRESH_CHECK selects the step:
--   plugins  every lazy-lock.json plugin is installed at its locked commit
--   parsers  every ensure_installed parser finishes compiling (the config
--            starts these installs itself; this only waits for them)
--   files    sample files get a filetype and an active treesitter highlighter
-- Exits Neovim with status 1 on the first failure.

local step = vim.env.FRESH_CHECK
local failures = {}

local function fail(msg)
    failures[#failures + 1] = msg
end

local function finish()
    if vim.v.errmsg ~= "" then
        fail("v:errmsg after startup: " .. vim.v.errmsg)
    end
    if #failures > 0 then
        io.stderr:write("\nFAIL [" .. step .. "]\n  " .. table.concat(failures, "\n  ") .. "\n")
        vim.cmd("cquit 1")
    end
    io.stdout:write("\nok [" .. step .. "]\n")
    vim.cmd("qall!")
end

local steps = {}

function steps.plugins()
    local lock = vim.json.decode(table.concat(
        vim.fn.readfile(vim.fn.stdpath("config") .. "/lazy-lock.json"), "\n"))
    local root = vim.fn.stdpath("data") .. "/lazy/"
    for name, entry in pairs(lock) do
        local dir = root .. name
        if vim.fn.isdirectory(dir) == 0 then
            fail(name .. ": not installed")
        else
            local head = vim.trim(vim.fn.system({ "git", "-C", dir, "rev-parse", "HEAD" }))
            if head ~= entry.commit then
                fail(("%s: at %s, lazy-lock.json has %s"):format(name, head, entry.commit))
            end
        end
    end
end

function steps.parsers()
    local wanted = require("nvim-treesitter.configs").get_ensure_installed_parsers()
    if #wanted == 0 then
        -- Empty when the treesitter config errored before calling setup().
        return fail("ensure_installed is empty (did the treesitter config run?)")
    end
    -- Try loading each parser: parsers.has_parser() caches its first answer
    -- (so stays false after the build), and a .so that exists may still be
    -- mid-copy.
    local function missing()
        local out = {}
        for _, lang in ipairs(wanted) do
            -- language.add returns nil (no error) when the parser is missing.
            local ok, loaded = pcall(vim.treesitter.language.add, lang)
            if not (ok and loaded) then
                out[#out + 1] = lang
            end
        end
        return out
    end
    local timeout_ms = tonumber(vim.env.FRESH_PARSER_TIMEOUT_MS) or 600000
    vim.wait(timeout_ms, function() return #missing() == 0 end, 1000)
    if #missing() > 0 then
        fail(("parsers not installed after %ds: %s"):format(
            timeout_ms / 1000, table.concat(missing(), ", ")))
    end
end

function steps.files()
    -- extension -> filetype; each needs a parser from ensure_installed.
    local samples = {
        lua = "lua", py = "python", go = "go", rs = "rust", c = "c",
        js = "javascript", ts = "typescript", sh = "sh",
    }
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    for ext, ft in pairs(samples) do
        local path = dir .. "/sample." .. ext
        vim.fn.writefile({ "x" }, path)
        vim.cmd.edit(vim.fn.fnameescape(path))
        local buf = vim.api.nvim_get_current_buf()
        if vim.bo[buf].filetype ~= ft then
            fail(("%s: filetype %q, expected %q"):format(path, vim.bo[buf].filetype, ft))
        elseif not vim.treesitter.highlighter.active[buf] then
            fail(path .. ": no treesitter highlighter")
        end
    end
end

-- A Lua error inside a step must fail it: headless Neovim would otherwise
-- print the error and keep running.
if not steps[step] then
    fail("unknown FRESH_CHECK " .. tostring(step))
else
    local ok, err = pcall(steps[step])
    -- First line only: a failed require() lists every path it searched.
    if not ok then fail("error: " .. tostring(err):match("[^\n]*")) end
end

finish()
