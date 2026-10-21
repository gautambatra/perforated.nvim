#!/bin/sh
# Neovim for filming the demo workspace (make demo-workspace): scripts/demo/init.lua, with its
# plugins and state in .deps/demo-nvim (so they survive --reset), the workspace's .p4config and
# the pinned p4 on PATH. Run it from inside the workspace:
#   cd /tmp/perforated-demo/gautam_ws && <repo>/scripts/demo/nvim.sh src/main.cpp
set -eu

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${PERFORATED_P4BIN:-$ROOT/.deps/p4bin}"
STATE="$ROOT/.deps/demo-nvim"

export XDG_CONFIG_HOME="$STATE/config"
export XDG_DATA_HOME="$STATE/data"
export XDG_STATE_HOME="$STATE/state"
export XDG_CACHE_HOME="$STATE/cache"
export NVIM_APPNAME=perforated-demo
export P4CONFIG=.p4config
export PATH="$BIN:$PATH"
exec nvim -u "$ROOT/scripts/demo/init.lua" "$@"
