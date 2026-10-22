-- The prompts of a session: jumping to them, and rewinding or forking the session from them, for agents that can.
-- Rewinding forks too, and switches the buffer to the fork, so the session it left stays saved

local history = require('otto.ui.history')
local pick = require('otto.ui.pick')
local util = require('otto.util')

local M = {}

--- @class otto.Prompt : otto.TranscriptPrompt
--- @field index integer Of the prompt in the session, from 1
--- @field id? string To fork from, when the agent can

--- The prompts of the transcript, with the ids that the agent forks from, which only match by their text
--- @async
--- @param session otto.Session
--- @return otto.Prompt[] newest first
function M.list(session)
  local prompts = session.buffer:prompts() --[[@as otto.Prompt[] ]]
  local points = session.handle.fork_points and session.handle:fork_points() or {}
  local next_point = 1
  for i, prompt in ipairs(prompts) do
    prompt.index = i
    for j = next_point, #points do
      if vim.trim(points[j].text) == vim.trim(prompt.text) then
        prompt.id, next_point = points[j].id, j + 1
        break
      end
    end
  end
  return vim.fn.reverse(prompts)
end

--- @param session otto.Session
--- @param prompt otto.Prompt
--- @return boolean
local function can_fork(session, prompt)
  if session.handle.fork == nil then
    util.notify(session.provider.name .. " can't rewind or fork sessions", vim.log.levels.WARN)
    return false
  end
  if prompt.id == nil then util.notify("the agent can't fork from this prompt", vim.log.levels.WARN) end
  return prompt.id ~= nil
end

--- Switches the buffer to a fork of the session from before the prompt, with the prompt in the prompt to edit
--- @async
--- @param session otto.Session
--- @param prompt otto.Prompt
function M.rewind(session, prompt)
  if not can_fork(session, prompt) then return end
  local fork = session.handle:fork(prompt.id)
  if fork == nil then return end
  local sessions = require('otto.session')
  sessions.restart(session.bufnr, fork.id)
  history.insert(sessions.sessions[session.bufnr], { text = fork.text })
end

--- Opens a fork of the session from before the prompt in the window, with the prompt in the prompt to edit. The
--- buffer keeps the session
--- @async
--- @param session otto.Session
--- @param prompt otto.Prompt
function M.fork(session, prompt)
  if not can_fork(session, prompt) then return end
  local fork = session.handle:fork(prompt.id)
  if fork == nil then return end
  local sessions = require('otto.session')
  -- since the agent switched to the fork
  sessions.restart(session.bufnr)
  vim.cmd.edit(session.provider.name .. '://' .. fork.id)
  history.insert(sessions.sessions[vim.api.nvim_get_current_buf()], { text = fork.text })
end

--- Puts the prompt into the prompt, keeping what it held like the history does
--- @param session otto.Session
--- @param prompt otto.TranscriptPrompt
function M.edit(session, prompt)
  history.insert(session, { text = prompt.text })
  if vim.api.nvim_get_current_buf() == session.bufnr then vim.cmd.startinsert({ bang = true }) end
end

--- Picks a prompt of the session, which the transcript scrolls to
--- @param session otto.Session
--- @param mode 'jump' | 'rewind' | 'fork' What accepting does
function M.pick(session, mode)
  util.run(function()
    local prompts = M.list(session)
    if #prompts == 0 then return util.notify('no prompts yet', vim.log.levels.WARN) end
    local win = vim.fn.bufwinid(session.bufnr)
    local view = win ~= -1 and vim.api.nvim_win_call(win, vim.fn.winsaveview)

    --- @param prompt otto.Prompt?
    local function preview(prompt)
      if win == -1 or not vim.api.nvim_win_is_valid(win) then return end
      vim.api.nvim_win_call(win, function()
        if prompt == nil then return vim.fn.winrestview(view) end
        vim.api.nvim_win_set_cursor(win, { prompt.row + 1, 0 })
        vim.cmd('normal! zt')
      end)
    end

    --- @param prompt otto.Prompt
    local function format(prompt)
      local lines = vim.split(prompt.text, '\n')
      local chunks = { { lines[1] } }
      if #lines > 1 then table.insert(chunks, { ('  +%d lines'):format(#lines - 1), 'Comment' }) end
      return chunks, { { tostring(prompt.index), 'Comment' } }
    end

    --- @param fn async fun(session: otto.Session, prompt: otto.Prompt)
    local function act(fn)
      return function(prompt, picker)
        if prompt ~= nil then
          picker.close(function()
            util.run(function() fn(session, prompt) end)
          end)
        end
      end
    end

    local accept = {
      jump = function(prompt) vim.api.nvim_win_set_cursor(win, { prompt.row + 1, 0 }) end,
      rewind = function(prompt)
        util.run(function() M.rewind(session, prompt) end)
      end,
      fork = function(prompt)
        util.run(function() M.fork(session, prompt) end)
      end,
    }
    local prompt = { jump = 'Prompt: ', rewind = 'Rewind to: ', fork = 'Fork from: ' }

    pick.select({
      prompt = prompt[mode],
      items = function() return prompts end,
      format = format,
      preview = preview,
      on_accept = accept[mode],
      actions = {
        { key = '<M-r>', desc = mode ~= 'rewind' and 'rewind' or nil, run = act(M.rewind) },
        { key = '<M-f>', desc = mode ~= 'fork' and 'fork' or nil, run = act(M.fork) },
        { key = '<M-e>', desc = 'edit', run = act(M.edit) },
        { key = '<M-y>', desc = 'yank', run = act(function(_, item) vim.fn.setreg(vim.v.register, item.text) end) },
      },
    })
  end)
end

return M
