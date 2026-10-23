<h2 align="center">Otto (otto.nvim)</h2>

<p align="center">
  <strong>Experimental</strong> neovim-native agent interface
</p>

**otto.nvim** is an agent interface for neovim, rendering natively in a prompt buffer (`:h prompt-buffer`), not a TUI! Currently, only Pi (specialized to my configuration), Codex and Claude Code are supported via RPC.

```lua
vim.pack.add({
  "https://github.com/saghen/otto.nvim",
  { source = "https://github.com/saghen/blink.lib", branch = "vim-async" },
})

vim.keymap.set('n', '<leader>af', '<cmd>Otto<cr>', { desc = 'Find session' })
vim.keymap.set('n', '<leader>ap', '<cmd>Otto pi<cr>', { desc = 'New Pi session' })
vim.keymap.set('n', '<leader>aP', ':Otto pi ', { desc = 'New named Pi session' })
vim.keymap.set('n', '<leader>ac', '<cmd>Otto claude<cr>', { desc = 'New Claude session' })
vim.keymap.set('n', '<leader>aC', ':Otto claude ', { desc = 'New named Claude session' })
vim.keymap.set('n', '<leader>ax', '<cmd>Otto codex<cr>', { desc = 'New Codex session' })
vim.keymap.set('n', '<leader>aX', ':Otto codex ', { desc = 'New named Codex session' })
vim.keymap.set('n', '<leader>ar', '<cmd>Otto resume<cr>', { desc = 'Resume session' })
vim.keymap.set({ 'n', 'x' }, '<leader>as', ':Otto send<cr>', { desc = 'Send to agent' })
```

Pickers use [minibuffer.nvim](https://github.com/saghen/minibuffer.nvim) when it's set up, and `vim.ui.select` otherwise.

| Key | Action |
| --- | --- |
| `<C-s>`, `<CR>` (normal) | Submit, steering while the agent works |
| `<M-CR>` | Submit as a follow-up |
| `<C-c>` | Take back queued prompts, or abort |
| `<M-p>`, `<M-n>` | Older and newer prompts of this folder, keeping your draft |
| `<M-r>` | Pick from the history (`<M-s>` all folders, `<M-d>` delete) |
| `<M-x>` | Commands |
| `\p` | Jump to a prompt (`<M-r>` rewind, `<M-f>` fork, `<M-e>` edit) |
| `\r`, `\f` | Rewind to, or fork from, the prompt under the cursor |
| `\e` | Edit the prompt under the cursor |
| `\y`, `\o` | Yank, or open in a split, the prompt, tool output or code block under the cursor |
| `\t` | Run the command under the cursor in a terminal |
| `\k` | Stop the subagent or command under the cursor |
| `\q` | Edits of the session to quickfix |

## Configuration

Otto works without `setup()`. These are the defaults, which `setup()` merges into. See `lua/otto/config.lua` for every keymap.

```lua
require('otto').setup({
  default_provider = 'pi',
  ask = { provider = 'pi' }, -- one-shot prompts, like naming sessions
  cleanup_delay = 10000, -- ms before an empty, hidden session's buffer is deleted
  tool_header = false, -- function(call) for custom tool headers, false for defaults
  -- command, command by mode, or false to disable. `keymaps = false` disables them all
  keymaps = {
    ['<CR>'] = { n = 'open', i = 'newline' },
    ['<C-s>'] = 'submit',
    -- ...
  },
  providers = {
    -- `cmd` comes before otto's arguments and `args` after, so `cmd` can be a wrapper like { 'bwrap', ..., 'pi' }
    pi = { cmd = { 'pi' }, args = {}, env = {} },
    claude = {
      cmd = { 'claude' },
      args = {},
      env = {},
      model = 'claude-opus-5-5',
      effort = 'high',
      permission_mode = 'auto',
    },
    codex = { cmd = { 'codex' }, args = {}, env = {} },
  },
})
```

Every command has a `<Plug>(otto-<command>)` mapping, which you can map yourself in `after/ftplugin/otto.lua`. Otto doesn't map over the buffer's own mappings:

```lua
vim.keymap.set('i', '<C-j>', '<Plug>(otto-submit)', { buffer = true })
-- or configure only this session, before its agent starts
require('otto.config').set({ providers = { claude = { model = 'claude-sonnet-5-5' } } }, { bufnr = 0 })
```

## Tool headers

Set `tool_header` to change the header of running and completed tool calls:

```lua
require('otto').setup({
  tool_header = function(call)
    if call.tool == 'bash' then
      return {
        { '$ ', 'OttoToolName' },
        (call.args.description or call.args.command):match('[^\n]*'),
      }
    end
    return nil -- use Otto's default header for other tools
  end,
})
```

The callback receives `{ tool, args }`, with Otto's normalized tool name and
arguments (see `otto.ToolArgs` in `lua/otto/event.lua`). Unknown tools keep their
provider names and arguments. Invalid arguments use Otto's existing fallback
name and description.

Return a list of strings or `{ text, highlight_group }` pairs. Strings and pairs
without a highlight group use `Normal`. Include any spaces between items.
Each item's text must be one line. Return `nil` for the default header, or set
`tool_header = false` to disable the callback. Callback errors and invalid return
values report an error and use the default header.

Otto still adds failure details, elapsed time, and edit/write counts. Tool output,
diffs, folds, navigation, and actions do not change. The callback also runs when
history loads and when running tools redraw; keep it fast and synchronous.
Arguments are copied so that changes in the callback cannot change the call.
Per-buffer configuration uses the session buffer, even when it is not current.
Headers already in the transcript do not change when the configuration changes.

Unlike my other projects, this project has been AI assisted, use at your own risk!
