# perforated.nvim

Perforce (Helix Core) integration for Neovim. It is designed to be fast, lightweight, and
completely dormant outside Perforce workspaces.

> **Status: early development (milestones M0 + M1 done).** Check-out on first edit, add on
> write, revert, gutter signs and hunks, side-by-side and `$P4DIFF` diffs, quickfix lists, a
> statusline component and stale-file notifications all work. See [docs/plan.md](docs/plan.md)
> for the roadmap and [docs/design-decisions.md](docs/design-decisions.md) for the agreed
> behaviour.

## Requirements

- Neovim 0.11+
- The `p4` command-line client

There are no Lua plugin dependencies.

## Install

With lazy.nvim:

```lua
{ 'perforated.nvim' } -- no setup() call required
```

Configuration is optional, through either `vim.g.perforated = { ... }` or
`require('perforated').setup({ ... })`. See `lua/perforated/config.lua` for the defaults.

## How it detects workspaces

- Opening a file looks for your `P4CONFIG` file (e.g. `.p4config`) in the file's directory and its
  parents. The lookup is pure Lua and cached per directory; it starts no processes.
- The directory containing that file is the workspace **anchor**. Every p4 command for the
  workspace runs from there, so all its buffers share one set of settings.
- Without a `P4CONFIG` file, but with `P4CLIENT` set, one background `p4 info` per session learns
  the client root.
- In any other case the plugin does nothing: no modules load and no processes or timers run.

## Commands (so far)

| Command | Description |
|---|---|
| `:P4 edit [-c CL] [file…]` | Open for edit (sticky CL, else default) |
| `:P4 add [-c CL] [file…]` | Open for add |
| `:P4 revert[!] [-a] [file…]` | Revert (asks first unless `!`); `-a` = only unchanged files |
| `:P4 diff[!] [#rev\|@CL\|@=CL\|prev]` | Side-by-side diff in a new tab (`q` closes it); `!` uses `$P4DIFF` |
| `:P4 opened` | Opened files grouped by changelist → quickfix |
| `:P4 status` | Stale / unresolved opened files → quickfix |
| `:P4 hunks [%]` | Hunks of all opened files → quickfix (`%`: this file → location list) |
| `:P4 notifications` / `:P4 dismiss` | Notification history / close notifications |
| `:P4 info` / `:P4 log` / `:P4 login` / `:P4 refresh[!]` | Info, command log, login, refresh |

Each command also has a flat alias (`:P4edit`, `:P4diff`, …). In a perforated quickfix list,
`gr` refreshes it and `d` diffs the entry.

**Check-out on first edit.** Modify an unopened file and a small menu appears:

- `<CR>` checks out to the sticky CL (otherwise the default CL)
- `c` picks an existing CL
- `n` creates a new CL
- `A` always uses this target for the rest of the session
- `s` skips this buffer
- `S` never asks again this session

Set `checkout = { prompt = false, on_write = true }` to check out silently when you write.

**Statusline.** `require('perforated').statusline()` returns e.g. `edit@123 +3 ~1 ↓#4→#5  ↓2`.
It works directly as a lualine component. You can also read `vim.b.perforated_status_dict`
and `vim.g.perforated_status`.

**Keymaps.** Nothing is mapped by default. `<Plug>(perforated-…)` mappings exist for every
action. `vim.g.perforated = { keymaps = 'default' }` enables this preset, in Perforce buffers
only:

- `]h` / `[h` next / previous hunk
- `<leader>pv` preview hunk, `<leader>pu` reset hunk
- `<leader>pe` edit (with the prompt), `<leader>pa` add, `<leader>pr` revert
- `<leader>pd` diff, `<leader>pD` diff with `$P4DIFF`
- `<leader>pq` all hunks, `<leader>pQ` this file's hunks
- `<leader>po` opened files, `<leader>ps` status
- `<leader>pi` info, `<leader>pl` log, `<leader>pn` notifications

## Development

```sh
make deps    # mini.nvim + p4/p4d test binaries into .deps/
make test    # full suite (fake p4 + throwaway real p4d); FILE=tests/test_x.lua for one file
make bench   # performance budgets (startup, dormant cost, memory)
make lint    # stylua + selene
```
