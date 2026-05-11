# bats file_tags=help

setup() {
  load "$(dirname "$BATS_TEST_FILE")/common.bash"
  setup_test_home
}

@test "help subcommand prints usage" {
  run_zmx help
  assert_success
  assert_line --partial "zmx - session persistence for terminal processes"
  assert_line --partial "Usage: zmx"
  assert_line --partial "Commands:"
}

@test "h alias prints usage" {
  run_zmx h
  assert_success
  assert_line --partial "Usage: zmx"
}

@test "-h alias prints usage" {
  run_zmx -h
  assert_success
  assert_line --partial "Usage: zmx"
}

@test "help lists every subcommand" {
  run_zmx help
  assert_success
  assert_line --partial "[a]ttach"
  assert_line --partial "[f]ork"
  assert_line --partial "[r]un"
  assert_line --partial "[d]etach"
  assert_line --partial "[da] detach-all"
  assert_line --partial "[gs] groups"
  assert_line --partial "[l]ist"
  assert_line --partial "[c]ompletions"
  assert_line --partial "[k]ill"
  assert_line --partial "[hi]story"
  assert_line --partial "[v]ersion"
  assert_line --partial "[h]elp"
}
