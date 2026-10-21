-- The winbar of a session: the agent's icon, the session's name, model, thinking level, context usage and cost

local M = {}

-- of the agents, with the space after them, since Claude's is two cells wide
local icons = { pi = '󰏿 ', claude = '󰛄  ' }

--- @class otto.State
--- @field name? string
--- @field model? string id, like deepseek/deepseek-v4.1-flash
--- @field thinking? string When the model reasons
--- @field context? number Percent of the context window that the session uses
--- @field cost number Dollars

--- Loads the state that the winbar shows
--- @async
--- @param session otto.Session
function M.refresh(session)
  local state = session.client:call({ type = 'get_state' })
  local stats = session.client:call({ type = 'get_session_stats' })
  session.state = {
    name = state.sessionName,
    model = state.model and state.model.id,
    thinking = state.model and state.model.reasoning and state.thinkingLevel or nil,
    context = vim.tbl_get(stats, 'contextUsage', 'percent'),
    cost = stats.cost,
  }
  vim.cmd.redrawstatus({ bang = true })
end

--- @param text string
--- @param group string
--- @return string
local function item(text, group) return ('%%#%s#%s'):format(group, (text:gsub('%%', '%%%%'))) end

local separator = item(' | ', 'OttoWinbarSeparator')

--- @param session otto.Session
--- @return string like "󰏿 investigate | model: deepseek/deepseek-v4.1-flash | effort: high"
function M.render(session)
  local state = session.state or { cost = 0 }
  local fields = {
    { 'model', state.model },
    { 'effort', state.thinking },
    { 'context', state.context and ('%d%%'):format(state.context) },
    { 'cost', state.cost >= 0.005 and ('$%.2f'):format(state.cost) or nil },
  }
  local bar = '  ' .. item(icons[session.backend], 'OttoWinbarIcon') .. item(state.name or session.id, 'Normal')
  for _, field in ipairs(fields) do
    if field[2] ~= nil then
      bar = bar .. separator .. item(field[1] .. ': ', 'OttoWinbarLabel') .. item(field[2], 'Normal')
    end
  end
  return bar
end

return M
