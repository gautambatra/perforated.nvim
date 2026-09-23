# Research notes — prior art for perforated.nvim

Collected 2026-09-23. Two surveys: (A) existing Perforce integrations + p4 CLI techniques, (B) best-in-class git plugins' UX/perf patterns.

## A. Perforce integrations

| Plugin | URL | State | p4 invocation |
|---|---|---|---|
| vim-perforce (nfvs) | github.com/nfvs/vim-perforce | dead (2020) | blocking `system()` |
| vim-vp4 | github.com/ngemily/vim-vp4 | 2024 | blocking `system()`, fugitive-like |
| perforce.vim (H. K. Dara) | vim.org script 240 | 2006 | blocking, P4Win menus |
| p4.nvim (rmccord7) | github.com/rmccord7/p4.nvim | WIP | nvim-nio + `:wait()` (still blocks) |
| nvim-p4 (BigLittle) | github.com/BigLittle/nvim-p4 | 2026 | `vim.system():wait()`, nui tree |
| perfnvim | github.com/guillemaru/perfnvim | 2026 | `io.popen`, describe-per-CL loop |
| p4.el (Gareth Rees) | github.com/gareth-rees/p4.el | 2022 | async status, batched `-x -` |
| vc-p4 (Emacs VC) | github.com/ryuslash/vc-p4 | 2023 | blocking fstat per visited file |
| vscode-perforce | github.com/mjcrouch/vscode-perforce | 2025 | async spawn, concurrency limiter |

### Ideas worth stealing
- **vim-vp4**: `:Vp4Diff [s][p][@cl][#rev]`; filelog → quickfix with lazy fetch; open `//depot/f#3` directly via `BufReadCmd`; change spec in buffer, `:w` submits.
- **p4.el**: batched async status — one `p4 -x - opened` for all buffers, then `-x - have` for the rest; silent back-off (600s) when server down / logged out; forms in buffers with `C-c C-c`.
- **vscode-perforce**: `maxConcurrent` bottleneck; "Edit and Save" to avoid readonly-save race; annotate via **one** `annotate -q -c` + **one** `filelog -l -i` (no per-CL describe); age colouring.
- **P4V time-lapse**: single-rev / incremental-diff / multi-rev modes; slider by rev/CL/date; age colouring.
- **JetBrains**: automatic offline mode; dump every p4 command to a log.

### Recurring complaints (design against)
1. Blocking the editor (nearly every vim/nvim plugin).
2. N+1 queries: describe/fstat per CL/file → server table locks (vscode-perforce #12, #301; JetBrains "many, many fstats").
3. Edit-on-save race with slow server (readonly overwrite prompt).
4. `autoread` "file changed" warning after `p4 edit` flips the mode bit (nfvs #18) → handle `FileChangedShell` with `v:fcs_reason == 'mode'`.
5. Shell-string quoting bugs (spaces, Cygwin).
6. Slow annotate rendering (per-line inserts).
7. Config friction (requiring explicit P4PORT etc.; fstat on non-p4 files).

### p4 CLI facts (several verified against p4d 2025.2)
- `p4 -Mj -ztag` → one JSON object per line. **Errors inline** (`severity` 2=warn, 3=fail, 4=fatal) with exit 0; **connection errors on stderr** with exit 1. Keep a `-ztag` text fallback.
- Indexed fields (`rev0, change0, …`) need a helper to turn into arrays.
- Tagged mode drops hunks for `diff2 -du` and `describe -S -du` → **compute diffs in nvim** from `p4 print` + `vim.text.diff`.
- `p4 print -q` under `-Mj` mangles non-UTF-8 → use `print -q -o tmp` for binary/other charsets.
- `p4 -x -` reads args from stdin (works with `-Mj`), `-b N` batch size.
- **Always unset `P4DIFF`, `P4PAGER`, `P4MERGE`** in child env (P4DIFF=`nvim -d` hung a test). Never rely on P4EDITOR: use `spec -o` / `spec -i`.
- Set both `cwd` and `env.PWD`; pass absolute paths.
- `p4 set` (no `-q`) is local and shows the source of each value (`config '/path/.p4config'`, `enviro`).
- `p4 -ztag info` → `clientRoot`, `serverVersion`, `caseHandling`.
- **No usable connect timeout** (`-vnet.maxwait` didn't help, hung 60s) → plugin-enforced timeout + circuit breaker.
- fstat: `-F` filters are *not* index-optimised; `-Ol` is expensive. Real reducers: path scope, `-Ro`, `-Rc`, `-e CL`, `-m`.
- `opened -C client` is cheap (open-files table only).
- `changes -s pending -c CLIENT -l` gives all pending CLs with full descriptions in one call; `describe -S -s CL…` accepts multiple CLs.
- `diff -se/-sr/-sa/-sl` compute client-side digests → scope them. `status`/`reconcile -n -m` (mtime first) + `--parallel`.
- `annotate -a -c` returns **every line that ever existed with its lower/upper revision** → time-lapse reconstructable in-process. `-I` follows integrations (can't combine with `-i`).
- `filelog -l -i -m N` gives full descriptions → blame metadata without describe.

## B. Git plugin patterns

- **gitsigns**: fetch base text once, diff in-process (`vim.text.diff`, linematch) on `uv.new_work` thread; `nvim_buf_attach` on_lines → 100ms debounce; `throttle_async({hash})` to collapse per-buffer concurrent work; fs_event watchers; `max_file_length` guard; statusline via `vim.b.gitsigns_status_dict`; `on_attach` for buffer-local maps; tests via nvim-test/busted with child nvim.
- **mini.diff**: source abstraction `{attach, detach, apply_hunks}` → `set_ref_text`; defaults 200ms / histogram / indent heuristic / linematch=60; hunk operators `gh`/`gH`, `[h`/`]h`; overlay view.
- **vim-signify**: supports p4 but runs `p4 diff` on every refresh (anti-pattern).
- **fugitive**: `:Git` hub; URL-addressed buffers (`fugitive://…`) make any revision a real buffer; blame split with `~` re-blame at parent.
- **neogit/Magit**: foldable status sections; component tree with row→item metadata; `refresh_scheduled` coalescing; partial refresh; stale-task cancellation; picker abstraction (telescope/fzf-lua/mini.pick/snacks → vim.ui.select); window kinds (tab/split/float); Magit per-section timing (`verbose-refresh`), removable sections, large-diff collapse threshold.
- **diffview**: tab with file panel + diff windows; `VCSAdapter` abstraction (git/hg) — a p4 adapter is feasible; `lazy.require` proxies; tiny `plugin/` file; health.lua; `diffview://null` for missing sides.
- **codediff**: char-level diff — now built into nvim 0.12 (`diffopt` `inline:char`).
- **vgit**: "live" buffer features vs on-demand "screens" separation.
- **git-blame.nvim**: whole-file blame once, cached; cursor reads cache with debounce; template.
- **fzf-lua / snacks.picker**: streamed proc finders, multiprocess transforms, previewers, multi-select actions.
- **Emacs diff-hl**: reference revision switch; skip when modified-tick unchanged. **vc-dir**: marks `m/u/M`, `v` next logical action. **vc-annotate**: age colours, `a` annotate-before-this-line's-change. **git-timemachine**: `p/n/g/t/w/b/q` in-place revision stepping.
- **Neovim APIs**: `vim.system`, `vim.uv` (new_work, timers), `vim.text.diff` (renamed from `vim.diff` in 0.12 — support both), extmark signs with priority, `virt_lines`, floats with title/footer, 0.12 `nvim_echo` progress messages, `vim.ui.select/input`, `:h lua-plugin` (tiny plugin/, no required setup(), `<Plug>` maps, health.lua, late FileType for plugin buffers). Idea: in-process LSP exposing actions as code actions (like `vim.pack`).
- **Testing**: fake `p4` on PATH replaying fixtures; real p4d via `P4PORT="rsh:p4d -r $TMP -L log -i"` (no daemon); isolate `P4CONFIG/P4ENVIRO/P4TICKETS`; race + debounce + screenshot tests.
