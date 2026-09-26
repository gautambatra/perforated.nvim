# perforated.nvim — Developer Guide

This guide has two parts:

- **Part I — Writing Neovim plugins.** What a plugin is, how Neovim finds and loads it, the Lua
  APIs you'll use, and the traps that bite everyone once. It uses this plugin's code as its
  examples, so it doubles as a gentle introduction to the codebase.
- **Part II — This codebase.** The design goals, the architecture, a walk through the main
  flows, a module-by-module reference, the data model, conventions, and the testing and
  debugging tools.

It assumes you can read Lua and know roughly what Perforce is (a [glossary](#29-perforce-glossary)
is at the end). Neovim 0.11 is the minimum version; features from 0.12 are used when present.

---

## Contents

**Part I — Writing Neovim plugins**

1. [What a Neovim plugin is](#1-what-a-neovim-plugin-is)
2. [How Neovim loads a plugin](#2-how-neovim-loads-a-plugin)
3. [The Lua API in one tour](#3-the-lua-api-in-one-tour)
4. [Buffers, windows and tabs](#4-buffers-windows-and-tabs)
5. [Autocommands and events](#5-autocommands-and-events)
6. [Commands and keymaps](#6-commands-and-keymaps)
7. [Highlights, extmarks and decorations](#7-highlights-extmarks-and-decorations)
8. [Floats, splits, winbars and statuslines](#8-floats-splits-winbars-and-statuslines)
9. [Asynchronous work: never block the editor](#9-asynchronous-work-never-block-the-editor)
10. [Configuration conventions](#10-configuration-conventions)
11. [Help files, health checks and integrations](#11-help-files-health-checks-and-integrations)
12. [Performance: startup, memory, rendering](#12-performance-startup-memory-rendering)
13. [Testing a plugin](#13-testing-a-plugin)
14. [Traps we fell into (so you don't have to)](#14-traps-we-fell-into)

**Part II — This codebase**

15. [Goals and design principles](#15-goals-and-design-principles)
16. [Repository layout](#16-repository-layout)
17. [Architecture](#17-architecture)
18. [Walkthroughs: what happens when…](#18-walkthroughs-what-happens-when)
19. [Module reference](#19-module-reference)
20. [Data model](#20-data-model)
21. [Conventions](#21-conventions)
22. [Recipes: adding things](#22-recipes-adding-things)
23. [Testing](#23-testing)
24. [Benchmarks and performance budgets](#24-benchmarks-and-performance-budgets)
25. [Debugging](#25-debugging)
26. [Documentation](#26-documentation)
27. [Continuous integration](#27-continuous-integration)
28. [Known limitations and ideas](#28-known-limitations-and-ideas)
29. [Perforce glossary](#29-perforce-glossary)

---

# Part I — Writing Neovim plugins

## 1. What a Neovim plugin is

A Neovim plugin is **a directory on Neovim's `runtimepath`** (`:set rtp?`). Neovim treats a
few subdirectory names specially:

| Directory | What Neovim does with it |
|---|---|
| `plugin/` | Every `*.lua` / `*.vim` file is **run once at startup** (after your config). |
| `lua/` | Nothing on its own: it's where `require('x.y')` looks (`lua/x/y.lua` or `lua/x/y/init.lua`). |
| `doc/` | Help files (`:h`). `:helptags` builds the index; plugin managers do it for you. |
| `ftplugin/`, `syntax/`, `indent/` | Run when a buffer gets that filetype. |
| `after/` | Same as above but runs later (to override other plugins). |
| `lua/<other>/…` | You can add modules to other plugins' namespaces — e.g. a lualine component in `lua/lualine/components/`. |

A plugin manager (lazy.nvim, packer, vim-plug, or the built-in `packadd` / `vim.pack`) clones
the repository somewhere and adds that directory to `runtimepath`. That's all "installing" is.

This plugin's shape:

```
plugin/perforated.lua          -- runs at startup: defines :P4, <Plug> maps, one autocmd
lua/perforated/…               -- the code, loaded on demand with require()
lua/lualine/components/…       -- an optional lualine component
doc/perforated.txt             -- :h perforated (generated)
```

There's no `init.lua` at the top level and no `setup()` call is needed: the `plugin/` file does
the minimum, and everything else loads when first used.

## 2. How Neovim loads a plugin

**At startup**, Neovim sources your config, then every file in every `plugin/` directory on
the runtimepath. Whatever `plugin/*.lua` does costs startup time for *every* user on *every*
start, even people who never use the plugin that day. So `plugin/` files should only
**register entry points** — commands, mappings, a couple of autocommands — and never
`require()` heavy code at top level.

**Lua modules load on `require()`**. The first `require('perforated.buffer')` finds
`lua/perforated/buffer.lua`, runs it, and caches the returned table in
`package.loaded['perforated.buffer']`. Later `require`s return the cached table. That's the
whole lazy-loading mechanism: put the `require` inside the function that needs the module.

```lua
-- plugin/perforated.lua: cheap. The gate module is only loaded when a file is opened.
vim.api.nvim_create_autocmd({ 'BufReadPost', 'BufNewFile' }, {
  group = group,
  callback = function(ev)
    require('perforated.gate').on_buf(ev)
  end,
})
```

**Plugin managers can defer loading** (lazy.nvim's `event`, `cmd`, `keys`). That's useful for
plugins that only act on demand, but this one must see files as they open (to attach to
them), so the README tells users not to lazy-load it on `cmd`/`keys`. Because `plugin/` is
tiny and nothing else loads outside a workspace, loading at startup costs well under a
millisecond anyway (measured by `make bench`).

**Loading after startup.** If a plugin manager loads the plugin late (`event = 'VeryLazy'`),
files may already be open. `plugin/perforated.lua` handles that: if `vim.v.vim_did_enter` is
1, it runs the handler for every loaded buffer.

**Guard against double loading** with a global flag (`vim.g.loaded_perforated`), and check the
Neovim version up front (`vim.fn.has('nvim-0.11')`), returning quietly on older versions.

## 3. The Lua API in one tour

Neovim exposes several layers to Lua. You'll use all of them:

| Namespace | What it is | Example |
|---|---|---|
| `vim.api.nvim_*` | The core API (same as over RPC). Fast, precise, verbose. | `vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)` |
| `vim.fn.*` | Every Vimscript function. | `vim.fn.bufnr(path)`, `vim.fn.confirm(...)` |
| `vim.cmd` | Run an Ex command. | `vim.cmd('tabnew')`, `vim.cmd.redraw()` |
| `vim.o`, `vim.bo[buf]`, `vim.wo[win]`, `vim.go` | Options (global / buffer / window). | `vim.bo[buf].modifiable = false` |
| `vim.g`, `vim.b[buf]`, `vim.w[win]`, `vim.t` | Variables (global / buffer / window / tab). | `vim.b[buf].perforated_ws = key` |
| `vim.keymap.set` | Mappings (a friendly wrapper over `nvim_set_keymap`). | `vim.keymap.set('n', 'q', close, { buffer = buf })` |
| `vim.uv` | libuv: timers, file system, processes, threads. | `vim.uv.new_timer()`, `vim.uv.fs_stat(p)` |
| `vim.system` | Run a process asynchronously (built on libuv). | `vim.system({ 'p4', 'info' }, opts, on_exit)` |
| `vim.schedule` | Run a function on the main loop, soon. | from a libuv callback into the editor |
| `vim.fs`, `vim.json`, `vim.text`, `vim.lsp`, `vim.ui`, `vim.filetype` | Utilities. | `vim.json.decode(line)`, `vim.text.diff(a, b)` |

Some habits that save time:

- **Numbers are handles.** Buffers, windows and tabpages are integers. `0` usually means
  "current". Always check validity (`nvim_buf_is_valid`, `nvim_win_is_valid`) in callbacks
  that run later — the user may have closed things.
- **`vim.bo[buf].x`** only works for buffer options, **`vim.wo[win].x`** for window options.
  Some options are *global-local* (see [§14](#14-traps-we-fell-into)).
- **`vim.fn` returns Vimscript types**: 0/1 for booleans, `''` for "nothing".
  `vim.fn.executable(x) == 1`, not `if vim.fn.executable(x) then`.
- **Type annotations** (`---@param`, `---@class`) are read by lua-language-server; this
  codebase uses them throughout. They're comments — they cost nothing at runtime.

## 4. Buffers, windows and tabs

A **buffer** is text (usually a file). A **window** shows a buffer. A **tabpage** is a set of
windows. One buffer can be in several windows; closing a window doesn't delete its buffer
(unless `bufhidden=wipe`).

**Scratch buffers** hold plugin UI (a tree view, a panel, a popup):

```lua
local buf = vim.api.nvim_create_buf(false, true)   -- unlisted, scratch
vim.bo[buf].bufhidden = 'wipe'                       -- deleted when no window shows it
vim.bo[buf].buftype = 'nofile'                       -- not a file: :w does nothing
vim.bo[buf].modifiable = false                       -- flip to true while you write to it
```

Useful `buftype` values: `nofile` (plugin UI), `acwrite` (writing runs your `BufWriteCmd`
— used for editable specs), `prompt`, `terminal`.

**Virtual files via URIs.** A plugin can own a URI scheme. Register a `BufReadCmd` for the
pattern and fill the buffer yourself when it's opened. This plugin serves any depot revision
as `perforated:////depot/path/file.c#3` (see `uri.lua`): `:e` that name and the plugin runs
`p4 print` asynchronously and fills the buffer when the content arrives.

**Reading and writing lines** is `nvim_buf_get_lines` / `nvim_buf_set_lines` (0-based,
end-exclusive, `-1` = end). One `set_lines` call with the whole content is much faster than
many small ones — except when only a few lines change, where targeted calls win (the
time-lapse view does exactly that; see [§19](#views-timelapselua)).

## 5. Autocommands and events

Autocommands run a callback when an event fires (`BufReadPost`, `BufEnter`, `CursorMoved`,
`WinClosed`, `FocusGained`, …):

```lua
local group = vim.api.nvim_create_augroup('perforated.buffer', { clear = true })
vim.api.nvim_create_autocmd('BufWipeout', {
  group = group,                           -- always use a group: clearable, no duplicates
  callback = function(ev) M.detach(ev.buf) end,
})
```

- **Groups** make autocommands idempotent (`clear = true`) and removable.
- **Buffer-local autocommands** (`buffer = buf`) are deleted with the buffer.
- **One global autocommand that looks up state** is cheaper than one per buffer. This
  plugin installs `FileChangedRO`, `BufWritePre` etc. once and checks
  `require('perforated.buffer').get(ev.buf)` inside.
- **`User` events** are your plugin's own events for others to hook:
  `vim.api.nvim_exec_autocmds('User', { pattern = 'PerforatedStatus', data = {...} })`.
- **Autocommands don't nest by default**: an event triggered *from inside* another
  autocommand's callback does not run its handlers unless the outer one has `nested = true`.
  This caused blank diff panes here once (`BufReadCmd` didn't fire from a `CursorMoved`
  callback) — see [§14](#14-traps-we-fell-into).

## 6. Commands and keymaps

**User commands:**

```lua
vim.api.nvim_create_user_command('P4', function(o)
  require('perforated.commands').run(o)    -- o.fargs, o.bang, o.range, ...
end, { nargs = '*', bang = true, complete = function(arglead, cmdline, pos) ... end })
```

This plugin has a single `:P4 <sub>` dispatcher plus flat aliases (`:P4edit`). Creating ~40
commands at startup was most of `plugin/`'s cost, so the aliases are created on first use via
the `CmdUndefined` event.

**`<Plug>` mappings** are the polite way to offer keys: define `<Plug>(perforated-diff)` and
let users bind their own keys to it. Only install default mappings when asked
(`keymaps = 'default'` here), and only in the buffers they apply to.

**Buffer-local mappings** for your own UI buffers: `vim.keymap.set('n', 'q', fn, { buffer =
buf, nowait = true })`. `nowait` makes a key fire immediately even if a longer mapping starts
with it — *but only against global mappings*; see [§14](#14-traps-we-fell-into).

## 7. Highlights, extmarks and decorations

**Highlight groups:** define your own names and link them to standard ones, with `default =
true`, so colorschemes and users can override them:

```lua
vim.api.nvim_set_hl(0, 'PerforatedModified', { link = 'Changed', default = true })
```

Re-apply them on `ColorScheme` (colorschemes clear highlights). This plugin keeps all links in
`hl.lua`.

**Namespaces and extmarks.** An extmark is a mark on a buffer position that moves with edits
and can carry decorations: a highlight over a range, a sign in the gutter, virtual text at the
end of a line or inline, virtual lines above/below, a whole-line highlight.

```lua
local ns = vim.api.nvim_create_namespace('perforated.signs')
vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
  end_row = row + count - 1,                -- one extmark spans a whole hunk
  sign_text = '▎', sign_hl_group = 'PerforatedAdd',
})
vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
```

Uses in this codebase: gutter signs (`signs.lua`), current-line blame (`virt_text`), deleted
lines in time-lapse (`virt_lines`), the diff-tab panel, the slider.

**Decoration providers** are the performance tool: instead of creating an extmark per row up
front (which costs time proportional to the whole list), register a provider that adds
*ephemeral* extmarks only for the rows being drawn. The tree view and the annotate column do
this, so a 5000-row list or a 20k-line annotation renders in a few milliseconds.

## 8. Floats, splits, winbars and statuslines

**Floating windows** (`nvim_open_win(buf, enter, { relative = 'editor', row, col, width,
height, border = 'rounded', title = ' X ' })`) are for popups and menus. `focusable = false`
for ones the cursor should never enter (toasts, the key footer).

**Splits** can also be created with `nvim_open_win`: `{ split = 'right', win = w, width = 50 }`
returns the new window id directly. Prefer that over `vim.cmd('split')` followed by guessing
which window is new.

**Statusline / winbar / tabline** are option strings with `%` items (`%#Group#` switches
highlight, `%=` aligns right). A statusline plugin (lualine) usually owns them; offer a
component or a function (`require('perforated').statusline()`) instead of setting them.

`winbar` and `statusline` are **global-local**: an empty window-local value means "use the
global one". You can't turn off a global winbar for one window by setting `''`.

## 9. Asynchronous work: never block the editor

Neovim runs your Lua on its main thread. Anything slow you do there freezes the editor. The
tools:

- **`vim.system(argv, opts, on_exit)`** runs a process without blocking. `stdout = function(err,
  chunk)` streams output. Callbacks run in a *fast* libuv context where most Neovim API calls
  are not allowed — wrap editor work in `vim.schedule(function() ... end)` (or
  `vim.schedule_wrap`).
- **Timers**: `local t = vim.uv.new_timer(); t:start(ms, repeat_ms, vim.schedule_wrap(fn))`.
  Stop and close timers you own.
- **Threads**: `vim.uv.new_work` runs pure Lua (no Neovim API) on a worker thread. The diff
  engine uses it for large files.
- **Coroutines** can make callback chains read sequentially (`core/async.lua`); this codebase
  mostly uses plain callbacks.
- **`vim.wait(ms, cond)`** processes events while waiting — acceptable in short, bounded
  cases (the check-out waits for an in-flight `p4 edit` before a write), never as a general
  tool.

Rules this plugin follows:

1. Never run `p4` synchronously; never use a shell.
2. Every callback that touches the UI checks that its buffer/window still exists.
3. Results that may arrive late carry a generation number or token so stale ones are
   dropped (`buffer.update` does this with `st.gen`).

## 10. Configuration conventions

Two common styles, both supported here:

- **`require('plugin').setup({ ... })`** — explicit, called from the user's config.
  lazy.nvim's `opts = { ... }` calls it for you.
- **`vim.g.plugin = { ... }`** — no call needed, works before the plugin loads.

Read configuration **lazily** (on first use) and merge it over defaults with
`vim.tbl_deep_extend('force', defaults, user)`. Don't make `setup()` mandatory. Report
unknown keys in `:checkhealth` (catches typos). All of this lives in `config.lua`.

## 11. Help files, health checks and integrations

- **Help**: `doc/<name>.txt` in vimdoc format (`*tag*` targets, `|link|`s). This plugin
  *generates* it from the code (commands, key tables, defaults) with `make doc`, and a test
  fails when it's stale.
- **Health**: a module `lua/<name>/health.lua` with a `check()` function is run by
  `:checkhealth <name>`. Use `vim.health.ok/warn/error/info`. Check the things users get
  wrong: binaries on `PATH`, environment, server reachability, config typos.
- **Integrations**: detect optional plugins without loading them (e.g. check for their files
  on the runtimepath), and degrade gracefully (`picker/init.lua` tries telescope, fzf-lua,
  snacks, mini.pick, then `vim.ui.select`).

## 12. Performance: startup, memory, rendering

- **Startup**: keep `plugin/` minimal; measure with `nvim --startuptime`.
- **Dormancy**: if your plugin only matters in some directories or filetypes, decide that as
  cheaply as possible and remove your autocommands otherwise.
- **Memory**: avoid per-buffer closures and tables that never shrink. Clear per-buffer state
  on `BufWipeout`. `collectgarbage('count')` in a test tells you if memory comes back.
- **Rendering**: one `set_lines` per update; highlights for visible rows only; avoid calling
  `vim.fn` in hot loops (each call crosses into Vimscript).
- **Measure**: `vim.uv.hrtime()` around the code; take the *best* of several runs to filter
  out noise.

## 13. Testing a plugin

The practical approach, used here: **drive a real Neovim from tests**.

- [mini.test](https://github.com/nvim-mini/mini.nvim) runs test files and can spawn *child*
  Neovim processes (`MiniTest.new_child_neovim()`) that you control over RPC:
  `child.cmd('edit x')`, `child.type_keys('gy')`, `child.lua_get('some.expression')`.
- Tests run headless (`nvim --headless`), so they run in CI.
- For external programs, provide fakes (a script on `PATH`) or real test servers.

Part II's [§23](#23-testing) shows how this repository does it.

## 14. Traps we fell into

Every one of these cost at least one bug report. Read them once.

| Trap | What happens | What to do |
|---|---|---|
| Autocommands don't nest | `bufload()` from inside a `CursorMoved` callback didn't trigger `BufReadCmd`: empty buffer. | `nested = true` on the outer autocmd, or do the work directly (`uri.buffer` loads content itself). |
| `readonly` buffers warn on change | Filling a read-only buffer (even from the API) shows `W10: Warning: Changing a readonly file`. | Turn `readonly` off while writing, back on after. |
| Global-local options | `vim.wo[w].winbar = ''` doesn't remove a *global* winbar; the window uses the global one. | Give the window its own non-empty value, or budget for the line. |
| `nowait` and buffer-local prefixes | With buffer-local `d` and `dw`, `d` waits `timeoutlen` despite `nowait`. | Avoid buffer-local keys that are prefixes of other buffer-local keys (`gw` instead of `dw`). |
| Tab handles vs numbers | `win_getid(winnr, tabnr)` wants a tab *number*; `nvim_win_get_tabpage` returns a *handle*. They often coincide — until they don't. | Get window ids directly (`nvim_open_win` with `split`). |
| `getcharstr()` blocks RPC | A menu waiting for a key blocks the child Neovim; tests calling `child.lua_get` hang. | In tests, `sleep` then `type_keys`; don't poll the child while it waits for input. |
| `OptionSet` doesn't fire at startup | Option watchers miss the initial values. | Read the initial state explicitly. |
| Removed events | `BufModifiedSet` was removed in Neovim 0.13 (nightly). | Feature-detect: `vim.fn.exists('##BufModifiedSet')`, fall back to `OptionSet` on `modified`. |
| Write-permission check order | Neovim's `E505` (file is read-only) check runs *before* `BufWritePre`, so a plugin can't make the file writable in time. | Make the file writable optimistically when the edit starts (`checkout.lua`). |
| `unpack()` mid-table | `{ a, unpack(t), b }` only includes the *first* value of `t`. | Build lists with `vim.list_extend`. |
| Shadowing builtins | A parameter named `pairs` broke `pairs()` in the same function. | Don't name things after builtins; selene doesn't catch all of these. |
| Version differences | `vim.text.diff` is new; 0.11 has `vim.diff`. `.txt` has no filetype in 0.11. Progress messages need `source` in 0.12. | `(vim.text and vim.text.diff) or vim.diff`; test on the whole version matrix. |
| JSON `level` isn't severity | p4 `{data, level}` messages use `level` for something else (34 for "Diff chunks"). | Only `severity >= 3` is an error. |
| Floats count as windows | `nvim_tabpage_list_wins` includes footer floats. | Filter by `relative == ''`, or count tabs instead. |

---

# Part II — This codebase

## 15. Goals and design principles

perforated.nvim integrates Perforce (Helix Core) into Neovim for people who work in large
workspaces (100k–1M files) on a fast LAN server. The non-negotiables:

1. **Never block the editor.** Every `p4` call is asynchronous; timeouts are enforced; the
   connection state machine makes calls fail fast when the server is unreachable.
2. **Dormant outside Perforce.** Outside a workspace, the only cost is one cached directory
   lookup per new directory; no processes, no timers, a single module loaded
   (`perforated.gate`). If the user isn't a Perforce user at all, even that autocmd is removed.
3. **Batch, never loop.** File arguments go through `p4 -x -` (stdin), fstat is coalesced
   across buffers (30 ms window), status queries cover whole changelists or clients in one
   call. Tests assert call counts ("annotate takes exactly N calls") to prevent N+1
   regressions.
4. **Compute locally.** Gutter diffs, inline diffs, time-lapse revisions and "are these
   identical?" checks run in Neovim (`vim.text.diff`, digests from `fstat -Ol`) instead of
   `p4 diff` per file.
5. **Per-session, in-memory state.** No disk caches; several Neovim sessions on one machine
   don't interfere. Revision content is cached in an LRU keyed by server + immutable
   revision.
6. **The user's environment is sacred.** Internal calls neutralise `P4DIFF`, `P4MERGE`,
   `P4EDITOR` (and unset `P4PAGER`) so nothing can launch a program and hang; anything the user
   *asks* to launch (their diff/merge tool, p4vc) runs with their untouched environment.
   Secrets (`p4 login` input, `P4PASSWD`) never reach logs.
7. **Familiar to P4V users.** P4V's shortcuts are on by default (`<C-d>`, `<C-r>`, `<C-t>`…),
   the time-lapse has a P4V-style slider, and file markers mimic P4V's changed/unchanged
   icons.
8. **Measured.** Budgets for startup, memory and rendering are enforced in CI (`make bench`).

## 16. Repository layout

```
plugin/perforated.lua        startup: :P4 command, lazy aliases, <Plug> maps, BufRead autocmd
lua/perforated/
  init.lua                   public API: setup(), workspace(), statusline()
  config.lua                 defaults, merging, unknown-key detection
  gate.lua                   activation gate: pure-Lua P4CONFIG lookup, dormancy
  commands.lua               :P4 dispatcher, every subcommand, completion
  keymaps.lua                <Plug> actions and the opt-in preset
  health.lua                 :checkhealth perforated
  hl.lua                     highlight groups (default links)
  core/
    activation.lua           gate hit → Workspace; environment-only (P4CLIENT) setups
    workspace.lua            Workspace registry and object: run(), info, idle, caches
    conn.lua                 connection state machine: online/offline/auth, login
    queue.lua                global process queue: concurrency, priorities, dedup, pause
    runner.lua               spawn p4 (vim.system), stream JSON, timeouts, cancel
    parse.lua                -Mj -ztag JSON lines, messages vs records, indexed fields
    env.lua                  P4ENVIRO parsing, child environment, p4 binary
    cache.lua                byte-accounted LRU (revision content)
    log.lua                  ring buffer of p4 invocations (:P4 log)
    debug.lua / debug_impl.lua   debug log front end / implementation, timings
    events.lua               User autocmd events
    async.lua                small coroutine helpers
  p4.lua                     typed p4 wrappers: fstat, print, pending changes, edit/add/revert
  buffer.lua                 per-buffer state, attach pipeline, base text, diff, signs
  signs.lua                  gutter signs, hunk navigation, preview, reset
  status.lua                 statusline variables (never calls p4)
  checkout.lua               check-out on first change, add on write, edit/add/revert
  checkout_prompt.lua        the check-out menu and changelist picker (loaded on first use)
  poll.lua                   stale/unresolved detection (cheap probe, full refresh on news)
  changelists.lua            changelist queries: describe, shelved files, submitted, reopen…
  lists.lua                  quickfix producers: opened files, status, hunks
  uri.lua                    perforated:// buffers (any depot revision)
  diff/
    engine.lua               in-process diff (worker thread for big files) → hunks
    view.lua                 side-by-side diff tab, $P4DIFF launcher, revision specs
    tab.lua                  multi-file diff tab with a file panel
  same.lua                   "are these sides identical?" (digests / p4 diff -sr / content)
  revs.lua                   helpers for comparison sides (spec / path / empty)
  history.lua                filelog, annotate (+cache), Swarm URL
  timelapse.lua              time-lapse engine (annotate -a → every revision in memory)
  blame.lua                  current-line blame
  modified.lua               changed vs unchanged opened files (p4 diff -sa)
  ops.lua                    shelve/unshelve, submit, sync, delete, move, delete changelist
  resolve.lua                resolve -am, then the merge tool
  integrate.lua              cherry-pick a changelist
  tools.lua                  launching the user's tools (P4MERGE…)
  jobs.lua                   long-running jobs: progress, :P4 jobs, :P4 cancel
  lookup.lua                 g/ — go to a changelist, path or user
  p4vc.lua                   P4V escape hatches (revgraph, timelapse, streamgraph)
  lsp.lua                    experimental in-process LSP server for code actions
  timings.lua                :P4 debug timings report
  ui/
    tree.lua                 foldable tree renderer (decoration-provider highlights)
    keys.lua                 action registry: keymaps, . menu, ? help, footer
    footer.lua               key footer float anchored to a window
    float.lua                single-key modal menu
    qf.lua                   quickfix/location-list sink and qf-window keys
    toast.lua                corner notifications (activity- and focus-gated)
    icons.lua                file icons (mini.icons/devicons) and status glyphs
    progress.lua             progress messages (0.12) + final notification
  picker/
    init.lua                 picker abstraction over telescope/fzf-lua/snacks/mini/select
    sources.lua              :P4 pick sources
  views/
    base.lua                 shared scaffolding for tree views
    client.lua               the client view (:P4)
    changes.lua              submitted changelists (:P4 changes)
    change_info.lua          the K popup
    change_editor.lua        changelist description editor
    describe.lua             changelist buffer (:P4 describe)
    history.lua              file history float (:P4 filelog)
    annotate.lua             annotate split (:P4 annotate)
    timelapse.lua            time-lapse view (:P4 timelapse)
    slider.lua               the time-lapse slider window
lua/lualine/components/perforated.lua   lualine component
doc/perforated.txt           :h perforated (generated by make doc)
docs/                        README companions: migrating.md, this guide, plan/design history
scripts/gen_doc.lua          help generator
scripts/dev-workspace.sh     persistent local Perforce sandbox for manual testing
tests/                       mini.test suites, helpers, fake p4 / merge tool / p4vc
bench/run.lua                performance budgets
Makefile                     deps, test, bench, lint, fmt, doc, dev-workspace
.github/workflows/ci.yml     lint + test + bench on Linux/macOS × 0.11/0.12/nightly
```

## 17. Architecture

### 17.1 Layers

```
┌───────────────────────────────────────────────────────────────────────────────┐
│ Entry points      plugin/perforated.lua · commands.lua · keymaps.lua · lsp.lua │
├───────────────────────────────────────────────────────────────────────────────┤
│ Views             views/* (client, describe, history, annotate, time-lapse…)   │
│ UI toolkit        ui/tree · ui/keys · ui/footer · ui/float · ui/qf · ui/toast  │
├───────────────────────────────────────────────────────────────────────────────┤
│ Features          buffer · signs · status · checkout · poll · ops · resolve ·  │
│                   integrate · history · timelapse · blame · modified · same ·  │
│                   diff/* · uri · lists · changelists · jobs                    │
├───────────────────────────────────────────────────────────────────────────────┤
│ p4 wrappers       p4.lua (fstat, print, edit…) · changelists.lua               │
├───────────────────────────────────────────────────────────────────────────────┤
│ Core              workspace ─ conn ─ queue ─ runner ─ parse · env · cache ·    │
│                   log · debug · events                                         │
├───────────────────────────────────────────────────────────────────────────────┤
│ Activation        gate.lua (pure Lua) → core/activation.lua                    │
└───────────────────────────────────────────────────────────────────────────────┘
```

Dependencies point downwards. Views and features never spawn processes themselves; they call
`ws:run()` (directly or through `p4.lua`), which goes through the connection state machine,
the queue and the runner.

### 17.2 The Workspace is the unit of everything

Exactly **one Workspace object exists per Perforce workspace** in a session, keyed by its
*anchor* — the directory containing the `P4CONFIG` file (or the client root for
environment-only setups). Every buffer in that workspace points to the same object
(`vim.b[buf].perforated_ws` holds its key). The Workspace owns:

- `conn` — the connection state machine (online, offline, auth…).
- `info` / `settings` — `p4 info` and `p4 set` results (client, user, root, case handling).
- `fstat` — a cache of fstat records by (case-normalised) local path.
- `clmemo` — changelist metadata learned along the way.
- `sticky_cl` — the changelist chosen last for check-outs (per session).
- a **queue group**, so a login can pause just this workspace's calls.

Every p4 call for the workspace runs with `cwd = PWD = anchor`, so p4 finds the right
`P4CONFIG`. A special **connection** context (no client) handles commands that make sense
outside any workspace (`:P4 describe N`, `:P4 changes`, depot paths).

### 17.3 How a p4 call flows

```
feature ──ws:run(args, opts, cb)──▶ Workspace:run
                                     │ conn:refuse()? → fail fast (offline, cancelled login)
                                     ▼
                                   queue.global():push{ group, priority, key, start, cb }
                                     │ concurrency cap (runner.concurrency, default 4)
                                     │ priorities: interactive 1 > buffer 2 > background 3
                                     │ dedup: same key in flight → share the result
                                     │ paused group (login in progress) → wait
                                     ▼
                                   runner.run{ args, cwd, globals, stdin, timeout, env_mode }
                                     │ vim.system(p4 -Mj -ztag …) ── stdout streamed, JSON lines
                                     │ timeout → SIGTERM, then SIGKILL after 2 s
                                     ▼
                                   parse.classify → { records, warnings, errors }
                                     ▼
                                   conn:observe(res) → 'ok' | 'error' | 'connect' | 'auth'
                                     │ auth → one password prompt (login), then retry
                                     ▼
                                   cb(res)   (on the main loop)
```

### 17.4 Buffers: the attach pipeline

```
BufReadPost ─▶ gate.on_buf ─▶ activation.attach ─▶ bind(ws, buf)
                                                     ├─ ws:attach(buf), ws:ensure_info()
                                                     ├─ buffer.attach(ws, buf)
                                                     │    └─ queue fstat (30 ms batch window)
                                                     └─ poll.start(ws)
fstat batch returns ─▶ buffer.apply(buf, rec)
      status: clean | opened | binary | new | unmanaged
      opened ─▶ load_base: p4 print base revision (cached if immutable)
             ─▶ update: vim.text.diff(base, buffer) → hunks → signs + status
buffer edits ─▶ nvim_buf_attach on_lines ─▶ debounce 100 ms ─▶ update (no p4 call)
```

### 17.5 Views: tree + registry

All list-like views (client view, describe, history, changes) render a **tree**
(`ui/tree.lua`): nodes with `id`, `kind`, `text` chunks, `item` (the domain object) and
optional `children`. Every key in those views comes from an **action registry**
(`ui/keys.lua`): each action has an id, a description, keys, the node kinds it applies to and
a `run` function. The same registry produces the buffer keymaps, the `.` action menu, the `?`
help, the key footer and — via the doc generator — the key tables in `:h perforated`. That's
why keys, menus and help never disagree.

## 18. Walkthroughs: what happens when…

### 18.1 Neovim starts

1. `plugin/perforated.lua` runs: checks the version, creates the `perforated` augroup with one
   `BufReadPost`/`BufNewFile` autocmd, the `:P4` command, a `CmdUndefined` autocmd for the
   `:P4<sub>` aliases, and the `<Plug>(perforated-*)` mappings (cheap string mappings that
   `require` on use).
2. Nothing else loads. `make bench` keeps this under 0.5 ms.

### 18.2 You open a file

1. `gate.on_buf` ignores special buffers (`buftype ~= ''`, URIs). If neither `P4CONFIG` nor
   `P4CLIENT` is set (environment or `P4ENVIRO` file, read in pure Lua), the user isn't a
   Perforce user here: the autocmd is removed for the session (**dormant**).
2. It walks up from the file's directory looking for the `P4CONFIG` file name, caching the
   answer for every directory visited (so the next file in the same tree costs one table
   lookup).
3. On a hit, it checks once that the `p4` binary exists, then calls
   `activation.attach(buf, path, hit)`.
4. `activation` finds or creates the Workspace for the anchor and **binds** the buffer: the
   workspace records the buffer, fetches `p4 set -q` and `p4 info` in the background (once per
   workspace), `buffer.attach` starts the per-buffer pipeline, and `poll.start` begins stale
   detection for the workspace.
5. Environment-only setups (`P4CLIENT` set, no `P4CONFIG` file) need one `p4 info` to learn the
   client root; buffers queue until it answers, then bind if they're under the root.

### 18.3 The buffer gets its status and signs

1. `buffer.attach` records state and queues the path. After 30 ms, **one** `p4 fstat -x -`
   covers every queued buffer of the workspace.
2. `buffer.apply` sets the status: `clean` (in the depot, not opened), `opened` (with an
   action), `binary`, `new` (in the client view but not in the depot), or `unmanaged`.
3. For opened text files, `load_base` prints the base revision (`#have`, or the moved-from
   file for moves) and caches it; `update` diffs it against the buffer and renders one sign
   extmark per hunk.
4. Status variables for statuslines are updated (`status.lua`): `vim.b.perforated_status`,
   `vim.b.perforated_status_dict`, `vim.g.perforated_status`, plus a coalesced
   `User PerforatedStatus` event.
5. Edits re-diff after a 100 ms debounce; big files (above `signs.max_lines`) diff on a worker
   thread; beyond `signs.hard_max` there are no signs at all.

### 18.4 You start typing in an unopened file

1. Files in a `noallwrite` workspace are read-only on disk, so the first change fires
   `FileChangedRO` (for `allwrite` workspaces the plugin watches the `modified` flag instead).
2. `checkout.on_first_change` clears `readonly` (so Vim doesn't show W10), lets the keystroke
   through, and schedules the **check-out menu** (`checkout_prompt.lua`): `<CR>` the sticky or
   default changelist, `c` pick one, `n` new, `A` always, `s` skip, `S` never. Keys typed
   during the first 300 ms (`checkout.prompt_grace`) are treated as typing, not choices, and
   replayed.
3. The choice runs `p4 edit` asynchronously. If you `:w` while it's in flight, `BufWritePre`
   waits (bounded) for it. The file is made writable optimistically because Neovim checks
   write permission before any write autocmd runs.
4. `FileChangedShell` for a mode-only change (p4 flipped the permission bit) is silenced.

### 18.5 A server outage

1. A call fails to connect (or times out). `conn.classify` returns `'connect'`; the state goes
   `offline` and a background probe (`p4 -ztag info -s`) runs with exponential backoff (5 s →
   5 min).
2. While offline, `ws:run` refuses new calls immediately with a clear message, instead of
   letting each one wait for a timeout.
3. When a probe succeeds the state returns to `online`.
4. An authentication error pauses the workspace's queue group, shows **one** password prompt,
   runs `p4 login` with the password on stdin (never logged), resumes the group and retries
   the waiting calls. A `login_pending` flag and a login epoch make sure concurrent failures
   produce one prompt, not several.

### 18.6 Stale files

1. `poll.probe` runs `p4 changes -m1 -s submitted <opened + loaded files>` — one indexed query
   — on a timer while Neovim is focused (default 5 minutes), on `FocusGained` (throttled) and
   when entering a Perforce buffer (throttled).
2. Only when it reports a newer changelist than last time does `poll.refresh` run the full
   `fstat -Ro //client/...` over opened files, update buffers and statuslines, and raise a
   toast for newly stale files.

### 18.7 You open the client view (`:P4`)

1. `views/client.lua` opens a tab (or float/split), paints a skeleton instantly, then runs one
   parallel round: pending changelists, `fstat` of opened files, submitted changelists, the
   Sync CL (`changes -m1 //client/...#have`), and `p4 diff -sa` (which opened files changed).
   A second round fetches shelved files only for changelists that have them.
2. `build()` turns the data into tree nodes; the tree renders with one `set_lines`.
3. The reconcile section scans (`p4 status`) only when expanded, as a job you can stop.
4. Any `User PerforatedChanged` event (check-out, revert, submit…) refreshes a visible view.

### 18.8 You step through a time-lapse

1. `timelapse.load` runs `filelog -l` (revision metadata) and `annotate -a` of the newest
   revision with content: every line the file ever had, in order, with its revision range.
2. Revision N is the lines with `lower ≤ N ≤ upper`. A step computes, in one pass, the buffer
   edits between the two revisions, where the cursor goes and which lines were added or
   removed — then applies only those edits (a few `set_lines` calls). About 2 ms for a 20k-line
   file with 200 revisions.

## 19. Module reference

This section goes through every module. For exact signatures, read the `---@` annotations at
the top of each function; this reference explains roles and non-obvious behaviour.

### Entry points

#### `plugin/perforated.lua`
Startup file. Defines the `perforated` augroup with the `BufReadPost`/`BufNewFile` → gate
autocmd; the `:P4` command (with completion); a `CmdUndefined` autocmd that creates `:P4<sub>`
aliases on first use (the list of subcommands `subs` must match `commands.lua`; a test enforces
it); and `<Plug>(perforated-<name>)` mappings that call `require('perforated.keymaps').run()`.
If loaded after startup, runs the gate for buffers already open.

#### `init.lua`
The small public API: `setup(opts)` (optional; merges into config), `workspace(buf)` (the
Workspace of a buffer) and `statusline()` (reads cached variables only).

#### `commands.lua`
The table `M.commands` maps each subcommand to `{ scope, desc, run, complete }`. `scope`
decides the context: `'none'` (no Perforce needed: log, debug, jobs), `'workspace'` (refused
outside a workspace) or `'connection'` (uses the workspace if there is one, else the
connection context). `M.resolve(scope, cb)` finds the context: the current buffer's workspace,
the workspace of the file's or cwd's directory (through activation, including env-only
setups), or the connection context. `parse_file_args` handles `-c CL` and file arguments
(default: the current file). `M.names()` feeds completion and the doc generator; each `desc`
becomes the command's entry in `:h perforated`.

#### `keymaps.lua`
`M.actions` maps `<Plug>` names to functions (mostly `:P4` subcommands). `M.PRESET` is the
opt-in `<leader>p…` preset; `M.attach(buf)` installs it in Perforce buffers when
`keymaps = 'default'`, never overriding the user's own buffer-local mappings.

#### `health.lua`
`:checkhealth perforated`: Neovim version, `p4` binary and version, `P4CONFIG`/`P4ENVIRO`,
`P4DIFF`/`P4MERGE`, p4vc, per-workspace server checks (reachability, latency, login state),
config typos (`config.unknown_keys()`), debug log, integrations (pickers, icons), and terminal
focus events (tmux `focus-events`, needed for `FocusGained` polling).

### Configuration and activation

#### `config.lua`
Defaults in one table (every key documented inline — the doc generator dumps it). `get()`
merges `vim.g.perforated` and `setup()` options over defaults on first use and caches the
result; `set()` merges more (tests use it); `reload()` re-reads `vim.g.perforated`;
`unknown_keys()` lists user keys that don't exist in the defaults (for `:checkhealth`).

#### `gate.lua`
The only module loaded outside Perforce. `config_name()` reads `P4CONFIG` from the environment
or the `P4ENVIRO` file (`p4 set` storage) in plain Lua; `env_client()` does the same for
`P4CLIENT`. `lookup(dir)` walks up with `fs_stat` looking for the `P4CONFIG` file and caches
the result for every directory on the way. `on_buf(ev)` is the autocmd handler described in
[§18.2](#182-you-open-a-file); it removes the plugin's autocmds when the user isn't a Perforce
user or `p4` is missing.

#### `core/activation.lua`
Turns gate hits into Workspaces (`config_ws`) and binds buffers (`bind`). Handles
environment-only setups: a single background `p4 info` from the file's directory (state
`unknown → pending → ready | none`), queuing buffers until it answers. `for_dir(dir)` and
`resolve(dir, cb)` give the Workspace for a directory (used by commands and quickfix entries).

### Core

#### `core/workspace.lua`
The registry (`get_or_create`, `get`, `list`, `for_buf`, `current`, `connection`) and the
Workspace class:

- `run(args, opts, cb)` — the one way to run p4 for a workspace ([§17.3](#173-how-a-p4-call-flows)).
  Options: `priority`, `key` (dedup), `tagged` (default JSON), `stdin`, `timeout` (0 = none),
  `env_mode` (`'user'` for calls that may launch programs), `globals` (e.g. `-x -`), `probe`
  (skip the offline gate), `force` (run while the group is paused — login), `on_record` /
  `on_spawn` (streaming and cancellation for jobs), `cwd` (connection context only). It also
  implements the stale-auth retry: an auth failure from a call that started before a
  successful login is retried quietly instead of prompting again.
- `ensure_info(cb)` — `p4 set -q` (local, run with the user's environment) and `p4 info`,
  once per workspace, shared by concurrent callers.
- `_set_info(rec)` — learns client, root and case handling. When the server is
  case-insensitive (the macOS default), cache keys are lower-cased and buffers attached
  before `info` answered are re-keyed (`buffer.rekey`).
- `client()`, `user()`, `server_key()`, `cwd()`.
- `attach(buf)` / `M.detach(buf)` and `_maybe_idle()` — when no buffer uses a workspace and
  cwd is outside it, heavy state (fstat cache, CL memo, connection timers) is freed; the
  object stays registered and wakes up on demand.

`for_buf(buf)` also honours `vim.b[buf].perforated_ws`, so plugin buffers (views,
`perforated://` revisions) resolve to the workspace they belong to.

#### `core/conn.lua`
The connection state machine (diagram in the file header). `classify(res)` maps a result to
`'ok' | 'auth' | 'connect' | 'error'` by matching known p4 messages. `observe(res)` updates the
state (a server-side *error* still proves the server is reachable). `refuse()` returns a
reason to fail fast (offline, cancelled login). `need_auth(retry)` coordinates a single login
per workspace: queue group paused, `login_pending` set, one `inputsecret` prompt, `p4 login`
via stdin, `epoch` bumped on success, waiters retried. `probe()` and the backoff timer handle
recovery from offline.

#### `core/queue.lua`
A global queue of process jobs: `cap` concurrent jobs (config `runner.concurrency`),
three priority FIFOs (`interactive`, `buffer`, `background`), in-flight de-duplication by
`key` (a second identical request shares the first one's result), and per-group
`pause`/`resume` (a login pauses its workspace only). `pending_count()` is used by tests.

#### `core/runner.lua`
`run(spec, cb)` spawns p4 with `vim.system` — no shell, argument list only. Tagged calls add
`-Mj -ztag` and decode JSON lines incrementally in the stdout callback
(`parse.line_splitter`). It enforces timeouts (SIGTERM at the deadline, SIGKILL 2 s later),
supports cancellation (`on_spawn` receives `{ cancel = fn }`) and streaming (`on_record`
receives each record, in a fast context — plain Lua only). Every call is recorded in
`core/log` (argv, cwd, duration, outcome) and, when debugging, in the debug log.

#### `core/parse.lua`
p4 output parsers. `json_line` decodes one `-Mj` line; `classify` splits records from
messages (a message has `severity`+`generic`, or `data`+`level` only); only `severity >= 3`
counts as an error. `indexed(rec, names)` unfolds p4's numbered fields (`rev0, change0, rev1…`
and two-level `how0,1`) into arrays. `jsonl` parses a whole output at once; `ztag` is a
fallback parser for the plain `-ztag` text format.

#### `core/env.lua`
`enviro()` parses the `P4ENVIRO` file; `get(name)` reads a p4 setting from the environment or
that file; `config_name()`, `has_env_client()`; `child_env(cwd, mode)` builds the child
environment (`PWD = cwd`; internal mode neutralises `P4DIFF`/`P4MERGE`/`P4EDITOR` and unsets
`P4PAGER`); `p4_bin()` resolves the configured binary.

#### `core/cache.lua`
`lru(max_bytes)` — a doubly-linked, byte-accounted LRU. `content()` is the session-wide cache
of revision content (`<server>|<depotFile>#<rev>`, only for immutable numbered revisions),
sized by `cache.content_mb`.

#### `core/log.lua`
A ring buffer (size `log.size`) of every p4 invocation, shown by `:P4 log` and aggregated by
`:P4 debug timings`.

#### `core/debug.lua` and `core/debug_impl.lua`
The front end is tiny because everything on the activation path requires it: while debugging
is off, `dbg.log()` is a boolean check. The implementation (buffered writes every 250 ms,
rotation, snapshots, redaction of secrets) loads only when enabled (config, `PERFORATED_DEBUG`
env, or `:P4 debug on`). `dbg.timing(name, ms)` keeps fixed-size aggregates for
`:P4 debug timings` and is always on (one table update).

#### `core/events.lua`, `core/async.lua`
`emit(name, data)` fires `User Perforated<Name>` (scheduled if called from a fast context).
`async.lua` has small coroutine helpers (`run`, `await`, `all`, `debounce`,
`throttle_by_key`) for flows that read better sequentially.

### p4 wrappers

#### `p4.lua`
Typed wrappers returning parsed data. `key(ws, path)` is the cache key (lower-cased on
case-insensitive servers). `fstat(ws, paths)` batches local paths through `-x -` and returns
records by key plus "missing" reasons (not in view / no such file) per path.
`fstat_opened(ws)` is `fstat -Ro //client/...`. `base_spec(rec)` decides the diff base (`#have`,
or the moved-from file). `print(ws, spec)` returns lines, cached when immutable;
`print_many` prints several specs in one call. `pending_changes`, `new_change`, `edit`, `add`,
`revert` (all through `-x -`) and `latest_changes` (the poll probe).

#### `changelists.lua`
Changelist queries used by views and operations: `describe` (files, optionally shelved),
`shelved_files`, `submitted_changes` (paged, scoped to the client by default),
`have_change` (the Sync CL), `status` (`p4 status` for reconcile, with job options),
`reopen`, `opened_by_user` (the "all my clients" scope), `change_status`, and the change spec
helpers used by the description editor (`change_spec`, `save_spec`, `spec_get_description`,
`spec_set_description`).

### Buffers, signs, status

#### `buffer.lua`
Per-buffer state (`BufState`, [§20](#20-data-model)) and the pipeline in
[§18.3](#183-the-buffer-gets-its-status-and-signs). Notable details: `ATTACH_CALLBACKS` is one
shared table for `nvim_buf_attach` (no closures per buffer); stale async diff results are
dropped by generation; `detach` drops the cached fstat of a file that's no longer shown and
isn't opened (found by the memory soak test); `rekey` recomputes keys after the case-handling
is learned; when enabled, blame and the LSP code-action server attach here.

#### `signs.lua`
`render(buf, hunks)` — one extmark per hunk with `end_row` spreading the sign over the
range. `render_stale` puts a "stale" marker on line 1. `nav` (`]h`/`[h`), `preview` (a float
with the hunk's unified diff) and `reset` (replace the hunk with the base lines).

#### `status.lua`
Statusline data only — never calls p4. `update(buf)` fills `vim.b.perforated_status_dict`
(status, action, change, have/head, stale, unresolved, added/changed/removed counts, connection)
and a ready-made `vim.b.perforated_status` string; `update_ws` fills `vim.g.perforated_status`
(workspace markers: stale / unresolved counts, offline). Changes are coalesced into one
`User PerforatedStatus` event and a statusline redraw. `is_stale(rec)` is used everywhere.

#### `checkout.lua` and `checkout_prompt.lua`
The check-out flow in [§18.4](#184-you-start-typing-in-an-unopened-file), add-on-write
(`checkout.add_on_write`), and the `edit`/`add`/`revert` operations used by every view and
command (each reports errors, refreshes affected buffers and emits `Changed`). Global hooks
are installed once and look up tracked buffers. `checkout.dirs` restricts automatic
behaviour to some directories. The prompt and changelist picker live in `checkout_prompt.lua`
so the activation path doesn't load UI code.

#### `poll.lua`
Stale/unresolved detection ([§18.6](#186-stale-files)). `refresh(ws)` also keeps the fstat
cache honest (drops entries of files no longer opened) and pushes fresh records into loaded
buffers. The per-buffer `BufEnter` throttle table is cleaned on `BufWipeout` (another soak
test finding).

#### `modified.lua`
"Changed vs unchanged" for opened files: `query(ws, paths)` runs `p4 diff -sa` (p4 compares
locally); `overlay(ws)` uses loaded buffers' own diff state for unsaved edits; `is_changed`
combines them (adds/deletes/moves always count as changed); `marker(changed)` returns the `●`
chunk and the row highlight.

#### `blame.lua`
Current-line blame: a debounced `CursorMoved` handler reads the annotation of the file's
revision (cached by `history.annotate`), maps the cursor line to the base line through the
buffer's hunks (`views/base.base_line`), and shows `CL {change} • {user} • {date} • {desc}`
as end-of-line virtual text.

### Diffs and revisions

#### `uri.lua`
`perforated://<depot spec>` buffers. `buffer(ws, spec)` creates or reuses the buffer and
loads it directly (not relying on `BufReadCmd`, which doesn't fire inside other
autocommands); `read(buf)` fills it asynchronously via `p4.print`, sets the filetype from the
depot path, keeps the buffer read-only (with `readonly` off while writing, to avoid W10) and
refreshes diff mode in windows showing it.

#### `diff/engine.lua`
In-process diffs: `hunks(base, cur)` via `vim.text.diff` (`result_type = 'indices'`, myers +
indent heuristic), `hunks_async` on a worker thread for big inputs, `to_hunks` normalising
into `{ type, a_start, a_count, b_start, b_count }`, `summary` (added/changed/removed counts).

#### `diff/view.lua`
`:P4 diff`: `resolve_spec(rec, rev)` understands `#N`, `#head`, `@CL`, `@=CL` (shelved) and
`prev`; `pair(ws, left, right)` opens a native side-by-side diff in a tab (`q` closes, fires
`User PerforatedDiffOpen/Close`); `external` launches the user's `$P4DIFF` with their
environment (a terminal tab for terminal tools, detached for GUI tools). Identical sides give
a message instead (`same.lua`).

#### `diff/tab.lua`
The multi-file diff tab: a file panel plus a native diff pair; files load when selected (the
next one is prefetched); `<Tab>`/`<S-Tab>` step files. Before opening, every pair is checked
with `same.check`: identical files go to an "Identical (N):" section; if all are identical,
the tab doesn't open. Sources: `open_change` (pending, shelved, submitted), `open_opened`
(`:P4 diff -a`), `open_shelf_vs_workspace`.

#### `same.lua`
`check(ws, pairs, cb)` answers "identical?" for many pairs, cheaply: depot-vs-depot by digest
(one `fstat -Ol` for all specs), opened-file-vs-its-base by `p4 diff -sr` (one call), and
only otherwise by content. `or_open(ws, left, right, open)` either says "identical" or opens.

#### `revs.lua`
Helpers for comparison sides (`{ spec }`, `{ path }`, `{ empty }`): `lines` (content),
`diff` (identical-check, then a diff pair), `open` (a revision or file in a new tab), `where`
(depot → workspace paths in one call), `unified` (unified diff lines for inline diffs).

### History, annotate, time-lapse

#### `history.lua`
`filelog(ws, path, opts)` (paged, follows branches with `-i`, returns flat revision records
including the "branched from" source), `annotate(ws, spec, opts)` (`annotate -c -i -u -q`: one
call gives each line's changelist, user and date; with `descriptions = true` it also runs
`filelog -l -i` for descriptions; results for numbered revisions are cached, 8 entries, with
in-flight sharing), and the Swarm URL (`swarm.url` or the `P4.Swarm.URL` server property)
with `swarm(ws, change, copy)`.

#### `timelapse.lua`
The time-lapse engine ([§18.8](#188-you-step-through-a-time-lapse)): `load` (filelog +
`annotate -a`, size guard `timelapse.max_bytes`), `parse` (entries `{ text, lo, hi }`,
joining chunked long lines), `revision(tl, n)` (lines and entry indices, LRU of 8),
`changes(tl, n)` (added lines and deleted lines grouped by where they'd sit), `range(tl, a, b)`
(for range mode), `transition(tl, from, to, lnum)` (buffer edits + cursor anchor + changes in
one pass), `anchor`, `step`.

### Operations

#### `ops.lua`
Shelve (`shelve -f`, confirmation before replacing), delete shelved files, unshelve (into the
shelf's own changelist when it's yours, else a picked one; `-f` only after confirming),
submit (a confirmation float with warnings about stale/unresolved/shelved files; failures to
quickfix), sync (confirmation with an on-request **Preview** via `sync -n`; runs as a job;
reloads unmodified buffers without prompts; afterwards every unresolved file goes to quickfix
and a menu offers to resolve now), sync to a changelist and its picker, delete (closes the
buffer), move (renames the buffer and keeps unsaved edits), delete a pending changelist
(moving or reverting its files and deleting its shelf first). Messages of the form
`<file> - <reason>` become quickfix items (`file_items`).

#### `resolve.lua`
`run(ws, paths)`: `resolve -am` (p4 takes clean merges), then `resolve -n -o` to find the
remaining conflicts; for each content conflict, base and theirs are printed to temp files and
the merge tool (`merge.tool` or `$P4MERGE`) runs as `tool base theirs yours merged`; exit 0
with a changed result → written through the buffer and accepted with `resolve -ay`.
Everything else goes to quickfix, where `R` retries. No merge logic in the plugin.

#### `integrate.lua`
Cherry-pick: the source is the changelist's common directory; the target is a path or
`-b branch` (remembered per session); preview (`integrate -n`) to quickfix, confirm,
integrate, then resolve. Without a changelist, pick one from a source path's history.

#### `jobs.lua`, `ui/progress.lua`
Long-running operations register as jobs: a progress message that updates twice a second
(file count, last file, elapsed), `:P4 jobs` (a live float; `x` stops a job) and
`:P4 cancel`. `start(ws, title)` returns run options (`timeout = 0`, `on_spawn`, `on_record`)
to pass to `ws:run`. Progress uses Neovim 0.12's progress messages (with `source`) while
running, and always ends with a normal notification.

#### `tools.lua`, `p4vc.lua`, `lookup.lua`
`tools` reads settings like `P4MERGE` the way p4 does (`p4 set -q`) and launches the user's
tools with their environment (terminal tab or detached GUI). `p4vc` offers the revision graph,
P4V's time-lapse and the stream graph when `p4vc` is installed, plus registry actions for
views. `lookup` (`g/`) routes a number to describe, a path to history, a bare word to a
user's changelists.

### UI toolkit

#### `ui/tree.lua`
The tree renderer. `set(roots)` replaces content; `render()` walks visible nodes (fold state is
tree state by node id, not Vim folds), builds all lines and one `set_lines`, keeps the cursor
on the same node, and records per-row highlight ranges that a **decoration provider** turns
into ephemeral extmarks for visible rows only. Prefixes (indent + `▸`/`▾` + mark) are built
once per distinct combination. `on_open` supports lazy children (inline diffs, reconcile).
Also: `node_at`, `row_of`, `open`/`close`/`toggle`, `collapse_at_cursor`, `jump_section`
(skipping spacer rows), marks for multi-item actions.

#### `ui/keys.lua`
The action registry ([§17.5](#175-views-tree--registry)). `keys_of(action)` applies user
overrides (`keys = { <id> = {...} | false }`, `keys.p4v = false`). `applies(action, node)`
checks `kinds` and `when`. `attach(buf, actions, view)` creates one raw keymap per key (raw
`nvim_buf_set_keymap` is faster than `vim.keymap.set`); keys shared by several actions
dispatch to the first that applies to the node under the cursor (so `x` reverts a file but
stops a reconcile scan). `menu` (the `.` menu), `help` (`?`), `footer` (chunks for the key
footer).

#### `ui/footer.lua`
A one-line, non-focusable float anchored to the bottom of a view window, updated on cursor
moves (per-window statuslines are hidden with `laststatus=3`, so a float is used instead).

#### `ui/float.lua`
`menu(opts)` — a single-key modal menu that waits with `getcharstr()` (events keep
processing). Supports multi-key choices (`gY`: a prefix waits for the rest) and a *grace
period* during which keys are captured for replay (for the check-out prompt, which can pop up
mid-typing).

#### `ui/qf.lua`
The quickfix sink: `set(spec)` makes one `setqflist` call with a title and a
`context = { perforated = true, kind }`; entries carry `user_data`; a `quickfixtextfunc`
aligns columns; perforated lists get buffer-local keys in the qf window (`d` diff, `x` revert,
`M` move, `R` resolve, `gr` re-run the producer) plus syntax for the changed-file markers.

#### `ui/toast.lua`
Corner notifications for stale files: bottom-right, non-focusable, stacking; the dismissal
countdown starts at the user's first keypress (so a toast can't vanish unseen), toasts raised
while unfocused wait for `FocusGained`; history for `:P4 notifications`.

#### `ui/icons.lua`
File icons from mini.icons or nvim-web-devicons (detected via runtime files, without loading
them) and status glyphs in Nerd Font or ASCII style (overridable via `icons.glyphs`).

### Pickers

#### `picker/init.lua`, `picker/sources.lua`
`pick({ title, items, format, preview, multi, on_choice })` over telescope, fzf-lua,
snacks.picker, mini.pick or `vim.ui.select` (auto-detected, or `picker = '…'`); `once()`
guarantees `on_choice` runs exactly once, even with backends that report cancel and choice
in odd orders. Sources for `:P4 pick {pending|opened|submitted|users}`.

### Views

#### `views/base.lua`
Shared scaffolding: `tab(name)` / `float(name, title)` create the window and scratch buffer;
`nav(view, title)` returns the standard navigation actions (fold, refresh, close, help, menu);
`finish(view)` attaches keys, the footer (or a float's own footer line) and sets the filetype
after the first paint; `date`, `first_line`; `base_line(hunks, lnum)` maps a buffer line to
its base line through hunks (used by annotate and blame).

#### `views/client.lua` (the biggest module)
The client view ([§18.7](#187-you-open-the-client-view-p4)). `file_node` renders a file row
(action, icon, path, `#have/#head`, stale/unresolved badges, the `●`/dimmed changed marker,
and in "Needs attention" the changelist). `build(view, data)` assembles the sections: header,
Sync CL, Pending (per changelist, with shelves), Needs attention, Workspace reconcile (lazy,
scoped by `client_view.reconcile.paths` or `p`, runs as a job), Recent submitted, with blank
spacer rows between sections. `refresh(view)` runs the parallel round (coalescing refreshes:
one in flight, one queued). `actions(view)` defines every key of the view. A `BufWritePost`
hook updates one file's changed marker; a `PerforatedChanged` hook refreshes the visible view.

#### `views/describe.lua`
`:P4 describe N`: header, description, files and shelved files; `<Tab>` expands a file's
unified diff inline (two prints, computed only when expanded; files above 20k lines say "use
`d`"). Pending changelists of this client diff against the workspace file; shelved files
against their base (`w` workspace, `gh` head). Actions include submit, delete, integrate,
sync-to-CL, Swarm, quickfix of the files.

#### `views/history.lua`
`:P4 filelog`: a float listing revisions (with a "branched from" section), paged (`gn` or
reaching the end), `<CR>` opens the action menu; `rev_actions(ctx)` is shared with the picker
and quickfix presenters (`history.presenter`). A directory's history is its changelists.

#### `views/annotate.lua`
`:P4 annotate`: a scroll- and cursor-bound split left of the file with the changelist, user
and date on every line, coloured by age (`PerforatedAge1..10`, a gradient derived from
`Comment` → `DiagnosticWarn` or `annotate.gradient`). Local edits show "Not submitted"
(mapped through the buffer's hunks). `~` re-annotates the revision before the line's change
(following a branch back to its source), `<BS>` returns; `d` diffs that change; `Q` lists the
lines from that changelist. Highlights come from a decoration provider.

#### `views/timelapse.lua` and `views/slider.lua`
The time-lapse view: a read-only buffer with the file's filetype, stepping with incremental
buffer edits; decorations for added lines (`line_hl_group`), deleted lines (`virt_lines`), an
optional age gutter; modes *single*, *incremental diff* (a left window with revision ◆,
diffed against ●) and *range* (everything changed since ◆). The **details panel** ("Slider
Revision:") sits on the right (`timelapse.info_position = 'right'`, stacked fields) or at the
bottom (two columns, a rule line as separator). The **slider** (`slider.lua`) is a three-line
window above: its own title winbar (so a global winbar can't steal a line), the track with a
tick per revision and the handles, and labels (changelists or revisions) placed by
bisection so they never crowd. Windows are created with `nvim_open_win({ split = … })`.

#### `views/changes.lua`, `views/change_info.lua`, `views/change_editor.lua`
`:P4 changes` (submitted changelists, paged); the `K` popup (full description, files,
shelved files); the description editor (a float with only the description; `:w`/`<C-s>` save;
only the Description field of the spec is replaced, so the file list can't be edited by
accident; submitted changelists use `change -u`, with an opt-in `-f` retry).

### Other

#### `lists.lua`
Quickfix producers: `opened_items` (grouped by changelist, with changed markers),
`status_items` (stale/unresolved), `buffer_hunk_items` and `all_hunk_items` (hunks across every
opened file: one fstat, one batched print for uncached bases, in-process diffs).

#### `lsp.lua` (experimental)
An in-process language server (`vim.lsp.start{ cmd = function(dispatchers) ... end }`) that
answers `textDocument/codeAction` with Perforce actions for the file and line; commands run
client-side via `vim.lsp.commands`. Loaded only when `lsp.enabled` is set.

#### `timings.lua`, `hl.lua`
`:P4 debug timings` report; highlight links (`LINKS`, re-applied on `ColorScheme`;
`PerforatedUnchanged` is derived halfway between `Normal` and `Comment`).

#### `lua/lualine/components/perforated.lua`
A lualine component showing `require('perforated').statusline()`.

## 20. Data model

**Workspace** (`core/workspace.lua`)

| Field | Meaning |
|---|---|
| `key`, `anchor`, `mode` | identity; `mode` is `'config'`, `'env'` or `'connection'` |
| `info`, `settings` | `p4 info` record; `p4 set -q` values |
| `root`, `icase` | client root; server is case-insensitive |
| `conn` | the connection state machine |
| `buffers` | set of attached buffers |
| `fstat` | fstat records by key (only shown or opened files) |
| `clmemo` | changelist → `{ user, client, time, desc }` |
| `opened`, `opened_count`, `stale_count`, `unresolved_count` | from the last poll refresh |
| `sticky_cl`, `sticky_desc` | last chosen changelist (session) |
| `idle`, `swarm_url`, `reconcile_scope`, `integrate_target` | misc session state |

**BufState** (`buffer.lua`): `buf`, `ws`, `path`, `key`, `status`, `rec` (fstat record),
`base` / `base_text` / `base_spec`, `hunks`, `gen`, `timer`, `too_big`.

**fstat record** (p4's own fields): `depotFile`, `clientFile`, `haveRev`, `headRev`,
`headChange`, `headType`, `headAction`, `type`, `action` (set when opened), `change`,
`unresolved`, `otherOpen`, `movedFile`, `movedRev`, locks.

**Hunk** (`diff/engine.lua`): `{ type = 'add'|'change'|'delete', a_start, a_count, b_start,
b_count }`, 1-based; for deletions `b_start` is the line *after which* lines were removed.

**Tree node** (`ui/tree.lua`): `{ id, kind, text = { {str, hl}, … }, item, children?, open?,
on_open? }`; `depth` and `parent` are set when rendered. `kind` is what actions match
(`opened_file`, `change`, `shelf`, `shelved_file`, `submitted`, `have_cl`, `section`,
`reconcile_file`, `describe_file`, `diff_line`, `rev`, `spacer`, …).

**Action** (`ui/keys.lua`): `{ id, desc, keys, p4v?, kinds?, when?, run, multi?, footer?,
nomenu? }`.

**Sides**: `perforated.DiffSide` = `{ buf } | { spec } | { empty }` for diff windows;
`perforated.RevSide` = `{ spec } | { path } | { empty }` for comparisons and content.

**Annotation** (`history.lua`): `{ depotFile, rev, change, count, cls = {line → CL},
meta = {CL → {user, time, desc, client}} }`.

**Timelapse** (`timelapse.lua`): `{ depotFile, revs = {n → rev record}, first, last, head,
entries = { {text, lo, hi} }, cache }`.

## 21. Conventions

**Style.** stylua formats everything (`make fmt`; config in `.stylua.toml`), selene lints
(`make lint`). Line length ~100. Module pattern: `local M = {}` … `return M`. Local helper
functions above their use. Type annotations (`---@param`, `---@return`, `---@class`) on public
functions.

**Comments** explain *why*, not *what* — especially non-obvious Neovim or p4 behaviour ("p4
sends X as a warning on stderr with exit 0, so…"). Every module starts with a header comment
describing its role; keep it current.

**Requires.** Core modules may be required at the top of a file; feature and UI modules are
required inside functions when they aren't needed on the activation path. The memory benchmark
("Lua memory: active workspace") catches accidental eager loading.

**User messages.** `vim.notify('[perforated] …')`, short, plain language; errors at
`vim.log.levels.ERROR` include p4's own message. Anything that concerns several files goes to
quickfix with p4's reason as the entry text.

**Confirmation.** Destructive or broad actions confirm first (revert, delete, sync, submit,
delete shelved, replacing a shelf) with `vim.fn.confirm` (Cancel as default) or a float menu.

**State after operations.** Operations call `checkout.changed(ws)` (fires `User
PerforatedChanged`, which refreshes visible views) and refresh affected buffers.

**Async safety.** Callbacks check buffer/window validity; long operations are jobs (stoppable);
no synchronous waits except bounded `vim.wait` in a few deliberate places.

**Commit messages.** Imperative subject, a body explaining what changed and why. No
co-author / AI attribution trailers.

## 22. Recipes: adding things

**A `:P4` subcommand**
1. Add an entry to `M.commands` in `commands.lua`: `scope`, a `desc` written as help text (it
   becomes `:h perforated`), `run(ctx, opts, args)`, optional `complete`.
2. Add its name to `subs` in `plugin/perforated.lua` (a test compares the two lists).
3. Test it (a real-p4d test if it talks to the server).
4. Mention it in the README's command table; run `make doc`.

**A key in a view**
1. Add an action to the view's `actions(view)` list: `id`, `desc`, `keys`, `kinds` (node kinds
   it applies to), optional `when(item, node)`, `run(items, ctx)`, `multi` if it accepts marked
   items, `footer = N` to show it in the footer.
2. Avoid buffer-local key prefixes of existing keys (see [§14](#14-traps-we-fell-into)).
3. `make doc` — the key tables in `:h perforated` come from these registries.

**A config option**
1. Add it with its default and a comment to `config.lua`.
2. Add it to the README's configuration block.
3. `make doc`. `:checkhealth` will accept it automatically (it compares against the
   defaults).

**A new p4 query**
Prefer a function in `p4.lua` or `changelists.lua` that returns parsed data. Batch file
arguments with `globals = { '-x', '-' }, stdin = paths`. Pick a priority (interactive for
things the user is waiting on). Use a `key` if identical requests may overlap. Assert the call
count in a test.

**A new view**
Use `views/base.lua`: `tab()`/`float()`, a `ui/tree` for lists, `base.nav()` plus your actions,
`base.finish(view)`. Set `vim.b[buf].perforated_ws` (so commands from the view use its
workspace) — `base.finish` does it. Expose `M._actions = actions` so the doc generator can
list its keys, and add it to `scripts/gen_doc.lua`.

## 23. Testing

### 23.1 Running tests

```sh
make deps                          # mini.nvim, telescope/plenary (picker tests), p4 + p4d
make test                          # the whole suite
make test FILE=tests/test_m4.lua   # one file
make lint                          # stylua --check + selene
make bench                         # performance budgets
```

`make deps` downloads the official `p4` and `p4d` binaries into `.deps/p4bin` (the release is
pinned in the Makefile), plus mini.nvim.

### 23.2 How the tests work

- `tests/run.lua` runs mini.test over `tests/test_*.lua`. Under GitHub Actions each failure is
  also printed as an `::error` annotation, so failures show on the run summary.
- `tests/minimal_init.lua` puts the repository and mini.nvim on the runtimepath; it's used by
  both the runner and every child Neovim.
- **Child Neovims.** Almost every test starts a fresh child with `H.child(opts)`
  (`tests/helpers/init.lua`): a temporary `HOME`, `P4ENVIRO` and `P4TICKETS` so the
  developer's Perforce setup can't leak in (every `P4*` variable of your shell is scrubbed),
  optional fake-p4 rules, extra environment, and a config table (`vim.g.perforated`). The test
  then drives the child: `child.cmd`, `child.type_keys`, `child.api.*`, `child.lua(code)`,
  `child.lua_get(expr)`.
- **Waiting.** Everything is asynchronous, so tests wait for conditions:
  `H.wait(child, 'lua expression', ms)` polls until truthy. Never assert immediately after an
  action that runs p4.

### 23.3 Two kinds of Perforce

**A real server** (`tests/helpers/p4d.lua`). `P.new()` creates a throw-away `p4d` in *rsh
mode* — `P4PORT=rsh:p4d -r <root> …` — so there's no daemon and no ports: each p4 command
spawns p4d on a private database. `server:client(name, root, user)`, `server:p4config(dir,
client)`, `server:submit_files(client, root, files, desc)` and `server:p4(args, opts)` set up
scenarios (another user "bob" submitting makes your files stale, and so on). Most feature tests
use this: they test real p4 behaviour, not our assumptions about it.

**A fake `p4`** (`tests/bin/p4`, a Lua script run by `nvim -l`). Rules in a file
(`$FAKE_P4_RULES`) match the command line and return records, stdout/stderr, exit codes,
delays, hangs (`hang`, `hang_after` for a slow command that streams output first), and state
changes (`touch`/`unless` model "logged in" etc.). Every call is logged
(`$FAKE_P4_LOG`) with argv, cwd, stdin and key environment variables, so tests can assert the
exact calls — e.g. that internal calls neutralise `P4DIFF`, or that there's exactly one
`p4 login`. Used for connection states, auth races, runner behaviour, streaming and
cancellation, and benchmarks.

Other fakes: `tests/bin/fake-merge` (a merge tool that writes a chosen result and exit code)
and `tests/bin/fake-p4vc` (records its arguments).

**macOS in miniature.** `PERFORATED_P4D_CASE=insensitive` runs p4d with `-C1`
(case-insensitive, the macOS default) and `PERFORATED_TEST_TMP` puts test workspaces under a
mixed-case path. CI runs this leg on Linux.

### 23.4 Test files

| File | Covers |
|---|---|
| `test_activation.lua` | dormancy, gate, workspaces, command list vs plugin/, aliases, completion |
| `test_runner.lua`, `test_parse.lua`, `test_async.lua`, `test_cache_queue_config.lua` | core units |
| `test_conn.lua` | offline/backoff, auth: one prompt, stale-auth retry, login races |
| `test_engine.lua` | diff engine: hunk types, ranges, async = sync |
| `test_debug.lua` | debug log, redaction |
| `test_integration.lua` | real p4d end to end: fstat, info, expired login |
| `test_m1.lua` | check-out prompt and modes, signs, hunks, revert, diff, stale detection |
| `test_m2.lua`, `test_m2_pickers.lua` | client view, changelists, diff tab, pickers, `:P4 changes` |
| `test_m3.lua` | describe, history, annotate, blame, lookup, Swarm |
| `test_m4.lua` | shelve, submit, sync (+jobs, preview, resolve prompt), resolve, delete, move, integrate, delete changelist, reconcile scope |
| `test_m5.lua` | time-lapse: every revision equals `p4 print`, stepping, anchoring, slider, modes, panel |
| `test_m6.lua` | p4vc, `:P4 debug timings`, the memory soak test |
| `test_lsp.lua` | code actions |
| `test_docs.lua` | `doc/perforated.txt` is up to date |

### 23.5 Writing a good test here

- **Real p4d when behaviour depends on the server**; the fake when you need exact control
  (failures, timing, call counts).
- **Assert outcomes on the server** (`p4 opened`, `p4 describe`) and in the UI (buffer lines,
  window names, extmarks), not just "no error".
- **Regression tests should fail without the fix.** Most bug fixes in history were verified by
  stashing the fix and watching the new test fail.
- **Blocking menus**: a float menu or `vim.fn.confirm` blocks the child. Stub `confirm`
  (`child.lua('vim.fn.confirm = function() return 1 end')`) or, for float menus, `lua_notify`
  the action, sleep, then `type_keys`.
- **Windows vs tabs**: footers and other floats count as windows; count tabs or filter.
- **Neovim versions**: behaviour differs across 0.11/0.12/nightly (filetypes, events); make
  assertions version-agnostic (e.g. compare with `vim.filetype.match` in the child).

### 23.6 The memory soak test

`test_m6.lua` opens and wipes 1000 workspace files (after a 20-file warm-up), then compares the size of **every table
reachable from the plugin's modules** (and their functions' upvalues) before and after. No
table may grow by more than 50 entries — a leak shows up by name (e.g.
`perforated.poll:_reset^last_enter +980`). A loose byte bound (400 KB beyond what a control run
shows Neovim itself using) backs it up. It found real leaks — the poll throttle table and the
fstat cache — the first time it ran.

## 24. Benchmarks and performance budgets

`bench/run.lua` (`make bench`, also in CI) measures and fails when a budget is exceeded:

| Metric | Budget |
|---|---|
| Startup cost of `plugin/` (`--startuptime`, best of 9) | 0.5 ms |
| Gate lookup in a dormant directory | 0.3 ms |
| Lua memory: active workspace / per attached buffer | 250 KB / 2 KB |
| Sign refresh, 10k lines, 100 hunks (UI part) | 5 ms |
| Attach: gate + activation (synchronous part) | 0.3 ms |
| Client view: render 5000 rows / first paint | 15 ms / 16 ms |
| Annotate: parse / render 20k lines | 20 / 25 ms |
| Time-lapse step, 20k lines × 200 revisions | 5 ms |

Timings take the **best of several runs** (and, for pure-Lua loops, the best of three fresh
Neovim processes) to filter out machine noise; budgets are about the plugin's cost, not the
CI machine's mood. The time-lapse benchmark also prints a breakdown (transition / edits /
decorate).

## 25. Debugging

**For users and for you:**

- `:P4 log` — every p4 command the plugin ran, with timing and outcome.
- `:P4 debug on [level]` (or `PERFORATED_DEBUG=1` / `=trace` before starting Neovim, or
  `debug = { enabled = true }`) — a diagnostic log at `stdpath('log')/perforated.log` (shared
  by all sessions; each line carries the pid). `:P4 debug open`, `:P4 debug clear`.
- `:P4 debug snapshot` — writes the current state (workspaces, buffers, queue, recent calls)
  to the log: ask users for this in bug reports.
- `:P4 debug timings` — p4 calls per command and the plugin's own timings.
- `:checkhealth perforated` — environment, server, config typos, integrations.
- `:P4 jobs` — what's running now.

**A sandbox.** `make dev-workspace` (or `scripts/dev-workspace.sh`) creates a persistent
Perforce server and workspace in `.dev/` (gitignored): `cd .dev/ws && P4CONFIG=.p4config nvim
src/parser.cpp`. `scripts/dev-workspace.sh --bob` makes another user submit a change so your
opened file goes stale; `--reset` starts over.

**Reproducing bugs headlessly.** The fastest loop is a throw-away test file
(`tests/test_dbg.lua`) that builds the scenario with `P.new()` and `H.child()`, then prints
what you need: `child.cmd_capture('messages')`, buffer lines, `core.log` entries,
`tostring(child.get_screenshot())` for the actual screen (text and highlight attributes). Run
it with `make test FILE=tests/test_dbg.lua` and delete it afterwards.

**Inspecting live state** from a running Neovim:
`:lua =require('perforated.buffer').get()` (this buffer's state),
`:lua =require('perforated').workspace()` (its workspace),
`:lua =require('perforated.core.queue').global()` (the queue),
`:lua =vim.b.perforated_status_dict`.

**CI failures.** Failed tests appear as annotations on the run. For full logs:
`gh run view <id> --log-failed`.

## 26. Documentation

- `README.md` — the feature tour, commands, keymaps, configuration, performance. Keep the
  configuration block in sync with `config.lua` (a quick script comparing the two is in the
  history).
- `doc/perforated.txt` — generated by `make doc` from the code; never edit by hand.
  `tests/test_docs.lua` fails when it's stale.
- `docs/migrating.md` — from vim-vp4 and vim-perforce.
- `docs/developer_guide.md` — this file.
- `docs/plan.md`, `docs/design-decisions.md`, `docs/research.md` — the original plan, the
  agreed behaviour and prior-art research; useful history, not user documentation.

## 27. Continuous integration

`.github/workflows/ci.yml` runs on every push to `main` and on pull requests:

- **lint** — stylua `--check` and selene.
- **test** — Ubuntu and macOS × Neovim 0.11.4, 0.12.5 and nightly, plus a Linux leg with a
  case-insensitive server and a mixed-case temp path. Each leg runs `make deps` (cached),
  `make test`, then `make bench`.

A green `main` matters: the plugin is installed straight from `main` by lazy.nvim.

## 28. Known limitations and ideas

- **Integrate** is tested with path pairs; stream-to-stream integrates and `-b` branch specs
  need real-world checking.
- **Time-lapse** refuses files above `timelapse.max_bytes` instead of falling back to printing
  each revision.
- **Windows** isn't supported (Linux, macOS, WSL are).
- **README GIFs** are still to be recorded.
- The macOS / Neovim 0.11 CI runner occasionally runs pure-Lua loops much slower in one
  process; the benchmarks tolerate it by taking the best of three processes.

## 29. Perforce glossary

| Term | Meaning |
|---|---|
| **Depot** | The server-side file store; paths look like `//depot/main/src/a.c`. |
| **Client / workspace** | A mapping from depot paths to local files (`p4 client`), plus the files you have. |
| **P4CONFIG** | A file name (e.g. `.p4config`) that p4 looks for in the current and parent directories to find `P4PORT`, `P4USER`, `P4CLIENT` for that tree. |
| **P4ENVIRO** | The file where `p4 set` stores settings. |
| **Have / head revision** | The revision you synced (`#have`) / the newest on the server (`#head`). |
| **Stale** | Have < head: someone submitted a newer revision. |
| **Changelist (CL)** | A numbered set of changes. *Pending* (yours, not submitted; `default` is the unnumbered one) or *submitted*. |
| **Open for edit / add / delete** | Tell the server you're changing a file (`p4 edit` etc.); files are read-only until then in `noallwrite` workspaces. |
| **Shelve** | Store your pending changes on the server without submitting (`@=CL` refers to shelved content). |
| **Resolve** | Merge server changes into your opened file before submitting (after a sync or unshelve). |
| **Integrate** | Copy changes between branches (cherry-pick a changelist with `@=CL`). |
| **Revision specs** | `file#3` (revision 3), `file#head`, `file@123` (as of changelist 123), `file@=123` (shelved in 123), `file@label`, `file@2026/09/01`. |
| **`-ztag` / `-Mj`** | Tagged output (key/value records) / as JSON lines — how this plugin reads everything. |
| **`-x -`** | Read file arguments from stdin (batching without command-line limits). |
| **fstat** | Per-file metadata (have/head, action, changelist, type, digest…). |
| **Swarm** | Perforce's code-review web app. |
| **p4vc / P4V** | P4V is the Perforce GUI; `p4vc` launches parts of it from the command line. |
