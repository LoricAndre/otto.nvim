-- pi: `pi --mode rpc`. Its session files and its events hold the same messages, which `decode.lua` turns into the log.
-- `stream.lua` runs its process, and `files.lua` finds and lists its session files

local files = require('otto.providers.pi.files')
local stream = require('otto.providers.pi.stream')

local M = { name = 'pi', icon = '󰏿 ' }

--- @param name? string
--- @return string id of a new session, which is its name, or when it started
function M.new_id(name)
  -- which pi requires to start and end with a letter or digit
  local id = (name or ''):gsub('[^%w._-]+', '_'):gsub('^[^%w]+', ''):gsub('[^%w]+$', '')
  if id == '' then id = os.date('%Y_%m_%d_%H%M%S') end
  -- pi resumes the session of an id that exists
  if files.session_file(id) ~= nil then id = id .. '_' .. os.date('%H%M%S') end
  return id
end

M.open = stream.open
M.files = files.list

return M
