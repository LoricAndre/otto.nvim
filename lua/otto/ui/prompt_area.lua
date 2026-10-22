-- Around the prompt: the tools that are running and what the agent is doing, for how long, at the end of the
-- transcript, and the prompts that it hasn't read yet, above the separator above the prompt

local tools = require('otto.render.tools')

local ns = vim.api.nvim_create_namespace('otto.prompt')
local slow = 3000 -- milliseconds before running tools show for how long they've run, since most finish sooner
local labels = { working = 'Working', thinking = 'Thinking', compacting = 'Compacting' }

--- @class otto.PromptArea
--- @field bufnr integer
--- @field state otto.State
--- @field layout otto.Layout With the tools that are running
--- @field started table<string, integer> When the tools started, in milliseconds of the event loop
--- @field timer? uv.uv_timer_t Counting the time while the agent works
local Area = {}
Area.__index = Area

local M = {}

--- @param bufnr integer
--- @param state otto.State
--- @param layout otto.Layout
--- @return otto.PromptArea
function M.new(bufnr, state, layout)
  return setmetatable({ bufnr = bufnr, state = state, layout = layout, started = {} }, Area)
end

--- Keeps the end of the buffer at the bottom of the window while in the prompt, as output arrives above it and folds
--- change, so that the prompt stays in view without scrolling past the end
--- @param bufnr integer
function M.pin(bufnr)
  if vim.api.nvim_get_current_buf() ~= bufnr then return end
  if vim.fn.line('.') < vim.api.nvim_buf_get_mark(bufnr, ':')[1] then return end
  local cursor = vim.api.nvim_win_get_cursor(0)
  -- the prompt can span lines, and the cursor may not be on the last
  vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(bufnr), 0 })
  vim.cmd('normal! zb')
  vim.api.nvim_win_set_cursor(0, cursor)
end

--- Draws the area again, after the transcript or the state changed
function Area:draw()
  local bufnr = self.bufnr
  local state = self.state
  local row = vim.api.nvim_buf_get_mark(bufnr, ':')[1] - 1
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

  local lines = {}
  local started = {}
  for _, running in ipairs(state.working and self.layout.running or {}) do
    started[running.id] = self.started[running.id] or vim.uv.now()
    local line = { { '  ' } } -- nested in a group
    for _, chunk in ipairs(tools.header(running.tool, running.args)) do
      -- without their filetype, which virtual text doesn't take
      table.insert(line, { chunk[1], chunk[2] })
    end
    local elapsed = vim.uv.now() - started[running.id]
    if elapsed >= slow then
      table.insert(line, { '  ' .. tools.duration(math.floor(elapsed / 1000)), 'OttoStatusTime' })
    end
    table.insert(lines, line)
  end
  self.started = started
  -- like the tools will be once they finish
  local tail = self.layout.tail
  if #lines > 0 and tail ~= 'tool' and tail ~= 'text' then table.insert(lines, 1, {}) end
  if state.working ~= nil then
    local elapsed = tools.duration(math.floor((vim.uv.now() - state.since) / 1000))
    -- the empty line before the separator spaces it below
    local status = { { labels[state.working] .. '...', 'OttoStatus' }, { ' ' .. elapsed, 'OttoStatusTime' } }
    vim.list_extend(lines, { {}, status })
  end
  if #state.queue > 0 then table.insert(lines, {}) end
  for _, queued in ipairs(state.queue) do
    for j, line in ipairs(vim.split(queued.text, '\n')) do
      local kind = j == 1 and queued.follow_up and '  follow-up' or ''
      table.insert(lines, { { line, 'OttoQueued' }, { kind, 'OttoQueued' } })
    end
  end
  if #lines > 0 then
    -- above the separator, or above the prompt before the first block renders
    if row == 0 and #lines[1] == 0 then table.remove(lines, 1) end
    local opts = { virt_lines = lines, virt_lines_above = true }
    vim.api.nvim_buf_set_extmark(bufnr, ns, math.max(row - 2, 0), 0, opts)
  end
  M.pin(bufnr)
end

--- Counts the time while the agent works, and draws the area again
function Area:update()
  if self.state.working ~= nil and self.timer == nil then
    self.timer = vim.uv.new_timer()
    self.timer:start(
      1000,
      1000,
      vim.schedule_wrap(function()
        if vim.api.nvim_buf_is_loaded(self.bufnr) then self:draw() end
      end)
    )
  elseif self.state.working == nil and self.timer ~= nil then
    self:close()
  end
  self:draw()
end

function Area:close()
  if self.timer == nil then return end
  self.timer:close()
  self.timer = nil
end

return M
