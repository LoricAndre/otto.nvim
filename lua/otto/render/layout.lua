-- What the transcript shows for the log, without a buffer: blocks of lines, separated by an empty line, except for
-- tools, which follow the text that explains them. Edits and writes stand on their own, and other tools group under a
-- summary on the line above the first. See `buffer.lua` for where they go

local tools = require('otto.render.tools')

local M = {}

local nested = '  ' -- indent of the tools in a group
local slow = 15 -- seconds that commands run for before their headers keep how long they ran
local body_indent = '  ' -- of the lines below the header of a tool
M.body_indent = body_indent

--- @class otto.Block
--- @field kind 'user' | 'text' | 'tool' | 'error' | 'note'
--- @field spaced boolean Whether an empty line comes before it
--- @field lines string[] The first is the header of tools
--- @field indent? string Before the header and the sections
--- @field header? otto.Chunks Of the first line, after the indent
--- @field sections? otto.Section[] Below the header
--- @field markdown? boolean Whether the lines highlight as markdown
--- @field diff? { filetype?: string } Whether the lines below the header are a diff, and its file's
--- @field highlights otto.BlockHighlight[]
--- @field targets otto.BlockTarget[] Locations that lines are about, which <CR> opens
--- @field fold? boolean Whether the tool folds below its header
--- @field group? { summary: otto.Chunks, first: boolean } Of the tool, which starts with its first tool
--- @field call? otto.BlockCall Of tools, for the actions on them

--- @class otto.BlockCall
--- @field tool string
--- @field args table
--- @field output? string Whole, which the lines may only show the start of

--- @class otto.BlockHighlight
--- @field index integer Of the line in the block, from 0
--- @field group string
--- @field col? integer Of the whole line by default
--- @field end_col? integer To the end of the line by default

--- @class otto.BlockTarget Lines that are about a location, from their first
--- @field index integer Of the first line in the block, from 0
--- @field count? integer Of lines, 1 by default
--- @field path? string
--- @field lnum? integer Of the first line, which the next lines count up from
--- @field parse? 'diff' | 'location' Whether the line number, or the location, comes from the text of each line
--- @field col? integer Where the location starts in the lines

--- @class otto.Op
--- @field type 'block' | 'settle' Settling folds the groups of the turn, which stay open while it runs
--- @field block? otto.Block

--- @class otto.Layout
--- @field tail? 'user' | 'text' | 'tool' | 'error' | 'note' Kind of the last block, which spaces the next one
--- @field group? { tools: string[], failed: integer } Tools since the last block of another kind
--- @field calls table<string, { tool: string, args: table, at?: integer }> Tool calls by id, until their result arrives
--- @field running { id: string, tool: string, args: table }[] The same calls, in order
--- @field edits vim.quickfix.entry[] Files that the agent edited, at the first changed line
local Layout = {}
Layout.__index = Layout

--- @return otto.Layout
function M.new() return setmetatable({ calls = {}, running = {}, edits = {} }, Layout) end

--- @param block otto.Block
--- @return otto.Op[]
function Layout:block(block)
  -- tools go right below the text that explains them, and below each other
  block.spaced = not (block.kind == 'tool' and (self.tail == 'tool' or self.tail == 'text'))
  block.highlights = block.highlights or {}
  block.targets = block.targets or {}
  if block.group == nil then self.group = nil end
  self.tail = block.kind
  return { { type = 'block', block = block } }
end

--- Lines below the header, with their highlights and targets
--- @param header otto.Chunks
--- @param sections otto.Section[]
--- @param indent string
--- @param highlights otto.BlockHighlight[]
--- @param targets otto.BlockTarget[]
--- @return string[]
local function tool_lines(header, sections, indent, highlights, targets)
  local lines = { indent .. tools.join(header) }
  local col = #indent + #body_indent
  for _, section in ipairs(sections) do
    local before = #lines - 1 -- index of the line before the section
    for _, line in ipairs(section.lines) do
      table.insert(lines, indent .. body_indent .. line)
    end
    local count = #section.lines
    if section.path and count > 0 then
      table.insert(targets, { index = before + 1, count = count, path = section.path, lnum = section.first })
    end
    if section.locations and count > 0 then
      table.insert(targets, { index = before + 1, count = count, parse = 'location', col = col })
    end
    for _, location in ipairs(section.locations and tools.locations(section.lines) or {}) do
      local index = before + location.index
      local path_end = col + #location.path
      table.insert(highlights, { index = index, col = col, end_col = path_end, group = 'OttoPath' })
      local lnum_end = path_end + 1 + location.width
      table.insert(highlights, { index = index, col = path_end + 1, end_col = lnum_end, group = 'OttoLineNumber' })
    end
    if (section.hidden or 0) > 0 then
      table.insert(lines, ('%s%s... %d more lines'):format(indent, body_indent, section.hidden))
      table.insert(highlights, { index = #lines - 1, col = col, group = 'OttoToolDetail' })
    end
  end
  return lines
end

--- A tool on its own, which folds below its header
--- @param kind 'tool' | 'note'
--- @param header otto.Chunks
--- @param sections otto.Section[]
--- @param targets? otto.BlockTarget[]
--- @return otto.Op[]
function Layout:tool_block(kind, header, sections, targets)
  local highlights = {}
  targets = targets or {}
  return self:block({
    kind = kind,
    lines = tool_lines(header, sections, '', highlights, targets),
    indent = '',
    header = header,
    sections = sections,
    highlights = highlights,
    targets = targets,
    -- in insert mode, a single line inserted right below a fold joins it, so blocks are never a single line there
    fold = true,
  })
end

--- @param text string
--- @return string[]
local function split(text) return vim.split(text, '\n') end

--- Edits show their diff since that's what matters, with the changed lines highlighted, and the code as its language
--- @param call { tool: string, args: table }
--- @param diff otto.DiffLine[]
--- @return otto.Op[]
function Layout:diff(call, diff)
  local header = tools.header(call.tool, call.args)
  local added, removed = tools.diff_counts(diff)
  vim.list_extend(header, { { ('  +%d'):format(added), 'Added' }, { (' -%d'):format(removed), 'Removed' } })
  local lines, first_changed = tools.diff_lines(diff)
  -- which results without a call don't have
  local path = call.args.path
  if path ~= nil then
    table.insert(self.edits, { filename = path, lnum = first_changed or 1, text = tools.join(header) })
  end

  local targets =
    { { index = 0, path = path, lnum = first_changed }, { index = 1, count = #lines, path = path, parse = 'diff' } }
  local ops = self:tool_block('tool', header, { { lines = lines } }, targets)
  local block = ops[1].block --[[@as otto.Block]]
  block.diff = { filetype = path and vim.filetype.match({ filename = path }) }
  block.call = { tool = call.tool, args = call.args }
  for i, line in ipairs(diff) do
    local group = line.sign == '+' and 'DiffAdd' or line.sign == '-' and 'DiffDelete' or nil
    if group ~= nil then table.insert(block.highlights, { index = i, group = group }) end
  end
  return ops
end

--- Adds the tool to the group of tools since the last block of another kind, or starts one
--- @param tool string
--- @param failed boolean
--- @param header otto.Chunks
--- @param sections otto.Section[]
--- @param count integer Of what the summary counts, like the pages that one tool read
--- @return otto.Op[]
function Layout:grouped(tool, failed, header, sections, count)
  local group = self.group or { tools = {}, failed = 0 }
  for _ = 1, count do
    table.insert(group.tools, tool)
  end
  if failed then group.failed = group.failed + 1 end

  local highlights, targets = {}, {}
  local lines = tool_lines(header, sections, nested, highlights, targets)
  local ops = self:block({
    kind = 'tool',
    lines = lines,
    indent = nested,
    header = header,
    sections = sections,
    highlights = highlights,
    targets = targets,
    fold = #lines > 1,
    group = { summary = tools.summary(group.tools, group.failed), first = self.group == nil },
  })
  self.group = group
  return ops
end

--- @param result otto.Event tool_result
--- @return otto.Op[]
function Layout:tool_result(result)
  local call = self.calls[result.id] or { tool = '?', args = {} }
  self.calls[result.id] = nil
  self.running = vim.tbl_filter(function(running) return running.id ~= result.id end, self.running)
  local tool = call.tool
  local args = call.args
  if result.diff ~= nil then return self:diff(call, result.diff) end

  local header = tools.header(tool, args)
  if tool == 'write' and result.ok then
    -- without the line that the last newline would start
    local lines = split((args.content:gsub('\n$', '')))
    table.insert(header, { ('  +%d'):format(#lines), 'Added' })
    local section = tools.output(lines, vim.filetype.match({ filename = args.path }))
    section.path = args.path
    section.first = 1
    local ops = self:tool_block('tool', header, { section }, { { index = 0, path = args.path } })
    ops[1].block.call = { tool = tool, args = args }
    return ops
  end

  local section = tools.output_of(tool, args, result.output or '')
  local lines = section.lines
  local seconds = call.at and math.floor((result.at - call.at) / 1000)
  if tool == 'bash' and seconds and seconds >= slow then
    table.insert(header, { '  ' .. tools.duration(seconds), 'OttoStatusTime' })
  end
  local code = result.exit_code
  -- commands only say how they ended when they fail
  if tool == 'bash' and (code or 0) ~= 0 then
    table.insert(header, { '  exit ' .. code, 'OttoToolFailed' })
  elseif not result.ok then
    vim.list_extend(header, { { '  failed', 'OttoToolFailed' }, { ' ' .. (lines[1] or ''), 'OttoToolDetail' } })
  elseif tool ~= 'bash' then
    table.insert(header, { '  done', 'OttoToolDone' })
  end
  local count = tool == 'fetch' and #args.urls or 1
  local sections = #lines > 0 and { section } or {}
  -- the header only shows the description or first line of commands
  local command = tool == 'bash' and split(vim.trim(args.command))
  if command and (#command > 1 or args.description ~= nil) then
    table.insert(sections, 1, tools.output(command, 'bash'))
  end
  local ops = self:grouped(tool, not result.ok, header, sections, count)
  ops[1].block.call = { tool = tool, args = args, output = result.output }
  if section.path ~= nil then
    table.insert(ops[1].block.targets, { index = 0, path = section.path, lnum = section.first })
  end
  return ops
end

--- @param tokens integer
--- @return string like "120k"
local function thousands(tokens) return math.floor(tokens / 1000) .. 'k' end

--- @param compaction otto.Event
--- @return otto.Op[]
function Layout:compaction(compaction)
  local before, after = compaction.before, compaction.after
  local tokens = after and before and ('  %s -> %s tokens'):format(thousands(before), thousands(after))
    or before and ('  from %s tokens'):format(thousands(before))
  local header = { { 'compacted', 'OttoToolName' }, tokens and { tokens, 'OttoToolDetail' } or nil }
  if compaction.summary == nil then
    return self:block({ kind = 'note', lines = { tools.join(header) }, indent = '', header = header })
  end
  return self:tool_block('note', header, { { lines = split(compaction.summary), filetype = 'markdown' } })
end

--- Notes how long the agent worked, like "Worked for 2m 10s · done 4:19 p.m"
--- @param turn_end otto.Event
--- @return otto.Op[]
function Layout:worked(turn_end)
  -- live and replayed times can differ by milliseconds
  local seconds = math.max(math.floor((turn_end.at - turn_end.started) / 1000), 0)
  local at = math.floor(turn_end.at / 1000)
  -- by the hour, since %p is empty or translated in some locales
  local time = os.date('%I:%M', at):gsub('^0', '') .. (os.date('*t', at).hour >= 12 and ' p.m' or ' a.m')
  local text = ('Worked for %s · %s %s'):format(
    tools.duration(seconds),
    turn_end.aborted and 'aborted' or 'done',
    time
  )
  local header = { { text, 'OttoStatusDone' } }
  return self:block({ kind = 'note', lines = { text }, indent = '', header = header })
end

--- @param event otto.Event
--- @return otto.Op[] what changes in the transcript
function Layout:add(event)
  if event.type == 'user' then
    return self:block({ kind = 'user', lines = split(event.text), markdown = true })
  elseif event.type == 'text' then
    return self:block({ kind = 'text', lines = split(event.text), markdown = true })
  elseif event.type == 'error' then
    return self:block({ kind = 'error', lines = split(event.message) })
  elseif event.type == 'tool_call' then
    local call = { tool = event.tool, args = event.args or {} }
    -- like the agent's own tools, so that it shows what the agent sent
    if not tools.valid(call.tool, call.args) then
      call = { tool = event.tool .. '?', args = { description = vim.json.encode(call.args) } }
    end
    call.at = event.at
    self.calls[event.id] = call
    table.insert(self.running, { id = event.id, tool = call.tool, args = call.args })
  elseif event.type == 'tool_result' then
    return self:tool_result(event)
  elseif event.type == 'compaction' then
    return self:compaction(event)
  elseif event.type == 'turn_end' then
    local ops = (event.worked or event.aborted) and self:worked(event) or {}
    self.group = nil
    self.calls = {}
    self.running = {}
    table.insert(ops, { type = 'settle' })
    return ops
  end
  return {}
end

return M
