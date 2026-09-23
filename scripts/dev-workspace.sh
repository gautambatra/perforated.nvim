#!/bin/sh
# Persistent local Perforce sandbox for trying the plugin by hand (not used by the tests).
#
#   scripts/dev-workspace.sh            create .dev/ (no-op if it exists)
#   scripts/dev-workspace.sh --reset    recreate it from scratch
#   scripts/dev-workspace.sh --bob      "bob" submits a change to src/parser.cpp (makes your
#                                       opened copy stale — exercises stale detection/toasts)
#
# Layout (gitignored):
#   .dev/p4root/     p4d server root (rsh mode: no daemon, no ports)
#   .dev/ws/         your workspace (client dev_ws, user dev) with a .p4config
#   .dev/bob/        second user's workspace
#
# Use it:  cd .dev/ws && P4CONFIG=.p4config nvim src/parser.cpp
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEV="$ROOT/.dev"
BIN="${PERFORATED_P4BIN:-$ROOT/.deps/p4bin}"
P4="$BIN/p4"

if [ ! -x "$BIN/p4d" ] || [ ! -x "$P4" ]; then
  echo "p4/p4d not found in $BIN — run 'make deps' first" >&2
  exit 1
fi

PORT="rsh:$BIN/p4d -r $DEV/p4root -L log -i -J off"
p4_as() { # user client cwd args...
  user=$1 client=$2 dir=$3
  shift 3
  (cd "$dir" && P4PORT="$PORT" P4USER="$user" P4CLIENT="$client" P4CONFIG= \
    P4ENVIRO=/dev/null P4TICKETS="$DEV/.p4tickets" PWD="$dir" "$P4" "$@")
}

if [ "${1:-}" = "--bob" ]; then
  [ -d "$DEV/bob" ] || { echo "no sandbox yet; run without --bob first" >&2; exit 1; }
  p4_as bob bob_ws "$DEV/bob" sync -q
  p4_as bob bob_ws "$DEV/bob" edit src/parser.cpp >/dev/null
  printf '// bob was here at %s\n' "$(date +%T)" >>"$DEV/bob/src/parser.cpp"
  p4_as bob bob_ws "$DEV/bob" submit -d "bob: tweak parser ($(date +%T))" | tail -1
  exit 0
fi

if [ -e "$DEV" ]; then
  if [ "${1:-}" != "--reset" ]; then
    echo "sandbox exists: $DEV/ws  (use --reset to recreate)"
    exit 0
  fi
  chmod -R u+w "$DEV" 2>/dev/null || true
  rm -rf "$DEV"
fi

mkdir -p "$DEV/p4root" "$DEV/ws" "$DEV/bob"
# Initialise the server with one command first (concurrent p4d starts on a fresh root race).
p4_as dev dev_ws "$DEV" info >/dev/null

make_client() { # user client root
  spec=$(p4_as "$1" "$2" "$DEV" client -o "$2" | sed "s#^Root:.*#Root:	$3#")
  printf '%s\n' "$spec" | p4_as "$1" "$2" "$DEV" client -i >/dev/null
}
make_client dev dev_ws "$DEV/ws"
make_client bob bob_ws "$DEV/bob"

W="$DEV/ws"
mkdir -p "$W/src" "$W/include" "$W/docs"
cat >"$W/src/parser.cpp" <<'EOF'
#include "parser.h"

int parse(const char *s) {
  if (!s) return -1;
  return 0;
}
EOF
cat >"$W/include/parser.h" <<'EOF'
#pragma once
int parse(const char *s);
EOF
cat >"$W/src/lexer.cpp" <<'EOF'
int lex(const char *s) {
  return s ? 1 : 0;
}
EOF
printf '# Notes\n\nSandbox for perforated.nvim.\n' >"$W/docs/notes.md"
p4_as dev dev_ws "$W" add -t text src/parser.cpp include/parser.h src/lexer.cpp docs/notes.md >/dev/null
p4_as dev dev_ws "$W" submit -d "Initial import" >/dev/null

# A little history for parser.cpp (revisions 2 and 3).
for msg in "Handle empty input" "Return length"; do
  p4_as dev dev_ws "$W" edit src/parser.cpp >/dev/null
  printf '// %s\n' "$msg" >>"$W/src/parser.cpp"
  p4_as dev dev_ws "$W" submit -d "$msg" >/dev/null
done

# A pending changelist with a description, for the "choose changelist" prompt.
printf 'Change: new\nDescription:\n\tWIP: lexer cleanup\n' | p4_as dev dev_ws "$W" change -i >/dev/null

p4_as bob bob_ws "$DEV/bob" sync -q

cat >"$W/.p4config" <<EOF
P4PORT=$PORT
P4USER=dev
P4CLIENT=dev_ws
P4TICKETS=$DEV/.p4tickets
EOF

echo "sandbox ready: $W"
echo "  cd $W && P4CONFIG=.p4config nvim src/parser.cpp"
echo "  $0 --bob    # simulate another user's submit (stale detection)"
