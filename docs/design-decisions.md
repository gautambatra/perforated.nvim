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
- **Environment for p4 calls:** only the *internal* background calls neutralize `P4EDITOR`/`P4DIFF`/`P4MERGE` (set to `false`) and unset `P4PAGER`, so a stray launch can't hang them. Connection variables are never touched. Launches the user asks for use the untouched environment. The user's **`$P4DIFF` always works**: the external-diff action runs p4's own `p4 diff` / `p4 diff2`, which invokes `$P4DIFF` exactly as the command line would; GUI tools run detached, terminal tools in a `:terminal` tab. `$P4MERGE` is launched the same way for resolve.
- Neovim floor: **0.11+** (author on 0.12.5).
- Platforms: Linux, macOS, WSL (no native Windows).
- Dependencies: **zero hard deps** (pure Lua + p4 binary); pickers/statuslines/notifiers are optional integrations.

## Check-out / add
- Trigger: **first modification** of an unopened depot file (keystroke not blocked).
- Prompt: **small floating menu** near cursor: `<CR>` default/sticky CL, `c` existing CL (picker), `n` new CL (inline description), `s` skip for buffer, `S` never this session.
- **Sticky CL per session**: last chosen CL becomes the `<CR>` default; resets on submit/delete of that CL.
- Option: auto-checkout on write (uses sticky CL).
- New files inside client root: **prompt to `p4 add`** on write (same float).

## Client view ("p4v inside nvim")
- **Hybrid**: Magit-style foldable status buffer as the core; drilling into a CL/file opens a diffview-style tab (file panel + side-by-side diff).
- Opens in a **new tab** by default (configurable: float/split).
- Sections: Pending CLs (+shelved files), Unresolved/stale, My recent submitted, Workspace reconcile (lazy — only queried when expanded).
- Pending scope: current client, key toggles to all my clients.
- On-demand (not default sections): lookup CL by number, submitted CLs of another user.
- Actions: **direct single keys** + `?` floating help; **always-visible footer** with the most common keys for the item under cursor.
- Freshness: **always fresh** (loading skeleton until data arrives; no stale-while-revalidate).

## Diffs & gutter
- Gutter base: **#have** (stale shown via separate indicator).
- `:P4 diff` default: **side-by-side in a new tab**, native `:diffthis`, `q` closes.
- Option to open diffs in the user's external tool from **$P4DIFF**.
- Shelved file default diff: **shelved vs its base rev**; menu offers vs workspace / vs head.
- Hunk ops: preview hunk (float), reset hunk to #have, current-line blame virtual text. Hunk navigation `]h`/`[h`.

## History / annotate / time-lapse
- Filelog `<CR>` opens an **action menu**: diff vs previous rev, diff vs workspace file, view submitted CL, open revision read-only. Presentation configurable (float / picker / quickfix).
- Annotate: **scrollbound left split**, age-coloured; `<CR>` describe, `~` re-annotate before this line's change.
- Time-lapse: **time-machine buffer first**, P4V-style slider in a later milestone. Engine: one `annotate -a -c` + one `filelog`.

## CL lookup
- `:P4 describe N` → **Magit-style buffer**: header, file list, `<Tab>` lazily expands inline diff, `D` opens all in diff tab. Works for pending/shelved/submitted.
- Submitted lists: **last 50, scoped to client view, paginated** (`@<oldest`).

## Operations in scope
edit, add, revert (+ revert unchanged), reopen (move to CL), change specs in `acwrite` buffers, submit, sync, delete, move/rename, shelve/unshelve (file + CL level), resolve, **integrate (cherry-pick a submitted CL into the client)**.

## Editing CL descriptions
One action, **`C` "edit description"**, available anywhere a CL appears:
- the client view (pending, submitted and shelved rows)
- the describe buffer
- history, annotate and time-lapse entries (the CL of that revision)
- picker results
- the quickfix window
- `<Space>` menus
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
- **Default CL:** its description **cannot** be edited. `C` isn't offered on the default CL, and its files can only be moved (`M`) to an existing CL or a new one.
- **After a save:** the CL memo cache is updated and every open view showing that CL (client view, describe, annotate, blame line) refreshes its text. The check-out float's "new CL" input uses the same quick editor, starting as a single line that expands on `<C-CR>` for multi-line descriptions.
- **Optional description template** (`change.template`), e.g. a string or function that pre-fills new CLs (`[JIRA-]`, reviewers). New CLs only.

## Resolve
- Behaves like `p4 resolve`: run `-am` first; for remaining conflicts launch the external merge tool ($P4MERGE / configured) asynchronously with base/theirs/yours; on success `resolve -ay` with the merged result. **No merge intelligence in the plugin.**

## Stale / unresolved checks
- Batched check **when a workspace activates** (idle), plus **manual `:P4 status` / `:P4 stale`**. Per-buffer fstat on open shows stale state for free.
- **Background polling:** a cheap probe (`changes -m1 -s submitted <opened files>`) every **5 min** while Neovim has focus and files are opened (0 disables). It also runs on `FocusGained` (throttled), on entering a p4 buffer (throttled) and **always before submit**. The full fstat runs only when the probe sees a newer CL.
- **Toast:** when an opened file *newly* becomes stale, a non-focusable bottom-right popup (stackable) lists `file #have→#head · CL · user` with `:P4 sync` / `:P4 stale` hints. It can be routed to `vim.notify`.
  - **Activity-gated dismissal:** the 8 s timer starts only at the user's first keypress or cursor move after the toast appears. Toasts raised while Neovim is unfocused are queued and shown on `FocusGained`.
  - **Polling only while focused** means a background tmux pane or tab doesn't poll; it catches up on return. Health checks that focus events work (tmux `focus-events on`).
  - **Nothing is lost if a toast is missed.** The persistent stale sign, the statusline markers and the `:P4 stale` quickfix list stay until you sync. `:P4 notifications` replays recent toasts, and submit always re-checks and warns.
  - **No OS or desktop notifications.**
- **Statusline markers** stay until you sync or resolve, with configurable glyphs:
  - **Per file:** `↓#8→#9` (`vim.b.perforated_status`, `status_dict.stale`).
  - **Per workspace:** `↓2` (stale opened files) and `!1` (unresolved) in `vim.g.perforated`, shown on every buffer of that workspace.
  - Both are available through the lualine component and `require('perforated').statusline()`.

## Icons
- File-type icons via mini.icons or nvim-web-devicons (auto-detected, cached per extension) in all views, quickfix text, pickers and toasts.
- Status glyphs (edit/add/delete/move/integrate/shelved/stale/unresolved/opened-by-other…) use Nerd Font glyphs by default when an icon provider is present, otherwise ASCII. All glyphs are overridable.

## Auth / offline
- Auth error → pause queue, prompt once (inputsecret → `p4 login` stdin), resume.
- Server unreachable → **offline mode** (cached signs keep working, clear errors, retry with backoff, statusline indicator).

## Commands & keymaps
- `:P4 <sub>` with completion **plus** flat aliases (`:P4edit`, `:P4diff`, …) generated from the same table.
- No global keymaps by default; `<Plug>` mappings + **opt-in preset** (`keymaps = 'default'`). Buffer-local maps in plugin buffers always on.

### Plugin-buffer keys (client view, describe, history, annotate, time-lapse)
- Folding: `l` / `<Tab>` / `<CR>` expand, `h` collapse (on a child: jump to parent + collapse). `<CR>` on a leaf → action menu.
- **Context action menu** everywhere: `<Space>` / `<RightMouse>` → float listing only actions valid for the item under cursor, each with its hotkey. Normal code buffers: `<leader>p<Space>`.
- Navigation: `]]`/`[[` sections, `gr` refresh, `q` close, `?` help, `m`/`u` mark/unmark, `/` filter.
- Vim-style actions: `d` diff, `D` diff all in CL, `e` edit, `a` add, `x` revert, `X` revert unchanged, `M` move to CL, `R` resolve, `s` shelve, `S` unshelve, `z` delete shelved, `c` new CL, `C` edit CL description (quick float; `gS` full spec), `P` submit, `y` yank, `L` history, `b` annotate, `o` open, `t` time-lapse, `A` toggle pending scope, `gy` sync, `gR` revision graph (p4vc), `g/` go-to/lookup, `g1/g2/g0/g9` jump sections.
- **P4V layer, on by default** (`keys.p4v = false` disables): `C-d` diff, `C-e` edit, `C-r` revert, `C-s` submit, `C-g` go-to/lookup, `C-t` history, `C-S-t` time-lapse*, `C-S-g` sync*, `C-S-c` copy depot path*, `C-S-r` revision graph*, `C-n` new CL, `C-f` filter, `C-1/2/0/9` section jumps*, `C-w` close. (*needs CSI-u terminal; vim-style fallback always exists.) **No lock/unlock.**
- Always-visible context-sensitive footer with the most common keys.
- Normal-buffer preset (opt-in) prefix: **`<leader>p`**; hunks `]h`/`[h`.

## Feedback
- Minimal notifications; progress for long ops (0.12 native progress, forwarded to fidget/snacks); `vim.b`/`vim.g` statusline vars + lualine component; `:P4 log` of every p4 command with timings.

## Quickfix / location list
Principle: **any list of files, revisions or lines can go to quickfix.** Workspace-wide lists go to the **quickfix list**. Lists about one file (its hunks, its history, lines from one CL) go to the **location list** of that window. Each entry can be switched to the other list.

Mechanics (one shared `ui/qf.lua`):
- **Build with a single `setqflist` call.** Each list gets a `title` (e.g. `P4 opened · client gautam_ws`) and a `context` (`{perforated=true, kind, args}`), so `gr` inside the qf window re-runs the query and replaces the list in place, and `:colder`/`:cnewer` history stays usable.
- **Streaming or slow sources** (sync, reconcile) create an empty list, then fill it with `setqflist({}, 'a', {id=…, items=…})` as results arrive. Focus is never taken unless the user opens it.
- **Depot-only entries** (not in the workspace) use `perforated://` URIs as `filename`, so `:cnext` opens the revision read-only through `BufReadCmd`.
- **Every entry carries `user_data`** `{depotFile, rev, change, action, kind}`. The qf window then gets buffer-local keys from the same action registry: `d` diff, `x` revert, `M` move, `D` describe, `<Space>` menu. These are active only for perforated lists, detected via `context`.
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
| Sync results needing attention (can't clobber, must resolve, deleted-while-open) | qf | affected files |
| Integrate preview (`-n`) and post-integrate "must resolve" | qf | files + planned action |
| Workspace reconcile / `p4 status` | qf | files to add/edit/delete (streamed) |
| Describe CL (`Q` in describe buffer) | qf | CL files; workspace path when mapped, else `perforated://…@CL` |
| Shelved files of a CL | qf | `perforated://…@=CL` entries |
| File history (existing presenter option) | loclist | one entry per rev (`perforated://f#rev`), text = `#rev CL user date desc` |
| Annotate: "lines from this CL" (`Q` on an annotate line) | loclist | every line in the file last changed by that CL |
| Time-lapse: lines changed in current revision | loclist | added/changed lines at rev N |
| p4 command errors that name files (e.g. revert on unopened files, batch edit failures) | qf | file + error text (instead of a wall of notifications) |

## Pickers
- Telescope is the author's primary, but a **picker-agnostic adapter** (telescope, fzf-lua, snacks, mini.pick, fallback `vim.ui.select`).

## Extras (roadmap)
- Swarm links (open/copy review URL).
- p4v escape hatches (`p4vc timelapse`, `revgraph`).

## Testing
- mini.test with child nvim; fake `p4` replaying recorded `-Mj` fixtures; real throwaway p4d (rsh, no daemon) for integration; nvim 0.11/0.12/nightly matrix; perf benchmarks with budgets in CI.
