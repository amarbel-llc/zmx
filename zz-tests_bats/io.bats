# bats file_tags=io
#
# Core I/O regression tests: the daemon must broadcast PTY output to every
# attached client, and forward a client's Input to the session's PTY. A zmx
# client is just a socket connection (see common.bash), so we drive raw-socket
# clients with `socat` and capture what each one receives back.

setup() {
  load "$(dirname "$BATS_TEST_FILE")/common.bash"
  setup_test_home
  export ZMX_DIR="$BATS_TEST_TMPDIR/zmx"
  export ZMX_LOG_DIR="$BATS_TEST_TMPDIR/log"
  mkdir -p "$ZMX_DIR" "$ZMX_LOG_DIR"
}

teardown() {
  "${ZMX_BIN:-zmx}" -g io kill sess 2>/dev/null || true
}

@test "PTY output is broadcast to every attached client" {
  local sh="$BATS_TEST_TMPDIR/ticker.sh"
  cat > "$sh" <<'EOF'
#!/usr/bin/env bash
while :; do printf 'TICK\n'; sleep 0.2; done
EOF
  chmod +x "$sh"

  "$ZMX_BIN" -g io attach --detach sess bash "$sh"
  local sock
  sock="$(find "$ZMX_DIR" -type s | head -1)"
  [ -n "$sock" ]

  # Two clients, each capturing everything the daemon sends it.
  local f1="$BATS_TEST_TMPDIR/c1" f2="$BATS_TEST_TMPDIR/c2"
  : > "$f1"; : > "$f2"
  ( zmx_init_msg 24 80; sleep 10 ) | socat - "UNIX-CONNECT:$sock" > "$f1" 2>/dev/null &
  local p1=$!
  ( zmx_init_msg 24 80; sleep 10 ) | socat - "UNIX-CONNECT:$sock" > "$f2" 2>/dev/null &
  local p2=$!

  local i
  for i in $(seq 1 40); do
    grep -qa TICK "$f1" && grep -qa TICK "$f2" && break
    sleep 0.1
  done
  kill "$p1" "$p2" 2>/dev/null || true

  grep -qa TICK "$f1" || { echo "client 1 received no broadcast output:" >&2; od -c "$f1" | head >&2; false; }
  grep -qa TICK "$f2" || { echo "client 2 received no broadcast output:" >&2; od -c "$f2" | head >&2; false; }
}

@test "input from a client is forwarded to the session PTY" {
  # `cat` keeps the session alive; the PTY echoes the forwarded input back, so a
  # marker we send as Input reappears in the broadcast output we capture.
  "$ZMX_BIN" -g io attach --detach sess cat
  local sock
  sock="$(find "$ZMX_DIR" -type s | head -1)"
  [ -n "$sock" ]

  local cap="$BATS_TEST_TMPDIR/cap"
  : > "$cap"
  ( zmx_init_msg 24 80; sleep 0.5; zmx_input_msg 'ZMXINPUT123\n'; sleep 10 ) \
    | socat - "UNIX-CONNECT:$sock" > "$cap" 2>/dev/null &
  local p=$!

  local i ok=
  for i in $(seq 1 40); do
    if grep -qa 'ZMXINPUT123' "$cap"; then ok=1; break; fi
    sleep 0.1
  done
  kill "$p" 2>/dev/null || true

  [ -n "$ok" ] || { echo "forwarded input was not reflected by the session; captured:" >&2; od -c "$cap" | head >&2; false; }
}
