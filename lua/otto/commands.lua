-- Slash commands: pi's built-in commands only exist in its TUI, so the ones that make sense in a buffer are
-- implemented here. Other commands (extensions, prompt templates and skills) are sent to pi as prompts

local rpc = require('otto.rpc')
local winbar = require('otto.winbar')

local M = {}

--- @class otto.Command
--- @field name string
--- @field description? string
--- @field args? string Describes the argument, for commands that take one
--- @field run? async fun(session: otto.Session, arg: string) Built-in commands only

--- @param session otto.Session
--- @param id string
local function switch(session, id) require('otto').restart(session.bufnr, id) end

--- @type otto.Command[]
M.builtin = {
  {
    name = 'new',
    args = '[name]',
    description = 'Start a new session',
    run = function(session, name) require('otto').new(name, session.backend) end,
  },
  {
    name = 'resume',
    description = 'Switch to another saved session',
    run = function() require('otto.resume').pick() end,
  },
  {
    name = 'name',
    args = '<name>',
    description = 'Set the session display name',
    run = function(session, name) session.client:call({ type = 'set_session_name', name = name }) end,
  },
  {
    name = 'compact',
    args = '[instructions]',
    description = 'Compact the context, optionally with custom instructions',
    run = function(session, instructions)
      session.client:call({ type = 'compact', customInstructions = instructions ~= '' and instructions or nil })
    end,
  },
  {
    name = 'model',
    args = '[provider/model]',
    description = 'Select a model',
    run = function(session, model)
      local provider, id = model:match('^([^/]+)/(.+)$')
      if provider == nil then
        local models = session.client:call({ type = 'get_available_models' }).models
        local format_item = function(item) return item.provider .. '/' .. item.id end
        local choice = rpc.select(models, { prompt = 'Model: ', format_item = format_item })
        if choice == nil then return end
        provider = choice.provider
        id = choice.id
      end
      session.client:call({ type = 'set_model', provider = provider, modelId = id })
    end,
  },
  {
    name = 'fork',
    description = 'Create a new session from an earlier prompt',
    run = function(session)
      local messages = session.client:call({ type = 'get_fork_messages' }).messages
      local format_item = function(message) return message.text:match('[^\n]*') end
      local message = rpc.select(messages, { prompt = 'Fork from: ', format_item = format_item })
      if message == nil then return end
      local fork = session.client:call({ type = 'fork', entryId = message.entryId })
      if fork.cancelled then return end
      switch(session, session.client:call({ type = 'get_state' }).sessionId)
      require('otto').append(fork.text) -- to edit the prompt before sending it again
    end,
  },
  {
    name = 'reload',
    description = 'Restart pi, reloading extensions, skills, prompt templates and context files',
    run = function(session) switch(session) end,
  },
}

--- Runs a built-in command, when the prompt is one
--- @param session otto.Session
--- @param text string
--- @return boolean handled
function M.run(session, text)
  local name, arg = vim.trim(text):match('^/(%S+)%s*(.*)')
  local command = vim.iter(M.builtin):find(function(command) return command.name == name end)
  if command == nil then return false end
  rpc.run(function()
    command.run(session, arg)
    winbar.refresh(session) -- for the model, which changes without an event
  end)
  return true
end

return M
