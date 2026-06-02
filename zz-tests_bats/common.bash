#! /bin/bash -e
#
# zz-tests_bats/common.bash — load from every .bats file's setup():
#
#   setup() {
#     load "$(dirname "$BATS_TEST_FILE")/common.bash"
#     setup_test_home
#   }

if [[ -z $BATS_TEST_TMPDIR ]]; then
  echo 'common.bash loaded before $BATS_TEST_TMPDIR set. aborting.' >&2
  exit 1
fi

pushd "$BATS_TEST_TMPDIR" >/dev/null || exit 1

bats_load_library bats-support
bats_load_library bats-assert
bats_load_library bats-emo
bats_load_library bats-island

require_bin ZMX_BIN zmx

# Wraps zmx invocation with a per-call timeout. BATS_TEST_TIMEOUT caps
# the whole @test block; this caps a single invocation. Bump only if a
# specific call legitimately needs more.
run_zmx() {
  local bin="${ZMX_BIN:-zmx}"
  run timeout --preserve-status 2s "$bin" "$@"
}

# --- raw IPC helpers for integration tests ------------------------------------
#
# A zmx client is just a socket connection that speaks the binary protocol, so
# tests can drive "fake" clients with socat (no PTY allocation). The wire format
# is an 8-byte Header { tag:u8, len:u32 } followed by `len` payload bytes. The
# header is 8 (not 5) bytes because its u40 backing integer makes @sizeOf round
# up to 8, leaving 3 trailing pad bytes.

# Render a u16 as two little-endian \xNN printf escapes.
zmx_le16() { printf '\\x%02x\\x%02x' "$(( $1 & 255 ))" "$(( ($1 >> 8) & 255 ))"; }

# Print (to stdout) an Init message carrying Resize{rows=$1, cols=$2}: an
# 8-byte Header { tag=0x07 Init, len=4 } + 4-byte Resize payload.
zmx_init_msg() {
  printf '%b' "\\x07\\x04\\x00\\x00\\x00\\x00\\x00\\x00$(zmx_le16 "$1")$(zmx_le16 "$2")"
}
