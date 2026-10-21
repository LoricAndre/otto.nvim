-- The transcript is markdown above the prompt, which only the plugin edits, and only by appending. Messages are blocks
-- separated by an empty line, except for tools, which follow the text that explains them. Their output is indented below
-- them, highlighted as its language, see `highlight.lua`. Edits fold on their own, and other tools fold under a summary
-- at the end of that text. Prompts are highlighted like the quickfix line. An empty
-- line and a separator come before the prompt being written. Long transcripts lose their oldest turns, see `trim_turns`

local highlight = require('otto.highlight')
local prompt = require('otto.prompt')

local M = {}

local ns = vim.api.nvim_create_namespace('otto')
local separator_ns = vim.api.nvim_create_namespace('otto.separators')
local user_ns = vim.api.nvim_create_namespace('otto.prompts')
local summary_ns = vim.api.nvim_create_namespace('otto.summaries')
local target_ns = vim.api.nvim_create_namespace('otto.targets')
local separator = { { ('─'):rep(500), 'OttoSeparator' } } -- clipped to the window
local max_output_lines = 50
local soft_limit = 25000 -- lines, which the transcript trims to by whole turns when a turn starts
local hard_limit = 40000 -- lines, past which it trims within a turn
local nested = '  ' -- indent of the tools in a group
local body_indent = '  ' -- of the lines below the header of a tool
local folds = {} --- @type table<integer, otto.Fold[]> by buffer, see `fold`

--- @class otto.Target A location that a line of the transcript is about, which <CR> opens
--- @field path string
--- @field lnum? integer
local targets = {} --- @type table<integer, table<integer, otto.Target>> by buffer, by extmark in `target_ns`

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
--- @field open? boolean A group of the turn that the agent is running, until it settles

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
  highlight.forget(bufnr)
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

--- Inserts lines at the end of the transcript. Ends the group of tools
--- @param session otto.Session
--- @param kind 'user' | 'text' | 'tool' | 'error' | 'note'
--- @param lines string[]
--- @return integer row of the first line
local function block(session, kind, lines)
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

--- @alias otto.Chunks { [1]: string, [2]: string?, filetype?: string }[] Text and highlight group pairs, like virtual
--- text, or text that highlights as its filetype

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
local function highlight_chunks(bufnr, namespace, row, col, chunks)
  for _, chunk in ipairs(chunks) do
    if chunk[2] ~= nil then
      vim.api.nvim_buf_set_extmark(bufnr, namespace, row, col, { hl_group = chunk[2], end_col = col + #chunk[1] })
    end
    if chunk.filetype ~= nil then highlight.lines(bufnr, row, col, { chunk[1] }, chunk.filetype) end
    col = col + #chunk[1]
  end
end

--- @class otto.Section Lines below the header of a tool
--- @field lines string[]
--- @field filetype? string Which they highlight as
--- @field locations? boolean Whether they start with locations, like `path:12:` from grep
--- @field path? string Of the file that they're lines of
--- @field first? integer Line number of the first line in the file
--- @field hidden? integer Lines past `max_output_lines`, which don't show

--- @param lines string[]
--- @param filetype? string
--- @return otto.Section
local function output(lines, filetype)
  return { lines = vim.list_slice(lines, 1, max_output_lines), filetype = filetype, hidden = #lines - max_output_lines }
end

--- @param header otto.Chunks
--- @param sections otto.Section[] below the header
--- @param indent string
--- @return string[]
local function tool_lines(header, sections, indent)
  local lines = { indent .. join(header) }
  for _, section in ipairs(sections) do
    for _, line in ipairs(section.lines) do
      table.insert(lines, indent .. body_indent .. line)
    end
    if (section.hidden or 0) > 0 then
      table.insert(lines, ('%s%s... %d more lines'):format(indent, body_indent, section.hidden))
    end
  end
  return lines
end

--- Makes <CR> on the row open the location
--- @param bufnr integer
--- @param row integer
--- @param path string
--- @param lnum? integer
local function target(bufnr, row, path, lnum)
  local id = vim.api.nvim_buf_set_extmark(bufnr, target_ns, row, 0, {})
  targets[bufnr][id] = { path = path, lnum = lnum }
end

--- Highlights the lines below the header of a tool, and makes <CR> open the locations they're about
--- @param bufnr integer
--- @param row integer of the header
--- @param indent string
--- @param sections otto.Section[]
local function highlight_sections(bufnr, row, indent, sections)
  local col = #indent + #body_indent
  for _, section in ipairs(sections) do
    if section.filetype ~= nil then highlight.lines(bufnr, row + 1, col, section.lines, section.filetype) end
    if section.locations then
      for _, location in ipairs(highlight.locations(bufnr, row + 1, col, section.lines)) do
        target(bufnr, row + location.index, location.path, location.lnum)
      end
    end
    for i = 1, section.path and #section.lines or 0 do
      target(bufnr, row + i, section.path, section.first and section.first + i - 1)
    end
    row = row + #section.lines
    if (section.hidden or 0) > 0 then
      row = row + 1
      vim.api.nvim_buf_set_extmark(
        bufnr,
        ns,
        row,
        col,
        { hl_group = 'OttoToolDetail', end_row = row + 1, strict = false }
      )
    end
  end
end

--- Inserts a tool block with a highlighted header, which folds the lines below it
--- @param session otto.Session
--- @param header otto.Chunks
--- @param sections otto.Section[] below the header
--- @param kind? 'tool' | 'note' Notes don't follow the text before them
--- @return integer row of the header
local function tool_block(session, header, sections, kind)
  local lines = tool_lines(header, sections, '')
  local row = block(session, kind or 'tool', lines)
  highlight_chunks(session.bufnr, ns, row, 0, header)
  highlight_sections(session.bufnr, row, '', sections)
  fold(session.bufnr, row + 1, row + #lines, false)
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
    -- Claude Code describes its commands, which reads better than them, while they show unfolded
    if args.description ~= nil then return { { '$', 'OttoToolName' }, { ' ' .. args.description, 'OttoToolArg' } } end
    local header = { { '$', 'OttoToolName' }, { ' ' .. first_line(args.command), filetype = 'bash' } }
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

--- Edits show their diff since that's what matters, with the changed lines highlighted, and the code as its language
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

  local row = tool_block(session, header, { { lines = lines } })
  target(session.bufnr, row, path, first_changed)
  for i, line in ipairs(lines) do
    local number = tonumber(line:match('^.%s*(%d+)'))
    if number ~= nil then target(session.bufnr, row + i, path, number) end
  end
  local filetype = vim.filetype.match({ filename = path })
  if filetype ~= nil then highlight.diff(session.bufnr, row + 1, #body_indent, lines, filetype) end
  for i, line in ipairs(lines) do
    local group = diff_highlights[line:sub(1, 1)]
    if group ~= nil then vim.api.nvim_buf_set_extmark(session.bufnr, ns, row + i, 0, { line_hl_group = group }) end
  end
end

--- Commands whose output is the content of the file that they end with, like `cat foo.lua` or `sed -n 1,20p foo.lua`
local readers = { cat = true, head = true, tail = true, sed = true, nl = true, bat = true }
--- Commands whose output starts with locations, like `path:12:`
local searchers = { rg = true, grep = true, ag = true }

--- Describes the output of a tool by what produced it
--- @param name string
--- @param args table
--- @param text string
--- @return otto.Section
local function output_of(name, args, text)
  local lines = text == '' and {} or vim.split(text, '\n')
  if name == 'read' then
    local section = output(lines, vim.filetype.match({ filename = args.path }))
    section.path = args.path
    section.first = args.offset or 1
    return section
  end
  if name == 'web_fetch' then return output(lines, 'markdown') end
  local section = output(lines)
  section.locations = name == 'grep' or name == 'search'
  if name ~= 'bash' then return section end

  local command = vim.trim(args.command)
  local program = command:match('^%S+')
  local git = command:match('^git%s+(%a+)')
  if program == 'diff' or git == 'diff' or git == 'show' then
    section.filetype = 'diff'
  elseif searchers[program] or git == 'grep' then
    section.locations = true
  -- only when the output is the file's, without pipes, redirections or other commands
  elseif readers[program] and not command:find('[|;&<>\n]') then
    section.path = command:match('(%S+)$')
    section.filetype = vim.filetype.match({ filename = section.path })
    -- the end of the file, unless it's a range like `sed -n 10,20p`
    section.first = program ~= 'tail' and tonumber(command:match("^sed %-n '?(%d+),") or 1) or nil
  elseif text:match('^[%[{]') and pcall(vim.json.decode, text) then
    section.filetype = 'json'
  end
  return section
end

--- Takes the exit code out of the output of a command, where Claude Code puts it first and pi last
--- @param text string
--- @return string output
--- @return integer? exit code
local function exit_code(text)
  local code, output = text:match('^Exit code (%d+)\n?(.*)$')
  if code == nil then
    output, code = text:match('^(.-)%s*Command exited with code (%d+)$')
  end
  if code == nil then return text end
  return output == '(no output)' and '' or output, tonumber(code)
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
--- @param sections otto.Section[] below the header
--- @param count integer Of what the summary counts, like the pages that one tool read
--- @return integer row of the header
local function grouped_block(session, name, failed, header, sections, count)
  local bufnr = session.bufnr
  local group = session.group or group_start(session)
  session.group = nil -- the tool doesn't end its own group
  for _ = 1, count do
    table.insert(group.names, name)
  end
  if failed then group.failed = group.failed + 1 end
  local summary = summarize(group)
  local lines = tool_lines(header, sections, nested)

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
    highlight_chunks(bufnr, summary_ns, group.row, 0, summary)
  end
  highlight_chunks(bufnr, ns, row, #nested, header)
  highlight_sections(bufnr, row, nested, sections)

  if #lines > 1 then fold(bufnr, row + 1, row + #lines, true) end
  if group.fold == nil then
    group.fold = fold(bufnr, group.row + 1, row + #lines, false)
    -- until the agent settles, unlike the groups of resumed sessions
    if session.started ~= nil then
      open(bufnr, group.fold)
      table.insert(session.opened, group.fold)
    end
  else
    group.fold.bottom = row + #lines
    refold(bufnr, group.fold)
  end
  prompt.pin(bufnr) -- the fold changed the height of the transcript
  session.group = group
  return row
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

  if name == 'write' and not result.isError then
    local lines = vim.split(args.content, '\n')
    table.insert(header, { ('  +%d'):format(#lines), 'Added' })
    local section = output(lines, vim.filetype.match({ filename = args.path }))
    section.path = args.path
    section.first = 1
    return target(session.bufnr, tool_block(session, header, { section }), args.path)
  end

  local text = vim.trim(text_of(result.content))
  local unit = 'lines'
  -- the text of search results has HTML in it, but their details don't
  local results = name == 'web_search' and vim.tbl_get(result, 'details', 'results')
  if results then
    text = table.concat(vim.tbl_map(function(item) return item.title .. '  ' .. item.url end, results), '\n')
    unit = 'results'
  end
  local code = vim.tbl_get(result, 'details', 'exitCode')
  if name == 'bash' and code == nil then
    text, code = exit_code(text)
  end
  local section = output_of(name, args, text)
  local lines = section.lines
  local size = ('(%d %s)'):format(#lines + math.max(section.hidden, 0), unit)
  -- commands only say how they ended when they fail
  if name == 'bash' and (code or 0) ~= 0 then
    table.insert(header, { '  exit ' .. code, 'OttoToolFailed' })
    if #lines > 0 then table.insert(header, { ' ' .. size, 'OttoToolDetail' }) end
  elseif result.isError then
    vim.list_extend(header, { { '  failed', 'OttoToolFailed' }, { ' ' .. (lines[1] or ''), 'OttoToolDetail' } })
  elseif name == 'bash' then
    if #lines > 0 then table.insert(header, { '  ' .. size, 'OttoToolDetail' }) end
  else
    vim.list_extend(header, { { '  done', 'OttoToolDone' }, { ' ' .. size, 'OttoToolDetail' } })
  end
  local count = name == 'web_fetch' and #args.urls or 1
  local sections = #lines > 0 and { section } or {}
  -- the header only shows the description or first line of commands
  local command = name == 'bash' and vim.split(vim.trim(args.command), '\n')
  if command and (#command > 1 or args.description ~= nil) then table.insert(sections, 1, output(command, 'bash')) end
  local row = grouped_block(session, name, result.isError, header, sections, count)
  if section.path ~= nil then target(session.bufnr, row, section.path, section.first) end
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
--- @return otto.Target? that the row is about, like the file and line of a line in a diff
function M.target_at(bufnr, row)
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, target_ns, { row, 0 }, { row, -1 }, { limit = 1 })
  return marks[1] and targets[bufnr][marks[1][1]]
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
  targets[bufnr] = {}
  prompt.clear(bufnr)
  highlight.clear(bufnr)
  for _, namespace in ipairs({ ns, separator_ns, user_ns, summary_ns, target_ns }) do
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

--- Closes the groups of tools that the agent ran
--- @param session otto.Session
function M.settled(session)
  for _, opened in ipairs(session.opened) do
    -- unless the line limit removed it
    if vim.list_contains(folds[session.bufnr], opened) then close(session.bufnr, opened) end
  end
  session.opened = {}
  prompt.pin(session.bufnr)
end

--- Notes how long the agent worked, like "Worked for 2m 10s · done 4:19 p.m"
--- @param session otto.Session
--- @param seconds integer
--- @param aborted boolean
function M.worked(session, seconds, aborted)
  local time = os.date('%I:%M'):gsub('^0', '') .. (os.date('%p') == 'PM' and ' p.m' or ' a.m')
  local text = ('Worked for %s · %s %s'):format(prompt.duration(seconds), aborted and 'aborted' or 'done', time)
  local chunks = { { text, 'OttoStatusDone' } }
  highlight_chunks(session.bufnr, ns, block(session, 'note', { join(chunks) }), 0, chunks)
end

--- @param tokens integer
--- @return string like "120k"
local function thousands(tokens) return math.floor(tokens / 1000) .. 'k' end

--- @param session otto.Session
--- @param summary? string which Codex doesn't share
--- @param tokens_before? integer
--- @param tokens_after? integer
function M.compacted(session, summary, tokens_before, tokens_after)
  local tokens = tokens_after and ('  %s -> %s tokens'):format(thousands(tokens_before), thousands(tokens_after))
    or tokens_before and ('  from %s tokens'):format(thousands(tokens_before))
  local header = { { 'compacted', 'OttoToolName' }, tokens and { tokens, 'OttoToolDetail' } or nil }
  if summary == nil then
    return highlight_chunks(session.bufnr, ns, block(session, 'note', { join(header) }), 0, header)
  end
  tool_block(session, header, { { lines = vim.split(summary, '\n'), filetype = 'markdown' } }, 'note')
end

--- Renders a message once it ends, both live and when loading the session
--- @param session otto.Session
--- @param msg table AgentMessage
function M.render(session, msg)
  local function markdown(kind, text)
    local lines = vim.split(vim.trim(text), '\n')
    highlight.lines(session.bufnr, block(session, kind, lines), 0, lines, 'markdown')
  end
  if msg.role == 'user' then markdown('user', text_of(msg.content)) end
  for _, content in ipairs(msg.role == 'assistant' and msg.content or {}) do
    if content.type == 'text' and vim.trim(content.text) ~= '' then markdown('text', content.text) end
    if content.type == 'toolCall' then
      session.tools[content.id] = { name = aliases[content.name] or content.name, args = content.arguments }
    end
  end
  if msg.role == 'toolResult' then tool(session, msg) end
  if msg.role == 'compactionSummary' then M.compacted(session, msg.summary, msg.tokensBefore, msg.tokensAfter) end
  if msg.errorMessage ~= nil then block(session, 'error', vim.split(msg.errorMessage, '\n')) end
end

return M
