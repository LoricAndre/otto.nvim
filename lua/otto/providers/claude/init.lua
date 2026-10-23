-- Claude Code: `claude -p` with stream-json in both directions. Its session files and its stream hold the same
-- entries, which `decode.lua` turns into the log. `stream.lua` runs its process, and `files.lua` lists the saved
-- sessions

local files = require('otto.providers.claude.files')
local stream = require('otto.providers.claude.stream')
local util = require('otto.util')

local M = { name = 'claude', icon = '󰛄  ' }

--- @return string random UUID, which Claude Code requires for session ids
function M.new_id() return util.uuid() end

M.open = stream.open
M.files = files.list

return M
