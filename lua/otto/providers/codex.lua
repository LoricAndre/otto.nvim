-- Codex: `codex app-server`, JSON-RPC over stdio. Turns are made of items, the same in its history and once they
-- complete, which `item` turns into the log. Its session files hold items of another kind, so the history comes from
-- the app-server too. Items have no times, so they take those of their turns

local event = require('otto.event')
local log = require('otto.providers.log')
local proc = require('otto.proc')
local util = require('otto.util')

local M = { name = 'codex', icon = '󰚩 ' }

--- @param id string
--- @return boolean whether it's the id of a thread, which Codex creates, rather than the name of a new session
local function is_thread(id) return id:match('^%x+%-%x+%-%x+%-%x+%-%x+$') ~= nil end

--- @param name? string
--- @return string id of a new session, until Codex creates its thread
function M.new_id(name) return ((name or os.date('%Y_%m_%d_%H%M%S')):gsub('[^%w._-]+', '_')) end

--- @param item table commandExecution
--- @return string like "cat a.txt", without the `bash -lc` that Codex runs it with
local function command(item)
  local quoted = item.command:match('^%S+ %-lc (.+)$')
  if quoted == nil then return item.command end
  -- with the single quotes inside it unescaped, which are '"'"'
  local single = quoted:match("^'(.*)'$")
  return single and (single:gsub([['"'"']], "'")) or quoted:match('^"(.*)"$') or quoted
end

--- Commands that only read, list or search become otto's tools for those, like Codex's own UI shows them
--- @param item table commandExecution
--- @return string tool
--- @return table args
local function shell_tool(item)
  local actions = item.commandActions or {}
  local action = #actions == 1 and actions[1] or {}
  -- like `sed -n '10,20p' file`
  local offset = tonumber(action.command and action.command:match('^sed %-n [\'"]?(%d+)[,p]') or nil)
  if action.type == 'read' then return 'read', { path = action.path, offset = offset } end
  if action.type == 'listFiles' then return 'ls', { path = action.path or '.' } end
  if action.type == 'search' then return 'grep', { pattern = action.query or action.command, path = action.path } end
  return 'bash', { command = command(item) }
end

--- @param change { diff: string, kind: { type: string } }
--- @return otto.DiffLine[]
local function diff_lines(change)
  local lines = {}
  local old = 1
  local new = 1
  for _, line in ipairs(vim.split(change.diff:gsub('\n$', ''), '\n')) do
    local old_start, new_start = line:match('^@@ %-(%d+),?%d* %+(%d+),?%d* @@')
    if old_start ~= nil then
      old = tonumber(old_start)
      new = tonumber(new_start)
    elseif change.kind.type == 'delete' then
      table.insert(lines, { sign = '-', lnum = old, text = line })
      old = old + 1
    elseif not vim.startswith(line, '\\') then -- like "\ No newline at end of file"
      -- empty lines around the change can lose their space
      local sign = line == '' and ' ' or line:sub(1, 1)
      table.insert(lines, { sign = sign, lnum = sign == '-' and old or new, text = line:sub(2) })
      if sign ~= '+' then old = old + 1 end
      if sign ~= '-' then new = new + 1 end
    end
  end
  return lines
end

--- Tool calls of an item, of which file changes have one per file
--- @param item table
--- @return { id: string, tool: string, args: table }[]
local function calls(item)
  local function call(id, tool, args) return { id = id, tool = tool, args = args } end
  if item.type == 'commandExecution' then return { call(item.id, shell_tool(item)) } end
  if item.type == 'webSearch' then return { call(item.id, 'web_search', { query = item.query }) } end
  if item.type == 'mcpToolCall' then return { call(item.id, item.tool, item.arguments) } end
  if item.type ~= 'fileChange' then return {} end
  return vim
    .iter(ipairs(item.changes))
    :map(function(i, change)
      local id = item.id .. ':' .. i
      -- the diff of a new file is its content
      if change.kind.type == 'add' then return call(id, 'write', { path = change.path, content = change.diff }) end
      return call(id, 'edit', { path = change.path })
    end)
    :totable()
end

--- @param item table
--- @return table[] results, see `otto.Log.tool_result`
local function results(item)
  if item.type == 'commandExecution' then
    local ok = item.status == 'completed' and (item.exitCode or 0) == 0
    return { { id = item.id, ok = ok, output = util.trim_end(item.aggregatedOutput or ''), exit_code = item.exitCode } }
  end
  if item.type == 'webSearch' then return { { id = item.id, ok = true, output = '' } } end
  if item.type == 'mcpToolCall' then
    local output = item.error and item.error.message or event.text_of(item.result and item.result.content)
    return { { id = item.id, ok = item.error == nil, output = util.trim_end(output) } }
  end
  if item.type ~= 'fileChange' then return {} end
  local ok = item.status == 'completed'
  return vim
    .iter(ipairs(item.changes))
    :map(function(i, change)
      local diff = ok and change.kind.type ~= 'add' and diff_lines(change) or nil
      return { id = item.id .. ':' .. i, ok = ok, output = '', diff = diff }
    end)
    :totable()
end

--- Adds a completed item to the log, of which the tool calls may have been added when it started
--- @param session_log otto.Log
--- @param item table
--- @param announced table<string, true> Tool calls in the log already
--- @param at? integer
local function add(session_log, item, announced, at)
  if item.type == 'userMessage' then return session_log:user(vim.trim(event.text_of(item.content)), at) end
  if item.type == 'agentMessage' then
    -- prompts after commentary steer the turn, which only ends when Codex says so
    if vim.trim(item.text) ~= '' then session_log:text(vim.trim(item.text), at, item.phase == 'commentary') end
    return
  end
  -- Codex keeps the summary to itself
  if item.type == 'contextCompaction' then return session_log:compaction({}, at) end
  for _, call in ipairs(calls(item)) do
    if not announced[call.id] then session_log:tool_call(call.id, call.tool, call.args, at) end
    announced[call.id] = nil
  end
  for _, result in ipairs(results(item)) do
    -- commands say how long they ran, which shows once they take a while
    session_log:tool_result(result, at and item.durationMs and at + item.durationMs or at)
  end
end

--- @param turn table
--- @return integer? started
--- @return integer? completed, in milliseconds since the epoch
local function times(turn)
  local started = turn.startedAt and turn.startedAt * 1000
  local completed = turn.completedAt and turn.completedAt * 1000
    or started and turn.durationMs and started + turn.durationMs
  return started, completed
end

--- @class otto.CodexHandle : otto.Handle
--- @field proc otto.Proc
--- @field log otto.Log
--- @field on_status fun(status: otto.Status)
--- @field thread? string id, once Codex started or resumed it
--- @field waiting fun()[] Requests that wait for the thread
--- @field error? string When the thread failed to start
--- @field turn? string id of the turn that's running
--- @field turn_at? integer When the turn started
--- @field working boolean From sending a prompt until its turn completes
--- @field model? string
--- @field effort? string like "medium", which turns take, since Codex sets both per turn
--- @field models table[] Of `model/list`
--- @field announced table<string, true> Tool calls that started, in the log before their items complete
--- @field unread { text: string, id: string }[] Prompts that Codex hasn't read yet
--- @field follow_ups string[] Prompts that wait for the turn to complete
--- @field created? boolean Whether the thread started with the handle, without history
local Handle = {}
Handle.__index = Handle

--- @param method string
--- @param params table
--- @param callback? fun(err?: string, data?: table) Notifies errors by default
function Handle:invoke(method, params, callback)
  self.proc:request(function(id) return { method = method, id = id, params = params } end, callback)
end

--- Waits until the thread started
--- @async
function Handle:wait()
  if self.thread == nil and self.error == nil then
    vim.async.await(1, function(done) table.insert(self.waiting, done) end)
  end
  if self.thread == nil then error(self.error, 0) end
end

--- Invokes the method once the thread started
--- @async
--- @param method string
--- @param params fun(): table
--- @return table?
function Handle:call(method, params)
  self:wait()
  local framed = params()
  return self.proc:call(function(id) return { method = method, id = id, params = framed } end)
end

function Handle:queue_update()
  local texts = vim.tbl_map(function(unread) return unread.text end, self.unread)
  self.on_status({ type = 'queue', steering = texts, follow_up = self.follow_ups })
end

--- @param working boolean
function Handle:set_working(working)
  self.working = working
  self.on_status({ type = 'working', state = working and 'working' or nil })
end

--- @param text string
--- @return table input of a turn
local function input(text) return { { type = 'text', text = text, text_elements = {} } } end

--- @param text string
function Handle:start_turn(text)
  local id = util.uuid()
  table.insert(self.unread, { text = text, id = id })
  self:queue_update()
  if not self.working then self:set_working(true) end
  -- prompts can come before the thread starts
  util.run(function()
    self:wait()
    local params = {
      threadId = self.thread,
      input = input(text),
      clientUserMessageId = id,
      model = self.model,
      effort = self.effort,
    }
    self:invoke('turn/start', params, function(err)
      if err == nil then return end
      util.notify(err)
      self:read({ clientId = id })
      if self.turn == nil then self:set_working(false) end
    end)
  end)
end

--- Codex echoes prompts once it reads them
--- @param item table userMessage
function Handle:read(item)
  local index = vim.iter(ipairs(self.unread)):find(function(_, unread) return unread.id == item.clientId end)
  if index == nil then return end
  table.remove(self.unread, index)
  self:queue_update()
end

--- Codex asks before running commands or changing files that its reviewer doesn't allow
--- @param msg table
function Handle:approval(msg)
  local params = msg.params or {}
  local what = msg.method == 'item/fileChange/requestApproval' and 'change files'
    or 'run ' .. (params.command or 'a command')
  local prompt = ('Codex wants to %s%s: '):format(what, params.reason and ' (' .. params.reason .. ')' or '')
  local decisions = { Allow = 'accept', ['Always allow'] = 'acceptForSession', Deny = 'decline' }
  self.on_status({
    type = 'request',
    kind = 'select',
    prompt = prompt,
    items = { 'Allow', 'Always allow', 'Deny' },
    respond = function(choice) self.proc:send({ id = msg.id, result = { decision = decisions[choice] or 'decline' } }) end,
  })
end

--- @param msg table
function Handle:on_message(msg)
  if msg.method == nil then
    return self.proc:respond(msg.id, msg.error and (msg.error.message or vim.inspect(msg.error)), msg.result)
  end
  local params = msg.params or {}
  if msg.id ~= nil then
    if not vim.endswith(msg.method, '/requestApproval') or msg.method == 'item/permissions/requestApproval' then
      return self.proc:send({
        id = msg.id,
        error = { code = -32601, message = msg.method .. ' is not supported by otto' },
      })
    end
    return self:approval(msg)
  end

  local item = params.item
  if msg.method == 'turn/started' then
    self.turn = params.turn.id
    self.turn_at = times(params.turn)
    -- like compactions, which are turns of their own
    if not self.working then self:set_working(true) end
  elseif msg.method == 'item/started' and item.type == 'contextCompaction' then
    self.on_status({ type = 'working', state = 'compacting' })
  elseif msg.method == 'item/started' and (item.type == 'commandExecution' or item.type == 'mcpToolCall') then
    for _, call in ipairs(calls(item)) do
      self.announced[call.id] = true
      self.log:tool_call(call.id, call.tool, call.args, self.turn_at)
    end
  -- not of earlier turns, like commands that ran in the background, which the log can't add to
  elseif msg.method == 'item/completed' and params.turnId == self.turn then
    if item.type == 'userMessage' then self:read(item) end
    add(self.log, item, self.announced, self.turn_at)
    if item.type == 'contextCompaction' then self.on_status({ type = 'working', state = 'working' }) end
  elseif msg.method == 'error' and not params.willRetry then
    self.log:error(params.error.message, self.turn_at)
  elseif msg.method == 'thread/tokenUsage/updated' then
    self.on_status({
      type = 'info',
      context = params.tokenUsage.last.totalTokens,
      window = params.tokenUsage.modelContextWindow,
    })
  elseif msg.method == 'thread/name/updated' then
    self.on_status({ type = 'info', name = params.threadName })
  elseif msg.method == 'turn/completed' then
    self.turn = nil
    -- whatever it didn't read is gone with the turn
    self.unread = {}
    self.log:settle(params.turn.status == 'interrupted', select(2, times(params.turn)))
    -- after interrupts too, so that <C-CR> sends them straight away
    if #self.follow_ups > 0 then return self:start_turn(table.remove(self.follow_ups, 1)) end
    self:queue_update()
    self:set_working(false)
  end
end

--- The history, from the app-server
--- @async
function Handle:replay()
  self:wait()
  -- Codex only lists the turns of threads with messages
  if self.created then return end
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
    local started, completed = times(turn)
    for _, item in ipairs(turn.items) do
      add(self.log, item, {}, started)
    end
    if turn.error ~= nil then self.log:error(turn.error.message, started) end
    self.log:settle(turn.status == 'interrupted', completed)
  end
  self.log:finish()
end

--- @param text string
--- @param mode 'steer' | 'follow_up' While a turn runs
function Handle:prompt(text, mode)
  if not self.working then return self:start_turn(text) end
  -- until the turn starts, which there's nothing to steer before
  if mode == 'follow_up' or self.turn == nil then
    table.insert(self.follow_ups, text)
    return self:queue_update()
  end
  local id = util.uuid()
  local turn = self.turn
  table.insert(self.unread, { text = text, id = id })
  self:queue_update()
  local params = { threadId = self.thread, input = input(text), clientUserMessageId = id, expectedTurnId = turn }
  self:invoke('turn/steer', params, function(err)
    if err == nil then return end
    self:read({ clientId = id })
    -- the turn completed before Codex got the prompt, which starts the next one instead
    if turn ~= nil and self.turn ~= turn then return self:start_turn(text) end
    util.notify(err)
  end)
end

function Handle:abort()
  if self.turn == nil then return end
  self:invoke('turn/interrupt', { threadId = self.thread, turnId = self.turn })
end

--- Prompts that steer are with Codex already
--- @async
--- @return string[]
function Handle:take_queue()
  local follow_ups = self.follow_ups
  self.follow_ups = {}
  self:queue_update()
  return follow_ups
end

--- @async
function Handle:compact()
  self:call('thread/compact/start', function() return { threadId = self.thread } end)
end

--- @async
--- @return string[]
function Handle:models()
  return vim.tbl_map(function(model) return model.id end, self.models)
end

--- @async
--- @param model string
function Handle:set_model(model)
  self.model = model
  self.on_status({ type = 'info', model = model })
end

--- @async
function Handle:cycle_effort()
  local model = vim.iter(self.models):find(function(option) return option.id == self.model end)
  local options = model and model.supportedReasoningEfforts or {}
  local levels = vim.tbl_map(function(option) return option.reasoningEffort end, options)
  if #levels == 0 then levels = { 'low', 'medium', 'high' } end
  self.effort = levels[(vim.fn.index(levels, self.effort) + 1) % #levels + 1]
  self.on_status({ type = 'info', effort = self.effort })
end

--- @async
--- @param name string
function Handle:rename(name)
  self:call('thread/name/set', function() return { threadId = self.thread, name = name } end)
end

--- @async
--- @return otto.Command[]
function Handle:commands() return {} end

function Handle:close() self.proc:close() end

--- Releases what waits for the thread
--- @param err? string When it failed to start
--- @param result? table Of `thread/start` or `thread/resume`
function Handle:started(err, result)
  if err ~= nil then
    -- which raises in what waits for the thread, like the replay that every session starts with
    self.error = err
    self.unread = {}
    self:queue_update()
    self:set_working(false)
  else
    self:on_thread(result)
  end
  for _, waiting in ipairs(self.waiting) do
    waiting()
  end
  self.waiting = {}
end

--- @param result table Of `thread/start` or `thread/resume`
function Handle:on_thread(result)
  self.thread = result.thread.id
  self.model = result.model
  self.effort = result.reasoningEffort
  self.on_status({
    type = 'info',
    id = self.thread,
    name = result.thread.name,
    model = self.model,
    effort = self.effort,
  })
end

--- Starts Codex for the session. Codex creates the ids of threads, so a new session starts with its name or when it
--- started, until its thread starts
--- @param id string Of the thread, or of the new session
--- @param opts otto.OpenOpts
--- @return otto.CodexHandle
function M.open(id, opts)
  --- @type otto.CodexHandle
  local handle = setmetatable({
    log = log.new(opts.on_log, opts.on_status),
    on_status = opts.on_status,
    waiting = {},
    working = false,
    models = {},
    announced = {},
    unread = {},
    follow_ups = {},
  }, Handle)
  handle.proc = proc.start({ 'codex', 'app-server' }, {
    name = 'codex',
    on_message = function(msg) handle:on_message(msg) end,
    on_exit = function()
      handle.log:settle(true)
      handle:set_working(false)
    end,
  })

  local info = { name = 'otto', title = 'Otto', version = '0' }
  handle:invoke('initialize', { clientInfo = info }, function(err)
    if err ~= nil then return handle:started(err) end
    handle.proc:send({ method = 'initialized' })
    handle:invoke('model/list', {}, function(_, data) handle.models = data and data.data or {} end)
    if is_thread(id) then
      return handle:invoke(
        'thread/resume',
        { threadId = id, excludeTurns = true },
        function(resume_err, result) handle:started(resume_err, result) end
      )
    end
    handle:invoke('thread/start', { cwd = vim.fn.getcwd() }, function(start_err, result)
      handle.created = start_err == nil
      handle:started(start_err, result)
      if start_err ~= nil then return end
      if opts.name ~= nil then handle:invoke('thread/name/set', { threadId = handle.thread, name = opts.name }) end
    end)
  end)
  return handle
end

--- @param file string
--- @param modified integer
--- @return otto.SessionInfo?
local function read(file, modified)
  -- closed before returning, since this reads the sessions of every folder
  local handle = assert(io.open(file))
  local meta = vim.json.decode(handle:read('*l') or '{}').payload or {}
  handle:close()
  -- sub-agents, like its reviewer, have sessions of their own
  if meta.cwd ~= vim.fn.getcwd() or type(meta.source) ~= 'string' then return end
  local info = { provider = 'codex', id = meta.id, messages = 0, modified = modified }
  local first_prompt
  for line in io.lines(file) do
    if line:find('"type":"item_completed"', 1, true) then
      info.messages = info.messages + 1
      if first_prompt == nil and line:find('"type":"UserMessage"', 1, true) then
        local content = vim.json.decode(line).payload.item.content
        first_prompt = (content[1] or {}).text
      end
    -- of older versions, which don't save items
    elseif line:find('"type":"user_message"', 1, true) or line:find('"type":"agent_message"', 1, true) then
      info.messages = info.messages + 1
      if first_prompt == nil and line:find('"type":"user_message"', 1, true) then
        first_prompt = vim.json.decode(line).payload.message
      end
    end
  end
  info.title = first_prompt and vim.trim(first_prompt):gsub('%s+', ' ') or meta.id
  return info
end

--- @return { file: string, read: fun(file: string, modified: integer): otto.SessionInfo? }[]
function M.files()
  return vim.tbl_map(
    function(file) return { file = file, read = read } end,
    vim.fn.glob('~/.codex/sessions/**/rollout-*.jsonl', false, true)
  )
end

--- Codex keeps the names apart from the sessions
--- @return table<string, string> names by id
function M.names()
  local names = {}
  local index = vim.fs.normalize('~/.codex/session_index.jsonl')
  if vim.uv.fs_stat(index) == nil then return names end
  for line in io.lines(index) do
    local entry = vim.json.decode(line)
    names[entry.id] = entry.thread_name
  end
  return names
end

return M
