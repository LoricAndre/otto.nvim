-- Experimental neovim-native agent interface, see ARCHITECTURE.md

require('otto.highlights')
local commands = require('otto.ui.commands')
local config = require('otto.config')
local highlight = require('otto.highlight')
local history = require('otto.ui.history')
local keymaps = require('otto.ui.keymaps')
local pick = require('otto.ui.pick')
local prompt_area = require('otto.ui.prompt_area')
local providers = require('otto.providers')
local session = require('otto.session')
local util = require('otto.util')
local winbar = require('otto.ui.winbar')

local M = {}

--- Merges into the configuration, see `config.lua`
--- @param opts? otto.Config
function M.setup(opts) config.set(opts or {}) end

local sessions = session.sessions
local names = {} --- @type table<string, string> of new sessions by buffer name, until they start

-- the buffer has no parser, see `highlight.lua`, but plugins that parse it themselves, like blink.pairs, look up its
-- language
vim.treesitter.language.register('markdown', 'otto')

--- Opens a new session, which is named after its first prompt unless it's given a name
--- @param name? string
--- @param provider? string Defaults to `default_provider`
function M.new(name, provider)
  provider = provider or config.default_provider
  local id = providers.get(provider).new_id(name)
  -- like a session of the same name, or of the same second, that isn't saved yet
  local uri, count = ('%s://%s'):format(provider, id), 1
  while vim.fn.bufexists(uri) == 1 do
    count = count + 1
    uri = ('%s://%s_%d'):format(provider, id, count)
  end
  names[uri] = name
  vim.cmd.edit(uri)
end

--- Sends a reference to lines of the current file to the most recent session
--- @param first integer
--- @param last integer
function M.send(first, last)
  local path = vim.fn.expand('%:.')
  M.append(first == last and ('`%s:%d`'):format(path, first) or ('`%s:%d-%d`'):format(path, first, last))
end

--- @return otto.Session[] The open sessions, most recently used first
local function open_sessions()
  local infos = vim.tbl_filter(
    function(info) return sessions[info.bufnr] ~= nil end,
    vim.fn.getbufinfo({ bufloaded = 1 })
  )
  table.sort(infos, function(a, b) return a.lastused > b.lastused end)
  return vim.tbl_map(function(info) return sessions[info.bufnr] end, infos)
end

--- Appends text to the prompt of the session, the most recently used one by default, or a new one, and starts insert
--- mode there
--- @param text string
--- @param bufnr? integer Of the session
function M.append(text, bufnr)
  local recent = sessions[bufnr] or open_sessions()[1]
  if recent ~= nil then
    vim.cmd.buffer(recent.bufnr)
  else
    M.new()
  end

  local line = vim.api.nvim_buf_get_lines(0, -2, -1, false)[1]
  local space = (line == '' or line:match('%s$')) and '' or ' '
  vim.api.nvim_buf_set_text(0, -1, #line, -1, #line, { space .. text .. ' ' })
  vim.cmd.startinsert({ bang = true })
end

--- Spaces the transcript from the edge, highlighted like the prompts on their lines. Signs would do, but they only
--- highlight the first row of wrapped lines: https://github.com/neovim/neovim/issues/12866
--- @return string
function M.statuscolumn()
  local current = sessions[vim.api.nvim_win_get_buf(vim.g.statusline_winid)]
  return current and current.buffer:is_prompt(vim.v.lnum - 1) and '%#OttoPrompt#  ' or '  '
end

--- @return string
function M.winbar()
  local current = sessions[vim.api.nvim_win_get_buf(vim.g.statusline_winid)]
  return current and winbar.render(current) or ''
end

-- agents only save sessions with messages, so an empty session only has its buffer to remove, once it's been hidden
-- for a while
local shown = {} --- @type table<integer, integer> times each session buffer was shown in a window
--- @param bufnr integer
--- @return boolean
local function is_empty(bufnr)
  -- prompts render once the agent reads them
  local state = sessions[bufnr] and sessions[bufnr].state
  -- or one that failed to load, which has no prompt
  if state == nil then return true end
  if state.working ~= nil or #state.queue > 0 then return false end
  return vim.api.nvim_buf_get_mark(bufnr, ':')[1] == 1 and vim.fn.prompt_getinput(bufnr) == ''
end

keymaps.plug()

local group = vim.api.nvim_create_augroup('otto', {})
local patterns = vim.tbl_map(function(name) return name .. '://*' end, vim.tbl_keys(providers.providers))
vim.api.nvim_create_autocmd('BufReadCmd', {
  group = group,
  pattern = patterns,
  callback = function(ev)
    local uri = vim.api.nvim_buf_get_name(ev.buf)
    local name = names[uri]
    names[uri] = nil
    session.load(ev.buf, name)
  end,
})
vim.api.nvim_create_autocmd('BufWinEnter', {
  group = group,
  pattern = patterns,
  callback = function(ev)
    local wo = vim.wo[0][0]
    wo.foldmethod = 'manual'
    if sessions[ev.buf] ~= nil then sessions[ev.buf].buffer:fold() end
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
    shown[ev.buf] = (shown[ev.buf] or 0) + 1
    -- once the window settles, so that the first output follows the prompt too
    local win = vim.api.nvim_get_current_win()
    vim.schedule(function()
      if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == ev.buf then prompt_area.watch(win) end
    end)
  end,
})
vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
  group = group,
  pattern = patterns,
  callback = function(ev)
    if sessions[ev.buf] ~= nil then highlight.prompt(ev.buf) end
  end,
})
vim.api.nvim_create_autocmd({ 'WinResized', 'WinScrolled' }, {
  group = group,
  callback = function()
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if sessions[vim.api.nvim_win_get_buf(win)] ~= nil then prompt_area.scrolled(win) end
    end
  end,
})
vim.api.nvim_create_autocmd('InsertEnter', {
  group = group,
  pattern = patterns,
  callback = function(ev)
    if sessions[ev.buf] == nil then return end
    -- insert mode opens the fold under the cursor before the prompt buffer moves the cursor to the prompt
    local prompt_lnum = vim.api.nvim_buf_get_mark(ev.buf, ':')[1]
    if vim.fn.line('.') >= prompt_lnum then return end
    vim.api.nvim_win_set_cursor(0, { prompt_lnum, 0 })
    vim.v.char = 'moved' -- keeps the cursor there, see :help InsertEnter
  end,
})
vim.api.nvim_create_autocmd('BufHidden', {
  group = group,
  pattern = patterns,
  callback = function(ev)
    local times = shown[ev.buf]
    vim.defer_fn(function()
      local hidden = vim.api.nvim_buf_is_loaded(ev.buf) and shown[ev.buf] == times
      if hidden and is_empty(ev.buf) then vim.api.nvim_buf_delete(ev.buf, { force = true }) end
    end, config.get({ bufnr = ev.buf }).cleanup_delay)
  end,
})
vim.api.nvim_create_autocmd('BufUnload', {
  group = group,
  pattern = patterns,
  callback = function(ev)
    if sessions[ev.buf] ~= nil then
      history.save_drafts({ ev.buf })
      sessions[ev.buf]:close()
      sessions[ev.buf] = nil
    end
    session.close_children(vim.api.nvim_buf_get_name(ev.buf))
  end,
})
vim.api.nvim_create_autocmd('VimLeavePre', {
  group = group,
  callback = function() history.save_drafts(vim.tbl_keys(sessions)) end,
})

--- @type table<string, fun(arg?: string, cmd: vim.api.keyset.create_user_command.command_args)>
local subcommands = {
  send = function(_, cmd) M.send(cmd.line1, cmd.line2) end,
  resume = function(id)
    if id == nil then return pick.sessions() end
    local saved = vim.iter(providers.list()):find(function(info) return info.id == id end)
    if saved == nil then return util.notify('no saved session ' .. id) end
    vim.cmd.edit(saved.provider .. '://' .. saved.id)
  end,
  pick = pick.sessions,
}
for name in pairs(providers.providers) do
  subcommands[name] = function(arg) M.new(arg, name) end
end

-- :Otto pi [name], :Otto claude [name], :Otto codex [name], :Otto resume [id], :Otto pick, which :Otto defaults to, and
-- :Otto send for the current line or a range. In a session, the commands of the palette too, like :Otto compact
vim.api.nvim_create_user_command('Otto', function(cmd)
  local subcommand = subcommands[cmd.fargs[1] or 'pick']
  local current = sessions[vim.api.nvim_get_current_buf()]
  if subcommand == nil and current ~= nil and commands.get(cmd.fargs[1]) then
    local keys = commands.run(current, cmd.fargs[1])
    if keys then vim.api.nvim_feedkeys(vim.keycode(keys), 'n', false) end
    return
  end
  if subcommand == nil then return util.notify('unknown subcommand: ' .. cmd.fargs[1]) end
  local arg = table.concat(cmd.fargs, ' ', 2)
  subcommand(arg ~= '' and arg or nil, cmd)
end, {
  nargs = '*',
  range = true,
  complete = function(lead, line)
    local words = vim.split(line, '%s+')
    if #words <= 2 then
      local subcommand_names = vim.tbl_keys(subcommands)
      local current = sessions[vim.api.nvim_get_current_buf()]
      for _, command in ipairs(current and commands.available(current) or {}) do
        if subcommands[command.name] == nil then table.insert(subcommand_names, command.name) end
      end
      table.sort(subcommand_names)
      return vim.tbl_filter(function(name) return vim.startswith(name, lead) end, subcommand_names)
    end
    if words[2] ~= 'resume' then return {} end
    local ids = vim.tbl_map(function(info) return info.id end, providers.list())
    return lead == '' and ids or vim.fn.matchfuzzy(ids, lead)
  end,
})

return M
