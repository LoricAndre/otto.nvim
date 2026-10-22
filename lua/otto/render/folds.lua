-- Folds of the transcript, which are manual, since 'foldexpr' folds don't update in insert mode. Folds belong to
-- windows, so the transcript keeps them, and windows fold the buffer once they show it. They're made closed, once
-- they're whole, since folds can't grow

local M = {}

--- @class otto.Fold
--- @field top integer 1-indexed, like Ex ranges
--- @field bottom integer
--- @field nested boolean Inside the fold of a group

--- Creates the fold, closed, in the current window. Folds inside it nest
--- @param fold otto.Fold
local function create(fold) vim.cmd(('%d,%dfold'):format(fold.top, fold.bottom)) end

--- Folds lines of the buffer in each window that shows it
--- @param bufnr integer
--- @param list otto.Fold[] Of the buffer, which the fold joins
--- @param top integer
--- @param bottom integer
--- @param nested boolean
function M.add(bufnr, list, top, bottom, nested)
  local fold = { top = top, bottom = bottom, nested = nested }
  table.insert(list, fold)
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.wo[win].foldmethod == 'manual' then vim.api.nvim_win_call(win, function() create(fold) end) end
  end
end

--- Folds the buffer in the current window, which has 'foldmethod' set to manual
--- @param list otto.Fold[]
function M.apply(list)
  vim.cmd('normal! zE')
  -- from the inside out, since Ex ranges include the closed folds that they touch
  for _, nested in ipairs({ true, false }) do
    for _, fold in ipairs(list) do
      if fold.nested == nested then create(fold) end
    end
  end
end

return M
