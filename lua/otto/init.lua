-- Experimental neovim-native agent buffer

local config = require('otto.config')
local providers = require('otto.providers')
local uri = require('otto.uri')
local view = require('otto.view')
local winbar = require('otto.ui.winbar')

local M = {}

--- @param opts? otto.ConfigPartial
function M.setup(opts) config.set(opts or {}) end

--- Opens a new session
--- @param name? string
--- @param provider? string Defaults to `default_provider`
function M.new(name, provider)
  provider = provider or config.default_provider
  local session_uri = uri.unique(provider, providers.get(provider).new_id(name))
  view.pending_names[session_uri] = name
  vim.cmd.edit(session_uri)
end

--- Sends a reference to lines of the current file to the most recent session
--- @param first integer
--- @param last integer
function M.send(first, last)
  local path = vim.fn.expand('%:.')
  M.append(first == last and ('`%s:%d`'):format(path, first) or ('`%s:%d-%d`'):format(path, first, last))
end

--- @return otto.View[] views of open sessions, most recently used first
local function open_views()
  local views = view.views
  local infos = vim.tbl_filter(function(info) return views[info.bufnr] ~= nil end, vim.fn.getbufinfo({ bufloaded = 1 }))
  table.sort(infos, function(a, b) return a.lastused > b.lastused end)
  return vim.tbl_map(function(info) return views[info.bufnr] end, infos)
end

--- Appends text to the most recently used session by default, or a new one, and starts insert mode
--- @param text string
--- @param session_bufnr? integer Of the session
function M.append(text, session_bufnr)
  local recent = view.views[session_bufnr] or open_views()[1]
  if recent ~= nil then
    vim.cmd.buffer(recent.bufnr)
  else
    M.new()
  end

  local line = vim.api.nvim_buf_get_lines(0, -2, -1, false)[1]
  local space = (line == '' or line:match('%s$')) and '' or ' '
  vim.api.nvim_buf_set_text(0, -1, #line, -1, #line, { space .. text .. ' ' })
  -- in the input, which entering insert mode from the transcript would move the cursor to the start of
  vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(0), 0 })
  vim.cmd.startinsert({ bang = true })
end

--- Spaces the transcript from the edge, highlighted like the prompts on their lines
--- https://github.com/neovim/neovim/issues/12866
--- @return string
function M.statuscolumn()
  local current = view.views[vim.api.nvim_win_get_buf(vim.g.statusline_winid)]
  return current and current.transcript:is_prompt(vim.v.lnum - 1) and '%#OttoPrompt#  ' or '  '
end

--- @return string
function M.winbar()
  local current = view.views[vim.api.nvim_win_get_buf(vim.g.statusline_winid)]
  return current and winbar.render(current) or ''
end

return M
