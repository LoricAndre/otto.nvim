-- What providers emit: the log, which the transcript shows, and which is the same whether it's read from a session
-- file or streamed live, changes to the state, which is everything else, like what the agent is doing, and requests
-- for the user to answer. Events don't change once they're emitted, since the session keeps them. See ARCHITECTURE.md

local M = {}

--- @class otto.Event
--- @field type 'user' | 'text' | 'tool_call' | 'tool_result' | 'compaction' | 'error' | 'turn_end'
--- @field at integer Milliseconds since the epoch, from the provider's record when it has one
--- user, text
--- @field text? string
--- tool_call, tool_result
--- @field id? string
--- @field tool? string `read`, `edit`, `write`, `bash`, `grep`, `find`, `ls`, `web_search`, `fetch`, `agent`, or the
--- agent's own
--- @field args? table See `otto.ToolArgs`
--- @field ok? boolean
--- @field output? string
--- @field exit_code? integer Of commands
--- @field diff? otto.DiffLine[] Of edits
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
--- @field background? boolean agent, bash: whether it ends as a second result

--- @class otto.DiffLine
--- @field sign '+' | '-' | ' ' | nil Nothing for the gaps between hunks
--- @field lnum? integer In the new file for added lines and context, in the old one for removed lines
--- @field text string

--- @class otto.StatePatch What changed of what the session runs with and what the agent is doing, which the session
--- merges into its state. Lists are replaced whole
--- @field id? string Of a session that the agent created
--- @field name? string
--- @field model? string
--- @field effort? string
--- @field context_window? integer
--- @field context_tokens? integer Tokens in the context, as of the last answer or compaction
--- @field cost? number Dollars, for the whole session
--- @field status? 'working' | 'thinking' | 'compacting' | false False once the agent stopped
--- @field queue? otto.Queued[] Prompts that the agent hasn't read yet, including the one that was just sent

--- @class otto.Queued
--- @field text string
--- @field follow_up boolean Whether it waits for the agent to finish, instead of steering

--- @class otto.Request What the agent waits for the user to answer, like a permission
--- @field kind 'select' | 'input' | 'confirm'
--- @field prompt string
--- @field items? string[] select
--- @field default? string input
--- @field respond fun(value: any) With nil when cancelled

--- @param steering? string[]
--- @param follow_up? string[]
--- @return otto.Queued[]
function M.queue(steering, follow_up)
  local queue = {}
  for _, text in ipairs(steering or {}) do
    table.insert(queue, { text = text, follow_up = false })
  end
  for _, text in ipairs(follow_up or {}) do
    table.insert(queue, { text = text, follow_up = true })
  end
  return queue
end

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
function M.parse_iso(iso)
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
