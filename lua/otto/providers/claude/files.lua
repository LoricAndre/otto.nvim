-- Claude Code's session files, in ~/.claude/projects/<folder>

local decode = require('otto.providers.claude.decode')

local M = {}

--- @type table<string, string> Session files by id, of the folder that they started in
M.started = {}

--- @param id string
--- @return string
function M.session_file(id)
  -- like Claude Code, which replaces each UTF-16 unit, so characters past U+FFFF take two
  local folder = vim.fn.getcwd():gsub('[%z\1-\127\194-\244][\128-\191]*', function(char)
    if char:match('^%w$') then return char end
    return #char == 4 and '--' or '-'
  end)
  return ('%s/.claude/projects/%s/%s.jsonl'):format(vim.env.HOME, folder, id)
end
--- @param file string
--- @param modified integer
--- @return otto.SessionInfo
local function read(file, modified)
  local id = vim.fs.basename(file):gsub('%.jsonl$', '')
  local info = { provider = 'claude', id = id, messages = 0, modified = modified }
  local custom, ai, first_prompt
  for line in io.lines(file) do
    if line:find('"type":"custom-title"', 1, true) then
      custom = vim.json.decode(line).customTitle
    elseif line:find('"type":"ai-title"', 1, true) then
      ai = vim.json.decode(line).aiTitle
    elseif line:find('"type":"user"', 1, true) or line:find('"type":"assistant"', 1, true) then
      info.messages = info.messages + 1
      local content = first_prompt == nil
        and line:find('"type":"user"', 1, true)
        and vim.json.decode(line).message.content
      -- tool results and the output of local commands aren't prompts
      if type(content) == 'string' and not decode.is_tagged(content) then first_prompt = content end
    end
  end
  info.name = custom or ai
  info.title = info.name or (first_prompt and vim.trim(first_prompt):gsub('%s+', ' ')) or id
  return info
end

--- @return { file: string, read: fun(file: string, modified: integer): otto.SessionInfo? }[]
function M.list()
  return vim.tbl_map(
    function(file) return { file = file, read = read } end,
    vim.fn.glob(vim.fs.dirname(M.session_file('')) .. '/*.jsonl', false, true)
  )
end

return M
