-- The current folder's saved sessions, read from the session files of pi (see docs/session-format.md) and Claude Code

local pick = require('otto.pick')

local M = {}

--- @class otto.SavedSession
--- @field id string
--- @field uri string Of the session's buffer, like pi://<id>
--- @field name? string Display name
--- @field title string Display name, or the first prompt
--- @field messages integer
--- @field modified integer Seconds since the epoch

local cache = {} --- @type table<string, otto.SavedSession> by file, while unmodified

--- @param file string
--- @param modified integer
--- @return otto.SavedSession
local function read_pi(file, modified)
  local id = file:match('_([^/]+)%.jsonl$')
  local session = { id = id, uri = 'pi://' .. id, messages = 0, modified = modified }
  local name, first_prompt
  -- decodes only the lines it needs, since sessions can be large
  for line in io.lines(file) do
    if line:find('"type":"session_info"', 1, true) then
      name = vim.json.decode(line).name
    elseif line:find('"type":"message"', 1, true) then
      session.messages = session.messages + 1
      if first_prompt == nil and line:find('"role":"user"', 1, true) then
        local content = vim.json.decode(line).message.content
        first_prompt = type(content) == 'string' and content or (content[1] or {}).text
      end
    end
  end
  session.name = name
  session.title = name or (first_prompt and vim.trim(first_prompt):gsub('%s+', ' ')) or id
  return session
end

--- @param file string
--- @param modified integer
--- @return otto.SavedSession
function M.read_claude(file, modified)
  local id = vim.fs.basename(file):gsub('%.jsonl$', '')
  local session = { id = id, uri = 'claude://' .. id, messages = 0, modified = modified }
  local name, first_prompt
  for line in io.lines(file) do
    if line:find('"type":"custom-title"', 1, true) then
      name = vim.json.decode(line).customTitle
    elseif line:find('"type":"ai-title"', 1, true) then
      name = name or vim.json.decode(line).aiTitle
    elseif line:find('"type":"user"', 1, true) or line:find('"type":"assistant"', 1, true) then
      session.messages = session.messages + 1
      local content = first_prompt == nil
        and line:find('"type":"user"', 1, true)
        and vim.json.decode(line).message.content
      -- tool results and the output of local commands aren't prompts
      if type(content) == 'string' and not vim.startswith(content, '<') then first_prompt = content end
    end
  end
  session.name = name
  session.title = name or (first_prompt and vim.trim(first_prompt):gsub('%s+', ' ')) or id
  return session
end

--- Newest first
--- @return otto.SavedSession[]
function M.list()
  local folder = vim.fn.getcwd():sub(2):gsub('[/\\:]', '-')
  local sessions = {}
  local folders = {
    [('~/.pi/agent/sessions/--%s--'):format(folder)] = read_pi,
    [vim.fs.dirname(require('otto.claude').session_file(''))] = M.read_claude,
  }
  for dir, read in pairs(folders) do
    for _, file in ipairs(vim.fn.glob(dir .. '/*.jsonl', false, true)) do
      local modified = vim.uv.fs_stat(file).mtime.sec
      if cache[file] == nil or cache[file].modified ~= modified then cache[file] = read(file, modified) end
      table.insert(sessions, cache[file])
    end
  end
  table.sort(sessions, function(a, b) return a.modified > b.modified end)
  return sessions
end

local units = { { 'mo', 30 * 86400 }, { 'w', 7 * 86400 }, { 'd', 86400 }, { 'h', 3600 }, { 'm', 60 } }

--- @param seconds integer
--- @return string like "4d"
local function age(seconds)
  for _, unit in ipairs(units) do
    if seconds >= unit[2] then return math.floor(seconds / unit[2]) .. unit[1] end
  end
  return 'now'
end

--- @param session otto.SavedSession
--- @return minibuffer.util.HighlightLine
local function format(session)
  -- Claude Code's ids are UUIDs, which only need their start to be told apart
  local id = vim.startswith(session.uri, 'claude://') and 'claude ' .. session.id:sub(1, 8) or session.id
  local details = ('%s  %d %4s'):format(id, session.messages, age(os.time() - session.modified))
  local width = vim.o.columns - 2 - vim.api.nvim_strwidth(details) -- the picker's margins
  return { { text = pick.column(session.title, width) .. ' ' }, { text = details, hl = 'Comment' } }
end

--- Picks a session, and opens it
function M.pick()
  local opts = {
    prompt = 'Resume session: ',
    text = function(session) return session.title .. ' ' .. session.id end,
    format = format,
  }
  pick.pick(M.list(), opts, function(session)
    if session ~= nil then vim.cmd.edit(session.uri) end
  end)
end

return M
