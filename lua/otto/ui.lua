-- Native rendering for the data Pi exposes through its RPC extension UI protocol.
local M = {}
local ns = vim.api.nvim_create_namespace('otto.ui')
local states = {}

local function text(value)
  return value
    :gsub('\27%[[0-?]*[ -/]*[@-~]', '')
    :gsub('\27%].-\7', '')
    :gsub('\27%].-\27\\', '')
    :gsub('[%z\1-\31\127]', ' ')
end

--- A copy of the session's extension UI state, for statusline integrations.
--- @param bufnr? integer
function M.get(bufnr)
  if bufnr == nil or bufnr == 0 then bufnr = vim.api.nvim_get_current_buf() end
  return vim.deepcopy(states[bufnr] or {})
end

local function changed(bufnr)
  vim.cmd.redrawstatus({ bang = true })
  vim.api.nvim_exec_autocmds('User', { pattern = 'OttoUIChanged', data = { bufnr = bufnr } })
end

function M.clear(bufnr)
  if states[bufnr] == nil then return end
  states[bufnr] = nil
  if vim.api.nvim_buf_is_valid(bufnr) then vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1) end
  changed(bufnr)
end

--- Draw virtual lines without adding widget text to the transcript or prompt.
function M.draw(bufnr)
  local state = states[bufnr]
  if state == nil or not vim.api.nvim_buf_is_loaded(bufnr) then return end
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  local above, below = {}, {}
  local keys = vim.tbl_keys(state.widgets)
  table.sort(keys)
  for _, key in ipairs(keys) do
    local widget = state.widgets[key]
    local target = widget.placement == 'belowEditor' and below or above
    for _, line in ipairs(widget.lines) do
      table.insert(target, { { line, 'Normal' } })
    end
  end
  local row = math.max(0, vim.api.nvim_buf_get_mark(bufnr, ':')[1] - 1)
  if #above > 0 then
    vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, { virt_lines = above, virt_lines_above = true })
  end
  if #below > 0 then
    vim.api.nvim_buf_set_extmark(bufnr, ns, vim.api.nvim_buf_line_count(bufnr) - 1, 0, { virt_lines = below })
  end
end

--- Fire-and-forget methods never receive an extension_ui_response.
function M.handle(bufnr, event)
  if not vim.api.nvim_buf_is_loaded(bufnr) then return end
  local state = states[bufnr] or { statuses = {}, widgets = {} }
  states[bufnr] = state
  if event.method == 'setStatus' then
    state.statuses[event.statusKey] = event.statusText and text(event.statusText) or nil
  elseif event.method == 'setWidget' then
    state.widgets[event.widgetKey] = event.widgetLines
        and {
          lines = vim.tbl_map(text, event.widgetLines),
          placement = event.widgetPlacement or 'aboveEditor',
        }
      or nil
  elseif event.method == 'setTitle' then
    state.title = event.title and text(event.title) or nil
  elseif event.method == 'set_editor_text' then
    local row = math.max(0, vim.api.nvim_buf_get_mark(bufnr, ':')[1] - 1)
    vim.api.nvim_buf_set_lines(bufnr, row, -1, false, vim.split(event.text or '', '\n', { plain = true }))
  else
    return
  end
  M.draw(bufnr)
  require('otto.ui.prompt_area').follow(bufnr)
  changed(bufnr)
end

--- Multi-line editor dialog using a scratch buffer. Returns an idempotent cancel function.
function M.editor(opts, on_choice)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(opts.prefill or '', '\n', { plain = true }))
  local width = math.max(1, math.min(80, vim.o.columns - 4))
  local height = math.max(1, math.min(16, vim.o.lines - vim.o.cmdheight - 4))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    style = 'minimal',
    border = 'single',
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    title = text(opts.title or 'Edit text'),
    footer = 'Ctrl-S: accept · q/Esc: cancel (normal mode)',
  })
  vim.wo[win].wrap = true
  local done, timer, closed
  local function finish(value)
    if done then return end
    done = true
    if timer ~= nil then timer:close() end
    if closed ~= nil then vim.api.nvim_del_autocmd(closed) end
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
    on_choice(value)
  end
  local function cancel() finish(nil) end
  vim.keymap.set(
    { 'n', 'i' },
    '<C-s>',
    function() finish(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')) end,
    { buffer = buf, desc = 'Otto: accept editor' }
  )
  vim.keymap.set('n', 'q', cancel, { buffer = buf, desc = 'Otto: cancel editor' })
  vim.keymap.set('n', '<Esc>', cancel, { buffer = buf, desc = 'Otto: cancel editor' })
  closed = vim.api.nvim_create_autocmd({ 'BufWipeout', 'WinClosed' }, {
    callback = function(event)
      if
        (event.event == 'BufWipeout' and event.buf == buf)
        or (event.event == 'WinClosed' and tonumber(event.match) == win)
      then
        vim.schedule(cancel)
      end
    end,
  })
  if opts.timeout ~= nil then
    timer = vim.uv.new_timer()
    timer:start(opts.timeout, 0, vim.schedule_wrap(cancel))
  end
  return cancel
end

return M
