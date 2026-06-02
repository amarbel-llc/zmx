# bats file_tags=detach_ipc
#
# Detach / DetachAll IPC framing. A correctly-framed (8-byte header) control
# message is processed by the daemon; a truncated one is silently ignored. We
# assert against the daemon's own log. The negative case documents
# amarbel-llc/eng#137, where a 5-byte DetachAll is a no-op because the wire
# Header is 8 bytes, not 5.

setup() {
  load "$(dirname "$BATS_TEST_FILE")/common.bash"
  setup_test_home
  export ZMX_DIR="$BATS_TEST_TMPDIR/zmx"
  export ZMX_LOG_DIR="$BATS_TEST_TMPDIR/log"
  mkdir -p "$ZMX_DIR" "$ZMX_LOG_DIR"

  "$ZMX_BIN" -g detachipc attach --detach sess sh -c 'while :; do sleep 0.2; done'
  sock="$(find "$ZMX_DIR" -type s | head -1)"
  [ -n "$sock" ]
}

teardown() {
  "${ZMX_BIN:-zmx}" -g detachipc kill sess 2>/dev/null || true
}

_log() { find "$ZMX_LOG_DIR" -name '*.log' -exec cat {} + 2>/dev/null; }

# Wait up to ~3s for the daemon log to contain the fixed string $1.
_wait_log() {
  local i
  for i in $(seq 1 30); do _log | grep -qaF "$1" && return 0; sleep 0.1; done
  echo "daemon log never contained '$1':" >&2; _log >&2; return 1
}

@test "a correctly-framed DetachAll detaches all clients; a truncated one is ignored" {
  # Two held clients.
  ( zmx_init_msg 24 80; sleep 10 ) | socat -u - "UNIX-CONNECT:$sock" 2>/dev/null &
  local c1=$!
  ( zmx_init_msg 24 80; sleep 10 ) | socat -u - "UNIX-CONNECT:$sock" 2>/dev/null &
  local c2=$!
  _wait_log "total=2"

  # A truncated 5-byte DetachAll (eng#137) is shorter than the 8-byte header, so
  # the daemon never completes the message and nothing is detached.
  printf '%b' '\x04\x00\x00\x00\x00' | socat -u - "UNIX-CONNECT:$sock" 2>/dev/null || true
  sleep 0.5
  if _log | grep -qaF "detach all clients"; then
    echo "a 5-byte DetachAll was processed, but it is too short to be a valid message:" >&2
    _log >&2
    false
  fi

  # The correctly-framed 8-byte DetachAll detaches everyone.
  zmx_ctrl_msg 4 | socat -u - "UNIX-CONNECT:$sock" 2>/dev/null || true
  _wait_log "detach all clients"

  kill "$c1" "$c2" 2>/dev/null || true
}

@test "a Detach message detaches the sending client" {
  ( zmx_init_msg 24 80; sleep 10 ) | socat -u - "UNIX-CONNECT:$sock" 2>/dev/null &
  local other=$!
  _wait_log "total=1"

  # A client that sends Detach is detached by the daemon (logged distinctly from
  # a plain socket close).
  ( zmx_init_msg 24 80; sleep 0.5; zmx_ctrl_msg 3; sleep 5 ) | socat -u - "UNIX-CONNECT:$sock" 2>/dev/null &
  local d=$!
  _wait_log "client detach"

  kill "$other" "$d" 2>/dev/null || true
}
