-- The agents that otto runs, which only translate between their processes and files, and the log and status, see
-- `event.lua`. They don't touch buffers or ask the user anything

--- @class otto.Provider
--- @field name string Of the buffers of its sessions, like claude://<id>
--- @field icon string With the space after it
--- @field new_id fun(name?: string): string Of a new session
--- @field open fun(id: string, opts: otto.OpenOpts): otto.Handle Starts the agent for the session
--- @field files fun(): { file: string, read: fun(file: string, modified: integer): otto.SessionInfo? }[] Saved sessions
--- @field names? fun(): table<string, string> Of sessions, when they're kept apart from their files
--- @field ask? async fun(message: string, opts: otto.AskOpts): string

--- @class otto.OpenOpts
--- @field name? string Display name of a new session
--- @field on_log fun(event: otto.Event)
--- @field on_status fun(status: otto.Status)

--- @class otto.Handle A running agent. Its methods that are async run inside tasks, and raise their errors
--- @field replay async fun(self: otto.Handle) Adds the session's history to the log
--- @field prompt fun(self: otto.Handle, text: string, mode: 'steer' | 'follow_up')
--- @field abort fun(self: otto.Handle)
--- @field take_queue async fun(self: otto.Handle, last?: boolean): string[] Prompts that the agent hasn't read yet,
--- or only the newest, which it drops
--- @field compact async fun(self: otto.Handle, instructions?: string)
--- @field models async fun(self: otto.Handle): string[]
--- @field set_model async fun(self: otto.Handle, model: string)
--- @field cycle_effort async fun(self: otto.Handle)
--- @field rename async fun(self: otto.Handle, name: string)
--- @field commands async fun(self: otto.Handle): otto.Command[] The agent's own
--- @field fork_points? async fun(self: otto.Handle): { id: string, text: string }[] Prompts to fork from
--- @field fork? async fun(self: otto.Handle, id: string): { id: string, text: string, switched?: boolean }? The new
--- session's id, and whether the agent switched to it
--- @field stop_task? async fun(self: otto.Handle, id: string) Stops a subagent or command in the background
--- @field read_only? boolean Whether it can't be prompted, like a subagent's session
--- @field close fun(self: otto.Handle)

--- @class otto.AskOpts
--- @field thinking? string Level, like "low"
--- @field tools? false | string[] None, or only these
--- @field skills? false

--- @class otto.SessionInfo A saved session
--- @field provider string
--- @field id string
--- @field name? string Display name
--- @field title string Display name, or the first prompt
--- @field messages integer
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

--- @type table<string, { mtime: uv.fs_stat.result.time, cwd: string, info?: otto.SessionInfo }> by file, while unmodified, without the sessions
--- of other folders
local cache = {}

--- The current folder's saved sessions, newest first
--- @return otto.SessionInfo[]
function M.list()
  local sessions = {}
  -- Codex's files are of every folder, and read only those of the current one
  local cwd = vim.fn.getcwd()
  for _, provider in pairs(M.providers) do
    for _, file in ipairs(provider.files()) do
      local mtime = vim.uv.fs_stat(file.file).mtime
      local cached = cache[file.file]
      -- to the nanosecond, since sessions change more than once a second
      if cached == nil or cached.mtime.sec ~= mtime.sec or cached.mtime.nsec ~= mtime.nsec or cached.cwd ~= cwd then
        cache[file.file] = { mtime = mtime, cwd = cwd, info = file.read(file.file, mtime.sec) }
      end
      if cache[file.file].info ~= nil then table.insert(sessions, cache[file.file].info) end
    end
    local names = provider.names and provider.names() or {}
    for _, info in ipairs(sessions) do
      if info.provider == provider.name and names[info.id] ~= nil then
        info.name = names[info.id]
        info.title = info.name
      end
    end
  end
  table.sort(sessions, function(a, b) return a.modified > b.modified end)
  return sessions
end

--- Sends `message` to a new agent without a saved session, and returns its final answer
--- @async
--- @param message string
--- @param opts? otto.AskOpts
--- @return string
function M.ask(message, opts)
  local provider = M.providers[vim.g.otto_ask_provider or 'pi']
  return assert(provider.ask, provider.name .. " can't answer one-shot prompts")(message, opts or {})
end

return M
