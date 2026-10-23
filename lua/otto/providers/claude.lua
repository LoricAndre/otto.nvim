-- Claude Code: `claude -p` with stream-json in both directions. Its session files and its stream hold the same
-- entries, which `entry` turns into the log

local event = require('otto.event')
local log = require('otto.providers.log')
local proc = require('otto.proc')
local util = require('otto.util')

local M = { name = 'claude', icon = '󰛄  ' }

--- @type table<string, { session: string, at?: string }> Forks by id, until they're prompted, which saves them
local forks = {}
--- @type table<string, true> Subagents that ended, by uri, which Claude Code before 2.1.304 only says in their parent's
local ended = {}
--- @type table<string, string> Session files by id, of the folder that they started in
local files = {}

-- of the default model, until Claude Code reports the window of the one that answers
local default_window = 1000000

--- Claude Code's tools as otto's
local tools = {
  Read = function(input) return 'read', { path = input.file_path, offset = input.offset, limit = input.limit } end,
  Edit = function(input) return 'edit', { path = input.file_path } end,
  MultiEdit = function(input) return 'edit', { path = input.file_path } end,
  Write = function(input) return 'write', { path = input.file_path, content = input.content } end,
  Bash = function(input)
    return 'bash', { command = input.command, description = input.description, background = input.run_in_background }
  end,
  Grep = function(input) return 'grep', { pattern = input.pattern, path = input.path } end,
  Glob = function(input) return 'find', { pattern = input.pattern, path = input.path } end,
  WebSearch = function(input) return 'web_search', { query = input.query } end,
  WebFetch = function(input) return 'fetch', { urls = { input.url } } end,
  Agent = function(input)
    local args = { description = input.description, prompt = input.prompt, type = input.subagent_type }
    args.background = input.run_in_background
    return 'agent', args
  end,
  SendMessage = function(input) return 'message', { to = input.to, text = input.message, summary = input.summary } end,
  -- of subagents, to the session that started them
  SubagentHandback = function(input) return 'message', { to = 'parent', text = input.message, summary = 'handback' } end,
}
tools.Task = tools.Agent

--- @param id string
--- @return string
local function session_file(id)
  -- like Claude Code, which replaces each UTF-16 unit, so characters past U+FFFF take two
  local folder = vim.fn.getcwd():gsub('[%z\1-\127\194-\244][\128-\191]*', function(char)
    if char:match('^%w$') then return char end
    return #char == 4 and '--' or '-'
  end)
  return ('%s/.claude/projects/%s/%s.jsonl'):format(vim.env.HOME, folder, id)
end

--- @return string random UUID, which Claude Code requires for session ids
function M.new_id() return util.uuid() end

--- Edits come with hunks
--- @param patch { oldStart: integer, newStart: integer, lines: string[] }[]
--- @return otto.DiffLine[]
local function diff_lines(patch)
  local lines = {}
  for _, hunk in ipairs(patch) do
    local old = hunk.oldStart
    local new = hunk.newStart
    -- without lines like "\ No newline at end of file"
    for _, line in ipairs(vim.tbl_filter(function(line) return not vim.startswith(line, '\\') end, hunk.lines)) do
      local sign = line:sub(1, 1)
      table.insert(lines, { sign = sign, lnum = sign == '-' and old or new, text = line:sub(2) })
      if sign ~= '+' then old = old + 1 end
      if sign ~= '-' then new = new + 1 end
    end
  end
  return lines
end

--- @param usage table Of an answer
--- @return integer tokens in the context
local function context_tokens(usage)
  return usage.input_tokens + usage.cache_read_input_tokens + usage.cache_creation_input_tokens
end

--- Tags of what Claude Code adds as prompts, like the output of local commands such as /compact, and the caveats around
--- them
local tags = {
  ['task-notification'] = true,
  ['command-name'] = true,
  ['command-message'] = true,
  ['local-command-caveat'] = true,
  ['local-command-stdout'] = true,
  ['local-command-stderr'] = true,
  ['system-reminder'] = true,
  ['bash-input'] = true,
  ['bash-stdout'] = true,
  ['bash-stderr'] = true,
  -- messages from other sessions
  ['cross-session-message'] = true,
  ['agent-message'] = true,
}

--- @param text string
--- @return boolean whether Claude Code added it, rather than the user, who may start a prompt with HTML
local function is_tagged(text) return tags[text:match('^<([%w-]+)[%s>]')] == true end

--- @class otto.ClaudeState What the decoder keeps between entries
--- @field compaction { before?: integer, after?: integer } The last one
--- @field model? string
--- @field titled? boolean Whether the session has a custom title, which AI titles don't replace
--- @field session string Id of the session, or of the session that started the subagent
--- @field calls table<string, { tool: string, args: table }> By id, for the subagents and commands that they start
--- @field agents table<string, { name: string, uri: string }> Subagents by id
--- @field handbacks table<string, string> Reports of subagents by id, which arrive before they end
--- @field notified table<string, true> Ends of subagents and commands, which the stream and the file may both have
--- @field child? { parent: { name: string, uri: string }, spawned?: boolean } Of a subagent's session
--- @field prompts { uuid: string, parent?: string, text: string }[] With the entry before each, which forks resume at
--- @field last? string Uuid of the last entry, which the stream's entries don't say they follow

--- @param session string
--- @param child? { parent: { name: string, uri: string } }
--- @return otto.ClaudeState
local function new_state(session, child)
  return {
    compaction = {},
    session = session,
    calls = {},
    agents = {},
    handbacks = {},
    notified = {},
    child = child,
    prompts = {},
  }
end

--- @param text string
--- @param name string Of the tag
--- @return string?
local function tag(text, name)
  local escaped = name:gsub('%-', '%%-')
  return text:match('<' .. escaped .. '>(.-)</' .. escaped .. '>')
end

--- The end of a subagent or a command, as Claude Code adds it to the conversation, like the stream's
--- `task_notification`
--- @param text string
--- @return table
local function notification_of(text)
  return {
    task_id = tag(text, 'task-id'),
    tool_use_id = tag(text, 'tool-use-id'),
    status = tag(text, 'status'),
    summary = tag(text, 'summary'),
    result = tag(text, 'result'),
    output_file = tag(text, 'output-file'),
    usage = {
      total_tokens = tonumber(tag(text, 'subagent_tokens') or tag(text, 'total_tokens')),
      tool_uses = tonumber(tag(text, 'tool_uses')),
      duration_ms = tonumber(tag(text, 'duration_ms')),
    },
  }
end

--- Adds the end of a subagent, as a message from it, or of a background command, as a second result of it
--- @param session_log otto.Log
--- @param state otto.ClaudeState
--- @param notification table See `notification_of`
--- @param at? integer
local function notify(session_log, state, notification, at)
  -- which the agent reads like a prompt
  session_log:prompted()
  if notification.task_id == nil or notification.skip_transcript then return end
  local usage = notification.usage or {}
  local key = table.concat({ notification.task_id, notification.status or '', usage.duration_ms or '' }, '\0')
  if state.notified[key] then return end
  state.notified[key] = true
  local call = state.calls[notification.tool_use_id or '']
  if call ~= nil and call.tool == 'bash' then
    local id = notification.task_id .. ':end'
    local code = tonumber((notification.summary or ''):match('.*exit code (%d+)'))
    local file = notification.output_file and io.open(notification.output_file, 'r')
    local output = file and file:read('*a') or ''
    if file then file:close() end
    local trailer = output:match('%[exited with code (%d+)%]%s*$')
    code = code or tonumber(trailer)
    output = output:gsub('%s*%[exited with code %d+%]%s*$', '')
    session_log:tool_call(id, 'bash', call.args, at)
    local ok = notification.status == 'completed' and (code or 0) == 0
    return session_log:tool_result({ id = id, ok = ok, output = util.trim_end(output), exit_code = code }, at)
  end
  local agent = state.agents[notification.task_id]
  if agent == nil and (call == nil or call.tool ~= 'agent') then return end
  local report = notification.handback_report or state.handbacks[notification.task_id]
  state.handbacks[notification.task_id] = nil
  local status = notification.status
  local uri = agent and agent.uri or ('claude://%s/%s'):format(state.session, notification.task_id)
  ended[uri] = true
  session_log:message({
    from = agent and agent.name or call.args.description,
    uri = uri,
    kind = status == 'completed' and (report and 'handback' or 'done') or status == 'killed' and 'stopped' or 'failed',
    text = report or notification.result or notification.summary,
    tokens = usage.total_tokens,
    tools = usage.tool_uses,
    seconds = usage.duration_ms and math.floor(usage.duration_ms / 1000),
  }, at)
end

--- A message from another agent, like a subagent's report, which only renders once the subagent ends
--- @param session_log otto.Log
--- @param state otto.ClaudeState
--- @param origin table Of the entry
--- @param at? integer
local function peer(session_log, state, origin, at)
  local agent = state.agents[origin.from or '']
  if origin.handback then
    state.handbacks[origin.from] = origin.handbackReportText or origin.body
    return session_log:prompted()
  end
  session_log:message(
    { from = agent and agent.name or origin.from or 'agent', uri = agent and agent.uri, text = origin.body },
    at
  )
end

--- @param session_log otto.Log
--- @param state otto.ClaudeState
--- @param entry table
--- @param at? integer
local function tool_results(session_log, state, entry, at)
  local content = entry.message.content
  for _, block in ipairs(content) do
    if block.type == 'tool_result' then
      local details = entry.toolUseResult or entry.tool_use_result or {}
      local patch = type(details) == 'table' and details.structuredPatch or nil
      -- reads number their lines, but come with the file's content too
      local file = #content == 1 and type(details) == 'table' and vim.tbl_get(details, 'file', 'content') or nil
      local output = file or event.text_of(block.content or '')
      local result = { id = block.tool_use_id, ok = not block.is_error, output = util.trim_end(output) }
      -- new files come with an empty patch, and show their content
      if patch ~= nil and #patch > 0 then result.diff = diff_lines(patch) end
      local code, rest = result.output:match('^Exit code (%d+)\n?(.*)$')
      if code ~= nil then
        result.exit_code = tonumber(code)
        result.output = rest
      end
      local call = state.calls[block.tool_use_id] or {}
      local agent = call.tool == 'agent' and result.output:match('agentId: (%w+)')
      if agent then
        result.child = ('claude://%s/%s'):format(state.session, agent)
        state.agents[agent] = { name = call.args.description, uri = result.child }
        -- which the agent may run in the background without being asked
        local async = type(details) == 'table' and details.isAsync or vim.startswith(result.output, 'Async agent')
        call.args.background = call.args.background or async or nil
        -- what's left is metadata, or the agent's answer when the turn waited for it
        result.output = async and '' or vim.trim((result.output:gsub('\n*agentId: .*$', '')))
        if not async then ended[result.child] = true end
      end
      -- where its output goes, which its end has
      if call.tool == 'bash' and call.args.background and result.ok then result.output = '' end
      -- what was sent, rather than whether it was
      if call.tool == 'message' and result.ok then result.output = call.args.text or '' end
      session_log:tool_result(result, at)
    end
  end
end

--- Adds an entry of Claude Code to the log, which is the same in its session files and its stream
--- @param session_log otto.Log
--- @param state otto.ClaudeState
--- @param entry table
local function add(session_log, state, entry)
  local at = event.time(entry.timestamp)
  if entry.type == 'custom-title' then
    state.titled = true
    return session_log:info({ name = entry.customTitle })
  end
  if entry.type == 'ai-title' then
    if not state.titled then session_log:info({ name = entry.aiTitle }) end
    return
  end
  if entry.subtype == 'compact_boundary' then
    local metadata = entry.compactMetadata or entry.compact_metadata or {}
    local before = metadata.preTokens or metadata.pre_tokens
    local after = metadata.postTokens or metadata.post_tokens
    state.compaction = { before = before, after = after }
    if after ~= nil then session_log:info({ context = after }) end
    return
  end
  local origin = type(entry.origin) == 'table' and entry.origin or {}
  if entry.type == 'user' and origin.kind == 'peer' then return peer(session_log, state, origin, at) end
  -- subagents' files are all of their side
  if (entry.isSidechain and not state.child) or entry.isMeta or entry.parent_tool_use_id ~= nil then return end
  local parent = entry.parentUuid or state.last
  state.last = entry.uuid or state.last
  -- prompts that the agent read while it worked, which the stream echoes like the others
  local attachment = entry.attachment or {}
  if attachment.type == 'queued_command' and vim.startswith(attachment.prompt or '', '<task-notification>') then
    return notify(session_log, state, notification_of(attachment.prompt), at)
  end
  -- a subagent's are from the session that started it, like its updates while the subagent runs
  local prompt = type(attachment.prompt) == 'string' and attachment.prompt or nil
  if attachment.type == 'queued_command' and state.child and prompt and not is_tagged(prompt) then
    return session_log:message({ from = state.child.parent.name, uri = state.child.parent.uri, text = prompt }, at)
  end
  if attachment.type == 'queued_command' and attachment.commandMode == 'prompt' then
    if prompt and not is_tagged(prompt) then
      table.insert(state.prompts, { uuid = entry.uuid, parent = parent, text = vim.trim(prompt) })
      return session_log:user(vim.trim(prompt), at)
    end
    -- like messages from other sessions, which the agent reads like prompts
    return session_log:prompted()
  end
  if entry.message == nil then return end
  local content = entry.message.content

  if entry.type == 'assistant' then
    local model = entry.message.model
    if model ~= nil and model ~= state.model and model ~= '<synthetic>' then
      state.model = model
      session_log:info({ model = model })
    end
    -- like a failed request, which Claude Code adds as an answer
    if entry.isApiErrorMessage then return session_log:error(vim.trim(event.text_of(content)), at) end
    -- like "No response requested.", which ends a turn that was killed once the session resumes, or the output of
    -- commands like /rename, which only the stream has
    if model == '<synthetic>' then return session_log:settle(true) end
    for _, block in ipairs(content) do
      if block.type == 'text' and vim.trim(block.text) ~= '' then session_log:text(vim.trim(block.text), at) end
      if block.type == 'tool_use' then
        local name, args = (tools[block.name] or function(input) return block.name, input end)(block.input)
        if name == 'message' then
          local agent = state.agents[args.to or '']
          args.to = agent and agent.name or args.to == 'parent' and state.child and state.child.parent.name or args.to
        end
        state.calls[block.id] = { tool = name, args = args }
        session_log:tool_call(block.id, name, args, at)
      end
    end
    -- answers that Claude Code made itself have none, and some only have it for each of their iterations
    local tokens = entry.message.usage and context_tokens(entry.message.usage)
    if tokens and tokens > 0 then session_log:info({ context = tokens }) end
    return
  end
  if entry.type ~= 'user' then return end

  local text = type(content) == 'string' and content or nil
  if entry.isCompactSummary then
    return session_log:compaction(
      { summary = event.text_of(content), before = state.compaction.before, after = state.compaction.after },
      at
    )
  end
  if type(content) == 'table' then
    tool_results(session_log, state, entry, at)
    if vim.iter(content):any(function(block) return block.type == 'tool_result' end) then return end
    text = event.text_of(content)
  end
  if text == nil then return end
  if vim.startswith(text, '[Request interrupted') then return session_log:interrupt() end
  if vim.startswith(text, '<task-notification>') then return notify(session_log, state, notification_of(text), at) end
  -- like /compact from Claude Code's own UI, which renders as the compaction
  if text == '/compact' or vim.startswith(text, '/compact ') then return end
  if is_tagged(text) then return session_log:prompted() end
  local child = state.child
  if child == nil then
    table.insert(state.prompts, { uuid = entry.uuid, parent = parent, text = vim.trim(text) })
    return session_log:user(vim.trim(text), at)
  end
  -- a subagent's prompts come from the session that started it, the first starting it
  session_log:message(
    { from = child.parent.name, uri = child.parent.uri, kind = not child.spawned and 'spawn' or nil, text = text },
    at
  )
  child.spawned = true
end

--- @class otto.ClaudeHandle : otto.Handle
--- @field id string
--- @field file string Of the session, in the folder that Claude Code started in
--- @field proc otto.Proc
--- @field log otto.Log
--- @field state otto.ClaudeState
--- @field on_status fun(status: otto.Status)
--- @field init? table Response to `initialize`, with the commands and models
--- @field init_error? string When `initialize` failed
--- @field waiting fun()[] Waiting for `init`
--- @field model string
--- @field effort string like "high", which Claude Code only writes to the session file
--- @field working boolean
--- @field thinking boolean
--- @field queue { text: string, uuid: string }[] Prompts that Claude Code hasn't read yet, which it doesn't report
--- @field taken table<string, true> Prompts that rendered when Claude Code took them, until it echoes them
--- @field tasks table<string, otto.Background | { background: boolean }> Subagents and commands that run, by task
--- @field notifications table[] Ends of subagents and commands that Claude Code hasn't read yet
local Handle = {}
Handle.__index = Handle

local task_kinds = { local_agent = 'subagent', remote_agent = 'subagent', local_workflow = 'subagent' }

--- @param task table Of `task_started` or `background_tasks_changed`
--- @return otto.Background | { background: boolean }
function Handle:new_task(task)
  local kind = task_kinds[task.task_type] or 'command'
  return {
    id = task.task_id,
    kind = kind,
    name = task.description or task.task_id,
    call_id = task.tool_use_id,
    since = vim.uv.now(),
    background = task.is_backgrounded ~= false,
    -- remote agents have no file here
    uri = task.task_type == 'local_agent' and ('claude://%s/%s'):format(self.id, task.task_id) or nil,
  }
end

--- Adds the ends of subagents and commands that Claude Code read
function Handle:flush()
  for _, notification in ipairs(self.notifications) do
    notify(self.log, self.state, notification, notification.at)
  end
  self.notifications = {}
end

function Handle:background_update()
  local list = vim.tbl_values(self.tasks)
  table.sort(list, function(a, b)
    if a.kind ~= b.kind then return a.kind == 'subagent' end
    return a.since < b.since
  end)
  self.on_status({ type = 'background', background = list })
end

--- Claude Code reports what runs beside the conversation, and adds their ends to it
--- @param msg table system message
function Handle:task(msg)
  local tasks = self.tasks
  if msg.subtype == 'background_tasks_changed' then
    local running = {}
    for _, task in ipairs(msg.tasks or {}) do
      running[task.task_id] = true
      tasks[task.task_id] = tasks[task.task_id] or self:new_task(task)
    end
    -- which lists only those in the background
    for id, task in pairs(tasks) do
      if task.background and not running[id] then tasks[id] = nil end
    end
  elseif msg.subtype == 'task_started' then
    local task = self:new_task(msg)
    task.since = (tasks[msg.task_id] or task).since
    tasks[msg.task_id] = task
  elseif msg.subtype == 'task_progress' and tasks[msg.task_id] then
    local task = tasks[msg.task_id]
    local usage = msg.usage or {}
    task.activity, task.tools, task.tokens = msg.last_tool_name or task.activity, usage.tool_uses, usage.total_tokens
  elseif msg.subtype == 'task_updated' then
    local status = (msg.patch or {}).status
    if status ~= nil and status ~= 'running' and status ~= 'pending' then tasks[msg.task_id] = nil end
  elseif msg.subtype == 'task_notification' then
    local task = tasks[msg.task_id]
    tasks[msg.task_id] = nil
    -- which end with their tool's result instead, unlike those in the background
    if msg.is_backgrounded == false or task and not task.background then return self:background_update() end
    -- until Claude Code reads it, which starts a turn, where its file has it
    msg.at = event.now()
    table.insert(self.notifications, msg)
  end
  self:background_update()
end

--- @param request table
--- @return fun(id: integer): table
local function control(request)
  return function(id) return { type = 'control_request', request_id = tostring(id), request = request } end
end

--- @param request table
--- @param callback? fun(err?: string, data?: table) Notifies errors by default
function Handle:control(request, callback) self.proc:request(control(request), callback) end

--- @async
--- @param request table
--- @return table?
function Handle:call(request) return self.proc:call(control(request)) end

--- @async
--- @return table response to `initialize`
function Handle:initialized()
  if self.init == nil and self.init_error == nil then
    vim.async.await(1, function(done) table.insert(self.waiting, done) end)
  end
  return self.init or error(self.init_error, 0)
end

function Handle:queue_update()
  local texts = vim.tbl_map(function(queued) return queued.text end, self.queue)
  self.on_status({ type = 'queue', steering = texts, follow_up = {} })
end

--- @param working boolean
function Handle:set_working(working)
  self.working = working
  self.thinking = false
  self.on_status({ type = 'working', state = working and 'working' or nil })
end

--- Claude Code echoes prompts once it reads them, see `--replay-user-messages`
--- @param text string
function Handle:read(text)
  local index = vim.iter(ipairs(self.queue)):find(function(_, queued) return queued.text == text end)
  if index == nil then return end
  table.remove(self.queue, index)
  self:queue_update()
  -- after an interrupt, Claude Code starts on the queued prompts itself
  if not self.working then self:set_working(true) end
end

--- Claude Code takes a prompt when it starts a turn with it, but only echoes it with the answer's first block, so it
--- renders when it's taken
--- @param uuid string
function Handle:take(uuid)
  local index = vim.iter(ipairs(self.queue)):find(function(_, queued) return queued.uuid == uuid end)
  if index == nil then return end
  local text = table.remove(self.queue, index).text
  self:queue_update()
  self.taken[uuid] = true
  table.insert(self.state.prompts, { uuid = uuid, parent = self.state.last, text = vim.trim(text) })
  self.log:user(vim.trim(text))
  -- like a follow-up, which starts after the turn that it waited for
  if not self.working then self:set_working(true) end
end

--- Claude Code asks before using tools, unless it's been allowed to
--- @param msg table control_request
function Handle:permission(msg)
  local request = msg.request
  local suggestions = request.permission_suggestions or {}
  local items = { 'Allow', 'Deny' }
  if #suggestions > 0 then table.insert(items, 2, 'Always allow') end
  local prompt = ('Claude wants to use %s %s: '):format(
    request.display_name or request.tool_name,
    request.description or ''
  )
  self.on_status({
    type = 'request',
    kind = 'select',
    prompt = prompt,
    items = items,
    respond = function(choice)
      local response = { behavior = 'deny', message = 'The user denied this' }
      if choice == 'Allow' or choice == 'Always allow' then
        response = {
          behavior = 'allow',
          updatedInput = request.input,
          updatedPermissions = choice == 'Always allow' and suggestions or nil,
        }
      end
      self.proc:send({
        type = 'control_response',
        response = { subtype = 'success', request_id = msg.request_id, response = response },
      })
    end,
  })
end

--- @param msg table
function Handle:on_message(msg)
  if msg.type == 'control_response' then
    local response = msg.response
    self.proc:respond(response.request_id, response.subtype == 'error' and response.error or nil, response.response)
  elseif msg.type == 'control_request' and msg.request.subtype == 'can_use_tool' then
    self:permission(msg)
  elseif msg.type == 'control_request' then
    -- which Claude Code would wait for
    local message = msg.request.subtype .. ' is not supported by otto'
    local response = { subtype = 'error', request_id = msg.request_id, error = message }
    self.proc:send({ type = 'control_response', response = response })
  elseif msg.type == 'system' then
    if msg.subtype == 'init' then
      self.model = msg.model
      self.on_status({ type = 'info', model = msg.model })
      self:flush()
    end
    if msg.subtype == 'status' and msg.status == 'compacting' then
      self.on_status({ type = 'working', state = 'compacting' })
    end
    if msg.subtype == 'compact_boundary' then
      add(self.log, self.state, msg)
      self.on_status({ type = 'working', state = self.working and 'working' or nil })
    end
    if msg.subtype == 'session_title_changed' then self.log:info({ name = msg.title }) end
    if msg.subtype == 'background_tasks_changed' or vim.startswith(msg.subtype or '', 'task_') then self:task(msg) end
  elseif msg.type == 'command_lifecycle' then
    -- unlike prompts that steer the turn, which render when it reads them
    if msg.state == 'started' and not self.log.turn then self:take(msg.command_uuid) end
  elseif msg.type == 'user' and self.taken[msg.uuid] then
    self.taken[msg.uuid] = nil
  elseif msg.type == 'assistant' or msg.type == 'user' then
    if msg.type == 'user' and type(msg.message.content) == 'string' then self:read(msg.message.content) end
    add(self.log, self.state, msg)
  elseif msg.type == 'stream_event' and msg.parent_tool_use_id == nil then
    local stream = msg.event
    if stream.type == 'content_block_start' and stream.content_block.type == 'thinking' then
      self.thinking = true
      self.on_status({ type = 'working', state = 'thinking' })
    elseif stream.type == 'content_block_stop' and self.thinking then
      self.thinking = false
      self.on_status({ type = 'working', state = 'working' })
    end
  elseif msg.type == 'result' then
    local usage = (msg.modelUsage or {})[self.model] or select(2, next(msg.modelUsage or {}))
    if usage then self.on_status({ type = 'info', window = usage.contextWindow }) end
    self.log:settle(msg.subtype == 'error_during_execution')
    self:set_working(false)
    -- subagents that the turn waited for, which only the background ones outlive
    for id, task in pairs(self.tasks) do
      if not task.background then self.tasks[id] = nil end
    end
    self:background_update()
  end
end

--- The history from the session file
--- @async
function Handle:replay()
  local file = self.file
  -- a fork, which Claude Code only saves once it's prompted, shows the session it forked up to where it did
  local fork = forks[self.id]
  if vim.uv.fs_stat(file) == nil and fork and fork.at then file = session_file(fork.session) end
  if vim.uv.fs_stat(file) == nil then return end
  for line in io.lines(file) do
    local entry
    -- like the stream, one bad line, like the last while it's written, doesn't lose the lines after it
    local ok, err = pcall(function()
      entry = vim.json.decode(line, { luanil = { object = true, array = true } })
      add(self.log, self.state, entry)
    end)
    if not ok then util.notify('claude: ' .. tostring(err)) end
    if file ~= self.file and entry and entry.uuid == fork.at then break end
  end
  self.log:finish()
end

--- @param text string
function Handle:prompt(text)
  local uuid = util.uuid() -- which cancels it while it's queued
  self.proc:send({ type = 'user', uuid = uuid, message = { role = 'user', content = text } })
  if not self.working then self:set_working(true) end
  -- commands render as their output
  if vim.startswith(text, '/') then return end
  table.insert(self.queue, { text = text, uuid = uuid })
  self:queue_update()
end

function Handle:abort() self:control({ subtype = 'interrupt' }) end

--- @async
--- @return string[]
--- @param last? boolean Only the newest
function Handle:take_queue(last)
  local texts = {}
  -- newest first, while it's waited on
  for i = #self.queue, 1, -1 do
    local queued = self.queue[i]
    -- unless Claude Code read it already, which then answers it
    if queued and self:call({ subtype = 'cancel_async_message', message_uuid = queued.uuid }).cancelled then
      table.insert(texts, 1, queued.text)
      self.queue = vim.tbl_filter(function(other) return other ~= queued end, self.queue)
      if last then break end
    end
  end
  self:queue_update()
  return texts
end

--- @async
--- @param instructions? string
function Handle:compact(instructions) self:prompt(vim.trim('/compact ' .. (instructions or ''))) end

--- @async
--- @return string[]
function Handle:models()
  -- aliases like "opus" resolve to the same model as "default"
  local ids = {}
  for _, model in ipairs(self:initialized().models) do
    if not vim.list_contains(ids, model.resolvedModel) then table.insert(ids, model.resolvedModel) end
  end
  return ids
end

--- @async
--- @param model string
function Handle:set_model(model)
  self:call({ subtype = 'set_model', model = model })
  self.model = model
  self.on_status({ type = 'info', model = model })
end

--- @async
function Handle:cycle_effort()
  local model = vim.iter(self:initialized().models):find(function(option) return option.resolvedModel == self.model end)
  local levels = model and model.supportedEffortLevels or { 'low', 'medium', 'high' }
  local level = levels[(vim.fn.index(levels, self.effort) + 1) % #levels + 1]
  self:call({ subtype = 'apply_flag_settings', settings = { effortLevel = level } })
  self.effort = level
  self.on_status({ type = 'info', effort = level })
end

--- With Claude Code's /rename, which it runs after the turn that's running, without the model. Claude Code keeps the
--- name, and reports it as `session_title_changed`
--- @async
--- @param name string
function Handle:rename(name) self:prompt('/rename ' .. name) end

--- @async
--- @return otto.Command[]
function Handle:commands()
  return vim.tbl_map(
    function(command) return { name = command.name, description = command.description, args = command.argumentHint } end,
    self:initialized().commands
  )
end

--- @async
--- @return { id: string, text: string }[] prompts to fork from
function Handle:fork_points()
  return vim.tbl_map(function(prompt) return { id = prompt.uuid, text = prompt.text } end, self.state.prompts)
end

--- A new session from before the prompt, which starts once it's opened, see `M.open`
--- @async
--- @param id string Uuid of the prompt
--- @return { id: string, text: string }? the new session, and the prompt to edit
function Handle:fork(id)
  local prompt = vim.iter(self.state.prompts):find(function(prompt) return prompt.uuid == id end)
  if prompt == nil then return end
  -- of a fork that wasn't prompted yet, the session that it forked
  local session = vim.uv.fs_stat(self.file) and self.id or (forks[self.id] or {}).session or self.id
  local fork = util.uuid()
  forks[fork] = { session = session, at = prompt.parent }
  return { id = fork, text = prompt.text }
end

--- @async
--- @param id string Of the task
function Handle:stop_task(id) self:call({ subtype = 'stop_task', task_id = id }) end

function Handle:close() self.proc:close() end

--- A subagent's session, read from its file and followed while Claude Code writes it, without a process of its own
--- @class otto.ClaudeChild : otto.Handle
--- @field uri string
--- @field file string
--- @field meta string Of the subagent, which says when it finished
--- @field offset integer Bytes of the file read so far
--- @field log otto.Log
--- @field state otto.ClaudeState
--- @field on_status fun(status: otto.Status)
--- @field timer? uv.uv_timer_t While it's followed
local Child = { read_only = true }
Child.__index = Child

--- @return table
function Child:metadata()
  local file = io.open(self.meta, 'r')
  if file == nil then return {} end
  local ok, meta = pcall(vim.json.decode, file:read('*a'))
  file:close()
  return ok and type(meta) == 'table' and meta or {}
end

--- Adds what Claude Code wrote since the last read
function Child:read()
  local file = io.open(self.file, 'r')
  if file == nil then return end
  file:seek('set', self.offset)
  local data = file:read('*a')
  file:close()
  -- up to the last full line, since Claude Code may be writing one
  local last = data:match('.*()\n')
  if last == nil then return end
  self.offset = self.offset + last
  for line in data:sub(1, last):gmatch('[^\n]+') do
    local ok, err = pcall(
      function() add(self.log, self.state, vim.json.decode(line, { luanil = { object = true, array = true } })) end
    )
    if not ok then util.notify('claude: ' .. tostring(err)) end
  end
end

--- @return boolean
function Child:finished() return self:metadata().finished ~= nil or ended[self.uri] == true end

--- @async
function Child:replay()
  -- before reading, so that what it wrote before it finished is read
  local finished = self:finished()
  self:read()
  if finished then return self.log:finish() end
  self.on_status({ type = 'working', state = 'working' })
  self.timer = vim.uv.new_timer()
  self.timer:start(
    1000,
    1000,
    vim.schedule_wrap(function()
      if self.timer == nil then return end
      local finished = self:finished()
      self:read()
      if not finished then return end
      self.log:finish()
      self.on_status({ type = 'working' })
      self:close()
    end)
  )
end

local function read_only() error("subagents can't be prompted yet", 0) end
Child.prompt = function() util.notify("subagents can't be prompted yet", vim.log.levels.WARN) end
Child.abort = function() end
Child.take_queue = function() return {} end
Child.models = function() return {} end
Child.commands = function() return {} end
Child.compact, Child.set_model, Child.cycle_effort, Child.rename = read_only, read_only, read_only, read_only

function Child:close()
  if self.timer == nil then return end
  self.timer:close()
  self.timer = nil
end

--- @param session string
--- @param agent string
--- @param opts otto.OpenOpts
--- @return otto.ClaudeChild
local function open_child(session, agent, opts)
  local folder = (files[session] or session_file(session)):gsub('%.jsonl$', '') .. '/subagents/agent-' .. agent
  local parent = { name = 'parent', uri = 'claude://' .. session }
  local child = setmetatable({
    uri = ('claude://%s/%s'):format(session, agent),
    file = folder .. '.jsonl',
    meta = folder .. '.meta.json',
    offset = 0,
    log = log.new(opts.on_log, opts.on_status),
    state = new_state(session, { parent = parent }),
    on_status = opts.on_status,
  }, Child)
  local meta = child:metadata()
  opts.on_status({ type = 'info', name = meta.description, parent = parent.uri })
  return child
end

--- Starts Claude Code for the session, which it creates when it doesn't exist
--- @param id string UUID
--- @param opts otto.OpenOpts
--- @return otto.ClaudeHandle
function M.open(id, opts)
  local session, agent = id:match('^([^/]+)/(.+)$')
  if session ~= nil then return open_child(session, agent, opts) end
  --- @type otto.ClaudeHandle
  local handle = setmetatable({
    id = id,
    file = session_file(id),
    log = log.new(opts.on_log, opts.on_status),
    state = new_state(id),
    on_status = opts.on_status,
    waiting = {},
    model = opts.config.model,
    effort = opts.config.effort,
    working = false,
    thinking = false,
    queue = {},
    taken = {},
    tasks = {},
    notifications = {},
  }, Handle)

  files[id] = handle.file
  local exists = vim.uv.fs_stat(handle.file) ~= nil
  local fork = not exists and forks[id] or {}
  local args = {
    '-p',
    '--input-format=stream-json',
    '--output-format=stream-json',
    '--verbose',
    '--include-partial-messages', -- which say when it's thinking
    '--replay-user-messages', -- prompts render when Claude Code reads them
    '--permission-prompt-tool=stdio',
    '--disallowedTools=AskUserQuestion',
    '--permission-mode=' .. opts.config.permission_mode,
    '--model=' .. opts.config.model,
    '--effort=' .. opts.config.effort,
    exists and '--resume' or '--session-id',
    id,
  }
  -- which keeps the history up to and including the entry
  if fork.at then
    vim.list_extend(args, { '--resume', fork.session, '--resume-session-at', fork.at, '--fork-session' })
  end
  if opts.name ~= nil then vim.list_extend(args, { '--name', opts.name }) end
  handle.proc = proc.start_provider(opts.config, args, {
    name = 'claude',
    on_message = function(msg) handle:on_message(msg) end,
    on_exit = function()
      -- without the ends that Claude Code didn't read, which its file doesn't have
      handle.notifications = {}
      handle.queue = {}
      handle:queue_update()
      handle.log:settle(true)
      handle:set_working(false)
      handle.tasks = {}
      handle:background_update()
    end,
    -- inside Claude Code, CLAUDECODE would make it refuse to start
    env = { CLAUDECODE = '' },
  })
  -- an error raises in what waits for it, like the commands that every session loads
  handle:control({ subtype = 'initialize' }, function(err, response)
    handle.init, handle.init_error = response, err
    for _, waiting in ipairs(handle.waiting) do
      waiting()
    end
    handle.waiting = {}
  end)
  opts.on_status({ type = 'info', model = opts.config.model, effort = opts.config.effort, window = default_window })
  return handle
end

--- @param file string
--- @param modified integer
--- @return otto.SessionInfo
local function read(file, modified)
  local id = vim.fs.basename(file):gsub('%.jsonl$', '')
  local info = { provider = 'claude', id = id, messages = 0, modified = modified }
  local custom, ai, first_prompt
  for line in io.lines(file) do
    if line:find('"type":"custom-title"', 1, true) then
      custom = vim.json.decode(line).customTitle
    elseif line:find('"type":"ai-title"', 1, true) then
      ai = vim.json.decode(line).aiTitle
    elseif line:find('"type":"user"', 1, true) or line:find('"type":"assistant"', 1, true) then
      info.messages = info.messages + 1
      local content = first_prompt == nil
        and line:find('"type":"user"', 1, true)
        and vim.json.decode(line).message.content
      -- tool results and the output of local commands aren't prompts
      if type(content) == 'string' and not is_tagged(content) then first_prompt = content end
    end
  end
  info.name = custom or ai
  info.title = info.name or (first_prompt and vim.trim(first_prompt):gsub('%s+', ' ')) or id
  return info
end

--- @return { file: string, read: fun(file: string, modified: integer): otto.SessionInfo? }[]
function M.files()
  return vim.tbl_map(
    function(file) return { file = file, read = read } end,
    vim.fn.glob(vim.fs.dirname(session_file('')) .. '/*.jsonl', false, true)
  )
end

return M
