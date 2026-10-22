-- The winbar of a session: the agent's icon, the session's name, model, thinking level, context usage and cost

local M = {}

--- @param text string
--- @param group string
--- @return string
local function item(text, group) return ('%%#%s#%s'):format(group, (text:gsub('%%', '%%%%'))) end

local separator = item(' | ', 'OttoWinbarSeparator')

--- @param session otto.Session
--- @return string like "󰏿 investigate | model: deepseek/deepseek-v4.1-flash | effort: high"
function M.render(session)
  local state = session.state
  local context = state.context and state.window and state.context / state.window * 100
  local fields = {
    { 'model', state.model },
    { 'effort', state.effort },
    { 'context', context and ('%d%%'):format(context) },
    { 'cost', (state.cost or 0) >= 0.005 and ('$%.2f'):format(state.cost) or nil },
  }
  local bar = '  ' .. item(session.provider.icon, 'OttoWinbarIcon') .. item(state.name or state.id, 'Normal')
  for _, field in ipairs(fields) do
    if field[2] ~= nil then
      bar = bar .. separator .. item(field[1] .. ': ', 'OttoWinbarLabel') .. item(field[2], 'Normal')
    end
  end
  return bar
end

return M
