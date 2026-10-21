-- Run with: nvim --headless -u NONE -l tests/ui.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local config = require('otto.config')
local util = require('otto.util')
local sessions = require('otto.session')
package.loaded['otto.ui.lsp'] = { attach = function() end }
local otto = require('otto')
local function without_tasks(fn, ...)
  local run = util.run
  util.run = function() end
  fn(...)
  util.run = run
end
local function open(name) without_tasks(otto.new, name) end
local function restart(buf) without_tasks(sessions.restart, buf) end
local ui = require('otto.ui')
local system, select, input, notify = vim.system, vim.ui.select, vim.ui.input, vim.notify
local count = 0
local function eq(expected, actual)
  assert(vim.deep_equal(expected, actual), 'expected ' .. vim.inspect(expected) .. ', got ' .. vim.inspect(actual))
  count = count + 1
end
local function pump()
  vim.wait(20, function() return false end)
end
local captures = {}
vim.system = function(_, opts, on_exit)
  local capture = { opts = opts, on_exit = on_exit, writes = {} }
  table.insert(captures, capture)
  return {
    is_closing = function() return capture.killed or false end,
    write = function(_, data) table.insert(capture.writes, vim.json.decode(data)) end,
    kill = function() capture.killed = true end,
  }
end
local function feed(capture, event)
  event.type = event.type or 'extension_ui_request'
  event.id = event.id or 'request'
  capture.opts.stdout(nil, vim.json.encode(event) .. '\n')
  pump()
end
local function key(desc)
  local maps = vim.api.nvim_buf_get_keymap(0, 'n')
  local map = vim.iter(maps):find(function(item) return item.desc == desc end)
  assert(map ~= nil, desc)
  map.callback()
  pump()
end

local ok, err = xpcall(function()
  config.set({ picker = 'vim_ui', keymaps = false })
  open('ui-test')
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'draft' })
  vim.api.nvim_buf_set_lines(buf, 0, 0, false, { 'transcript', '' })
  local changes = 0
  vim.api.nvim_create_autocmd('User', {
    pattern = 'OttoUIChanged',
    callback = function(event)
      eq(buf, event.data.bufnr)
      changes = changes + 1
    end,
    group = vim.api.nvim_create_augroup('otto.ui.test', {}),
  })
  local client = sessions.sessions[buf].handle
  local capture = captures[#captures]
  feed(capture, { method = 'setStatus', statusKey = 'test', statusText = '\27[31m25%\27[0m\nnext' })
  eq('25% next', ui.get(buf).statuses.test)
  eq(ui.get(buf), ui.get())
  eq(ui.get(buf), ui.get(0))
  local copy = ui.get(buf)
  copy.statuses.test = 'changed'
  eq('25% next', ui.get(buf).statuses.test)
  feed(capture, { method = 'setTitle', title = 'Demo % title' })
  local bar = require('otto.ui.winbar').render(sessions.sessions[buf])
  eq(true, bar:find('25%% next', 1, true) ~= nil)
  eq(true, bar:find('Demo %% title', 1, true) ~= nil)
  feed(capture, { method = 'setWidget', widgetKey = 'above', widgetLines = { 'first', '\27[32msecond\27[0m' } })
  feed(
    capture,
    { method = 'setWidget', widgetKey = 'below', widgetLines = { 'last' }, widgetPlacement = 'belowEditor' }
  )
  eq({ 'first', 'second' }, ui.get(buf).widgets.above.lines)
  local ns = vim.api.nvim_get_namespaces()['otto.ui']
  local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
  eq(2, #marks)
  eq(true, marks[1][4].virt_lines_above)
  eq(false, marks[2][4].virt_lines_above)
  eq({ 'transcript', '', 'draft' }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  feed(capture, { method = 'set_editor_text', text = 'new\nprompt' })
  eq({ 'transcript', '', 'new', 'prompt' }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
  eq(3, marks[2][2]) -- below the complete multi-line prompt
  feed(capture, { method = 'setWidget', widgetKey = 'above', widgetLines = { 'replacement' } })
  eq({ 'replacement' }, ui.get(buf).widgets.above.lines)
  feed(capture, { method = 'setWidget', widgetKey = 'above' })
  eq(nil, ui.get(buf).widgets.above)
  feed(capture, { method = 'setStatus', statusKey = 'test' })
  eq(nil, ui.get(buf).statuses.test)
  eq(true, changes > 0)
  eq(0, #capture.writes) -- no responses to fire-and-forget methods
  vim.api.nvim_del_augroup_by_name('otto.ui.test')

  local notification
  vim.notify = function(message, level) notification = { message, level } end
  feed(capture, { method = 'notify', message = 'hello', notifyType = 'warning' })
  eq({ 'otto: hello', vim.log.levels.WARN }, notification)
  eq(0, #capture.writes)
  feed(capture, { method = 'future_method' })
  eq(0, #capture.writes)

  local choose
  vim.ui.select = function(items, opts, callback)
    eq('Choose', opts.prompt)
    eq({ 'same', 'same' }, items)
    choose = callback
  end
  feed(capture, { method = 'select', title = 'Choose', options = { 'same', 'same' } })
  choose('same', 2)
  pump()
  choose(nil) -- a frontend must not cause a duplicate response
  eq(1, #capture.writes)
  eq('same', capture.writes[1].value)
  eq('extension_ui_response', capture.writes[1].type)
  vim.ui.select = function(_, _, callback) callback(nil) end
  feed(capture, { method = 'select', title = 'Cancel', options = {} })
  eq(true, capture.writes[#capture.writes].cancelled)
  config.set({ picker = 'minibuffer' }) -- also use the configured minibuffer backend
  package.loaded['minibuffer.internal.state'] = { initialized = true }
  package.loaded.minibuffer = {
    select = function(opts)
      eq('Confirm: details', opts.prompt)
      opts.fetch_fn({}, function(items)
        eq({ 'Yes', 'No' }, items)
        opts.on_accept({ { item = items[2] } })
      end)
    end,
  }
  feed(capture, { method = 'confirm', title = 'Confirm', message = 'details' })
  eq(false, capture.writes[#capture.writes].confirmed)
  eq(nil, capture.writes[#capture.writes].cancelled)
  config.set({ picker = 'vim_ui' })
  local answer, input_opts
  vim.ui.input = function(opts, callback)
    input_opts, answer = opts, callback
  end
  feed(capture, { method = 'input', title = 'Input' })
  eq('Input\n> ', input_opts.prompt)
  answer('value')
  pump()
  eq('value', capture.writes[#capture.writes].value)
  feed(capture, { method = 'input', title = 'Question\nContext', prefill = 'draft' })
  eq('Question\nContext\n> ', input_opts.prompt)
  eq('draft', input_opts.default)
  answer('answer only')
  pump()
  eq('answer only', capture.writes[#capture.writes].value)
  feed(capture, { method = 'input', title = 'Input', timeout = 1 })
  local before = #capture.writes
  answer('too late')
  eq(before, #capture.writes)

  local original = vim.api.nvim_get_current_win()
  feed(capture, { method = 'editor', title = 'Edit', prefill = 'one\ntwo' })
  eq({ 'one', 'two' }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'edited', 'text' })
  key('Otto: accept editor')
  eq('edited\ntext', capture.writes[#capture.writes].value)
  eq(original, vim.api.nvim_get_current_win())
  feed(capture, { method = 'editor', title = 'Empty editor' })
  key('Otto: accept editor')
  eq('', capture.writes[#capture.writes].value)
  eq(nil, capture.writes[#capture.writes].cancelled)
  feed(capture, { method = 'editor', title = 'Cancel editor' })
  key('Otto: cancel editor')
  eq(true, capture.writes[#capture.writes].cancelled)
  feed(capture, { method = 'editor', title = 'Close window' })
  vim.api.nvim_win_close(0, true)
  pump()
  eq(true, capture.writes[#capture.writes].cancelled)
  before = #capture.writes
  feed(capture, { method = 'editor', title = 'Timeout', timeout = 1 })
  eq(original, vim.api.nvim_get_current_win())
  eq(before, #capture.writes)
  feed(capture, { method = 'editor', title = 'Process exit' })
  capture.on_exit({ code = 0 })
  pump()
  eq(original, vim.api.nvim_get_current_win())
  eq(before, #capture.writes)
  eq({}, ui.get(buf))
  eq({}, vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}))
  eq(true, client.closed)

  -- Route through actual Otto sessions, including restart and unload cleanup.
  open('ui-first')
  local first = vim.api.nvim_get_current_buf()
  local first_capture = captures[#captures]
  feed(first_capture, { method = 'setStatus', statusKey = 'one', statusText = 'first session' })
  feed(first_capture, { method = 'setWidget', widgetKey = 'one', widgetLines = { 'first widget' } })
  eq('first session', ui.get(first).statuses.one)
  feed(first_capture, { type = 'message_end', message = { role = 'user', content = 'A user message' } })
  local first_marks = vim.api.nvim_buf_get_extmarks(first, ns, 0, -1, { details = true })
  eq(1, #first_marks)
  eq(vim.api.nvim_buf_get_mark(first, ':')[1] - 1, first_marks[1][2])
  eq(true, first_marks[1][4].virt_lines_above)
  local lines = vim.api.nvim_buf_get_lines(first, 0, -1, false)
  eq(false, vim.list_contains(lines, 'first widget'))
  open('ui-second')
  local second = vim.api.nvim_get_current_buf()
  local second_capture = captures[#captures]
  feed(second_capture, { method = 'setStatus', statusKey = 'two', statusText = 'second session' })
  eq('first session', ui.get(first).statuses.one)
  eq(nil, ui.get(second).statuses.one)
  restart(first)
  eq({}, ui.get(first))
  feed(first_capture, { method = 'setStatus', statusKey = 'stale', statusText = 'ignore' })
  eq({}, ui.get(first))
  vim.api.nvim_buf_delete(second, { force = true })
  eq({}, ui.get(second))
  vim.api.nvim_set_current_buf(first)
  local restarted = captures[#captures]
  feed(restarted, { method = 'editor', title = 'Restart dialog' })
  before = #restarted.writes
  restart(first)
  eq(before, #restarted.writes)
  eq(first, vim.api.nvim_get_current_buf())
  vim.api.nvim_buf_delete(first, { force = true })
  vim.api.nvim_buf_delete(buf, { force = true })
  eq('', vim.v.errmsg)
end, debug.traceback)

vim.system, vim.ui.select, vim.ui.input, vim.notify = system, select, input, notify
if not ok then
  io.stderr:write(err .. '\n')
  vim.cmd('cquit 1')
end
print(('Passed %d UI checks'):format(count))
vim.cmd('qa!')
