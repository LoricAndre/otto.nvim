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
vim.keymap.set('n', '<leader>ar', '<cmd>Otto resume<cr>', { desc = 'Resume session' })
vim.keymap.set({ 'n', 'x' }, '<leader>as', ':Otto send<cr>', { desc = 'Send to agent' })

vim.keymap.set('n', '<leader>ap', '<cmd>Otto pi<cr>', { desc = 'New Pi session' })
vim.keymap.set('n', '<leader>aP', ':Otto pi ', { desc = 'New named Pi session' })
vim.keymap.set('n', '<leader>ac', '<cmd>Otto claude<cr>', { desc = 'New Claude session' })
vim.keymap.set('n', '<leader>aC', ':Otto claude ', { desc = 'New named Claude session' })
vim.keymap.set('n', '<leader>ax', '<cmd>Otto codex<cr>', { desc = 'New Codex session' })
vim.keymap.set('n', '<leader>aX', ':Otto codex ', { desc = 'New named Codex session' })
```

Pickers use [minibuffer.nvim](https://github.com/saghen/minibuffer.nvim) when it's set up, and `vim.ui.select` otherwise. For below, I'm assuming your `<localleader>` is `\` (default). See `:h maplocalleader`.

| Key | Action |
| --- | --- |
| `<C-s>`, `<CR>` (normal) | Submit |
| `<M-CR>` | Submit as follow-up |
| `<C-c>` | Stop, taking back queued prompts |
| `<M-p>`, `<M-n>` | Take back queued prompts one by one, then prompt history |
| `<M-r>` | Prompt history picker |
| `<M-x>` | Commands |
| `\p` | Jump to a prompt |
| `\q` | Edits of the session to quickfix |

## Configuration

Otto works without `setup()`. These are the defaults, which `setup()` merges into. See `lua/otto/config.lua` for every keymap.

```lua
require('otto').setup({
  default_provider = 'pi',
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

Unlike my other projects, this project has been AI assisted, use at your own risk!
