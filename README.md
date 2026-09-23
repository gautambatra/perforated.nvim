# perforated.nvim

> [!WARNING]
> **perforated.nvim is under active development.** The features marked ✅ below are
> implemented and tested (including against a real Helix Core server). Features marked 🚧 are
> designed and scheduled but not written yet. Commands, options and defaults may still change
> between commits until the first tagged release.

Perforce (Helix Core) integration for Neovim. It is built to be fast and lightweight, and to
keep out of your way:

- **Never blocks the editor.** Every `p4` call is asynchronous, with timeouts and an offline mode.
- **Dormant outside Perforce workspaces.** Outside a workspace no modules load and no processes
  or timers run.
- **Built for large workspaces** (100k–1M files). p4 queries are batched instead of run once per
  file, and gutter diffs are computed inside Neovim, so they never call `p4 diff`.
- **Zero dependencies.** Pure Lua plus the `p4` command-line client. Pickers, statuslines and
  icon plugins are optional.

## Requirements

- Neovim **0.11+**
- The `p4` command-line client (Helix Core CLI) on your `$PATH`, or set its path in the config
- A workspace configured through a `P4CONFIG` file (e.g. `.p4config`), or `P4CLIENT` set in your
  environment or with `p4 set`
- Linux, macOS or WSL

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{ 'gautambatra/perforated.nvim' }
```

That's all you need; `setup()` isn't required. To configure it, pass `opts`:

```lua
{
  'gautambatra/perforated.nvim',
  opts = {
    keymaps = 'default', -- opt-in <leader>p… preset (see Keymaps)
  },
}
```

- **Don't lazy-load it on `cmd`/`keys`.** It has to be loaded when files open so it can attach to
  them. Loading at startup costs under 0.5 ms, and `event = 'VeryLazy'` also works.
- **Run `:checkhealth perforated` after installing.** It checks the `p4` binary, your
  P4CONFIG/P4ENVIRO setup, server reachability and latency, login state, and tmux focus events.

Configuration can also be set as `vim.g.perforated = { … }` before the plugin loads.

## Features

### ✅ Workspace detection

- Opening a file looks for your `P4CONFIG` file in that file's directory and its parents. The
  lookup is pure Lua and cached per directory, and starts no processes.
- The directory containing that file is the workspace **anchor**. Every p4 command for the
  workspace runs from there, so all its buffers see the same settings.
- Without a `P4CONFIG` file but with `P4CLIENT` set, one background `p4 info` per session learns
  the client root.
- Buffers from **several workspaces** can be open in one session. Each workspace keeps its
  connection, caches and settings, shared by all of its buffers.
- **All state is per Neovim session.** Several Neovim instances on one machine never interfere.

### ✅ Check-out on edit

The first change to an unopened (read-only) depot file opens a small menu next to the cursor:

```
╭ Perforce: check out? ──────────────────────────────────╮
│ src/parser.cpp  #4/#4                                  │
│                                                        │
│  <CR>   Check out to CL 123470 "Fix crash in parser"   │
│  c      choose changelist…                             │
│  n      new changelist…                                │
│  A      always use this target (session, no prompt)    │
│  s      skip (this buffer)                             │
│  S      never ask (this session)                       │
╰────────────────────────────────────────────────────────╯
```

- **Sticky changelist.** The last CL you chose becomes the `<CR>` default for this session. It's
  dropped automatically once that CL is submitted or deleted.
- **Choosing a changelist.** `c` lists the default CL, your pending CLs and `+ new changelist…`.
- **Cancelling isn't skipping.** `<Esc>`, or backing out of the CL picker or the description
  prompt, leaves the file unopened and read-only. Only `s` skips the buffer, and `:e!` resets
  that too. To check out later, reload with `:e!` and edit, or use `<leader>pe` / `:P4 edit`.
- **Typing through the menu is safe.** Keys typed in the first 300 ms after the menu appears
  count as text and are replayed into the buffer (`checkout.prompt_grace`).
- **Writes never wait on the server.** Choosing a target makes the file writable right away;
  `p4 edit` runs in the background.
- **Warnings in the menu.** It warns when a newer revision exists in the depot, or when another
  user has the file open.
- **Silent mode.** `checkout = { prompt = false, on_write = true }` checks out silently when you
  save.
- **Directory limit.** `checkout.dirs` restricts automatic check-out to the directories you list.

### ✅ Add on write

Saving a new file inside the workspace offers to `p4 add` it, using the same menu.
`checkout.add_on_write = 'auto' | 'prompt' | false`.

### ✅ Gutter signs and hunks

- Signs mark added, changed and deleted lines against your **#have** revision. Stale files
  (have < head) get their own marker.
- The base text is fetched once per revision and cached in memory. Diffs run inside Neovim, and
  on a background thread for large files. Nothing calls `p4` while you type.
- `]h` / `[h` jump between hunks; you can also preview a hunk or reset it to `#have` (undoable).

### ✅ Diffs

- `:P4 diff` opens the current file against its depot revision, side by side in a new tab, using
  Neovim's diff mode (`]c`, `do`, `dp` all work). `q` closes the tab.
- Accepts `#rev`, `#head`, `@CL`, `@=CL` (shelved) and `prev`.
- `:P4 diff!` (or `diff.tool = 'external'`) opens your **`$P4DIFF`** tool with your own
  environment. GUI tools run detached; terminal tools open in a terminal tab.
- **Events for customising the diff tab.** `User PerforatedDiffOpen` fires when the diff tab is
  ready, and `User PerforatedDiffClose` fires once it closes, whether by `q`, `:q` or
  `:tabclose`. `ev.data` holds `{ tab, wins = { left, right }, bufs = { left, right }, spec,
  path }`. Example:
  ```lua
  vim.api.nvim_create_autocmd('User', {
    pattern = 'PerforatedDiffOpen',
    callback = function(ev) vim.wo[ev.data.wins.left].cursorline = true end,
  })
  ```
  For settings that should apply to every diff (`nvim -d`, `:diffsplit`, `:P4 diff`), use
  `OptionSet` with pattern `diff` instead, and restore them when the last diff window closes.
- Any depot revision can be opened as a read-only buffer, e.g.
  `:e perforated:////depot/path/file.c\#3` (escape `#` in `:e`).

### ✅ Revert

- `:P4 revert` asks for confirmation; `:P4 revert!` skips it.
- `:P4 revert -a` reverts only files you haven't changed.
- Affected buffers reload automatically.

### ✅ Quickfix integration

| Command | List |
|---|---|
| `:P4 opened` | Opened files grouped by changelist, with `STALE` / `UNRESOLVED` flags |
| `:P4 status` | Stale and unresolved opened files, with the reason |
| `:P4 hunks` | Every hunk across all opened files, found with one batched `p4 print` |
| `:P4 hunks %` | Hunks of the current file, in the location list |

Inside these lists, `gr` re-runs the query and `d` diffs the entry under the cursor.

### ✅ Stale-file detection

- **A cheap background check** runs every 5 minutes, only while Neovim has focus and you have
  files open. It also runs when focus returns and when you enter a Perforce buffer. The full
  status query only runs when the check sees a newer submit.
- **When an opened file becomes stale**, a small corner notification lists the file, the new
  revision, the CL and who submitted it. It never takes focus.
  - Its dismissal timer starts only once you press a key.
  - Notifications raised while Neovim was unfocused wait until you come back.
  - `:P4 notifications` shows the history, and `:P4 dismiss` closes them.
- **The stale marker stays in the statusline and sign column** until you sync.

### ✅ Statusline

```lua
-- lualine: a built-in component
sections = { lualine_c = { 'filename', 'perforated' } }
-- or a plain statusline
vim.o.statusline = '%f %= %{v:lua.require("perforated").statusline()} '
```

For a function-style component, pass the function itself: `require('perforated').statusline`,
without `()`. Calling it in your config evaluates it once at startup and shows an empty string.

What it shows:
- **Opened files:** the action and CL plus line counts, e.g. `edit@123 +3 ~1 ↓#4→#5  ↓2 !1`.
  That reads: opened for edit in CL 123, three lines added, one changed, the file is stale (#4
  vs #5), and in this workspace two opened files are stale and one is unresolved.
- **Files not opened:** the have revision, e.g. `#3`, or `#3 ↓#3→#4` when stale.
- **New files:** `not in depot`.
- **Outside Perforce:** nothing.

The raw data is also available as variables:
- `vim.b.perforated_status_dict` (per buffer)
- `vim.g.perforated_status` (workspace)

A `User PerforatedStatus` event fires whenever they change.

### ✅ Connection handling

- **Expired login:** exactly one password prompt, then the calls that failed are retried.
- **Unreachable server:** offline mode. Calls fail immediately with a clear message, and a
  background retry backs off from 5 s to 5 min. The statusline shows `⊘`.
- **Command log:** `:P4 log` lists every p4 command the plugin ran, with timings.

### ✅ Debug log

For diagnosing issues on a live machine, perforated can write a detailed log file. The log is
off by default, and costs nothing while off. There are three ways to turn it on:

```sh
PERFORATED_DEBUG=1 nvim          # for one session, no config change (or PERFORATED_DEBUG=trace)
```
```vim
:P4 debug on [trace|debug|info]  " at runtime
```
```lua
opts = { debug = { enabled = true } }  -- always
```

The file is `stdpath('log')/perforated.log`, typically `~/.local/state/nvim/perforated.log`. It
records:
- why each file was or wasn't treated as a Perforce file
- every p4 command, with its working directory, timing, result, errors and stderr
- workspace and connection state changes (offline, login)
- buffer status changes, and check-out prompts and choices
- background stale checks and notifications

Each line carries the Neovim session's process ID, so several sessions can share the file. It
rotates at `debug.max_kb`. **Secrets are never written:** the password sent to `p4 login` and
`P4PASSWD` are redacted.

| Command | |
|---|---|
| `:P4 debug` | Show whether logging is on and where the file is |
| `:P4 debug on [level]` / `off` | Toggle at runtime |
| `:P4 debug snapshot` | Write the current state (workspaces, buffers, queue, recent p4 calls) to the log, for bug reports |
| `:P4 debug open` / `clear` | Open or delete the log file |

### ✅ Icons

- File-type icons come from mini.icons or nvim-web-devicons, when installed.
- Status glyphs use Nerd Font symbols, with an ASCII fallback. Both are configurable.

### 🚧 Coming next

| Milestone | Features |
|---|---|
| M2 | **Client view** (a p4v-like tab: pending CLs with files and shelves, unresolved/stale, recent submits, reconcile) with P4V-compatible shortcuts and an action menu; changelist operations (new CL, move files between CLs, edit descriptions of pending and submitted CLs); picker adapters (telescope, fzf-lua, snacks, mini.pick, `vim.ui.select`); submitted CLs of any user |
| M3 | `:P4 describe` (CL lookup with lazily expanded diffs), file history, annotate (scroll-bound split, age-coloured, walk back), current-line blame, Swarm links |
| M4 | Shelve / unshelve (file and CL), resolve (auto-merge, then your `$P4MERGE`), submit, sync, delete, move/rename, integrate (cherry-pick a CL) |
| M5 | Time-lapse view (step through revisions instantly) |
| M6 | P4V-style time-lapse slider, `p4vc` escape hatches, polish |

The detailed plan is in [docs/plan.md](docs/plan.md). Agreed behaviour is in
[docs/design-decisions.md](docs/design-decisions.md).

## Commands

Every command also has a flat alias (`:P4edit`, `:P4diff`, …). A bang goes on the subcommand
(`:P4 revert!`).

| Command | Description |
|---|---|
| `:P4` | Workspace info (the client view replaces this in M2) |
| `:P4 edit [-c CL] [file…]` | Open for edit (sticky CL, else default) |
| `:P4 add [-c CL] [file…]` | Open for add |
| `:P4 revert[!] [-a] [file…]` | Revert; `!` skips confirmation, `-a` = only unchanged files |
| `:P4 diff[!] [rev]` | Side-by-side diff (`#rev`, `#head`, `@CL`, `@=CL`, `prev`); `!` = `$P4DIFF` |
| `:P4 opened` | Opened files → quickfix |
| `:P4 status` | Stale / unresolved opened files → quickfix |
| `:P4 hunks [%]` | Hunks → quickfix (`%`: this file → location list) |
| `:P4 notifications` | Notification history |
| `:P4 dismiss` | Close notifications |
| `:P4 info` | Workspace, client, root, user, server, connection state |
| `:P4 log` | Every p4 command the plugin ran, with timings |
| `:P4 debug [on [level]\|off\|open\|clear\|snapshot]` | Diagnostic log file (see Debug log) |
| `:P4 login` | Log in (password prompt) |
| `:P4 refresh[!]` | Refresh cached state (`!` also forgets workspace detection) |

## Keymaps

Nothing is mapped globally by default. Every action is available as a `<Plug>` mapping:

```
<Plug>(perforated-next-hunk)      <Plug>(perforated-prev-hunk)
<Plug>(perforated-preview-hunk)   <Plug>(perforated-reset-hunk)
<Plug>(perforated-edit)           <Plug>(perforated-edit-prompt)
<Plug>(perforated-add)            <Plug>(perforated-revert)
<Plug>(perforated-diff)           <Plug>(perforated-diff-external)
<Plug>(perforated-hunks)          <Plug>(perforated-hunks-file)
<Plug>(perforated-opened)         <Plug>(perforated-status)
<Plug>(perforated-info)           <Plug>(perforated-log)
<Plug>(perforated-notifications)
```

`keymaps = 'default'` installs this preset, in Perforce buffers only:

| Keys | Action |
|---|---|
| `]h` / `[h` | Next / previous hunk |
| `<leader>pv` / `<leader>pu` | Preview / reset hunk |
| `<leader>pe` | Check out (with the menu) |
| `<leader>pa` / `<leader>pr` | Add / revert |
| `<leader>pd` / `<leader>pD` | Diff / diff with `$P4DIFF` |
| `<leader>pq` / `<leader>pQ` | All hunks → quickfix / this file's hunks → location list |
| `<leader>po` / `<leader>ps` | Opened files / stale & unresolved |
| `<leader>pi` / `<leader>pl` / `<leader>pn` | Info / command log / notifications |

## Configuration

These are the defaults for everything that has an effect today:

```lua
{
  p4 = 'p4', -- executable name or absolute path
  checkout = {
    prompt = true, -- menu on first modification
    on_write = false, -- with prompt = false: check out silently on :w
    sticky = true, -- remember the last chosen CL for this session
    dirs = nil, -- list of directories where automatic check-out applies (nil = all)
    add_on_write = 'prompt', -- 'prompt' | 'auto' | false
    prompt_grace = 300, -- ms during which keys count as typing, not menu choices
  },
  signs = {
    enabled = true,
    priority = 6,
    algorithm = 'myers', -- 'myers' | 'patience' | 'histogram' | 'minimal'
    max_lines = 2000, -- above this, diff on a worker thread
    hard_max = 500000, -- above this, no signs
    text = { add = '▎', change = '▎', delete = '▁', stale = '↓' },
  },
  diff = {
    tool = 'builtin', -- 'external' = always use $P4DIFF
    external_terminal = 'auto', -- true: terminal tab; false: detached GUI; auto: guess from tool name
  },
  change = { template = nil }, -- string or function(ws) pre-filling new CL descriptions
  keymaps = false, -- 'default' = <leader>p preset in Perforce buffers
  commands = { aliases = true }, -- :P4edit-style aliases (read at startup via vim.g.perforated)
  qf = { open = true }, -- open the quickfix window when a list has results
  startup_check = true, -- check opened files for stale/unresolved when a workspace activates
  poll = { interval = 300, focus_throttle = 30, bufenter_throttle = 60 }, -- seconds; 0 disables the timer
  toast = { timeout = 8000, backend = 'float', history = 50 }, -- timeout 0 = sticky; backend 'notify' = vim.notify
  statusline = { stale = '↓', unresolved = '!', offline = '⊘' },
  icons = { provider = 'auto', style = 'auto', glyphs = {} }, -- provider: 'auto'|'mini'|'devicons'|false; style: 'nerd'|'ascii'|'auto'
  runner = { concurrency = 4, timeout = 10000, background_timeout = 5000 }, -- ms
  cache = { content_mb = 32 }, -- in-memory cache of depot revisions
  log = { size = 500 }, -- entries kept for :P4 log
  debug = {
    enabled = false, -- or env PERFORATED_DEBUG=1|trace, or :P4 debug on
    level = 'debug', -- 'error' | 'warn' | 'info' | 'debug' | 'trace'
    file = nil, -- default: stdpath('log')/perforated.log
    max_kb = 5120, -- rotate to <file>.1 above this size
  },
}
```

Some keys are reserved for upcoming features and have no effect yet: `client_view`, `history`,
`changes`, `merge`, `picker`, `keys`, `blame_line`, `swarm`. `:checkhealth perforated`
reports unknown keys, which catches typos.

Highlight groups (`PerforatedAdd`, `PerforatedChange`, `PerforatedDelete`, `PerforatedStale`,
`PerforatedToast`, …) are all `default` links, so you can override them.

## Performance

Budgets are enforced by `make bench` in CI:

| Metric | Budget | Current |
|---|---|---|
| Startup cost (`plugin/`) | < 0.5 ms | ~0.3 ms |
| Opening a file outside a workspace | < 0.3 ms | ~0.002 ms |
| Opening a workspace file (synchronous part) | < 0.3 ms | ~0.015 ms |
| Sign refresh, 10k-line file (UI time, debounced) | ≤ 5 ms | ~2–3 ms |
| Lua memory for an active workspace | ≤ 250 KB | ~200 KB |
| Lua memory per attached buffer | ≤ 2 KB | ~1.6 KB |

The timing figures are the best of several runs, which filters out noise from other processes.

## Development

```sh
make deps    # mini.nvim + p4/p4d test binaries into .deps/
make test    # full suite (fake p4 + throwaway real p4d); FILE=tests/test_x.lua for one file
make bench   # performance budgets
make lint    # stylua + selene
make fmt     # format
make dev-workspace   # persistent local Perforce sandbox in .dev/ (gitignored)
```

**Try the plugin without a real server.** `make dev-workspace` creates `.dev/`, which is
gitignored. It contains:

- a local p4d, running in rsh mode
- your workspace, `.dev/ws`, with a `.p4config`
- a few files with history and a pending changelist
- a second user, "bob"

Open it with `cd .dev/ws && P4CONFIG=.p4config nvim src/parser.cpp`.
`scripts/dev-workspace.sh --bob` makes bob submit a change, which exercises stale detection, and
`--reset` recreates the sandbox. The p4 binaries live in `.deps/p4bin`: either add that directory
to `PATH`, or set `vim.g.perforated = { p4 = '<repo>/.deps/p4bin/p4' }`.

The tests use [mini.test](https://github.com/nvim-mini/mini.nvim) with child Neovim instances.
Unit-level tests run against a scriptable fake `p4`. Integration tests start a throwaway real
`p4d` in rsh mode (no daemon, no ports), seeded fresh for each test.
