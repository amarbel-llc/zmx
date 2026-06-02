# bats file_tags=resize
#
# Multi-client PTY sizing (amarbel-llc/zmx#8): the daemon must size the PTY to
# the elementwise minimum across all attached clients, and grow it back when the
# smaller client detaches. A zmx client is just a socket connection that sends
# an Init{rows,cols}, so we drive fake clients with `socat` (no PTY allocation
# needed) and observe the live size from a session shell that polls `stty size`.

setup() {
  load "$(dirname "$BATS_TEST_FILE")/common.bash"
  setup_test_home
  export ZMX_DIR="$BATS_TEST_TMPDIR/zmx"
  export ZMX_LOG_DIR="$BATS_TEST_TMPDIR/log"
  mkdir -p "$ZMX_DIR" "$ZMX_LOG_DIR"
}

# Little-endian u16 rendered as two \xNN printf escapes.
_le16() { printf '\\x%02x\\x%02x' "$(( $1 & 255 ))" "$(( ($1 >> 8) & 255 ))"; }

# Open a held connection to socket $3 that sends Init{rows=$1, cols=$2}. The wire
# message is an 8-byte Header { tag:u8=0x07 Init, len:u32=4 } — the u40 backing
# integer makes sizeof round up to 8, hence 3 trailing pad bytes — followed by a
# Resize{rows:u16, cols:u16} payload. Leaves the socat pid in $!.
_client_init() {
  ( printf '%b' "\\x07\\x04\\x00\\x00\\x00\\x00\\x00\\x00$(_le16 "$1")$(_le16 "$2")"; sleep 10 ) \
    | socat -u - "UNIX-CONNECT:$3" 2>/dev/null &
}

# Wait up to ~3s for the last recorded PTY size to equal "$1 $2".
_wait_size() {
  local want="$1 $2" i
  for i in $(seq 1 30); do
    [ "$(tail -n1 "$BATS_TEST_TMPDIR/sizes" 2>/dev/null | tr -s ' ')" = "$want" ] && return 0
    sleep 0.1
  done
  echo "timed out waiting for PTY size '$want'; observed:" >&2
  cat "$BATS_TEST_TMPDIR/sizes" >&2
  return 1
}

@test "PTY clamps to the smallest attached client and grows back on detach" {
  local out="$BATS_TEST_TMPDIR/sizes"
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
  local sock
  sock="$(find "$ZMX_DIR" -type s | head -1)"
  [ -n "$sock" ]

  # Larger client first, then a smaller one: the PTY must follow the minimum.
  _client_init 50 200 "$sock"; local pidA=$!
  _wait_size 50 200

  _client_init 24 80 "$sock"; local pidB=$!
  _wait_size 24 80   # elementwise minimum while both are attached

  # Detaching the smaller client must grow the PTY back to the larger one.
  kill "$pidB" 2>/dev/null || true
  _wait_size 50 200

  kill "$pidA" 2>/dev/null || true
  "$ZMX_BIN" -g resize kill sess 2>/dev/null || true
}
