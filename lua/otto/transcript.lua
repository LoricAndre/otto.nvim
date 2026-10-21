-- The transcript is markdown above the prompt, which only the plugin edits, and only by appending. Messages are blocks
-- separated by an empty line, except for tools, which follow the text that explains them. Edits fold on their own, and
-- other tools fold under a summary at the end of that text. Prompts are highlighted like the quickfix line. An empty
-- line and a separator come before the prompt being written. Long transcripts lose their oldest turns, see `trim_turns`

local prompt = require('otto.prompt')

local M = {}

local ns = vim.api.nvim_create_namespace('otto')
local separator_ns = vim.api.nvim_create_namespace('otto.separators')
local user_ns = vim.api.nvim_create_namespace('otto.prompts')
local summary_ns = vim.api.nvim_create_namespace('otto.summaries')
local separator = { { ('─'):rep(500), 'OttoSeparator' } } -- clipped to the window
local max_output_lines = 50
local soft_limit = 5000 -- lines, which the transcript trims to by whole turns when a turn starts
local hard_limit = 8000 -- lines, past which it trims within a turn
local nested = '  ' -- indent of the tools in a group
-- longer than the fences in tool output, like markdown files and heredocs, so that those don't close it
local fence = '````'
local folds = {} --- @type table<integer, otto.Fold[]> by buffer, see `fold`

--- How groups summarize their tools, like "read 2 files", by the text that counts them
local summaries = {
  read = 'read %d file',
  bash = 'ran %d command',
  grep = 'searched %d pattern',
  search = 'searched %d pattern',
  find = 'searched %d pattern',
  ls = 'listed %d folder',
  edit = 'edited %d file', -- only failed edits, which have no diff
  write = 'wrote %d file',
  web_search = 'ran %d web search',
  web_fetch = 'read %d web page',
}

--- Names of tools that render like others
local aliases = { kagi_search = 'web_search', kagi_extract = 'web_fetch' }

--- @param bufnr integer
--- @param row integer
--- @return boolean
local function is_separator(bufnr, row)
  return #vim.api.nvim_buf_get_extmarks(bufnr, separator_ns, { row, 0 }, { row, 0 }, {}) > 0
end

--- @param text string
--- @return string
local function first_line(text) return text:match('[^\n]*') end

--- @class otto.Fold
--- @field top integer 1-indexed, like Ex ranges
--- @field bottom integer
--- @field nested boolean Inside the fold of a group
--- @field open? boolean The group that the agent is running, until the transcript moves past it

--- Runs `fn` in each window that shows the buffer, since folds belong to windows. Windows fold the buffer once they
--- show it, see `M.fold`
--- @param bufnr integer
--- @param fn fun()
local function in_windows(bufnr, fn)
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.wo[win].foldmethod == 'manual' then vim.api.nvim_win_call(win, fn) end
  end
end

--- Creates the fold, closed, in the current window. Folds inside it nest
--- @param fold otto.Fold
local function create(fold) vim.cmd(('%d,%dfold'):format(fold.top, fold.bottom)) end

--- Folds lines of the transcript. The folds are manual, since 'foldexpr' folds don't update in insert mode. But in
--- insert mode, a single line inserted right below a fold joins it, so blocks are never a single line there
--- @param bufnr integer
--- @param top integer
--- @param bottom integer
--- @param nested boolean
--- @return otto.Fold
local function fold(bufnr, top, bottom, nested)
  local new = { top = top, bottom = bottom, nested = nested }
  table.insert(folds[bufnr], new)
  in_windows(bufnr, function() create(new) end)
  return new
end

--- Folds can't grow, so this makes the fold again with its new bottom, open when it was
--- @param bufnr integer
--- @param grown otto.Fold
local function refold(bufnr, grown)
  in_windows(bufnr, function()
    local open = vim.fn.foldclosed(grown.top) == -1
    local view = vim.fn.winsaveview()
    vim.cmd(grown.top .. 'normal! zd') -- the folds inside move up a level, and nest again
    create(grown)
    if open then vim.cmd(grown.top .. 'foldopen') end
    vim.fn.winrestview(view)
  end)
end

--- @param bufnr integer
--- @param opened otto.Fold
local function open(bufnr, opened)
  opened.open = true
  in_windows(bufnr, function() vim.cmd(opened.top .. 'foldopen') end)
end

--- @param bufnr integer
--- @param closed otto.Fold
local function close(bufnr, closed)
  closed.open = false
  in_windows(bufnr, function() vim.cmd(closed.top .. 'foldclose') end)
end

--- Calls `fn` outside of the undo history, so that undoing in the prompt never removes output. It's called with the
--- 0-indexed row where the transcript ends, and the row of the prompt. Then adds the separator above the prompt
--- @param bufnr integer
--- @param fn fun(row: integer, prompt_row: integer)
local function modify(bufnr, fn)
  local undolevels = vim.bo[bufnr].undolevels
  vim.bo[bufnr].undolevels = -1

  local prompt_row = vim.api.nvim_buf_get_mark(bufnr, ':')[1] - 1
  fn(prompt_row > 0 and is_separator(bufnr, prompt_row - 1) and prompt_row - 2 or prompt_row, prompt_row)

  prompt_row = vim.api.nvim_buf_get_mark(bufnr, ':')[1] - 1
  if prompt_row > 0 and not is_separator(bufnr, prompt_row - 1) then
    vim.api.nvim_buf_set_lines(bufnr, prompt_row, prompt_row, false, { '', '' })
    vim.api.nvim_buf_set_extmark(bufnr, separator_ns, prompt_row + 1, 0, {
      virt_text = separator,
      virt_text_pos = 'overlay',
      hl_mode = 'combine', -- keeps the cursorline
    })
  end
  vim.bo[bufnr].undolevels = undolevels
  prompt.draw(bufnr)
end

--- Removes the transcript above the row, which starts a block
--- @param bufnr integer
--- @param row integer 0-indexed
local function remove_above(bufnr, row)
  vim.api.nvim_buf_clear_namespace(bufnr, -1, 0, row)
  modify(bufnr, function() vim.api.nvim_buf_set_lines(bufnr, 0, row, false, {}) end)
  -- windows move their folds with the lines, but windows that show the buffer later fold from these
  folds[bufnr] = vim.tbl_filter(function(existing) return existing.top > row end, folds[bufnr])
  for _, existing in ipairs(folds[bufnr]) do
    existing.top = existing.top - row
    existing.bottom = existing.bottom - row
  end
end

--- Removes the oldest turns when a turn starts, so that the rest fits within the soft limit, or else all but the last
--- @param bufnr integer
local function trim_turns(bufnr)
  local count = vim.api.nvim_buf_line_count(bufnr)
  if count <= soft_limit then return end
  local row = 0
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, user_ns, 0, -1, {})) do
    row = mark[2]
    if count - row <= soft_limit then break end
  end
  if row > 0 then remove_above(bufnr, row) end
end

--- Removes everything above the newest block past the hard limit, like when a turn runs long
--- @param bufnr integer
--- @param newest integer row of the newest block
--- @return integer lines removed
local function trim_lines(bufnr, newest)
  if vim.api.nvim_buf_line_count(bufnr) <= hard_limit then return 0 end
  remove_above(bufnr, newest)
  return newest
end

--- Whether tools go right below the last block, like below the text that explains them, instead of after an empty line
--- @param session otto.Session
--- @return boolean
local function tools_follow(session) return session.tail == 'tool' or session.tail == 'text' end

--- Inserts lines at the end of the transcript. Ends the group of tools, which closes
--- @param session otto.Session
--- @param kind 'user' | 'text' | 'tool' | 'error' | 'note'
--- @param lines string[]
--- @return integer row of the first line
local function block(session, kind, lines)
  if session.group ~= nil then close(session.bufnr, session.group.fold) end
  session.group = nil
  if kind == 'user' then trim_turns(session.bufnr) end
  local start
  modify(session.bufnr, function(row)
    local spaced = row > 0 and not (kind == 'tool' and tools_follow(session))
    start = spaced and row + 1 or row
    vim.api.nvim_buf_set_lines(session.bufnr, row, row, false, spaced and { '', unpack(lines) } or lines)
    if kind == 'error' then
      local opts = { hl_group = 'DiagnosticError', end_row = start + #lines }
      vim.api.nvim_buf_set_extmark(session.bufnr, ns, start, 0, opts)
    end
    if kind == 'user' then
      local opts = {
        line_hl_group = 'OttoPrompt',
        end_row = start + #lines - 1,
      }
      vim.api.nvim_buf_set_extmark(session.bufnr, user_ns, start, 0, opts)
    end
  end)
  -- only between groups, since the rows of the group would move
  if kind ~= 'tool' then start = start - trim_lines(session.bufnr, start) end
  if kind == 'text' then session.text_row = start end
  session.tail = kind
  return start
end

--- @alias otto.Chunks [string, string?][] Text and highlight group pairs, like virtual text

--- @param chunks otto.Chunks
--- @return string
local function join(chunks)
  return vim.iter(chunks):map(function(chunk) return chunk[1] end):join('')
end

--- @param bufnr integer
--- @param namespace integer
--- @param row integer
--- @param col integer where the chunks start
--- @param chunks otto.Chunks
local function highlight(bufnr, namespace, row, col, chunks)
  for _, chunk in ipairs(chunks) do
    if chunk[2] ~= nil then
      vim.api.nvim_buf_set_extmark(bufnr, namespace, row, col, { hl_group = chunk[2], end_col = col + #chunk[1] })
    end
    col = col + #chunk[1]
  end
end

--- @param header otto.Chunks
--- @param lines string[] below the header
--- @param indent string
--- @return string[]
local function tool_lines(header, lines, indent)
  return vim.tbl_map(function(line) return indent .. line end, { join(header), unpack(lines) })
end

--- Inserts a tool block with a highlighted header, which folds the lines below it
--- @param session otto.Session
--- @param header otto.Chunks
--- @param lines string[] below the header
--- @param kind? 'tool' | 'note' Notes don't follow the text before them
--- @return integer row of the header
local function tool_block(session, header, lines, kind)
  local row = block(session, kind or 'tool', tool_lines(header, lines, ''))
  highlight(session.bufnr, ns, row, 0, header)
  fold(session.bufnr, row + 1, row + 1 + #lines, false)
  return row
end

--- @param content string | { text?: string }[]
--- @return string
local function text_of(content)
  if type(content) == 'string' then return content end
  return vim.iter(content):map(function(part) return part.text end):join('\n')
end

--- @param path string
--- @return string relative to the current folder, or the home folder
local function short(path) return vim.fn.fnamemodify(path, ':~:.') end

--- @param name string
--- @param args table
--- @return otto.Chunks
local function call(name, args)
  if name == 'bash' then
    local header = { { '$', 'OttoToolName' }, { ' ' .. first_line(args.command), 'OttoToolArg' } }
    local more = #vim.split(vim.trim(args.command), '\n') - 1
    if more > 0 then table.insert(header, { ('  +%d lines'):format(more), 'OttoToolDetail' }) end
    return header
  end
  if name == 'web_search' then return { { 'web', 'OttoToolName' }, { ' ' .. args.query, 'OttoToolArg' } } end
  if name == 'web_fetch' then
    local more = #args.urls > 1 and (' +%d'):format(#args.urls - 1) or ''
    return { { 'fetch', 'OttoToolName' }, { ' ' .. args.urls[1] .. more, 'OttoToolArg' } }
  end
  local path = type(args.path) == 'table' and table.concat(vim.tbl_map(short, args.path), ' ')
    or args.path and short(args.path)
  if args.pattern ~= nil then
    local header = { { name, 'OttoToolName' }, { ' ' .. first_line(args.pattern), 'OttoToolArg' } }
    if path then table.insert(header, { '  in ' .. path, 'OttoToolDetail' }) end
    return header
  end
  if name == 'read' and (args.offset or args.limit) then
    local first = args.offset or 1
    path = path .. ':' .. first .. (args.limit and '-' .. (first + args.limit - 1) or '')
  end
  local arg = path or args.description or vim.json.encode(args)
  return { { name, 'OttoToolName' }, { ' ' .. first_line(arg), 'OttoToolArg' } }
end

local diff_highlights = { ['+'] = 'DiffAdd', ['-'] = 'DiffDelete' }

--- Edits show their diff since that's what matters, with the changed lines highlighted
--- @param session otto.Session
--- @param header otto.Chunks
--- @param path string
--- @param diff string
local function diff_block(session, header, path, diff)
  local lines = vim.split(diff, '\n')
  local function count(prefix)
    return #vim.tbl_filter(function(line) return vim.startswith(line, prefix) end, lines)
  end
  vim.list_extend(header, { { ('  +%d'):format(count('+')), 'Added' }, { (' -%d'):format(count('-')), 'Removed' } })

  local first_changed = vim.iter(lines):map(function(line) return tonumber(line:match('^[+-]%s*(%d+)')) end):next()
  table.insert(session.edits, { filename = path, lnum = first_changed or 1, text = join(header) })

  local row = tool_block(session, header, vim.list_extend({ fence }, vim.list_extend(lines, { fence })))
  for i, line in ipairs(lines) do
    local group = diff_highlights[line:sub(1, 1)]
    if group ~= nil then vim.api.nvim_buf_set_extmark(session.bufnr, ns, row + 1 + i, 0, { line_hl_group = group }) end
  end
end

--- Other output is fenced, so that it highlights as `lang`
--- @param lines string[]
--- @param lang string
--- @return string[]
local function fenced(lines, lang)
  local hidden = #lines - max_output_lines
  lines = vim.list_slice(lines, 1, max_output_lines)
  if hidden > 0 then table.insert(lines, ('... %d more lines'):format(hidden)) end
  return { fence .. lang, unpack(vim.list_extend(lines, { fence })) }
end

--- @param group otto.Group
--- @return otto.Chunks like "read 2 files, ran 1 command"
local function summarize(group)
  local counts = {}
  local parts = {}
  for _, name in ipairs(group.names) do
    local part = summaries[name] or 'called %d tool'
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
  if group.failed == 0 then return { { text, 'OttoToolSummary' } } end
  return { { text .. ', ', 'OttoToolSummary' }, { ('%d failed'):format(group.failed), 'OttoToolFailed' } }
end

--- Starts a group, with a dot at the start of the text that explains its tools
--- @param session otto.Session
--- @return otto.Group
local function group_start(session)
  local explained = session.tail == 'text'
  if explained then
    local dot = { virt_text = { { '• ', 'NonText' } }, virt_text_pos = 'inline' }
    vim.api.nvim_buf_set_extmark(session.bufnr, ns, session.text_row, 0, dot)
  end
  --- @class otto.Group
  --- @field row? integer of the summary, which goes on its own line with the first tool, unless text explains them
  --- @field explained boolean Whether the summary goes at the end of the text that explains the tools
  --- @field fold? otto.Fold
  --- @field names string[] of the tools
  --- @field failed integer
  return { names = {}, failed = 0, explained = explained }
end

--- Adds the tool to the group of tools that follows the last text, or starts one, and updates its summary
--- @param session otto.Session
--- @param name string
--- @param failed boolean
--- @param header otto.Chunks
--- @param body string[] below the header
--- @param count integer Of what the summary counts, like the pages that one tool read
local function grouped_block(session, name, failed, header, body, count)
  local bufnr = session.bufnr
  local group = session.group or group_start(session)
  session.group = nil -- the tool doesn't end its own group
  for _ = 1, count do
    table.insert(group.names, name)
  end
  if failed then group.failed = group.failed + 1 end
  local summary = summarize(group)
  local lines = tool_lines(header, body, nested)

  local row
  if group.explained then
    row = block(session, 'tool', lines)
    group.row = group.row or row - 1
  elseif group.row == nil then
    row = block(session, 'tool', { join(summary), unpack(lines) }) + 1
    group.row = row - 1
  else
    modify(bufnr, function() vim.api.nvim_buf_set_lines(bufnr, group.row, group.row + 1, false, { join(summary) }) end)
    row = block(session, 'tool', lines)
  end
  vim.api.nvim_buf_clear_namespace(bufnr, summary_ns, group.row, group.row + 1)
  if group.explained then
    local col = #vim.api.nvim_buf_get_lines(bufnr, group.row, group.row + 1, false)[1]
    local opts = { virt_text = { { '  ' }, unpack(summary) }, virt_text_pos = 'inline' }
    vim.api.nvim_buf_set_extmark(bufnr, summary_ns, group.row, col, opts)
  else
    highlight(bufnr, summary_ns, group.row, 0, summary)
  end
  highlight(bufnr, ns, row, #nested, header)

  fold(bufnr, row + 1, row + #lines, true)
  if group.fold == nil then
    group.fold = fold(bufnr, group.row + 1, row + #lines, false)
    open(bufnr, group.fold) -- while the agent runs it
  else
    group.fold.bottom = row + #lines
    refold(bufnr, group.fold)
  end
  session.group = group
end

--- Edits and writes show what they changed, reads highlight as the file's language, and other tools group
--- @param session otto.Session
--- @param result table ToolResultMessage
local function tool(session, result)
  local tool_call = session.tools[result.toolCallId] or { name = '?', args = {} }
  session.tools[result.toolCallId] = nil
  prompt.tool_finished(session.bufnr, result.toolCallId)
  local name = tool_call.name
  local args = tool_call.args
  local header = call(name, args)
  local diff = vim.tbl_get(result, 'details', 'diff')
  if diff ~= nil then return diff_block(session, header, args.path, diff) end

  local lang = (name == 'read' or name == 'write') and vim.filetype.match({ filename = args.path })
    or name == 'web_fetch' and 'markdown'
    or 'text'
  if name == 'write' and not result.isError then
    local lines = vim.split(args.content, '\n')
    table.insert(header, { ('  +%d'):format(#lines), 'Added' })
    return tool_block(session, header, fenced(lines, lang))
  end

  local output = vim.split(vim.trim(text_of(result.content)), '\n')
  local unit = 'lines'
  -- the text of search results has HTML in it, but their details don't
  local results = name == 'web_search' and vim.tbl_get(result, 'details', 'results')
  if results then
    output = vim.tbl_map(function(item) return item.title .. '  ' .. item.url end, results)
    unit = 'results'
  end
  if result.isError then
    vim.list_extend(header, { { '  failed', 'OttoToolFailed' }, { ' ' .. output[1], 'OttoToolDetail' } })
  else
    vim.list_extend(header, { { '  done', 'OttoToolDone' }, { (' (%d %s)'):format(#output, unit), 'OttoToolDetail' } })
  end
  local count = name == 'web_fetch' and #args.urls or 1
  local body = fenced(output, lang)
  -- the header only shows the first line of commands
  local command = name == 'bash' and vim.split(vim.trim(args.command), '\n')
  if command and #command > 1 then body = vim.list_extend(fenced(command, 'bash'), body) end
  grouped_block(session, name, result.isError, header, body, count)
end

--- Folds the transcript in the current window, which has 'foldmethod' set to manual
--- @param bufnr integer
function M.fold(bufnr)
  vim.cmd('normal! zE')
  -- from the inside out, since Ex ranges include the closed folds that they touch
  for _, nested in ipairs({ true, false }) do
    for _, existing in ipairs(folds[bufnr]) do
      if existing.nested == nested then create(existing) end
    end
  end
  for _, existing in ipairs(folds[bufnr]) do
    if existing.open then vim.cmd(existing.top .. 'foldopen') end
  end
end

--- Shows the tool below the transcript until its result renders
--- @param session otto.Session
--- @param event table `tool_execution_start`
function M.tool_started(session, event)
  local header = call(aliases[event.toolName] or event.toolName, event.args)
  prompt.tool_started(session.bufnr, event.toolCallId, header, not tools_follow(session))
end

--- @param bufnr integer
--- @param row integer 0-indexed
--- @return boolean
function M.is_prompt(bufnr, row)
  return #vim.api.nvim_buf_get_extmarks(bufnr, user_ns, { row, 0 }, { row, 0 }, { overlap = true, limit = 1 }) > 0
end

--- @param bufnr integer
--- @param row integer 0-indexed
--- @param backward boolean
--- @return integer? row of the next prompt
function M.find_prompt(bufnr, row, backward)
  local start = backward and { row - 1, 0 } or { row + 1, 0 }
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, user_ns, start, backward and 0 or -1, { limit = 1 })
  return marks[1] and marks[1][2]
end

--- Removes the transcript
--- @param bufnr integer
function M.clear(bufnr)
  folds[bufnr] = {}
  prompt.clear(bufnr)
  for _, namespace in ipairs({ ns, separator_ns, user_ns, summary_ns }) do
    vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
  end
  modify(bufnr, function(_, prompt_row) vim.api.nvim_buf_set_lines(bufnr, 0, prompt_row, false, {}) end)
end

--- Removes the submitted prompt, which the prompt buffer leaves in place. It returns as a user block when pi reads it
--- @param session otto.Session
--- @param text string
function M.submitted(session, text)
  local line_count = #vim.split(text, '\n')
  modify(
    session.bufnr,
    function(_, prompt_row) vim.api.nvim_buf_set_lines(session.bufnr, prompt_row - line_count, prompt_row, false, {}) end
  )
end

--- Notes how long the agent worked, like "Worked for 2m 10s · done 4:19 p.m"
--- @param session otto.Session
--- @param seconds integer
--- @param aborted boolean
function M.worked(session, seconds, aborted)
  local time = os.date('%I:%M'):gsub('^0', '') .. (os.date('%p') == 'PM' and ' p.m' or ' a.m')
  local text = ('Worked for %s · %s %s'):format(prompt.duration(seconds), aborted and 'aborted' or 'done', time)
  local chunks = { { text, 'OttoStatusDone' } }
  highlight(session.bufnr, ns, block(session, 'note', { join(chunks) }), 0, chunks)
end

--- @param tokens integer
--- @return string like "120k"
local function thousands(tokens) return math.floor(tokens / 1000) .. 'k' end

--- @param session otto.Session
--- @param summary string
--- @param tokens_before integer
--- @param tokens_after? integer
function M.compacted(session, summary, tokens_before, tokens_after)
  local tokens = tokens_after and ('  %s -> %s tokens'):format(thousands(tokens_before), thousands(tokens_after))
    or ('  from %s tokens'):format(thousands(tokens_before))
  local header = { { 'compacted', 'OttoToolName' }, { tokens, 'OttoToolDetail' } }
  tool_block(session, header, fenced(vim.split(summary, '\n'), 'markdown'), 'note')
end

--- Renders a message once it ends, both live and when loading the session
--- @param session otto.Session
--- @param msg table AgentMessage
function M.render(session, msg)
  if msg.role == 'user' then block(session, 'user', vim.split(vim.trim(text_of(msg.content)), '\n')) end
  for _, content in ipairs(msg.role == 'assistant' and msg.content or {}) do
    if content.type == 'text' and vim.trim(content.text) ~= '' then
      block(session, 'text', vim.split(vim.trim(content.text), '\n'))
    end
    if content.type == 'toolCall' then
      session.tools[content.id] = { name = aliases[content.name] or content.name, args = content.arguments }
    end
  end
  if msg.role == 'toolResult' then tool(session, msg) end
  if msg.role == 'compactionSummary' then M.compacted(session, msg.summary, msg.tokensBefore, msg.tokensAfter) end
  if msg.errorMessage ~= nil then block(session, 'error', vim.split(msg.errorMessage, '\n')) end
end

return M
