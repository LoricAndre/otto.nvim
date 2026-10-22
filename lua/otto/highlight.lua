-- Treesitter highlights for the transcript and the prompt, since the buffer has no parser of its own. The transcript
-- only changes by appending, so each block highlights once, parsed on its own as its language, when it's first drawn,
-- and changing the prompt only parses the prompt. See PLAN.md

local M = {}

local ns = vim.api.nvim_create_namespace('otto.highlights')
local prompt_ns = vim.api.nvim_create_namespace('otto.prompt.highlights')
local pending_ns = vim.api.nvim_create_namespace('otto.highlights.pending')

--- Highlighting of the blocks that haven't been drawn yet, by buffer and by the extmark that spans the block
local pending = {} --- @type table<integer, table<integer, fun(row: integer)>>

--- Captures that aren't highlights
local skipped = { spell = true, nospell = true, conceal = true }

--- @class otto.Place Where a line of the parsed text is in the buffer
--- @field row integer 0-indexed
--- @field col integer
--- @field hidden? boolean Parsed for its context, but not highlighted

--- @param places otto.Place[]
--- @param row integer of the first line
--- @param col integer
--- @param count integer of lines
--- @return otto.Place[] of lines below each other
local function below(places, row, col, count)
  for i = 0, count - 1 do
    table.insert(places, { row = row + i, col = col })
  end
  return places
end

--- Highlights the lines, which may be apart in the buffer, as `lang`, with the injections of the language, like code
--- blocks in markdown
--- @param bufnr integer
--- @param namespace integer
--- @param places otto.Place[] of each line
--- @param lines string[]
--- @param lang string Treesitter language, which may not have a parser
local function highlight(bufnr, namespace, places, lines, lang)
  local text = table.concat(lines, '\n')
  local ok, parser = pcall(vim.treesitter.get_string_parser, text, lang)
  if not ok then return end
  parser:parse(true)
  parser:for_each_tree(function(tree, language_tree)
    local language = language_tree:lang()
    local query = vim.treesitter.query.get(language, 'highlights')
    if query == nil then return end
    for id, node, metadata in query:iter_captures(tree:root(), text) do
      local name = query.captures[id]
      if not skipped[name] and not vim.startswith(name, '_') then
        local range = vim.treesitter.get_range(node, text, metadata[id])
        local priority = tonumber(metadata.priority or metadata[id] and metadata[id].priority)
        local opts =
          { hl_group = '@' .. name .. '.' .. language, priority = vim.hl.priorities.treesitter + (priority or 0) }
        -- line by line, since the lines may be apart
        for line = range[1], range[4] do
          local place = places[line + 1]
          local first = line == range[1] and range[2] or 0
          local last = line == range[4] and range[5] or #(lines[line + 1] or '')
          if place ~= nil and not place.hidden and last > first then
            opts.end_col = place.col + last
            vim.api.nvim_buf_set_extmark(bufnr, namespace, place.row, place.col + first, opts)
          end
        end
      end
    end
  end)
end

--- Highlights the block once it's drawn, since most of the transcript is folded or scrolled past
--- @param bufnr integer
--- @param row integer 0-indexed, of the first line
--- @param count integer of lines
--- @param fn fun(row: integer) Highlights the block, which starts at the row
local function lazily(bufnr, row, count, fn)
  if count == 0 then return end
  -- up to the next line, without the lines that go after it
  local opts = { end_row = row + count, end_right_gravity = false }
  local id = vim.api.nvim_buf_set_extmark(bufnr, pending_ns, row, 0, opts)
  pending[bufnr] = pending[bufnr] or {}
  pending[bufnr][id] = fn
end

vim.api.nvim_set_decoration_provider(pending_ns, {
  on_win = function(_, _, bufnr, top, bottom)
    if next(pending[bufnr] or {}) == nil then return false end
    local opts = { overlap = true, limit = 1 }
    return #vim.api.nvim_buf_get_extmarks(bufnr, pending_ns, { top, 0 }, { bottom, -1 }, opts) > 0
  end,
  -- closed folds only draw their first line, and the extmarks set here draw with the line
  on_line = function(_, _, bufnr, row)
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, pending_ns, { row, 0 }, { row, -1 }, { overlap = true })) do
      local fn = pending[bufnr][mark[1]]
      pending[bufnr][mark[1]] = nil
      vim.api.nvim_buf_del_extmark(bufnr, pending_ns, mark[1])
      fn(mark[2])
    end
  end,
})

--- Removes the highlights of the transcript
--- @param bufnr integer
function M.clear(bufnr)
  pending[bufnr] = {}
  vim.api.nvim_buf_clear_namespace(bufnr, pending_ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
end

--- Highlights lines of the transcript, which don't change once they're appended
--- @param bufnr integer
--- @param row integer 0-indexed, of the first line
--- @param indent integer Columns before the lines in the buffer
--- @param lines string[]
--- @param filetype string
function M.lines(bufnr, row, indent, lines, filetype)
  local lang = vim.treesitter.language.get_lang(filetype)
  if lang == nil then return end
  lazily(bufnr, row, #lines, function(first) highlight(bufnr, ns, below({}, first, indent, #lines), lines, lang) end)
end

--- @param bufnr integer
--- @param row integer
--- @param indent integer
--- @param lines string[]
--- @param lang string
local function diff(bufnr, row, indent, lines, lang)
  local before, after
  -- hunks parse apart, since a string that one leaves open would continue into the next
  local function hunk()
    if before ~= nil then
      highlight(bufnr, ns, before.places, before.lines, lang)
      highlight(bufnr, ns, after.places, after.lines, lang)
    end
    before, after = { lines = {}, places = {} }, { lines = {}, places = {} }
  end
  hunk()
  local next_lnum -- in the new file, which jumps between hunks
  for i, line in ipairs(lines) do
    local sign = line:sub(1, 1)
    local number, code = line:match('^.(%s*%d+ )(.*)$')
    local lnum = tonumber(number)
    -- or at the gaps between them, like pi's
    if lnum == nil or (sign ~= '-' and next_lnum ~= nil and lnum ~= next_lnum) then hunk() end
    if sign ~= '-' then next_lnum = lnum and lnum + 1 end
    if number ~= nil then
      local col = indent + 1 + #number
      local opts = { end_col = col - 1, hl_group = 'OttoLineNumber' }
      vim.api.nvim_buf_set_extmark(bufnr, ns, row + i - 1, indent + 1, opts)
      if sign ~= '+' then
        table.insert(before.lines, code)
        -- the lines around the change highlight after it
        table.insert(before.places, { row = row + i - 1, col = col, hidden = sign == ' ' })
      end
      if sign ~= '-' then
        table.insert(after.lines, code)
        table.insert(after.places, { row = row + i - 1, col = col })
      end
    end
  end
  hunk()
end

--- Highlights a diff like pi's, with a line number after the sign of each line, as the language of its file, like
--- delta. The lines before the change and after it parse apart, each with the lines around the change
--- @param bufnr integer
--- @param row integer 0-indexed, of the first line
--- @param indent integer Columns before the lines in the buffer
--- @param lines string[]
--- @param filetype string
function M.diff(bufnr, row, indent, lines, filetype)
  local lang = vim.treesitter.language.get_lang(filetype)
  if lang == nil then return end
  lazily(bufnr, row, #lines, function(first) diff(bufnr, first, indent, lines, lang) end)
end

--- Highlights the prompt as markdown again, after it changed
--- @param bufnr integer
function M.prompt(bufnr)
  local row = vim.api.nvim_buf_get_mark(bufnr, ':')[1] - 1
  vim.api.nvim_buf_clear_namespace(bufnr, prompt_ns, row, -1)
  local lines = vim.api.nvim_buf_get_lines(bufnr, row, -1, false)
  highlight(bufnr, prompt_ns, below({}, row, 0, #lines), lines, 'markdown')
end

return M
