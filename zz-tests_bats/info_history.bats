# bats file_tags=info_history
#
# Info (tag 0x06) and History (tag 0x08) IPC round-trips. A client sends the
# request on a fresh connection (no Init needed — the daemon's own SessionProbe
# queries Info this way) and the daemon replies on the same socket: session
# metadata for Info (including the spawn-command text), or the serialized
# terminal contents for History. Both are no-payload requests (zmx_ctrl_msg), so
# we send one and grep the captured reply.

setup() {
  load "$(dirname "$BATS_TEST_FILE")/common.bash"
  setup_test_home
  export ZMX_DIR="$BATS_TEST_TMPDIR/zmx"
  export ZMX_LOG_DIR="$BATS_TEST_TMPDIR/log"
  mkdir -p "$ZMX_DIR" "$ZMX_LOG_DIR"
}

teardown() {
  "${ZMX_BIN:-zmx}" -g infohist kill sess 2>/dev/null || true
}

# Send no-payload control message $1 on a fresh connection; capture the daemon's
# reply into file $2.
_query() {
  : > "$2"
  ( zmx_ctrl_msg "$1"; sleep 2 ) | socat - "UNIX-CONNECT:$sock" > "$2" 2>/dev/null &
}

# Wait up to ~3s for file $2 to contain $1.
_wait_reply() {
  local i
  for i in $(seq 1 30); do grep -qa "$1" "$2" && return 0; sleep 0.1; done
  echo "reply never contained '$1':" >&2
  od -c "$2" 2>/dev/null | head -40 >&2
  return 1
}

@test "Info returns the session's spawn command" {
  "$ZMX_BIN" -g infohist attach --detach sess sh -c 'INFOMARKER_9z=1; while :; do sleep 0.2; done'
  sock="$(find "$ZMX_DIR" -type s | head -1)"
  [ -n "$sock" ]

  local cap="$BATS_TEST_TMPDIR/info"
  _query 6 "$cap"
  _wait_reply 'INFOMARKER_9z' "$cap"
}

@test "History returns the session's terminal contents" {
  "$ZMX_BIN" -g infohist attach --detach sess sh -c 'printf "HISTMARKER_9z\n"; while :; do sleep 0.2; done'
  sock="$(find "$ZMX_DIR" -type s | head -1)"
  [ -n "$sock" ]
  sleep 0.5   # let the printed marker reach the terminal model

  local cap="$BATS_TEST_TMPDIR/hist"
  _query 8 "$cap"
  _wait_reply 'HISTMARKER_9z' "$cap"
}
