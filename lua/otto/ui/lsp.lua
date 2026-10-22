local M = {}

local cmd --- @type fun(dispatchers: vim.lsp.rpc.Dispatchers, config: vim.lsp.ClientConfig): vim.lsp.rpc.Client

--- Completes the agent's /commands at the start of the prompt and @paths anywhere in it
--- @param params lsp.CompletionParams
--- @return lsp.CompletionList?
local function complete(params)
  local util = require('blink.lib.lsp').util
  local session = require('otto.session').sessions[util.bufnr(params.textDocument)]
  if session == nil then return end

  local row, col = util.position(params.position)
  local before = vim.api.nvim_buf_get_lines(session.bufnr, row, row + 1, false)[1]:sub(1, col)
  local token = before:match('%S*$')
  local kinds = vim.lsp.protocol.CompletionItemKind

  local items = {}
  local prompt_row = vim.api.nvim_buf_get_mark(session.bufnr, ':')[1] - 1
  -- the agent's own commands, since otto's are in the palette. Like submitting, which trims the prompt
  if vim.startswith(token, '/') and vim.trim(before) == token and row == prompt_row then
    for _, command in ipairs(session.state.commands) do
      local item = { label = command.name, kind = kinds.Function, detail = command.args }
      item.documentation = command.description
      table.insert(items, item)
    end
  elseif vim.startswith(token, '@') then
    -- one folder at a time, like cmdline completion, since `/` triggers completion again
    for _, path in ipairs(vim.fn.getcompletion(token:sub(2), 'file')) do
      table.insert(items, { label = path, kind = kinds.File })
    end
  end

  -- replace the token after its trigger character, which may contain `:` or `/`
  local range = util.range(session.bufnr, row, col - #token + 1, row, col)
  for _, item in ipairs(items) do
    item.textEdit = util.text_edit(range, item.label)
  end
  return { isIncomplete = false, items = items }
end

--- @param params lsp.CodeActionParams
--- @return lsp.CodeAction[]?
local function code_actions(params)
  local bufnr = require('blink.lib.lsp').util.bufnr(params.textDocument)
  if bufnr ~= nil then return require('otto.actions').code_actions(bufnr, params.range) end
end

vim.lsp.config('otto', {
  -- created lazily, since blink.lib is added to the runtimepath after this module loads
  cmd = function(dispatchers, config)
    cmd = cmd
      or require('blink.lib.lsp').server({
        name = 'otto',
        capabilities = { codeActionProvider = true, completionProvider = { triggerCharacters = { '/', '@' } } },
        handlers = { ['textDocument/completion'] = complete, ['textDocument/codeAction'] = code_actions },
      })
    return cmd(dispatchers, config)
  end,
})
vim.lsp.enable('otto')

--- Attaches to the session's prompt buffer, which `vim.lsp.enable` skips
--- @param session otto.Session
function M.attach(session) vim.lsp.start(vim.lsp.config.otto, { bufnr = session.bufnr }) end

return M
