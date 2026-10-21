-- Around the prompt: the tools that are running and what the agent is doing, for how long, at the end of the transcript,
-- and the messages that it hasn't read yet, above the separator above the prompt

local M = {}

local ns = vim.api.nvim_create_namespace('otto.prompt')

--- @class otto.PromptArea
--- @field status? string What the agent is doing, like "Working"
--- @field since? integer When the agent started, in milliseconds of the event loop
--- @field timer? uv.uv_timer_t Counting the time while the agent works
--- @field running { id: string, header: otto.Chunks, spaced: boolean, started: integer }[] Tools that haven't
--- finished
--- @field queue [string, string][] Messages that pi hasn't read yet, and their kind

local areas = {} --- @type table<integer, otto.PromptArea> by buffer
local slow = 3000 -- milliseconds before a running tool shows, since most finish sooner

--- @param bufnr integer
function M.clear(bufnr) areas[bufnr] = { running = {}, queue = {} } end

--- @param seconds integer
--- @return string like "2m 10s"
function M.duration(seconds)
  if seconds < 60 then return seconds .. 's' end
  if seconds < 3600 then return ('%dm %ds'):format(math.floor(seconds / 60), seconds % 60) end
  return ('%dh %dm'):format(math.floor(seconds / 3600), math.floor(seconds % 3600 / 60))
end

--- Draws the area again, after the transcript changed
--- @param bufnr integer
function M.draw(bufnr)
  local area = areas[bufnr]
  local row = vim.api.nvim_buf_get_mark(bufnr, ':')[1] - 1
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  -- the agent only queues messages after the first, so there's always a transcript and a separator
  if row == 0 then return end

  local running = vim.tbl_filter(function(tool) return vim.uv.now() - tool.started >= slow end, area.running)
  local lines = vim.tbl_map(function(tool) return { { '  ' }, unpack(tool.header) } end, running) -- nested in a group
  if #running > 0 and running[1].spaced then table.insert(lines, 1, {}) end -- like the tools will be once they finish
  if area.status ~= nil then
    local elapsed = M.duration(math.floor((vim.uv.now() - area.since) / 1000))
    -- the empty line before the separator spaces it below
    local status = { { area.status .. '...', 'OttoStatus' }, { ' ' .. elapsed, 'OttoStatusTime' } }
    vim.list_extend(lines, { {}, status })
  end
  if #area.queue > 0 then table.insert(lines, {}) end
  for _, message in ipairs(area.queue) do
    for j, line in ipairs(vim.split(message[1], '\n')) do
      table.insert(lines, { { line, 'OttoQueued' }, { j == 1 and message[2] or '', 'OttoQueued' } })
    end
  end
  if #lines > 0 then
    vim.api.nvim_buf_set_extmark(bufnr, ns, row - 2, 0, { virt_lines = lines, virt_lines_above = true })
  end
  M.pin(bufnr)
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

--- @param bufnr integer
--- @param status? string like "Working", or nil when the agent stops, which also drops the tools that didn't finish
function M.set_status(bufnr, status)
  local area = areas[bufnr]
  if area.status == nil and status ~= nil then
    area.since = vim.uv.now()
    area.timer = vim.uv.new_timer()
    area.timer:start(
      1000,
      1000,
      vim.schedule_wrap(function()
        if vim.api.nvim_buf_is_valid(bufnr) then M.draw(bufnr) end
      end)
    )
  elseif status == nil and area.timer ~= nil then
    area.timer:close()
    area.timer = nil
    area.running = {}
  end
  area.status = status
  M.draw(bufnr)
end

--- @param bufnr integer
--- @param id string
--- @param header otto.Chunks
--- @param spaced boolean Whether an empty line comes before the tool
function M.tool_started(bufnr, id, header, spaced)
  table.insert(areas[bufnr].running, { id = id, header = header, spaced = spaced, started = vim.uv.now() })
  vim.defer_fn(function()
    if vim.api.nvim_buf_is_valid(bufnr) then M.draw(bufnr) end
  end, slow)
end

--- @param bufnr integer
--- @param id string
function M.tool_finished(bufnr, id)
  local area = areas[bufnr]
  area.running = vim.tbl_filter(function(running) return running.id ~= id end, area.running)
  M.draw(bufnr)
end

--- @param bufnr integer
--- @return boolean
function M.has_queue(bufnr) return #areas[bufnr].queue > 0 end

--- @param bufnr integer
--- @param steering string[]
--- @param follow_up string[]
function M.set_queue(bufnr, steering, follow_up)
  areas[bufnr].queue = vim.list_extend(
    vim.tbl_map(function(text) return { text, '' } end, steering),
    vim.tbl_map(function(text) return { text, '  follow-up' } end, follow_up)
  )
  M.draw(bufnr)
end

return M
