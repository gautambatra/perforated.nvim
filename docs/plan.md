# perforated.nvim — implementation plan

Companion docs: [`design-decisions.md`](design-decisions.md) (the behaviour we agreed on) and [`research.md`](research.md) (prior art and p4 CLI facts). This file covers **how** to build it and **in what order**.

---

## 1. Guiding principles

1. **Never block the UI thread on p4.** Every p4 call goes through an async runner. The only allowed wait is a bounded `vim.wait` in `BufWritePre`, used when a `p4 edit` for that buffer is already in flight.
2. **No N+1 queries.** Batch with `-x -` and multi-arg commands. A view is built from a small fixed number of p4 calls, no matter how many CLs or files it shows.
3. **Diff in-process.** Signs, hunks, time-lapse and shelf diffs all use `vim.text.diff` on content from `p4 print`. We never run `p4 diff` just to draw signs.
4. **Revision content is immutable, so cache it.** `depotFile#rev` never changes. It goes in a byte-bounded in-memory LRU. There is no disk cache: all state is per session.
5. **Pay for what you use; dormant outside Perforce.** `plugin/` only registers commands, `<Plug>` maps and one cheap autocmd. Each feature module is `require`d on first use. Outside a workspace there are no modules loaded, no timers, no processes and no caches (§3.3).
8. **Everything is per session and per workspace.** No state is shared between Neovim processes except p4's own ticket file. Inside a session, all state hangs off a `Workspace` object, so buffers from different workspaces can coexist.
6. **Zero hard dependencies.** Pure Lua plus the `p4` binary. Pickers, statuslines and notifiers are optional adapters.
7. **Structured output.** `p4 -Mj -ztag` (JSON lines) is the primary format, with a `-ztag` text parser as fallback for old servers.

## 2. Performance and memory budgets (enforced by CI benchmarks)

| Metric | Budget |
|---|---|
| Added startup time (`--startuptime`, plugin/ only) | < 0.5 ms |
| Resident Lua memory when idle, no p4 buffers | ≈ 0 (dormant: only plugin/ is loaded) |
| Lua memory of an active workspace (code + state) | ≤ 250 KB |
| Lua memory per attached buffer | ≤ 2 KB (plus base text for opened files) |
| `BufReadPost` handler cost on the UI thread | < 0.3 ms (the work is queued) |
| Sign refresh after an edit, 10k-line file | ≤ 5 ms UI time (debounced 100 ms; revised from 3 ms: reading 10k lines from the buffer alone costs 2–3.5 ms). Files > 2k lines diff on `uv.new_work`; ≤ 2k lines take about 1 ms |
| Sign refresh, 100k-line file | never blocks; worker-thread diff |
| Check-out float appears after first keystroke | < 16 ms (a single frame); the CL list fills in asynchronously |
| Client view first paint (skeleton) | < 16 ms |
| Client view populated (LAN, ~20 CLs / 200 opened files) | < 1 wall-clock p4 round trip plus 10 ms render |
| Render 5k-row status buffer | < 15 ms (one `nvim_buf_set_lines` plus extmarks in bulk) |
| Time-lapse step (after initial load) | < 5 ms |
| Revision-content cache | default 32 MB cap, byte-accounted LRU |
| Per attached buffer overhead | base text plus hunks only; freed on `BufUnload` |

"Always fresh" (a design decision) means views re-query every time they open. The perceived-speed budget therefore depends on painting the skeleton instantly and keeping the query count to one parallel round.

## 3. Architecture

```
plugin/perforated.lua          -- commands, <Plug> maps, 1 BufReadPost/BufNewFile autocmd (lazy)
lua/perforated/
  init.lua                     -- public API (lazy proxies), setup() = config merge only
  config.lua                   -- defaults, vim.g.perforated merge, validation (health reports unknown keys)
  core/
    runner.lua                 -- vim.system wrapper: argv, env sanitize, timeout+kill, -Mj stream parse
    queue.lua                  -- concurrency cap, in-flight dedupe, priorities, pause/resume (auth)
    async.lua                  -- tiny coroutine helpers: run(fn), await(cb-style), all{}, debounce, throttle_by_key
    parse.lua                  -- JSON-line + ztag parsers, indexed-field unfolder (rev0,rev1… → array), severity mapping
    activation.lua             -- dormant gate: pure-Lua, per-dir cached P4CONFIG lookup; env-only fallback
    workspace.lua              -- Workspace objects (anchor, env, info, conn, queue, caches, sticky CL); buffer→workspace map; connection-only contexts
    env.lua                    -- `p4 set` parsing, P4CONFIG/P4ENVIRO resolution, user tool lookup (P4DIFF/P4MERGE)
    conn.lua                   -- per-workspace connection state machine: unknown/online/auth_needed/offline (+backoff)
    cache.lua                  -- per-workspace fstat cache, revision-content LRU (memory only), CL memo (user/date/desc)
    poll.lua                   -- stale detection: cheap `changes -m1` probe → fstat on change; focus/enter/submit triggers
    log.lua                    -- ring buffer of commands + timings, :P4 log buffer
    events.lua                 -- internal pub/sub (User autocmds PerforatedOpened, PerforatedRefresh…)
  p4/                          -- thin typed wrappers, one per p4 command family
    fstat.lua opened.lua changes.lua describe.lua filelog.lua annotate.lua print.lua
    edit.lua add.lua revert.lua reopen.lua change.lua submit.lua sync.lua delete.lua move.lua
    shelve.lua unshelve.lua resolve.lua integrate.lua login.lua
  buffer/
    attach.lua                 -- per-buffer state, lifecycle, on_lines, BufUnload cleanup
    checkout.lua               -- FileChangedRO/first-modification flow, BufWritePre guard, add-on-write
    signs.lua                  -- hunks → extmarks, ]h [h, preview, reset
    blame_line.lua             -- current-line virtual text
    status.lua                 -- vim.b.perforated_status(_dict), vim.g.perforated
  diff/
    engine.lua                 -- vim.text.diff/vim.diff shim, hunk model, worker-thread path
    view.lua                   -- side-by-side tab (native diff mode), $P4DIFF external launch
    difftab.lua                -- diffview-style tab: file panel + diff pair (multi-file CL diffs)
  uri.lua                      -- perforated:// BufReadCmd: //depot/f#rev, @CL, @=shelvedCL, #have/#head
  ui/
    tree.lua                   -- component tree renderer (row→item map, folds, bulk render, diff-patching)
    float.lua                  -- menus (check-out prompt, action menu), help, previews
    footer.lua                 -- context-sensitive key footer (winbar/statusline of the window)
    keys.lua                   -- keymap tables (vim-style + p4v layer), action registry → menus/help/footer
    skeleton.lua               -- loading placeholders
    toast.lua                  -- non-focusable corner popup (stale notices), auto-dismiss, stackable; optional vim.notify routing
    icons.lua                  -- filetype icons (mini.icons / nvim-web-devicons, cached per extension) + status glyphs (nerd / ascii)
    qf.lua                     -- quickfix/loclist sink: entry schema (user_data), titles/context, streaming append, qftextfunc, qf-window action keys
  views/
    client.lua                 -- the status buffer (sections)
    describe.lua               -- CL buffer
    history.lua                -- filelog (float / picker / quickfix)
    annotate.lua               -- scrollbound split
    timelapse.lua              -- time-machine buffer (later: slider)
    spec.lua                   -- acwrite buffers for change specs + description-only quick editor float
  ops/                         -- user-level workflows composing p4/* + UI
    resolve.lua integrate.lua submit.lua shelve.lua sync.lua
  picker/
    init.lua                   -- pick{items, format, preview, actions, multi}
    telescope.lua fzf_lua.lua snacks.lua mini_pick.lua select.lua
  integrations/
    lualine.lua fidget.lua swarm.lua p4v.lua
  health.lua
```

### 3.1 The runner (core/runner.lua)

- `vim.system(argv, {cwd=ws.anchor, env=env, stdin=…, text=true, stdout=on_chunk})`, where argv is `{'p4', '-Mj', '-ztag', [globals], cmd, …}`. Never use a shell.
- **No external programs, ever.** Only the four variables that make p4 launch programs are touched. Connection settings (`P4PORT`, `P4USER`, `P4CLIENT`, `P4CHARSET`, …) are never modified.
  - p4 runs detached from any terminal, so a launched diff tool, pager or editor would hang the call. This was reproduced with `P4DIFF="nvim -d"`.
  - **The primary guarantee:** the plugin never runs p4 in a way that consults these programs. Diffs are computed in-process, specs use `-o`/`-i`, and resolve uses `-am`/`-ay`. Stdin is closed unless we feed it, and every call has a timeout.
  - **The backstop** covers env-sourced values (a P4CONFIG value takes precedence over the environment, so it can't be the only defence): `P4EDITOR`, `P4DIFF` and `P4MERGE` are set to `false`, so an accidental launch fails immediately rather than hanging, and `P4PAGER` is unset.
  - **This applies only to the plugin's internal (background) p4 calls.** Launches the user explicitly asks for keep the user's environment untouched:
    - **External diff** (`:P4 diff!`, `diff.tool = 'external'`, or the "diff in external tool" menu action) runs p4's *own* command with the unmodified environment: `p4 diff <file>` for workspace vs #have, and `p4 diff2 <a> <b>` for revision, shelf (`@=CL`) and CL comparisons. p4 then invokes `$P4DIFF` itself, from the environment, P4CONFIG or P4ENVIRO, with exactly the arguments, charset handling (`P4DIFFUNICODE`) and temp files it would use from a shell, so the user's tool always works as it does on the command line.
    - GUI tools (p4merge, meld, Beyond Compare, kdiff3…) run as a detached job with no timeout, so Neovim stays usable. Terminal tools (vimdiff, delta, `diff | less`…) run in a `:terminal` tab. The mode is chosen from `diff.external_terminal = 'auto' | true | false`, where auto checks the tool's basename against a known-GUI list.
    - If `P4DIFF` resolves to nothing, the action is hidden and `:P4 diff!` explains why.
    - **Merge tool:** resolve launches `$P4MERGE` (read via `p4 set -q P4MERGE` from the anchor, so P4CONFIG and P4ENVIRO values count) ourselves with base/theirs/yours/result, as a job with the user's environment.
- **Working directory = the workspace anchor (§3.3).** `PWD` is set to the same path, and paths are always absolute. This makes every call for a workspace resolve the same P4CONFIG, whichever buffer triggered it.
- **Streaming parse:** split stdout on `\n` and `vim.json.decode` each line into a record. Classify records with `severity` (2 = warning, collected; ≥3 = error). Stderr text plus a nonzero exit code is a connection or usage error, and goes to `conn.lua`.
- **Timeouts:** a uv timer kills the process at the timeout (defaults: 10 s for interactive calls, 5 s for background calls, none for sync/submit, which report progress instead).
- **Batching:** `stdin = table.concat(paths, '\n')` with `-x -`.
- **Result type:** `{ok, records, warnings, errors, stderr, code, ms}`. Every call is logged to `log.lua`.
- **Binary and non-UTF-8 content:** `print -q -o <tmp>` then read the bytes. This path is chosen from fstat `headType`/`type` (binary, utf16) and `P4CHARSET`.

### 3.2 Queue

- Global concurrency cap (default 4) shared by all workspaces. Pause/resume and offline state are per workspace.
- **Dedupe:** identical `(cmd, args, stdin)` requests that are in flight share one promise.
- **Priorities:** `interactive` (the user is waiting) is served before `buffer` (attach/fstat), which is served before `background` (the startup check).
- **Pause/resume:** used for the login flow. Queued work resumes after a successful login.
- **Per-key coalescing:** `throttle_by_key('fstat:'..path)` collapses bursts, in the style of gitsigns `throttle_async`.

### 3.3 Activation, workspaces and connections

**Dormant by default.** `plugin/perforated.lua` defines `:P4` (plus aliases), `<Plug>` maps and one `BufReadPost`/`BufNewFile` autocmd. No other module loads until activation.
- The autocmd runs `activation.check(dir)`, a pure-Lua lookup cached per directory: `vim.fs.find(P4CONFIG name, {upward=true})`. The P4CONFIG name is read once from `$P4CONFIG`, or from P4ENVIRO by parsing the file directly, with no process.
- **Env-only setups** (no P4CONFIG, but a client comes from the environment or P4ENVIRO): one background `p4 -ztag info` per session learns the client root. After that, the check is a prefix test.
- **If the `p4` binary is missing**, or nothing resolves, the plugin stays dormant: no processes, timers or caches.

**Workspace anchor.** p4 uses the working directory for two things: finding P4CONFIG (searching upward) and resolving relative paths. Project markers such as `.git` are irrelevant to it.
- **Anchor** = the directory containing the P4CONFIG file that was found. Without P4CONFIG, it is the client root from `p4 info`.
- Every p4 call for the workspace runs with `cwd = PWD = anchor` and absolute paths. This avoids nested-P4CONFIG surprises that can happen when running from a file's own directory.
- A client with a `null` root or `AltRoots` uses `info.clientRoot` plus the AltRoots for membership tests.

**Workspace object** (`core/workspace.lua`). Key: anchor, plus port, user and client from `p4 set` (local, no server call).
- **One object per workspace, shared by all its buffers.** `workspace.registry[key]` is created on first activation. With 15 buffers from one workspace there is still exactly one `info`, `conn`, queue, fstat cache, CL memo, sticky CL and poller.
- A buffer stores only `vim.b.perforated_ws = key`, its fstat entry (a reference into the shared cache), its hunks and extmarks. Its base text is a reference into the shared content LRU, so two buffers of the same `file#rev` share one string.
- **Directory-to-workspace resolution** is cached per directory, so opening the 15th buffer is a table lookup.
- It holds env, info (`clientRoot`, `caseHandling`, `serverVersion`, `clientStream`, unicode), `conn`, pause state, the fstat cache, the CL memo, the sticky CL, the poller, and the qf lists it owns.
- Every buffer binds to the workspace containing it (`vim.b.perforated_ws`). Signs, check-out, statusline and diff always use the buffer's own workspace. Buffers from different workspaces coexist.
- Views bind to the workspace they were opened from (the current buffer's, else the working directory's). The header shows the client. `gw` switches between workspaces when more than one is active.
- **Teardown:** when a workspace's last buffer closes and the working directory is outside it, its poller stops, caches free and state becomes idle. It reactivates on demand.

**Connection-only contexts** (outside any workspace). Commands that only need a server run anywhere a port and user resolve (from the environment, P4ENVIRO or the `p4 set` defaults):
- `describe`, `changes`, CL lookup
- `filelog`/`annotate`/`print` of depot paths
- `perforated://` links
- the submitted CLs of a user

They get a lightweight context with no client and no poller, created on first use. Workspace-only commands (`edit`, `add`, `diff` of a local file, the client view, …) outside a workspace reply "not in a Perforce workspace (see :checkhealth perforated)".

**Connection state machine** (`conn.lua`, per workspace or context):
- An auth error (message code or "session has expired", "P4PASSWD invalid") → `auth_needed`. The workspace queue pauses and there is one `inputsecret` prompt, sent to `p4 login` on stdin, then the queue resumes. If the user cancels, the state becomes `offline_auth` and later calls fail fast with a hint. Tickets live in p4's own ticket file, so a login in one Neovim session covers the others.
- A connection failure or timeout → `offline`, with exponential backoff probes (5 s → 5 min) using `p4 -ztag info -s`.
- It is exposed through `vim.b.perforated_status_dict.conn` (per buffer) and `vim.g.perforated` (for the current workspace).

**Session isolation.**
- All state is in-process memory. Temp files (merge tool inputs, external diff) live under `vim.fn.tempname()`'s per-process directory and are deleted on `VimLeavePre`.
- Nothing is written under `stdpath('cache')` or `stdpath('state')` except the optional `:P4 log` export when the user asks for it.
- Changes made by other sessions or the p4 command line are picked up by the refresh triggers in §3.6.

### 3.4 Caches (core/cache.lua)

- **Every cache is per workspace** except the content LRU, which is keyed by server plus depot path and revision.
- **fstat cache:** `path → {depotFile, haveRev, headRev, action, change, type, unresolved, otherOpen, …, t}`. It is filled from batched fstat and `opened -C client`. Our own commands (edit, revert and so on) invalidate precisely what they touch, and `:P4 refresh` clears everything.
- **Content LRU:** `depotFile#rev → string` (or a file path for binaries), with byte accounting and a 32 MB default cap, shared by all workspaces of one server within the session. Memory only; no disk layer.
- **CL memo:** `CL → {user, client, time, desc}`, filled from `changes -l`, `filelog -l` and `describe`. It is shared by blame, history and time-lapse.
- **Weak references:** caches keyed by buffer number are dropped on `BufUnload` and `BufWipeout`.

### 3.5 Buffer attach pipeline

```
BufReadPost (plugin/, cheap) → in_client? → queue fstat (coalesced 30 ms window, -x - batch)
   → state.fstat known → if opened: fetch base (print #have, cached) → diff → signs
                       → if not opened & in depot: arm checkout hooks (FileChangedRO + BufModifiedSet)
                       → if not in depot: arm add-on-write hook
   → set vim.b.perforated_status_dict
nvim_buf_attach on_lines → debounce 100 ms → diff (in-process / worker for large) → signs
```

- Guards: `max_file_length` (default 50k lines → worker thread; above `hard_max` (default 500k) signs are off), binary types skipped, and `buftype ~= ''` skipped.
- `FileChangedShell` with `v:fcs_reason == 'mode'` is swallowed, which fixes the spurious "file changed" warning after `p4 edit` flips the read-only bit.

### 3.6 Stale detection and refresh (core/poll.lua)

Perforce can't push notifications to clients, so we poll, cheaply.
- **Probe:** `p4 changes -m1 -s submitted <depot paths of opened files>`, sent through `-x -` in batches (take the max). This is an indexed query that returns the newest submitted CL touching any opened file.
  - **If the probe finds no newer CL** than the last one seen, stop there.
  - **Otherwise** run one batched `fstat -T depotFile,haveRev,headRev,headChange,unresolved` over the opened files. The CL memo resolves the new head CLs (user, description) without `describe`, using `changes -l` over the new CL range.
  - Buffers that are loaded but not opened are included in the fstat as well, so the stale sign and statusline stay correct. They never trigger a popup.
- **Triggers:**
  - a timer every `poll.interval` (default 300 s; 0 disables). It runs only while Neovim has focus, the workspace has opened files and it is online.
  - `FocusGained` (throttled to at most one per 30 s), which catches up on anything missed while unfocused
  - `BufEnter` of a p4 buffer (throttled per buffer, 60 s)
  - **always** before submit
  - after our own sync, submit or revert (precise invalidation, no probe)
- **On a newly stale opened file** (a transition only, never repeated for the same head revision):
  - update the stale sign and `vim.b.perforated_status_dict.stale`
  - add the file to the `:P4 status` quickfix list, without opening it
  - show a **toast**: a bottom-right float (`focusable=false`, `noautocmd`, high zindex, `winblend`) that stacks. It lists each file as `#have→#head · CL · user` with a hint: `:P4 sync` / `:P4 stale`.
    - **Activity-gated dismissal:** the `toast.timeout` countdown (default 8 s) starts at the first `CursorMoved`/`CursorMovedI`/`InsertEnter`/`CmdlineEnter` after the toast is shown, not at creation. `toast.timeout = 0` makes toasts sticky until `:P4 dismiss`.
    - **Focus gating:** while unfocused (after `FocusLost`), toasts queue and render on `FocusGained`. Polling is also paused while unfocused, and a catch-up probe runs on return.
    - Health warns when focus events look unsupported (for example tmux without `focus-events on`).
    - **History:** `:P4 notifications` shows a ring buffer of the last 50 toasts.
    - No OS or desktop notifications.
  - update the **statusline markers**, which stay until sync or resolve:
    - **Per buffer:** `vim.b.perforated_status_dict.stale = {have, head, change, user}`, with the string form `↓#8→#9`.
    - **Per workspace:** `vim.g.perforated.ws[key] = {stale = n, unresolved = n, conn}`, plus the current buffer's view in `vim.g.perforated` (`↓2 !1`).
    - Shipped as a lualine component and as `require('perforated').statusline()`, with configurable glyphs.
    - Updates fire `User PerforatedStatus` so statuslines redraw without polling.
  - `toast.backend = 'notify'` routes it to `vim.notify` instead (nvim-notify, snacks, fidget).
  - Unresolved files discovered by the same fstat use the same path.

### 3.7 Icons (ui/icons.lua)

- **File-type icons** come from mini.icons or nvim-web-devicons (auto-detected, `icons.provider = 'auto' | 'mini' | 'devicons' | false`). They are cached per extension or filename and used in the client view, describe, diff-tab file panel, quickfix text, pickers and toasts.
- **Status glyphs** cover edit, add, delete, move/add, move/delete, integrate, branch, shelved, stale, unresolved, opened-by-another, locked-by-another and default CL.
  - `icons.style = 'nerd'` (the default when an icon provider is detected) or `'ascii'` (the fallback: `e a d m i b S ! U ⇄ @`).
  - Each glyph and highlight group can be overridden.
- Rendering stays bulk: icons are part of each row's text chunks and highlights come from one extmark pass, with no per-row API calls.

### 3.8 UI tree renderer (ui/tree.lua)

- Declarative nodes `{id, kind, text_chunks, children, folded, item}`. Rendering produces the lines, highlight ranges and a `row → node` map.
- **Bulk update:** one `nvim_buf_set_lines` call plus extmarks in a single namespace. On refresh, diff the new line array against the old one with `vim.text.diff` and patch only the changed ranges. This keeps the cursor and scroll position stable and is cheap.
- Folds are tree state, not Vim folds, so `h`/`l` and `<Tab>` re-render the subtree only.
- Actions resolve `node.item` → `keys.registry` → the valid actions for that item kind. The same registry drives the `<Space>` menu, the `?` help and the footer, so these three can never drift apart.

### 3.9 Action registry (ui/keys.lua)

```lua
{ id='diff', label='Diff vs #have', keys={'d','<C-d>'}, kinds={'opened_file','shelved_file','file'},
  when=function(item) … end, run=function(items) … end, footer=1 }
```

- Keys come from a vim-style table plus a p4v layer (on by default, `keys.p4v=false` disables it). Users override with `keys = { diff = {'dd'} }` or `false`.
- Marks (`m`/`u`) turn `run(items)` into a multi-item call. Operations then batch with `-x -`.

### 3.10 Commands

- One command table: `{name, run, complete, nargs, range, bang, desc}`. It generates `:P4 <sub>` (with subcommand-aware completion for CL numbers, users, depot paths and revisions) and, if `commands.aliases = true` (the default), flat `:P4edit`-style aliases.
- `:P4` with no arguments opens the client view.

---

## 4. Milestones

Each milestone ends in a usable, tested release. Estimates assume one developer working part-time and are for relative sizing only.

### M0 — Foundations (runtime, no user features) · ~1.5 weeks

> **Status (2026-09-23): done.** 50 tests pass (fake p4 + real p4d 2025.2) and benchmarks are within budget (startup 0.26 ms, dormant lookup 0.001 ms, workspace + 50 buffers 120 KB).
> Deviations:
> - Fake-p4 behaviour is written as inline rules per test rather than recorded fixtures. The real-p4d tests keep them honest. The recorder script is deferred until fixtures grow (M1/M2).
> - The runner adds a SIGKILL escalation 2 s after vim.system's SIGTERM timeout.
> - Env-only activation requires an explicit P4CLIENT (P4PORT alone isn't enough).

**Scope:** the repo skeleton, `config`, `core/*` (runner, queue, async, parse, env, conn, cache, log, events), `health.lua`, `:P4 log`, `:P4 info`, and the test harness.

**Implementation notes**
- `async.lua`: `run(fn)` wraps a coroutine. `await(fn, ...)` yields until the callback. `all(list)` handles parallel rounds. Errors carry p4 context.
- `parse.lua`: unfold indexed fields; JSON-line and text-ztag parsers with identical output; severity mapping.
- `health.lua` checks:
  - the p4 binary and its version, and `-Mj` support
  - `p4 set` sources
  - reachability and latency of `info`
  - `login -s`
  - client root
  - unknown config keys
  - which optional integrations were detected
  - the terminal's CSI-u capability hint for the p4v keys
- `:P4 log`: a ring buffer (default 500 entries) with command, ms, record count, exit status and error, rendered in a scratch buffer.

**Testing**
- A **fake p4**: an executable Lua script (`tests/bin/p4`, run with `nvim -l`) placed first on `PATH`. It matches argv and stdin against fixture files (`tests/fixtures/<scenario>/<hash>.jsonl`) and can inject latency, errors and hangs.
- A **fixture recorder**: `scripts/record.lua` runs real p4d scenarios and stores their outputs.
- **Real p4d:** CI downloads `p4`/`p4d` (pinned version, cached). `P4PORT="rsh:p4d -r $TMP -L log -i -J off"` per test gives a server with no daemon. The seed script creates a depot, stream/classic depots, a user and a client.
- Isolation: `P4CONFIG`, `P4ENVIRO`, `P4TICKETS` and `HOME` all point at temp paths.
- Framework: **mini.test** with a child Neovim, on a matrix of nvim 0.11, 0.12 and nightly for Linux and macOS.
- **Dormancy tests:** opening files outside any workspace (and with no `p4` on PATH) loads zero perforated modules beyond `plugin/`, spawns zero processes (the fake p4 counts calls) and creates zero timers. A connection-only command (`:P4 describe N`) works outside a workspace, and workspace-only commands return the clear message.
- **Multi-workspace tests:** two seeded clients (two P4CONFIG anchors). Buffers bind to the right workspace, cwd/PWD equal each anchor, caches don't cross, and a nested P4CONFIG is resolved deterministically.
- **Session isolation:** two child Neovims on different workspaces share no state and write nothing outside their temp directories (checked with a directory snapshot diff).
- **Env tests:** internal calls see `P4DIFF=false`, etc. The user-requested external diff sees the untouched `P4DIFF` from the environment, a P4CONFIG file and P4ENVIRO. A fake diff tool records its argv; GUI mode is detached, terminal mode opens a `:terminal`.
- Tests in this milestone: the parser on real outputs; runner timeout and kill (fake p4 hangs); dedupe; priority; pause/resume; transitions of the connection state machine; env sanitizing (fake p4 asserts `P4DIFF` is unset).
- **Benchmark harness:** `tests/bench/*.lua` measures startup (`--startuptime` delta), memory (`collectgarbage('count')`) and timings. CI fails on budget regressions.

**Exit:** `:checkhealth perforated` is green against the real p4d, and `:P4 log` shows calls.

### M1 — Daily-driver MVP · ~3 weeks

> **Status (2026-09-23): done.** 76 tests pass (26 new M1 cases, mostly against a real p4d). All benchmarks are within budget: startup 0.44 ms, attach 0.03 ms, sign refresh for 10k lines 4.3 ms, 203 KB per active workspace, 1.6 KB per buffer.
> Deviations and additions:
> - `A` (always, this session) added to the check-out prompt.
> - Keys typed during a grace period are replayed as text.
> - Files are made writable optimistically when a target is chosen (E505 happens before write autocmds).
> - External diff launches `$P4DIFF` directly (p4 skips identical files; `diff2` ignores P4DIFF).
> - Sign diff uses myers, not histogram.
> - Check-out hooks are global autocmds, not per buffer.
> - The statusline global is `vim.g.perforated_status`.
> - `:P4 revert!` bang syntax.
> - The lualine "component" is `require('perforated').statusline`.

**Scope**
1. **Attach pipeline** (§3.5) and the batched fstat on buffer open.
2. **Check-out flow**:
   - On first modification, show the float: `<CR>` for the sticky CL (default CL initially), `c` to pick a CL, `n` for a new CL (inline description input, `change -i`), `s` to skip for this buffer, `S` to never ask this session.
   - The CL list for `c` comes from a fresh `changes -s pending -c client -l` fetched when the float opens. It appears in the picker adapter as soon as it arrives.
   - `p4 edit -c CL` runs asynchronously. `readonly` is cleared immediately, and the `BufWritePre` guard waits (bounded to 5 s) on the pending edit.
   - Option `checkout.on_write = true` checks out silently to the sticky CL on write, with no prompt.
   - Option `checkout.dirs` is an allowlist or denylist of paths.
3. **Add-on-write** for new files inside the client root, using the same float.
4. **Revert** (`:P4 revert`, with confirmation) and `:P4 revert -a` (revert unchanged). The buffer reloads, and signs and state are updated.
5. **Gutter signs:**
   - The diff engine shim (`vim.text.diff` or `vim.diff`, histogram algorithm, `linematch=60`), with the worker-thread path for large files.
   - Signs are extmarks with configurable glyphs and priority.
   - `]h`/`[h` navigate hunks (with count and wrap). Preview hunk shows a float with the original lines, and reset hunk restores the #have lines through the buffer (undoable).
   - A stale indicator appears when have < head (a sign on line 1 plus the statusline).
6. **`:P4 diff`**: the current file against #have, side by side in a new tab. The left side is the `perforated://` buffer (read-only, `nomodifiable`, filetype copied) and native `diffthis` is used. `q` closes the tab. `:P4 diff #rev`, `@CL` and `#head` are supported. `:P4 diff!` or `diff.tool='external'` launches `$P4DIFF` with temp files instead.
7. **`perforated://` URIs** via `BufReadCmd`, so `:e perforated:////depot/a.c#3` works.
8. **Statusline:**
   - `vim.b.perforated_status_dict = {action, change, have, head, stale, unresolved, added, changed, removed}`
   - `vim.b.perforated_status` (string)
   - `vim.g.perforated = {client, user, conn}`
   - a lualine component
9. **Commands framework** (`:P4 <sub>` plus aliases) with `edit`, `add`, `revert`, `diff`, `info`, `log`, `refresh`, `status`.
10. **Quickfix foundation (`ui/qf.lua`)** — entry schema with `user_data`, `title` + `context` (so `gr` in the qf window refreshes), `quickfixtextfunc` column alignment, streaming append by list `id`, and the opening policy. Wired to: `:P4 opened` (qf, grouped by CL), `:P4 status` / startup check (qf), `:P4 hunks` (all hunks in opened files → qf; base text from one `p4 -x - print` batch, diffed in-process) and `:P4 hunks %` (loclist), plus p4 errors that name files (qf instead of a notification flood).
11. **Opt-in keymap preset** (`<leader>p…`, `]h`/`[h`) and `<Plug>` mappings for everything.
12. **Stale detection** (§3.6):
    - **On workspace activation (idle):** `opened -C client`, then one batched `fstat` over the opened files. It shows a toast if anything is stale or unresolved.
    - **Background probe** every 5 min while focused, plus the `FocusGained`, `BufEnter` and pre-submit triggers.
    - **Toast:** the non-focusable corner float for newly stale files (`ui/toast.lua`).
    - **`:P4 status` / `:P4 stale`:** show the results in the quickfix list.
13. **Offline and auth flows** (§3.3) wired into the UI, with the statusline indicator.
14. **Icons** (§3.7) for the check-out float, toast and statusline. The client view and other views use them from M2.

**Testing**
- Check-out: the float appears on the first `x` and on the first `i`+type. `<CR>` edits into the sticky CL. Stickiness resets after that CL is submitted. `S` suppresses prompts. The on-write mode works. The write guard waits for the in-flight edit. With a slow fake p4 (2 s latency) typing stays responsive; this is measured by timing `nvim_input` round trips in the child.
- Signs: golden tests of hunk extmarks for add, change and delete, at the start and end of the file, with CRLF and without a trailing EOL. A 100k-line file never blocks for more than 5 ms. Reset hunk can be undone.
- `FileChangedShell` mode-only change: no prompt.
- Stale polling:
  - An unchanged probe causes no fstat.
  - A submit from a second client causes exactly one fstat, plus one toast listing the right CL and user.
  - No repeat toast for the same head revision.
  - No polling while unfocused, then a catch-up on `FocusGained`.
  - Pre-submit always probes.
  - Toasts never take focus, and they stack and dismiss correctly.
  - The countdown doesn't start without user input.
  - A toast raised while unfocused appears only after `FocusGained`.
  - `:P4 notifications` replays toasts.
  - The per-buffer and per-workspace statusline markers set and clear on sync or resolve, and `User PerforatedStatus` fires.
- Sharing: opening 15 buffers from one workspace creates exactly one Workspace object and one poller, and makes one batched fstat call (coalesced). Two buffers of the same `file#rev` share one base-text string.
- Offline: the fake p4 hangs, the state becomes offline, commands fail fast, the probe recovers, and queued interactive work runs.
- Auth: the fake p4 returns "session expired", the prompt appears once, the password goes to stdin, and the queue resumes.
- Integration against real p4d: edit, add, revert, diff and the startup check, end to end.
- Benchmarks: attach cost, sign refresh time, startup delta.

**Exit:** the author uses it daily on a real 100k–1M-file workspace with no perceptible lag.

### M2 — Client view, CLs, pickers · ~3 weeks

**Scope**
1. **ui/tree, ui/float (action menu), ui/footer, ui/keys registry** (§3.8–3.9), and `?` help generated from the registry.
2. **Client view** (`:P4`, opens in a new tab; also available as a float or split):
   - A header with client, stream, user, server and connection state.
   - The skeleton paints immediately.
   - **One parallel round:**
     - `changes -s pending -c client -l`
     - `opened -C client`
     - `describe -S -s <all pending CLs>`, for shelved files
     - `fstat -Ro -T … //client/...`, which gives unresolved and stale state for opened files
     - `changes -s submitted -u me -m 20 //client/...`
   - Sections:
     - **Pending**: each CL folds open to its files (action, depot path, #have/#head, and STALE / UNRESOLVED / shelved badges).
     - **Unresolved / stale**
     - **Submitted (mine)**
     - **Workspace reconcile**: lazy. It runs `p4 status -m` over the client (with `--parallel` when supported) only when expanded, reports progress, and can be cancelled.
   - `A` toggles pending scope to all my clients (`-u me`, grouped by client; other clients are read-only).
   - Keys as in the design doc: vim-style keys plus the p4v layer, `h`/`l` folding, `<Space>` menu, footer, marks.
   - The view re-queries on open and after every action it triggers ("always fresh"), with a coalesced refresh (one in flight plus one queued).
3. **Diff tab** (`difftab.lua`): a file panel (list or tree) plus a native diff pair, with `<Tab>`/`<S-Tab>` to cycle files. Used by `D` on a CL, `:P4 diff -a` (all opened files, with an optional selection picker) and shelf diffs. Content is fetched per file only when that file is focused, and prefetches the next one.
4. **CL operations:**
   - `c` new CL (quick description editor, optional template)
   - **`C` edit description**, the same action everywhere a CL appears (client view, describe, qf, pickers, `<leader>pC` in code buffers) and as `:P4 change [N]`:
     - Quick mode is a float with only the description. It fetches `change -o [-u] N`, replaces only the `Description:` field, and saves with `change -i [-u]` on `:w` or `<C-s>`.
     - Submitted CLs use `-u` (owner update), with an opt-in `-f` retry for admins after confirmation.
     - The default CL has no `C` action; its files can only be moved (`M`) to an existing or new CL.
     - `gS` or `:P4 change!` switches to the full `acwrite` spec buffer.
     - Parse and server errors are shown inline.
     - After a save, the CL memo updates and every view showing that CL refreshes.
   - The M1 check-out float's "new CL" input is upgraded to the same editor (single line, `<C-CR>` expands).
   - `M` reopen marked files into a picked or new CL
   - `x`/`X` revert
   - `e`/`a` edit/add
5. **Send-to-quickfix action** (`Q` → qf, `gQ` → loclist) in the registry, for the item under the cursor, the marked items or the whole list. It works from the client view and the diff-tab file panel. Qf-window buffer-local action keys (`d`, `x`, `M`, `D`, `<Space>`) are active for perforated lists. Workspace reconcile results stream into qf.
6. **Picker adapter** (`picker/*`): each adapter maps its native send-to-qf onto our entry format so `user_data` survives. telescope first (the author's primary), then fzf-lua, snacks, mini.pick and the `vim.ui.select` fallback. Auto-detected, or set via `picker = 'telescope'`. Sources: pending CLs, opened files, submitted CLs (streaming, paginated) and users.
7. **Submitted views:** `:P4 changes [-u user] [path]` shows the last 50, scoped to the client view by default. Scrolling past the end (or pressing `gn`) loads the next 50 using `@<oldest`. Available in the client view section, a picker or a standalone buffer.

**Testing**
- Renderer: golden screenshots (mini.test `child.get_screenshot()`). Row→item mapping. The patch-diff refresh keeps the cursor on the same item after data changes.
- Registry consistency: every action shown in the footer or help has a key and a `when`. The menu shows only valid actions per item kind.
- **Query-count assertions:** opening the client view makes exactly N p4 calls whether there are 1 or 50 CLs (the fake p4 counts calls). This is the N+1 regression guard.
- Spec buffer round trip against real p4d (create, edit description, reopen files).
- Description editor against real p4d:
  - The pending edit is saved.
  - A submitted edit by the owner works via `-u`.
  - A submitted edit by a non-owner shows the inline error, and the `-f` path runs only when `allow_force` is set and confirmed.
  - `C` isn't available on the default CL (registry `when` guard), and `:P4 change default` gives a clear error.
  - Non-description fields are byte-identical after the round trip (Jobs, Type, and Files including paths with spaces or unicode).
  - Multi-line and unicode descriptions survive.
  - Views showing the CL refresh after a save.
- Picker contract tests: each adapter gets the same items and triggers the same actions (headless, calling adapter functions directly), and the `vim.ui.select` fallback is always tested.
- Benchmarks: render a 5k-row view; first-paint time.

### M3 — History, annotate, describe, blame line · ~2.5 weeks

**Scope**
1. **`:P4 describe N`** (and `C-g`/`g/` lookup by CL number, path or user): a Magit-style buffer with a header (user, client, date, status, description) and files. `<Tab>` expands an inline unified diff, which is generated lazily in-process from two `print` calls and rendered with the `diff` highlight groups. `D` opens the diff tab. It handles pending, shelved (`-S`) and submitted CLs. Shelved files default to shelved vs base (`@=CL` vs `#base`); the menu adds vs workspace and vs head.
2. **History (`:P4 filelog`, `L`, `C-t`):** one `filelog -l -i -m 100` call, paginated. Presentation is configurable (float by default, picker or quickfix). `<CR>` opens an action menu: diff vs previous rev, diff vs workspace, view the submitted CL, open the revision read-only. Directory history uses `changes path/...`.
3. **Annotate (`:P4 annotate`, `b`):** one `annotate -c -q [-I]` call plus one `filelog -l` (for CL metadata, no describe). Shown in a left scrollbound, cursorbind split with columns for CL, user and date, coloured by age with a configurable gradient. `<CR>` describes the CL, and `~` re-annotates at the revision before this line's change. Rendered with one `set_lines` call.
4. **Current-line blame:** virtual text, opt-in (`blame_line = true`). The whole-file annotate is cached per `depotFile#have`, and the cursor reads the cache with a 150 ms debounce. Locally modified lines show "Not submitted".
5. **Quickfix hooks:** `Q` in describe sends the CL's files (workspace paths when mapped, otherwise `perforated://…@CL`; `perforated://…@=CL` for shelves). History as a loclist presenter (`perforated://f#rev` entries). `Q` on an annotate line gives a loclist of every line from that CL.
6. **Swarm links:** `swarm.url` comes from config or the server's `P4.Swarm.URL` property. Actions to open or copy the review URL are available for a CL.

**Testing**
- Annotate on files with 1, 100 and 1000 revisions: exactly 2 p4 calls; render time under budget for 20k lines.
- The `~` walk-back sequence against a seeded real p4d history.
- Filelog pagination and action-menu targets (each action opens the right URI pair).
- Describe on pending, shelved and submitted CLs (real p4d), including shelved vs base.
- Blame-line debounce: rapid cursor moves cause no extra p4 calls.

### M4 — Shelve, resolve, submit, sync, integrate, rename · ~3 weeks

**Scope**
1. **Shelve and unshelve** at file and CL level:
   - `s` shelves the marked files or a CL (`shelve -f -c CL`, with a replace confirmation).
   - `S` unshelves into the current or a picked CL (`unshelve -s CL -c target`), with `-f` when confirmed.
   - `z` deletes shelved files (`shelve -d`).
   - The client view shows shelved badges and a nested shelf group.
2. **Resolve** (`R`, `:P4 resolve`):
   - First run `resolve -am` over the target (file, CL or all).
   - For each remaining conflict, fetch base, theirs and yours to temp files (`resolve -o`/fstat `resolveBase*` and `print`), then launch the merge tool (`$P4MERGE` or `merge.tool`) **as an async job**.
   - On exit 0, if the result file changed, run `resolve -ay` with the merged content copied in. The file is written through the buffer if it is loaded.
   - Otherwise leave the file unresolved and report it. There is no merge logic in the plugin, and a clear summary is shown at the end.
3. **Submit** (`P`, `C-s`): a confirmation float showing the file count and description with actions: submit, edit the description first (spec buffer), cancel. Runs `submit -c CL` asynchronously with progress. On success the CL is removed from the view and signs are cleared, and it resets the sticky CL if it was that CL. Submit errors (unresolved files, out-of-date files) link to resolve or sync.
4. **Sync** (`gy`, `C-S-g`, `:P4 sync [path|@CL|#head]`): progress via native 0.12 progress messages, forwarded to fidget or snacks. Afterwards, loaded buffers reload via `checktime`, and their fstat and base text are invalidated.
5. **Quickfix outcomes:** files left unresolved after `-am` or a cancelled merge, submit failures (out of date, unresolved, locked; the entries link to sync or resolve), sync results that need attention (can't clobber, must resolve), and integrate preview plus "must resolve" results. Each goes to qf with the p4 reason as text, and `R` on an entry resumes resolve.
6. **Delete and move:** `:P4 delete` (with confirmation; the buffer is wiped or marked). `:P4 move {new}`: `edit` if needed, then `move`, then the buffer is renamed via `nvim_buf_set_name` and saved, and state is kept.
7. **Integrate (cherry-pick CL):** `:P4 integrate CL` or an action on a submitted CL in any view.
   - Determine the source path from `describe -s CL`, and map it to the target through a stream relationship (`-S`/`-P`), a branch spec, or a path pair the user enters. The last-used pair is remembered.
   - Run `integrate` (or `merge` for streams) `-c targetCL src/...@=CL tgt/...`, with a preview first (`-n`).
   - Then offer to resolve. A picker of "submitted CLs on another branch" (`changes //other/...`) supplies the source.

**Testing**
- Real p4d scenarios for each operation. For resolve, the merge tool is replaced by a fake script that writes a chosen result and exit code (success, cancel, failure). Checks cover `-am` auto-accepts clean merges and conflicts invoking the tool with the correct base/theirs/yours.
- Integrate across two streams and across a classic branch spec. The preview matches the result.
- Buffer consistency after sync, move and submit: no stale signs, no "file changed" prompts.
- Concurrency: a submit in flight while the user edits another file keeps the UI responsive.

### M5 — Time-lapse (time-machine buffer) · ~1.5 weeks

**Scope**
- `:P4 timelapse` (`t`, `C-S-t`) runs **one** `annotate -a -c [-I]` and **one** `filelog -l`. It builds an in-memory line table `{text, lower, upper}` and reconstructs revision N by filtering `lower ≤ N ≤ upper`. This is O(lines), cached per N, so stepping is instant.
- A read-only buffer with the file's filetype:
  - `[r`/`]r` (and `h`/`l`) step through revisions, and `g` jumps to a revision number.
  - `T` picks a revision by CL description (picker).
  - A winbar shows `#N/#head · CL · user · date · description`.
  - Lines added in N are highlighted, and deleted lines are shown as `virt_lines`.
  - An optional age gutter can be toggled.
  - `d` diffs N-1 vs N (a split), `D` describes the CL, and `y` yanks the CL. `Q` sends the lines changed at revision N to the loclist.
- The cursor stays anchored on the same logical line across steps, mapped through line identity from annotate, so no diff is needed.
- Memory: the line table is freed when the buffer closes. Files over the size guard fall back to a `print`-per-revision mode with an LRU.

**Testing**
- Reconstruction correctness: for a seeded file with 50 revisions, rebuilt revision N equals `p4 print #N` for every N.
- Step latency under 5 ms with 20k lines × 200 revisions.
- Cursor anchoring across insertions and deletions above the cursor.

### M6 — Slider, extras, polish · ~2 weeks

- **P4V-style slider:** a top float with revision ticks (and CL/date scales). The modes are single revision, incremental diff (two handles, split diff) and a multi-revision range. It uses the M5 engine.
- **p4v escape hatches:** `gR`/`C-S-r` run `p4vc revgraph`, and there are actions for `p4vc timelapse` and `p4vc streamgraph`, when p4vc is present (health reports this).
- In-process LSP code actions (experimental, opt-in): the same action registry is exposed through `gra`.
- Docs: `:h perforated`, generated from annotations with an up-to-date key table, a README with GIFs, and a migration guide from vim-vp4 and nfvs.
- A performance pass: profile with `jit.p`/`vim.uv.hrtime` markers, `:P4 debug timings` (Magit's verbose-refresh equivalent), and memory soak tests (open and close 1000 files, then check memory returns to baseline).

---

## 5. Cross-cutting testing strategy

| Layer | Tool | What |
|---|---|---|
| Unit | mini.test (in-process) | parsers, diff/hunk model, LRU, registry, URI parsing, time-lapse reconstruction |
| Functional (UI) | mini.test child nvim + fake p4 | flows, keymaps, floats, screenshots, query-count guards, latency injection |
| Integration | child nvim + real p4d (rsh) | end-to-end ops on seeded depots (stream + classic), resolve with a fake merge tool |
| Performance | bench scripts in CI | startup, memory, attach, render, sign refresh, time-lapse step; fail on regression > 20% |
| Soak | nightly CI | 1000-file open/close, 100 CL views, memory back to baseline |

- **CI:** GitHub Actions on `ubuntu-latest` and `macos-latest`, nvim 0.11, 0.12 and nightly. p4/p4d binaries are cached. The lint job runs `stylua`, `selene` and lua-language-server type checks (LuaCATS annotations on public APIs).
- **Fixture discipline:** every fake-p4 fixture is recorded from real p4d by `scripts/record.lua`, so fixtures never drift from reality. `make fixtures` re-records them.
- **Manual QA checklist per milestone:** run on the author's real workspace, check `:P4 log` timings, and do a slow-network drill (`tc netem` or a fake p4 with latency).

## 6. Configuration sketch (defaults)

```lua
vim.g.perforated = {
  checkout = { prompt = true, on_write = false, sticky = true, dirs = nil, add_on_write = 'prompt' },
  signs = { enabled = true, base = 'have', priority = 6, max_lines = 50000, hard_max = 500000,
            text = { add = '▎', change = '▎', delete = '▁', stale = '↓' } },
  blame_line = { enabled = false, delay = 150, format = '{user} • {date} • {desc}' },
  diff = { layout = 'tab', tool = 'builtin' },           -- 'external' uses $P4DIFF
  client_view = { kind = 'tab', sections = { 'pending', 'unresolved', 'submitted', 'reconcile' },
                  submitted_limit = 20 },
  history = { presenter = 'float', limit = 100 },        -- 'picker' | 'loclist'
  qf = { open = true, loclist_for_file_scoped = true },
  changes = { page_size = 50, scope = 'client' },
  merge = { tool = nil },                                -- nil → $P4MERGE
  picker = 'auto',                                        -- telescope|fzf_lua|snacks|mini|select
  keymaps = false,                                        -- 'default' → <leader>p preset
  keys = { p4v = true },                                  -- per-action overrides allowed
  commands = { aliases = true },
  startup_check = true,
  poll = { interval = 300, focus_throttle = 30, bufenter_throttle = 60 },
  toast = { timeout = 8000, backend = 'float', history = 50 },  -- countdown starts on user activity; 0 = sticky; 'notify' routes to vim.notify
  statusline = { stale = '↓', unresolved = '!', offline = '⊘' },
  icons = { provider = 'auto', style = 'auto' },           -- provider: auto|mini|devicons|false; style: nerd|ascii|auto
  runner = { concurrency = 4, timeout = 10000, background_timeout = 5000 },
  cache = { content_mb = 32 },
  change = { template = nil, allow_force = false },
  swarm = { url = nil },
  notify = 'minimal',
}
```

## 7. Risks and mitigations

| Risk | Mitigation |
|---|---|
| `-Mj` unsupported on old servers | Detect in `info`/health; text `-ztag` parser with an identical output shape |
| Charset/unicode servers, utf16 files | Choose the `print -o` byte path from the fstat type; test with a unicode-mode p4d |
| Case-insensitive servers (macOS clients) | Normalize with `caseHandling` in `in_client` and cache keys |
| Huge files | Worker-thread diff, `hard_max` cutoff, time-lapse fallback mode |
| Ctrl+Shift keys not distinguishable in the terminal | Vim-style fallbacks for everything; health hints |
| p4 hangs without a timeout | Plugin-enforced timeout/kill plus offline state machine |
| Merge tool differences (p4merge args) | Configurable argv template: `{base} {theirs} {yours} {result}` |
| "Always fresh" feels slower on bad days | Skeleton first-paint, one parallel query round, `:P4 log` timings to diagnose |
| Scope creep (the UI) | The action registry is the only way to add an action; each milestone has an explicit exit criterion |

## 8. Suggested order of first commits (M0)

1. Repo skeleton: `plugin/`, `lua/perforated/`, `tests/`, `Makefile` (`test`, `bench`, `fixtures`, `lint`), CI workflow, `.stylua.toml`, `selene.toml`.
2. `core/async.lua` + `core/runner.lua` + fake p4 + the first runner tests.
3. `core/parse.lua` with fixtures recorded from real p4d.
4. `core/activation.lua`, `core/workspace.lua`, `core/env.lua`, `core/conn.lua`, `health.lua`.
5. `core/queue.lua`, `core/cache.lua`, `core/log.lua` + `:P4 log`.
6. The bench harness with baseline budgets.
