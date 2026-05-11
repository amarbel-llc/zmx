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
