# bats file_tags=title
#
# Window-title restoration on re-attach (amarbel-llc/zmx#6): the daemon tracks
# the inner program's OSC 0/2 window title from the PTY output stream and
# re-emits it to a client that re-attaches to an existing session. The title was
# set in the past, so a freshly-attached terminal would otherwise never see it
# (the terminal backends don't serialize the title).
#
# A zmx client is just a socket connection (see zmx_init_msg in common.bash), so
# we drive fake clients with `socat` and capture what the daemon sends back to a
# re-attaching client.

setup() {
  load "$(dirname "$BATS_TEST_FILE")/common.bash"
  setup_test_home
  export ZMX_DIR="$BATS_TEST_TMPDIR/zmx"
  export ZMX_LOG_DIR="$BATS_TEST_TMPDIR/log"
  mkdir -p "$ZMX_DIR" "$ZMX_LOG_DIR"
}

@test "re-attaching to an existing session replays the OSC window title" {
  # Session shell sets an OSC 2 window title once, then idles. The daemon
  # captures it from the PTY output stream (it is not drawn to the screen, so it
  # can only reach a re-attaching client via the daemon's title replay).
  local sh="$BATS_TEST_TMPDIR/titler.sh"
  cat > "$sh" <<'EOF'
#!/usr/bin/env bash
printf '\033]2;MYTITLE\007'
while :; do sleep 0.2; done
EOF
  chmod +x "$sh"

  "$ZMX_BIN" -g title attach --detach sess bash "$sh"
  local sock
  sock="$(find "$ZMX_DIR" -type s | head -1)"
  [ -n "$sock" ]
  sleep 0.5   # let the shell emit the title so the daemon captures it

  # First attach + detach so the session counts as "existing" on the next
  # attach (the daemon only replays state to re-attaching clients).
  ( zmx_init_msg 24 80; sleep 5 ) | socat -u - "UNIX-CONNECT:$sock" 2>/dev/null &
  local pid1=$!
  sleep 0.5
  kill "$pid1" 2>/dev/null || true
  sleep 0.5

  # Re-attach and capture everything the daemon sends to this client.
  local capture="$BATS_TEST_TMPDIR/recv"
  : > "$capture"
  ( zmx_init_msg 24 80; sleep 10 ) | socat - "UNIX-CONNECT:$sock" > "$capture" 2>/dev/null &
  local pid2=$!

  # Wait for the replayed OSC title to arrive.
  local i ok=
  for i in $(seq 1 30); do
    if grep -qa ']2;MYTITLE' "$capture"; then ok=1; break; fi
    sleep 0.1
  done

  kill "$pid2" 2>/dev/null || true
  "$ZMX_BIN" -g title kill sess 2>/dev/null || true

  if [ -z "$ok" ]; then
    echo "OSC window title was not replayed to the re-attaching client. Captured bytes:" >&2
    od -c "$capture" >&2
    false
  fi
}
