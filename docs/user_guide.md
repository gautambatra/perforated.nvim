# perforated.nvim user guide

The [README](../README.md) is the overview; this guide has the details. For the reference
lists of commands, keys and options, see `:h perforated` ([doc/perforated.txt](../doc/perforated.txt)),
which is generated from the code.

- [Editing files](#editing-files): check-out, add, signs and hunks, revert
- [Client view](#client-view)
- [Changelists](#changelists)
- [Diffs](#diffs)
- [Describe, history, annotate, blame](#describe-history-annotate-blame)
- [Time-lapse](#time-lapse)
- [Shelve, submit, sync, resolve, integrate](#shelve-submit-sync-resolve-integrate)
- [Messages and pop-ups](#messages-and-pop-ups)
- [Stale files](#stale-files)
- [Quickfix lists](#quickfix-lists)
- [Pickers, statusline, icons, code actions](#pickers-statusline-icons-code-actions)
- [Workspaces and connections](#workspaces-and-connections)
- [Debug log](#debug-log)
- [Colours](#colours)

## Editing files

### Check-out on edit

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
│  S      don't ask for any file (this session)          │
╰────────────────────────────────────────────────────────╯
```

- **Sticky changelist.** The last changelist you chose becomes the `<CR>` default for the
  session. It's dropped once that changelist is submitted or deleted.
- **Choosing a changelist.** `c` lists the default changelist, your pending ones and
  `+ new changelist…`.
- **Writes never wait on the server.** Choosing a target makes the file writable at once;
  `p4 edit` runs in the background while a "Checking out a.c…" pop-up shows.
- **Warnings.** The menu warns when a newer revision exists in the depot, or when another user
  has the file open.
- **Typing through the menu is safe.** Keys typed in the first 300 ms after the menu appears
  count as text and are replayed into the buffer (`checkout.prompt_grace`).
- **Cancelling isn't skipping.** `<Esc>`, or backing out of the changelist picker or the
  description prompt, leaves the file unopened and read-only. Only `s` skips the buffer, and
  `:e!` resets that. To check out later, reload with `:e!` and edit, or use `:P4 edit`.
- **Without the menu.** `checkout = { prompt = false, on_write = true }` checks out silently
  when you save. `checkout.dirs` limits automatic check-out to the directories you list.

### Add on write

Saving a new file inside the workspace offers to `p4 add` it, with the same menu. Its `s`
means **don't ask again for this file**, for the rest of the session, even if you close and
reopen it. `:w other.c` offers to add `other.c`, the file you wrote, not the buffer's own file.
`checkout.add_on_write` is `'prompt'` (the default), `'auto'` or `false`.

### Gutter signs and hunks

- Signs mark added, changed and deleted lines against your **have** revision. Stale files
  (have < head) get their own marker on the first line.
- The base text is fetched once per revision and cached in memory. Diffs run inside Neovim,
  on a background thread for large files, so nothing calls `p4` while you type.
- `]h` / `[h` jump between hunks.
- **Preview** shows the hunk in a float, in the diff views' colours. In a changed line, the
  words that changed are highlighted, as in diff mode. It follows `diff.syntax`, so it's plain
  text by default. `<Esc>` or moving the cursor closes it.
- **Reset** puts the hunk back to the have revision. It's undoable.

### Revert

- `:P4 revert` asks for confirmation; `:P4 revert!` doesn't.
- `:P4 revert -a` reverts only the files you haven't changed.
- Affected buffers reload automatically.

## Client view

`:P4` opens a P4V-style overview of your workspace in a tab. `:P4 view float` and
`:P4 view split` open it in other layouts, and `client_view.kind` sets the default.

```
Client alice_ws  Stream //main/dev  User alice  perforce:1666  online
    Sync CL: 123501  Nightly integration  bob 2026-09-26

▼ Pending  (3)
    ▼ default  (2)
        ● edit      src/lexer.cpp  #3/#3
          edit      src/util.cpp  #7/#7              ← dimmed: opened, unchanged
    ▼ CL 123470  Fix crash in parser  (1)  S 1
        ● edit      src/parser.cpp  #4/#5  ↓ stale
        ▶ S Shelved (1)

▼ Needs attention  (1)
    ● edit (123470)  src/parser.cpp  #4/#5  ↓ stale

▶ Workspace reconcile  · src/myteam  (not scanned)

▶ Recent submitted  (20)
 d diff against have revision  D diff all files  …  . actions  ? help
```

### What it shows

- **The top line:** client, stream, user, server and connection state.
- **Sync CL:** the newest changelist your workspace has synced. `gd`, `K` and `y` work on it.
- **Pending:** your pending changelists, the default one first and then the newest, with their
  files and shelved files.
- **Needs attention:** opened files that are stale or unresolved.
- **Workspace reconcile:** files changed outside Perforce, to open for add, edit or delete
  (`a`). See [Reconcile](#reconcile).
- **Recent submitted:** your latest submits, from any client and anywhere in the depot
  (`client_view.submitted_limit`, 20 by default). The last row, "… all my submitted
  changelists", opens the full list: `<CR>` on it, or `gn` anywhere in the section. That's
  `:P4 changes` for all your clients, loaded a page at a time as you scroll.

### File markers

- **Changed or not:** an opened file that differs from its base gets a `●` and the "modified"
  colour. One that's opened but unchanged is dimmed, like P4V's blue and white file icons.
  Unsaved edits count, and the marker updates when you save. The describe buffer and the
  `:P4 opened` list use the same markers (`·` for unchanged there).
- **Stale and unresolved:** a stale file's path and `●` are drawn in the stale colour, an
  unresolved file's in orange. Unresolved wins when both apply.

### Staying current

The view re-queries every time it opens or refreshes. It draws a skeleton at once, and each
section fills in as soon as its own query answers, so a slow one never holds back the rest.

After that it refreshes itself:

- after every plugin action on the workspace (check-out, revert, resolve, submit, sync…),
  wherever in Neovim you started it;
- when the background check finds news, such as a file becoming stale or someone resolving one.

There's no timer. `<F5>`, or `:P4` again, refreshes on demand.

### Keys and the action menu

- **`.` or right-click** opens a menu of what you can do with the line under the cursor. It
  lists only what applies, in groups, with each action's Ctrl shortcut on the right. Choose an
  item by its key, by clicking it, or by highlighting it and pressing `<CR>`. Right-clicking
  another line while a menu is open switches to that line's menu. (`<Space>` is left alone,
  since many people use it as their leader key. To use another key:
  `keys = { menu = { '<your key>' } }`.)
- **`?`** lists every key, grouped by section. Keys that do the same thing are separated by a
  dimmed `·`, as in `l · <Tab> · <CR>`.
- **The footer** shows the keys for the current line. Off a changelist or file, it offers `gS`
  (sync the workspace) and `W` (switch client).
- **P4V's shortcuts** work alongside the Vim-style keys: `<C-d>` diff, `<C-r>` revert, `<C-n>`
  new changelist, `<C-w>` close, `<F5>` refresh, `<C-1>`/`<C-2>` jump to a section.
  `keys.p4v = false` turns them off.

The full list is `?` in the view, or `:h perforated-client-view`. Some keys need a word more:

- **`d`** diffs an opened file against its have revision, and a shelved file against its base.
  **`w`** diffs a shelved file against your workspace file; on the "Shelved (N)" line it opens a
  diff tab of every shelved file against the workspace.
- **`dd`** deletes an empty changelist. `d` waits for a second `d` only on a changelist;
  elsewhere it diffs at once.
- **`gs`** syncs to the latest revision: a file, a changelist's files, or "Needs attention".
  **`gS`** syncs the whole workspace.
- **`g@`** on a file picks a revision from its history and syncs the file to it; on a submitted
  changelist it syncs the workspace to that changelist. **`gD`** diffs against a revision you
  pick the same way.
- **`gr`** reverts a file if it's unchanged; on a changelist, it reverts its unchanged files.
- **`K`** on a changelist opens **View changelist**: a scrollable pop-up with the full
  description, the files and the shelved files. `D` there opens the diff tab, and `C` turns
  the pop-up into the description editor (`q` goes back). It works in `:P4 changes` too, so
  you can read other people's changelists.
- **`A`** toggles between this client and all your clients. **`W`** switches the view to
  another of your clients, picked from a list with their root, host and stream. If Perforce
  refuses (say, a client bound to another host), the view keeps its client. Your open files
  are unaffected: each stays in its own workspace.
- **`Q` / `gQ`** send the line, the marked lines or a whole changelist to quickfix / the
  location list.

**Several files at once:** `m` marks files for an action such as revert, move or shelve, and
`u` clears the marks. Or select rows with `V` and press the action's key. A changelist selected
together with its files counts once. This works in every list view, describe and history
included.

Folds are kept across refreshes.

### What the menu offers

- **On a changelist:** submit; view, diff all, edit the description, copy the number or Swarm
  URL, quickfix, sync to the latest revision (when a file is stale), delete (when no files are
  opened in it); revert unchanged, revert, resolve (with unresolved files), move all files;
  shelve, unshelve, delete shelved files; new changelist, sync, switch client.
- **On an opened file:** open, sync to the latest revision (when stale), get revision…; revert
  if unchanged, revert, move, shelve; diff against the have revision, diff against revision…;
  history, annotate, time-lapse; mark; new changelist, sync, switch client.
- **On a shelved file:** diff against its base, diff against the workspace file; unshelve it,
  delete it from the shelf; history, time-lapse; mark; new changelist, sync, switch client.
- **On a submitted changelist** (Recent submitted, and `:P4 changes`): view, copy the number;
  diff all files, integrate into this workspace, edit the description (your own), sync the
  workspace to it, copy the Swarm URL; all my submitted changelists, sync, switch client.
- **On a file of a submitted changelist:** open that revision; history, time-lapse, diff
  against the previous revision, diff against revision…; view its changelist.

### Reconcile

Scanning for files changed outside Perforce is expensive on a large workspace, so the section
only scans when you expand it (`l`).

- `x` stops a running scan, as do `:P4 jobs` and `:P4 cancel`.
- `r` scans again.
- To scan only the parts you work on, set `client_view.reconcile.paths`, e.g.
  `{ 'src/myteam' }`. Paths are relative to the client root; local and depot paths work too.
  `p` on the section changes them for the session.

## Changelists

- **Create one:** `c` in the client view, or `:P4 change new`. A small editor opens for the
  description: `:w` or `<C-s>` saves, `q` cancels. Check-out's "new changelist" uses the same
  editor.
- **Edit a description:** `i`, `:P4 change [N]`, or `C` in the `K` pop-up. This works on
  pending *and* submitted changelists; for your own submitted ones it uses `p4 change -u`.
  Only the description changes, so the file list can't be edited by accident. `gS` in the
  editor, or `:P4 change! N`, opens the full spec instead. The default changelist has no
  description: move its files to a numbered changelist instead.
- **Delete one:** `dd`, or `:P4 change -d N`. In the client view `dd` is offered only on a
  changelist with no opened files. One confirmation says what's in it; its opened files move to
  the default changelist (or are reverted, if you choose that), its shelved files are deleted,
  then the changelist is. The default changelist can't be deleted.
- **Another client's changelist** needs `change.allow_force = true`, which retries with `-f`
  after a confirmation. It's meant for admins.
- **Move files:** `gm`. Pick a changelist (the default one included) or create one. On a file it
  moves that file, or the marked files; on a changelist it moves all its opened files.
- **Diff a whole changelist:** `D` opens a diff tab, with a file panel on the left and a
  side-by-side diff on the right. It works for pending changelists, shelves and submitted
  changelists, and `:P4 diff -a` opens it for every opened file.
  - Moving through the panel switches files, as do `<Tab>` / `<S-Tab>` from any window.
  - In the panel the cursor stays on the file list, and `j` / `k` wrap around at both ends.
  - Each file opens at its first change, with both sides scrolled in line. It loads when you
    select it, and the next one is fetched ahead of time.
  - `Ctrl+1` / `Ctrl+2` jump to the previous / next change, like `[c` / `]c`, in terminals that
    report Ctrl+digit.
- **Browse submitted changelists:** `:P4 changes [-u user] [-m N] [path]`, newest first. It's
  scoped to your client view unless you give a path; `-u` shows another user's work. Pages load
  as you reach the end, or with `gn`.
  - `l` expands a changelist into its files and `h` collapses it.
  - On a file: `d` or `<CR>` diffs that revision against the previous one, `gD` against a
    revision you pick, `o` opens that revision, `gh` shows its history, `t` its time-lapse and
    `K` its changelist.
  - `D` diffs every file in a tab, `i` edits a description (your own), `<F5>` refreshes.
  - The client view's "Recent submitted" rows expand the same way.

## Diffs

### One file

`:P4 diff` opens the current file against its depot revision, side by side in a new tab, in
Neovim's diff mode (`]c`, `do`, `dp` all work).

- It takes a revision: `#rev`, `#head`, `@CL`, `@=CL` (shelved) or `prev`.
- Each side has a header naming the file and what it is: `#4 (have)`, `@=123 (shelved)`,
  `(workspace)`.
- `q` in either side, or `:q`, closes the whole tab. (In your own file, `q` only does this
  inside the diff tab.)
- The mouse wheel over either side scrolls both, whichever window has focus.

### Identical files

Every diff first checks whether the two sides are identical, and if they are just says so.
For a set of files (`D` on a changelist or a shelf, `:P4 diff -a`), identical files are listed
under "Identical" at the end of the file panel and only the rest are diffed. If every file is
identical, the diff tab doesn't open.

Diffing a shelf against the workspace (`w` on a shelf) also lists, under "Not in Shelf", every
file you have opened (in any changelist) that the shelf doesn't hold.

### Your own diff tool

`:P4 diff!`, or `diff.tool = 'external'`, opens your **`$P4DIFF`** tool with your own
environment. GUI tools run detached; terminal tools open in a terminal tab
(`diff.external_terminal` decides which is which when the name doesn't say). If a GUI tool
fails, the error includes the line of its output that says why. Exit code 1 means "files
differ" for diff tools, so it only counts as a failure when the tool printed an error.

### Diff colours

By default diff views use your colorscheme with syntax colouring turned off in the two sides,
so only the diff colours stand out. `diff.syntax = true` brings syntax colouring back.

`diff.colors = 'perforated'` switches the whole diff view (both sides, the file panel, the
headers) to the plugin's own light palette, after onedark's light style, with crisp black
window separators. A table changes single colours of it, e.g. `{ diff_add = '#d8f5dc' }`; the
names are in `:h perforated-diff-colors`.

Only the diff windows change. Other tabs and windows keep your theme, even when they show the
same file, and switching themes (by hand or with auto-dark-mode) leaves a `'perforated'` diff
light.

### Customising the diff tab

`User PerforatedDiffOpen` fires when a diff tab is ready, and `User PerforatedDiffClose` once
it closes, whether by `q`, `:q` or `:tabclose`. `ev.data` holds `{ tab, wins = { left, right },
bufs = { left, right }, spec, path }`:

```lua
vim.api.nvim_create_autocmd('User', {
  pattern = 'PerforatedDiffOpen',
  callback = function(ev) vim.wo[ev.data.wins.left].cursorline = true end,
})
```

For settings that should apply to every diff (`nvim -d`, `:diffsplit`, `:P4 diff`), use
`OptionSet` with the pattern `diff` instead, and restore them when the last diff window closes.

### Depot revisions as buffers

Any depot revision opens as a read-only buffer, e.g.
`:e perforated:////depot/path/file.c\#3` (escape `#` in `:e`).

## Describe, history, annotate, blame

### Describe

`:P4 describe N`, or `gd` on a changelist anywhere, opens a buffer with the changelist's
header, full description, files and shelved files. With no number it uses the current file's
changelist.

- `<Tab>` expands a file's diff inline. It's computed only when you expand it.
- `d` opens a side-by-side diff, `D` a diff tab of every file, and `Q` sends the files to
  quickfix.
- Pending changelists work too: your pending files are diffed against the workspace.
- **Shelves:** `d` compares a shelved file with its base, `w` with your workspace file and
  `gh` with the head revision. `w` on the Shelved line opens a diff tab of every shelved file
  against the workspace.
- **`S` unshelves** anyone's shelf, another user's or another client's too: on a shelved
  file, that file; on the header or the Shelved line, the whole shelf. It goes into the
  changelist itself when that's yours in this workspace; otherwise you pick one. The `K`
  pop-up has `S` too.

### File history

`:P4 filelog [path]`, or `gh` / `<C-t>` in the client view, lists a file's revisions in a
float, with the files a branch came from. A directory's history is its list of changelists.

- `<CR>` opens the action menu: `d` diff against the previous revision, `w` against your
  workspace file, `gd` describe, `K` view the changelist, `o` open the revision read-only,
  `b` annotate it.
- **Comparing two revisions:** mark them with `m` (`u` clears) or select them with `V`, then
  `D` diffs them, older on the left. `gD` picks the other revision from the file's history.
- Pages load as you reach the end, or with `gn`. `Q` moves the list to the location list.
- `history.presenter = 'picker'` or `'quickfix'` shows it there instead.

### Annotate

`:P4 annotate`, or `b`, opens a split left of the file showing the changelist, user and date
that last changed each line, coloured by age. It scrolls with the file, and your local edits
show "Not submitted".

- `<CR>` describes the line's changelist.
- `~` re-annotates the revision before that change, and `<BS>` goes back.
- `d` diffs that change, and `Q` lists every line from it in the location list.

It follows branches (`p4 annotate -i`), so each line shows the change that wrote it, not the
one that branched the file. `annotate.integrations = true` follows integrations too (`-I`).

### Current-line blame

`:P4 blame`, or `blame_line = { enabled = true }`, shows who last changed the current line as
virtual text (`blame_line.format`). The file is annotated once per revision, so moving the
cursor makes no p4 calls.

### Lookup and Swarm

- **`:P4 lookup`** (`g/` / `<C-g>`) goes to a changelist number, a path's history or a user's
  changelists. The keys work in every Perforce window: the client view, describe, history,
  annotate, time-lapse, `:P4 changes`, diff views, the `K` pop-up, revision buffers and the
  plugin's quickfix lists.
- **`gX`** copies a changelist's Swarm review URL. The URL comes from `swarm.url` or the
  server's `P4.Swarm.URL` property.

## Time-lapse

`:P4 timelapse` (`t` on a file in the client view, describe, history or annotate; `<C-S-t>`)
opens the file read-only, with its syntax highlighting, and steps through every revision
instantly.

- **Moving:** `h` / `l` (or `[r` / `]r`) step back and forward, `[R` / `]R` jump to the first /
  last revision, `r` goes to `#N` or `@CL`, and `T` picks a revision by its description. The
  cursor stays on the same line of the file as you step, even when lines are added or removed
  above it.
- **What changed:** lines added in the shown revision are highlighted, and lines it deleted
  are shown where they were.
- **The Slider Revision panel**, right of the file, shows the revision's details: file and
  revision, changelist, date, file type, author, size, action and the full description (scroll
  it with `<C-w>l`). `i` hides / shows it; `timelapse.info_position = 'bottom'` puts it below.
- **The slider**, above the file, has a tick per revision, labelled with changelist numbers
  (`S` switches to revision numbers). `●` marks the shown revision; click the track to jump.
  `s` hides it (`timelapse.slider = false` starts without it).
- **Other keys:** `d` diffs against the previous revision, `D` describes the changelist, `K`
  shows it in a pop-up, `y` copies its number, `Q` lists the lines it added (location list),
  `a` toggles an age gutter, `b` annotates the revision, `gL` opens the history.

**Modes** (`m` cycles): *single* (the default), *incremental diff* and *range*. The two
comparison modes add a second handle, `◆`, for the older revision you compare against.
*Incremental diff* shows `◆` in a window on the left, diffed against `●`. *Range* shows `●`
with every line added since `◆` highlighted (tagged with the revision that added it) and
every line deleted since `◆` shown where it was. `h` / `l` move `●`, `[a` / `]a` move `◆`,
and the info panel says which mode you're in.

Files above `timelapse.max_bytes` (20 MB) point you to their history instead.

## Shelve, submit, sync, resolve, integrate

### Shelve and unshelve

In the client view, `s` shelves and `S` unshelves a changelist or the marked files. `<Del>`
deletes shelved files (on a shelf or a shelved file), and `g<Del>` a changelist's whole shelf.
The commands are `:P4 shelve [-c CL] [file…]`, `:P4 shelve -d` and
`:P4 unshelve CL [-c target]`.

- **Re-shelving** asks before replacing the shelf. `r` replaces the shelved copies of the
  files you're shelving. When the shelf also holds files no longer opened in the changelist,
  `a` "replace all" (`p4 shelve -r`) makes the shelf exactly the opened files; the prompt lists
  the ones it would remove.
- **Unshelving** goes back into the shelf's own changelist when that's yours; otherwise you
  pick one. Files that need a resolve are listed in quickfix.

### Submit

`P` / `<C-s>`, or `:P4 submit [CL]`, opens a confirmation with the description and file
count. It warns about out-of-date, unresolved or shelved files. `s` submits; `e` edits the
description first. Failures (e.g. out of date) go to quickfix with p4's reason.

### Sync

- **The workspace:** `gS` / `<C-S-g>`, or `:P4 sync`.
- **Files, to their latest revision:** `gs` on a file, a changelist or "Needs attention";
  `:P4 sync %` or `:P4 sync path…`.
- **To a changelist:** `g@` on any submitted changelist (Recent submitted, the Sync CL row,
  `:P4 changes`, describe, history), `:P4 sync @12345`, or `:P4 sync @` to pick one. Labels and
  dates work too: `:P4 sync @mylabel`, `@2026/09/01`.

Every sync asks first, with a **Preview** choice (`p4 sync -n`): how many files would be
updated, added or deleted, and whether opened files are affected.

Afterwards:

- Open buffers reload without "file changed" prompts, and their signs follow the new revision.
- Every opened file is re-checked. Files that need attention go to quickfix: files p4 couldn't
  overwrite, files named in other errors, and *every* unresolved file in the workspace, not
  just this sync's.
- If anything didn't go as asked, a pop-up in the middle of the screen lists it, so it can't
  go unnoticed. For example, a file that's writable but not opened stays at its old revision.
  When files need resolving, it offers to resolve now (`sync.resolve_prompt = false` turns
  that off).
- The result counts each kind: `12 updated · 2 not updated (writable, not opened) · 3 to
  resolve`.

### Watching and stopping jobs

A sync or submit shows a pop-up when it starts and one with the result. `:P4 jobs` shows the
live progress (files so far, the last file, the time taken), and `x` there stops a job;
`:P4 cancel` stops them all. Stopping a sync midway is safe: p4 updates your have list file by
file.

### Resolve

`R`, or `:P4 resolve [file…]`:

1. `p4 resolve -am` takes every clean merge.
2. Each remaining conflict opens your merge tool (`$P4MERGE`, or `merge.tool`) as
   `tool base theirs yours merged`. Neovim stays usable while it runs.
3. When the tool exits 0 with a changed result, the result is accepted as an edited merge,
   like `p4 resolve`'s own `ae`, and written to the file (through the buffer if it's open).
4. Anything else stays unresolved and goes to quickfix, where `R` on an entry tries again.

At the end a pop-up says what happened: merged automatically, merged with your merge tool,
and every file left unresolved with the reason (`c` opens the quickfix list). When the merge
tool fails, the reason includes the line of its output that says why; the full output is in
`:P4 log`. On Linux a GUI tool such as p4merge needs `$DISPLAY` or `$WAYLAND_DISPLAY`: without
either it isn't launched, and the pop-up says so.

Resolve runs as a job (`:P4 jobs`, `:P4 cancel`) without the usual time limit, since merging
happens on your machine and can take a while. The plugin has no merge logic of its own.

### Delete and move

- `:P4 delete [file…]` opens files for delete, after a confirmation, and closes the buffer.
- `:P4 move {new path}` moves or renames the current file, opening it for edit if needed. The
  buffer follows the file and keeps any unsaved edits.

### Integrate

`I` on a submitted changelist, or `:P4 integrate [CL]`, cherry-picks it into your workspace.

1. **Target.** The source is the changelist's common directory. You give the target as a path
   (`//depot/rel/...`) or a branch spec (`-b name`), remembered for the session. In a stream
   workspace, your stream is offered. Relative paths line up: a change under
   `//stream1/app/src` integrated into `//stream2/...` lands in `//stream2/app/src`. Any two
   streams work, not just parent and child.
2. **Changelist.** Pick where the files go: the default changelist, a pending one, a new one,
   or a new one with the original description filled in for you to edit. A new changelist is
   deleted again if you cancel.
3. **Preview.** The planned files go to quickfix; you confirm.
4. **Integrate and resolve.** Clean merges are accepted; conflicts go to your merge tool.

`:P4 integrate` with no number asks for a source path and lets you pick one of its
changelists.

## Messages and pop-ups

Everything the plugin tells you appears as a small pop-up instead of on the command line,
centred horizontally. Where it sits says what it is:

- **Near the top:** the result of something you just did ("created CL 123", "moved 2 files",
  p4 errors from your command, a job that failed). Errors have a red border.
- **At the bottom**, above the statusline: news you didn't ask for just then (newly stale
  files, a job that finished).
- **In the middle:** things you're waiting on, confirmations and text prompts.

The check-out menu is the exception: it opens at the cursor, where you were typing.

- **Pop-ups never take focus** and never cause a "Press ENTER" prompt. A message's dismissal
  countdown (`toast.timeout`, 3 s) starts only once you press a key; `0` keeps messages until
  `:P4 dismiss`.
- **`:P4 messages`** (`<leader>pm`) shows the recent ones; `:P4 dismiss` closes them.
- **Busy pop-ups.** Anything that waits on the server says so from the moment you ask:
  "Checking out a.c…", "Opening diff view…", "Shelving CL 123…", "Submitting CL 123…",
  "Merging CL 123…". If a question comes up on the way ("replace the shelf?"), the busy pop-up
  steps aside for it and comes back until the work is done. It also steps aside while your
  merge tool runs.
- **Questions** are pop-ups too. Confirmations are a small menu: the underlined letter
  chooses, `<CR>` takes the default, `<Esc>` cancels. Text prompts are a one-line input box.
- **Closing.** Every pop-up you can focus closes with `q` or `<Esc>`: `K`, history, the client
  view as a float, menus, prompts, the picker, `?` help, `:P4 jobs`. The hunk preview closes
  with `<Esc>` or when you move.
- **Stacked pop-ups.** When one pop-up opens over another (the lookup over a file history, a
  menu over the `K` pop-up), the one in use gets a border in your theme's accent colour and the
  ones under it are dimmed. Input boxes have a more prominent border.

**Prefer your own notifier** (nvim-notify, snacks, fidget, …) or the command line? Set
`toast = { backend = 'notify' }`. Every message then goes to `vim.notify`, questions go to
`confirm()` and `vim.ui.input` (so snacks.input or dressing apply), and running jobs show
Neovim's progress messages. The only prompt that always stays on the command line is the
`p4 login` password.

## Stale files

A **cheap background check** runs every 30 seconds (`poll.interval`), only while Neovim has
focus and once a Perforce file or the client view is open. It also runs when focus returns
and when you enter a Perforce buffer. It asks three small questions:

- Was a newer revision of your files submitted?
- Did your opened files change elsewhere (opened, reverted, moved or unshelved from another
  terminal or P4V)?
- Did your pending changelists change (created, deleted, described or shelved elsewhere)?

Only when one of the answers is yes does the full status query run and the client view
refresh. Re-shelving new versions into an existing shelf isn't visible this way; `<F5>` shows
it.

**When an opened file becomes stale**, a pop-up at the bottom names the file, the new
revision, the changelist and who submitted it. Notifications raised while Neovim was
unfocused wait until you come back. The stale marker stays in the statusline and the sign
column until you sync.

## Quickfix lists

| Command | List |
|---|---|
| `:P4 opened` | Opened files grouped by changelist, with `STALE` / `UNRESOLVED` flags |
| `:P4 status` | Stale and unresolved opened files, with the reason |
| `:P4 hunks` | Every hunk across all opened files |
| `:P4 hunks %` | Hunks of the current file, in the location list |

- `gr` re-runs the query and `d` diffs the entry under the cursor.
- Files that need resolving end with "· R resolves": `R` resolves that file.
- Lists of files to resolve keep up with you. Once a file is resolved (from the list, the
  client view, `:P4 resolve`) or reverted, its entry disappears; when none are left, the title
  says "all resolved" and the window closes.

## Pickers, statusline, icons, code actions

Every plugin that changes how perforated looks or behaves, and what you get without it, is
listed in [integrations.md](integrations.md).

### Pickers

Every list-picking step (e.g. choosing a changelist) and `:P4 pick {pending|opened|submitted|users}`
use your fuzzy finder: **telescope**, **fzf-lua**, **snacks.picker** or **mini.pick**, detected
in that order. Without one, the plugin uses **its own list**: a filter line, the list and a
preview.

- Lists of changelists preview what `K` shows: the header, the full description, the files and
  the shelved files. (fzf-lua shows no preview.)
- In the plugin's own list: `j` / `k` / arrows move (wrapping around), `<CR>` or a double-click
  chooses, `q` / `<Esc>` cancel. `i` or `/` types in the filter line (fuzzy; arrows still move
  the list, `<Esc>` goes back to it). `m` marks several where that's allowed. Leaving the pop-up
  cancels it.
- Pickers open in **normal mode**, even from insert mode; `picker_mode = 'insert'` starts in the
  filter line instead. That applies to the plugin's list, telescope and snacks.picker (fzf-lua
  and mini.pick have no normal mode).
- `picker = 'telescope'` (etc.) chooses one explicitly, `'perforated'` forces the plugin's own
  list and `'select'` uses `vim.ui.select` (e.g. with dressing.nvim). With
  `toast.backend = 'notify'` the fallback is `vim.ui.select`. `:checkhealth perforated` shows
  which one is used.

### Statusline

```lua
-- lualine: a built-in component
sections = { lualine_c = { 'filename', 'perforated' } }
-- or a plain statusline
vim.o.statusline = '%f %= %{v:lua.require("perforated").statusline()} '
```

For a function-style component, pass the function itself, `require('perforated').statusline`,
without `()`. Calling it in your config evaluates it once at startup and shows an empty string.

What it shows, e.g. `alice_ws edit@123 ● #4 ↓#5 !unresolved  ↓2 !1`:

- **The client**, then for an **opened file** its action and changelist (`edit@123`), and `●`
  when it differs from the revision you have.
- **The revision you have** (`#4`), or `not in depot` for a new file.
- **When they apply:** `↓#5` if a newer revision exists (stale), `!unresolved` if it needs a
  resolve, and for the whole workspace `↓2` stale opened files, `!1` unresolved, `⊘` offline or
  `⊘login` when you need to log in.
- **Outside Perforce:** nothing.

The file part is `statusline.format`, a template of tokens that disappear when they don't
apply: `{client}`, `{action}`, `{change}`, `{modified}`, `{rev}`, `{head}`, `{stale}`,
`{unresolved}` and `{diff}` (lines added / changed / removed, e.g. `+3 ~1 -2`). To add line
counts to the default:

```lua
statusline = { format = '{client} {action} {modified} {diff} {rev} {stale} {unresolved}' }
```

It can also be a function that receives the status dict and returns the string. The raw data
is in `vim.b.perforated_status_dict` (per buffer) and `vim.g.perforated_status` (workspace),
and a `User PerforatedStatus` event fires whenever they change.

### Icons

File-type icons come from mini.icons or nvim-web-devicons, when installed. Status glyphs use
Nerd Font symbols, with an ASCII fallback. Both are configurable (`icons`).

### Code actions (experimental)

`lsp = { enabled = true }` attaches a small in-process language server to Perforce buffers (no
external process), so your code-action menu (`gra`, or your picker's) offers what applies to
the file and line: check out, get latest, resolve, diff, preview / undo the change under the
cursor, move to another changelist, revert (if unchanged), describe the file's changelist or
the one that last changed the line, history, annotate, time-lapse.

## Workspaces and connections

- **Finding the workspace.** Opening a file looks for your `P4CONFIG` file in that file's
  directory and its parents (in Lua, cached, starting no processes). Every p4 command for that
  workspace runs from the directory containing it, so all its buffers see the same settings.
  Without a `P4CONFIG` file but with `P4CLIENT` set, one background `p4 info` per session
  learns the client root.
- **Several workspaces** can be open in one session; each keeps its own connection, caches and
  settings. Several Neovim instances on one machine never interfere.
- **Expired login:** exactly one password prompt, then the calls that failed are retried. If
  you cancel it, calls fail fast and the statusline shows `⊘login` until `:P4 login`.
- **Unreachable server:** offline mode. Calls fail immediately with a clear message, and a
  background retry backs off from 5 s to 5 min; the statusline shows `⊘`. A command that's
  merely slow doesn't count: the plugin checks the server first and only goes offline if that
  fails too.
- **`:P4 log`** lists every p4 command the plugin ran, with timings.

## Debug log

For diagnosing problems, perforated can write a detailed log file. It's off by default and
costs nothing while off. Three ways to turn it on:

```sh
PERFORATED_DEBUG=1 nvim          # for one session (or PERFORATED_DEBUG=trace)
```
```vim
:P4 debug on [trace|debug|info]  " at runtime
```
```lua
opts = { debug = { enabled = true } }  -- always
```

The file is `stdpath('log')/perforated.log`, typically `~/.local/state/nvim/perforated.log`.
It records why each file was or wasn't treated as a Perforce file; every p4 command with its
directory, timing, result and errors; connection and login changes; buffer status changes and
check-out prompts; and the background checks. Each line carries the Neovim process ID, so
several sessions can share the file, and it rotates at `debug.max_kb`. **Secrets are never
written:** the password sent to `p4 login` and `P4PASSWD` are redacted.

| Command | |
|---|---|
| `:P4 debug` | Whether logging is on, and where the file is |
| `:P4 debug on [level]` / `off` | Turn it on or off |
| `:P4 debug timings` | Where the time goes: p4 calls per command and the plugin's own work |
| `:P4 debug snapshot` | Write the current state to the log, for bug reports |
| `:P4 debug open` / `clear` | Open or delete the log file |

## Colours

Every highlight group is a `default` link (or a derived colour), so your config or theme can
override it; `:h perforated-highlights` lists them all. The ones you're most likely to change:

| Group | What | Default |
|---|---|---|
| `PerforatedAdd` / `Change` / `Delete` / `Stale` | Gutter signs | `Added` / `Changed` / `Removed` / `DiagnosticWarn` |
| `PerforatedModified` / `PerforatedUnchanged` | Opened files, changed or not | `Changed` / `Comment` (dimmed) |
| `PerforatedBar` / `PerforatedBarText` | The client view's top line and key footer | gdu's blue, `#2479d0`, in every theme; black / white text |
| `PerforatedFloatBorderActive` | The pop-up in use, when pop-ups are stacked | `FloatTitle` |
| `PerforatedInputBorder` | Input boxes | `DiagnosticWarn` |
| `PerforatedPreviewAdd` / `Delete` / `Text` | The hunk preview | `DiffAdd` / `DiffDelete` / `DiffText` |

Diff views have their own settings, `diff.colors` and `diff.syntax`: see [Diff colours](#diff-colours).
