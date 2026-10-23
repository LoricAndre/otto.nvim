-- A session with an agent, without a buffer: the agent's handle, the log so far, and the state that the agent reports. Views
-- subscribe to show it, see `view.lua`, and render the log from the start when they attach

local config = require('otto.config')
local providers = require('otto.providers')
local uri = require('otto.uri')
local util = require('otto.util')

--- @class otto.State What the session runs with, and what the agent is doing, see `otto.StatePatch`
--- @field id string
--- @field name? string
--- @field model? string
--- @field effort? string
--- @field window? integer
--- @field context? integer Tokens in the context
--- @field cost? number Dollars
--- @field working? 'working' | 'thinking' | 'compacting'
--- @field since? integer When the agent started working, in milliseconds of the event loop
--- @field queue otto.Queued[] Prompts that the agent hasn't read yet
--- @field commands otto.Command[] The agent's own

--- @class otto.Listener What a view, or anything else, is told of a session
--- @field log? fun(event: otto.Event) Once it's in the log
--- @field state? fun(patch: otto.StatePatch) Once the state has it

--- @class otto.Session
--- @field uri string Like claude://<id>, which changes when the agent creates the id
--- @field provider otto.Provider
--- @field handle otto.Handle
--- @field state otto.State
--- @field events otto.Event[] The log so far, as the agent said it
--- @field running { id: string, tool: string, args: table }[] Tool calls of the turn without results yet, in order
--- @field listeners otto.Listener[]
--- @field requests vim.async.Semaphore Answered one at a time, since pickers can't show two at once
local Session = {}
Session.__index = Session

local M = {}

--- @type table<otto.Session, true> Open sessions
M.sessions = {}

--- @param name? string Uri
--- @return otto.Session?
function M.find(name)
  for session in pairs(M.sessions) do
    if session.uri == name then return session end
  end
end

--- @param listener otto.Listener
--- @return fun() unsubscribe
function Session:subscribe(listener)
  table.insert(self.listeners, listener)
  return function()
    self.listeners = vim.tbl_filter(function(other) return other ~= listener end, self.listeners)
  end
end

--- @param event otto.Event
function Session:on_log(event)
  table.insert(self.events, event)
  if event.type == 'tool_call' then
    table.insert(self.running, { id = event.id, tool = event.tool, args = event.args or {} })
  elseif event.type == 'tool_result' then
    self.running = vim.tbl_filter(function(call) return call.id ~= event.id end, self.running)
  elseif event.type == 'turn_end' then
    self.running = {}
  end
  for _, listener in ipairs(self.listeners) do
    if listener.log then listener.log(event) end
  end
end

--- Asks the user, one request at a time
--- @param request otto.Request
function Session:on_request(request)
  util.run(function()
    self.requests:with(function()
      -- cancelled when the picker fails, since the agent waits for an answer
      local ok, value = pcall(function()
        if request.kind == 'select' then return util.select(request.items, { prompt = request.prompt }) end
        if request.kind == 'input' then return util.input({ prompt = request.prompt, default = request.default }) end
        local choice = util.select({ 'Yes', 'No' }, { prompt = request.prompt })
        return choice and choice == 'Yes'
      end)
      if ok then return request.respond(value) end
      request.respond(nil)
      error(value, 0)
    end)
  end)
end

local keys = { 'id', 'name', 'model', 'effort', 'window', 'context', 'cost', 'queue' }

--- @param patch otto.StatePatch
function Session:on_state(patch)
  local state = self.state
  if patch.working ~= nil then
    if state.working == nil and patch.working then state.since = vim.uv.now() end
    state.working = patch.working or nil
  end
  for _, key in ipairs(keys) do
    if patch[key] ~= nil then state[key] = patch[key] end
  end
  -- like Codex, which creates the ids of its sessions
  if patch.id ~= nil then self.uri = uri.format(self.provider.name, patch.id) end
  for _, listener in ipairs(self.listeners) do
    if listener.state then listener.state(patch) end
  end
end

function Session:close()
  M.sessions[self] = nil
  self.listeners = {}
  self.handle:close()
end

--- @class otto.SessionOpts
--- @field name? string Display name of a new session
--- @field config? otto.ProviderConfig The global one by default

--- Starts the agent for the session, and adds its history to the log
--- @param name string Uri, like claude://<id>
--- @param opts? otto.SessionOpts
--- @return otto.Session
function M.open(name, opts)
  opts = opts or {}
  local provider_name, id = uri.parse(name)
  local provider = providers.get(provider_name or '')
  if provider == nil then error('unknown agent: ' .. name, 0) end

  local session = setmetatable({
    uri = name,
    provider = provider,
    state = { id = id, queue = {}, commands = {} },
    events = {},
    running = {},
    listeners = {},
    requests = vim.async.semaphore(1),
  }, Session)
  session.handle = provider.open(id, {
    name = opts.name,
    config = opts.config or config.get().providers[provider.name],
    on_log = function(event) session:on_log(event) end,
    on_state = function(patch) session:on_state(patch) end,
    on_request = function(request) session:on_request(request) end,
  })
  M.sessions[session] = true
  util.run(function()
    session.handle:replay()
    -- after the history, since Claude Code only lists its commands once it starts
    session.state.commands = session.handle:commands()
  end)
  return session
end

return M
