-- A session's buffer: its window options, and keeping the input and the transcript in place as they change. Its
-- keymaps come from the config once the session loads, without mapping over the keys of after/ftplugin/otto.lua

if vim.b.did_ftplugin then return end
vim.b.did_ftplugin = true

local bufnr = vim.api.nvim_get_current_buf()
local group = vim.api.nvim_create_augroup('otto.buffer', { clear = false })
-- which runs again when the session restarts and sets the filetype again
vim.b.undo_ftplugin = ("lua vim.api.nvim_clear_autocmds({ group = 'otto.buffer', buffer = %d })"):format(bufnr)

--- @return otto.View?
local function view() return require('otto.view').views[bufnr] end

vim.api.nvim_create_autocmd('BufWinEnter', {
  group = group,
  buffer = bufnr,
  callback = function()
    local wo = vim.wo[0][0]
    wo.foldmethod = 'manual'
    if view() ~= nil then view().transcript:fold() end
    wo.foldtext = ''
    wo.conceallevel = 0 -- concealed lines, like code fences, break scrolling
    wo.wrap = true
    wo.linebreak = true
    wo.number = false
    wo.relativenumber = false
    wo.signcolumn = 'no'
    wo.statuscolumn = "%!v:lua.require'otto'.statuscolumn()"
    wo.foldcolumn = '0'
    wo.winbar = "%!v:lua.require'otto'.winbar()"
    wo.winhighlight = 'Folded:Normal' -- folded tools look like the rest of the transcript
    -- once the window settles, so that the first output follows the prompt too
    local win = vim.api.nvim_get_current_win()
    vim.schedule(function()
      if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr then
        require('otto.ui.scroll').watch(win)
      end
    end)
  end,
})
vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
  group = group,
  buffer = bufnr,
  callback = function()
    if view() == nil then return end
    view().transcript:anchor()
    require('otto.highlight').input(bufnr)
  end,
})
vim.api.nvim_create_autocmd('InsertEnter', {
  group = group,
  buffer = bufnr,
  callback = function()
    if view() == nil then return end
    -- insert mode opens the fold under the cursor before the prompt buffer moves the cursor to the input
    local input_lnum = vim.api.nvim_buf_get_mark(bufnr, ':')[1]
    if vim.fn.line('.') >= input_lnum then return end
    vim.api.nvim_win_set_cursor(0, { input_lnum, 0 })
    vim.v.char = 'moved' -- keeps the cursor there, see :help InsertEnter
  end,
})
vim.api.nvim_create_autocmd('BufUnload', {
  group = group,
  buffer = bufnr,
  callback = function()
    local views = require('otto.view').views
    if views[bufnr] == nil then return end
    require('otto.ui.history').save_drafts({ bufnr })
    views[bufnr]:close()
    views[bufnr] = nil
  end,
})
