local M = {}

--- @param message string
--- @param level? integer
function M.notify(message, level) vim.notify('otto: ' .. message, level or vim.log.levels.ERROR) end

--- Runs `fn` as a task, notifying its error
--- @param fn async fun()
function M.run(fn)
  -- detached, since a task started inside another would report its error twice, and be closed when the other fails
  vim.async.run(fn):detach():on_complete(function(err)
    if err ~= nil then M.notify(tostring(err)) end
  end)
end

--- `vim.ui.select` inside a task
--- @async
--- @param items any[]
--- @param opts table
--- @return any?
function M.select(items, opts) return vim.async.await(3, vim.ui.select, items, opts) end

--- `vim.ui.input` inside a task
--- @async
--- @param opts table
--- @return string?
function M.input(opts) return vim.async.await(2, vim.ui.input, opts) end

--- Awaits a function that takes a callback of an error and data, raising the error
--- @async
--- @param fn fun(callback: fun(err?: string, data?: any))
--- @return any
function M.await(fn)
  local err, data = vim.async.await(1, fn)
  if err ~= nil then error(err, 0) end
  return data
end

--- @param text string
--- @return string without the whitespace at its end, unlike `vim.trim`, which would shift the lines of file contents
function M.trim_end(text) return text:match('^(.*%S)') or '' end

--- @param path string
--- @return string relative to the current folder, or the home folder
function M.short(path) return vim.fn.fnamemodify(path, ':~:.') end

--- @return string random version 4 UUID
function M.uuid()
  local hex = vim.iter({ vim.uv.random(16):byte(1, 16) }):map(function(byte) return ('%02x'):format(byte) end):join('')
  local variant = ('%x'):format(8 + tonumber(hex:sub(17, 17), 16) % 4)
  return ('%s-%s-4%s-%s%s-%s'):format(
    hex:sub(1, 8),
    hex:sub(9, 12),
    hex:sub(14, 16),
    variant,
    hex:sub(18, 20),
    hex:sub(21)
  )
end

return M
