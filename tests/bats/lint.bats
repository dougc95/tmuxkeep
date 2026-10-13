#!/usr/bin/env bats
# Static checks on the broker. Every constant is used, so shellcheck runs with no exclusions
# (TMUXKEEP_VERSION carries its own disable directive in the broker).
load helpers

@test "broker passes bash -n and shellcheck -S warning with no exclusions" {
  run bash -n "$TMUXKEEP_BIN"
  [ "$status" -eq 0 ]
  run shellcheck -S warning "$TMUXKEEP_BIN"
  [ "$status" -eq 0 ]
}

@test "GATED_VERBS is one line in the agreed format" {
  run grep -c '^GATED_VERBS=' "$TMUXKEEP_BIN"
  [ "$output" = 1 ]
  grep -qx 'GATED_VERBS="new go send rename unlock rm resume auth"' "$TMUXKEEP_BIN"
}

@test "TMUXKEEP_VERSION=dev appears exactly once" {
  run grep -c '^TMUXKEEP_VERSION=dev$' "$TMUXKEEP_BIN"
  [ "$output" = 1 ]
}

@test "constants have the spec values" {
  local c
  for c in LEASE_SECS=1800 TOMBSTONE_TTL=86400 OTP_STEP=30 OTP_FAIL_MAX=3 OTP_FAIL_WINDOW=600 \
           OTP_COOLDOWN=300 OTP_HARD_MAX=10 OTP_READ_TIMEOUT=60 SEND_ENTER_DELAY=0.3 SEND_MAX_BYTES=8000; do
    grep -qx "$c" "$TMUXKEEP_BIN" || { echo "missing: $c"; return 1; }
  done
}

@test "no eval and no has-session anywhere" {
  run grep -nE '(^|[^a-z_])eval[[:space:]]|has-session' "$TMUXKEEP_BIN"
  [ "$status" -eq 1 ]
}

@test "broker has no carriage returns" {
  run grep -c $'\r' "$TMUXKEEP_BIN"
  [ "$output" = 0 ]
}

@test "the broker never sources a file" {
  run grep -nE '^[[:space:]]*(source|\.)[[:space:]]' "$TMUXKEEP_BIN"
  [ "$status" -eq 1 ]
}

@test "every shell file of spec 9.5 passes shellcheck --shell=bash -S warning" {
  local f
  for f in vps/tmuxkeep vps/tmuxkeep-setup vps/vps-facts.sh laptop/tmuxkeep.sh laptop/deploy.sh \
           laptop/completion.bash tests/bats/stubs/oathtool tests/bats/stubs/ssh tests/bats/stubs/scp \
           tests/bats/stubs/ssh-keygen tests/bats/helpers.bash tests/bats/laptop-helpers.bash \
           tests/smoke.sh tests/run-bats.sh; do
    [ -f "/src/$f" ] || { echo "missing: $f"; return 1; }
    run shellcheck --shell=bash -S warning "/src/$f"
    [ "$status" -eq 0 ] || { echo "$f:"; echo "$output"; return 1; }
  done
  [ "$(ls /src/tests/bats/stubs | LC_ALL=C sort | tr '\n' ' ')" = 'oathtool scp ssh ssh-keygen ' ]
}
