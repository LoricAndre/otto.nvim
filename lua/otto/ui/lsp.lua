local M = {}

local server --- @type fun(dispatchers: vim.lsp.rpc.Dispatchers, config: vim.lsp.ClientConfig): vim.lsp.rpc.Client

--- Completes the agent's /commands at the start of the input and @paths anywhere in it
--- @param params lsp.CompletionParams
--- @return lsp.CompletionList?
local function complete(params)
  local util = require('blink.lib.lsp').util
  local view = require('otto.view').views[util.bufnr(params.textDocument)]
  if view == nil then return end

  local row, col = util.position(params.position)
  local before = vim.api.nvim_buf_get_lines(view.bufnr, row, row + 1, false)[1]:sub(1, col)
  local token = before:match('%S*$')
  local kinds = vim.lsp.protocol.CompletionItemKind

  local items = {}
  local input_row = vim.api.nvim_buf_get_mark(view.bufnr, ':')[1] - 1
  -- the agent's own commands, since otto's are in the palette. Like submitting, which trims the input
  if vim.startswith(token, '/') and vim.trim(before) == token and row == input_row then
    for _, command in ipairs(require('otto.ui.commands').agent_commands(view)) do
      local item = { label = command.name, kind = kinds.Function, detail = command.arg_hint }
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
  local range = util.range(view.bufnr, row, col - #token + 1, row, col)
  for _, item in ipairs(items) do
    item.textEdit = util.text_edit(range, item.label)
  end
  return { isIncomplete = false, items = items }
end

vim.lsp.config('otto', {
  -- created lazily, since blink.lib is added to the runtimepath after this module loads
  cmd = function(dispatchers, config)
    server = server
      or require('blink.lib.lsp').server({
        name = 'otto',
        capabilities = { completionProvider = { triggerCharacters = { '/', '@' } } },
        handlers = { ['textDocument/completion'] = complete },
      })
    return server(dispatchers, config)
  end,
})

--- Attaches to the session's prompt buffer
--- @param view otto.View
function M.attach(view) vim.lsp.start(vim.lsp.config.otto, { bufnr = view.bufnr }) end

return M
