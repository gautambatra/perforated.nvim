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

### ✅ Client view (`:P4`)

A p4v-style overview of your workspace in a tab (`:P4 view float` or `:P4 view split` for
other layouts):

```
Client alice_ws  Stream //main/dev  User alice  perforce:1666  online
 Pending  (3)
    default  (2)
      edit        src/lexer.cpp  #3/#3
      edit        src/parser.cpp  #4/#5  ↓ stale
    CL 123470  Fix crash in parser  (1)  S 1
      edit        src/parse.cpp  #8/#8
     S Shelved (1)
    CL 123488  WIP refactor  (0)
 Needs attention  (1)
 Workspace reconcile  (not scanned)
 Recent submitted  (20)
 d diff  D diff all files  o open file  x revert  M move to changelist  c new changelist  . actions  ? help
```

- **Sections:** pending changelists with their files and shelved files, files needing attention
  (stale or unresolved), workspace reconcile, and your recent submits. Reconcile is expensive on
  large workspaces, so it only scans when you expand it (`l`), and `x` stops a running scan
  (so do `:P4 jobs` and `:P4 cancel`). To scan only the parts you care about, set
  `client_view.reconcile.paths` (e.g. `{ 'src/myteam' }`, relative to the client root; local
  or depot paths work too), or press `p` on the section to change the paths for the session.
- **Always fresh:** the view re-queries every time it opens or refreshes, drawing a skeleton
  instantly while the data loads. It also updates after check-outs and reverts made anywhere
  in Neovim.
- **Keys:**
  - Vim-style keys, plus P4V's shortcuts (`<C-d>` diff, `<C-r>` revert, `<C-n>` new CL,
    `<C-w>` close, `<C-1>`/`<C-2>` jump to a section).
  - `.` or right-click opens a menu of what you can do with the line under the cursor
    (`<Space>` is left alone because many people use it as their leader key; remap with
    `keys = { menu = { '<your key>' } }`).
  - `K` on a changelist opens **View changelist**: a scrollable popup with the full
    description, its files and its shelved files (`D` there opens the diff tab). It works in
    `:P4 changes` too, so you can read other people's submitted changelists.
  - `d` is *Diff against have revision* on opened files and *Diff shelved vs base revision* on
    shelved files. `y` copies the changelist number.
  - `?` lists every key, and a footer always shows the keys that apply to the current line.
  - `l`/`<Tab>`/`<CR>` expand and `h` collapses. Folds are kept across refreshes.
  - `m` marks files for multi-file actions (revert, move, …) and `u` clears the marks.
  - `A` toggles between this client and **all your clients**.
  - `Q`/`gQ` send the line, the marked lines or a whole changelist to quickfix / the location list.

### ✅ Changelists

- **`c` / `:P4 change new`: create a changelist.** A small editor opens for the description;
  `:w` or `<C-s>` saves and `q` cancels. Check-out's "new changelist" uses the same editor.
- **`C` / `:P4 change [N]`: edit a description.** This works on pending *and* submitted
  changelists; for submitted ones it uses `p4 change -u`, which Perforce allows for your own
  changelists. Only the Description field is changed, so the file list can't be edited by
  accident. `gS` or `:P4 change! N` opens the full spec instead. Admins can set
  `change.allow_force = true` to retry with `-f`, with a confirmation. The default changelist
  has no description, so move its files to a numbered changelist instead.
- **`<Del>` / `:P4 change -d N`: delete a pending changelist.** One confirmation says what's in
  it; its opened files move to the default changelist (or are reverted, if you choose that) and
  its shelved files are deleted, then the changelist is. The default changelist can't be
  deleted; another client's changelist needs `change.allow_force`.
- **`M`: move files between changelists.** Pick an existing changelist or create a new one.
- **`D`: diff a whole changelist in a diff tab.** A file panel on the left and a side-by-side
  diff on the right; moving through the panel switches files, as do `<Tab>`/`<S-Tab>` from any
  window. It works for pending changelists, shelves and submitted changelists. Each file loads
  when you select it, and the next one is fetched ahead of time. `:P4 diff -a` opens the same
  view for every opened file.
- **`:P4 changes [-u user] [-m N] [path]`: submitted changelists,** newest first. Scoped to
  your client view unless you pass a path; `-u` shows another user's work. Pages load as you
  reach the end (or with `gn`), so no query is unbounded.

### ✅ Describe, history, annotate, blame

- **`:P4 describe N` (`gd` on a changelist anywhere):** a changelist buffer with the header, the
  full description, the files and any shelved files. `<Tab>` expands a file's diff inline; it
  is computed in Neovim from two `p4 print` calls, and only when you expand it. `d` opens a
  side-by-side diff, `D` the diff tab of every file and `Q` sends the files to quickfix
  (workspace paths when mapped). It works for submitted and pending changelists (your pending
  files are diffed against the workspace) and for shelves: `d` compares the shelf with its base,
  `gw` with your workspace file and `gh` with the head revision. `:P4 describe` with no
  number uses the current file's changelist.
- **`:P4 filelog [path]` (`L` / `<C-t>`): file history.** A float lists the revisions, with
  the files a branch came from. `<CR>` opens the action menu: `d` diff against the previous
  revision, `w` against your workspace file, `gd` describe, `K` view changelist, `o` open the
  revision read-only, `b` annotate it. Pages load as you reach the end (or `gn`). `Q` moves
  the list to the location list. Set `history.presenter` to `'picker'` or `'quickfix'` to
  use those instead. A directory's history is its list of changelists.
- **`:P4 annotate` (`b`):** a split left of the file shows the changelist, user and date that
  last changed each line, coloured by age. It scrolls with the file. Your local edits show
  "Not submitted". `<CR>` describes the line's changelist, `~` re-annotates the revision
  before that change (`<BS>` goes back), `d` diffs that change and `Q` lists every line from
  it in the location list. It follows branches (`p4 annotate -i`), so each line shows the change
  that wrote it, not the one that branched the file. It takes one p4 call (`annotate -c -i -u`)
  whatever the file's size or history.
- **`:P4 blame` (or `blame_line = { enabled = true }`): current-line blame** as virtual text.
  The file is annotated once per revision; moving the cursor makes no p4 calls.
- **`:P4 lookup` (`g/` / `<C-g>`):** type a changelist number, a path or a user name.
- **Swarm:** `gx` opens a changelist's review and `gX` copies its URL. The URL comes from
  `swarm.url` or the server's `P4.Swarm.URL` property.

### ✅ Shelve, submit, sync, resolve, integrate

- **Shelve (`s`), unshelve (`S`), delete shelved files (`z`)** on a changelist or on marked
  files in the client view; `:P4 shelve [-c CL] [file…]`, `:P4 shelve -d`, `:P4 unshelve CL
  [-c target]`. Re-shelving asks before replacing the shelf. Unshelving goes back into the
  shelf's own changelist when it's yours, otherwise you pick one; files that need a resolve are
  listed in quickfix.
- **Submit (`P` / `<C-s>`, `:P4 submit [CL]`):** a confirmation float shows the description and
  file count, and warns about out-of-date, unresolved or shelved files. `s` submits, `e` edits
  the description first. Failures (e.g. out of date) go to quickfix with p4's reason.
- **Sync (`gy`, `:P4 sync [path|%|@CL|#head]`):** open buffers reload without "file changed"
  prompts, and their signs follow the new revision. Afterwards every opened file is re-checked:
  files that need attention (can't clobber, and *every* unresolved file in the workspace, not
  just this sync's) go to quickfix, and if any need resolving you're offered to resolve them
  now (`sync.resolve_prompt = false` turns the offer off).
- **Watch or stop long operations:** a sync or submit shows a live progress message (files so
  far, last file, elapsed time). `:P4 jobs` lists running jobs in a float that updates live,
  where `x` stops one; `:P4 cancel` stops them all. p4 is sent SIGTERM, then SIGKILL after 2 s.
  Stopping a sync midway is safe: p4 updates your have list file by file.
- **Resolve (`R`, `:P4 resolve [file…]`):** `resolve -am` first, so p4 takes every clean merge.
  Each remaining conflict opens your merge tool (`$P4MERGE`, or `merge.tool`) as
  `tool base theirs yours merged`, asynchronously. When it exits 0 with a changed result, the
  result is written (through the buffer if it's open) and accepted. Anything else stays
  unresolved and goes to quickfix, where `R` on an entry tries again. There's no merge logic in
  the plugin.
- **Delete and move:** `:P4 delete [file…]` (after a confirmation; the buffer is closed) and
  `:P4 move {new path}` (opens the file for edit if needed; the buffer follows the file and
  keeps any unsaved edits).
- **Integrate / cherry-pick (`I` on a submitted changelist, `:P4 integrate [CL]`):** the source
  is the changelist's common directory. You give the target as a path (`//depot/rel/...`) or a
  branch spec (`-b name`), remembered for the session, and pick the target changelist. A
  preview goes to quickfix, and after you confirm the integrate runs and resolves (clean merges
  accepted, conflicts to the merge tool). `:P4 integrate` with no number asks for a source path
  and lets you pick one of its changelists.

### ✅ Pickers

Every list-picking step (e.g. choosing a changelist) and `:P4 pick {pending|opened|submitted|users}`
use your fuzzy finder: **telescope**, **fzf-lua**, **snacks.picker** or **mini.pick**,
detected in that order, falling back to `vim.ui.select`. Set `picker = 'telescope'` (etc.) to
choose one explicitly.

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
| M5 | Time-lapse view (step through revisions instantly) |
| M6 | P4V-style time-lapse slider, `p4vc` escape hatches, polish |

The detailed plan is in [docs/plan.md](docs/plan.md). Agreed behaviour is in
[docs/design-decisions.md](docs/design-decisions.md).

## Commands

Every command also has a flat alias (`:P4edit`, `:P4diff`, …), defined the first time you use
it. A bang goes on the subcommand (`:P4 revert!`).

| Command | Description |
|---|---|
| `:P4` / `:P4 view [tab\|float\|split]` | Client view |
| `:P4 change[!] [N\|new]` | Edit a changelist description (`!`: full spec); `new` creates one; `-d N` deletes a pending one |
| `:P4 changes [-u user] [-m N] [path]` | Submitted changelists (paged) |
| `:P4 pick {pending\|opened\|submitted\|users}` | Pick with your fuzzy finder |
| `:P4 describe [N]` | Changelist buffer (default: the current file's changelist) |
| `:P4 filelog [path]` / `:P4 history` | File history (a directory: its changelists) |
| `:P4 annotate [//depot/path#rev]` | Annotate split for the current file (or a depot revision) |
| `:P4 blame [on\|off]` | Toggle current-line blame |
| `:P4 lookup [what]` | Go to a changelist number, a path's history or a user's changelists |
| `:P4 shelve [-c CL] [-d] [file…]` | Shelve a changelist (or files); `-d` deletes the shelf |
| `:P4 unshelve CL [-c target] [file…]` | Unshelve |
| `:P4 submit [CL\|default]` | Submit (with a confirmation) |
| `:P4 sync [path\|%\|@CL\|#head …]` | Sync (no args: the whole workspace) |
| `:P4 jobs` / `:P4 cancel` | Watch running syncs and submits / stop them |
| `:P4 resolve [file…]` | Resolve (auto-merge, then your merge tool) |
| `:P4 delete [file…]` | Open for delete |
| `:P4 move {new}` | Move/rename the current file |
| `:P4 integrate [CL]` | Cherry-pick a submitted changelist |
| `:P4 edit [-c CL] [file…]` | Open for edit (sticky CL, else default) |
| `:P4 add [-c CL] [file…]` | Open for add |
| `:P4 revert[!] [-a] [file…]` | Revert; `!` skips confirmation, `-a` = only unchanged files |
| `:P4 diff[!] [rev]` | Side-by-side diff (`#rev`, `#head`, `@CL`, `@=CL`, `prev`); `!` = `$P4DIFF`; `-a` = all opened files in a diff tab |
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

In plugin views (client view, `:P4 changes`, describe, history, annotate), keys are buffer-local, `?` lists them all, and
any action's keys can be changed or removed:

```lua
keys = {
  p4v = true,         -- P4V shortcuts (<C-d>, <C-r>, …) alongside the vim-style keys
  diff = { 'dd' },    -- per action id (shown in `?` help)
  revert = false,     -- remove an action's keys
}
```

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
<Plug>(perforated-notifications)  <Plug>(perforated-history)
<Plug>(perforated-annotate)       <Plug>(perforated-blame-line)
<Plug>(perforated-describe)       <Plug>(perforated-lookup)
<Plug>(perforated-sync)           <Plug>(perforated-sync-file)
<Plug>(perforated-resolve)        <Plug>(perforated-submit)
<Plug>(perforated-shelve)
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
| `<leader>pL` / `<leader>pb` / `<leader>pB` | History / annotate / toggle current-line blame |
| `<leader>pc` / `<leader>pg` | Describe the file's changelist / lookup |
| `<leader>py` / `<leader>pY` | Sync this file / the workspace |
| `<leader>pR` / `<leader>pP` / `<leader>pz` | Resolve this file / submit its changelist / shelve its changelist |

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
  change = { template = nil, allow_force = false }, -- template: string or function(ws) for new CLs
  merge = { tool = nil }, -- merge tool command (default: $P4MERGE), run as `tool base theirs yours merged`
  picker = 'auto', -- 'telescope' | 'fzf_lua' | 'snacks' | 'mini' | 'select'
  client_view = {
    kind = 'tab', -- 'tab' | 'float' | 'split'
    submitted_limit = 20,
    reconcile = { paths = {} }, -- paths to scan (relative to the client root); {} = whole client
  },
  sync = { resolve_prompt = true }, -- offer to resolve after a sync leaves files unresolved
  changes = { page_size = 50 }, -- :P4 changes page size
  history = { presenter = 'float', limit = 100 }, -- presenter: 'float' | 'picker' | 'quickfix'; limit = page size
  annotate = {
    width = 36,
    integrations = false, -- true: -I, follow integrations to the change that wrote each line
    history_max = 1000, -- filelog depth for descriptions (blame line) and `~` / `d` in annotate
    gradient = nil, -- { oldest, newest } hex colours; default: Comment → DiagnosticWarn
  },
  blame_line = { enabled = false, delay = 150, format = 'CL {change} • {user} • {date} • {desc}' }, -- also {client}
  swarm = { url = nil }, -- default: the server's P4.Swarm.URL property
  keys = { p4v = true }, -- plus per-action overrides (see Keymaps)
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

`:checkhealth perforated`
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
| Lua memory per attached buffer | ≤ 2 KB | ~1.8 KB |
| Client view: render 5000 rows | ≤ 15 ms | ~10 ms |
| Client view: first paint of `:P4` | ≤ 16 ms (one frame) | ~4 ms |
| Annotate: parse / render 20k lines | ≤ 20 / ≤ 25 ms | ~10 / ~16 ms |

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
