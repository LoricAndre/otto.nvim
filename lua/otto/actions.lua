-- One-shot prompts about code, offered as code actions by otto.ui.lsp. Each is answered by a new agent without a saved
-- session. While it works, the target line says what it's doing

local providers = require('otto.providers')
local util = require('otto.util')

local M = {}

local ns = vim.api.nvim_create_namespace('otto.actions')
local quick = { thinking = 'low' }

--- @class otto.ActionTarget
--- @field bufnr integer
--- @field path string
--- @field start_row integer 1-indexed
--- @field end_row integer 1-indexed, inclusive

--- @param target otto.ActionTarget
--- @return string
local function describe(target)
  local lines = vim.api.nvim_buf_get_lines(target.bufnr, target.start_row - 1, target.end_row, false)
  local filetype = vim.bo[target.bufnr].filetype
  local location = ('%s, lines %d-%d'):format(target.path, target.start_row, target.end_row)
  return ('%s:\n```%s\n%s\n```'):format(location, filetype, table.concat(lines, '\n'))
end

--- Runs a command, resuming on the main loop
--- @async
--- @param cmd string[]
--- @return string stdout
local function system(cmd)
  local opts = { text = true }
  local out = vim.async.await(1, function(callback) vim.system(cmd, opts, vim.schedule_wrap(callback)) end)
  return out.stdout
end

--- Sends `message` to a new agent and returns its final answer
--- @async
--- @param doing string What the agent is doing, like "explaining"
--- @param target otto.ActionTarget
--- @param message string
--- @param opts? otto.AskOpts
--- @return string
local function prompt(doing, target, message, opts)
  local virt_text = { { doing .. '...', 'Comment' } }
  local mark = vim.api.nvim_buf_set_extmark(target.bufnr, ns, target.start_row - 1, 0, { virt_text = virt_text })
  local ok, answer = pcall(providers.ask, message, opts)
  vim.api.nvim_buf_del_extmark(target.bufnr, ns, mark)
  if not ok then error(answer, 0) end
  return answer
end

--- @class otto.Action
--- @field name string
--- @field title string
--- @field available? fun(bufnr: integer): boolean
--- @field run async fun(target: otto.ActionTarget)

--- @type otto.Action[]
M.actions = {
  {
    name = 'ask',
    title = 'Ask',
    run = function(target)
      local question = util.input({ prompt = 'Ask: ', default = 'Briefly explain this code' })
      if question == nil then return end
      local answer = prompt('answering', target, question .. '\n\n' .. describe(target), quick)
      local opts = { focus_id = 'otto', max_width = 100 }
      vim.lsp.util.open_floating_preview(vim.split(answer, '\n'), 'markdown', opts)
    end,
  },
  {
    name = 'fix',
    title = 'Fix',
    run = function(target)
      local problems = {}
      for _, diagnostic in ipairs(vim.diagnostic.get(target.bufnr)) do
        if diagnostic.lnum + 1 >= target.start_row and diagnostic.lnum + 1 <= target.end_row then
          table.insert(problems, ('line %d: %s'):format(diagnostic.lnum + 1, diagnostic.message))
        end
      end
      local task = #problems > 0 and 'Fix these problems:\n' .. table.concat(problems, '\n') or 'Fix this code'

      -- the agent edits the file on disk
      vim.api.nvim_buf_call(target.bufnr, function() vim.cmd('silent update') end)
      prompt('fixing', target, task .. '\n\n' .. describe(target))
      vim.cmd.checktime() -- the agent may have edited other files too
    end,
  },
  {
    name = 'send',
    title = 'Send to session',
    run = function(target) require('otto').send(target.start_row, target.end_row) end,
  },
  {
    name = 'commit',
    title = 'Write commit message',
    available = function(bufnr) return vim.bo[bufnr].filetype == 'gitcommit' end,
    run = function(target)
      -- the buffer is in the repository's folder, like .git/COMMIT_EDITMSG, or .git/worktrees/<name>/COMMIT_EDITMSG
      local git_dir = '--git-dir=' .. vim.fs.dirname(vim.api.nvim_buf_get_name(target.bufnr))
      local message = ('Write a commit message for this diff, in the style of these recent commits:\n%s\n\n%s'):format(
        system({ 'git', git_dir, 'log', '--format=%s', '-20' }),
        system({ 'git', git_dir, 'diff', '--cached' })
      )
      message = message .. '\n\nReply with only the commit message'
      local commit = prompt('writing', target, message, { tools = { 'read', 'grep' }, thinking = quick.thinking })
      vim.api.nvim_buf_set_lines(target.bufnr, 0, 0, false, vim.split(vim.trim(commit), '\n'))
    end,
  },
}

--- Code actions for the range, which run through the `otto` client command
--- @param bufnr integer
--- @param range lsp.Range
--- @return lsp.CodeAction[]
function M.code_actions(bufnr, range)
  local code_actions = {}
  for _, action in ipairs(M.actions) do
    if action.available == nil or action.available(bufnr) then
      local command = { title = action.title, command = 'otto', arguments = { action.name, range } }
      table.insert(code_actions, { title = 'otto: ' .. action.title, command = command })
    end
  end
  return code_actions
end

--- @param command lsp.Command
--- @param ctx { bufnr: integer }
vim.lsp.commands['otto'] = function(command, ctx)
  local name, range = unpack(command.arguments)
  local action = vim.iter(M.actions):find(function(action) return action.name == name end)
  local start_row = range.start.line + 1
  -- a linewise selection ends at the start of the next line
  local end_row = range['end'].character == 0 and range['end'].line or range['end'].line + 1
  local path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(ctx.bufnr), ':.')
  local target = { bufnr = ctx.bufnr, path = path, start_row = start_row, end_row = math.max(start_row, end_row) }
  util.run(function() action.run(target) end)
end

return M
