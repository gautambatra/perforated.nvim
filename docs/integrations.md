# Other plugins and perforated.nvim

perforated.nvim has **no required dependencies**. Some other plugins, if you have them, change
how it looks or where its output goes. This page lists all of them, what changes, and what you
get without them. `:checkhealth perforated` shows which ones it found.

| Area | Plugins | Without them |
|---|---|---|
| [Pickers](#pickers) | telescope, fzf-lua, snacks.picker, mini.pick | the plugin's own list |
| [Icons](#icons) | mini.icons, nvim-web-devicons | no file icons, ASCII glyphs |
| [Statusline](#statusline) | lualine | `require('perforated').statusline()` or the status variables |
| [Messages, prompts, progress](#messages-prompts-and-progress) | nvim-notify, noice, snacks, fidget, dressing… (only with `toast.backend = 'notify'`) | the plugin's own pop-ups |
| [Code actions](#code-actions) | any code-action UI (opt-in feature) | Neovim's own menu |
| [Colours](#colours) | your colorscheme, theme switchers, diff hooks | — |

## Pickers

Every step that chooses from a list uses a picker:

- **Choosing a changelist** (pending changelists, `default`, "+ new changelist…"): the
  check-out / add prompt's `c`, `gm` in the client view (a file or a whole changelist) and in
  quickfix, `:P4 reopen`, unshelving someone else's shelf, the target of an integrate.
- **Revisions and changelists:** `g@` "Get revision…" and `gD` "Diff against revision…" in the
  client view, `:P4 sync @`, integrate without a changelist number, time-lapse's "Pick a
  revision by description", `:P4 filelog` with `history.presenter = 'picker'`.
- **Clients:** `W` in the client view.
- **`:P4 pick`:** `pending` and `submitted` (then a diff tab), `opened` (several at once),
  `users` (then their submitted changelists).

The action menus (`.`, right-click), the check-out prompt's single keys, confirmations and
text inputs never use a picker: they're the plugin's own pop-ups.

**Which picker** (`picker = …`):

| Value | Uses |
|---|---|
| `'auto'` (default) | the first installed of telescope, fzf-lua, snacks.picker, mini.pick; else the plugin's own list (with `toast.backend = 'notify'`: `vim.ui.select`) |
| `'telescope'`, `'fzf_lua'`, `'snacks'`, `'mini'` | that one |
| `'perforated'` | always the plugin's own list |
| `'select'` | always `vim.ui.select` (e.g. to route everything through dressing.nvim) |

If a picker plugin fails (for example it errors while loading), lists fall back the same way as
`'auto'` does without one.

**The plugin's own list:** a filter line, the list and a preview, as pop-ups.

- `j`/`k`/arrows move and wrap around; `<CR>` or a double-click chooses; `q`/`<Esc>` cancel;
  clicking or moving outside cancels.
- `i` or `/` types in the filter line: fuzzy, matched characters highlighted. There, arrows
  still move the list, `<CR>` chooses, `<Esc>` goes back to the list.
- `m` marks several items where that's allowed (`:P4 pick opened`).
- Opening 500 items takes about 2 ms; a keystroke in the filter a few milliseconds (worst case,
  5000 items that all match what you type: 12–16 ms).

**`vim.ui.select`** without a plugin replacing it is a numbered list on the command line: the
same choices, but no filtering, no preview and one item at a time.

`picker_mode = 'normal'` (default) opens the list focused (move with `j`/`k`, `i` to type);
`'insert'` starts in the filter line. It applies to the plugin's list, telescope and
snacks.picker; fzf-lua and mini.pick have no normal mode.

```lua
-- lazy.nvim
{ 'gautambatra/perforated.nvim', opts = { picker = 'perforated' } }
-- or
require('perforated').setup({ picker = 'perforated' })
```

## Icons

**mini.icons** (preferred) or **nvim-web-devicons**:

- **With one:** file-type icons in the client view, describe, history, quickfix lists,
  pickers and pop-ups, and Nerd Font status glyphs (stale, unresolved, shelved, …).
- **Without:** no file icons, and ASCII glyphs: `*` modified, `!` stale, `U` unresolved, `S`
  shelved, `e`/`a`/`d` edit/add/delete, …

Settings: `icons.provider` (`'auto'`, or `false` for no file icons), `icons.style`
(`'auto'`, `'nerd'`, `'ascii'`) and `icons.glyphs` (override any glyph). The icon plugin is
only loaded when the first file icon is drawn.

## Statusline

**lualine:** a ready-made `perforated` component. The plugin also asks lualine to redraw as
soon as a status changes (lualine otherwise refreshes up to a second later).

**Any statusline:** `require('perforated').statusline()`, or the variables it reads:
`vim.b.perforated_status` (the file: client, action@changelist, modified, have revision,
stale/unresolved) and `vim.g.perforated_status` (the workspace: stale and unresolved counts,
offline, login needed). `User PerforatedStatus` fires when they change.

## Messages, prompts and progress

With the default `toast.backend = 'float'`, messages, confirmations, text prompts and job
results are the plugin's own pop-ups, and **no other plugin is involved**.

With `toast.backend = 'notify'`, the plugin uses Neovim's standard interfaces instead, and
whatever plugin implements them takes over:

| What | Goes to | Restyled by, e.g. |
|---|---|---|
| Messages | `vim.notify` | nvim-notify, noice, snacks.notifier, fidget |
| Text prompts (new changelist, reconcile paths, …) | `vim.ui.input` | snacks.input, dressing |
| Progress of long jobs (Neovim 0.12+) | native progress messages | fidget, snacks, noice |
| Confirmations | `confirm()` | noice |
| Lists, without a picker plugin | `vim.ui.select` | dressing, snacks, telescope-ui-select |

The `p4 login` password prompt always stays on the command line.

## Code actions

Experimental and opt-in (`lsp = { enabled = true }`): an in-process language server offers
Perforce actions (check out, diff, revert, history, annotate, the line's changelist, hunk
actions…) in Neovim's code-action menu (`gra`). Whatever shows that menu for you
(telescope-ui-select, actions-preview, fzf-lua, …) shows them too.

## Colours

- **Your colorscheme** decides most colours: the plugin's highlight groups link to standard
  ones (`:h perforated-highlights`). A colorscheme that defines `Perforated*` groups itself
  wins over the plugin's defaults.
- **Theme switches** (a light/dark toggle, auto-dark-mode) rebuild the diff look, so a
  `diff.colors = 'perforated'` diff stays light while everything else switches.
- **`OptionSet diff` hooks** in other plugins or your config also run on perforated's diffs.
  Whatever they do to a diff window's colours, the plugin re-applies its diff look after
  every file switch.
- **Syntax colouring** (Vim syntax, treesitter, LSP semantic tokens) is hidden in diff
  windows only with `diff.syntax = false` (default); buffers keep it everywhere else.

See `:h perforated-diff-colors`.

## Not plugins, but they matter too

- **tmux:** `focus-events on`, so the background checks pause in panes you aren't looking at
  and notices wait until you come back.
- **Your terminal:** CSI-u key reporting for the `Ctrl+Shift` P4V keys (vim-style keys always
  work), and mouse reporting for clicks and hover in menus (`mouse` enabled, tmux `mouse on`).
- **`$P4DIFF` / `$P4MERGE`:** your diff and merge tools, used by the external diff
  (`:P4 diff!`, `diff.tool = 'external'`) and by resolve.
