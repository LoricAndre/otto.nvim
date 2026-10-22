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

In a session, `<M-x>` opens the commands, with their keys. Prompts go to the agent as written, so its own commands work as `/name args`, which the palette starts for you. Pickers use [minibuffer.nvim](https://github.com/saghen/minibuffer.nvim) when it's set up, and `vim.ui.select` otherwise.

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
| `\q` | Edits of the session to quickfix |

Unlike my other projects, this project has been AI assisted, use at your own risk!
