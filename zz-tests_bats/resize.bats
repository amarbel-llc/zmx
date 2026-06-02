# bats file_tags=resize
#
# Multi-client PTY sizing (amarbel-llc/zmx#8): the daemon sizes the PTY to the
# elementwise minimum across all attached clients, and grows it back when a
# smaller client detaches. A zmx client is just a socket connection that sends
# an Init/Resize message (see common.bash), so we drive fake clients with
# `socat` (no PTY allocation) and observe the live size from a session shell
# that polls `stty size`.

setup() {
  load "$(dirname "$BATS_TEST_FILE")/common.bash"
  setup_test_home
  export ZMX_DIR="$BATS_TEST_TMPDIR/zmx"
  export ZMX_LOG_DIR="$BATS_TEST_TMPDIR/log"
  mkdir -p "$ZMX_DIR" "$ZMX_LOG_DIR"

  out="$BATS_TEST_TMPDIR/sizes"
  : > "$out"

  # Session shell: poll `stty size` and append each change, so the live PTY size
  # (set by the daemon via TIOCSWINSZ) is observable from $out.
  local obs="$BATS_TEST_TMPDIR/observer.sh"
  cat > "$obs" <<EOF
#!/usr/bin/env bash
prev=""
while :; do
  cur="\$(stty size 2>/dev/null)"
  if [ "\$cur" != "\$prev" ]; then printf '%s\n' "\$cur" >> "$out"; prev="\$cur"; fi
  sleep 0.1
done
EOF
  chmod +x "$obs"

  "$ZMX_BIN" -g resize attach --detach sess bash "$obs"
  sock="$(find "$ZMX_DIR" -type s | head -1)"
  [ -n "$sock" ]
}

teardown() {
  "${ZMX_BIN:-zmx}" -g resize kill sess 2>/dev/null || true
}

# Open a held connection to the session socket that sends Init{rows=$1, cols=$2}.
# Leaves the socat pid in $!.
_client_init() {
  ( zmx_init_msg "$1" "$2"; sleep 10 ) | socat -u - "UNIX-CONNECT:$sock" 2>/dev/null &
}

# Wait up to ~3s for the last recorded PTY size to equal "$1 $2".
_wait_size() {
  local want="$1 $2" i
  for i in $(seq 1 30); do
    [ "$(tail -n1 "$out" 2>/dev/null | tr -s ' ')" = "$want" ] && return 0
    sleep 0.1
  done
  echo "timed out waiting for PTY size '$want'; observed:" >&2
  cat "$out" >&2
  return 1
}

@test "PTY clamps to the smallest attached client and grows back on detach" {
  _client_init 50 200; local pidA=$!
  _wait_size 50 200
  _client_init 24 80; local pidB=$!
  _wait_size 24 80
  kill "$pidB" 2>/dev/null || true
  _wait_size 50 200
  kill "$pidA" 2>/dev/null || true
}

@test "minimum is recomputed correctly as three clients detach" {
  _client_init 50 200; local pidA=$!
  _wait_size 50 200
  _client_init 30 100; local pidB=$!
  _wait_size 30 100
  _client_init 24 80; local pidC=$!
  _wait_size 24 80                  # minimum of all three

  # Detaching the MIDDLE client (not the minimum) must leave the size unchanged.
  kill "$pidB" 2>/dev/null || true
  _wait_size 24 80                  # still bounded by client C

  # Detaching the smallest now grows the PTY back to the only client left.
  kill "$pidC" 2>/dev/null || true
  _wait_size 50 200
  kill "$pidA" 2>/dev/null || true
}

@test "a client Resize message updates the shared minimum" {
  # A single client: Init at 50x200, then later Resize down to 20x60.
  ( zmx_init_msg 50 200; sleep 1; zmx_resize_msg 20 60; sleep 10 ) \
    | socat -u - "UNIX-CONNECT:$sock" 2>/dev/null &
  local p=$!
  _wait_size 50 200
  _wait_size 20 60
  kill "$p" 2>/dev/null || true
}
