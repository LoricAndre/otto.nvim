-- How tools look: their headers, the lines below them, and how groups of them summarize. Only the tools in the log,
-- see `otto.ToolArgs`

local util = require('otto.util')

local M = {}

M.max_output_lines = 50

--- @alias otto.Chunks { [1]: string, [2]: string?, filetype?: string }[] Text and highlight group pairs, like virtual
--- text, or text that highlights as its filetype

--- @param chunks otto.Chunks
--- @return string
function M.join(chunks)
  return vim.iter(chunks):map(function(chunk) return chunk[1] end):join('')
end

--- @param text string
--- @return string
local function first_line(text) return text:match('[^\n]*') end

--- @class otto.Section Lines below the header of a tool
--- @field lines string[]
--- @field filetype? string Which they highlight as
--- @field locations? boolean Whether they start with locations, like `path:12:` from grep
--- @field path? string Of the file that they're lines of
--- @field lnum? integer Line number of the first line in the file
--- @field truncated? integer Lines past `max_output_lines`, which don't show

--- @param lines string[]
--- @param filetype? string
--- @return otto.Section
function M.section(lines, filetype)
  return {
    lines = vim.list_slice(lines, 1, M.max_output_lines),
    filetype = filetype,
    truncated = #lines - M.max_output_lines,
  }
end

--- How groups summarize their tools, like "read 2 files", by the text that counts them
local summaries = {
  read = 'read %d file',
  bash = 'ran %d command',
  grep = 'searched %d pattern',
  find = 'searched %d pattern',
  ls = 'listed %d folder',
  edit = 'edited %d file', -- only failed edits, which have no diff
  write = 'wrote %d file',
  web_search = 'ran %d web search',
  fetch = 'read %d web page',
  agent = 'ran %d subagent',
}

--- @param tools string[] of the group
--- @param failed integer
--- @return otto.Chunks like "read 2 files, ran 1 command"
function M.summary(tools, failed)
  local counts = {}
  local parts = {}
  for _, tool in ipairs(tools) do
    local part = summaries[tool] or 'called %d tool'
    if counts[part] == nil then table.insert(parts, part) end
    counts[part] = (counts[part] or 0) + 1
  end
  local text = vim
    .iter(parts)
    :map(function(part)
      local plural = part:match('[sh]$') and 'es' or 's'
      return part:format(counts[part]) .. (counts[part] > 1 and plural or '')
    end)
    :join(', ')
  if failed == 0 then return { { text, 'OttoToolSummary' } } end
  return { { text .. ', ', 'OttoToolSummary' }, { ('%d failed'):format(failed), 'OttoToolFailed' } }
end

--- Args that otto's tools need, and the types of the others, see `otto.ToolArgs`
local required = {
  read = { path = 'string' },
  edit = { path = 'string' },
  write = { path = 'string', content = 'string' },
  bash = { command = 'string' },
  web_search = { query = 'string' },
  fetch = { urls = 'table' },
  agent = { description = 'string' },
}
local optional = { pattern = 'string', description = 'string', offset = 'number', limit = 'number' }

--- @param tool string
--- @param args any
--- @return boolean whether the args are what the tool takes, which models sometimes get wrong
function M.valid(tool, args)
  if type(args) ~= 'table' then return false end
  for field, kind in pairs(vim.tbl_extend('force', optional, required[tool] or {})) do
    if (args[field] ~= nil or (required[tool] or {})[field]) and type(args[field]) ~= kind then return false end
  end
  local paths = type(args.path) == 'table' and args.path or { args.path or '' }
  local urls = tool == 'fetch' and args.urls or { '' }
  for _, text in ipairs(vim.list_extend(vim.list_extend({}, paths), urls)) do
    if type(text) ~= 'string' then return false end
  end
  return #urls > 0
end

--- @param tool string
--- @param args? table
--- @return { tool: string, args: table } as it shows, like the agent's own tools when the args aren't what the tool
--- takes, so that it shows what the agent sent
function M.display_call(tool, args)
  args = args or {}
  if M.valid(tool, args) then return { tool = tool, args = args } end
  return { tool = tool .. '?', args = { description = vim.json.encode(args) } }
end

--- @param tool string
--- @param args table
--- @return otto.Chunks like "read lua/otto/init.lua:10-20"
function M.header(tool, args)
  if tool == 'bash' then
    -- when the agent describes its commands, which reads better than them, while they show unfolded
    if args.description ~= nil then
      return { { '$', 'OttoToolName' }, { ' ' .. first_line(args.description), 'OttoToolArg' } }
    end
    local header = { { '$', 'OttoToolName' }, { ' ' .. first_line(vim.trim(args.command)), filetype = 'bash' } }
    local more = #vim.split(vim.trim(args.command), '\n') - 1
    if more > 0 then table.insert(header, { ('  +%d lines'):format(more), 'OttoToolDetail' }) end
    return header
  end
  if tool == 'agent' then
    local header = { { 'agent', 'OttoToolName' }, { ' ' .. first_line(args.description), 'OttoToolArg' } }
    if type(args.type) == 'string' then table.insert(header, { '  ' .. args.type, 'OttoToolDetail' }) end
    return header
  end
  if tool == 'web_search' then
    return { { 'web', 'OttoToolName' }, { ' ' .. first_line(args.query), 'OttoToolArg' } }
  end
  if tool == 'fetch' then
    local more = #args.urls > 1 and (' +%d'):format(#args.urls - 1) or ''
    return { { 'fetch', 'OttoToolName' }, { ' ' .. first_line(args.urls[1]) .. more, 'OttoToolArg' } }
  end
  local path = type(args.path) == 'table' and table.concat(vim.tbl_map(util.short_path, args.path), ' ')
    or args.path and util.short_path(args.path)
  if args.pattern ~= nil then
    local header = { { tool, 'OttoToolName' }, { ' ' .. first_line(args.pattern), 'OttoToolArg' } }
    if path then table.insert(header, { '  in ' .. path, 'OttoToolDetail' }) end
    return header
  end
  if tool == 'read' and (args.offset or args.limit) then
    local first = args.offset or 1
    path = path .. ':' .. first .. (args.limit and '-' .. (first + args.limit - 1) or '')
  end
  local arg = path or args.description or vim.json.encode(args)
  return { { tool, 'OttoToolName' }, { ' ' .. first_line(arg), 'OttoToolArg' } }
end

--- Commands whose output is the content of the file that they end with, like `cat foo.lua` or `sed -n 1,20p foo.lua`
local readers = { cat = true, head = true, tail = true, sed = true, nl = true, bat = true }
--- Commands whose output starts with locations, like `path:12:`
local searchers = { rg = true, grep = true, ag = true }

--- Describes the output of a tool by what produced it
--- @param tool string
--- @param args table
--- @param text string
--- @return otto.Section
function M.output_section(tool, args, text)
  local lines = text == '' and {} or vim.split(text, '\n')
  if tool == 'read' then
    local section = M.section(lines, vim.filetype.match({ filename = args.path }))
    section.path = args.path
    section.lnum = args.offset or 1
    return section
  end
  -- like a subagent's report
  if tool == 'fetch' or tool == 'agent' then return M.section(lines, 'markdown') end
  local section = M.section(lines)
  section.locations = tool == 'grep'
  if tool ~= 'bash' then return section end

  local command = vim.trim(args.command)
  local program = command:match('^%S+')
  local git = command:match('^git%s+(%a+)')
  if program == 'diff' or git == 'diff' or git == 'show' then
    section.filetype = 'diff'
  elseif searchers[program] or git == 'grep' then
    section.locations = true
  -- only when the output is the file's, without pipes, redirections or other commands
  elseif readers[program] and not command:find('[|;&<>\n]') then
    section.path = command:match('(%S+)$'):gsub('^([\'"])(.*)%1$', '%2')
    section.filetype = vim.filetype.match({ filename = section.path })
    -- the end of the file, or a range like `sed -n 10,20p`, which only says where it starts with a number
    local range = command:match('^sed %-n [\'"]?(%S+)')
    if range ~= nil then
      section.lnum = tonumber(range:match('^(%d+)[,p]'))
    elseif program ~= 'tail' then
      section.lnum = 1
    end
  elseif text:match('^[%[{]') and pcall(vim.json.decode, text) then
    section.filetype = 'json'
  end
  return section
end

--- @class otto.Location A location at the start of a line, like `path:12:` from grep
--- @field index integer Of the line
--- @field path string
--- @field lnum integer
--- @field width integer Of the line number

--- @param line string
--- @return string? path
--- @return string? lnum
function M.location(line)
  -- the first, since the text of context lines, like `path-12-`, can have the same, like dates
  local path, _, lnum = line:match('^([^:%s][^:]-)([:-])(%d+)%2')
  return path, lnum
end

--- @param lines string[]
--- @return otto.Location[]
function M.locations(lines)
  local locations = {}
  for i, line in ipairs(lines) do
    local path, lnum = M.location(line)
    if path ~= nil then table.insert(locations, { index = i, path = path, lnum = tonumber(lnum), width = #lnum }) end
  end
  return locations
end

--- @param diff otto.DiffLine[]
--- @return string[] like "+12 code", with the line numbers aligned
--- @return integer? first line that changed
function M.format_diff(diff)
  local width = 1
  for _, line in ipairs(diff) do
    if line.lnum ~= nil then width = math.max(width, #tostring(line.lnum)) end
  end
  local first
  local lines = vim.tbl_map(function(line)
    if line.sign == nil then return (' '):rep(width + 2) .. line.text end
    if first == nil and line.sign ~= ' ' then first = line.lnum end
    return ('%s%' .. width .. 'd %s'):format(line.sign, line.lnum, line.text)
  end, diff)
  return lines, first
end

--- @param diff otto.DiffLine[]
--- @return integer added
--- @return integer removed
function M.diff_counts(diff)
  local added, removed = 0, 0
  for _, line in ipairs(diff) do
    if line.sign == '+' then added = added + 1 end
    if line.sign == '-' then removed = removed + 1 end
  end
  return added, removed
end

return M
