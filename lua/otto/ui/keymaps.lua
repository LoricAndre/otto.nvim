-- Keymaps of a session's buffer, which run the commands of `commands.lua`. Actions on what's under the cursor are
-- under <localleader>, which which-key lists

local commands = require('otto.ui.commands')

local M = {}

--- @type table<string, string[]> Commands by key, of their modes
M.defaults = {
  ['<CR>'] = { 'open', 'newline' },
  ['<C-s>'] = { 'submit' },
  ['<M-CR>'] = { 'follow_up' },
  ['<C-w>'] = { 'delete_word' },
  ['dd'] = { 'delete_line' },
  ['<C-c>'] = { 'abort' },
  ['<C-CR>'] = { 'send_queued' },
  [']]'] = { 'next_prompt' },
  ['[['] = { 'previous_prompt' },
  ['<M-p>'] = { 'history_older' },
  ['<M-n>'] = { 'history_newer' },
  ['<M-r>'] = { 'history' },
  ['<M-x>'] = { 'commands' },
  ['<C-p>'] = { 'model' },
  ['<S-Tab>'] = { 'effort' },
  ['<localleader>q'] = { 'edits' },
  ['<localleader>p'] = { 'prompts' },
  ['<localleader>r'] = { 'rewind_here' },
  ['<localleader>f'] = { 'fork_here' },
  ['<localleader>e'] = { 'edit_here' },
  ['<localleader>y'] = { 'yank_here' },
  ['<localleader>o'] = { 'open_here' },
  ['<localleader>t'] = { 'terminal_here' },
  ['<localleader>k'] = { 'stop_here' },
}

--- @return table<string, string> The key of each command that has one, for the palette
function M.keys()
  local keys = {}
  for lhs, names in pairs(M.defaults) do
    for _, name in ipairs(names) do
      -- the shortest, like <M-x> over <localleader>x
      if keys[name] == nil or #lhs < #keys[name] then keys[name] = lhs end
    end
  end
  for name, lhs in pairs(keys) do
    keys[name] = lhs:gsub('<localleader>', vim.g.maplocalleader or '\\')
  end
  return keys
end

--- @param session otto.Session
function M.attach(session)
  for lhs, names in pairs(M.defaults) do
    for _, name in ipairs(names) do
      local command = assert(commands.get(name), name)
      vim.keymap.set(command.modes or 'n', lhs, function() return commands.run(session, name) end, {
        buf = session.bufnr,
        desc = 'Otto: ' .. command.description,
        expr = command.expr,
      })
    end
  end
end

return M
