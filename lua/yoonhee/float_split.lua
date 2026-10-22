-- Make :split / :vsplit work from a file opened inside a floating window,
-- such as the full-screen Claude Code window.
--
-- Neovim can't split a float: the split happens in the normal window layout
-- underneath, hidden by the float. So when a new normal window opens while
-- leaving a float that shows a file, close the float and show its file in the
-- window that was split, leaving the two side by side as :vsplit intended.
-- Claude keeps running; toggling Claude Code opens its window again.

local M = {}

-- The window that `new` was split from: its neighbour in the layout, on the
-- side away from where splitright / splitbelow put the new window.
local function split_from(new)
  local function walk(node)
    if node[1] == "leaf" then return nil end
    local kids = node[2]
    for i, kid in ipairs(kids) do
      if kid[1] == "leaf" and kid[2] == new then
        local new_after = (node[1] == "row") and vim.o.splitright or vim.o.splitbelow
        local other = new_after and kids[i - 1] or kids[i + 1]
        return other and other[1] == "leaf" and other[2] or nil
      end
      local found = walk(kid)
      if found then return found end
    end
  end
  return walk(vim.fn.winlayout())
end

function M.setup()
  vim.api.nvim_create_autocmd("WinNew", {
    group    = vim.api.nvim_create_augroup("FloatSplit", { clear = true }),
    callback = function()
      -- During WinNew the new window is current and the previous window is
      -- the one the split was run from.
      local new   = vim.api.nvim_get_current_win()
      local float = vim.fn.win_getid(vim.fn.winnr("#"))
      if float == 0 or vim.api.nvim_win_get_config(float).relative == ""
        or vim.api.nvim_win_get_config(new).relative ~= "" then
        return
      end
      local buf = vim.api.nvim_win_get_buf(float)
      -- Only real files: not the Claude terminal itself, hover/preview popups,
      -- or claude-review's own panel and comment box.
      if vim.bo[buf].buftype ~= "" or vim.b[buf].claude_review then return end

      local base = split_from(new)
      local view = vim.api.nvim_win_call(float, vim.fn.winsaveview)
      -- Let the split command finish before rearranging windows.
      vim.schedule(function()
        if not vim.api.nvim_win_is_valid(new) then return end
        if vim.api.nvim_win_is_valid(float) then pcall(vim.api.nvim_win_close, float, false) end
        if base and vim.api.nvim_win_is_valid(base) and vim.api.nvim_buf_is_valid(buf) then
          vim.api.nvim_win_set_buf(base, buf)
          vim.api.nvim_win_call(base, function() vim.fn.winrestview(view) end)
        end
        vim.api.nvim_set_current_win(new)
      end)
    end,
  })
end

return M
