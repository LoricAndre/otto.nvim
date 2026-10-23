-- pi's session files, in ~/.pi/agent/sessions/<folder>

local event = require('otto.event')

local M = {}

--- @return string folder of the current folder's sessions
local function folder()
  return ('%s/.pi/agent/sessions/--%s--'):format(vim.env.HOME, (vim.fn.getcwd():sub(2):gsub('[/\\:]', '-')))
end

--- @param id string
--- @return string? path of the session's file
function M.session_file(id)
  -- files are named <time>_<id>.jsonl, and `*_fix.jsonl` would match the id auth_fix too
  return vim
    .iter(vim.fn.glob(('%s/*_%s.jsonl'):format(folder(), id), false, true))
    :find(function(file) return vim.fs.basename(file):match('^[^_]*_(.+)%.jsonl$') == id end)
end
--- @param file string
--- @param modified integer
--- @return otto.SessionInfo
local function read(file, modified)
  local id = file:match('_([^/]+)%.jsonl$')
  local info = { provider = 'pi', id = id, messages = 0, modified = modified }
  local first_prompt
  -- decodes only the lines it needs, since sessions can be large
  for line in io.lines(file) do
    if line:find('"type":"session_info"', 1, true) then
      info.name = vim.json.decode(line).name
    elseif line:find('"type":"message"', 1, true) then
      info.messages = info.messages + 1
      if first_prompt == nil and line:find('"role":"user"', 1, true) then
        -- not prompts of only images
        local text = event.text_of(vim.json.decode(line).message.content)
        if vim.trim(text) ~= '' then first_prompt = text end
      end
    end
  end
  info.title = info.name or (first_prompt and vim.trim(first_prompt):gsub('%s+', ' ')) or id
  return info
end

--- @return { file: string, read: fun(file: string, modified: integer): otto.SessionInfo? }[]
function M.list()
  return vim.tbl_map(
    function(file) return { file = file, read = read } end,
    vim.fn.glob(folder() .. '/*.jsonl', false, true)
  )
end

return M
