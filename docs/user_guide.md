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
- **Checking out runs in the background.** `p4 edit` runs while a "Checking out a.c…" pop-up
  shows, and you keep typing. A `:w` (or `:wq`) made before p4 answers waits for it, saying
  "Waiting for p4 edit of a.c before writing… (Ctrl-C to stop)", for up to `runner.timeout`
  (10 s). If p4 is still working when you press Ctrl-C or the time runs out, the file isn't
  written: Neovim reports it read-only, the buffer keeps your changes and `:wq` doesn't quit.
  `:w` again once the file is checked out.
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
  on a background thread for large files, so nothing calls `p4` while you type. In very large
  files the signs update after a longer pause (100 ms up to 50k lines, up to 500 ms at 500k),
  and never more than one diff runs at a time.
- `]h` / `[h` jump between hunks.
- **Preview** shows the hunk in a float, in the diff views' colours. In a changed line, the
  words that changed are highlighted, as in diff mode. It follows `diff.syntax`, so it's plain
  text by default. `<Esc>` or moving the cursor closes it. Previewing the same hunk again
  moves into the preview, to scroll or copy from it; `q`, `<Esc>` or leaving it closes it.
- **Reset** puts the hunk back to the have revision. It's undoable.

### Directories and wildcards

The file commands (`:P4 edit`, `add`, `revert`, `reopen`, `shelve`, `resolve`, `delete`)
take files, directories and p4 wildcards.

- A wildcard you type runs as given: `:P4 edit src/...` checks out everything under `src`.
- A directory asks first, because it can cover thousands of files. `:P4 edit src` offers
  **All under it** (runs on `src/...`), **Directory as given** (passes `src` to p4 as typed,
  which p4 answers with "not on client"), or **Cancel**, the default.
- `:P4 add src` with **All under it** runs `p4 reconcile -a src/...`: it opens for add only
  the files under `src` that aren't in the depot yet (p4 add takes no wildcards).
- `:P4 revert! src` skips the "local changes will be lost" question, not the directory one.

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
  files and shelved files. Every changelist starts expanded, so your opened files are in view.
  `h` collapses one and it stays collapsed through refreshes, until a file is newly checked
  out, added or moved into it: then it opens again (with Pending, if you collapsed that too).
  `client_view.expand_limit = 30` starts changelists with more than 30 files collapsed (0, the
  default, means no limit).
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

After an action it asks again only for what the action can change: checking out or reverting
a file re-reads your changelists, that file's state and its changed marker (a revert skips
the marker: it can't change a file's content), not every opened file; unshelving, moving or
resolving does the same for the files involved. The file's buffer, the statusline counts and
any list of files to resolve take their state from that same answer. Editing a description re-reads only the changelists;
shelving, deleting shelved files or deleting a changelist re-reads them and that one
changelist's shelf. The Sync CL and Recent submitted are asked
again after a submit or sync. News from the background check re-reads only what it found
changed: files opened, reverted, moved or brought up to date elsewhere re-read your
changelists and those files' changed markers; a changelist created, described or deleted
elsewhere re-reads the changelists, plus the shelf of one that gained or lost shelved
files. Recent submitted is asked again when a changelist or an opened file went away (it
may have been submitted) or a newer revision of an opened file appeared. The Sync CL is
never asked for it: finding it means reading your whole workspace's have list, which is slow
on a large workspace, and only a sync moves it. A sync made outside Neovim shows there on
`<F5>`.

Files you edit outside Neovim (another editor, a script, a code generator) get their changed
marker at the next background check while the view is visible (`poll.interval`, or when you
return to Neovim). The check looks at each opened file's modification time and size, with no
p4 call, and asks p4 only about the files that changed since their marker was found; with
nothing edited it asks nothing. The same answers serve the opened-files picker, `:P4 opened`,
the describe view of a pending changelist, `:P4 hunks` (which skips files known to be
unchanged) and the check that two sides are identical before a diff opens: each asks p4 only
about files edited since, or whose have revision moved (a sync or resolve). A tool that
rewrites a file but keeps its old modification time and size (`cp -p`, `rsync -a`) isn't
noticed: `<F5>` in the client view and `:P4 refresh` always ask about every opened file.

If p4 doesn't answer a query (an error, or no reply within `runner.timeout`), its section
keeps what it showed before, and the view's first line says `refresh failed:` and why. The
next refresh that succeeds takes the line away.

The changed markers have no time limit: p4 reads every opened file to answer, which takes a
while for large files on a slow disk. Until it answers, rows show no marker (unknown, not
unchanged). If the query fails, the rows stay without markers and `<F5>` asks again.

There's no timer. `<F5>`, or `:P4` again, refreshes every section on demand.

### Keys and the action menu

- **`.` or right-click** opens a menu of what you can do with the line under the cursor. It
  lists only what applies, in groups, with each action's Ctrl shortcut on the right. Choose an
  item by its key, by clicking it, or by highlighting it and pressing `<CR>`. Right-clicking
  another line while a menu is open switches to that line's menu. (`<Space>` is left alone,
  since many people use it as their leader key. To use another key:
  `keys = { menu = { '<your key>' } }`.)
- **`?`** lists every key, grouped by section. Keys that do the same thing are separated by a
  dimmed `·`, as in `l · <Tab> · <CR>`.
- **The same key does the same thing in every view:** wherever they apply, `gh` is a file's
  history, `i` edits a description and `dd` deletes a changelist. The keys these views used before (`gL`, `C` and
  `<Del>` in describe) still work for now, but `?` doesn't list them.
- **The footer** shows the keys for the current line. Off a changelist or file, it offers `gS`
  (sync the workspace) and `W` (all my clients, or back to this client).
- **P4V's shortcuts** work alongside the Vim-style keys: `<C-d>` diff, `<C-r>` revert, `<C-n>`
  new changelist, `<C-w>` close, `<F5>` refresh, `<C-1>`/`<C-2>` jump to a section.
  `keys.p4v = false` turns them off.

The full list is `?` in the view, or `:h perforated-client-view`. Some keys need a word more:

- **`d`** diffs an opened file against its have revision, and a shelved file against its base.
  **`w`** diffs a shelved file against your workspace file; on the "Shelved (N)" line it opens a
  diff tab of every shelved file against the workspace.
- **`dd`** deletes a changelist, asking first what happens to its opened files. `d` waits for a second `d` only on a changelist;
  elsewhere it diffs at once.
- **`gs`** syncs to the latest revision: a file, a changelist's files, or "Needs attention".
  **`gS`** syncs the whole workspace.
- **`g@`** on a file picks a revision from its history and syncs the file to it; on a submitted
  changelist it syncs the workspace to that changelist. **`gD`** diffs against a revision you
  pick the same way.
- **`gr`** reverts a file if it's unchanged; on a changelist, it reverts its unchanged files.
- **`K`** on a changelist opens **View changelist**: a scrollable pop-up with the full
  description, the files and the shelved files. `D` there opens the diff tab, and `i` turns
  the pop-up into the description editor (`q` goes back). It works in `:P4 changes` too, so
  you can read other people's changelists.
- **`W`** toggles between this client and all your clients. **`gW`** switches the view to
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
  if unchanged, revert, resolve (when unresolved), move, shelve; diff against the have revision, diff against revision…;
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

- `a` opens the files under the cursor (or selected) for add, edit or delete. A file leaves the
  section once p4 opens it; one p4 refuses stays listed, and the message says why.
- `a` on the section header opens every file the scan found, after a question that counts
  them (`Open 14 file(s) found by the reconcile scan? (9 edit, 4 add, 1 delete)`).
- `d` shows what changed: the have revision against your file for an edit, an empty
  "not in depot" side against it for an add, and the have revision against an empty
  "deleted locally" side for a delete. `o` opens the file (not offered for a delete).
- `x` stops a running scan, as do `:P4 jobs` and `:P4 cancel`.
- `r` scans again.
- To scan only the parts you work on, set `client_view.reconcile.paths`, e.g.
  `{ 'src/myteam' }`. Paths are relative to the client root; local and depot paths work too.
  `p` on the section changes them for the session. Paths are separated by spaces; write a
  space inside a path as `\ ` (what `<Tab>` completion inserts) or put the path in quotes
  (`"my dir" src/other`).
- The scan reads only files whose modification time moved since they were synced
  (`p4 status -m`), so it doesn't hash the whole workspace. A tool that rewrites a file but keeps
  its old mtime (`cp -p`, `rsync -t`, some archive tools) slips past it: set
  `client_view.reconcile.mtime = false` to hash every file, or run `p4 status` in a terminal. On
  a server too old for `-m`, the scan hashes every file by itself.

## Changelists

- **Create one:** `c` in the client view, or `:P4 change new`. A small editor opens for the
  description: `:w` or `<C-s>` saves, `q` cancels. Check-out's "new changelist" uses the same
  editor.
- **Edit a description:** `i`, or `A` to start typing at the end of the text (in the client
  view, `:P4 changes`, describe and the `K` pop-up), or `:P4 change [N]`. This works on
  pending *and* submitted changelists; for your own submitted ones it uses `p4 change -u`.
  Only the description changes, so the file list can't be edited by accident. `gS` in the
  editor, or `:P4 change! N`, opens the full spec instead. The default changelist has no
  description: move its files to a numbered changelist instead.
- **While a description saves**, the editor's footer says `saving…` and another `:w` waits
  for it. If the editor closes before the server answers, the save still goes through; if it
  fails, the editor opens again with your text (unless you chose to discard it).
- **Delete one:** `dd`, or `:P4 change -d N`. One confirmation says what's in it; its opened
  files move to the default changelist (or are reverted, if you choose that), its shelved files
  are deleted, then the changelist is. The default changelist can't be deleted. What the confirmation says is
  asked at once (the changelist with its shelf, and its opened files), as for submit, re-shelve,
  `K` on a pending changelist and its describe view.
- **Another client's changelist** needs `change.allow_force = true`, which retries with `-f`
  after a confirmation. It's meant for admins.
- **Move files:** `gm`. Pick a changelist (the default one included) or create one. On a file it
  moves that file, or the marked files; on a changelist it moves all its opened files.
- **Diff a whole changelist:** `D` opens a diff tab, with a file panel on the left and a
  side-by-side diff on the right. It works for pending changelists, shelves and submitted
  changelists, and `:P4 diff -a` opens it for every opened file.
  - `D` on a file does the same for the changelist it is in (the shelf, for a shelved file),
    and the tab starts on that file.
  - Moving through the panel switches files, as do `<Tab>` / `<S-Tab>` from any window.
    Holding `j` (or `<Tab>`) only moves the cursor: the file you stop on loads once you have
    paused for 50 ms, so files you pass over aren't read from the server. A single move
    loads its file at once.
  - Each shelved or `#head` file is read from the server once per diff tab, while you
    move between files or leave the tab and come back. It shows what it was when first
    shown: after someone re-shelves, press `<F5>` to see the new shelf.
  - `<F5>` (in the panel or either diff side) refreshes the tab in place: the file list
    again (files added to or gone from the changelist or shelf, files now identical), the
    shelved and `#head` files read again, and your workspace files as they are on disk.
    Numbered revisions can't change, so they aren't read again. It stays on the file you're
    viewing, or the one in its place if that file is gone, and the tab closes with a message
    if nothing is left to diff.
  - While you look at one file, the next ones load in the background, several in one call
    to the server (`diff.prefetch`: up to 10 files and 2 MB, files over 512 KB only when
    shown; `files = 0` turns it off). Closing the tab frees what it loaded.
  - Opening the tab, the first file loads while the plugin checks which files are identical,
    so the tab is ready one server round trip sooner. A shelf against your workspace (`w`)
    is checked in one call that compares checksums, without reading the shelved files;
    files that call can't answer (not synced to your workspace, or with unsaved changes in
    Neovim) are compared by content, in batches of 50.
  - In the panel the cursor stays on the file list, and `j` / `k` wrap around at both ends.
    Each line shows the file name first, then its folder, so a narrow panel cuts off the
    folder rather than the name.
  - `o` opens the file: your workspace file in the window you opened the tab from, or the
    revision for a submitted or shelved file. `r` reverts an opened file, after asking; it
    leaves the panel. `<CR>` goes into the diff.
  - Like the other views, the panel has a footer with its keys, `?` for all of them and `.`
    for a menu.
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

### Identical, new and deleted files

Every diff first checks whether the two sides are identical, and if they are just says so.
For a set of files (`D` on a changelist or a shelf, `:P4 diff -a`), only the files that changed
are diffed. Below them, the file panel lists:

- **New Files:** files marked for add (or added, in a submitted changelist), which have nothing
  to compare with;
- **Deleted:** files marked for delete, or deleted;
- **Identical:** files with no changes.

`<Tab>`/`<S-Tab>` step through the diffs only. `j`/`k` move over the new and deleted files too:
the diff stays as it was, and `o` opens the file and `r` reverts it there. If no file has a
diff, the tab doesn't open, and a pop-up lists the files instead.

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

`diff.prefetch = { files = 10, max_kb = 2048, file_max_kb = 512 }` sets how far ahead the
diff tab loads files: how many files at most, how much content in all, and the largest file
it loads ahead (a bigger one loads when you show it). On a slow server, more files ahead means
fewer waits; `files = 0` loads only the file shown.

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

The plugin's other buffers are named after what they show, so `:ls`, your statusline or a
buffer picker tells them apart: `perforated://client/<client>`, `perforated://description/1234`
(the description editor), `perforated://changelist/1234` (`K`), `perforated://files/CL 1234`
(a diff tab's file panel), `perforated://jobs` and so on.

## Describe, history, annotate, blame

### Describe

`:P4 describe N`, or `gd` on a changelist anywhere, opens a buffer with the changelist's
header, full description, files and shelved files. With no number it uses the current file's
changelist.

- `<Tab>` expands a file's diff inline. It's computed only when you expand it.
- `d` opens a side-by-side diff, `D` a diff tab of every file, `gh` the file's history, and
  `Q` sends the files to quickfix.
- On the header or description, `i` edits the description and `dd` deletes the changelist (a
  pending one of yours). On a file, `d` still diffs at once.
- Pending changelists work too: your pending files are diffed against the workspace.
- **Shelves:** `d` compares a shelved file with its base, `w` with your workspace file and
  `gH` with the head revision. `w` on the Shelved line opens a diff tab of every shelved file
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
- `d` diffs that change, `gh` opens the file's history, and `Q` lists every line from it in
  the location list.

It follows branches (`p4 annotate -i`), so each line shows the change that wrote it, not the
one that branched the file. `annotate.integrations = true` follows integrations too (`-I`).

A large file with a long history can take a while to annotate on a slow server: the view
waits for it however long it takes (it shows "annotating…"), and closing the view, or
moving on with `~` / `<BS>`, stops it.

### Current-line blame

`:P4 blame`, or `blame_line = { enabled = true }`, shows who last changed the current line as
virtual text (`blame_line.format`). The file is annotated once per revision, so moving the
cursor makes no p4 calls. Moving to another file stops an annotate still running for the
last one. If a file's annotate fails, the blame line leaves that revision alone for 5
minutes instead of asking again at every cursor stop; `:P4 refresh` makes it ask again.

### Lookup and Swarm

- **`:P4 lookup`** (`g/` / `<C-g>`) goes to a changelist number, a path's history or a user's
  submitted changelists (all of them, from any client and anywhere in the depot). The keys
  work in every Perforce window: the client view, describe, history, annotate, time-lapse,
  `:P4 changes`, diff views, the `K` pop-up, revision buffers and the plugin's quickfix lists.
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
  `a` toggles an age gutter, `b` annotates the revision, `gh` opens the history.

**Modes** (`m` cycles): *single* (the default), *incremental diff* and *range*. The two
comparison modes add a second handle, `◆`, for the older revision you compare against.
*Incremental diff* shows `◆` in a window on the left, diffed against `●`. *Range* shows `●`
with every line added since `◆` highlighted (tagged with the revision that added it) and
every line deleted since `◆` shown where it was. `h` / `l` move `●`, `[a` / `]a` move `◆`,
and the info panel says which mode you're in.

**Long histories** load in two parts, because the server's cost grows with the number of
revisions it walks. The newest `timelapse.window` revisions (50) come first and the view opens
on them; the older ones follow in the background. Until they're in, the older part of the
slider is dashed, its title says `loading revisions before #N…`, and stepping past `#N` tells
you they're still loading. Opening it from a file's buffer also starts that first part
alongside the revision list, instead of after it. `timelapse.window = 0` loads everything at
once.

**Reopening** a file's time-lapse in the same session is instant: the last two closed ones
are kept for ten minutes (unless their text is above 5 MB). If the file has new revisions,
only those are fetched.

Files above `timelapse.max_bytes` (20 MB) point you to their history instead.

## Shelve, submit, sync, resolve, integrate

### Shelve and unshelve

In the client view, `s` shelves and `S` unshelves a changelist or the marked files. `<Del>`
deletes shelved files (on a shelf or a shelved file), and `g<Del>` a changelist's whole shelf.
The commands are `:P4 shelve [-c CL] [file…]`, `:P4 shelve -d` and
`:P4 unshelve CL [-c target]`.

- **The default changelist** can't be shelved by p4. `s` on it (or on its files), or
  `:P4 shelve` on one of its files, asks whether to move them to a new changelist and shelve
  that. The new-changelist editor opens; saving it creates the changelist with those files in
  one call, then shelves it. Shelving some of the files moves only those; quitting the editor
  moves nothing.
- **Re-shelving** asks before replacing the shelf. `r` replaces the shelved copies of the
  files you're shelving. When the shelf also holds files no longer opened in the changelist,
  `a` "replace all" (`p4 shelve -r`) makes the shelf exactly the opened files; the prompt lists
  the ones it would remove.
- **Only changed files:** with `shelve.unchanged = 'leave'` (`p4 shelve -a leaveunchanged`),
  files you checked out but didn't change aren't uploaded; they stay opened. The message counts
  them apart ("shelve: 1 file(s) (2 unchanged, not shelved)"). An unchanged file already in the
  shelf keeps that older version, and the message says so; "replace all" drops it from the
  shelf.
- **Parallel uploads:** `shelve.parallel = 4` asks for 4 upload threads
  (`--parallel=threads=4`). It only helps when the server allows parallel transfers
  (`net.parallel.max` above 0, an admin setting); otherwise p4 shelves one file at a time, as
  without it.
- **Unshelving** goes back into the shelf's own changelist when that's yours; otherwise you
  pick one. Files that need a resolve are listed in quickfix. When some workspace files are
  writable but not opened, p4 unshelves the rest and the plugin asks whether to overwrite
  those; only they are unshelved again.

### Submit

`P` / `<C-s>`, or `:P4 submit [CL]`, opens a confirmation with the description and file
count. It warns about out-of-date, unresolved or shelved files, checked fresh: the changelist's
files and its shelf are asked at the same time, so the confirmation waits for one answer from
the server, not three. `s` submits; `e` edits the description first. For the default
changelist, `s` opens the description editor (pre-filled from `change.template`): `:w` or
`<C-s>` submits with every line of it, `q` cancels the submit. Failures (e.g. out of date) go to quickfix with p4's reason.

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
live progress (files so far, the last file, the time taken), and `x` there stops a job.
Each file counts once, and a job on files you chose shows how many are done, as in
`resolve 4 files · 3s · 2/4 files`;
a sync also shows how far it has got, from the totals p4 sends first, as in
`sync workspace · 12s · 340/1,200 files (28%) · 45.0/160.0 MB`. With
`toast.backend = 'notify'`, the percentage reaches Neovim's progress messages, so fidget or
snacks can draw a bar.
`:P4 cancel` stops them all. Stopping a sync midway is safe: p4 updates your have list file by
file.

Commands that change files (check out, add, revert, delete, move, shelve, unshelve, delete
shelved, submit, resolve, integrate) have no time limit, because stopping one halfway leaves only some files
done. They're jobs too. When a busy pop-up says **Ctrl+c to cancel**, pressing it in normal mode
stops that command only; the key goes back to normal when the pop-up closes. With
`toast.backend = 'notify'` there's no pop-up to press it on, so use `:P4 cancel`.

However you stop a command, a warning tells you what may already have happened, for example
`revert cancelled: some files may already be reverted`. A submit may still go through after you
cancel it, so check the changelist.

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

`:P4 cancel` stops a resolve between files: a merge tool that's already open stays open (you
may be in the middle of a merge), and the files after it are left unresolved in the quickfix
list, where `R` resumes. If p4 can't say which files are still unresolved after `resolve -am`
(the server went away, say), the pop-up says so instead of counting them as merged;
`:P4 status` lists them once p4 answers again.

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

Changes you make from the plugin don't wait for that check: after a check-out, a revert or a
move to another changelist, the statusline and the opened-file counts update within a moment,
even with `poll.interval = 0`.

What was fetched in the last 5 seconds (`poll.reuse`) answers again instead of asking the
server: opening a file just refreshed (from the client view, a diff tab), entering its buffer,
and the pickers and changelist prompts right after the background check or a view refresh.
Any change you make from the plugin ends that at once. A change made outside Neovim in
those seconds shows at the next check or on `<F5>`; `poll.reuse = 0` always asks. While the
server is unreachable or you're logged out, nothing is reused: you get the reason instead.

Entering a buffer asks for its file's status only when the file changed on disk since it was
last asked (a sync from a terminal rewrites it), and right away then; your own saves don't
count. A check-out or revert from elsewhere shows at the next background check. An untouched file is asked again after 10 minutes (`poll.bufenter_max_age`), which
catches what leaves the file alone: a `p4 flush` from elsewhere, or another user opening or
locking it. With `poll.interval = 0` (no background check), entering a buffer asks at most once
a minute (`poll.bufenter_throttle`), as before.

**`:P4 refresh`** asks everything again at once: the status of every open buffer, your opened
files, and the server details. It says `refreshed (N buffers)` when done, or warns if p4
didn't answer. Use it with `poll.interval = 0`, or after changing files outside Neovim.
`:P4 refresh!` also forgets the workspace detection and settings.

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

## Command-line completion

`:P4 <Tab>` completes the subcommands, and after one, its arguments:

- **Changelist numbers** for `change`, `describe`, `submit`, `unshelve` (the ones with a
  shelf), `integrate` and every `-c`, plus `default` or `new` where the command takes them.
  They come from what the plugin already knows (your pending changelists, your opened files,
  the client view's recent submits), so they cost no call to the server.
- **Depot paths:** a word starting with `//` completes from `p4 dirs` and `p4 files` for that
  directory, kept for 5 minutes. A space in a name is completed as `\ `.
- **Users** after `changes -u` (`p4 users`, once per session), and each command's **flags**.

Completion never waits long on the server: a `<Tab>` waits at most `complete.wait` (300 ms)
for a directory or the user list it doesn't have yet. If the server is slower, that `<Tab>`
shows nothing and the next one has the answer. Offline, it doesn't ask the server at all.

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
  you cancel it, calls fail fast and the statusline shows `⊘login` until `:P4 login`, or until
  you come back to Neovim after logging in elsewhere (a terminal, P4V): each return checks the
  ticket (`p4 login -s`, no prompt).
- **Multi-factor sign-in in the browser:** the login waits as long as the sign-in takes. A
  pop-up says "Waiting for the sign-in to finish…"; Ctrl+c cancels the login.
- **Unreachable server:** offline mode. Calls fail immediately with a clear message, and a
  background retry backs off from 5 s to 5 min; the statusline shows `⊘`. A command that's
  merely slow doesn't count: the plugin checks the server first and only goes offline if that
  fails too.
  Commands that list things say why they couldn't instead of showing an empty result: `P`
  says "can't submit: Perforce server unreachable…" rather than "nothing to submit", and
  `:P4 opened`, `:P4 status` and `:P4 hunks` (or `gr` in their list) warn and leave the list
  you had.
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
