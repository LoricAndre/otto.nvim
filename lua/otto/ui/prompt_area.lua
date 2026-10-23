-- Around the prompt: the tools that are running and what the agent is doing, for how long, at the end of the
-- transcript, and the prompts that it hasn't read yet, above the separator above the prompt

local tools = require('otto.render.tools')

local ns = vim.api.nvim_create_namespace('otto.prompt')
local slow = 3000 -- milliseconds before running tools show for how long they've run, since most finish sooner
local labels = { working = 'Working', thinking = 'Thinking', compacting = 'Compacting' }

--- @class otto.PromptArea
--- @field bufnr integer
--- @field session otto.Session With the tools that are running
--- @field layout otto.Layout Which spaces the area like the next block
--- @field started table<string, integer> When the tools started, in milliseconds of the event loop
--- @field timer? uv.uv_timer_t Counting the time while the agent works
local Area = {}
Area.__index = Area

local M = {}

--- @param bufnr integer
--- @param session otto.Session
--- @param layout otto.Layout
--- @return otto.PromptArea
function M.new(bufnr, session, layout)
  return setmetatable({ bufnr = bufnr, session = session, layout = layout, started = {} }, Area)
end

--- Where the window shows the prompt, which the separator isn't part of
--- @class otto.View
--- @field height integer Of the window
--- @field offset? integer From the prompt of the line at the bottom, or nil for the end of the buffer

--- Remembers where the window shows the prompt
--- @param win integer
function M.watch(win)
  local bufnr = vim.api.nvim_win_get_buf(win)
  vim.w[win].otto_view = vim.api.nvim_win_call(win, function()
    local bottom = vim.fn.line('w$')
    local prompt = vim.api.nvim_buf_get_mark(bufnr, ':')[1]
    if bottom < prompt then return nil end
    local offset = bottom < vim.api.nvim_buf_line_count(bufnr) and bottom - prompt or nil
    return { height = vim.api.nvim_win_get_height(win), offset = offset }
  end)
end

--- Puts the line of the view back at the bottom of the window
--- @param win integer
local function scroll(win)
  local view = vim.w[win].otto_view --- @type otto.View?
  if view == nil then return end
  local bufnr = vim.api.nvim_win_get_buf(win)
  vim.api.nvim_win_call(win, function()
    local last = vim.api.nvim_buf_line_count(bufnr)
    local prompt = vim.api.nvim_buf_get_mark(bufnr, ':')[1]
    local cursor = vim.api.nvim_win_get_cursor(win)
    local scrolloff = vim.api.nvim_get_option_value('scrolloff', { win = win, scope = 'local' })
    vim.wo[win].scrolloff = 0 -- so that the line goes to the very bottom
    vim.api.nvim_win_set_cursor(win, { math.min(prompt + (view.offset or last), last), 0 })
    vim.cmd('normal! zb')
    vim.api.nvim_set_option_value('scrolloff', scrolloff, { win = win, scope = 'local' })
    -- in the transcript, the cursor moves with the text like with <C-e>
    vim.cmd('normal! H')
    if cursor[1] >= vim.fn.line('.') then vim.api.nvim_win_set_cursor(win, cursor) end
  end)
end

--- Keeps the same lines of the prompt in view in the windows that show it, as output arrives above it and folds
--- change. With the end of the buffer at the bottom, that's the whole prompt, without scrolling past the end
--- @param bufnr integer
function M.follow(bufnr)
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    scroll(win)
    M.watch(win)
  end
end

--- Keeps the same line at the bottom when the window's height changed, like when the command line grows, and otherwise
--- remembers where it scrolled to
--- @param win integer
function M.scrolled(win)
  local view = vim.w[win].otto_view
  if view ~= nil and view.height ~= vim.api.nvim_win_get_height(win) then scroll(win) end
  M.watch(win)
end

--- Draws the area again, after the transcript or the state changed
function Area:draw()
  local bufnr = self.bufnr
  local state = self.session.state
  local row = vim.api.nvim_buf_get_mark(bufnr, ':')[1] - 1
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

  local lines = {}
  local started = {}
  for _, running in ipairs(state.working and self.session.running or {}) do
    started[running.id] = self.started[running.id] or vim.uv.now()
    local line = { { '  ' } } -- nested in a group
    local call = tools.call(running.tool, running.args)
    for _, chunk in ipairs(tools.header(call.tool, call.args)) do
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
  M.follow(bufnr)
end

--- Counts the time while the agent works, and draws the area again
function Area:update()
  local running = self.session.state.working ~= nil
  if running and self.timer == nil then
    self.timer = vim.uv.new_timer()
    self.timer:start(
      1000,
      1000,
      vim.schedule_wrap(function()
        if vim.api.nvim_buf_is_loaded(self.bufnr) then self:draw() end
      end)
    )
  elseif not running and self.timer ~= nil then
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
