#!/usr/bin/env bats
# laptop/completion.bash (spec 6.4, plan Q15): verbs, cached names and tombstones, failure caching,
# literal prefixes, symlinked caches. ssh is a stub.
load laptop-helpers

setup() {
  laptop_setup
  # shellcheck source=/dev/null
  source "$REPO/laptop/completion.bash"
  printf 'api\nweb\na[b\n' > "$BATS_TEST_TMPDIR/names.out"
  export TK_STUB_SSH_OUT="$BATS_TEST_TMPDIR/names.out"
  CACHE="$TMPDIR/tmuxkeep-names-$(id -u).txt"
  TOMB_CACHE="$TMPDIR/tmuxkeep-tombstones-$(id -u).txt"
}

# complete_words WORD...: runs _tmuxkeep with the cursor on the last word; prints COMPREPLY, one per line.
complete_words() {
  COMP_WORDS=("$@")
  COMP_CWORD=$(( $# - 1 ))
  _tmuxkeep
  if [ "${#COMPREPLY[@]}" -gt 0 ]; then printf '%s\n' "${COMPREPLY[@]}"; fi
}

@test "sourcing registers the completer and the two one-line lists" {
  run complete -p tmuxkeep
  [ "$output" = 'complete -F _tmuxkeep tmuxkeep' ]
  grep -qx '_TK_VERBS="new ls peek go send rename lock unlock rm restore resume log auth"' "$REPO/laptop/completion.bash"
  grep -qx '_TK_NAME_VERBS="peek go send rename lock unlock rm resume"' "$REPO/laptop/completion.bash"
}

@test "the first word completes the verbs" {
  run complete_words tmuxkeep re
  [ "$output" = "$(printf '%s\n' rename restore resume)" ]
  run complete_words tmuxkeep ''
  [ "${#lines[@]}" -eq 13 ]
  [ ! -s "$TK_STUB_LOG" ]
}

@test "session names after a name verb, fetched with the exact ssh arguments" {
  run complete_words tmuxkeep go a
  [ "$output" = "$(printf '%s\n' api 'a[b')" ]
  [ "$(stub_calls)" = 'ssh [-n] [-o] [BatchMode=yes] [-o] [ConnectTimeout=5] [-o] [ServerAliveInterval=2] [-o] [ServerAliveCountMax=2] [tmuxkeep] [ls] [--names]' ]
  [ -f "$CACHE" ]
}

@test "a second Tab within 60 seconds is served from the cache" {
  run complete_words tmuxkeep peek ''
  run complete_words tmuxkeep send w
  [ "$output" = web ]
  [ "$(stub_calls | grep -c .)" -eq 1 ]
}

@test "restore completes tombstone base names from its own cache" {
  printf 'old\n' > "$BATS_TEST_TMPDIR/tombs.out"
  export TK_STUB_SSH_OUT="$BATS_TEST_TMPDIR/tombs.out"
  run complete_words tmuxkeep restore ''
  [ "$output" = old ]
  [[ "$(stub_calls)" == *'[ls] [--tombstones]' ]]
  [ -f "$TOMB_CACHE" ]
}

@test "a cache older than 60 seconds, or dated in the future, is fetched again" {
  printf 'stale\n' > "$CACHE"
  touch -t 200001010000 "$CACHE"
  run complete_words tmuxkeep go ''
  [[ "$output" == *api* ]]
  [[ "$output" != *stale* ]]
  printf 'stale\n' > "$CACHE"
  touch -t 209901010000 "$CACHE"
  run complete_words tmuxkeep go ''
  [[ "$output" != *stale* ]]
  [ "$(stub_calls | grep -c .)" -eq 2 ]
}

@test "a failed fetch is cached as an empty file for 60 seconds" {
  export TK_STUB_SSH_RC=255
  run complete_words tmuxkeep go ''
  [ -z "$output" ]
  [ -f "$CACHE" ]
  [ ! -s "$CACHE" ]
  run complete_words tmuxkeep go ''
  [ "$(stub_calls | grep -c .)" -eq 1 ]
}

@test "ssh's stderr is discarded" {
  export TK_STUB_SSH_ERR='Warning: Permanently added the host key'
  run --separate-stderr complete_words tmuxkeep go a
  [ -z "$stderr" ]
  [[ "$output" == *api* ]]
}

@test "no names after new, and nothing for a third word" {
  run complete_words tmuxkeep new ''
  [ -z "$output" ]
  run complete_words tmuxkeep go api ''
  [ -z "$output" ]
  [ ! -s "$TK_STUB_LOG" ]
}

@test "the typed prefix is matched literally, so a bracket is not a pattern" {
  run complete_words tmuxkeep go 'a['
  [ "$output" = 'a[b' ]
  run complete_words tmuxkeep go '*'
  [ -z "$output" ]
}

@test "a symlinked cache is neither read nor written through (plan Q15)" {
  printf 'planted\n' > "$BATS_TEST_TMPDIR/target"
  ln -s "$BATS_TEST_TMPDIR/target" "$CACHE"
  run complete_words tmuxkeep go ''
  [[ "$output" == *api* ]]
  [[ "$output" != *planted* ]]
  [ "$(cat "$BATS_TEST_TMPDIR/target")" = planted ]
  [ -L "$CACHE" ]
}

@test "TMPDIR with a trailing slash still gives one cache path" {
  export TMPDIR="$TMPDIR/"
  run complete_words tmuxkeep go ''
  [ -f "$CACHE" ]
}
