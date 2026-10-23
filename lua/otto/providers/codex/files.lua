-- Codex's session files, in ~/.codex/sessions, of every folder, which are only listed, since they hold items of
-- another kind than the app-server's

local M = {}

--- @param file string
--- @param modified integer
--- @return otto.SessionInfo?
local function read(file, modified)
  -- closed before returning, since this reads the sessions of every folder
  local handle = assert(io.open(file))
  local meta = vim.json.decode(handle:read('*l') or '{}').payload or {}
  handle:close()
  -- sub-agents, like its reviewer, have sessions of their own
  if meta.cwd ~= vim.fn.getcwd() or type(meta.source) ~= 'string' then return end
  local info = { provider = 'codex', id = meta.id, messages = 0, modified = modified }
  local first_prompt
  for line in io.lines(file) do
    if line:find('"type":"item_completed"', 1, true) then
      info.messages = info.messages + 1
      if first_prompt == nil and line:find('"type":"UserMessage"', 1, true) then
        local content = vim.json.decode(line).payload.item.content
        first_prompt = (content[1] or {}).text
      end
    -- of older versions, which don't save items
    elseif line:find('"type":"user_message"', 1, true) or line:find('"type":"agent_message"', 1, true) then
      info.messages = info.messages + 1
      if first_prompt == nil and line:find('"type":"user_message"', 1, true) then
        first_prompt = vim.json.decode(line).payload.message
      end
    end
  end
  info.title = first_prompt and vim.trim(first_prompt):gsub('%s+', ' ') or meta.id
  return info
end

--- @return { file: string, read: fun(file: string, modified: integer): otto.SessionInfo? }[]
function M.list()
  return vim.tbl_map(
    function(file) return { file = file, read = read } end,
    vim.fn.glob('~/.codex/sessions/**/rollout-*.jsonl', false, true)
  )
end

--- Codex keeps the names apart from the sessions
--- @return table<string, string> names by id
function M.names()
  local names = {}
  local index = vim.fs.normalize('~/.codex/session_index.jsonl')
  if vim.uv.fs_stat(index) == nil then return names end
  for line in io.lines(index) do
    local entry = vim.json.decode(line)
    names[entry.id] = entry.thread_name
  end
  return names
end

return M
