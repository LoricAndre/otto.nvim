-- Codex's process: `codex app-server`, JSON-RPC over stdio, which has the history too, see `decode.lua` for its items

local decode = require('otto.providers.codex.decode')
local event = require('otto.event')
local log = require('otto.providers.log')
local rpc = require('otto.rpc')
local util = require('otto.util')

local M = {}

--- @param id string
--- @return boolean whether it's the id of a thread, which Codex creates, rather than the name of a new session
local function is_thread(id) return id:match('^%x+%-%x+%-%x+%-%x+%-%x+$') ~= nil end

--- @class otto.CodexAgent : otto.Agent
--- @field rpc otto.Rpc
--- @field log otto.Log
--- @field on_state fun(patch: otto.StatePatch)
--- @field on_request fun(request: otto.Request)
--- @field thread? string id, once Codex started or resumed it
--- @field waiting fun()[] Requests that wait for the thread
--- @field thread_error? string When the thread failed to start
--- @field turn? string id of the turn that's running
--- @field turn_started? integer When the turn started
--- @field working boolean From sending a prompt until its turn completes
--- @field model? string
--- @field effort? string like "medium", which turns take, since Codex sets both per turn
--- @field models table[] Of `model/list`
--- @field announced table<string, true> Tool calls that started, in the log before their items complete
--- @field unread { text: string, id: string }[] Prompts that Codex hasn't read yet
--- @field follow_ups string[] Prompts that wait for the turn to complete
--- @field new_thread? boolean Whether the thread started with the agent, without history
--- @field decoder otto.CodexDecoder
local Agent = {}
Agent.__index = Agent

--- @param method string
--- @param params table
--- @param callback? fun(err?: string, data?: table) Notifies errors by default
function Agent:request(method, params, callback)
  self.rpc:request(function(id) return { method = method, id = id, params = params } end, callback)
end

--- Waits until the thread started
--- @async
function Agent:await_thread()
  if self.thread == nil and self.thread_error == nil then
    vim.async.await(1, function(done) table.insert(self.waiting, done) end)
  end
  if self.thread == nil then error(self.thread_error, 0) end
end

--- Invokes the method once the thread started
--- @async
--- @param method string
--- @param params fun(): table
--- @return table?
function Agent:call(method, params)
  self:await_thread()
  local framed = params()
  return self.rpc:call(function(id) return { method = method, id = id, params = framed } end)
end

function Agent:report_queue()
  local texts = vim.tbl_map(function(unread) return unread.text end, self.unread)
  self.on_state({ queue = event.queue(texts, self.follow_ups) })
end

--- @param working boolean
function Agent:set_working(working)
  self.working = working
  self.on_state({ status = working and 'working' })
end

--- @param text string
--- @return table input of a turn
local function input(text) return { { type = 'text', text = text, text_elements = {} } } end

--- @param text string
--- @param on_error? fun(err: string)
function Agent:start_turn(text, on_error)
  on_error = on_error or util.notify
  -- of a thread that failed to start, which nothing would read
  if self.thread_error ~= nil then return on_error(self.thread_error) end
  local id = util.uuid()
  table.insert(self.unread, { text = text, id = id })
  self:report_queue()
  if not self.working then self:set_working(true) end
  -- prompts can come before the thread starts
  util.run_task(function()
    self:await_thread()
    local params = {
      threadId = self.thread,
      input = input(text),
      clientUserMessageId = id,
      model = self.model,
      effort = self.effort,
    }
    self:request('turn/start', params, function(err)
      if err == nil then return end
      on_error(err)
      self:echoed({ clientId = id })
      if self.turn ~= nil then return end
      -- like the follow-ups that waited for it
      if #self.follow_ups > 0 then return self:start_turn(table.remove(self.follow_ups, 1)) end
      self:report_queue()
      self:set_working(false)
    end)
  end)
end

--- Codex echoes prompts once it reads them
--- @param item table userMessage
function Agent:echoed(item)
  local index = vim.iter(ipairs(self.unread)):find(function(_, unread) return unread.id == item.clientId end)
  if index == nil then return end
  table.remove(self.unread, index)
  self:report_queue()
end

--- Codex asks before running commands or changing files that its reviewer doesn't allow
--- @param msg table
function Agent:on_approval(msg)
  local params = msg.params or {}
  local what = msg.method == 'item/fileChange/requestApproval' and 'change files'
    or 'run ' .. (params.command or 'a command')
  local prompt = ('Codex wants to %s%s: '):format(what, params.reason and ' (' .. params.reason .. ')' or '')
  local decisions = { Allow = 'accept', ['Always allow'] = 'acceptForSession', Deny = 'decline' }
  self.on_request({
    kind = 'select',
    prompt = prompt,
    items = { 'Allow', 'Always allow', 'Deny' },
    respond = function(choice) self.rpc:send({ id = msg.id, result = { decision = decisions[choice] or 'decline' } }) end,
  })
end

--- @param msg table
function Agent:on_message(msg)
  if msg.method == nil then
    return self.rpc:resolve(msg.id, msg.error and (msg.error.message or vim.inspect(msg.error)), msg.result)
  end
  local params = msg.params or {}
  if msg.id ~= nil then
    if not vim.endswith(msg.method, '/requestApproval') or msg.method == 'item/permissions/requestApproval' then
      return self.rpc:send({
        id = msg.id,
        error = { code = -32601, message = msg.method .. ' is not supported by otto' },
      })
    end
    return self:on_approval(msg)
  end

  local item = params.item
  if msg.method == 'turn/started' then
    self.turn = params.turn.id
    self.turn_started = decode.times(params.turn)
    -- like compactions, which are turns of their own
    if not self.working then self:set_working(true) end
  elseif msg.method == 'item/started' and item.type == 'contextCompaction' then
    self.on_state({ status = 'compacting' })
  elseif msg.method == 'item/started' and (item.type == 'commandExecution' or item.type == 'mcpToolCall') then
    for _, call in ipairs(decode.calls(item)) do
      self.announced[call.id] = true
      self.log:tool_call(call.id, call.tool, call.args, self.turn_started)
    end
  -- not of earlier turns, like commands that ran in the background, which the log can't add to
  elseif msg.method == 'item/completed' and params.turnId == self.turn then
    if item.type == 'userMessage' then self:echoed(item) end
    decode.add(self.log, self.decoder, item, self.announced, self.turn_started)
    if item.type == 'contextCompaction' then self.on_state({ status = 'working' }) end
  elseif msg.method == 'error' and not params.willRetry then
    self.log:error(params.error.message, self.turn_started)
  elseif msg.method == 'thread/tokenUsage/updated' then
    self.on_state({
      context_tokens = params.tokenUsage.last.totalTokens,
      context_window = params.tokenUsage.modelContextWindow,
    })
  elseif msg.method == 'thread/name/updated' then
    self.on_state({ name = params.threadName })
  elseif msg.method == 'turn/completed' then
    self.turn = nil
    -- whatever it didn't read is gone with the turn
    self.unread = {}
    self.log:end_turn(params.turn.status == 'interrupted', select(2, decode.times(params.turn)))
    -- after interrupts too
    if #self.follow_ups > 0 then return self:start_turn(table.remove(self.follow_ups, 1)) end
    self:report_queue()
    self:set_working(false)
  end
end

--- The history, from the app-server
--- @async
function Agent:replay()
  self:await_thread()
  -- Codex only lists the turns of threads with messages
  if self.new_thread then return end
  local turns = {}
  local cursor
  repeat
    local page = self:call(
      'thread/turns/list',
      function() return { threadId = self.thread, itemsView = 'full', sortDirection = 'asc', cursor = cursor } end
    )
    vim.list_extend(turns, page.data)
    cursor = page.nextCursor
  until cursor == nil
  for _, turn in ipairs(turns) do
    local started, completed = decode.times(turn)
    for _, item in ipairs(turn.items) do
      decode.add(self.log, self.decoder, item, {}, started)
    end
    if turn.error ~= nil then self.log:error(turn.error.message, started) end
    self.log:end_turn(turn.status == 'interrupted', completed)
  end
  self.log:end_turn()
end

--- @param text string
--- @param mode 'steer' | 'follow_up' While a turn runs
--- @param on_error? fun(err: string)
function Agent:prompt(text, mode, on_error)
  if not self.working then return self:start_turn(text, on_error) end
  -- until the turn starts, which there's nothing to steer before
  if mode == 'follow_up' or self.turn == nil then
    table.insert(self.follow_ups, text)
    return self:report_queue()
  end
  local id = util.uuid()
  local turn = self.turn
  table.insert(self.unread, { text = text, id = id })
  self:report_queue()
  local params = { threadId = self.thread, input = input(text), clientUserMessageId = id, expectedTurnId = turn }
  self:request('turn/steer', params, function(err)
    if err == nil then return end
    self:echoed({ clientId = id })
    -- like a turn that can't be steered, such as a compaction, or one that completed before Codex got the prompt, which
    -- then goes after it
    if self.turn ~= nil then
      table.insert(self.follow_ups, text)
      return self:report_queue()
    end
    self:start_turn(text)
  end)
end

function Agent:abort()
  if self.turn == nil then return end
  -- prompts that Codex hasn't read, which it drops with the turn, go on after it
  for i = #self.unread, 1, -1 do
    table.insert(self.follow_ups, 1, self.unread[i].text)
  end
  self.unread = {}
  self:report_queue()
  self:request('turn/interrupt', { threadId = self.thread, turnId = self.turn })
end

--- Prompts that steer are with Codex already, and only come back all at once, like before an abort, which drops them
--- @async
--- @return string[]
--- @param newest_only? boolean
function Agent:take_queue(newest_only)
  if newest_only then
    local texts = { table.remove(self.follow_ups) }
    self:report_queue()
    return texts
  end
  local texts = vim.tbl_map(function(unread) return unread.text end, self.unread)
  vim.list_extend(texts, self.follow_ups)
  self.unread, self.follow_ups = {}, {}
  self:report_queue()
  return texts
end

--- @async
function Agent:compact()
  self:call('thread/compact/start', function() return { threadId = self.thread } end)
end

--- @async
--- @return string[]
function Agent:models()
  return vim.tbl_map(function(model) return model.id end, self.models)
end

--- @async
--- @param model string
function Agent:set_model(model)
  self.model = model
  self.on_state({ model = model })
end

--- @async
function Agent:cycle_effort()
  local model = vim.iter(self.models):find(function(option) return option.id == self.model end)
  local options = model and model.supportedReasoningEfforts or {}
  local levels = vim.tbl_map(function(option) return option.reasoningEffort end, options)
  if #levels == 0 then levels = { 'low', 'medium', 'high' } end
  self.effort = levels[(vim.fn.index(levels, self.effort) + 1) % #levels + 1]
  self.on_state({ effort = self.effort })
end

--- @async
--- @param name string
function Agent:rename(name)
  self:call('thread/name/set', function() return { threadId = self.thread, name = name } end)
end

--- @async
--- @return otto.AgentCommand[]
function Agent:commands() return {} end

function Agent:close() self.rpc:close() end

--- Releases what waits for the thread
--- @param err? string When it failed to start
--- @param result? table Of `thread/start` or `thread/resume`
function Agent:on_thread_started(err, result)
  if err ~= nil then
    -- which raises in what waits for the thread, like the replay that every session starts with
    self.thread_error = err
    self.unread, self.follow_ups = {}, {}
    self:report_queue()
    self:set_working(false)
  elseif result ~= nil then
    self:set_thread(result)
  end
  for _, waiting in ipairs(self.waiting) do
    waiting()
  end
  self.waiting = {}
end

--- @param result table Of `thread/start` or `thread/resume`
function Agent:set_thread(result)
  self.thread = result.thread.id
  self.model = result.model
  self.effort = result.reasoningEffort
  self.on_state({
    id = self.thread,
    name = result.thread.name,
    model = self.model,
    effort = self.effort,
  })
end

--- Starts Codex for the session. Codex creates the ids of threads, so a new session starts with its name or when it
--- started, until its thread starts
--- @param id string Of the thread, or of the new session
--- @param opts otto.AgentOpts
--- @return otto.CodexAgent
function M.open(id, opts)
  --- @type otto.CodexAgent
  local agent = setmetatable({
    log = log.new(opts.on_log, opts.on_state),
    on_state = opts.on_state,
    on_request = opts.on_request,
    waiting = {},
    working = false,
    models = {},
    announced = {},
    decoder = decode.new(),
    unread = {},
    follow_ups = {},
  }, Agent)
  agent.rpc = rpc.start_agent(opts.config, { 'app-server' }, {
    name = 'codex',
    on_message = function(msg) agent:on_message(msg) end,
    on_exit = function()
      agent.log:end_turn(true)
      agent:set_working(false)
    end,
  })

  local info = { name = 'otto', title = 'Otto', version = '0' }
  agent:request('initialize', { clientInfo = info }, function(err)
    if err ~= nil then return agent:on_thread_started(err) end
    agent.rpc:send({ method = 'initialized' })
    agent:request('model/list', {}, function(_, data) agent.models = data and data.data or {} end)
    if is_thread(id) then
      return agent:request(
        'thread/resume',
        { threadId = id, excludeTurns = true },
        function(resume_err, result) agent:on_thread_started(resume_err, result) end
      )
    end
    agent:request('thread/start', { cwd = vim.fn.getcwd() }, function(start_err, result)
      agent.new_thread = start_err == nil
      agent:on_thread_started(start_err, result)
      if start_err ~= nil then return end
      if opts.name ~= nil then agent:request('thread/name/set', { threadId = agent.thread, name = opts.name }) end
    end)
  end)
  return agent
end

return M
