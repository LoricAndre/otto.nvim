-- Run with: nvim --headless -u NONE --cmd 'set rtp+=/path/to/blink.lib' -l tests/events.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local count = 0
local function eq(expected, actual)
  assert(vim.deep_equal(expected, actual), 'expected ' .. vim.inspect(expected) .. ', got ' .. vim.inspect(actual))
  count = count + 1
end
local function pump()
  vim.wait(10, function() return false end)
end
local providers = require('otto.providers')
local real = vim.tbl_extend('force', {}, providers.providers)
local captures = {}
local rendered = {}
for _, name in ipairs({ 'pi', 'claude', 'codex' }) do
  providers.providers[name] = {
    name = name,
    open = function(_, opts)
      local handle = { opts = opts }
      function handle:close() self.closed = true end
      function handle:replay() opts.on_log({ type = 'user', text = 'history', at = 1 }) end
      function handle:commands() return {} end
      table.insert(captures, handle)
      return handle
    end,
  }
end
package.loaded['otto.ui.lsp'] = { attach = function() end }
require('otto.config').set({ keymaps = false })
local sessions = require('otto.session')
require('otto')
local received = {}
vim.api.nvim_create_autocmd('User', {
  pattern = 'Otto*',
  callback = function(args) table.insert(received, { pattern = args.match, data = args.data }) end,
})
local ok, err = xpcall(function()
  for _, backend in ipairs({ 'pi', 'claude', 'codex' }) do
    received, rendered = {}, {}
    vim.cmd.edit(backend .. '://event-test')
    local buf = vim.api.nvim_get_current_buf()
    local client = captures[#captures]
    pump()
    eq({
      {
        pattern = 'OttoSessionStart',
        data = { bufnr = buf, backend = backend, id = 'event-test', event = { type = 'session_start' } },
      },
    }, received)
    eq(true, vim.list_contains(vim.api.nvim_buf_get_lines(buf, 0, -1, false), 'history'))
    vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(true, false))
    local events = {
      { 'OttoAgentStart', { type = 'agent_start' } },
      { 'OttoMessageEnd', { type = 'message_end', message = { role = 'assistant', content = {} } } },
      {
        'OttoToolExecutionStart',
        { type = 'tool_execution_start', toolCallId = 'tool', toolName = 'read', args = {} },
      },
      { 'OttoCompactionStart', { type = 'compaction_start' } },
      { 'OttoCompactionEnd', { type = 'compaction_end' } },
      { 'OttoQueueUpdate', { type = 'queue_update', steering = {}, followUp = {} } },
      { 'OttoAgentSettled', { type = 'agent_settled', aborted = true } },
    }
    for _, item in ipairs(events) do
      client.opts.on_event(item[2])
      eq(
        { pattern = item[1], data = { bufnr = buf, backend = backend, id = 'event-test', event = item[2] } },
        received[#received]
      )
    end
    local mutate = vim.api.nvim_create_autocmd('User', {
      pattern = 'OttoMessageEnd',
      callback = function(args) args.data.event.message.role = 'changed' end,
    })
    client.opts.on_event(events[2][2])
    eq('assistant', events[2][2].message.role)
    vim.api.nvim_del_autocmd(mutate)
    local failing = vim.api.nvim_create_autocmd('User', {
      pattern = 'OttoMessageEnd',
      callback = function() error('test callback failure') end,
    })
    client.opts.on_event(events[2][2])
    eq(true, vim.v.errmsg:find('test callback failure', 1, true) ~= nil)
    vim.v.errmsg = ''
    vim.api.nvim_del_autocmd(failing)
    client.opts.on_event(events[7][2])
    eq('OttoAgentSettled', received[#received].pattern)
    sessions.restart(buf)
    pump()
    local before = #received
    client.opts.on_event(events[1][2])
    client.opts.on_log({ type = 'user', text = 'stale', at = 1 })
    client.opts.on_status({ type = 'info', name = 'stale' })
    eq(before, #received)
    eq(nil, sessions.sessions[buf].state.name)
    eq(false, vim.list_contains(vim.api.nvim_buf_get_lines(buf, 0, -1, false), 'stale'))
    eq('OttoSessionStart', received[#received].pattern)
    local restarted = captures[#captures]
    vim.api.nvim_buf_delete(buf, { force = true })
    before = #received
    restarted.opts.on_event(events[1][2])
    pump()
    eq(before, #received)
  end

  -- No start event can come from a session removed before replay completes.
  received = {}
  local util = require('otto.util')
  local run = util.run
  local pending
  util.run = function(fn) pending = fn end
  vim.cmd.edit('pi://removed-before-ready')
  vim.api.nvim_buf_delete(0, { force = true })
  util.run = run
  pending()
  eq({}, received)

  -- Test the real provider adapters without starting any agent process.
  local proc, util = require('otto.proc'), require('otto.util')
  local start, run = proc.start_provider, util.run
  proc.start_provider = function()
    return { send = function() end, request = function() end, close = function() end }
  end
  util.run = function() end
  local log, statuses, events = {}, {}, {}
  local opts = {
    config = { cmd = { 'agent' }, args = {}, env = {} },
    on_log = function(event) table.insert(log, event) end,
    on_status = function(status) table.insert(statuses, status) end,
    on_event = function(event) table.insert(events, event) end,
  }
  local function last(kind)
    for i = #events, 1, -1 do
      if events[i].type == kind then return events[i] end
    end
    error('missing event: ' .. kind)
  end
  for _, backend in ipairs({ 'pi', 'claude', 'codex' }) do
    log, statuses, events = {}, {}, {}
    opts.config = require('otto.config').providers[backend]
    local handle = real[backend].open('adapter-test', opts)
    if backend == 'pi' then
      handle:on_message({ type = 'agent_start' })
      handle:on_message({
        type = 'message_end',
        message = { role = 'assistant', content = { { type = 'text', text = 'answer' } } },
      })
      handle:on_message({ type = 'tool_execution_start', toolCallId = 'tool', toolName = 'read', args = {} })
      handle:on_message({ type = 'compaction_start' })
      handle:on_message({ type = 'compaction_end' })
      handle:on_message({ type = 'queue_update', steering = {}, followUp = {} })
      handle:on_message({ type = 'agent_settled', aborted = true })
    elseif backend == 'claude' then
      handle:prompt('hello')
      handle:on_message({
        type = 'assistant',
        uuid = 'answer',
        message = {
          role = 'assistant',
          content = {
            { type = 'text', text = 'answer' },
            { type = 'tool_use', id = 'tool', name = 'Read', input = { file_path = 'file' } },
          },
        },
      })
      eq('text', log[1].type)
      eq('assistant', last('message_end').message.role)
      handle:on_message({
        type = 'user',
        uuid = 'result',
        message = {
          content = {
            { type = 'tool_result', tool_use_id = 'tool', content = 'output', is_error = false },
          },
        },
      })
      eq('toolResult', last('message_end').message.role)
      eq('output', last('message_end').message.content)
      handle:on_message({ type = 'system', subtype = 'status', status = 'compacting' })
      handle:on_message({ type = 'system', subtype = 'compact_boundary', compact_metadata = { pre_tokens = 10 } })
      handle:on_message({ type = 'result', subtype = 'error_during_execution' })
    else
      handle:on_message({ method = 'turn/started', params = { turn = { id = 'turn' } } })
      handle:on_message({
        method = 'item/started',
        params = { item = { type = 'mcpToolCall', id = 'tool', tool = 'read', arguments = {} } },
      })
      handle:on_message({
        method = 'item/completed',
        params = { turnId = 'turn', item = { type = 'agentMessage', text = 'answer' } },
      })
      eq('answer', log[#log].text)
      handle:on_message({
        method = 'item/completed',
        params = {
          turnId = 'turn',
          item = {
            type = 'mcpToolCall',
            id = 'tool',
            tool = 'read',
            arguments = {},
            result = { content = 'output' },
          },
        },
      })
      eq('toolResult', last('message_end').message.role)
      eq('output', last('message_end').message.content)
      handle:on_message({ method = 'item/started', params = { item = { type = 'contextCompaction' } } })
      handle:on_message({
        method = 'item/completed',
        params = { turnId = 'turn', item = { type = 'contextCompaction' } },
      })
      handle:on_message({ method = 'turn/completed', params = { turn = { status = 'interrupted' } } })
    end
    eq('agent_start', last('agent_start').type)
    eq('tool', last('tool_execution_start').toolCallId)
    eq('read', last('tool_execution_start').toolName)
    eq('compaction_start', last('compaction_start').type)
    eq('compaction_end', last('compaction_end').type)
    eq({}, last('queue_update').followUp)
    eq(true, last('agent_settled').aborted)
    eq(nil, statuses[#statuses].state)
    handle:close()
  end
  proc.start_provider, util.run = start, run
end, debug.traceback)
providers.providers = real
if not ok then
  io.stderr:write(err .. '\n')
  vim.cmd('cquit 1')
end
print(('Passed %d event checks'):format(count))
vim.cmd('qa!')
