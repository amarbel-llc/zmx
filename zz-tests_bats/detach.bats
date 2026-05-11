# bats file_tags=detach

setup() {
  load "$(dirname "$BATS_TEST_FILE")/common.bash"
  setup_test_home
  export ZMX_DIR="$BATS_TEST_TMPDIR/zmx"
}

@test "attach --detach creates a new session" {
  run_zmx attach --detach foo
  assert_success
  assert_output 'session "foo" created'
}

@test "attach --detach on existing session reports already exists" {
  run_zmx attach --detach bar
  assert_success
  assert_output 'session "bar" created'

  run_zmx attach --detach bar
  assert_success
  assert_output 'session "bar" already exists'
}

@test "--detach accepted before the session name" {
  run_zmx attach --detach baz
  assert_success
  assert_output 'session "baz" created'
}

@test "--detach accepted after the session name" {
  run_zmx attach qux --detach
  assert_success
  assert_output 'session "qux" created'
}

@test "--detach accepted between session name and spawn command" {
  run_zmx attach quux --detach /bin/sh
  assert_success
  assert_output 'session "quux" created'
}

@test "attach with --detach but no session name errors" {
  run_zmx attach --detach
  assert_failure
}

@test "help text mentions --detach" {
  run_zmx help
  assert_success
  assert_line --partial "--detach"
  assert_line --partial "any position"
}
