-- What providers emit: the log, which the transcript shows, and which is the same whether it's read from a session
-- file or streamed live, and the status, which is everything else, like what the agent is doing. See ARCHITECTURE.md

local M = {}

--- @class otto.Event
--- @field type 'user' | 'text' | 'tool_call' | 'tool_result' | 'message' | 'compaction' | 'error' | 'turn_end'
--- @field at integer Milliseconds since the epoch, from the provider's record when it has one
--- user, text
--- @field text? string
--- tool_call, tool_result
--- @field id? string
--- @field tool? string `read`, `edit`, `write`, `bash`, `grep`, `find`, `ls`, `web_search`, `fetch`, `agent`, `message`, or
--- the agent's own
--- @field args? table See `otto.ToolArgs`
--- @field ok? boolean
--- @field output? string
--- @field exit_code? integer Of commands
--- @field diff? otto.DiffLine[] Of edits
--- @field child? string Buffer name of the session that a subagent tool started, like claude://<session>/<agent>
--- message, from another agent, like a subagent handing back its report. The agent's own are `message` tools
--- @field from? string Name of the agent
--- @field uri? string Buffer name of its session
--- @field kind? 'spawn' | 'handback' | 'done' | 'failed' | 'stopped' Of messages that start or end a subagent
--- @field tokens? integer That the subagent used, when it ended
--- @field tools? integer That the subagent called, when it ended
--- @field seconds? integer That the subagent ran for, when it ended
--- compaction
--- @field summary? string
--- @field before? integer Tokens in the context
--- @field after? integer
--- error
--- @field message? string
--- turn_end, which every turn has, since a turn starts with what the agent does after the last one ended
--- @field aborted? boolean
--- @field started? integer When the turn started
--- @field worked? boolean Whether the agent did anything in the turn, unlike for commands like /compact

--- @class otto.ToolArgs Of the tools that otto knows, while others keep the agent's own
--- @field path? string | string[] read, edit, write, grep, find, ls
--- @field offset? integer read: line number of the first line
--- @field limit? integer read: count of lines
--- @field content? string write
--- @field command? string bash
--- @field description? string bash, when the agent describes its commands
--- @field pattern? string grep, find
--- @field query? string web_search
--- @field urls? string[] fetch
--- @field prompt? string agent
--- @field type? string agent: its kind, like "general-purpose"
--- @field background? boolean agent, bash
--- @field to? string message: name of the agent
--- @field text? string message
--- @field summary? string message

--- @class otto.Background A subagent or command that the agent runs in the background, or a subagent that it waits for
--- @field id string
--- @field kind 'subagent' | 'command'
--- @field name string
--- @field call_id? string Of the tool call that started it
--- @field since integer When it started, in milliseconds of the event loop
--- @field activity? string Like the subagent's last tool
--- @field tools? integer
--- @field tokens? integer
--- @field uri? string Buffer name of a subagent's session

--- @class otto.DiffLine
--- @field sign '+' | '-' | ' ' | nil Nothing for the gaps between hunks
--- @field lnum? integer In the new file for added lines and context, in the old one for removed lines
--- @field text string

--- @class otto.Status
--- @field type 'working' | 'queue' | 'info' | 'background' | 'request' | 'extension_ui' | 'ui_reset'
--- @field event? table Extension UI request
--- working
--- @field state? 'working' | 'thinking' | 'compacting' Nothing when the agent stopped
--- queue: prompts that the agent hasn't read yet, including the one that was just sent
--- @field steering? string[]
--- @field follow_up? string[]
--- info: what the session runs with, from its history or its process
--- @field id? string Of a session that the agent created
--- @field name? string
--- @field model? string
--- @field effort? string
--- @field window? integer Size of the context window
--- @field context? integer Tokens in the context, as of the last answer or compaction
--- @field cost? number Dollars, for the whole session
--- @field parent? string Buffer name of the session that started this one, of subagents
--- background: what the agent runs beside the conversation, replaced whole
--- @field background? otto.Background[]
--- request
--- @field kind? 'select' | 'input' | 'confirm' | 'editor'
--- @field active? fun(): boolean Whether the request can still be answered
--- @field deadline? integer Milliseconds of the event loop
--- @field prompt? string
--- @field items? string[] select
--- @field default? string input
--- @field respond? fun(value: any) With nil when cancelled

--- @return integer milliseconds since the epoch
function M.now()
  local seconds, microseconds = vim.uv.gettimeofday()
  return seconds * 1000 + math.floor(microseconds / 1000)
end

--- Days since the epoch, since `os.time` takes local times, see https://howardhinnant.github.io/date_algorithms.html
--- @param year integer
--- @param month integer
--- @param day integer
--- @return integer
local function days(year, month, day)
  year = month <= 2 and year - 1 or year
  local era = math.floor(year / 400)
  local year_of_era = year - era * 400
  local day_of_year = math.floor((153 * ((month + 9) % 12) + 2) / 5) + day - 1
  local day_of_era = year_of_era * 365 + math.floor(year_of_era / 4) - math.floor(year_of_era / 100) + day_of_year
  return era * 146097 + day_of_era - 719468
end

--- @param iso? string in UTC, like 2026-10-21T17:15:04.312Z
--- @return integer? milliseconds since the epoch
function M.time(iso)
  if iso == nil then return nil end
  local year, month, day, hour, min, sec, ms = iso:match('^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)%.?(%d*)Z$')
  if year == nil then return nil end
  local seconds = days(tonumber(year), tonumber(month), tonumber(day)) * 86400 + hour * 3600 + min * 60 + sec
  return seconds * 1000 + tonumber((ms .. '000'):sub(1, 3))
end

--- @param content string | { type: string, text?: string }[]
--- @return string
function M.text_of(content)
  if type(content) == 'string' then return content end
  local texts = vim.tbl_filter(function(part) return part.type == 'text' and part.text ~= nil end, content or {})
  return vim.iter(texts):map(function(part) return part.text end):join('\n')
end

return M
