-- The agents that otto runs, which only translate between their processes and files, and the log, the state and
-- requests, see `event.lua`. They don't touch buffers or ask the user anything

--- @class otto.Provider
--- @field name string Of the buffers of its sessions, like claude://<id>
--- @field icon string With the space after it
--- @field new_id fun(name?: string): string Of a new session
--- @field open fun(id: string, opts: otto.AgentOpts): otto.Agent Starts the agent for the session
--- @field files fun(): otto.SessionFile[] Saved sessions
--- @field names? fun(): table<string, string> Of sessions, when they're kept apart from their files

--- @class otto.SessionFile
--- @field file string
--- @field parse fun(file: string, modified: integer): otto.SavedSession?

--- @class otto.AgentOpts
--- @field name? string Display name of a new session
--- @field config otto.ProviderConfig Of the session's buffer
--- @field on_log fun(event: otto.Event)
--- @field on_state fun(patch: otto.StatePatch)
--- @field on_request fun(request: otto.Request)

--- @class otto.Agent A running agent. Its methods that are async run inside tasks, and raise their errors
--- @field replay async fun(self: otto.Agent) Adds the session's history to the log
--- @field prompt fun(self: otto.Agent, text: string, mode: 'steer' | 'follow_up', on_error?: fun(err: string)) With
--- `on_error` instead of a notification when the agent refuses it
--- @field abort fun(self: otto.Agent)
--- @field take_queue async fun(self: otto.Agent, newest_only?: boolean): string[] Prompts that the agent hasn't read yet,
--- or only the newest, which it drops
--- @field compact async fun(self: otto.Agent, instructions?: string)
--- @field models async fun(self: otto.Agent): string[]
--- @field set_model async fun(self: otto.Agent, model: string)
--- @field cycle_effort async fun(self: otto.Agent)
--- @field rename async fun(self: otto.Agent, name: string)
--- @field commands async fun(self: otto.Agent): otto.AgentCommand[]
--- @field fork_points? async fun(self: otto.Agent): { id: string, text: string }[] Prompts to fork from
--- @field fork? async fun(self: otto.Agent, id: string): { id: string, text: string }? The new session's id, and the
--- prompt to edit
--- @field close fun(self: otto.Agent)

--- @class otto.AgentCommand The agent's own, like pi's extensions, prompt templates and skills
--- @field name string
--- @field description? string
--- @field arg_hint? string

--- @class otto.SavedSession
--- @field provider string
--- @field id string
--- @field name? string Display name
--- @field prompt? string The first one
--- @field title string Display name, or the first prompt, or the id
--- @field message_count integer
--- @field modified integer Seconds since the epoch

local M = {}

--- @type table<string, otto.Provider>
M.providers = {
  pi = require('otto.providers.pi'),
  claude = require('otto.providers.claude'),
  codex = require('otto.providers.codex'),
}

--- @param name string
--- @return otto.Provider?
function M.get(name) return M.providers[name] end

--- @type table<string, { mtime: uv.fs_stat.result.time, cwd: string, saved?: otto.SavedSession }> by file, while
--- unmodified, without the sessions of other folders
local cache = {}

--- The current folder's saved sessions, newest first
--- @return otto.SavedSession[]
function M.saved()
  local sessions = {}
  -- Codex's files are of every folder, and read only those of the current one
  local cwd = vim.fn.getcwd()
  for _, provider in pairs(M.providers) do
    local names = provider.names and provider.names() or {}
    for _, file in ipairs(provider.files()) do
      local mtime = vim.uv.fs_stat(file.file).mtime
      local cached = cache[file.file]
      -- to the nanosecond, since sessions change more than once a second
      if cached == nil or cached.mtime.sec ~= mtime.sec or cached.mtime.nsec ~= mtime.nsec or cached.cwd ~= cwd then
        cache[file.file] = { mtime = mtime, cwd = cwd, saved = file.parse(file.file, mtime.sec) }
      end
      local saved = cache[file.file].saved
      if saved ~= nil then
        saved.name = names[saved.id] or saved.name
        saved.title = saved.name or (saved.prompt and vim.trim(saved.prompt):gsub('%s+', ' ')) or saved.id
        table.insert(sessions, saved)
      end
    end
  end
  table.sort(sessions, function(a, b) return a.modified > b.modified end)
  return sessions
end

return M
