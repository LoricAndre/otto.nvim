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
  local ui = require('otto.ui').get(session.bufnr)
  local context = state.context and state.window and state.context / state.window * 100
  local subagents = #vim.tbl_filter(function(item) return item.kind == 'subagent' end, state.background)
  local fields = {
    { 'model', state.model },
    { 'subagents', subagents > 0 and tostring(subagents) or nil },
    { 'effort', state.effort },
    { 'context', context and ('%d%%'):format(context) },
    { 'cost', (state.cost or 0) >= 0.005 and ('$%.2f'):format(state.cost) or nil },
  }
  local bar = '  ' .. item(session.provider.icon, 'OttoWinbarIcon')
  -- of subagents, whose session started them
  if state.parent then
    local parent = require('otto.session').find(state.parent)
    local name = parent and (parent.state.name or parent.state.id) or state.parent:match('://(.+)')
    bar = bar .. item(name .. ' › ', 'OttoWinbarLabel')
  end
  bar = bar .. item(ui.title or state.name or state.id, 'Normal')
  for _, field in ipairs(fields) do
    if field[2] ~= nil then
      bar = bar .. separator .. item(field[1] .. ': ', 'OttoWinbarLabel') .. item(field[2], 'Normal')
    end
  end
  local keys = vim.tbl_keys(ui.statuses or {})
  table.sort(keys)
  for _, key in ipairs(keys) do
    bar = bar .. separator .. item(ui.statuses[key], 'Normal')
  end
  return bar
end

return M
