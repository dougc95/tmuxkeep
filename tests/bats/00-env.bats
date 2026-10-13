#!/usr/bin/env bats
# Sanity checks for the test image and the mounted repo.
load helpers

@test "required tools are present" {
  local t
  for t in bash tmux bats oathtool jq script flock base64 base32 git visudo shellcheck timeout zsh; do
    command -v "$t" >/dev/null || { echo "missing: $t"; return 1; }
  done
  [ -x /usr/sbin/sshd ]
}

@test "tmux is 3.0 or newer" {
  run tmux -V
  [ "$status" -eq 0 ]
  local v=${output#tmux }
  [ "${v%%.*}" -ge 3 ]
}

@test "repo is mounted read-only at /src" {
  [ -f /src/tests/bats/helpers.bash ]
  run touch /src/.write-probe
  [ "$status" -ne 0 ]
}

@test "real oathtool accepts - to read the key from stdin (spec 14)" {
  local a b
  a=$(printf 'JBSWY3DPEHPK3PXP' | oathtool --totp -b -N @0 -)
  b=$(oathtool --totp -b -N @0 JBSWY3DPEHPK3PXP)
  [ "$a" = "$b" ]
  [[ "$a" =~ ^[0-9]{6}$ ]]
}

@test "oathtool stub is deterministic and logs argv only" {
  setup_local
  run bash -c "printf secret | '$TMUXKEEP_OATHTOOL' --totp -b -N @$(( 59666666 * 30 )) -"
  [ "$status" -eq 0 ]
  [ "$output" = 666666 ]
  run grep -c secret "$OATH_STUB_LOG"
  [ "$output" = 0 ]
}

@test "script(1) gives the child a terminal" {
  run script -qec 'test -t 0 && echo tty' /dev/null
  [ "$status" -eq 0 ]
  [[ "$(strip_cr "$output")" == *tty* ]]
}

@test "no carriage returns under vps/, tests/ or in the laptop bash files" {
  run grep -rlI $'\r' /src/vps /src/tests /src/laptop/tmuxkeep.sh /src/laptop/deploy.sh /src/laptop/completion.bash
  [ "$status" -eq 1 ]
}
