-- Otto's commands, which its keymaps and the palette (<M-x>) run. The agents' own commands, like pi's extensions,
-- prompt templates and skills, are prompts like "/review", which the palette starts in the prompt

local history = require('otto.ui.history')
local layout = require('otto.render.layout')
local pick = require('otto.ui.pick')
local prompts = require('otto.ui.prompts')
local uri = require('otto.uri')
local util = require('otto.util')

local M = {}

--- @class otto.Command
--- @field name string
--- @field description? string
--- @field args? string Describes the argument, of the agents' commands
--- @field modes? string[] Of its keymaps, normal mode by default
--- @field expr? boolean Whether it returns the keys to run instead of running, which keeps it out of the palette
--- @field run? async fun(view: otto.View): string? Otto's commands only
--- @field palette? false Whether the palette skips it, like for moving around
--- @field available? fun(view: otto.View): boolean Commands that only some agents support

--- Opens the location in the previous window, or this one when there's no other
--- @param target otto.Target
function M.open_target(target)
  local previous = vim.fn.win_getid(vim.fn.winnr('#'))
  if previous ~= 0 and previous ~= vim.api.nvim_get_current_win() then vim.api.nvim_set_current_win(previous) end
  vim.cmd.edit(vim.fn.fnameescape(target.path))
  if target.lnum ~= nil then
    vim.api.nvim_win_set_cursor(0, { math.max(math.min(target.lnum, vim.api.nvim_buf_line_count(0)), 1), 0 })
    vim.cmd('normal! zz')
  end
end

--- Puts queued prompts back above what the prompt holds, in the order they were sent
--- @param view otto.View
--- @param texts string[]
local function take_back(view, texts)
  if #texts == 0 then return end
  local input = vim.fn.prompt_getinput(view.bufnr)
  if input ~= '' then table.insert(texts, input) end
  local row = vim.api.nvim_buf_get_mark(view.bufnr, ':')[1] - 1
  vim.api.nvim_buf_set_lines(view.bufnr, row, -1, false, vim.split(table.concat(texts, '\n'), '\n'))
end

--- @param view otto.View
--- @param backward boolean
local function jump_to_prompt(view, backward)
  local row = view.buffer:find_prompt(vim.fn.line('.') - 1, backward)
  if row ~= nil then vim.api.nvim_win_set_cursor(0, { row + 1, 0 }) end
end

--- @type otto.Command[]
M.builtin = {
  {
    name = 'model',
    description = 'Select a model',
    run = function(view)
      local models = view.session.handle:models()
      -- pi's models are listed with their provider, and its state has their id
      local function current(id)
        return id == view.session.state.model or vim.endswith(id, '/' .. (view.session.state.model or ''))
      end
      pick.select({
        prompt = 'Model: ',
        items = models,
        format = function(id)
          local notes = current(id) and view.session.state.effort and { { view.session.state.effort, 'Comment' } }
            or nil
          return { { current(id) and '● ' or '  ', 'OttoStatus' }, { id } }, notes
        end,
        on_accept = function(id)
          util.run(function() view.session.handle:set_model(id) end)
        end,
      })
    end,
  },
  {
    name = 'effort',
    description = 'Cycle thinking level',
    run = function(view) view.session.handle:cycle_effort() end, -- the winbar shows the level
  },
  {
    name = 'compact',
    description = 'Compact the context, optionally with custom instructions',
    run = function(view)
      local instructions = util.input({ prompt = 'Compact instructions (optional): ' })
      if instructions == nil then return end
      view.session.handle:compact(vim.trim(instructions) ~= '' and instructions or nil)
    end,
  },
  {
    name = 'name',
    description = 'Set the session display name',
    run = function(view)
      local name = util.input({ prompt = 'Name: ', default = view.session.state.name })
      if name == nil or vim.trim(name) == '' then return end
      view.session.handle:rename(vim.trim(name))
    end,
  },
  {
    name = 'clear',
    description = 'Start a new session in this buffer, keeping this one saved',
    run = function(view)
      local provider = view.session.provider
      require('otto.view').restart(view.bufnr, uri.id(uri.unique(provider.name, provider.new_id())))
    end,
  },
  {
    name = 'resume',
    description = 'Switch to another session',
    run = function() pick.sessions(true) end,
  },
  {
    name = 'prompts',
    description = 'Jump to a prompt of the session',
    run = function(view) prompts.pick(view) end,
  },
  {
    name = 'rewind',
    description = 'Rewind the session to an earlier prompt, keeping the session it leaves saved',
    available = function(view) return view.session.handle.fork ~= nil end,
    run = function(view) prompts.pick(view, true) end,
  },
  {
    name = 'reload',
    description = 'Restart the agent, reloading its extensions, skills, prompt templates and context files',
    run = function(view) require('otto.view').restart(view.bufnr) end,
  },
  {
    name = 'history',
    description = 'Pick a prompt from the history of this folder',
    modes = { 'n', 'i' },
    run = function(view) history.pick(view, false) end,
  },
  {
    name = 'history_all',
    description = 'Pick a prompt from the history of every folder',
    run = function(view) history.pick(view, true) end,
  },
  {
    name = 'edits',
    description = 'Edits of the session to quickfix',
    run = function(view)
      local edits = layout.edits(view.session.events)
      vim.fn.setqflist({}, ' ', { title = view.session.state.id .. ' edits', items = edits })
      vim.cmd.copen()
    end,
  },
  {
    name = 'abort',
    description = 'Stop the agent, taking back the queued prompts',
    run = function(view)
      -- first, since the agent would go on with them
      take_back(view, view.session.handle:take_queue())
      view.session.handle:abort()
    end,
  },
  {
    name = 'open',
    description = 'Open the location under the cursor, or submit',
    expr = true,
    run = function(view)
      local target = view.buffer:target_at(vim.fn.line('.') - 1)
      if target == nil then return 'A<CR><Esc>' end
      vim.schedule(function() M.open_target(target) end) -- windows can't change while the mapping evaluates
      return ''
    end,
  },
  {
    name = 'submit',
    description = 'Submit, which steers while the agent is working',
    modes = { 'n', 'i' },
    expr = true,
    run = function() return vim.fn.mode() == 'i' and '<CR>' or 'A<CR><Esc>' end,
  },
  {
    name = 'follow_up',
    description = 'Submit as a follow-up, which waits for the agent to finish',
    modes = { 'i' },
    expr = true,
    run = function(view)
      view.follow_up = true
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
    run = function(view) jump_to_prompt(view, false) end,
  },
  {
    name = 'previous_prompt',
    description = 'Previous prompt',
    palette = false,
    run = function(view) jump_to_prompt(view, true) end,
  },
  {
    name = 'history_older',
    description = 'Take back the newest queued prompt, or the older prompt in history',
    modes = { 'n', 'i' },
    palette = false,
    run = function(view)
      local count = vim.v.count1
      -- like when the agent read them meanwhile
      local texts = #view.session.state.queue > 0 and view.session.handle:take_queue(true) or {}
      if #texts == 0 then return history.step(view, count) end
      take_back(view, texts)
    end,
  },
  {
    name = 'history_newer',
    description = 'Newer prompt in history',
    modes = { 'n', 'i' },
    palette = false,
    run = function(view) history.step(view, -vim.v.count1) end,
  },
  {
    name = 'commands',
    description = 'Commands',
    modes = { 'n', 'i' },
    palette = false,
    run = function(view) M.palette(view) end,
  },
}

--- @param view otto.View
--- @return otto.Command[] that the session's agent supports
function M.available(view)
  return vim.tbl_filter(function(command) return command.available == nil or command.available(view) end, M.builtin)
end

--- @param name string
--- @return otto.Command?
function M.get(name)
  return vim.iter(M.builtin):find(function(command) return command.name == name end)
end

--- Runs a built-in command, returning the keys to run of those that return them
--- @param view otto.View
--- @param name string
--- @return string?
function M.run(view, name)
  local command = M.get(name)
  if command == nil then return util.notify('unknown command: ' .. name) end
  if command.available and not command.available(view) then
    return util.notify(name .. " isn't supported by " .. view.session.provider.name)
  end
  if command.expr then return command.run(view) end
  util.run(function() command.run(view) end)
end

--- @param view otto.View
--- @return otto.Command[] The agent's own, without those of the same name as otto's
function M.agent_commands(view)
  local builtin = {}
  for _, command in ipairs(M.available(view)) do
    builtin[command.name] = true
  end
  return vim.tbl_filter(function(command) return not builtin[command.name] end, view.session.state.commands)
end

--- Picks a command. Otto's run, and the agent's start in the prompt, to finish writing
--- @param view otto.View
function M.palette(view)
  local keys = require('otto.ui.keymaps').keys(view.bufnr)

  --- @class otto.PaletteItem
  --- @field command otto.Command
  --- @field builtin boolean

  local items = {} --- @type otto.PaletteItem[]
  for _, command in ipairs(M.available(view)) do
    if not command.expr and command.palette ~= false then table.insert(items, { command = command, builtin = true }) end
  end
  for _, command in ipairs(M.agent_commands(view)) do
    table.insert(items, { command = command, builtin = false })
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
    if item.builtin then return M.run(view, name) end
    -- before what the prompt holds, which becomes its argument
    local row = vim.api.nvim_buf_get_mark(view.bufnr, ':')[1]
    vim.api.nvim_buf_set_text(view.bufnr, row - 1, 0, row - 1, 0, { '/' .. name .. ' ' })
    if vim.api.nvim_get_current_buf() ~= view.bufnr then return end
    if vim.fn.mode() == 'i' then return vim.api.nvim_win_set_cursor(0, { row, #name + 2 }) end
    -- after the space, which normal mode can't put the cursor past at the end of the line
    vim.api.nvim_win_set_cursor(0, { row, #name + 1 })
    vim.api.nvim_feedkeys('a', 'n', false)
  end

  pick.select({ prompt = 'Command: ', items = items, format = format, on_accept = run })
end

return M
