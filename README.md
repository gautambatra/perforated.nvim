# perforated.nvim

Perforce (Helix Core) integration for Neovim. It is designed to be fast, lightweight, and
completely dormant outside Perforce workspaces.

> **Status: early development (milestone M0: core runtime).** The async p4 runner, workspace
> detection, connection and login handling, `:P4 info`, `:P4 log` and `:checkhealth perforated`
> work today. See [docs/plan.md](docs/plan.md) for the roadmap and
> [docs/design-decisions.md](docs/design-decisions.md) for the agreed behaviour.

## Requirements

- Neovim 0.11+
- The `p4` command-line client

There are no Lua plugin dependencies.

## Install

With lazy.nvim:

```lua
{ 'perforated.nvim' } -- no setup() call required
```

Configuration is optional, through either `vim.g.perforated = { ... }` or
`require('perforated').setup({ ... })`. See `lua/perforated/config.lua` for the defaults.

## How it detects workspaces

- Opening a file looks for your `P4CONFIG` file (e.g. `.p4config`) in the file's directory and its
  parents. The lookup is pure Lua and cached per directory; it starts no processes.
- The directory containing that file is the workspace **anchor**. Every p4 command for the
  workspace runs from there, so all its buffers share one set of settings.
- Without a `P4CONFIG` file, but with `P4CLIENT` set, one background `p4 info` per session learns
  the client root.
- In any other case the plugin does nothing: no modules load and no processes or timers run.

## Commands (so far)

| Command | Description |
|---|---|
| `:P4 info` | Workspace, client, root, user, server and connection state |
| `:P4 log` | Every p4 command the plugin ran, with timings |
| `:P4 login` | Log in (password prompt) |
| `:P4 refresh[!]` | Refresh cached state (`!` also forgets workspace detection) |

Each command also has a flat alias (`:P4info`, `:P4log`, …).

## Development

```sh
make deps    # mini.nvim + p4/p4d test binaries into .deps/
make test    # full suite (fake p4 + throwaway real p4d); FILE=tests/test_x.lua for one file
make bench   # performance budgets (startup, dormant cost, memory)
make lint    # stylua + selene
```
