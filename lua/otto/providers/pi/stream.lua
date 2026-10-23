-- pi's process: `pi --mode rpc`, JSONL commands on stdin, and responses and events on stdout, see `decode.lua` for
-- its messages
-- https://github.com/earendil-works/pi/blob/main/docs/rpc.md

local decode = require('otto.providers.pi.decode')
local event = require('otto.event')
local files = require('otto.providers.pi.files')
local log = require('otto.providers.log')
local proc = require('otto.proc')
local util = require('otto.util')

local M = {}

--- @class otto.PiHandle : otto.Handle
--- @field id string
--- @field proc otto.Proc
--- @field log otto.Log
--- @field state otto.PiState
--- @field on_state fun(patch: otto.StatePatch)
--- @field on_request fun(request: otto.Request)
--- @field working boolean
local Handle = {}
Handle.__index = Handle

--- @param msg table A command, see docs/rpc-commands.md
--- @return fun(id: integer): table
local function command(msg)
  return function(id) return vim.tbl_extend('force', msg, { id = tostring(id) }) end
end

--- @param msg table
--- @param callback? fun(err?: string, data?: table) Notifies errors by default
function Handle:request(msg, callback) self.proc:request(command(msg), callback) end

--- @async
--- @param msg table
--- @return table?
function Handle:call(msg) return self.proc:call(command(msg)) end

--- Answers pi's extension dialogs, see docs/rpc-extension-ui.md
--- @param request table
function Handle:dialog(request)
  if request.method == 'notify' then
    local levels = { warning = vim.log.levels.WARN, error = vim.log.levels.ERROR }
    return util.notify(request.message, levels[request.notifyType] or vim.log.levels.INFO)
  end
  local function respond(value)
    local key = request.method == 'confirm' and 'confirmed' or 'value'
    self.proc:send({ type = 'extension_ui_response', id = request.id, [key] = value, cancelled = value == nil or nil })
  end
  if request.method == 'input' or request.method == 'editor' then
    self.on_request({
      kind = 'input',
      prompt = request.title,
      default = request.prefill,
      respond = respond,
    })
  elseif request.method == 'select' then
    self.on_request({
      kind = 'select',
      prompt = request.title,
      items = request.options,
      respond = respond,
    })
  elseif request.method == 'confirm' then
    local prompt = request.title .. (request.message and ': ' .. request.message or '')
    self.on_request({ kind = 'confirm', prompt = prompt, respond = respond })
  end
end

--- @param working? 'working' | 'thinking' | 'compacting'
function Handle:set_working(working) self.on_state({ working = working or false }) end

--- @param msg table
function Handle:on_message(msg)
  if msg.type == 'response' then
    self.proc:respond(msg.id, not msg.success and msg.error or nil, msg.data)
  elseif msg.type == 'extension_ui_request' then
    self:dialog(msg)
  elseif msg.type == 'agent_start' then
    self.working = true
    self:set_working('working')
  elseif msg.type == 'agent_settled' then
    self.working = false
    self.log:settle(msg.aborted)
    self:set_working(nil)
  elseif msg.type == 'message_end' then
    decode.message(self.log, self.state, msg.message)
  elseif msg.type == 'message_update' then
    local update = msg.assistantMessageEvent.type
    if update == 'thinking_start' then self:set_working('thinking') end
    if update == 'thinking_end' then self:set_working('working') end
  elseif msg.type == 'compaction_start' then
    self:set_working('compacting')
  elseif msg.type == 'compaction_end' then
    -- compacting can happen while the agent works
    self:set_working(self.working and 'working' or nil)
    if msg.result ~= nil then
      self.log:compaction({ summary = msg.result.summary, before = msg.result.tokensBefore })
    end
  elseif msg.type == 'queue_update' then
    self.on_state({ queue = event.queued(msg.steering, msg.followUp) })
  elseif msg.type == 'session_info_changed' then
    self.log:state({ name = msg.name })
  elseif msg.type == 'thinking_level_changed' then
    self.log:state({ effort = msg.level })
  end
end

--- The history from the session file, along its current branch
--- @async
function Handle:replay()
  local file = files.session_file(self.id)
  if file == nil then return end
  local entries = {}
  local by_id = {}
  for line in io.lines(file) do
    -- one bad line, like the last while it's written, doesn't lose the lines after it
    local ok, entry = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
    if not ok then
      util.notify('pi: ' .. tostring(entry))
    elseif entry.id ~= nil and entry.type ~= 'session' then
      table.insert(entries, entry)
      by_id[entry.id] = entry
    end
  end
  local branch = {}
  local entry = entries[#entries]
  while entry ~= nil do
    table.insert(branch, 1, entry)
    entry = entry.parentId and by_id[entry.parentId]
  end

  for _, current in ipairs(branch) do
    local at = event.time(current.timestamp)
    if current.type == 'message' then
      decode.message(self.log, self.state, current.message, at)
    elseif current.type == 'compaction' then
      self.log:compaction({ summary = current.summary, before = current.tokensBefore }, at)
    elseif current.type == 'session_info' then
      self.log:state({ name = current.name })
    elseif current.type == 'model_change' then
      self.log:state({ model = current.modelId })
    elseif current.type == 'thinking_level_change' then
      self.log:state({ effort = current.thinkingLevel })
    end
  end
  self.log:finish()
end

--- @param text string
--- @param mode 'steer' | 'follow_up' While the agent works
--- @param on_error? fun(err: string)
function Handle:prompt(text, mode, on_error)
  local msg = { type = 'prompt', message = text, streamingBehavior = mode == 'follow_up' and 'followUp' or 'steer' }
  self:request(msg, function(err)
    if err ~= nil then (on_error or util.notify)(err) end
  end)
end

function Handle:abort() self:request({ type = 'abort' }) end

--- @async
--- @param last? boolean Only the newest
--- @return string[]
function Handle:take_queue(last)
  local queued = self:call({ type = 'clear_queue' })
  if not last then return vim.list_extend(vim.list_extend({}, queued.steering), queued.followUp) end
  -- pi only clears them all, so the others go back
  local newest = table.remove(#queued.followUp > 0 and queued.followUp or queued.steering)
  for _, text in ipairs(queued.steering) do
    self:prompt(text, 'steer')
  end
  for _, text in ipairs(queued.followUp) do
    self:prompt(text, 'follow_up')
  end
  return { newest }
end

--- @async
--- @param instructions? string
function Handle:compact(instructions) self:call({ type = 'compact', customInstructions = instructions }) end

--- @async
--- @return string[] like "openrouter/deepseek/deepseek-v4.1-flash"
function Handle:models()
  local models = self:call({ type = 'get_available_models' }).models
  return vim.tbl_map(function(model) return model.provider .. '/' .. model.id end, models)
end

--- @async
--- @param model string like "openrouter/deepseek/deepseek-v4.1-flash"
function Handle:set_model(model)
  local provider, id = model:match('^([^/]+)/(.+)$')
  local result = self:call({ type = 'set_model', provider = provider, modelId = id })
  self.on_state({ model = id, window = result and result.contextWindow })
end

--- @async
function Handle:cycle_effort()
  -- pi reports the level as `thinking_level_changed`
  self:call({ type = 'cycle_thinking_level' })
end

--- @async
--- @param name string
function Handle:rename(name) self:call({ type = 'set_session_name', name = name }) end

--- @async
--- @return otto.Command[]
function Handle:commands()
  return vim.tbl_map(
    function(command) return { name = command.name, description = command.description } end,
    self:call({ type = 'get_commands' }).commands
  )
end

--- @async
--- @return { id: string, text: string }[] prompts to fork from
function Handle:fork_points()
  return vim.tbl_map(
    function(point) return { id = point.entryId, text = point.text } end,
    self:call({ type = 'get_fork_messages' }).messages
  )
end

--- @async
--- @param id string Of the prompt
--- @return { id: string, text: string }? the new session, and the prompt to edit
function Handle:fork(id)
  local fork = self:call({ type = 'fork', entryId = id })
  if fork.cancelled then return end
  return { id = self:call({ type = 'get_state' }).sessionId, text = fork.text }
end

function Handle:close() self.proc:close() end

--- Starts pi for the session, which it creates when it doesn't exist
--- @param id string
--- @param opts otto.OpenOpts
--- @return otto.PiHandle
function M.open(id, opts)
  local args = { '--session-id', id }
  if opts.name ~= nil then vim.list_extend(args, { '--name', opts.name }) end

  --- @type otto.PiHandle
  local handle = setmetatable({
    id = id,
    log = log.new(opts.on_log, opts.on_state),
    state = { cost = 0 },
    on_state = opts.on_state,
    on_request = opts.on_request,
    working = false,
  }, Handle)
  handle.proc = proc.start_provider(opts.config, vim.list_extend({ '--mode', 'rpc' }, args), {
    name = 'pi',
    on_message = function(msg) handle:on_message(msg) end,
    on_exit = function()
      handle.log:settle(true)
      handle:set_working(nil)
    end,
  })
  util.run(function()
    local state = handle:call({ type = 'get_state' })
    local model = state.model or {}
    opts.on_state({
      name = state.sessionName,
      model = model.id,
      effort = model.reasoning and state.thinkingLevel or nil,
      window = model.contextWindow,
    })
  end)
  return handle
end

return M
