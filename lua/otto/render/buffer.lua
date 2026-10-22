-- The transcript is above the prompt, which only the plugin edits, and only by appending the blocks of `layout.lua`.
-- Tool output is indented below its header, highlighted as its language, see `highlight.lua`. Prompts are highlighted
-- like the quickfix line. An empty line and a separator come before the prompt being written

local folds = require('otto.render.folds')
local highlight = require('otto.highlight')
local layout = require('otto.render.layout')
local tools = require('otto.render.tools')

local ns = vim.api.nvim_create_namespace('otto')
local separator_ns = vim.api.nvim_create_namespace('otto.separators')
local user_ns = vim.api.nvim_create_namespace('otto.prompts')
local call_ns = vim.api.nvim_create_namespace('otto.calls')
local summary_ns = vim.api.nvim_create_namespace('otto.summaries')
local target_ns = vim.api.nvim_create_namespace('otto.targets')
local separator = { { ('─'):rep(500), 'OttoSeparator' } } -- clipped to the window

--- @class otto.Target A location that a line of the transcript is about, which <CR> opens
--- @field path string
--- @field lnum? integer

--- @class otto.Buffer
--- @field bufnr integer
--- @field folds otto.Fold[]
--- @field targets table<integer, otto.BlockTarget> by extmark in `target_ns`, at their first line
--- @field calls table<integer, otto.BlockCall> by extmark in `call_ns`, over their tool's lines
--- @field group? otto.Fold Of the last tools, from their summary, until it folds
--- @field groups otto.Fold[] Of the turn that's running, which fold once it ends
--- @field on_change fun() After the transcript changed
local Buffer = {}
Buffer.__index = Buffer

local M = {}

--- @param bufnr integer
--- @param row integer
--- @return boolean
local function is_separator(bufnr, row)
  return #vim.api.nvim_buf_get_extmarks(bufnr, separator_ns, { row, 0 }, { row, 0 }, {}) > 0
end

--- Calls `fn` outside of the undo history, so that undoing in the prompt never removes output. It's called with the
--- 0-indexed row where the transcript ends, and the row of the prompt. Then adds the separator above the prompt
--- @param fn fun(row: integer, prompt_row: integer)
function Buffer:modify(fn)
  local bufnr = self.bufnr
  local undolevels = vim.bo[bufnr].undolevels
  vim.bo[bufnr].undolevels = -1

  local prompt_row = vim.api.nvim_buf_get_mark(bufnr, ':')[1] - 1
  -- the undo levels come back even when it fails
  local ok, err =
    pcall(fn, prompt_row > 0 and is_separator(bufnr, prompt_row - 1) and prompt_row - 2 or prompt_row, prompt_row)

  prompt_row = vim.api.nvim_buf_get_mark(bufnr, ':')[1] - 1
  if prompt_row > 0 and not is_separator(bufnr, prompt_row - 1) then
    vim.api.nvim_buf_set_lines(bufnr, prompt_row, prompt_row, false, { '', '' })
    vim.api.nvim_buf_set_extmark(bufnr, separator_ns, prompt_row + 1, 0, {
      virt_text = separator,
      virt_text_pos = 'overlay',
      hl_mode = 'combine', -- keeps the cursorline
    })
  end
  vim.bo[bufnr].undolevels = undolevels
  if not ok then error(err, 0) end
end

--- @param namespace integer
--- @param row integer
--- @param col integer where the chunks start
--- @param chunks otto.Chunks
function Buffer:highlight_chunks(namespace, row, col, chunks)
  for _, chunk in ipairs(chunks) do
    if chunk[2] ~= nil then
      vim.api.nvim_buf_set_extmark(self.bufnr, namespace, row, col, { hl_group = chunk[2], end_col = col + #chunk[1] })
    end
    if chunk.filetype ~= nil then highlight.lines(self.bufnr, row, col, { chunk[1] }, chunk.filetype) end
    col = col + #chunk[1]
  end
end

--- Inserts lines at the end of the transcript
--- @param block otto.Block
--- @param lines string[]
--- @return integer row of the first line
function Buffer:insert(block, lines)
  local bufnr = self.bufnr
  local start
  self:modify(function(row)
    local spaced = row > 0 and block.spaced
    start = spaced and row + 1 or row
    vim.api.nvim_buf_set_lines(bufnr, row, row, false, spaced and vim.list_extend({ '' }, lines) or lines)
    if block.kind == 'error' then
      vim.api.nvim_buf_set_extmark(bufnr, ns, start, 0, { hl_group = 'DiagnosticError', end_row = start + #lines })
    end
    if block.kind == 'user' then
      local opts = { line_hl_group = 'OttoPrompt', end_row = start + #lines - 1 }
      vim.api.nvim_buf_set_extmark(bufnr, user_ns, start, 0, opts)
    end
  end)
  return start
end

--- Adds the tool to its group, whose summary goes on its own line above the first
--- @param block otto.Block
--- @return integer row of the header
function Buffer:grouped(block)
  local group = block.group --[[@as { summary: otto.Chunks, first: boolean }]]
  local summary = tools.join(group.summary)
  local row
  -- or when the first failed to render
  if group.first or self.group == nil then
    row = self:insert(block, vim.list_extend({ summary }, block.lines)) + 1
    self.group = { top = row, bottom = row, nested = false }
    table.insert(self.groups, self.group)
  else
    local top = self.group.top - 1
    self:modify(function() vim.api.nvim_buf_set_lines(self.bufnr, top, top + 1, false, { summary }) end)
    row = self:insert(block, block.lines)
  end
  vim.api.nvim_buf_clear_namespace(self.bufnr, summary_ns, self.group.top - 1, self.group.top)
  self:highlight_chunks(summary_ns, self.group.top - 1, 0, group.summary)
  self.group.bottom = row + #block.lines
  return row
end

--- @param block otto.Block
function Buffer:block(block)
  local bufnr = self.bufnr
  if block.group == nil then self.group = nil end
  local row = block.group and self:grouped(block) or self:insert(block, block.lines)
  if block.markdown then highlight.lines(bufnr, row, 0, block.lines, 'markdown') end
  if block.header then self:highlight_chunks(ns, row, #block.indent, block.header) end
  local col = #(block.indent or '') + #layout.body_indent
  local first = row + 1
  for _, section in ipairs(block.sections or {}) do
    if section.filetype ~= nil then highlight.lines(bufnr, first, col, section.lines, section.filetype) end
    first = first + #section.lines + ((section.hidden or 0) > 0 and 1 or 0)
  end
  if block.diff ~= nil and block.diff.filetype ~= nil then
    highlight.diff(bufnr, row + 1, col, block.sections[1].lines, block.diff.filetype)
  end
  for _, hl in ipairs(block.highlights) do
    local opts = hl.col == nil and { line_hl_group = hl.group }
      or hl.end_col and { hl_group = hl.group, end_col = hl.end_col }
      or { hl_group = hl.group, end_row = row + hl.index + 1, strict = false }
    vim.api.nvim_buf_set_extmark(bufnr, ns, row + hl.index, hl.col or 0, opts)
  end
  if block.call ~= nil then
    local id = vim.api.nvim_buf_set_extmark(bufnr, call_ns, row, 0, { end_row = row + #block.lines - 1 })
    self.calls[id] = block.call
  end
  for _, target in ipairs(block.targets) do
    self.targets[vim.api.nvim_buf_set_extmark(bufnr, target_ns, row + target.index, 0, {})] = target
  end
  if block.fold then folds.add(bufnr, self.folds, row + 1, row + #block.lines, block.group ~= nil) end
end

--- Folds the groups of the turn, which stay open while it runs
function Buffer:settle()
  for _, group in ipairs(self.groups) do
    folds.add(self.bufnr, self.folds, group.top, group.bottom, false)
  end
  self.groups = {}
  self.group = nil
end

--- @param op otto.Op
function Buffer:apply(op)
  if op.type == 'block' then self:block(op.block) end
  if op.type == 'settle' then self:settle() end
  self.on_change()
end

--- Folds the transcript in the current window, which has 'foldmethod' set to manual
function Buffer:fold() folds.apply(self.folds) end

--- @param row integer 0-indexed
--- @return otto.Target? that the row is about, like the file and line of a line in a diff
function Buffer:target_at(row)
  -- the closest target above, which may span the row
  local marks = vim.api.nvim_buf_get_extmarks(self.bufnr, target_ns, { row, -1 }, { 0, 0 }, { limit = 1 })
  local target = marks[1] and self.targets[marks[1][1]]
  if target == nil or row >= marks[1][2] + (target.count or 1) then return end
  local line = vim.api.nvim_buf_get_lines(self.bufnr, row, row + 1, false)[1]
  if target.parse == 'diff' then
    -- removed lines are numbered in the old file, so they open at the next line of the new one
    local lines = vim.api.nvim_buf_get_lines(self.bufnr, row, marks[1][2] + target.count, false)
    local sign, lnum = line:match('^%s*([+-]?)%s*(%d+) ')
    for _, next_line in ipairs(sign == '-' and lines or {}) do
      local next_sign, next_lnum = next_line:match('^%s*([+-]?)%s*(%d+) ')
      if next_lnum == nil then break end
      if next_sign ~= '-' then
        lnum = next_lnum
        break
      end
    end
    return lnum and { path = target.path, lnum = tonumber(lnum) }
  end
  if target.parse == 'location' then
    local path, lnum = tools.location(line:sub(target.col + 1))
    return path and { path = path, lnum = tonumber(lnum) }
  end
  return { path = target.path, lnum = target.lnum and target.lnum + row - marks[1][2] }
end

--- @param row integer 0-indexed
--- @return boolean
function Buffer:is_prompt(row)
  local opts = { overlap = true, limit = 1 }
  return #vim.api.nvim_buf_get_extmarks(self.bufnr, user_ns, { row, 0 }, { row, 0 }, opts) > 0
end

--- @param mark vim.api.keyset.get_extmark_item
--- @return otto.TranscriptPrompt
function Buffer:prompt(mark)
  local lines = vim.api.nvim_buf_get_lines(self.bufnr, mark[2], mark[4].end_row + 1, false)
  return { row = mark[2], text = table.concat(lines, '\n') }
end

--- @class otto.TranscriptPrompt
--- @field row integer 0-indexed
--- @field text string

--- @return otto.TranscriptPrompt[] oldest first
function Buffer:prompts()
  local marks = vim.api.nvim_buf_get_extmarks(self.bufnr, user_ns, 0, -1, { details = true })
  return vim.tbl_map(function(mark) return self:prompt(mark) end, marks)
end

--- @param row integer 0-indexed
--- @return otto.TranscriptPrompt? that the row is in
function Buffer:prompt_at(row)
  local opts = { overlap = true, limit = 1, details = true }
  local mark = vim.api.nvim_buf_get_extmarks(self.bufnr, user_ns, { row, 0 }, { row, 0 }, opts)[1]
  return mark and self:prompt(mark)
end

--- @param row integer 0-indexed
--- @return otto.BlockCall? Of the tool that the row is in
function Buffer:call_at(row)
  local opts = { overlap = true, limit = 1 }
  local mark = vim.api.nvim_buf_get_extmarks(self.bufnr, call_ns, { row, 0 }, { row, 0 }, opts)[1]
  return mark and self.calls[mark[1]]
end

--- @param row integer 0-indexed
--- @param backward boolean
--- @return integer? row of the next prompt
function Buffer:find_prompt(row, backward)
  local start = backward and { math.max(row - 1, 0), 0 } or { row + 1, 0 }
  local marks = vim.api.nvim_buf_get_extmarks(self.bufnr, user_ns, start, backward and 0 or -1, { limit = 1 })
  return marks[1] and marks[1][2]
end

--- Removes the submitted prompt, which the prompt buffer leaves in place. It returns as a user block when the agent
--- reads it
--- @param text string
function Buffer:submitted(text)
  local count = #vim.split(text, '\n')
  self:modify(
    function(_, prompt_row) vim.api.nvim_buf_set_lines(self.bufnr, prompt_row - count, prompt_row, false, {}) end
  )
  self.on_change()
end

--- Starts the transcript of the buffer, removing what was there
--- @param bufnr integer
--- @param on_change fun()
--- @return otto.Buffer
function M.new(bufnr, on_change)
  local buffer =
    setmetatable({ bufnr = bufnr, folds = {}, targets = {}, calls = {}, groups = {}, on_change = on_change }, Buffer)
  highlight.clear(bufnr)
  for _, namespace in ipairs({ ns, separator_ns, user_ns, summary_ns, target_ns, call_ns }) do
    vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
  end
  buffer:modify(function(_, prompt_row) vim.api.nvim_buf_set_lines(bufnr, 0, prompt_row, false, {}) end)
  return buffer
end

return M
