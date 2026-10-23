<h2 align="center">Otto (otto.nvim)</h2>

<p align="center">
  <strong>Experimental</strong> neovim-native agent interface
</p>

Requires Neovim 0.13 nightly or newer with `vim.async`.

**otto.nvim** is an agent interface for neovim, rendering natively in a prompt buffer (`:h prompt-buffer`), not a TUI! Currently, only Pi, Codex and Claude Code are supported via RPC.

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

```lua
require('otto').setup({
  providers = {
    pi = {
      cmd = { '/opt/Pi Tools/bin/pi', '--model', 'provider/model' },
      args = {},
      env = {
        PI_CODING_AGENT_DIR = '/path/to/agent',
        PI_CODING_AGENT_SESSION_DIR = '/path/to/sessions',
      },
    },
  },
})
```

Pi session storage uses `PI_CODING_AGENT_SESSION_DIR`, then
`<PI_CODING_AGENT_DIR>/sessions`, then `~/.pi/agent/sessions`. Configured environment
values take precedence over inherited values. Empty values count as unset. Paths
expand home and environment variables, but not glob characters. Otto keeps Pi's
encoded project subdirectories and passes a session-root override through
`--session-dir`. Main sessions and one-shot helper calls use the same settings.
Commands run directly without a shell; each `cmd` and `args` entry stays one argument.

Otto works without `setup()`. These are the defaults, which `setup()` merges into. See `lua/otto/config.lua` for every keymap.

```lua
require('otto').setup({
  default_provider = 'pi',
  ask = { provider = 'pi' }, -- one-shot prompts, like naming sessions
  cleanup_delay = 10000, -- ms before an empty, hidden session's buffer is deleted
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

## Agent events

Use Neovim `User` autocommands to run logic when an agent changes status or sends a
message. Pi, Claude Code, and Codex use the same event names and data format.

```lua
vim.api.nvim_create_autocmd('User', {
  pattern = 'OttoAgentSettled',
  callback = function(args)
    local data = args.data
    if not data.event.aborted then
      vim.notify(data.backend .. ' finished: ' .. data.id)
    end
    -- Use data.bufnr to access the session, which can be in a hidden buffer.
  end,
})
```

| User event | When it runs |
| --- | --- |
| `OttoSessionStart` | A new or resumed session has loaded its history and state; also runs after restart |
| `OttoAgentStart` | The agent starts work |
| `OttoAgentSettled` | The agent stops work; `data.event.aborted` indicates an interrupted run |
| `OttoMessageEnd` | A complete new message is received; see `data.event.message` |
| `OttoToolExecutionStart` | A tool starts; includes `toolCallId`, `toolName`, and `args` in `data.event` |
| `OttoCompactionStart` | Context compaction starts |
| `OttoCompactionEnd` | Context compaction ends |
| `OttoQueueUpdate` | The prompt queue changes; includes `steering` and `followUp` in `data.event` |

Every callback receives `args.data = { bufnr, backend, id, event }`. `backend` is
`pi`, `claude`, or `codex`; `id` is the session ID. `event` is a copy of Otto's
normalized agent event, with its original snake-case `type`, such as
`agent_settled` or `message_end`. Optional fields depend on what the harness reports.
Otto generates `OttoSessionStart` for each harness. Other events run only when
reported by the harness; Otto does not infer missing tool or compaction events.

Callbacks run after Otto updates the prompt or transcript for that event.
Messages from saved history do not trigger `OttoMessageEnd`. Callback errors do
not stop later agent events. Events from old clients after restart or buffer
unload are ignored. The session buffer need not be current: use
`args.data.bufnr`, not `args.buf`.

## Extension UI

Otto renders the UI data that Pi sends through RPC. No extra UI dependencies are needed.

| Pi extension method | Neovim frontend |
| --- | --- |
| `select`, `confirm` | Otto's auto-detected picker (`minibuffer` or `vim.ui.select`) |
| `input` | `vim.ui.input` |
| `notify` | `vim.notify` |
| `editor` | Native scratch-buffer window for multi-line text |
| `setStatus` | Session winbar entries, ordered by key |
| `setWidget` with text lines | Virtual lines above or below the prompt |
| `setTitle` | Session winbar title, not the global terminal title |
| `setEditorText` | Replace the current prompt without submitting it |

Pickers use minibuffer when it is set up, otherwise `vim.ui.select`, as described
above. Otto uses your current `vim.ui.input` and `vim.notify` functions.
It does not replace these global functions.

In the multi-line editor, use **Ctrl-S** to accept. In normal mode, use **q** or
**Esc** to cancel. Closing the window also cancels. A request timeout, session restart,
or process exit closes the editor. Other dialog frontends own their windows; Otto
ignores answers received after the request timeout or process exit.

Status and widget keys update independently within each session. Omit the status text
or widget lines to remove an entry. Widgets are display-only: they do not change the
transcript, undo history, or submitted prompt. They redraw as the prompt moves.
ANSI styling is removed; text uses Neovim highlights. State is cleared on restart,
process exit, and buffer unload. It is not saved in the transcript.

For a custom statusline, read a copy of a buffer's extension UI state:

```lua
local state = require('otto.ui').get(bufnr)
-- state.statuses: key -> text
-- state.widgets: key -> { lines = { ... }, placement = 'aboveEditor' | 'belowEditor' }
-- state.title: optional title
```

Listen for the `User` event `OttoUIChanged`; `event.data.bufnr` identifies the session
buffer. The getter returns an empty table when no extension UI state exists.

Pi does not send custom terminal components, component-factory widgets, or custom
footers through RPC. Installing a Neovim UI frontend does not enable those features.

Unlike my other projects, this project has been AI assisted, use at your own risk!
