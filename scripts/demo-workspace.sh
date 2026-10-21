#!/bin/sh
# A Perforce workspace for screenshots and recordings: a small C++ calculator with a year of
# history by four people, pending changelists, a shelf, a stale file, an unresolved file and
# files for reconcile to find. Not used by the tests (see dev-workspace.sh for the plain sandbox).
#
#   scripts/demo-workspace.sh           create it and start the server (no-op if it exists)
#   scripts/demo-workspace.sh --reset   recreate it from scratch
#   scripts/demo-workspace.sh --stale   mira submits a change to a file you have open, so it
#                                       goes stale (for filming the notification)
#   scripts/demo-workspace.sh --start   start the server again (after --stop)
#   scripts/demo-workspace.sh --stop    stop the server
#
# You are gautam (client gautam_ws); your teammates are aadya, ryan and mira. The server runs
# as a daemon on localhost:1666 (DEMO_PORT), so the client view shows a plain address; files
# live in /tmp/perforated-demo (DEMO_DIR).
#
# History: scripts/demo/steps.txt lists the submitted changelists. Each line of the files in
# scripts/demo/files is tagged with the steps it exists in:
#   no tag      from step 1 on
#   @S-|        from step S on
#   @S-E|       from step S until step E (removed in E)
#   @P|         only in your pending edits (made on top of step BASE)
#   @S-P|       from step S on, but removed in your pending edits
# Changelists are backdated (`p4 change -f`) so annotate's age colours and the history spread
# over a year.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="$ROOT/scripts/demo"
DEMO="${DEMO_DIR:-/tmp/perforated-demo}"
PORT="localhost:${DEMO_PORT:-1666}"
BIN="${PERFORATED_P4BIN:-$ROOT/.deps/p4bin}"
P4="$BIN/p4"
BASE=14 # your workspace is synced to this step; later steps make your files stale / unresolved
MARK="$DEMO/.perforated-demo"

if [ ! -x "$BIN/p4d" ] || [ ! -x "$P4" ]; then
  echo "p4/p4d not found in $BIN; run 'make deps' first" >&2
  exit 1
fi

ws_dir() { # user
  if [ "$1" = gautam ]; then echo "$DEMO/gautam_ws"; else echo "$DEMO/.team/$1_ws"; fi
}

p4_as() { # user args...
  _u=$1
  shift
  _d=$(ws_dir "$_u")
  (cd "$_d" && P4PORT="$PORT" P4USER="$_u" P4CLIENT="${_u}_ws" P4CONFIG='' \
    P4ENVIRO=/dev/null P4TICKETS="$DEMO/.p4tickets" PWD="$_d" "$P4" "$@")
}

server_up() {
  P4PORT="$PORT" P4USER=gautam P4CONFIG='' P4ENVIRO=/dev/null "$P4" -s info >/dev/null 2>&1
}

start_server() {
  if server_up; then
    return
  fi
  (cd "$DEMO/.server" && "$BIN/p4d" -r "$DEMO/.server" -p "$PORT" -L log -J off --daemonsafe) \
    >/dev/null 2>&1
  i=0
  until server_up; do
    i=$((i + 1))
    if [ "$i" -gt 50 ]; then
      echo "the server didn't start; see $DEMO/.server/log" >&2
      exit 1
    fi
    sleep 0.1
  done
}

stop_server() {
  if server_up; then
    p4_as gautam admin stop >/dev/null
  fi
  # admin stop returns before p4d exits; --reset can't delete the server directory under it.
  i=0
  while pgrep -f "[p]4d -r $DEMO/.server" >/dev/null; do
    i=$((i + 1))
    if [ "$i" -gt 50 ]; then
      echo "the server didn't stop" >&2
      exit 1
    fi
    sleep 0.1
  done
}

# A file's content at a step, or with your pending edits (pending = 1).
render() { # file step pending
  awk -v n="$2" -v p="$3" -v base="$BASE" '
    {
      if (substr($0, 1, 1) != "@") { if (n > 0 || p) print; next }
      bar = index($0, "|"); tag = substr($0, 2, bar - 2); text = substr($0, bar + 1)
      if (tag == "P") { if (p) print text; next }
      dash = index(tag, "-"); s = substr(tag, 1, dash - 1) + 0; e = substr(tag, dash + 1)
      if (e == "P") { if (!p && s <= n) print text; next }
      at = p ? base : n
      if (s <= at && (e == "" || at < e + 0)) print text
    }' "$SRC/files/$1"
}

files() {
  (cd "$SRC/files" && find . -type f | sed 's#^\./##' | sort)
}

date_of() { # days ago, step: a time of day that varies a little per step
  ts=$(($(date +%s) - $1 * 86400 - 3 * 3600 - ($2 * 1777) % 7200))
  date -d "@$ts" '+%Y/%m/%d %H:%M:%S' 2>/dev/null || date -r "$ts" '+%Y/%m/%d %H:%M:%S'
}

submit_step() { # step user days description
  n=$1 user=$2 days=$3 desc=$4
  dir=$(ws_dir "$user")
  p4_as "$user" sync -q >/dev/null 2>&1 || true
  tmp="$DEMO/.tmp"
  mkdir -p "$tmp"
  for f in $(files); do
    render "$f" "$n" 0 >"$tmp/new"
    render "$f" $((n - 1)) 0 >"$tmp/old"
    if cmp -s "$tmp/old" "$tmp/new"; then
      continue
    fi
    if [ ! -s "$tmp/old" ]; then
      mkdir -p "$(dirname "$dir/$f")"
      cp "$tmp/new" "$dir/$f"
      p4_as "$user" add -t text "$f" >/dev/null
    elif [ ! -s "$tmp/new" ]; then
      p4_as "$user" delete "$f" >/dev/null
    else
      p4_as "$user" edit "$f" >/dev/null
      cp "$tmp/new" "$dir/$f"
    fi
  done
  cl=$(p4_as "$user" submit -d "$desc" | awk '/^Change [0-9]+ submitted/ { print $2 }')
  when=$(date_of "$days" "$n")
  p4_as "$user" change -o "$cl" | sed "s#^Date:.*#Date: $when#" | p4_as "$user" change -f -i >/dev/null
}

run_steps() { # from to
  grep -v '^#' "$SRC/steps.txt" | while IFS='|' read -r n user days desc; do
    if [ "$n" -ge "$1" ] && [ "$n" -le "$2" ]; then
      submit_step "$n" "$user" "$days" "$desc"
    fi
  done
}

new_change() { # user description → number
  printf 'Change: new\nDescription:\n\t%s\n' "$2" | p4_as "$1" change -i | awk '{ print $2 }'
}

pending() { # file: write your pending version into your workspace
  render "$1" 0 1 >"$(ws_dir gautam)/$1"
}

case "${1:-}" in
--stop)
  stop_server
  exit 0
  ;;
--start)
  [ -f "$MARK" ] || { echo "no demo workspace yet; run without arguments first" >&2; exit 1; }
  start_server
  echo "server running on $PORT"
  exit 0
  ;;
--stale)
  [ -f "$MARK" ] || { echo "no demo workspace yet; run without arguments first" >&2; exit 1; }
  start_server
  p4_as mira sync -q >/dev/null 2>&1 || true
  p4_as mira edit include/parser.h >/dev/null
  printf '// Checked by mira at %s.\n' "$(date +%T)" >>"$(ws_dir mira)/include/parser.h"
  p4_as mira submit -d "parser.h: review notes ($(date +%T))" | tail -1
  exit 0
  ;;
--reset)
  if [ -e "$DEMO" ]; then
    [ -f "$MARK" ] || { echo "$DEMO exists but isn't a demo workspace; not touching it" >&2; exit 1; }
    stop_server
    chmod -R u+w "$DEMO" 2>/dev/null || true
    rm -rf "$DEMO"
  fi
  ;;
"") ;;
*)
  sed -n '2,13p' "$0" >&2
  exit 1
  ;;
esac

if [ -e "$DEMO" ]; then
  if [ ! -f "$MARK" ]; then
    echo "$DEMO exists but isn't a demo workspace; set DEMO_DIR elsewhere" >&2
    exit 1
  fi
  start_server
  echo "demo workspace exists: $DEMO/gautam_ws  (--reset to recreate)"
  exit 0
fi

mkdir -p "$DEMO/.server" "$DEMO/.team"
touch "$MARK"
start_server

for user in gautam aadya ryan mira; do
  dir=$(ws_dir "$user")
  mkdir -p "$dir"
  p4_as "$user" client -o "${user}_ws" | awk -v root="$dir" -v c="${user}_ws" '
    /^Root:/ { print "Root:\t" root; next }
    /^View:/ { print "View:"; print "\t//depot/calc/... //" c "/..."; skip = 1; next }
    skip && /^\t/ { next }
    { skip = 0; print }' | p4_as "$user" client -i >/dev/null
done
p4_as gautam property -a -n P4.Swarm.URL -v https://swarm.example.com >/dev/null

echo "submitting the history…"
run_steps 1 "$BASE"

# Your work in progress, on top of step BASE.
G=$(ws_dir gautam)
p4_as gautam sync -q >/dev/null 2>&1 || true
a=$(new_change gautam "Parser: modulo operator")
b=$(new_change gautam "Lexer: hex literals (0x1F)")
p4_as gautam edit -c "$a" src/parser.cpp include/parser.h tests/test_parser.cpp >/dev/null
pending src/parser.cpp
pending tests/test_parser.cpp # include/parser.h stays opened but unchanged
p4_as gautam edit -c "$b" src/lexer.cpp >/dev/null
pending src/lexer.cpp
p4_as gautam shelve -c "$b" >/dev/null
p4_as gautam edit docs/README.md >/dev/null
pending docs/README.md
pending src/format.cpp
p4_as gautam add -t text src/format.cpp >/dev/null

# Teammates carry on: lexer.cpp goes stale, and parser.cpp conflicts with your edit.
run_steps $((BASE + 1)) 99
p4_as gautam sync -q src/parser.cpp >/dev/null 2>&1 || true # now needs a resolve

# ryan has main.cpp open, so checking it out warns that someone else is working on it.
r=$(new_change ryan "REPL: line editing with readline")
p4_as ryan edit -c "$r" src/main.cpp >/dev/null

# For reconcile: a new file, and a file edited without checking it out.
printf 'Ideas\n- hex output (0x...)\n- keep a history of results (ans1, ans2, ...)\n' >"$G/TODO.txt"
chmod u+w "$G/CMakeLists.txt"
printf 'add_compile_options(-Wall -Wextra)\n' >>"$G/CMakeLists.txt"

cat >"$G/.p4config" <<EOF
P4PORT=$PORT
P4USER=gautam
P4CLIENT=gautam_ws
EOF

rm -rf "$DEMO/.tmp"
echo "demo workspace ready: $G"
echo "  cd $G && P4CONFIG=.p4config PATH=$BIN:\$PATH nvim src/parser.cpp"
echo "  $0 --stale    # a teammate's submit makes one of your files stale"
echo "  $0 --stop     # stop the server (--start brings it back)"
