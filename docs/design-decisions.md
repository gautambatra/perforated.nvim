# perforated.nvim — design decisions (interview log)

Converged with the author on 2026-09-23 via interview. This is the source of truth for behaviour; the implementation plan is in `plan.md`.

## Environment & targets
- Primary environment: fast LAN server, workspaces of 100k–1M files, `noallwrite` (read-only unopened files).
- Depots: both streams and classic.
- **Per-workspace internals, shared, never duplicated.** A registry holds **one** Workspace object per workspace (keyed by anchor), which owns connection state, `p4 info`, the fstat cache, CL memo, sticky CL, poller and queue. Buffers hold only a *reference* plus truly per-buffer data (base text via the shared content LRU, hunks, extmarks). Every buffer binds to the workspace containing it (anchor = the directory containing P4CONFIG, else the client root). Signs, check-out, statusline and diff always use the buffer's workspace. Views bind to the workspace they were opened from, with the client shown in the header; `gw` switches when several are active.
- **Dormant outside Perforce.** Only the commands, `<Plug>` maps and one autocmd are defined; nothing else loads, and no processes, timers or caches exist. Activation is a pure-Lua, per-directory cached P4CONFIG lookup; env-only setups use one background `p4 info` per session.
- **Commands outside a workspace:** connection-only commands work anywhere a port and user resolve (`describe`, `changes`, CL lookup, `filelog`/`annotate`/`print` of depot paths, `perforated://` links, a user's submitted CLs). Workspace-only commands reply "not in a Perforce workspace".
- **Session isolation:** all state is in-process memory, per session. There is **no disk cache**, and temp files live in Neovim's per-process temp directory. The only shared thing is p4's own ticket file.
- **p4 working directory:** every call for a workspace runs from its anchor, with `PWD` set to it and absolute paths. Project root markers are irrelevant to p4.
- **Environment for p4 calls:** only the *internal* background calls neutralize `P4EDITOR`/`P4DIFF`/`P4MERGE` (set to `false`) and unset `P4PAGER`, so a stray launch can't hang them. Connection variables are never touched. Launches the user asks for use the untouched environment. The user's **`$P4DIFF` always works**: the external-diff action launches it as p4 would (`$P4DIFF <depot copy> <workspace file>`, with the user's environment and tool arguments). p4 itself can't be relied on here because `p4 diff` skips identical files and `p4 diff2` ignores P4DIFF. GUI tools run detached, terminal tools in a `:terminal` tab. `$P4MERGE` is launched the same way for resolve.
- Neovim floor: **0.11+** (author on 0.12.5).
- Platforms: Linux, macOS, WSL (no native Windows).
- Dependencies: **zero hard deps** (pure Lua + p4 binary); pickers/statuslines/notifiers are optional integrations.

## Check-out / add
- Trigger: **first modification** of an unopened depot file (keystroke not blocked).
- Prompt: **small floating menu** near cursor: `<CR>` default/sticky CL, `c` existing CL (picker), `n` new CL (inline description), `A` always use this target for the rest of the session without asking (added in M1 for `:bufdo`/macro edits across many files), `s` skip for buffer (in the **add** prompt: "don't ask again for this file", for the session, surviving close/reopen — 2026-10-02), `S` "don't ask for any file (this session)" — check-out and add prompts both stop.
- While `p4 edit` / `p4 add` runs, a centred busy pop-up says so ("Checking out a.c…", "Opening a.c for add…"); likewise revert, deleting a changelist, shelve, unshelve and deleting shelved files.
- `:w other.c` (the buffer keeps its name) offers to add `other.c`, the file actually written, not the buffer's file; check-out-on-write likewise acts only on writes to the buffer's own file.
- **Keys typed right after the prompt appears are treated as text.** For `checkout.prompt_grace` (default 300 ms) keys aren't menu choices; they're replayed into the buffer afterwards, so typing `cat` can't select `n` by accident.
- **No permission warnings.** A check-out only changes the file's permissions; Neovim's "file changed" warnings for that (W16, and W12 when there are unsaved edits) are silenced. A change of the file's modification time or size still warns. *(W12 case fixed 2026-10-04.)*
- **No waiting on `:w`.** Choosing a target makes the file writable immediately (what `p4 edit` does anyway) and restores it if the edit fails. Neovim's read-only check (E505) runs before any write autocmd, so the write can't wait for the server.
- **Sticky CL per session**: last chosen CL becomes the `<CR>` default; resets on submit/delete of that CL.
- Option: auto-checkout on write (uses sticky CL).
- New files inside client root: **prompt to `p4 add`** on write (same float).

## Client view ("p4v inside nvim")
- **Hybrid**: Magit-style foldable status buffer as the core; drilling into a CL/file opens a diffview-style tab (file panel + side-by-side diff).
- Opens in a **new tab** by default (configurable: float/split).
- Sections: Pending CLs (+shelved files), Unresolved/stale, Workspace reconcile (lazy — only queried when expanded; scope configurable), My recent submitted.
- "Recent submitted" shows the latest `client_view.submitted_limit` (20) of the user's changelists from any client; its last row (`<CR>`, or `gn` anywhere in the section) opens the full list in `:P4 changes` (all clients, paged as you scroll) rather than growing the section *(2026-10-10)*.
- Pending scope: current client, key toggles to all my clients.
- On-demand (not default sections): lookup CL by number, submitted CLs of another user.
- Actions: **direct single keys** + `?` floating help; **always-visible footer** with the most common keys for the item under cursor.
- **Changelist `.` menu** *(2026-10-04)*: a fixed order in groups separated by rules — Submit… | View changelist, Diff all files (`<C-d>` too), Edit description, Copy CL number, Copy Swarm URL, Send to quickfix, Get latest file revisions (only when some file is stale), Delete changelist (only when no files are opened in it) | Revert unchanged files, Revert files, Resolve (only with unresolved files), Move all files to another changelist | Shelve files, Unshelve files, Delete shelved files (`g<Del>`; `<Del>` stays "delete changelist") | Create new changelist, Sync entire workspace, Switch client. "Send to location list" (`gQ`) keeps its key but isn't in this menu. "Describe changelist" stays on `gd` (and in `?`) but is in no menu of the client view: `K` "View changelist" covers it there.
- Freshness: **always fresh** (loading skeleton until data arrives; no stale-while-revalidate).
- Refresh: after every plugin action (`PerforatedChanged`) and when the background poll's refresh sees the opened files change *(2026-10-03)*; no timer of its own; `gr` forces one. Stale files' paths and `●` markers use the stale colour, unresolved files' the unresolved colour, orange `#ff8700` (it wins over stale) *(2026-10-04)*. Changelist numbers keep `PerforatedChangelist` (→ `Identifier`); bold white/black was tried and reverted the same day.

## Diffs & gutter
- Gutter base: **#have** (stale shown via separate indicator).
- `:P4 diff` default: **side-by-side in a new tab**, native `:diffthis`, `q` closes.
  - Every diff split (single file or changelist tab) has a winbar header naming the file and the side: `#4 (have)`, `@=123 (shelved)`, `(workspace)`. *(added 2026-10-02)*
  - `q` closes the whole diff tab from any of its windows, including the user's own file. There the mapping only acts inside that tab, and `q` keeps its normal meaning everywhere else. `:q` in any diff window also closes the whole tab.
  - `Ctrl+1` / `Ctrl+2`: previous / next change in diff windows (Vim's `[c` / `]c` keep working), scoped to the diff tab like `q`; P4V-style keys, so not with `keys.p4v = false` *(2026-10-10)*. (`Ctrl+W` to close was considered and dropped.)
  - The workspace file is always on the **right**: shelf vs workspace shows the shelf on the left.
  - Shelf vs workspace (diff tab) lists, below "Identical", a **"Not in Shelf"** section: every opened file of the workspace, in any changelist, that the shelf doesn't hold (listed, not diffed). When every shelved file is identical there is no tab, and the pop-up names those files, one per line, indented under "Not in Shelf (N):" *(2026-10-10)*.
  - Diff windows have **no sign column** *(2026-10-07)*: the diff colours already mark every change; hunk signs and diagnostics would repeat them. The setting is window-local and dropped before the window closes, so the user's file keeps its signs elsewhere.
  - **Both sides stay in line** *(2026-10-07)*: in the multi-file tab each file opens at its first change; `:P4 diff` keeps the user's place in their file and the revision follows it. Scroll-bound windows only follow one that scrolls, so the plugin aligns them itself: when the diff opens, after the first redraw (diff folds can scroll a window), and when a revision arrives from p4 (it was empty until then).
  - In the multi-file diff tab, the panel's cursor stays on the file list (never the title or the "Identical" section); `j`/`k`/arrows wrap around at both ends *(2026-10-06)*.
- **Diff colours** *(2026-10-06)*: `diff.colors = 'colorscheme'` (default) or `'perforated'` (the plugin's own palette, onedark's light style; a table overrides single colours), and `diff.syntax = false` (default: no Vim syntax / treesitter / LSP colouring in the diff sides). Applied per window with highlight namespaces (`nvim_win_set_hl_ns`): the whole diff view (sides, file panel, headers) and nothing else, so other tabs keep the user's theme, the same file elsewhere keeps its colours, and a theme switch (by hand, auto-dark-mode) leaves a `'perforated'` diff light. Never global: no `'background'`, `:colorscheme`, `:syntax` or buffer treesitter changes. Names chosen with the author: `'colorscheme'` vs `'perforated'` ("whose colours"); `'system'` was rejected as it reads like "follow the OS". A function to give other diff tools the look stays in the author's own config (out of scope). The palette's window separators are crisp black lines on the light background (`separator`, matching the author's config) *(2026-10-06)*.
- Option to open diffs in the user's external tool from **$P4DIFF** (`:P4 diff!` or `diff.tool = 'external'`). The plugin launches it itself as `$P4DIFF <depot copy> <workspace file>`, with the user's environment, because `p4 diff` skips identical files and `p4 diff2` ignores P4DIFF.
- Shelved file default diff: **shelved vs its base rev**; menu offers vs workspace / vs head.
- Hunk ops: preview hunk (float), reset hunk to #have, current-line blame virtual text. Hunk navigation `]h`/`[h`.
- Sign diffs use `myers` + indent heuristic (configurable via `signs.algorithm`). Histogram is about 5x slower on large files, and linematch doubles the cost for no benefit in the gutter.

## History / annotate / time-lapse
- Filelog `<CR>` opens an **action menu**: diff vs previous rev, diff vs workspace file, view submitted CL, open revision read-only. Presentation configurable (float / picker / quickfix).
- Filelog: **diff any two revisions** *(2026-10-10)*: mark two (`m`, `u` clears) or select them (`V`), then `D` (older left); `gD` "Diff against revision…" picks the other one from the file's history (like `gD` on an opened file).
- Annotate: **scrollbound left split**, age-coloured; `<CR>` describe, `~` re-annotate before this line's change.
- Time-lapse: **time-machine buffer first**, P4V-style slider in a later milestone. Engine: one `annotate -a -c` + one `filelog`.

## CL lookup
- `:P4 describe N` → **Magit-style buffer**: header, file list, `<Tab>` lazily expands inline diff, `D` opens all in diff tab. Works for pending/shelved/submitted.
- **Unshelve anyone's shelf** from the describe buffer and the `K` pop-up (`S`) *(2026-10-10)*: another user's or client's shelf goes into a changelist you pick; your own (in this workspace) into itself. On a shelved file `S` takes that file, on the header / Shelved line the whole shelf.
- Submitted lists: **last 50, scoped to client view, paginated** (`@<oldest`).

## Operations in scope
edit, add, revert (+ revert unchanged), reopen (move to CL), change specs in `acwrite` buffers, submit, sync, delete, move/rename, shelve/unshelve (file + CL level) — re-shelving a whole CL whose shelf holds files no longer opened in it offers "replace all" (`p4 shelve -r`) besides replace (`-f`, keeps them) and cancel *(2026-10-10)*, resolve, **integrate (cherry-pick a submitted CL into the client)**.

## Editing CL descriptions
One action, **`C` "edit description"**, available anywhere a CL appears:
- the client view (pending, submitted and shelved rows)
- the `K` "view changelist" popup: `C` turns the popup itself into the quick editor (same place), and a save or cancel returns to the popup
- the describe buffer
- history, annotate and time-lapse entries (the CL of that revision)
- picker results
- the quickfix window
- `.` menus
- normal buffers via `<leader>pC` (the CL the current file is opened in; with no CL, the sticky CL)

It is also available as the command `:P4 change [N]` (no N means the current file's CL).

- **Quick mode (default): a description-only float.** A centered float containing only the description text, with the CL, status, user and file count in the title. `:w` or `<C-s>` saves and `q` or `<Esc>` cancels, with a confirmation if there are unsaved edits.
  - The plugin fetches the full spec (`change -o [-u] N`), replaces only the `Description:` field, and sends it back (`change -i [-u]`).
  - Every other field (Files, Jobs, Type and so on) goes back byte-for-byte, so the file list can never be edited by accident.
  - The first line is highlighted as the "summary" line, and a soft ruler shows where Swarm and P4V truncate it.
- **Full-spec mode:** `gS` inside the float, or `:P4 change! N`, switches to the full `acwrite` spec buffer (jobs, type, files) with the same `:w` flow.
- **Pending CLs:** `change -o N` / `change -i`.
- **Submitted CLs:** `change -u -o N` / `change -u -i`. `-u` lets the owner update the description of their own submitted CL.
  - If the server refuses (not the owner, or policy), the error is shown inline.
  - Admins can set `change.allow_force = true` to retry with `-f`, after an explicit confirmation.
- **Default CL:** its description **cannot** be edited. `C` isn't offered on the default CL, and its files can only be moved (`gm`) to an existing CL or a new one.
- **`gm` on a changelist** (any pending CL with opened files, default included) moves all its opened files: the picker lists every other pending CL, the default one and "+ new changelist…".
- **After a save:** the CL memo cache is updated and every open view showing that CL (client view, describe, annotate, blame line) refreshes its text. The check-out float's "new CL" input uses the same quick editor, starting as a single line that expands on `<C-CR>` for multi-line descriptions.
- **Optional description template** (`change.template`), e.g. a string or function that pre-fills new CLs (`[JIRA-]`, reviewers). New CLs only.

## Resolve
- Behaves like `p4 resolve`: run `-am` first; for remaining conflicts launch the external merge tool ($P4MERGE / configured) asynchronously with base/theirs/yours; on success `resolve -ay` with the merged result. **No merge intelligence in the plugin.**
- Feedback *(2026-10-10)*: a **centred busy pop-up** while p4 resolves (closed while the merge tool runs, so it isn't covered), then the **result in a centred pop-up that waits for a key**: merged automatically / with the merge tool / left unresolved (each file with its reason; `c` opens quickfix). Not modal: the editor stays usable ("never block the editor"); still a job in `:P4 jobs`, without its start/result notices.

## Stale / unresolved checks
- Batched check **when a workspace activates** (idle), plus **manual `:P4 status` / `:P4 stale`**. Per-buffer fstat on open shows stale state for free.
- **Background polling:** a cheap probe (`changes -m1 -s submitted <opened files>`) every **30 s** (was 5 min until 2026-10-03; it's one indexed query) while Neovim has focus and files are opened (0 disables). It also runs on `FocusGained` (throttled to one per 2 s; was 30 s until *2026-10-10*, which missed an unshelve from another terminal when you came back within 30 s of your last return, since the timer is paused while unfocused). Polling starts with the first Perforce file buffer *or* the client view (*2026-10-10*: the view alone, `:P4` in a fresh Neovim, never started it), on entering a p4 buffer (throttled) and **always before submit**. The full fstat runs only when the probe sees a newer CL, or when `p4 opened` (also part of the probe, *2026-10-03*) differs from the last refresh's opened files: files opened, reverted, moved or unshelved from another terminal or P4V. A third probe query, `changes -s pending -l -c <client>`, catches changelists created, deleted, described or shelved elsewhere (announced as `PerforatedChanged`, which refreshes a visible client view).
- **Toast:** when an opened file *newly* becomes stale, a non-focusable popup at the bottom centre (stackable; *background* placement, see Feedback) lists `file #have→#head · CL · user` with `:P4 sync` / `:P4 stale` hints. It can be routed to `vim.notify`.
  - **Activity-gated dismissal:** the 3 s timer (`toast.timeout`) starts only at the user's first keypress or cursor move after the toast appears. Toasts raised while Neovim is unfocused are queued and shown on `FocusGained`.
  - **Polling only while focused** means a background tmux pane or tab doesn't poll; it catches up on return. Health checks that focus events work (tmux `focus-events on`).
  - **Nothing is lost if a toast is missed.** The persistent stale sign, the statusline markers and the `:P4 stale` quickfix list stay until you sync. `:P4 messages` (`<leader>pm`; was `:P4 notifications`) replays recent messages, and submit always re-checks and warns.
  - **No OS or desktop notifications.**
- **Statusline markers** stay until you sync or resolve, with configurable glyphs:
  - **Per file:** `#8 ↓#9` (`vim.b.perforated_status`, `vim.b.perforated_status_dict.stale`), within the file part: client, action@CL, a modified marker, the have revision, then stale / unresolved when they apply (`statusline.format`, a template of tokens; line counts are the optional `{diff}`).
  - **Per workspace:** `↓2` (stale opened files), `!1` (unresolved), `⊘` offline and `⊘login` (login needed) in `vim.g.perforated_status` (not `vim.g.perforated`, which holds the config), shown on every buffer of that workspace.
  - Both are available through the lualine component and `require('perforated').statusline()`.

## Icons
- File-type icons via mini.icons or nvim-web-devicons (auto-detected, cached per extension) in all views, quickfix text, pickers and toasts.
- Status glyphs (edit/add/delete/move/integrate/shelved/stale/unresolved/opened-by-other…) use Nerd Font glyphs by default when an icon provider is present, otherwise ASCII. All glyphs are overridable.

## Auth / offline
- Auth error → pause queue, prompt once (inputsecret → `p4 login` stdin), resume.
- Server unreachable → **offline mode** (cached signs keep working, clear errors, retry with backoff, statusline indicator).
- A call that merely **times out** isn't proof of an outage *(2026-10-03)*: the plugin probes (`info -s`) first and goes offline only if the probe fails. Heavy, legitimately slow commands (sync, submit, resolve, reconcile) run as jobs without the call timeout.

## Commands & keymaps
- `:P4 <sub>` with completion **plus** flat aliases (`:P4edit`, `:P4diff`, …) generated from the same table. A bang goes on the subcommand: `:P4 revert!`, `:P4 diff!` (`:P4! revert` also works).
- Depot revisions open as `perforated:////depot/path#rev` buffers. In `:edit`, `#` must be escaped (`\#`) because Vim expands it to the alternate file.
- No global keymaps by default; `<Plug>` mappings + **opt-in preset** (`keymaps = 'default'`). Buffer-local maps in plugin buffers always on.

### Plugin-buffer keys (client view, describe, history, annotate, time-lapse)
- Tree layout *(2026-10-04)*: 4 columns per level, `▶`/`▼` fold triangles; a row without a triangle starts where one would, so "Shelved" lines up with the files above it (their `●` column).
- Folding: `l` / `<Tab>` / `<CR>` expand, `h` collapse (on a child: jump to parent + collapse). `<CR>` on a leaf → action menu.
- **Context action menu** everywhere: `.` / `<RightMouse>` (not `<Space>`: commonly the leader key) → float listing only actions valid for the item under cursor, each with its hotkey. Normal code buffers: `<leader>p<Space>`. Items can also be clicked (a click outside cancels) *(2026-10-04)*. Right-click acts on the clicked line, not the cursor's; right-clicking another line while a menu is open closes it and opens that line's *(2026-10-05)*. A highlighted item follows `j`/`k`/arrows and the mouse pointer (`mousemoveevent` is on only while a menu is open, and a 40 ms timer, also only then, follows the pointer: `getcharstr()` never returns `<MouseMove>`); `<CR>` runs it, starting on the menu's `<CR>` default if it has one *(2026-10-05)*.
- Navigation: `]]`/`[[` sections, `gr` refresh, `q` close, `?` help, `m`/`u` mark/unmark (or select rows with `V`: multi-item actions take the selection, a changelist selected with its files counting once *(2026-10-10)*), `/` filter.
- Vim-style actions: `d` diff, `D` diff all in CL, `e` edit, `a` add, `x` revert, `X` revert unchanged, `gm` move to CL, `R` resolve, `s` shelve, `S` unshelve, `<Del>` delete shelved (on a shelf; on a CL: delete the CL), `c` new CL, `C` edit CL description (quick float; `gS` full spec), `P` submit, `y` yank, `gL` history, `b` annotate, `o` open, `t` time-lapse, `A` toggle pending scope, `W` switch client, `gy` sync, `g/` go-to/lookup (and `C-g`; in every Perforce window, diff views and the `K` pop-up included *(2026-10-10)*), `g1/g2/g0/g9` jump sections.
- **Opened-file `.` menu** *(2026-10-04)*: Open file, Get latest revision (only when stale), Get revision… (`g@`: pick from the file's history, then `sync file#N` with the usual confirmation) | Revert if unchanged, Revert, Move to another changelist, Shelve | Diff against have revision, Diff against revision… (`gD`: same picker, workspace vs `#N`) | File history, Annotate, Time-lapse view | Create new changelist, Sync entire workspace, Switch client. Send to quickfix / location list keep their keys (`Q`/`gQ`) but aren't in it.
- **Action menus name the Ctrl shortcut** *(2026-10-04)*: in an aligned right-hand column, no parentheses (`Diff all files      Ctrl+D`, `Revert files      Ctrl+R`) — from the P4V layer, so none with `keys.p4v = false`.
- **P4V layer, on by default** (`keys.p4v = false` disables): `C-d` diff, `C-e` edit, `C-r` revert, `C-s` submit, `C-g` go-to/lookup, `C-t` history, `C-S-t` time-lapse*, `C-S-g` sync*, `C-S-c` copy depot path*, `C-n` new CL, `C-f` filter, `C-1/2/0/9` section jumps*, `C-w` close, `F5` refresh (every view, like `gr`). (*needs CSI-u terminal; vim-style fallback always exists.) **No lock/unlock.**
- **Never shadow Vim's own motions** in plugin buffers: no `z` (folds, scrolling), `M`, `H`, `L` (cursor to screen middle / top / bottom).
- Always-visible context-sensitive footer with the most common keys.
- Normal-buffer preset (opt-in) prefix: **`<leader>p`**; hunks `]h`/`[h`.

## Feedback
- Minimal notifications; `vim.b`/`vim.g` statusline vars + lualine component; `:P4 log` of every p4 command with timings.
- **Everything follows `toast.backend`** *(2026-10-02)*: with pop-ups (the default) messages, confirmations (a centred single-key menu) and text prompts (a one-line input float) never use the command line. Long jobs show a pop-up when they start and when they finish, and live progress only in `:P4 jobs`. Slow-to-open views show a busy pop-up ("Opening diff view…") until they're ready. With `backend = 'notify'`: `vim.notify`, `confirm()`, `vim.ui.input` and 0.12 native progress messages. The `p4 login` password prompt always stays on the command line.
- **Pop-up placement** *(2026-10-02)*: all centred horizontally; vertically by kind. **Centre:** blocking (busy "Opening diff view…", confirmations, text input, submit confirmation, "resolve now?" after sync). **Top** (two lines down, stacking downward): results of the action just taken, including a long job's *start* and its *failure*. **Bottom** (above the statusline, stacking upward): background news (newly stale files, diff base load failure, a long job's *successful* finish). Context menus stay where the context is: the check-out prompt and the `.` menu open at the cursor.

## Quickfix / location list
Principle: **any list of files, revisions or lines can go to quickfix.** Workspace-wide lists go to the **quickfix list**. Lists about one file (its hunks, its history, lines from one CL) go to the **location list** of that window. Each entry can be switched to the other list.

Mechanics (one shared `ui/qf.lua`):
- **Build with a single `setqflist` call.** Each list gets a `title` (e.g. `P4 opened · client gautam_ws`) and a `context` (`{perforated=true, kind, args}`), so `gr` inside the qf window re-runs the query and replaces the list in place, and `:colder`/`:cnewer` history stays usable.
- **Streaming or slow sources** (sync, reconcile) create an empty list, then fill it with `setqflist({}, 'a', {id=…, items=…})` as results arrive. Focus is never taken unless the user opens it.
- **Depot-only entries** (not in the workspace) use `perforated://` URIs as `filename`, so `:cnext` opens the revision read-only through `BufReadCmd`.
- **Every entry carries `user_data`** `{depotFile, rev, change, action, kind}`. The qf window then gets buffer-local keys from the same action registry: `d` diff, `x` revert, `gm` move, `D` describe, `.` menu. These are active only for perforated lists, detected via `context`. Entries to resolve end with a dimmed "· R resolves"; lists of files to resolve drop entries once the file is resolved anywhere (re-checked after every `PerforatedChanged`), and the quickfix window closes when the shown list is left empty *(2026-10-03)*.
- A **`quickfixtextfunc`** aligns columns (`action  #have/#head  CL  path  desc`) without making the stored entries bigger.
- `valid=0` entries serve as group headers, e.g. one per CL.
- A **generic "send to quickfix" action** in the registry: `Q` sends the item under the cursor, the marked items, or the whole list to quickfix; `gQ` sends to the location list. It works in the client view, describe, history, annotate, the diff tab file panel, and picker results. Every picker adapter maps its native send-to-qf key to our entry format, so `user_data` survives.
- **Opening policy:** commands populate quickfix but only open the qf window when `qf.open = true` (the default) and the list is non-empty. Otherwise a notification gives the count. `:P4 … !` suppresses opening.

Where it's used:
| Source | List | Entries |
|---|---|---|
| `:P4 opened [-c CL]` / client view `Q` on a CL | qf | opened files, text = `action CL desc`, grouped by CL |
| Startup stale/unresolved check, `:P4 status` | qf | stale / unresolved files with reason |
| **All hunks in opened files** (`:P4 hunks`, preset `<leader>pq`) | qf | one entry per hunk (lnum, `+a -d` text); base text from one `p4 -x - print` batch, diffed in-process |
| Hunks of current file (`:P4 hunks %`) | loclist | one per hunk |
| Resolve: files left unresolved after `-am` / merge tool cancelled | qf | unresolved files; `R` on entry resumes resolve |
| Submit failures (out-of-date, unresolved, locked) | qf | offending files, text = p4 reason; linked actions sync/resolve |
| Sync results needing attention (can't clobber, must resolve, deleted-while-open, other errors) | qf | affected files — plus a centred pop-up listing anything that didn't go as asked (files not updated, errors) *(2026-10-10)* |
| Integrate preview (`-n`) and post-integrate "must resolve" | qf | files + planned action |
| Workspace reconcile / `p4 status` | qf | files to add/edit/delete (streamed) |
| Describe CL (`Q` in describe buffer) | qf | CL files; workspace path when mapped, else `perforated://…@CL` |
| Shelved files of a CL | qf | `perforated://…@=CL` entries |
| File history (existing presenter option) | loclist | one entry per rev (`perforated://f#rev`), text = `#rev CL user date desc` |
| Annotate: "lines from this CL" (`Q` on an annotate line) | loclist | every line in the file last changed by that CL |
| Time-lapse: lines changed in current revision | loclist | added/changed lines at rev N |
| p4 command errors that name files (e.g. revert on unopened files, batch edit failures) | qf | file + error text (instead of a wall of notifications) |

## Debug log (added after M1)
- **Off by default, free when off.**
- **Turned on** by config `debug.enabled`, env `PERFORATED_DEBUG=1|<level>` (no config change needed on a live machine), or `:P4 debug on [level]`.
- **One file,** `stdpath('log')/perforated.log`, shared by sessions: every line has a timestamp, level, pid and scope. Buffered writes every 250 ms (errors flushed immediately); rotates at `debug.max_kb`.
- **Logged:**
  - gate decisions, including why a file isn't a workspace file (gate logging only loads when debugging is requested, so dormancy is preserved)
  - every p4 call: argv, cwd, env mode, stdin summary, timing, result, errors, stderr
  - workspace, connection and queue state changes
  - buffer transitions and base loads
  - check-out decisions and prompt choices
  - poll probes and refreshes
  - toasts
- **Never logged:** `p4 login`/`passwd` stdin, or `P4PASSWD` values.
- **Commands:** `:P4 debug snapshot` dumps workspaces, buffers, queue and recent p4 calls for bug reports; also `:P4 debug open|clear|off`.

## Pickers
- Telescope is the author's primary, but a **picker-agnostic adapter** (telescope, fzf-lua, snacks, mini.pick).
- **Without a picker plugin, the plugin's own list** *(2026-10-06)* instead of `vim.ui.select` (a numbered command-line list, against "pop-ups never use the command line"): a filter line (fuzzy, `matchfuzzy`, debounced), the list and a preview, as floats; `j`/`k` wrap, `<CR>`/double-click choose, `m` marks (multi), leaving cancels. Installed pickers still win by default (`picker = 'auto'`): the user chose them. `picker = 'perforated'` forces the plugin's list, `'select'` forces `vim.ui.select`; with `toast.backend = 'notify'` the fallback is `vim.ui.select`. A picker plugin that fails falls back to the same choice.
- Pickers open in **normal mode** (`picker_mode = 'normal'`, the default; `'insert'` starts in the prompt) *(2026-10-02)*: telescope `initial_mode`, snacks `focus = 'list'`. fzf-lua and mini.pick have no normal mode.

## Extras (roadmap)
- Swarm links: copy the review URL (`gX`). Opening it in a browser was dropped *(2026-10-04)*.
- ~~p4v escape hatches (`p4vc timelapse`, `revgraph`)~~ — removed *(2026-10-04)*, with every p4vc integration (`:P4 p4vc`, `gR`, the `p4vc` option).

## Testing
- mini.test with child nvim; fake `p4` replaying recorded `-Mj` fixtures; real throwaway p4d (rsh, no daemon) for integration; nvim 0.11/0.12/nightly matrix; perf benchmarks with budgets in CI.
