-- pi's messages as the log, which are the same in its session files and its events

local event = require('otto.event')
local util = require('otto.util')

local M = {}

--- pi's tools, and those of extensions, which are otto's under another name
local tools = { search = 'grep', kagi_search = 'web_search', web_fetch = 'fetch', kagi_extract = 'fetch' }

--- pi's diffs number their lines, like "+12 code", and mark the gaps between hunks with "..."
--- @param diff string
--- @return otto.DiffLine[]
local function diff_lines(diff)
  -- lines around the change are numbered in the old file, so they move by the lines changed above them
  local shift = 0
  return vim.tbl_map(function(line)
    local sign, number, text = line:match('^([+%- ])%s*(%d+) ?(.*)$')
    if sign == nil then return { text = vim.trim(line) } end
    local lnum = tonumber(number) + (sign == ' ' and shift or 0)
    shift = shift + (sign == '+' and 1 or sign == '-' and -1 or 0)
    return { sign = sign, lnum = lnum, text = text }
  end, vim.split(diff, '\n'))
end

--- @class otto.PiState What the decoder keeps between messages
--- @field cost number Of the session so far

--- Adds a message of pi to the log, which is the same in its session files and its events
--- @param session_log otto.Log
--- @param state otto.PiState
--- @param msg table AgentMessage
--- @param at? integer When it ended, which is when its entry was saved, or now, since messages only say when they
--- started
function M.message(session_log, state, msg, at)
  if msg.role == 'user' then
    session_log:user(vim.trim(event.text_of(msg.content)), at)
  elseif msg.role == 'assistant' then
    for _, part in ipairs(msg.content or {}) do
      if part.type == 'text' and vim.trim(part.text) ~= '' then session_log:text(vim.trim(part.text), at) end
      if part.type == 'toolCall' then
        session_log:tool_call(part.id, tools[part.name] or part.name, part.arguments, at)
      end
    end
    if msg.errorMessage ~= nil then session_log:error(msg.errorMessage, at) end
    -- aborting ends the answer with an error, like "The operation was aborted."
    local aborted = msg.stopReason == 'error' and (msg.errorMessage or ''):find('aborted', 1, true)
    if msg.stopReason == 'aborted' or aborted then session_log:interrupt() end
    if msg.usage ~= nil then
      state.cost = state.cost + (vim.tbl_get(msg.usage, 'cost', 'total') or 0)
      session_log:state({ context = msg.usage.totalTokens, cost = state.cost })
    end
  elseif msg.role == 'toolResult' then
    local output = util.trim_end(event.text_of(msg.content))
    local result = { id = msg.toolCallId, ok = not msg.isError, output = output }
    local diff = vim.tbl_get(msg, 'details', 'diff')
    if diff ~= nil then result.diff = diff_lines(diff) end
    -- the text of search results has HTML in it, but their details don't
    local results = vim.tbl_get(msg, 'details', 'results')
    if type(results) == 'table' and results[1] and results[1].url then
      result.output = vim
        .iter(results)
        :map(function(item) return (item.title and item.title .. '  ' or '') .. (item.url or '') end)
        :join('\n')
    end
    -- which extensions can add a line after, like "[Output truncated...]"
    local text, code, rest = output:match('^(.-)%s*Command exited with code (%d+)(%s*[^\n]*)$')
    if code ~= nil then
      text = text == '(no output)' and '' or text
      result.output = text == '' and vim.trim(rest) or text .. rest
      result.exit_code = tonumber(code)
    end
    session_log:tool_result(result, at)
  end
end

return M
