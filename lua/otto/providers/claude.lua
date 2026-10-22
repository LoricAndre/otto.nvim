-- Claude Code: `claude -p` with stream-json in both directions. Its session files and its stream hold the same
-- entries, which `entry` turns into the log

local event = require('otto.event')
local log = require('otto.providers.log')
local proc = require('otto.proc')
local util = require('otto.util')

local M = { name = 'claude', icon = '󰛄  ' }

local default_model = 'claude-opus-5-5'
local default_effort = 'high'
-- of the default model, until Claude Code reports the window of the one that answers
local default_window = 1000000

--- Claude Code's tools as otto's
local tools = {
  Read = function(input) return 'read', { path = input.file_path, offset = input.offset, limit = input.limit } end,
  Edit = function(input) return 'edit', { path = input.file_path } end,
  MultiEdit = function(input) return 'edit', { path = input.file_path } end,
  Write = function(input) return 'write', { path = input.file_path, content = input.content } end,
  Bash = function(input) return 'bash', { command = input.command, description = input.description } end,
  Grep = function(input) return 'grep', { pattern = input.pattern, path = input.path } end,
  Glob = function(input) return 'find', { pattern = input.pattern, path = input.path } end,
  WebSearch = function(input) return 'web_search', { query = input.query } end,
  WebFetch = function(input) return 'fetch', { urls = { input.url } } end,
}

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
  if entry.isSidechain or entry.isMeta or entry.parent_tool_use_id ~= nil then return end
  -- prompts that the agent read while it worked, which the stream echoes like the others
  local attachment = entry.attachment or {}
  if attachment.type == 'queued_command' and attachment.commandMode == 'prompt' then
    if type(attachment.prompt) == 'string' and not is_tagged(attachment.prompt) then
      session_log:user(vim.trim(attachment.prompt), at)
    end
    return
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
  -- like /compact from Claude Code's own UI, which renders as the compaction
  if is_tagged(text) or text == '/compact' or vim.startswith(text, '/compact ') then return end
  session_log:user(vim.trim(text), at)
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
local Handle = {}
Handle.__index = Handle

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
    end
    if msg.subtype == 'status' and msg.status == 'compacting' then
      self.on_status({ type = 'working', state = 'compacting' })
    end
    if msg.subtype == 'compact_boundary' then
      add(self.log, self.state, msg)
      self.on_status({ type = 'working', state = self.working and 'working' or nil })
    end
    if msg.subtype == 'session_title_changed' then self.log:info({ name = msg.title }) end
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
  end
end

--- The history from the session file
--- @async
function Handle:replay()
  local file = self.file
  if vim.uv.fs_stat(file) == nil then return end
  for line in io.lines(file) do
    -- like the stream, one bad line, like the last while it's written, doesn't lose the lines after it
    local ok, err = pcall(
      function() add(self.log, self.state, vim.json.decode(line, { luanil = { object = true, array = true } })) end
    )
    if not ok then util.notify('claude: ' .. tostring(err)) end
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
function Handle:take_queue()
  local texts = {}
  for _, queued in ipairs(vim.list_extend({}, self.queue)) do
    -- unless Claude Code read it already, which then answers it
    if self:call({ subtype = 'cancel_async_message', message_uuid = queued.uuid }).cancelled then
      table.insert(texts, queued.text)
      self.queue = vim.tbl_filter(function(other) return other ~= queued end, self.queue)
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

function Handle:close() self.proc:close() end

--- Starts Claude Code for the session, which it creates when it doesn't exist
--- @param id string UUID
--- @param opts otto.OpenOpts
--- @return otto.ClaudeHandle
function M.open(id, opts)
  --- @type otto.ClaudeHandle
  local handle = setmetatable({
    id = id,
    file = session_file(id),
    log = log.new(opts.on_log, opts.on_status),
    state = { compaction = {} },
    on_status = opts.on_status,
    waiting = {},
    model = default_model,
    effort = default_effort,
    working = false,
    thinking = false,
    queue = {},
  }, Handle)

  local exists = vim.uv.fs_stat(handle.file) ~= nil
  local cmd = {
    'claude',
    '-p',
    '--input-format=stream-json',
    '--output-format=stream-json',
    '--verbose',
    '--include-partial-messages', -- which say when it's thinking
    '--replay-user-messages', -- prompts render when Claude Code reads them
    '--permission-prompt-tool=stdio',
    '--disallowedTools=AskUserQuestion',
    '--permission-mode=auto', -- asks only for what its classifier doesn't allow
    '--model=' .. default_model,
    '--effort=' .. default_effort,
    exists and '--resume' or '--session-id',
    id,
  }
  if opts.name ~= nil then vim.list_extend(cmd, { '--name', opts.name }) end
  handle.proc = proc.start(cmd, {
    name = 'claude',
    on_message = function(msg) handle:on_message(msg) end,
    on_exit = function()
      handle.log:settle(true)
      handle:set_working(false)
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
  opts.on_status({ type = 'info', model = default_model, effort = default_effort, window = default_window })
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
