-- Codex as a session backend: `codex app-server`, JSON-RPC over stdio, which this client translates to the requests and
-- events of pi's RPC mode, like `claude.lua`. Turns are made of items, which become pi's messages once they complete

local rpc = require('otto.rpc')

local M = {}

--- @param id string
--- @return boolean whether it's the id of a thread, which Codex creates, rather than the name of a new session
function M.is_thread(id) return id:match('^%x+%-%x+%-%x+%-%x+%-%x+$') ~= nil end

--- @param item table commandExecution
--- @return string like "cat a.txt", without the `bash -lc` that Codex runs it with
local function command(item)
  local quoted = item.command:match('^%S+ %-lc (.+)$')
  if quoted == nil then return item.command end
  return quoted:match("^'(.*)'$") or quoted:match('^"(.*)"$') or quoted
end

--- Commands that only read, list or search become pi's tools for those, like Codex's own UI shows them
--- @param item table commandExecution
--- @return string name
--- @return table args
local function shell_tool(item)
  local actions = item.commandActions or {}
  local action = #actions == 1 and actions[1] or {}
  -- like `sed -n '10,20p' file`
  local offset = tonumber(action.command and action.command:match("^sed %-n '?(%d+),") or nil)
  if action.type == 'read' then return 'read', { path = action.path, offset = offset } end
  if action.type == 'listFiles' then return 'ls', { path = action.path or '.' } end
  if action.type == 'search' then return 'grep', { pattern = action.query or action.command, path = action.path } end
  return 'bash', { command = command(item) }
end

--- A change's unified diff as a diff like pi's, with a line number after the sign
--- @param change { diff: string, kind: { type: string } }
--- @return string
local function diff(change)
  local lines = {}
  local old = 1
  local new = 1
  for _, line in ipairs(vim.split(change.diff:gsub('\n$', ''), '\n')) do
    local old_start, new_start = line:match('^@@ %-(%d+),?%d* %+(%d+),?%d* @@')
    if old_start ~= nil then
      old = tonumber(old_start)
      new = tonumber(new_start)
    elseif change.kind.type == 'delete' then
      table.insert(lines, ('-%d %s'):format(old, line))
      old = old + 1
    elseif not vim.startswith(line, '\\') then -- like "\ No newline at end of file"
      local sign = line:sub(1, 1)
      table.insert(lines, ('%s%d %s'):format(sign, sign == '-' and old or new, line:sub(2)))
      if sign ~= '+' then old = old + 1 end
      if sign ~= '-' then new = new + 1 end
    end
  end
  return table.concat(lines, '\n')
end

--- @param content table[] UserInput or MCP content
--- @return string
local function text_of(content)
  local texts = vim.tbl_filter(function(part) return part.type == 'text' end, content or {})
  return vim.iter(texts):map(function(part) return part.text end):join('\n')
end

--- pi's tool calls for an item, of which file changes have one per file
--- @param item table
--- @return table[] toolCall
local function calls(item)
  local function call(id, name, args) return { type = 'toolCall', id = id, name = name, arguments = args } end
  if item.type == 'commandExecution' then return { call(item.id, shell_tool(item)) } end
  if item.type == 'webSearch' then return { call(item.id, 'web_search', { query = item.query }) } end
  if item.type == 'mcpToolCall' then return { call(item.id, item.tool, item.arguments) } end
  if item.type ~= 'fileChange' then return {} end
  return vim
    .iter(ipairs(item.changes))
    :map(function(i, change)
      local id = item.id .. ':' .. i
      if change.kind.type == 'add' then return call(id, 'write', { path = change.path, content = change.diff }) end
      return call(id, 'edit', { path = change.path })
    end)
    :totable()
end

--- @param item table
--- @return table[] ToolResultMessage
local function results(item)
  local function result(id, content, failed, details)
    return { role = 'toolResult', toolCallId = id, content = content, isError = failed, details = details }
  end
  if item.type == 'commandExecution' then
    local failed = item.status ~= 'completed' or (item.exitCode or 0) ~= 0
    return { result(item.id, item.aggregatedOutput or '', failed, { exitCode = item.exitCode }) }
  end
  if item.type == 'webSearch' then return { result(item.id, '', false) } end
  if item.type == 'mcpToolCall' then
    local content = item.error and item.error.message or text_of(item.result and item.result.content)
    return { result(item.id, content, item.error ~= nil) }
  end
  if item.type ~= 'fileChange' then return {} end
  local failed = item.status ~= 'completed'
  return vim
    .iter(ipairs(item.changes))
    :map(function(i, change)
      local details = not failed and change.kind.type ~= 'add' and { diff = diff(change) } or nil
      return result(item.id .. ':' .. i, '', failed, details)
    end)
    :totable()
end

--- Messages of pi for a completed item
--- @param item table
--- @param announced table<string, true> Tool calls that started already
--- @param tokens_before? integer In the context, for compactions
--- @return table[] AgentMessage
local function messages(item, announced, tokens_before)
  if item.type == 'userMessage' then return { { role = 'user', content = text_of(item.content) } } end
  if item.type == 'agentMessage' then
    return { { role = 'assistant', content = { { type = 'text', text = item.text } } } }
  end
  -- Codex keeps the summary to itself
  if item.type == 'contextCompaction' then return { { role = 'compactionSummary', tokensBefore = tokens_before } } end
  local unannounced = vim.tbl_filter(function(call) return not announced[call.id] end, calls(item))
  local all = #unannounced > 0 and { { role = 'assistant', content = unannounced } } or {}
  return vim.list_extend(all, results(item))
end

--- @class otto.CodexClient
--- @field proc vim.SystemObj
--- @field closed boolean
--- @field seq integer
--- @field pending table<integer, fun(err?: string, data?: table)> Responses by request id
--- @field on_event fun(event: table)
--- @field thread? string id, once Codex started or resumed it
--- @field waiting fun()[] Requests that wait for the thread
--- @field turn? string id of the turn that's running
--- @field working boolean From sending a prompt until its turn completes
--- @field model? string
--- @field effort? string like "medium", which turns take, since Codex sets both per turn
--- @field models table[] Of `model/list`
--- @field name? string
--- @field tokens? integer In the context, as of the last request to the model
--- @field window? integer Size of the context window
--- @field announced table<string, true> Tool calls that started, which render once they complete
--- @field shown? string Client id of the prompt that rendered when it was sent, before Codex echoed it
--- @field steering { text: string, id: string }[] Prompts that Codex hasn't read yet
--- @field follow_ups string[] Prompts that wait for the turn to complete
--- @field created? boolean Whether the thread started with the client, without history
local Client = {}
Client.__index = Client

--- @param msg table
function Client:send(msg)
  if self.proc:is_closing() then return rpc.notify('codex is not running') end
  self.proc:write(vim.json.encode(msg) .. '\n')
end

--- @param method string
--- @param params table
--- @param callback? fun(err?: string, data?: table) Notifies errors by default
function Client:invoke(method, params, callback)
  self.seq = self.seq + 1
  self.pending[self.seq] = callback or function(err)
    if err ~= nil then rpc.notify(err) end
  end
  self:send({ method = method, id = self.seq, params = params })
end

function Client:queue_update()
  local texts = vim.tbl_map(function(queued) return queued.text end, self.steering)
  self.on_event({ type = 'queue_update', steering = texts, followUp = self.follow_ups })
end

--- @param text string
function Client:start_turn(text)
  local working = self.working
  self.working = true
  self.shown = require('otto.claude').uuid()
  self:invoke('turn/start', {
    threadId = self.thread,
    input = { { type = 'text', text = text, text_elements = {} } },
    clientUserMessageId = self.shown,
    model = self.model,
    effort = self.effort,
  })
  -- follow-ups continue the work
  if not working then self.on_event({ type = 'agent_start' }) end
  -- Codex starts on it straight away, but takes a moment to echo it
  self.on_event({ type = 'message_end', message = { role = 'user', content = text } })
end

--- @param text string
--- @param behavior? 'steer' | 'followUp' While a turn runs
function Client:prompt(text, behavior)
  if not self.working then return self:start_turn(text) end
  if behavior == 'followUp' then
    table.insert(self.follow_ups, text)
    return self:queue_update()
  end
  local id = require('otto.claude').uuid()
  table.insert(self.steering, { text = text, id = id })
  self:queue_update()
  local input = { { type = 'text', text = text, text_elements = {} } }
  self:invoke(
    'turn/steer',
    { threadId = self.thread, input = input, clientUserMessageId = id, expectedTurnId = self.turn }
  )
end

--- Codex echoes prompts once it reads them
--- @param item table userMessage
--- @return boolean whether the prompt rendered already
function Client:read(item)
  if item.clientId ~= nil and item.clientId == self.shown then
    self.shown = nil
    return true
  end
  local index = vim.iter(ipairs(self.steering)):find(function(_, queued) return queued.id == item.clientId end)
  if index ~= nil then
    table.remove(self.steering, index)
    self:queue_update()
  end
  return false
end

--- Codex asks before running commands or changing files that its reviewer doesn't allow
--- @async
--- @param method string
--- @param params table
--- @return table response
local function approval(method, params)
  local what = method == 'item/fileChange/requestApproval' and 'change files'
    or 'run ' .. (params.command or 'a command')
  local prompt = ('Codex wants to %s%s: '):format(what, params.reason and ' (' .. params.reason .. ')' or '')
  local decisions = { Allow = 'accept', ['Always allow'] = 'acceptForSession', Deny = 'decline' }
  local choice = rpc.select({ 'Allow', 'Always allow', 'Deny' }, { prompt = prompt })
  return { decision = decisions[choice] or 'decline' }
end

--- @param msg table
function Client:on_output(msg)
  if msg.method == nil then
    local callback = self.pending[msg.id]
    self.pending[msg.id] = nil
    if callback ~= nil then callback(msg.error and msg.error.message, msg.result) end
    return
  end
  local params = msg.params or {}
  if msg.id ~= nil then
    if not vim.endswith(msg.method, '/requestApproval') or msg.method == 'item/permissions/requestApproval' then
      return self:send({ id = msg.id, error = { code = -32601, message = msg.method .. ' is not supported by otto' } })
    end
    return rpc.run(function() self:send({ id = msg.id, result = approval(msg.method, params) }) end)
  end

  local item = params.item
  if msg.method == 'turn/started' then
    self.turn = params.turn.id
    -- like compactions, which are turns of their own
    if not self.working then
      self.working = true
      self.on_event({ type = 'agent_start' })
    end
  elseif msg.method == 'item/started' and item.type == 'contextCompaction' then
    self.on_event({ type = 'compaction_start' })
  elseif msg.method == 'item/started' and (item.type == 'commandExecution' or item.type == 'mcpToolCall') then
    local started = calls(item)
    self.on_event({ type = 'message_end', message = { role = 'assistant', content = started } })
    for _, call in ipairs(started) do
      self.announced[call.id] = true
      self.on_event({ type = 'tool_execution_start', toolCallId = call.id, toolName = call.name, args = call.arguments })
    end
  elseif msg.method == 'item/completed' then
    if item.type == 'userMessage' and self:read(item) then return end
    for _, message in ipairs(messages(item, self.announced, self.tokens)) do
      self.on_event({ type = 'message_end', message = message })
    end
    if item.type == 'contextCompaction' then self.on_event({ type = 'compaction_end' }) end
  elseif msg.method == 'error' and not params.willRetry then
    local message = { role = 'assistant', content = {}, errorMessage = params.error.message }
    self.on_event({ type = 'message_end', message = message })
  elseif msg.method == 'thread/tokenUsage/updated' then
    self.tokens = params.tokenUsage.last.totalTokens
    self.window = params.tokenUsage.modelContextWindow or self.window
  elseif msg.method == 'thread/name/updated' then
    self.name = params.threadName
    self.on_event({ type = 'session_info_changed', name = self.name })
  elseif msg.method == 'turn/completed' then
    self.turn = nil
    -- whatever it didn't read is gone with the turn
    self.steering = {}
    -- after interrupts too, like pi, so that <C-CR> sends them straight away
    if #self.follow_ups > 0 then
      self:start_turn(table.remove(self.follow_ups, 1))
      return self:queue_update()
    end
    self.working = false
    self:queue_update()
    self.on_event({ type = 'agent_settled', aborted = params.turn.status == 'interrupted' })
  end
end

--- @param turns table[] Turn
--- @return table[] AgentMessage
local function history(turns)
  local all = {}
  for _, turn in ipairs(turns) do
    for _, item in ipairs(turn.items) do
      vim.list_extend(all, messages(item, {}))
    end
    if turn.error ~= nil then
      table.insert(all, { role = 'assistant', content = {}, errorMessage = turn.error.message })
    end
  end
  return all
end

--- pi's requests, see `rpc.lua`
--- @type table<string, fun(self: otto.CodexClient, msg: table, done: fun(err?: string, data?: table))>
local handlers = {
  prompt = function(self, msg, done)
    self:prompt(msg.message, msg.streamingBehavior)
    done()
  end,
  abort = function(self, _, done)
    if self.turn == nil then return done() end
    self:invoke('turn/interrupt', { threadId = self.thread, turnId = self.turn }, done)
  end,
  -- prompts that steer are with Codex already
  clear_queue = function(self, _, done)
    local follow_ups = self.follow_ups
    self.follow_ups = {}
    self:queue_update()
    done(nil, { steering = {}, followUp = follow_ups })
  end,
  compact = function(self, _, done) self:invoke('thread/compact/start', { threadId = self.thread }, done) end,
  set_model = function(self, msg, done)
    self.model = msg.modelId
    done()
  end,
  cycle_thinking_level = function(self, _, done)
    local model = vim.iter(self.models):find(function(option) return option.id == self.model end)
    local options = model and model.supportedReasoningEfforts or {}
    local levels = vim.tbl_map(function(option) return option.reasoningEffort end, options)
    if #levels == 0 then levels = { 'low', 'medium', 'high' } end
    self.effort = levels[(vim.fn.index(levels, self.effort) + 1) % #levels + 1]
    self.on_event({ type = 'thinking_level_changed', level = self.effort })
    done(nil, { level = self.effort })
  end,
  set_session_name = function(self, msg, done)
    self:invoke('thread/name/set', { threadId = self.thread, name = msg.name }, done)
  end,
  get_commands = function(_, _, done) done(nil, { commands = {} }) end,
  get_available_models = function(self, _, done)
    local models = vim.tbl_map(function(model) return { provider = 'codex', id = model.id } end, self.models)
    done(nil, { models = models })
  end,
  get_messages = function(self, _, done)
    -- Codex only lists the turns of threads with messages
    if self.created then return done(nil, { messages = {} }) end
    local turns = {}
    local function page(cursor)
      local params = { threadId = self.thread, itemsView = 'full', sortDirection = 'asc', cursor = cursor }
      self:invoke('thread/turns/list', params, function(err, data)
        if err ~= nil then return done(err) end
        vim.list_extend(turns, data.data)
        if data.nextCursor ~= nil then return page(data.nextCursor) end
        done(nil, { messages = history(turns) })
      end)
    end
    page(nil)
  end,
  get_state = function(self, _, done)
    local model = { id = self.model, reasoning = true }
    done(nil, { sessionId = self.thread, sessionName = self.name, model = model, thinkingLevel = self.effort })
  end,
  get_session_stats = function(self, _, done)
    local percent = self.tokens and self.window and self.tokens / self.window * 100
    -- Codex uses the ChatGPT subscription
    done(nil, { cost = 0, contextUsage = percent and { percent = percent } })
  end,
}

--- Answers pi's requests, once the thread started
--- @param msg table
--- @param callback? fun(err?: string, data?: table)
function Client:request(msg, callback)
  callback = callback or function(err)
    if err ~= nil then rpc.notify(err) end
  end
  if self.thread == nil then
    return table.insert(self.waiting, function() self:request(msg, callback) end)
  end
  local handler = handlers[msg.type]
  if handler == nil then return callback(msg.type .. ' is not supported by codex') end
  handler(self, msg, callback)
end

--- @async
--- @param msg table
--- @return table?
function Client:call(msg)
  local err, data = vim.async.await(3, self.request, self, msg)
  if err ~= nil then error(err, 0) end
  return data
end

function Client:close()
  self.closed = true
  if not self.proc:is_closing() then self.proc:kill('sigterm') end
end

--- @param result table Of `thread/start` or `thread/resume`
function Client:started(result)
  self.thread = result.thread.id
  self.model = result.model
  self.effort = result.reasoningEffort
  self.name = result.thread.name
  for _, waiting in ipairs(self.waiting) do
    waiting()
  end
  self.waiting = {}
end

--- Starts Codex for the session. Codex creates the ids of threads, so a new session starts with its name or when it
--- started, and emits `session_created` with its id
--- @param id string Of the thread, or of the new session
--- @param on_event fun(event: table) like pi's, see `rpc.lua`
--- @param name? string Display name of a new session
--- @return otto.CodexClient
function M.start(id, on_event, name)
  --- @type otto.CodexClient
  local client = setmetatable({
    closed = false,
    seq = 0,
    pending = {},
    on_event = on_event,
    waiting = {},
    working = false,
    models = {},
    announced = {},
    steering = {},
    follow_ups = {},
  }, Client)

  local partial = ''
  local function on_stdout(_, data)
    local lines = vim.split(partial .. (data or ''), '\n')
    partial = table.remove(lines)
    for _, line in ipairs(lines) do
      if client.closed then return end
      client:on_output(vim.json.decode(line, { luanil = { object = true, array = true } }))
    end
  end

  local opts = { stdin = true, stdout = vim.schedule_wrap(on_stdout) }
  local stderr
  opts.stderr = function(_, data) stderr = data or stderr end
  client.proc = vim.system({ 'codex', 'app-server' }, opts, function(out)
    if client.closed or out.code == 0 then return end
    vim.schedule(function() rpc.notify('codex exited: ' .. (stderr or out.code)) end)
  end)

  local info = { name = 'otto', title = 'Otto', version = '0' }
  client:invoke('initialize', { clientInfo = info }, function(err)
    if err ~= nil then return rpc.notify(err) end
    client:send({ method = 'initialized' })
    client:invoke('model/list', {}, function(_, data) client.models = data and data.data or {} end)
    if M.is_thread(id) then
      return client:invoke('thread/resume', { threadId = id, excludeTurns = true }, function(resume_err, result)
        if resume_err ~= nil then return rpc.notify(resume_err) end
        client:started(result)
      end)
    end
    client:invoke('thread/start', { cwd = vim.fn.getcwd() }, function(start_err, result)
      if start_err ~= nil then return rpc.notify(start_err) end
      client.created = true
      client:started(result)
      on_event({ type = 'session_created', id = client.thread })
      if name ~= nil then client:request({ type = 'set_session_name', name = name }) end
    end)
  end)
  return client
end

return M
