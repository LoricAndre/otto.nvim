-- Keymaps of a session's buffer, which run the commands of `commands.lua` through <Plug>(otto-<command>) maps, like
-- <Plug>(otto-submit), which after/ftplugin/otto.lua can map too

local commands = require('otto.ui.commands')
local config = require('otto.config')

local M = {}

--- @param name string Of the command
--- @return string
local function plug(name) return ('<Plug>(otto-%s)'):format(name) end

--- Maps <Plug>(otto-<command>) of every command, which runs it in the current buffer's session
function M.define_plugs()
  for _, command in ipairs(commands.builtin) do
    vim.keymap.set(command.modes or 'n', plug(command.name), function()
      local view = require('otto.view').views[vim.api.nvim_get_current_buf()]
      if view == nil then return '' end
      return commands.run(view, command.name)
    end, { desc = 'Otto: ' .. command.description, expr = command.expr })
  end
end

--- @param lhs string
--- @param than? string
--- @return boolean Whether it's the better key to show, the one of fewer keys, like <M-x> over <localleader>x
local function shorter(lhs, than)
  if than == nil then return true end
  local keys, than_keys = #lhs:gsub('<[^<>]+>', '_'), #than:gsub('<[^<>]+>', '_')
  return keys < than_keys or keys == than_keys and #lhs < #than
end

--- @param bufnr integer
--- @return table<string, string> The key of each command that has one in the buffer, for the palette
function M.keys_by_command(bufnr)
  local keys = {}
  for _, mode in ipairs({ 'n', 'i' }) do
    local maps = vim.api.nvim_buf_get_keymap(bufnr, mode)
    local local_lhs = {}
    for _, map in ipairs(maps) do
      local_lhs[map.lhs] = true
    end
    -- unless the buffer's own hide them
    for _, map in ipairs(vim.api.nvim_get_keymap(mode)) do
      if not local_lhs[map.lhs] then table.insert(maps, map) end
    end
    for _, map in ipairs(maps) do
      local name = map.rhs and map.rhs:match('^<Plug>%(otto%-(.+)%)$')
      if name ~= nil and shorter(map.lhs, keys[name]) then keys[name] = map.lhs end
    end
  end
  return keys
end

--- Maps the configured keys, but not over the buffer's own, like those of after/ftplugin/otto.lua
--- @param view otto.View
function M.attach(view)
  local bufnr = view.bufnr
  local keymaps = config.get({ bufnr = bufnr }).keymaps
  vim.api.nvim_buf_call(bufnr, function()
    -- otto's from before a restart, which the config may have changed since
    for _, map in ipairs(vim.b.otto_keymaps or {}) do
      if vim.fn.maparg(map.lhs, map.mode, false, true).rhs == map.rhs then
        vim.keymap.del(map.mode, map.lhs, { buf = bufnr })
      end
    end
    local set = {}
    for lhs, value in pairs(keymaps or {}) do
      for mode, name in pairs(commands.by_mode(value)) do
        if vim.fn.maparg(lhs, mode, false, true).buffer ~= 1 then
          local desc = 'Otto: ' .. commands.get(name).description
          vim.keymap.set(mode, lhs, plug(name), { buf = bufnr, desc = desc })
          table.insert(set, { mode = mode, lhs = lhs, rhs = plug(name) })
        end
      end
    end
    vim.b.otto_keymaps = set
  end)
end

return M
