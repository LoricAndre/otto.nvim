-- Otto's commands, which its keymaps and the palette (<M-x>) run. The agents' own commands, like pi's extensions,
-- prompt templates and skills, are prompts like "/review", which the palette starts in the prompt

local cursor = require('otto.ui.cursor')
local history = require('otto.ui.history')
local pick = require('otto.ui.pick')
local prompts = require('otto.ui.prompts')
local util = require('otto.util')

local M = {}

--- @class otto.Command
--- @field name string
--- @field description? string
--- @field args? string Describes the argument, of the agents' commands
--- @field modes? string[] Of its keymaps, normal mode by default
--- @field expr? boolean Whether it returns the keys to run instead of running, which keeps it out of the palette
--- @field run? async fun(session: otto.Session): string? Otto's commands only
--- @field palette? false Whether the palette skips it, like for moving around
--- @field available? fun(session: otto.Session): boolean Commands that only some agents support
--- @field replaces? string[] The agents' commands that it does instead, besides the one of its name
--- @field prompts? boolean Whether it changes the prompt, which subagents' sessions can't take

--- Opens the location in the previous window, or this one when there's no other
--- @param target otto.Target
function M.open_target(target)
  -- sessions open in this window, so that <C-o> goes back
  if target.uri ~= nil then return vim.cmd.edit(target.uri) end
  local previous = vim.fn.win_getid(vim.fn.winnr('#'))
  if previous ~= 0 and previous ~= vim.api.nvim_get_current_win() then vim.api.nvim_set_current_win(previous) end
  vim.cmd.edit(vim.fn.fnameescape(target.path))
  if target.lnum ~= nil then
    vim.api.nvim_win_set_cursor(0, { math.max(math.min(target.lnum, vim.api.nvim_buf_line_count(0)), 1), 0 })
    vim.cmd('normal! zz')
  end
end

--- Puts queued prompts back above what the prompt holds, in the order they were sent
--- @param session otto.Session
--- @param texts string[]
local function take_back(session, texts)
  if #texts == 0 then return end
  local input = vim.fn.prompt_getinput(session.bufnr)
  if input ~= '' then table.insert(texts, input) end
  local row = vim.api.nvim_buf_get_mark(session.bufnr, ':')[1] - 1
  vim.api.nvim_buf_set_lines(session.bufnr, row, -1, false, vim.split(table.concat(texts, '\n'), '\n'))
end

--- @param session otto.Session
--- @param backward boolean
local function jump_to_prompt(session, backward)
  local row = session.buffer:find_prompt(vim.fn.line('.') - 1, backward)
  if row ~= nil then vim.api.nvim_win_set_cursor(0, { row + 1, 0 }) end
end

--- @type otto.Command[]
M.builtin = {
  {
    name = 'model',
    description = 'Select a model',
    run = function(session)
      local models = session.handle:models()
      -- pi's models are listed with their provider, and its state has their id
      local function current(id)
        return id == session.state.model or vim.endswith(id, '/' .. (session.state.model or ''))
      end
      pick.select({
        prompt = 'Model: ',
        items = function() return models end,
        format = function(id)
          local notes = current(id) and session.state.effort and { { session.state.effort, 'Comment' } } or nil
          return { { current(id) and '● ' or '  ', 'OttoStatus' }, { id } }, notes
        end,
        on_accept = function(id)
          util.run(function() session.handle:set_model(id) end)
        end,
      })
    end,
  },
  {
    name = 'effort',
    description = 'Cycle thinking level',
    run = function(session) session.handle:cycle_effort() end, -- the winbar shows the level
  },
  {
    name = 'compact',
    description = 'Compact the context, optionally with custom instructions',
    run = function(session)
      local instructions = util.input({ prompt = 'Compact instructions (optional): ' })
      if instructions == nil then return end
      session.handle:compact(vim.trim(instructions) ~= '' and instructions or nil)
    end,
  },
  {
    name = 'name',
    description = 'Set the session display name',
    replaces = { 'rename' },
    run = function(session)
      local name = util.input({ prompt = 'Name: ', default = session.state.name })
      if name == nil or vim.trim(name) == '' then return end
      session.named = true -- which agents can take a turn to report
      session.handle:rename(vim.trim(name))
    end,
  },
  {
    name = 'new',
    description = 'Start a new session with the same agent',
    run = function(session) require('otto').new(nil, session.provider.name) end,
  },
  {
    name = 'clear',
    description = 'Start a new session in this buffer, keeping this one saved',
    prompts = true,
    run = function(session)
      local base = session.provider.new_id()
      -- like a new session of the same second
      local id, count = base, 1
      while vim.fn.bufexists(session.provider.name .. '://' .. id) == 1 do
        count = count + 1
        id = base .. '_' .. count
      end
      require('otto.session').restart(session.bufnr, id)
    end,
  },
  {
    name = 'resume',
    description = 'Switch to another session',
    run = function() pick.sessions() end,
  },
  {
    name = 'prompts',
    description = 'Jump to a prompt of the session',
    run = function(session) prompts.pick(session, 'jump') end,
  },
  {
    name = 'rewind',
    description = 'Rewind the session to an earlier prompt, keeping the session it leaves saved',
    available = function(session) return session.handle.fork ~= nil end,
    run = function(session) prompts.pick(session, 'rewind') end,
  },
  {
    name = 'fork',
    description = 'Fork the session from an earlier prompt into a new buffer',
    available = function(session) return session.handle.fork ~= nil end,
    run = function(session) prompts.pick(session, 'fork') end,
  },
  {
    name = 'reload',
    description = 'Restart the agent, reloading its extensions, skills, prompt templates and context files',
    run = function(session) require('otto.session').restart(session.bufnr) end,
  },
  {
    name = 'history',
    description = 'Pick a prompt from the history of this folder',
    modes = { 'n', 'i' },
    run = function(session) history.pick(session, false) end,
  },
  {
    name = 'history_all',
    description = 'Pick a prompt from the history of every folder',
    run = function(session) history.pick(session, true) end,
  },
  {
    name = 'edits',
    description = 'Edits of the session to quickfix',
    run = function(session)
      vim.fn.setqflist({}, ' ', { title = session.state.id .. ' edits', items = session.layout.edits })
      vim.cmd.copen()
    end,
  },
  {
    name = 'abort',
    description = 'Stop the agent, taking back the queued prompts',
    run = function(session)
      -- first, since the agent would go on with them
      take_back(session, session.handle:take_queue())
      session.handle:abort()
    end,
  },
  {
    name = 'send_now',
    description = 'Send the prompt, or the queued prompts, now, interrupting the agent',
    modes = { 'n', 'i' },
    expr = true,
    run = function(session)
      if vim.trim(vim.fn.prompt_getinput(session.bufnr)) == '' then
        -- since the agent goes on with them once it's interrupted
        if #session.state.queue > 0 then session.handle:abort() end
        return ''
      end
      -- as a follow-up, since Codex drops prompts that steer a turn when it's interrupted before reading them
      session.follow_up, session.now = true, true
      return vim.fn.mode() == 'i' and '<CR>' or 'A<CR><Esc>'
    end,
  },
  {
    name = 'rewind_here',
    description = 'Rewind to the prompt under the cursor, or pick one',
    palette = false,
    run = function(session) cursor.rewind(session) end,
  },
  {
    name = 'fork_here',
    description = 'Fork from the prompt under the cursor, or pick one',
    palette = false,
    run = function(session) cursor.fork(session) end,
  },
  {
    name = 'edit_here',
    description = 'Edit the prompt under the cursor in the prompt',
    palette = false,
    run = function(session) cursor.edit(session) end,
  },
  {
    name = 'yank_here',
    description = 'Yank the prompt, command, output or code block under the cursor',
    palette = false,
    run = function(session) cursor.yank(session) end,
  },
  {
    name = 'open_here',
    description = 'Open the output, file or code block under the cursor in a split',
    palette = false,
    run = function(session) cursor.open(session) end,
  },
  {
    name = 'stop_here',
    description = 'Stop the subagent or command under the cursor',
    palette = false,
    run = function(session) cursor.stop(session) end,
  },
  {
    name = 'terminal_here',
    description = 'Run the command under the cursor in a terminal',
    palette = false,
    run = function(session) cursor.terminal(session) end,
  },
  {
    name = 'open',
    description = 'Open the location under the cursor, or submit',
    expr = true,
    run = function(session)
      local target = session.buffer:target_at(vim.fn.line('.') - 1)
      if target == nil then return not session.handle.read_only and 'A<CR><Esc>' or '' end
      vim.schedule(function() M.open_target(target) end) -- windows can't change while the mapping evaluates
      return ''
    end,
  },
  {
    name = 'submit',
    description = 'Submit, which steers while the agent is working',
    prompts = true,
    modes = { 'n', 'i' },
    expr = true,
    run = function() return vim.fn.mode() == 'i' and '<CR>' or 'A<CR><Esc>' end,
  },
  {
    name = 'follow_up',
    description = 'Submit as a follow-up, which waits for the agent to finish',
    prompts = true,
    modes = { 'i' },
    expr = true,
    run = function(session)
      session.follow_up = true
      return '<CR>'
    end,
  },
  {
    -- <CR> in insert mode adds a line, like <S-CR> in prompt buffers
    name = 'newline',
    description = 'New line',
    modes = { 'i' },
    expr = true,
    run = function() return '<S-CR>' end,
  },
  {
    -- prompt buffers start window commands with <C-w> in insert mode, and delete words with <C-S-w>
    name = 'delete_word',
    description = 'Delete word',
    modes = { 'i' },
    expr = true,
    run = function() return '<C-S-w>' end,
  },
  {
    name = 'next_prompt',
    description = 'Next prompt',
    palette = false,
    run = function(session) jump_to_prompt(session, false) end,
  },
  {
    name = 'previous_prompt',
    description = 'Previous prompt',
    palette = false,
    run = function(session) jump_to_prompt(session, true) end,
  },
  {
    name = 'history_older',
    description = 'Take back the newest queued prompt, or the older prompt in history',
    prompts = true,
    modes = { 'n', 'i' },
    palette = false,
    run = function(session)
      local count = vim.v.count1
      -- like when the agent read them meanwhile
      local texts = #session.state.queue > 0 and session.handle:take_queue(true) or {}
      if #texts == 0 then return history.step(session, count) end
      take_back(session, texts)
    end,
  },
  {
    name = 'history_newer',
    description = 'Newer prompt in history',
    prompts = true,
    modes = { 'n', 'i' },
    palette = false,
    run = function(session) history.step(session, -vim.v.count1) end,
  },
  {
    name = 'commands',
    description = 'Commands',
    modes = { 'n', 'i' },
    palette = false,
    run = function(session) M.palette(session) end,
  },
}

--- @param session otto.Session
--- @return otto.Command[] that the session's agent supports
function M.available(session)
  return vim.tbl_filter(function(command)
    if command.prompts and session.handle.read_only then return false end
    return command.available == nil or command.available(session)
  end, M.builtin)
end

--- @param name string
--- @return otto.Command?
function M.get(name)
  return vim.iter(M.builtin):find(function(command) return command.name == name end)
end

--- Runs a built-in command, returning the keys to run of those that return them
--- @param session otto.Session
--- @param name string
--- @return string?
function M.run(session, name)
  local command = M.get(name)
  if command == nil then return util.notify('unknown command: ' .. name) end
  if command.prompts and session.handle.read_only then
    return util.notify("subagents can't be prompted yet", vim.log.levels.WARN)
  end
  if command.available and not command.available(session) then
    return util.notify(name .. " isn't supported by " .. session.provider.name)
  end
  if command.expr then return command.run(session) end
  util.run(function() command.run(session) end)
end

--- @param session otto.Session
--- @return otto.Command[] The agent's own, without those that otto does itself
function M.agent_commands(session)
  local replaced = {}
  for _, command in ipairs(M.available(session)) do
    replaced[command.name] = true
    for _, name in ipairs(command.replaces or {}) do
      replaced[name] = true
    end
  end
  return vim.tbl_filter(function(command) return not replaced[command.name] end, session.state.commands)
end

local recent = {} --- @type string[] Names of the commands run from the palette, most recent first

--- Picks a command, the most recently run first. Otto's run, and the agent's start in the prompt, to finish writing
--- @param session otto.Session
function M.palette(session)
  local keys = require('otto.ui.keymaps').keys(session.bufnr)

  --- @class otto.PaletteItem
  --- @field command otto.Command
  --- @field builtin boolean

  local function items()
    local list = {} --- @type otto.PaletteItem[]
    for _, command in ipairs(M.available(session)) do
      if not command.expr and command.palette ~= false then
        table.insert(list, { command = command, builtin = true })
      end
    end
    for _, command in ipairs(M.agent_commands(session)) do
      table.insert(list, { command = command, builtin = false })
    end
    local rank = {}
    for i, name in ipairs(recent) do
      rank[name] = i
    end
    -- stable, so that the rest keep their order
    for i, item in ipairs(list) do
      item.order = rank[item.command.name] or #recent + i
    end
    table.sort(list, function(a, b) return a.order < b.order end)
    return list
  end

  --- @param item otto.PaletteItem
  local function format(item)
    local command = item.command
    local chunks = { { item.builtin and command.name or '/' .. command.name, 'OttoToolName' } }
    if command.args then table.insert(chunks, { ' ' .. command.args, 'OttoToolArg' }) end
    if command.description then table.insert(chunks, { '  ' .. command.description:gsub('\n.*', ''), 'Comment' }) end
    local key = item.builtin and keys[command.name]
    return chunks, key and { { key, 'OttoToolDetail' } } or nil
  end

  --- @param item otto.PaletteItem
  local function run(item)
    local name = item.command.name
    for i, other in ipairs(recent) do
      if other == name then table.remove(recent, i) end
    end
    table.insert(recent, 1, name)
    if item.builtin then return M.run(session, name) end
    -- before what the prompt holds, which becomes its argument
    local row = vim.api.nvim_buf_get_mark(session.bufnr, ':')[1]
    vim.api.nvim_buf_set_text(session.bufnr, row - 1, 0, row - 1, 0, { '/' .. name .. ' ' })
    if vim.api.nvim_get_current_buf() ~= session.bufnr then return end
    if vim.fn.mode() == 'i' then return vim.api.nvim_win_set_cursor(0, { row, #name + 2 }) end
    -- after the space, which normal mode can't put the cursor past at the end of the line
    vim.api.nvim_win_set_cursor(0, { row, #name + 1 })
    vim.api.nvim_feedkeys('a', 'n', false)
  end

  pick.select({ prompt = 'Command: ', items = items, format = format, on_accept = run })
end

return M
