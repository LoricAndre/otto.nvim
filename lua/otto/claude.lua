-- Claude Code as a session backend: `claude -p` with stream-json in both directions, which this client translates to
-- the requests and events of pi's RPC mode, so the rest of the plugin doesn't tell them apart. History comes from
-- Claude Code's session files, since it only streams new messages

local rpc = require('otto.rpc')

local M = {}

local default_model = 'claude-opus-5-5'
local default_effort = 'high'
-- of the default model, until Claude Code reports the window of the one that answers
local default_window = 1000000

--- Claude Code's tools as pi's, which the transcript renders
local tools = {
  Read = function(input) return 'read', { path = input.file_path, offset = input.offset, limit = input.limit } end,
  Edit = function(input) return 'edit', { path = input.file_path } end,
  MultiEdit = function(input) return 'edit', { path = input.file_path } end,
  Write = function(input) return 'write', { path = input.file_path, content = input.content } end,
  Bash = function(input) return 'bash', { command = input.command, description = input.description } end,
  Grep = function(input) return 'grep', { pattern = input.pattern, path = input.path } end,
  Glob = function(input) return 'find', { pattern = input.pattern, path = input.path } end,
  WebSearch = function(input) return 'web_search', { query = input.query } end,
  WebFetch = function(input) return 'web_fetch', { urls = { input.url } } end,
}

--- @param id string
--- @return string
function M.session_file(id)
  return ('%s/.claude/projects/%s/%s.jsonl'):format(vim.env.HOME, (vim.fn.getcwd():gsub('[^%w]', '-')), id)
end

--- @return string random version 4 UUID, which Claude Code requires for session ids
function M.uuid()
  local hex = vim.iter({ vim.uv.random(16):byte(1, 16) }):map(function(byte) return ('%02x'):format(byte) end):join('')
  local variant = ('%x'):format(8 + tonumber(hex:sub(17, 17), 16) % 4)
  return ('%s-%s-4%s-%s%s-%s'):format(
    hex:sub(1, 8),
    hex:sub(9, 12),
    hex:sub(14, 16),
    variant,
    hex:sub(18, 20),
    hex:sub(21)
  )
end

--- Edits come with hunks, which become a diff like pi's, with a line number after the sign
--- @param patch { oldStart: integer, newStart: integer, lines: string[] }[]
--- @return string
local function diff(patch)
  local lines = {}
  for _, hunk in ipairs(patch) do
    local old = hunk.oldStart
    local new = hunk.newStart
    for _, line in ipairs(hunk.lines) do
      local sign = line:sub(1, 1)
      table.insert(lines, ('%s%d %s'):format(sign, sign == '-' and old or new, line:sub(2)))
      if sign ~= '+' then old = old + 1 end
      if sign ~= '-' then new = new + 1 end
    end
  end
  return table.concat(lines, '\n')
end

--- @param content string | table[]
--- @return string?
local function text_of(content)
  if type(content) == 'string' then return content end
  local texts = vim.tbl_filter(function(block) return block.type == 'text' end, content)
  if #texts > 0 then
    return vim.iter(texts):map(function(block) return block.text end):join('\n')
  end
end

--- @class otto.Compaction
--- @field before integer Tokens in the context
--- @field after? integer

--- @param usage table Of an answer
--- @return integer tokens in the context
local function context_tokens(usage)
  return usage.input_tokens + usage.cache_read_input_tokens + usage.cache_creation_input_tokens
end

--- Messages of pi for an entry of Claude Code, which are the same in its session files and its stream
--- @param entry table
--- @param compaction otto.Compaction The last one
--- @return table[] AgentMessage
local function messages(entry, compaction)
  if entry.isSidechain or entry.isMeta or entry.message == nil then return {} end
  local content = entry.message.content
  if entry.type == 'assistant' then
    local parts = {}
    for _, block in ipairs(content) do
      if block.type == 'text' then table.insert(parts, { type = 'text', text = block.text }) end
      if block.type == 'tool_use' then
        local name, args = (tools[block.name] or function(input) return block.name, input end)(block.input)
        table.insert(parts, { type = 'toolCall', id = block.id, name = name, arguments = args })
      end
    end
    return { { role = 'assistant', content = parts } }
  end

  if entry.isCompactSummary or entry.isSynthetic then
    local summary = text_of(content)
    return {
      {
        role = 'compactionSummary',
        summary = summary,
        tokensBefore = compaction.before,
        tokensAfter = compaction.after,
      },
    }
  end
  local results = {}
  for _, block in ipairs(type(content) == 'table' and content or {}) do
    if block.type == 'tool_result' then
      local details = entry.toolUseResult or entry.tool_use_result or {}
      local patch = vim.tbl_get(details, 'structuredPatch')
      -- reads number their lines, unlike pi's, but come with the file's content too
      local file = #content == 1 and vim.tbl_get(details, 'file', 'content') or nil
      table.insert(results, {
        role = 'toolResult',
        toolCallId = block.tool_use_id,
        content = file or text_of(block.content) or '',
        isError = block.is_error,
        details = patch and { diff = diff(patch) },
      })
    end
  end
  if #results > 0 then return results end
  -- the output of local commands, like /compact, and notes like "[Request interrupted by user]" are messages too
  local text = text_of(content)
  if text == nil or vim.startswith(text, '<') or vim.startswith(text, '[Request interrupted') then return {} end
  return { { role = 'user', content = text } }
end

--- @class otto.ClaudeClient
--- @field id string
--- @field proc vim.SystemObj
--- @field closed boolean
--- @field seq integer
--- @field pending table<string, fun(err?: string, data?: table)> Control responses by request id
--- @field on_event fun(event: table)
--- @field init? table Response to `initialize`, with the commands and models
--- @field model string
--- @field effort string like "high", which Claude Code only writes to the session file
--- @field tokens? integer In the context, as of the last answer or compaction
--- @field window? integer Size of the context window
--- @field working boolean
--- @field queue { text: string, uuid: string }[] Prompts that Claude Code hasn't read yet, which it doesn't report
--- @field shown? string Prompt that rendered when it was sent, before Claude Code echoed it
--- @field compaction otto.Compaction The last one
local Client = {}
Client.__index = Client

--- @param msg table
function Client:send(msg)
  if self.proc:is_closing() then return rpc.notify('claude is not running') end
  self.proc:write(vim.json.encode(msg) .. '\n')
end

--- @param request table
--- @param callback? fun(err?: string, data?: table)
function Client:control(request, callback)
  self.seq = self.seq + 1
  local id = tostring(self.seq)
  self.pending[id] = callback or function(err)
    if err ~= nil then rpc.notify(err) end
  end
  self:send({ type = 'control_request', request_id = id, request = request })
end

--- @param text string
function Client:prompt(text)
  local working = self.working
  self.working = true
  local uuid = M.uuid() -- which cancels it while it's queued
  self:send({ type = 'user', uuid = uuid, message = { role = 'user', content = text } })
  if not working then self.on_event({ type = 'agent_start' }) end
  -- commands render as their output
  if vim.startswith(text, '/') then return end
  if working then
    table.insert(self.queue, { text = text, uuid = uuid })
    return self:queue_update()
  end
  -- Claude Code starts on it straight away, but takes a moment to echo it
  self.shown = text
  self.on_event({ type = 'message_end', message = { role = 'user', content = text } })
end

function Client:queue_update()
  local texts = vim.tbl_map(function(queued) return queued.text end, self.queue)
  self.on_event({ type = 'queue_update', steering = texts, followUp = {} })
end

--- Claude Code echoes prompts once it reads them, see `--replay-user-messages`
--- @param text string
--- @return boolean whether the prompt rendered already
function Client:read(text)
  if text == self.shown then
    self.shown = nil
    return true
  end
  local index = vim.iter(ipairs(self.queue)):find(function(_, queued) return queued.text == text end)
  if index == nil then return false end
  table.remove(self.queue, index)
  self:queue_update()
  -- after an interrupt, Claude Code starts on the queued prompts itself
  if not self.working then
    self.working = true
    self.on_event({ type = 'agent_start' })
  end
  return false
end

--- Claude Code asks before using tools, unless it's been allowed to
--- @async
--- @param request table can_use_tool
--- @return table response
local function permission(request)
  local choices = { 'Allow', 'Deny' }
  local suggestions = request.permission_suggestions or {}
  if #suggestions > 0 then table.insert(choices, 2, 'Always allow') end
  local prompt = ('Claude wants to use %s %s: '):format(
    request.display_name or request.tool_name,
    request.description or ''
  )
  local choice = rpc.select(choices, { prompt = prompt })
  if choice == 'Deny' or choice == nil then return { behavior = 'deny', message = 'The user denied this' } end
  return {
    behavior = 'allow',
    updatedInput = request.input,
    updatedPermissions = choice == 'Always allow' and suggestions or nil,
  }
end

--- Answers pi's requests, see `rpc.lua`
--- @param msg table
--- @param callback? fun(err?: string, data?: table)
function Client:request(msg, callback)
  callback = callback or function(err)
    if err ~= nil then rpc.notify(err) end
  end
  local id = self.id
  local handlers = {
    prompt = function() self:prompt(msg.message) end,
    abort = function() self:control({ subtype = 'interrupt' }) end,
    clear_queue = function()
      local texts = {}
      for _, queued in ipairs(self.queue) do
        self:control({ subtype = 'cancel_async_message', message_uuid = queued.uuid })
        table.insert(texts, queued.text)
      end
      self.queue = {}
      self:queue_update()
      return { steering = texts, followUp = {} }
    end,
    compact = function() self:prompt(vim.trim('/compact ' .. (msg.customInstructions or ''))) end,
    set_model = function()
      self:control({ subtype = 'set_model', model = msg.modelId }, function(err)
        if err == nil then self.model = msg.modelId end
        callback(err)
      end)
    end,
    cycle_thinking_level = function()
      local model = vim.iter(self.init.models):find(function(option) return option.resolvedModel == self.model end)
      local levels = model and model.supportedEffortLevels or { 'low', 'medium', 'high' }
      local level = levels[(vim.fn.index(levels, self.effort) + 1) % #levels + 1]
      self:control({ subtype = 'apply_flag_settings', settings = { effortLevel = level } }, function(err)
        if err ~= nil then return callback(err) end
        self.effort = level
        self.on_event({ type = 'thinking_level_changed', level = level })
        callback(nil, { level = level })
      end)
    end,
    set_session_name = function()
      -- like Claude Code's /rename, which is a turn of its own
      local file = assert(io.open(M.session_file(id), 'a'))
      file:write(vim.json.encode({ type = 'custom-title', customTitle = msg.name, sessionId = id }), '\n')
      file:close()
      self.on_event({ type = 'session_info_changed', name = msg.name })
    end,
    get_commands = function()
      local commands = vim.tbl_map(
        function(command) return { name = command.name, description = command.description, args = command.argumentHint } end,
        self.init.commands
      )
      return { commands = commands }
    end,
    get_available_models = function()
      -- aliases like "opus" resolve to the same model as "default"
      local ids = {}
      for _, model in ipairs(self.init.models) do
        if not vim.list_contains(ids, model.resolvedModel) then table.insert(ids, model.resolvedModel) end
      end
      return { models = vim.tbl_map(function(model_id) return { provider = 'claude', id = model_id } end, ids) }
    end,
    get_messages = function()
      local all, tokens = M.history(id)
      -- until it answers again, the session's context is that of its last answer
      self.tokens = self.tokens or tokens
      return { messages = all }
    end,
    get_state = function()
      local file = M.session_file(id)
      local saved = vim.uv.fs_stat(file) and require('otto.resume').read_claude(file, 0)
      local model = { id = self.model, reasoning = true }
      return { sessionId = id, sessionName = saved and saved.name, model = model, thinkingLevel = self.effort }
    end,
    get_session_stats = function()
      local percent = self.tokens and self.window and self.tokens / self.window * 100
      -- Claude Code's cost is what the tokens would cost through the API, not what a subscription pays
      return { cost = 0, contextUsage = percent and { percent = percent } }
    end,
  }
  local handler = handlers[msg.type]
  if handler == nil then return callback(msg.type .. ' is not supported by claude') end
  -- commands and models arrive in the response to `initialize`
  if self.init == nil and (msg.type == 'get_commands' or msg.type == 'get_available_models') then
    return vim.defer_fn(function() self:request(msg, callback) end, 100)
  end
  local ok, data = pcall(handler)
  if not ok then return callback(tostring(data)) end
  if msg.type ~= 'set_model' and msg.type ~= 'cycle_thinking_level' then callback(nil, data) end
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

--- @param event table
function Client:on_output(event)
  if event.type == 'control_response' then
    local response = event.response
    local callback = self.pending[response.request_id]
    self.pending[response.request_id] = nil
    if callback ~= nil then callback(response.subtype == 'error' and response.error or nil, response.response) end
  elseif event.type == 'control_request' and event.request.subtype == 'can_use_tool' then
    rpc.run(function()
      local response = permission(event.request)
      self:send({
        type = 'control_response',
        response = { subtype = 'success', request_id = event.request_id, response = response },
      })
    end)
  elseif event.type == 'system' then
    if event.subtype == 'init' then self.model = event.model end
    if event.subtype == 'status' and event.status == 'compacting' then self.on_event({ type = 'compaction_start' }) end
    if event.subtype == 'compact_boundary' then
      local metadata = event.compact_metadata
      self.compaction = { before = metadata.pre_tokens, after = metadata.post_tokens }
      self.tokens = metadata.post_tokens or self.tokens
      self.on_event({ type = 'compaction_end' })
    end
    if event.subtype == 'session_title_changed' then self.on_event({ type = 'session_info_changed' }) end
  elseif event.type == 'assistant' or event.type == 'user' then
    if event.type == 'assistant' and event.message.usage then self.tokens = context_tokens(event.message.usage) end
    for _, message in ipairs(messages(event, self.compaction)) do
      if message.role ~= 'user' or not self:read(message.content) then
        self.on_event({ type = 'message_end', message = message })
      end
      for _, part in ipairs(message.role == 'assistant' and message.content or {}) do
        if part.type == 'toolCall' then
          self.on_event({
            type = 'tool_execution_start',
            toolCallId = part.id,
            toolName = part.name,
            args = part.arguments,
          })
        end
      end
    end
  elseif event.type == 'result' then
    local usage = (event.modelUsage or {})[self.model] or select(2, next(event.modelUsage or {}))
    if usage then self.window = usage.contextWindow end
    self.working = false
    self.on_event({ type = 'agent_settled', aborted = event.subtype == 'error_during_execution' })
  end
end

--- Starts Claude Code for the session, which it creates when it doesn't exist
--- @param id string UUID
--- @param on_event fun(event: table) like pi's, see `rpc.lua`
--- @param args string[] for claude
--- @return otto.ClaudeClient
function M.start(id, on_event, args)
  --- @type otto.ClaudeClient
  local client = setmetatable({
    id = id,
    closed = false,
    seq = 0,
    pending = {},
    on_event = on_event,
    working = false,
    queue = {},
    model = default_model,
    effort = default_effort,
    window = default_window,
    compaction = { before = 0 },
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

  local exists = vim.uv.fs_stat(M.session_file(id)) ~= nil
  local cmd = {
    'claude',
    '-p',
    '--input-format=stream-json',
    '--output-format=stream-json',
    '--verbose',
    '--replay-user-messages', -- prompts render when Claude Code reads them, like pi's
    '--permission-prompt-tool=stdio',
    '--disallowedTools=AskUserQuestion',
    '--permission-mode=auto', -- asks only for what its classifier doesn't allow
    '--model=' .. default_model,
    '--effort=' .. default_effort,
    exists and '--resume' or '--session-id',
    id,
    unpack(args),
  }
  -- inside Claude Code, CLAUDECODE would make it refuse to start
  local opts = { stdin = true, stdout = vim.schedule_wrap(on_stdout), env = { CLAUDECODE = '' } }
  local stderr
  opts.stderr = function(_, data) stderr = data or stderr end
  client.proc = vim.system(cmd, opts, function(out)
    if client.closed or out.code == 0 then return end
    vim.schedule(function() rpc.notify('claude exited: ' .. (stderr or out.code)) end)
  end)
  client:control({ subtype = 'initialize' }, function(err, response)
    if err ~= nil then return rpc.notify(err) end
    client.init = response
  end)
  return client
end

--- The session's messages, from its file
--- @param id string
--- @return table[] AgentMessage
--- @return integer? tokens in the context, as of the last answer or compaction
function M.history(id)
  if vim.uv.fs_stat(M.session_file(id)) == nil then return {} end
  local all = {}
  local tokens
  local compaction = { before = 0 }
  for line in io.lines(M.session_file(id)) do
    local entry = vim.json.decode(line, { luanil = { object = true, array = true } })
    if entry.subtype == 'compact_boundary' then
      local metadata = entry.compactMetadata or {}
      compaction = { before = metadata.preTokens or 0, after = metadata.postTokens }
      tokens = metadata.postTokens or tokens
    end
    if entry.type == 'assistant' and not entry.isSidechain and entry.message.usage then
      tokens = context_tokens(entry.message.usage)
    end
    vim.list_extend(all, messages(entry, compaction))
  end
  return all, tokens
end

return M
