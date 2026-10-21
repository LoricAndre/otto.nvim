-- Otto's highlight groups, linked to the groups that colorschemes already define, so that a theme only sets the ones
-- it wants to change

local links = {
  OttoPrompt = 'QuickFixLine', -- background of the prompts in the transcript, and their sign column
  OttoSeparator = 'NonText', -- the rule above the prompt
  OttoToolName = '@markup.strong', -- like "read" or "$"
  OttoToolArg = 'String', -- the path, command, pattern or query
  OttoToolDetail = 'Comment', -- like "(5 lines)"
  OttoToolDone = 'DiagnosticOk',
  OttoToolFailed = 'DiagnosticError', -- also counts the failed tools in summaries
  OttoToolSummary = 'Comment', -- like "read 2 files, ran 1 command"
  OttoPath = 'Directory', -- of locations in tool output, like `path:12:` from grep
  OttoLineNumber = 'LineNr', -- of those locations, and of the lines in diffs
  OttoStatus = 'Function', -- like "Working..."
  OttoStatusTime = 'Comment', -- how long the agent has been working
  OttoStatusDone = 'Comment', -- like "Worked for 2m 10s · done 4:19 p.m"
  OttoQueued = 'Comment', -- prompts that the agent hasn't read yet
  OttoWinbarIcon = 'Function',
  OttoWinbarLabel = 'Comment', -- like "model:"
  OttoWinbarSeparator = 'NonText',
}

local function link()
  for name, target in pairs(links) do
    vim.api.nvim_set_hl(0, name, { link = target, default = true })
  end
end

link()
-- colorschemes clear the highlights first
vim.api.nvim_create_autocmd(
  'ColorScheme',
  { group = vim.api.nvim_create_augroup('otto.highlights', {}), callback = link }
)
