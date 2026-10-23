-- A session's buffer, which shows its transcript and state, and sends what's submitted to its agent. Buffers are named
-- after their session, like claude://<id>, and sessions don't know of them, see `session.lua`

local buffer = require('otto.render.buffer')
local config = require('otto.config')
local history = require('otto.ui.history')
local keymaps = require('otto.ui.keymaps')
local layout = require('otto.render.layout')
local lsp = require('otto.ui.lsp')
local prompt_area = require('otto.ui.prompt_area')
local providers = require('otto.providers')
local sessions = require('otto.session')
local uri = require('otto.uri')
local util = require('otto.util')

--- @class otto.View
--- @field bufnr integer
--- @field session otto.Session
--- @field layout otto.Layout
--- @field buffer otto.Buffer
--- @field area otto.PromptArea
--- @field unsubscribe fun()
--- @field follow_up? boolean Whether the prompt being submitted waits for the agent to finish, instead of steering
--- @field recall? otto.Recall Where the prompt is in the history
local View = {}
View.__index = View

local M = {}

--- @type table<integer, otto.View> by buffer
M.views = {}

--- @param event otto.Event
function View:on_log(event)
  for _, op in ipairs(self.layout:add(event)) do
    self.buffer:apply(op)
  end
  -- which shows below the transcript until its result renders
  if event.type == 'tool_call' then self.area:draw() end
end

--- Shows what the session runs with
function View:sync()
  local session = self.session
  -- like Codex, which creates the ids of its sessions
  if vim.api.nvim_buf_get_name(self.bufnr) ~= session.uri then util.rename_buffer(self.bufnr, session.uri) end
  vim.cmd.redrawstatus({ bang = true })
end

--- @param patch otto.StatePatch
function View:on_state(patch)
  -- reloads the files that the agent edited
  if patch.working == false then vim.cmd.checktime() end
  if patch.working ~= nil or patch.queue then self.area:update() end
  self:sync()
end

--- @param text string
function View:submit(text)
  local session = self.session
  local follow_up = self.follow_up
  self.follow_up = nil
  history.add(text, session.uri)
  history.reset(self)
  self.buffer:submitted(text)
  local message = vim.trim(text)
  if message == '' then return end
  session.handle:prompt(message, follow_up and 'follow_up' or 'steer')
end

--- Closes the view and its session, which nothing else shows yet
function View:close()
  self.unsubscribe()
  self.area:close()
  self.session:close()
end

--- Shows the session that names the buffer, starting its agent unless it runs already
--- @param bufnr integer
--- @param name? string Display name of a new session
function M.load(bufnr, name)
  local session_uri = vim.api.nvim_buf_get_name(bufnr)
  local provider = providers.get(uri.parse(session_uri) or '')
  if provider == nil then return util.notify('unknown agent: ' .. session_uri) end

  -- before anything changes the buffer, which would start the window's folding, like treesitter's, which then parses
  -- the whole transcript after every change
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    vim.wo[win][0].foldmethod = 'manual'
  end
  vim.bo[bufnr].buftype = 'prompt'
  vim.bo[bufnr].bufhidden = 'hide'
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = 'otto'
  vim.b[bufnr].completion = true -- blink.cmp skips prompt buffers otherwise
  vim.fn.prompt_setprompt(bufnr, '')
  -- which may have been started for the filetype
  vim.treesitter.stop(bufnr)

  local view = setmetatable({ bufnr = bufnr }, View)
  view.layout = layout.new()
  view.buffer = buffer.new(bufnr, function() view.area:draw() end)
  view.session = sessions.find(session_uri)
    or sessions.open(session_uri, { name = name, config = config.get({ bufnr = bufnr }).providers[provider.name] })
  view.area = prompt_area.new(bufnr, view.session, view.layout)
  -- over the area of the session before a restart
  view.area:draw()
  history.restore_draft(bufnr)
  M.views[bufnr] = view

  -- what the session logged before the buffer showed it, like its history
  for _, event in ipairs(view.session.events) do
    view:on_log(event)
  end
  view.unsubscribe = view.session:subscribe({
    log = function(event) view:on_log(event) end,
    state = function(patch) view:on_state(patch) end,
  })
  view:sync()
  view.area:update()

  vim.fn.prompt_setcallback(bufnr, function(text) view:submit(text) end)
  keymaps.attach(view)
  lsp.attach(view)
end

--- Restarts the agent for the session's buffer, and renders the session again
--- @param bufnr integer
--- @param id? string Session to switch the buffer to
function M.restart(bufnr, id)
  local view = M.views[bufnr]
  view:close()
  -- which is closed, even if the agent fails to start again
  M.views[bufnr] = nil
  if id ~= nil then util.rename_buffer(bufnr, uri.format(view.session.provider.name, id)) end
  M.load(bufnr)
end

return M
