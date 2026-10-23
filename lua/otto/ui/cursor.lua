-- Actions on what's under the cursor in the transcript: a prompt, a tool or a code block. Each verb does what makes
-- sense for what it's on, and the prompt pickers when it's on none, like rewinding from the prompt

local prompts = require('otto.ui.prompts')
local tools = require('otto.render.tools')
local util = require('otto.util')

local M = {}

--- @class otto.CodeBlock
--- @field lines string[]
--- @field filetype? string

--- The fenced code block around the row, outside of tools, counting the fences since the prompt above it
--- @param session otto.Session
--- @param row integer 0-indexed
--- @return otto.CodeBlock?
local function code_block(session, row)
  local start = session.buffer:find_prompt(row + 1, true) or 0
  local lines = vim.api.nvim_buf_get_lines(session.bufnr, start, -1, false)
  local open --- @type integer? Index in `lines` of the fence that opens the block around the row
  for i, line in ipairs(lines) do
    local at = start + i - 1
    if at > row and open == nil then return end
    if line:match('^%s*```') and session.buffer:call_at(at) == nil then
      if open == nil then
        open = i
      elseif at >= row then
        return { lines = vim.list_slice(lines, open + 1, i - 1), filetype = lines[open]:match('^%s*```%s*([%w_+-]+)') }
      else
        open = nil
      end
    end
  end
end

--- @class otto.Thing What's under the cursor
--- @field prompt? otto.TranscriptPrompt
--- @field call? otto.BlockCall
--- @field code? otto.CodeBlock

--- @param session otto.Session
--- @return otto.Thing
local function at_cursor(session)
  local row = vim.fn.line('.') - 1
  -- the prompt being written
  if row >= vim.api.nvim_buf_get_mark(session.bufnr, ':')[1] - 1 then return {} end
  local prompt = session.buffer:prompt_at(row)
  if prompt then return { prompt = prompt } end
  local call = session.buffer:call_at(row)
  if call then return { call = call } end
  return { code = code_block(session, row) }
end

--- @param session otto.Session
--- @param prompt otto.TranscriptPrompt
--- @return otto.Prompt?
local function with_id(session, prompt)
  return vim.iter(prompts.list(session)):find(function(other) return other.row == prompt.row end)
end

--- @param message string
local function nothing(message) util.notify(message, vim.log.levels.INFO) end

--- Opens lines in a scratch buffer, in a split
--- @param lines string[]
--- @param filetype? string
local function scratch(lines, filetype)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].bufhidden = 'wipe'
  if filetype then vim.bo[bufnr].filetype = filetype end
  vim.cmd.split()
  vim.api.nvim_win_set_buf(0, bufnr)
end

--- @async
--- @param session otto.Session
function M.rewind(session)
  local prompt = at_cursor(session).prompt
  if prompt == nil then return prompts.pick(session, 'rewind') end
  prompt = with_id(session, prompt)
  if prompt then prompts.rewind(session, prompt) end
end

--- @async
--- @param session otto.Session
function M.fork(session)
  local prompt = at_cursor(session).prompt
  if prompt == nil then return prompts.pick(session, 'fork') end
  prompt = with_id(session, prompt)
  if prompt then prompts.fork(session, prompt) end
end

--- @param session otto.Session
function M.edit(session)
  local prompt = at_cursor(session).prompt
  if prompt == nil then return nothing('no prompt under the cursor to edit') end
  prompts.edit(session, prompt)
end

--- Yanks the prompt, the command or output of the tool, or the code block
--- @param session otto.Session
function M.yank(session)
  local thing = at_cursor(session)
  local call = thing.call
  local text = thing.prompt and thing.prompt.text
    or call and (call.tool == 'bash' and call.args.command or call.output)
    or thing.code and table.concat(thing.code.lines, '\n')
  if text == nil then return nothing('nothing under the cursor to yank') end
  vim.fn.setreg(vim.v.register, text)
end

--- Opens the output of the tool, the file that it edited, or the code block
--- @param session otto.Session
function M.open(session)
  local thing = at_cursor(session)
  local call = thing.call
  if call and call.args.path and (call.tool == 'edit' or call.tool == 'write') then
    return require('otto.ui.commands').open_target({ path = call.args.path })
  end
  if call and call.output then
    return scratch(vim.split(call.output, '\n'), tools.output_of(call.tool, call.args, call.output).filetype)
  end
  if thing.code then return scratch(thing.code.lines, thing.code.filetype) end
  nothing('nothing under the cursor to open')
end

--- Stops the subagent or command under the cursor, which runs in the background
--- @async
--- @param session otto.Session
function M.stop(session)
  local call = at_cursor(session).call
  local item = call and vim.iter(session.state.background):find(function(item) return item.call_id == call.id end)
  if item == nil then return nothing('nothing running under the cursor to stop') end
  if session.handle.stop_task == nil then
    return util.notify(session.provider.name .. " can't stop what it runs", vim.log.levels.WARN)
  end
  session.handle:stop_task(item.id)
end

--- Runs the command of the tool in a terminal
--- @param session otto.Session
function M.terminal(session)
  local call = at_cursor(session).call
  if call == nil or call.tool ~= 'bash' then return nothing('no command under the cursor to run') end
  -- by the shell, since `:terminal` would expand % and # in it
  vim.cmd.new()
  vim.fn.jobstart(call.args.command, { term = true })
end

return M
