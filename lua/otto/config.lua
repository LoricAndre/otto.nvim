-- Otto's configuration, which `require('otto').setup()` merges into, or `set` with `{ bufnr }` for a session's
-- buffer, like in after/ftplugin/otto.lua. Providers read theirs when they start

--- @class (exact) otto.Config
--- @field default_provider 'pi' | 'claude' | 'codex' Of `:Otto` and new sessions
--- @field keymaps table<string, otto.Keymap> | false Of the session's buffer, false for none
--- @field providers { pi: otto.ProviderConfig, claude: otto.ClaudeConfig, codex: otto.ProviderConfig }

--- @alias otto.Keymap string | false | table<string, string | false> Command, or command by mode, like { n = 'open', i = 'newline' }

--- @class (exact) otto.ProviderConfig
--- @field cmd string[] Before otto's arguments, like { 'claude' } or a wrapper
--- @field args string[] After otto's arguments
--- @field env table<string, string>

--- @class (exact) otto.ClaudeConfig : otto.ProviderConfig
--- @field model string
--- @field effort string
--- @field permission_mode string

--- @class (exact) otto.ConfigPartial : otto.Config, {}
--- @field default_provider? 'pi' | 'claude' | 'codex'
--- @field keymaps? table<string, otto.Keymap> | false
--- @field providers? { pi?: otto.ProviderConfigPartial, claude?: otto.ClaudeConfigPartial, codex?: otto.ProviderConfigPartial }

--- @class (exact) otto.ProviderConfigPartial : otto.ProviderConfig, {}
--- @field cmd? string[]
--- @field args? string[]
--- @field env? table<string, string>

--- @class (exact) otto.ClaudeConfigPartial : otto.ClaudeConfig, {}
--- @field cmd? string[]
--- @field args? string[]
--- @field env? table<string, string>
--- @field model? string
--- @field effort? string
--- @field permission_mode? string

local commands = require('otto.ui.commands')

local keymaps = {
  ['<CR>'] = { n = 'open', i = 'newline' },
  ['<C-s>'] = 'submit',
  ['<M-CR>'] = 'follow_up',
  ['<C-w>'] = 'delete_word',
  ['<C-c>'] = 'abort',
  [']]'] = 'next_prompt',
  ['[['] = 'previous_prompt',
  ['<M-p>'] = 'history_older',
  ['<M-n>'] = 'history_newer',
  ['<M-r>'] = 'history',
  ['<M-x>'] = 'commands',
  ['/'] = 'slash',
  ['@'] = 'at',
  ['<C-p>'] = 'model',
  ['<S-Tab>'] = 'effort',
  ['<localleader>q'] = 'edits',
  ['<localleader>p'] = 'prompts',
}

--- Spells keys one way, like <C-S> for <c-s>, so that the user's replace the defaults. Leaders stay, since they may be
--- set after setup
--- @param lhs string
--- @return string
local function normalize_lhs(lhs)
  return (
    lhs:gsub('<[^<>]+>', function(key)
      local lower = key:lower()
      if lower == '<leader>' then return '<Leader>' end
      if lower == '<localleader>' then return '<LocalLeader>' end
      return vim.fn.keytrans(vim.keycode(key))
    end)
  )
end

--- @param keymaps table<string, otto.Keymap>
--- @return table<string, otto.Keymap>
local function normalize(keymaps)
  local normalized = {}
  for lhs, value in pairs(keymaps) do
    normalized[type(lhs) == 'string' and normalize_lhs(lhs) or lhs] = value
  end
  return normalized
end

--- @return blink.lib.ConfigSchema
local function schema()
  local types = require('blink.lib.config').types

  local keymaps_type = types.validator('map(keycode, command | false | map(mode, command | false))', function(val)
    if type(val) ~= 'table' then return false end
    for lhs, value in pairs(val) do
      if not types.keycode.validator(lhs) then return false, ('[%s]: expected keycode'):format(tostring(lhs)) end
      if value ~= false and type(value) ~= 'string' and type(value) ~= 'table' then
        return false, ('[%s]: expected command, false or table, got %s'):format(lhs, vim.inspect(value))
      end
      for mode, name in pairs(commands.by_mode(value)) do
        local path = type(value) == 'table' and ('[%s].%s'):format(lhs, mode) or ('[%s]'):format(lhs)
        local command = type(name) == 'string' and commands.get(name)
        if not command then return false, ('%s: unknown command %s'):format(path, vim.inspect(name)) end
        if not vim.list_contains(command.modes or { 'n' }, mode) then
          return false, ('%s: %s has no keymap in this mode'):format(path, name)
        end
      end
    end
    return true
  end)

  --- @param cmd string
  --- @param extra? table
  local function provider(cmd, extra)
    return vim.tbl_extend('error', {
      cmd = { { cmd }, types.list('string') },
      args = { {}, types.list('string') },
      env = { {}, types.map('string', 'string') },
    }, extra or {})
  end

  return {
    default_provider = { 'pi', types.enum({ 'pi', 'claude', 'codex' }) },
    keymaps = { normalize(keymaps), { types.enum({ false }), keymaps_type } },
    providers = {
      pi = provider('pi'),
      claude = provider('claude', {
        model = { 'claude-opus-5-5', 'string' },
        effort = { 'high', 'string' },
        -- asks only for what its classifier doesn't allow
        permission_mode = { 'auto', 'string' },
      }),
      codex = provider('codex'),
    },
  }
end

-- created on first use, since blink.lib may be added to the runtimepath after otto loads
local cached --- @type blink.lib.Config?
local function instance()
  if cached == nil then cached = require('blink.lib.config').new(schema(), { validate = false }) end
  return cached
end

--- The current buffer, which blink.lib only tracks on BufEnter, after a session's buffer loads and its ftplugin runs
--- @param bufnr? integer
--- @return integer?
local function to_bufnr(bufnr)
  if (bufnr == nil or bufnr == 0) and not vim.in_fast_event() then return vim.api.nvim_get_current_buf() end
  return bufnr
end

local M = {}

--- @param filter? blink.lib.config.Filter
--- @return otto.Config
function M.get(filter)
  return instance().get(vim.tbl_extend('force', filter or {}, { bufnr = to_bufnr(filter and filter.bufnr) }))
end

--- @param tbl otto.ConfigPartial
--- @param opts? blink.lib.config.SetOpts
function M.set(tbl, opts)
  if type(tbl.keymaps) == 'table' then tbl = vim.tbl_extend('force', tbl, { keymaps = normalize(tbl.keymaps) }) end
  if opts and opts.bufnr ~= nil then opts = vim.tbl_extend('force', opts, { bufnr = to_bufnr(opts.bufnr) }) end
  instance().set(tbl, opts)
  return M
end

--- @type otto.Config | { get: fun(filter?: blink.lib.config.Filter): otto.Config, set: fun(tbl: otto.ConfigPartial, opts?: blink.lib.config.SetOpts) }
return setmetatable(M, {
  __index = function(_, key) return M.get()[key] end,
  __call = function(_, ...) return M.set(...) end,
})
