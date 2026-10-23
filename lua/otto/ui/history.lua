-- History of prompts, of every session and folder, which <M-p> and <M-n> step through for the current folder. What the
-- prompt held when it was left is kept, the draft included, until the next submit. Unsent prompts are saved when
-- their buffer unloads, and come back when the session opens again

local pick = require('otto.ui.pick')
local prompt_area = require('otto.ui.prompt_area')
local util = require('otto.util')

local path = vim.fn.stdpath('state') .. '/otto/history.jsonl'
local drafts_path = vim.fn.stdpath('state') .. '/otto/drafts.json'
local draft_days = 30 -- before a draft is dropped, like those of sessions that were never saved

--- @class otto.HistoryEntry
--- @field text string
--- @field cwd string
--- @field at integer Seconds since the epoch
--- @field session string Like pi://<id>

--- @class otto.Recall Where a session is in the history
--- @field entries otto.HistoryEntry[] Newest first, from when it started, with the draft at 0
--- @field index integer
--- @field edits table<otto.HistoryEntry, string> What the prompt held when it left an entry

local M = {}

--- @type otto.HistoryEntry[] Oldest first, which stay the same tables, since edits are keyed by them
local entries = {}
local offset = 0 -- bytes of the file read so far

--- Reads what other instances and sessions added since the last read
local function load()
  local stat = vim.uv.fs_stat(path)
  if stat == nil or stat.size == offset then return end
  -- like when it was replaced
  if stat.size < offset then
    entries, offset = {}, 0
  end
  local file = io.open(path, 'r')
  if file == nil then return end
  file:seek('set', offset)
  local data = file:read('*a')
  file:close()
  -- up to the last full line, since another instance may be writing one
  local last = data:match('.*()\n')
  if last == nil then return end
  offset = offset + last
  for line in data:sub(1, last):gmatch('[^\n]+') do
    local ok, entry = pcall(vim.json.decode, line)
    if ok and type(entry) == 'table' and type(entry.text) == 'string' then table.insert(entries, entry) end
  end
end

--- @param text string As submitted
--- @param session string Like pi://<id>
function M.add(text, session)
  -- a leading space keeps it out, like in shells
  if text:match('^%s') or vim.trim(text) == '' then return end
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  local file = io.open(path, 'a')
  if file == nil then return end
  -- read back by `load`, like those of other instances
  file:write(
    vim.json.encode({ text = vim.trim(text), cwd = vim.fn.getcwd(), at = os.time(), session = session }) .. '\n'
  )
  file:close()
end

--- @param cwd? string Of every folder when nil
--- @return otto.HistoryEntry[] newest first, without repeats
function M.list(cwd)
  load()
  local list, seen = {}, {}
  for i = #entries, 1, -1 do
    local entry = entries[i]
    if (cwd == nil or entry.cwd == cwd) and not seen[entry.text] then
      seen[entry.text] = true
      table.insert(list, entry)
    end
  end
  return list
end

--- @param bufnr integer
--- @param text string
local function set_prompt(bufnr, text)
  local row = vim.api.nvim_buf_get_mark(bufnr, ':')[1] - 1
  local lines = vim.split(text, '\n')
  vim.bo[bufnr].undolevels = vim.bo[bufnr].undolevels -- its own undo step, so that `u` brings back what was there
  vim.api.nvim_buf_set_lines(bufnr, row, -1, false, lines)
  if vim.api.nvim_get_current_buf() ~= bufnr then return end
  vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(bufnr), #lines[#lines] })
  prompt_area.follow(bufnr)
end

--- Keeps what the prompt holds, when it changed from the entry it shows
--- @param view otto.View
local function leave(view)
  local recall = view.recall
  local entry = recall.entries[recall.index]
  local text = vim.fn.prompt_getinput(view.bufnr)
  recall.edits[entry] = text ~= entry.text and text or nil
end

--- @param view otto.View
--- @return otto.Recall
local function start(view)
  local recall = view.recall or { index = 0, edits = {}, entries = {} }
  -- the newest entries, unless it's stepping through them
  if recall.index == 0 then
    local draft = recall.entries[0] or { text = '' }
    recall.entries = M.list(vim.fn.getcwd())
    recall.entries[0] = draft
  end
  view.recall = recall
  return recall
end

--- Steps through the history of the current folder, older for a positive count
--- @param view otto.View
--- @param count integer
function M.step(view, count)
  local recall = start(view)
  local index = math.max(math.min(recall.index + count, #recall.entries), 0)
  if index == recall.index then return end
  leave(view)
  recall.index = index
  local entry = recall.entries[index]
  set_prompt(view.bufnr, recall.edits[entry] or entry.text)
end

--- Puts text into the prompt, keeping what it held like stepping does, so that <M-n> brings it back
--- @param view otto.View
--- @param entry otto.HistoryEntry | { text: string } Of the history, or of somewhere else, like a prompt to edit
function M.insert(view, entry)
  local recall = start(view)
  leave(view)
  recall.index = 0
  for i, other in ipairs(recall.entries) do
    if other == entry then recall.index = i end
  end
  -- of another folder, or not of the history
  if recall.index == 0 then
    table.insert(recall.entries, 1, entry)
    recall.index = 1
  end
  recall.edits[entry] = nil
  set_prompt(view.bufnr, entry.text)
end

--- Writes the file whole, renamed into place so that another instance never reads half of it
--- @param file_path string
--- @param data string
local function write(file_path, data)
  vim.fn.mkdir(vim.fs.dirname(file_path), 'p')
  local temp = file_path .. '.' .. vim.uv.os_getpid()
  local file = io.open(temp, 'w')
  if file == nil then return end
  file:write(data)
  file:close()
  vim.uv.fs_rename(temp, file_path)
end

--- Picks a prompt from the history into the prompt, which shows the one under the cursor
--- @param view otto.View
--- @param all boolean Of every folder
function M.pick(view, all)
  local bufnr = view.bufnr
  local original = vim.fn.prompt_getinput(bufnr)
  --- @param text string
  local function show(text)
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    local row = vim.api.nvim_buf_get_mark(bufnr, ':')[1] - 1
    -- outside of the undo history, which only keeps the prompt that's picked
    local undolevels = vim.bo[bufnr].undolevels
    vim.bo[bufnr].undolevels = -1
    vim.api.nvim_buf_set_lines(bufnr, row, -1, false, vim.split(text, '\n'))
    vim.bo[bufnr].undolevels = undolevels
  end

  --- @param entry otto.HistoryEntry
  local function format(entry)
    local lines = vim.split(entry.text, '\n')
    local chunks = { { lines[1] } }
    if #lines > 1 then table.insert(chunks, { ('  +%d lines'):format(#lines - 1), 'Comment' }) end
    local notes = { { pick.age(os.time() - entry.at), 'Comment' } }
    if all then table.insert(notes, 1, { util.short(entry.cwd) .. '  ', 'OttoPath' }) end
    return chunks, notes
  end

  pick.select({
    prompt = 'History: ',
    items = M.list(not all and vim.fn.getcwd() or nil),
    format = format,
    text = function(entry) return entry.text end,
    preview = function(entry) show(entry and entry.text or original) end,
    on_accept = function(entry)
      if not vim.api.nvim_buf_is_valid(bufnr) then return end
      show(original)
      M.insert(view, entry)
    end,
  })
end

--- @return table<string, { text: string, at: integer }> by buffer name
local function read_drafts()
  local file = io.open(drafts_path, 'r')
  if file == nil then return {} end
  local ok, drafts = pcall(vim.json.decode, file:read('*a'))
  file:close()
  return ok and type(drafts) == 'table' and drafts or {}
end

--- Saves the unsent prompts of the sessions' buffers, or forgets them when they're empty
--- @param bufnrs integer[]
function M.save_drafts(bufnrs)
  local drafts = read_drafts()
  for name, draft in pairs(drafts) do
    if os.time() - draft.at > draft_days * 86400 then drafts[name] = nil end
  end
  for _, bufnr in ipairs(bufnrs) do
    local text = vim.fn.prompt_getinput(bufnr)
    drafts[vim.api.nvim_buf_get_name(bufnr)] = vim.trim(text) ~= '' and { text = text, at = os.time() } or nil
  end
  write(drafts_path, vim.json.encode(drafts))
end

--- Puts back the unsent prompt of the session's buffer, unless the prompt has text already, like after a restart
--- @param bufnr integer
function M.restore_draft(bufnr)
  local drafts = read_drafts()
  local name = vim.api.nvim_buf_get_name(bufnr)
  if drafts[name] == nil then return end
  if vim.fn.prompt_getinput(bufnr) == '' then set_prompt(bufnr, drafts[name].text) end
  -- back in the prompt, which saves it again when its buffer unloads, unless it's sent
  drafts[name] = nil
  write(drafts_path, vim.json.encode(drafts))
end

--- Forgets where the session was in the history, and what the prompt held, once it submits
--- @param view otto.View
function M.reset(view) view.recall = nil end

return M
