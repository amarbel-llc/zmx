# bats file_tags=title
#
# Window-title restoration on re-attach (amarbel-llc/zmx#6): the daemon tracks
# the inner program's OSC 0/2 window title from the PTY output stream and
# re-emits it to a client that RE-attaches to an existing session — and only on
# re-attach, not the first attach. The title is an escape sequence (not drawn to
# the screen), so it can only reach a client via the daemon's replay. A zmx
# client is just a socket connection (see common.bash); we drive fake clients
# with `socat` and capture what the daemon sends back.

setup() {
  load "$(dirname "$BATS_TEST_FILE")/common.bash"
  setup_test_home
  export ZMX_DIR="$BATS_TEST_TMPDIR/zmx"
  export ZMX_LOG_DIR="$BATS_TEST_TMPDIR/log"
  mkdir -p "$ZMX_DIR" "$ZMX_LOG_DIR"
}

teardown() {
  "${ZMX_BIN:-zmx}" -g title kill sess 2>/dev/null || true
}

# Spawn a session whose shell emits the OSC escape $1 once (printf-interpreted),
# then idles. Sets $sock.
_start_title_session() {
  local sh="$BATS_TEST_TMPDIR/titler.sh"
  {
    echo '#!/usr/bin/env bash'
    echo "printf '$1'"
    echo 'while :; do sleep 0.2; done'
  } > "$sh"
  chmod +x "$sh"
  "$ZMX_BIN" -g title attach --detach sess bash "$sh"
  sock="$(find "$ZMX_DIR" -type s | head -1)"
  [ -n "$sock" ]
  sleep 0.5   # let the shell emit the title so the daemon captures it
}

# Wait up to ~3s for file $2 to contain $1.
_wait_grep() {
  local i
  for i in $(seq 1 30); do grep -qa "$1" "$2" && return 0; sleep 0.1; done
  echo "reply never contained '$1':" >&2
  od -c "$2" 2>/dev/null | head -40 >&2
  return 1
}

@test "re-attaching replays an OSC 2 window title" {
  _start_title_session '\033]2;MYTITLE2\007'

  # First attach + detach so the session counts as "existing".
  ( zmx_init_msg 24 80; sleep 5 ) | socat -u - "UNIX-CONNECT:$sock" 2>/dev/null &
  local p1=$!
  sleep 0.5; kill "$p1" 2>/dev/null || true; sleep 0.5

  # Re-attach, capturing what the daemon sends.
  local cap="$BATS_TEST_TMPDIR/recv"; : > "$cap"
  ( zmx_init_msg 24 80; sleep 5 ) | socat - "UNIX-CONNECT:$sock" > "$cap" 2>/dev/null &
  local p2=$!
  _wait_grep ']2;MYTITLE2' "$cap"
  kill "$p2" 2>/dev/null || true
}

@test "re-attaching replays an OSC 0 icon+title" {
  _start_title_session '\033]0;MYICON0\007'

  ( zmx_init_msg 24 80; sleep 5 ) | socat -u - "UNIX-CONNECT:$sock" 2>/dev/null &
  local p1=$!
  sleep 0.5; kill "$p1" 2>/dev/null || true; sleep 0.5

  local cap="$BATS_TEST_TMPDIR/recv"; : > "$cap"
  ( zmx_init_msg 24 80; sleep 5 ) | socat - "UNIX-CONNECT:$sock" > "$cap" 2>/dev/null &
  local p2=$!
  _wait_grep ']0;MYICON0' "$cap"
  kill "$p2" 2>/dev/null || true
}

@test "the title is not replayed on the first attach" {
  _start_title_session '\033]2;NOREPLAY7\007'

  # First (and only) attach captures everything the daemon sends. The title was
  # emitted before this client connected, so it must NOT appear: the daemon only
  # replays state to a re-attaching client.
  local cap="$BATS_TEST_TMPDIR/recv"; : > "$cap"
  ( zmx_init_msg 24 80; sleep 5 ) | socat - "UNIX-CONNECT:$sock" > "$cap" 2>/dev/null &
  local p1=$!
  sleep 1.5
  kill "$p1" 2>/dev/null || true

  if grep -qa ']2;NOREPLAY7' "$cap"; then
    echo "title was replayed on the FIRST attach, but it should only replay on re-attach:" >&2
    od -c "$cap" 2>/dev/null | head -40 >&2
    false
  fi
}
