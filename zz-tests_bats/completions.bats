# bats file_tags=completions

setup() {
  load "$(dirname "$BATS_TEST_FILE")/common.bash"
  setup_test_home
}

@test "fish completion script parses" {
  run bash -c '"$ZMX_BIN" completions fish | fish -n /dev/stdin'
  assert_success
}

@test "bash completion script parses" {
  run bash -c '"$ZMX_BIN" completions bash | bash -n /dev/stdin'
  assert_success
}

@test "zsh completion script parses" {
  run bash -c '"$ZMX_BIN" completions zsh | zsh -n /dev/stdin'
  assert_success
}
