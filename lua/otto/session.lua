-- A session's buffer, which wires its agent to its state, the transcript and the views. Buffers are named after their
-- agent and session, like claude://<id>

local buffer = require('otto.render.buffer')
local config = require('otto.config')
local history = require('otto.ui.history')
local keymaps = require('otto.ui.keymaps')
local layout = require('otto.render.layout')
local lsp = require('otto.ui.lsp')
local prompt_area = require('otto.ui.prompt_area')
local providers = require('otto.providers')
local util = require('otto.util')

--- @class otto.State What the session runs with, and what the agent is doing, from the status
--- @field id string
--- @field name? string
--- @field model? string
--- @field effort? string
--- @field window? integer
--- @field context? integer Tokens in the context
--- @field cost? number Dollars
--- @field working? 'working' | 'thinking' | 'compacting'
--- @field since? integer When the agent started working, in milliseconds of the event loop
--- @field queue { text: string, follow_up: boolean }[] Prompts that the agent hasn't read yet
--- @field background otto.Background[] What the agent runs beside the conversation
--- @field parent? string Buffer name of the session that started this one, of subagents
--- @field commands otto.Command[] The agent's own

--- @class otto.Session
--- @field bufnr integer
--- @field provider otto.Provider
--- @field handle otto.Handle
--- @field state otto.State
--- @field layout otto.Layout
--- @field buffer otto.Buffer
--- @field area otto.PromptArea
--- @field naming? boolean Whether a name is on its way, from the user or `name_after`
--- @field named? boolean Whether the user named the session, which `name_after` doesn't override
--- @field follow_up? boolean Whether the prompt being submitted waits for the agent to finish, instead of steering
--- @field now? boolean Whether the prompt being submitted interrupts the agent, which then goes on with it
--- @field recall? otto.Recall Where the prompt is in the history
--- @field requests vim.async.Semaphore Answered one at a time, since pickers can't show two at once
local Session = {}
Session.__index = Session

local M = {}

--- @type table<integer, otto.Session> by buffer
M.sessions = {}

--- @param uri? string Buffer name
--- @return otto.Session? open with that name exactly, unlike `bufnr()`, which takes a parent's for its subagent's
function M.find(uri)
  for bufnr, session in pairs(M.sessions) do
    if vim.api.nvim_buf_get_name(bufnr) == uri then return session end
  end
end

--- @param uri? string
--- @return string? name of the open session
local function name_of(uri)
  local other = M.find(uri)
  return other and other.state.name
end

--- @param event otto.Event
function Session:on_log(event)
  -- by the names they have here, which subagents don't know of the sessions that started them
  if event.type == 'message' then event.from = name_of(event.uri) or event.from end
  if event.type == 'tool_call' and event.tool == 'message' and event.args.to == 'parent' then
    event.args.to = name_of(self.state.parent) or event.args.to
  end
  for _, op in ipairs(self.layout:add(event)) do
    self.buffer:apply(op)
  end
  -- which shows below the transcript until its result renders
  if event.type == 'tool_call' then self.area:draw() end
end

--- @param status otto.Status
function Session:answer(status)
  util.run(function()
    self.requests:with(function()
      -- cancelled when the picker fails, since the agent waits for an answer
      local ok, value = pcall(function()
        if status.kind == 'select' then return util.select(status.items, { prompt = status.prompt }) end
        if status.kind == 'input' then return util.input({ prompt = status.prompt, default = status.default }) end
        local choice = util.select({ 'Yes', 'No' }, { prompt = status.prompt })
        return choice and choice == 'Yes'
      end)
      if ok then return status.respond(value) end
      status.respond(nil)
      error(value, 0)
    end)
  end)
end

--- @param status otto.Status
function Session:on_status(status)
  local state = self.state
  if status.type == 'working' then
    if state.working == nil and status.state ~= nil then state.since = vim.uv.now() end
    -- reloads the files that the agent edited
    if state.working ~= nil and status.state == nil then vim.cmd.checktime() end
    state.working = status.state
    self.area:update()
  elseif status.type == 'queue' then
    state.queue = {}
    for _, text in ipairs(status.steering or {}) do
      table.insert(state.queue, { text = text, follow_up = false })
    end
    for _, text in ipairs(status.follow_up or {}) do
      table.insert(state.queue, { text = text, follow_up = true })
    end
    self.area:draw()
  elseif status.type == 'background' then
    state.background = status.background
    self.area:update()
    vim.cmd.redrawstatus({ bang = true })
  elseif status.type == 'info' then
    for _, key in ipairs({ 'id', 'name', 'model', 'effort', 'window', 'context', 'cost', 'parent' }) do
      if status[key] ~= nil then state[key] = status[key] end
    end
    -- reached from their parent, with <C-o> back
    if status.parent ~= nil then vim.bo[self.bufnr].buflisted = false end
    -- like Codex, which creates the ids of its sessions
    if status.id ~= nil and vim.api.nvim_buf_get_name(self.bufnr) ~= self.provider.name .. '://' .. status.id then
      util.rename_buffer(self.bufnr, self.provider.name .. '://' .. status.id)
    end
    vim.cmd.redrawstatus({ bang = true })
  elseif status.type == 'request' then
    self:answer(status)
  end
end

--- Names the session after its first prompt, like "fix_winbar_highlights", with a quick one-shot prompt
--- @async
--- @param text string
function Session:name_after(text)
  local message = 'Name a coding session that starts with this prompt, in 2 to 4 words of snake_case. '
    .. 'Reply with only the name.\n\n'
    .. text
  -- quietly, since it's only a nicety, and the agent that answers may not be installed
  local opts = { bufnr = self.bufnr, tools = false, skills = false, thinking = 'off' }
  local ok, name = pcall(providers.ask, message, opts)
  if not ok then return end
  name = vim.trim(name):lower():gsub('[^%w]+', '_'):gsub('^_+', ''):gsub('_+$', '')
  -- unless the user named it while it was asked, or the session restarted
  if name ~= '' and self.state.name == nil and not self.named and M.sessions[self.bufnr] == self then
    self.handle:rename(name)
  end
end

--- @param text string
function Session:submit(text)
  local follow_up, now = self.follow_up, self.now
  self.follow_up, self.now = nil, nil
  history.add(text, self.provider.name .. '://' .. self.state.id)
  history.reset(self)
  self.buffer:submitted(text)
  local message = vim.trim(text)
  if message == '' then return end
  -- after a prompt rather than one of the agent's commands, like Claude Code's /rename
  if self.state.name == nil and not self.naming and not vim.startswith(message, '/') then
    self.naming = true
    util.run(function() self:name_after(message) end)
  end
  -- before sending, which makes it work
  local working = self.state.working ~= nil
  self.handle:prompt(message, follow_up and 'follow_up' or 'steer')
  if now and working then self.handle:abort() end
end

function Session:close()
  self.handle:close()
  self.area:close()
end

--- Starts the agent for the session that names the buffer, and renders its history
--- @param bufnr integer
--- @param name? string Display name of a new session, which keeps it from being named after its first prompt
function M.load(bufnr, name)
  local provider_name, id = vim.api.nvim_buf_get_name(bufnr):match('^(%a+)://(.+)')
  local provider = providers.get(provider_name)
  if provider == nil then return util.notify('unknown agent: ' .. vim.api.nvim_buf_get_name(bufnr)) end

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

  local session = setmetatable(
    { bufnr = bufnr, provider = provider, naming = name ~= nil, requests = vim.async.semaphore(1) },
    Session
  )
  session.state = { id = id, queue = {}, commands = {}, background = {} }
  session.layout = layout.new()
  session.area = prompt_area.new(bufnr, session.state, session.layout)
  session.buffer = buffer.new(bufnr, function() session.area:draw() end)
  -- over the area of the session before a restart
  session.area:draw()
  history.restore_draft(bufnr)
  session.handle = provider.open(id, {
    name = name,
    config = config.get({ bufnr = bufnr }).providers[provider.name],
    on_log = function(event) session:on_log(event) end,
    on_status = function(status) session:on_status(status) end,
  })
  M.sessions[bufnr] = session
  if session.handle.read_only then vim.bo[bufnr].modifiable = false end

  vim.fn.prompt_setcallback(bufnr, function(text) session:submit(text) end)
  keymaps.attach(session)
  lsp.attach(session)

  util.run(function()
    session.handle:replay()
    -- after the history, since Claude Code only lists its commands once it starts
    session.state.commands = session.handle:commands()
  end)
end

--- Deletes the buffers of the subagents' sessions, which are reached from their parent's
--- @param parent string Buffer name
function M.close_children(parent)
  for bufnr, child in pairs(M.sessions) do
    if child.state.parent == parent then
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(bufnr) then vim.api.nvim_buf_delete(bufnr, { force = true }) end
      end)
    end
  end
end

--- Restarts the agent for the session's buffer, and renders the session again
--- @param bufnr integer
--- @param id? string Session to switch the buffer to
function M.restart(bufnr, id)
  local session = M.sessions[bufnr]
  session:close()
  if id ~= nil then M.close_children(vim.api.nvim_buf_get_name(bufnr)) end
  -- which is closed, even if the agent fails to start again
  M.sessions[bufnr] = nil
  if id ~= nil then util.rename_buffer(bufnr, session.provider.name .. '://' .. id) end
  M.load(bufnr)
end

return M
