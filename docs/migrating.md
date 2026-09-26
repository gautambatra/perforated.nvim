# Migrating to perforated.nvim

From [vim-vp4](https://github.com/ngemily/vim-vp4) or
[vim-perforce](https://github.com/nfvs/vim-perforce) (nfvs). Both run p4 synchronously
(`system()`), so every command blocks the editor until the server answers; perforated.nvim
never blocks, and stays dormant outside Perforce workspaces. Remove the old plugin first: the
nfvs commands `:P4info`, `:P4edit` and `:P4revert` have the same names as perforated's
aliases.

## From vim-vp4

| vim-vp4 | perforated.nvim |
|---|---|
| `:Vp4Edit` | `:P4 edit` — or nothing: the check-out menu appears on your first change to a read-only file |
| `:Vp4Add` | `:P4 add` — or on `:w` of a new file (`checkout.add_on_write`) |
| `:Vp4Delete[!]` | `:P4 delete` (confirms; the buffer is closed) |
| `:Vp4Revert[!]` | `:P4 revert[!]` (`!` skips the confirmation) |
| `:Vp4Reopen` | `:P4 reopen [-c CL]` (no `-c`: pick one), or `M` in the client view / quickfix |
| `:Vp4Diff` | `:P4 diff` (side-by-side in a tab; `q` closes) |
| `:Vp4Diff s` | `:P4 diff @=<your CL>` |
| `:Vp4Diff p` | `:P4 diff prev` |
| `:Vp4Diff @{cl}` | `:P4 diff @={cl}` (shelved in `{cl}`) |
| `:Vp4Diff #{rev}` | `:P4 diff #{rev}` |
| `:[range]Vp4Annotate` | `:P4 annotate` (scroll-bound split, whole file in two p4 calls; works on files you're editing) |
| `:Vp4Filelog` | `:P4 filelog` (a float; `history.presenter = 'quickfix'` for the location list) |
| `:Vp4Change` | `:P4 change` (description only; `:P4 change!` for the full spec) |
| `:Vp4Describe` | `:P4 describe` (the current file's changelist, with inline diffs) |
| `:Vp4Shelve[!]` | `:P4 shelve` (asks before replacing an existing shelf) |
| open `//depot/...` paths | `:e perforated:////depot/path/file.c#3` (any revision, `@CL`, `@=shelf`) |

| vim-vp4 setting | perforated.nvim |
|---|---|
| `g:vp4_prompt_on_write` | `checkout = { prompt = true }` (the default; it prompts on the first change, not on write) |
| `g:vp4_open_on_write` | `checkout = { prompt = false, on_write = true }` |
| `g:vp4_filelog_max` | `history = { limit = N }` (a page size; more load as you scroll) |
| `g:vp4_open_loclist` | `qf = { open = false }` |
| `g:vp4_annotate_simple` | not needed: annotate takes two p4 calls whatever the file |
| `g:vp4_allow_open_depot_file` | always on for `perforated://` paths |

## From vim-perforce (nfvs)

| vim-perforce | perforated.nvim |
|---|---|
| `:P4info` | `:P4 info` (or `:P4info`) |
| `:P4edit` | `:P4 edit` |
| `:P4revert` | `:P4 revert` |
| `:P4movetocl` | `:P4 reopen` |

| vim-perforce setting | perforated.nvim |
|---|---|
| `g:perforce_open_on_change` | `checkout = { prompt = true }` (the default) |
| `g:perforce_open_on_save` | `checkout = { prompt = false, on_write = true }` |
| `g:perforce_auto_source_dirs` | `checkout = { dirs = { … } }` |
| `g:perforce_prompt_on_open = 0` | `checkout = { prompt = false, on_write = true }` |
| `g:perforce_use_relative_paths`, `g:perforce_use_cygpath` | not needed (Linux, macOS, WSL) |

## What's new

Once you've switched, the parts neither plugin had: the client view (`:P4`), gutter signs
and hunks, stale-file detection, the describe buffer, time-lapse (`:P4 timelapse`), resolve
with your merge tool, sync / submit / shelve / integrate with watchable, stoppable jobs, and
pickers. See the [README](../README.md) and `:h perforated`.
