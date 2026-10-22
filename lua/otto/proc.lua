-- A process that speaks JSONL on stdin and stdout, like the agents' RPC modes, with requests that it responds to

local util = require('otto.util')

--- @class otto.Proc
--- @field name string Shown in errors
--- @field system vim.SystemObj
--- @field closed boolean
--- @field stderr? string
--- @field seq integer
--- @field pending table<string, fun(err?: string, data?: any)> Response callbacks by request id
local Proc = {}
Proc.__index = Proc

local M = {}

--- @class otto.ProcOpts
--- @field name string
--- @field on_message fun(msg: table) On the main loop
--- @field on_exit? fun(code: integer) When it exits without being closed
--- @field env? table<string, string>

--- @param cmd string[]
--- @param opts otto.ProcOpts
--- @return otto.Proc
function M.start(cmd, opts)
  local proc = setmetatable({ name = opts.name, closed = false, seq = 0, pending = {} }, Proc)

  -- split only on LF, since JSON strings can contain U+2028
  local partial = ''
  local function on_stdout(_, data)
    local lines = vim.split(partial .. (data or ''), '\n')
    -- the last line is whole once stdout closes
    partial = data and table.remove(lines) or ''
    for _, line in ipairs(lines) do
      if proc.closed then return end
      if line ~= '' then
        -- one bad line or handler doesn't lose the lines after it
        local ok, err = pcall(
          function() opts.on_message(vim.json.decode(line, { luanil = { object = true, array = true } })) end
        )
        if not ok then util.notify(proc.name .. ': ' .. tostring(err)) end
      end
    end
  end

  local system_opts = { stdin = true, stdout = vim.schedule_wrap(on_stdout), env = opts.env }
  -- the end of it, which errors usually are
  system_opts.stderr = function(_, data) proc.stderr = data and ((proc.stderr or '') .. data):sub(-2000) or proc.stderr end
  proc.system = vim.system(cmd, system_opts, function(out)
    if proc.closed then return end
    vim.schedule(function()
      if out.code ~= 0 or out.signal ~= 0 then
        util.notify(proc.name .. ' exited: ' .. (proc.stderr and vim.trim(proc.stderr) or out.code))
      end
      -- requests that it never responded to
      for id in pairs(proc.pending) do
        proc:respond(id, proc.name .. ' exited')
      end
      if opts.on_exit then opts.on_exit(out.code) end
    end)
  end)
  return proc
end

--- Starts a provider's agent, with otto's arguments between the configured command and arguments
--- @param config otto.ProviderConfig
--- @param args string[] Otto's
--- @param opts otto.ProcOpts Its `env` goes under the configured one
--- @return otto.Proc
function M.start_provider(config, args, opts)
  local cmd = vim.list_extend(vim.list_extend(vim.deepcopy(config.cmd), args), config.args)
  return M.start(cmd, vim.tbl_extend('force', opts, { env = vim.tbl_extend('force', opts.env or {}, config.env) }))
end

--- @param msg table
function Proc:send(msg)
  if self.system:is_closing() then return util.notify(self.name .. ' is not running') end
  self.system:write(vim.json.encode(msg) .. '\n')
end

--- Sends a request, which `frame` makes around its id, and calls back once `respond` gets its response
--- @param frame fun(id: integer): table
--- @param callback? fun(err?: string, data?: any) Notifies errors by default
function Proc:request(frame, callback)
  callback = callback or function(err)
    if err ~= nil then util.notify(err) end
  end
  -- which would never respond
  if self.system:is_closing() then return callback(self.name .. ' is not running') end
  self.seq = self.seq + 1
  self.pending[tostring(self.seq)] = callback
  self:send(frame(self.seq))
end

--- Awaits a request inside a task, raising its error
--- @async
--- @param frame fun(id: integer): table
--- @return any
function Proc:call(frame)
  return util.await(function(callback) self:request(frame, callback) end)
end

--- @param id string | integer Of the request
--- @param err? string
--- @param data? any
function Proc:respond(id, err, data)
  local callback = self.pending[tostring(id)]
  self.pending[tostring(id)] = nil
  if callback ~= nil then callback(err, data) end
end

function Proc:close()
  self.closed = true
  if not self.system:is_closing() then self.system:kill('sigterm') end
end

return M
