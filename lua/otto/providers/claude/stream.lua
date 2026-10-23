-- Claude Code's process: `claude -p` with stream-json in both directions, see `decode.lua` for its entries

local decode = require('otto.providers.claude.decode')
local event = require('otto.event')
local files = require('otto.providers.claude.files')
local log = require('otto.providers.log')
local proc = require('otto.proc')
local util = require('otto.util')

local M = {}

--- @type table<string, { session: string, at?: string }> Forks by id, until they're prompted, which saves them
local forks = {}

-- of the default model, until Claude Code reports the window of the one that answers
local default_window = 1000000

--- @class otto.ClaudeHandle : otto.Handle
--- @field id string
--- @field file string Of the session, in the folder that Claude Code started in
--- @field proc otto.Proc
--- @field log otto.Log
--- @field state otto.ClaudeState
--- @field on_state fun(patch: otto.StatePatch)
--- @field on_request fun(request: otto.Request)
--- @field init? table Response to `initialize`, with the commands and models
--- @field init_error? string When `initialize` failed
--- @field waiting fun()[] Waiting for `init`
--- @field model string
--- @field effort string like "high", which Claude Code only writes to the session file
--- @field working boolean
--- @field thinking boolean
--- @field queue { text: string, uuid: string }[] Prompts that Claude Code hasn't read yet, which it doesn't report
--- @field taken table<string, true> Prompts that rendered when Claude Code took them, until it echoes them
--- @field foreground table<string, true> Subagents that the turn waits for, by task, which end with their tool's result
--- @field notifications table[] Ends of subagents and commands in the background that Claude Code hasn't read yet
local Handle = {}
Handle.__index = Handle

--- Adds the ends of subagents and commands that Claude Code read
function Handle:flush()
  for _, notification in ipairs(self.notifications) do
    decode.notify(self.log, self.state, notification, notification.at)
  end
  self.notifications = {}
end

--- Claude Code adds the ends of what runs in the background to the conversation, once it reads them
--- @param msg table system message
function Handle:task(msg)
  if msg.subtype == 'task_started' and msg.is_backgrounded == false then
    self.foreground[msg.task_id] = true
  elseif msg.subtype == 'background_tasks_changed' then
    for _, task in ipairs(msg.tasks or {}) do
      self.foreground[task.task_id] = nil
    end
  elseif msg.subtype == 'task_notification' then
    local foreground = msg.is_backgrounded == false or self.foreground[msg.task_id]
    self.foreground[msg.task_id] = nil
    if foreground then return end
    -- until Claude Code reads it, which starts a turn, where its file has it
    msg.at = event.now()
    table.insert(self.notifications, msg)
  end
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
  self.on_state({ queue = event.queued(texts) })
end

--- @param working boolean
function Handle:set_working(working)
  self.working = working
  self.thinking = false
  self.on_state({ working = working and 'working' })
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
  self.on_request({
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
      self.on_state({ model = msg.model })
      self:flush()
    end
    if msg.subtype == 'status' and msg.status == 'compacting' then self.on_state({ working = 'compacting' }) end
    if msg.subtype == 'compact_boundary' then
      decode.add(self.log, self.state, msg)
      self.on_state({ working = self.working and 'working' })
    end
    if msg.subtype == 'session_title_changed' then self.log:state({ name = msg.title }) end
    if msg.subtype == 'background_tasks_changed' or vim.startswith(msg.subtype or '', 'task_') then self:task(msg) end
  elseif msg.type == 'command_lifecycle' then
    -- unlike prompts that steer the turn, which render when it reads them
    if msg.state == 'started' and not self.log.turn then self:take(msg.command_uuid) end
  elseif msg.type == 'user' and self.taken[msg.uuid] then
    self.taken[msg.uuid] = nil
  elseif msg.type == 'assistant' or msg.type == 'user' then
    if msg.type == 'user' and type(msg.message.content) == 'string' then self:read(msg.message.content) end
    decode.add(self.log, self.state, msg)
  elseif msg.type == 'stream_event' and msg.parent_tool_use_id == nil then
    local stream = msg.event
    if stream.type == 'content_block_start' and stream.content_block.type == 'thinking' then
      self.thinking = true
      self.on_state({ working = 'thinking' })
    elseif stream.type == 'content_block_stop' and self.thinking then
      self.thinking = false
      self.on_state({ working = 'working' })
    end
  elseif msg.type == 'result' then
    local usage = (msg.modelUsage or {})[self.model] or select(2, next(msg.modelUsage or {}))
    if usage then self.on_state({ window = usage.contextWindow }) end
    self.log:settle(msg.subtype == 'error_during_execution')
    self:set_working(false)
    -- which only the background ones outlive
    self.foreground = {}
  end
end

--- The history from the session file
--- @async
function Handle:replay()
  local file = self.file
  -- a fork, which Claude Code only saves once it's prompted, shows the session it forked up to where it did
  local fork = forks[self.id]
  if vim.uv.fs_stat(file) == nil and fork and fork.at then file = files.session_file(fork.session) end
  if vim.uv.fs_stat(file) == nil then return end
  for line in io.lines(file) do
    local entry
    -- like the stream, one bad line, like the last while it's written, doesn't lose the lines after it
    local ok, err = pcall(function()
      entry = vim.json.decode(line, { luanil = { object = true, array = true } })
      decode.add(self.log, self.state, entry)
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
  self.on_state({ model = model })
end

--- @async
function Handle:cycle_effort()
  local model = vim.iter(self:initialized().models):find(function(option) return option.resolvedModel == self.model end)
  local levels = model and model.supportedEffortLevels or { 'low', 'medium', 'high' }
  local level = levels[(vim.fn.index(levels, self.effort) + 1) % #levels + 1]
  self:call({ subtype = 'apply_flag_settings', settings = { effortLevel = level } })
  self.effort = level
  self.on_state({ effort = level })
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

function Handle:close() self.proc:close() end
--- Starts Claude Code for the session, which it creates when it doesn't exist
--- @param id string UUID
--- @param opts otto.OpenOpts
--- @return otto.ClaudeHandle
function M.open(id, opts)
  --- @type otto.ClaudeHandle
  local handle = setmetatable({
    id = id,
    file = files.session_file(id),
    log = log.new(opts.on_log, opts.on_state),
    state = decode.new_state(),
    on_state = opts.on_state,
    on_request = opts.on_request,
    waiting = {},
    model = opts.config.model,
    effort = opts.config.effort,
    working = false,
    thinking = false,
    queue = {},
    taken = {},
    foreground = {},
    notifications = {},
  }, Handle)

  files.started[id] = handle.file
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
      handle.foreground = {}
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
  opts.on_state({ model = opts.config.model, effort = opts.config.effort, window = default_window })
  return handle
end

return M
