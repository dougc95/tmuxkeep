#!/usr/bin/env bats
# tests/smoke.sh driven by a fake wrapper that simulates the broker (spec 9.7). Never the real one.
load laptop-helpers

setup() {
  laptop_setup
  export TK_FAKE_DIR="$BATS_TEST_TMPDIR/fake"
  mkdir -p "$TK_FAKE_DIR"
  unset TK_FAKE_IGNORE_LOCK TK_FAKE_RM_NOW_LOCKED TK_FAKE_STATUS_EMPTY TK_FAKE_STATUS_BAD TK_FAKE_STATUS_STDERR TK_FAKE_STATUS_UNAUDITED TK_SMOKE_JQ
  SMOKE="$REPO/tests/smoke.sh"
  FAKE="$BATS_TEST_TMPDIR/fake-tmuxkeep"
  cat > "$FAKE" <<'EOF'
#!/usr/bin/env bash
# Fake wrapper: simulates the broker for smoke.sh tests. State lives in $TK_FAKE_DIR.
dir=$TK_FAKE_DIR
printf '%s\n' "$*" >> "$dir/calls.log"
verb=${1:-}
name=${2:-}
state=''
n=''
if [ -f "$dir/state" ]; then state=$(cat "$dir/state"); fi
if [ -f "$dir/name" ]; then n=$(cat "$dir/name"); fi
case $verb in
  auth) exit 0 ;;
  new) printf '%s\n' "$name" > "$dir/name"; echo live > "$dir/state"
       echo "created $name in /home/claude/work/$name"; exit 0 ;;
  ls) echo 'NAME  STATE  ATTACHED  AGE  IDLE  TITLE'
      if [ "$state" = live ]; then echo "$n  live    1m  1m  x"; fi
      if [ "$state" = tombstone ]; then echo "zz~$n~1790000000  tombstone    1m  1m  x"; fi
      exit 0 ;;
  peek) echo 'some pane text'; exit 0 ;;
  send) echo "sent 5 bytes to $name"; exit 0 ;;
  lock) echo 1 > "$dir/locked"; echo "locked $name"; exit 0 ;;
  unlock) rm -f "$dir/locked"; echo "unlocked $name"; exit 0 ;;
  rm) if [ -f "$dir/locked" ] && [ -z "${TK_FAKE_IGNORE_LOCK:-}" ]; then exit 3; fi
      case " $* " in
        *' --now '*)
          if [ -n "${TK_FAKE_RM_NOW_LOCKED:-}" ]; then exit 3; fi
          echo gone > "$dir/state"; echo "killed $name"; exit 0 ;;
      esac
      echo tombstone > "$dir/state"
      echo "tombstoned $name; still running, reaped after 24h; restore with: tmuxkeep restore $name"; exit 0 ;;
  restore) echo live > "$dir/state"; echo "restored $name"; exit 0 ;;
  status) if [ -n "${TK_FAKE_STATUS_STDERR:-}" ]; then echo 'warning: a stderr line that is not JSON' >&2; fi
          if [ -n "${TK_FAKE_STATUS_BAD:-}" ]; then printf '{"sessions":[{"name":"%s"}\n' "$n"; exit 0; fi
          if [ "$state" = live ] && [ -z "${TK_FAKE_STATUS_EMPTY:-}" ]; then
            printf '{"version":"x","sessions":[{"name":"%s","state":"live"}]}\n' "$n"
          else
            printf '{"version":"x","sessions":[]}\n'
          fi
          exit 0 ;;
  log) while IFS= read -r c; do
         v=${c%% *}
         s=''
         case $c in *' '*) s=${c#* }; s=${s%% *} ;; esac
         if [ "$v" = status ] && [ -n "${TK_FAKE_STATUS_UNAUDITED:-}" ]; then continue; fi
         printf '{"verb":"%s","session":"%s"}\n' "$v" "$s"
       done < "$dir/calls.log"
       exit 0 ;;
  *) exit 2 ;;
esac
EOF
  chmod +x "$FAKE"
}

calls() { cat "$TK_FAKE_DIR/calls.log"; }

@test "passes against a broker that behaves" {
  run "$BASH" "$SMOKE" --wrapper "$FAKE"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *'smoke: all steps passed'* ]]
  [ "$(printf '%s\n' "$output" | grep -c '^PASS ')" -eq 14 ]
}

@test "runs auth first and uses a fresh smoke- name of 6 characters" {
  run "$BASH" "$SMOKE" --wrapper "$FAKE"
  [ "$(calls | sed -n 1p)" = auth ]
  calls | sed -n 2p | grep -Eqx 'new smoke-[a-z0-9]{6}'
}

@test "fails with exit 1 when rm is not refused on a locked session, and stops there" {
  export TK_FAKE_IGNORE_LOCK=1
  run "$BASH" "$SMOKE" --wrapper "$FAKE"
  [ "$status" -eq 1 ]
  [[ "$output" == *FAIL* ]]
  [[ "$output" != *'smoke: all steps passed'* ]]
  calls | tail -n 1 | grep -Eqx 'rm smoke-[a-z0-9]{6}'
}

@test "prints the cleanup hint once, restore before unlock, when rm --now is refused as locked" {
  export TK_FAKE_RM_NOW_LOCKED=1
  run "$BASH" "$SMOKE" --wrapper "$FAKE"
  [ "$status" -eq 1 ]
  [[ "$output" == *'FAIL 13/14'* ]]
  printf '%s\n' "$output" | grep -Eq 'tmuxkeep rm smoke-[a-z0-9]{6} --now --confirm smoke-[a-z0-9]{6}'
  printf '%s\n' "$output" | grep -Eq "restore smoke-[a-z0-9]{6}'.*'tmuxkeep unlock smoke-"
  [ "$(printf '%s\n' "$output" | grep -c 'To clean it up')" -eq 1 ]
}

@test "a missing wrapper and an unknown argument stop at once" {
  run "$BASH" "$SMOKE" --wrapper "$BATS_TEST_TMPDIR/nope"
  [ "$status" -eq 1 ]
  [[ "$output" == 'FAIL setup: wrapper not found or not executable: '* ]]
  run "$BASH" "$SMOKE" --frob
  [ "$status" -eq 2 ]
  [ ! -e "$TK_FAKE_DIR/calls.log" ]
}

@test "the default wrapper is ~/.local/bin/tmuxkeep" {
  grep -qx 'TK_WRAPPER=$HOME/.local/bin/tmuxkeep' "$SMOKE"
}

@test "the session name comes from a bounded read of /dev/urandom (BSD tr never ends on an unbounded one where SIGPIPE is ignored)" {
  [ "$(grep -c '/dev/urandom' "$SMOKE")" -eq 1 ]
  grep -qF 'od -An -N3 -tx1 /dev/urandom' "$SMOKE"
}

@test "finishes when SIGPIPE is ignored, as it is under GitHub Actions and other Node-spawned shells" {
  local out pid i
  out=$BATS_TEST_TMPDIR/sigpipe.out
  "$BASH" -c 'trap "" PIPE; exec "$0" "$@"' "$BASH" "$SMOKE" --wrapper "$FAKE" > "$out" 2>&1 3>&- &
  pid=$!
  i=0
  while kill -0 "$pid" 2>/dev/null; do
    i=$((i + 1))
    if [ "$i" -gt 300 ]; then
      kill "$pid" 2>/dev/null || true
      echo 'smoke.sh did not finish within 30 s with SIGPIPE ignored'
      return 1
    fi
    sleep 0.1
  done
  wait "$pid"
  grep -q 'smoke: all steps passed' "$out"
}

@test "step 4 fails, with the cleanup hint, when the status JSON does not name the session" {
  export TK_FAKE_STATUS_EMPTY=1
  run "$BASH" "$SMOKE" --wrapper "$FAKE"
  [ "$status" -eq 1 ]
  [[ "$output" == *'FAIL 4/14 status (JSON naming the session): the status output does not name smoke-'* ]]
  [ "$(printf '%s\n' "$output" | grep -c 'To clean it up')" -eq 1 ]
  [ "$(calls | tail -n 1)" = status ]
  # The same failure without jq: the fixed-string fallback must reject a status that lacks the name.
  export TK_FAKE_DIR="$BATS_TEST_TMPDIR/fake2"
  mkdir -p "$TK_FAKE_DIR"
  export TK_SMOKE_JQ=no-such-jq-program
  run "$BASH" "$SMOKE" --wrapper "$FAKE"
  [ "$status" -eq 1 ]
  [[ "$output" == *'FAIL 4/14 status (JSON naming the session): the status output does not name smoke-'* ]]
  [ "$(printf '%s\n' "$output" | grep -c 'To clean it up')" -eq 1 ]
  [ "$(calls | tail -n 1)" = status ]
}

@test "step 4 reads stdout only: a stderr line on a successful status does not fail it" {
  export TK_FAKE_STATUS_STDERR=1
  run "$BASH" "$SMOKE" --wrapper "$FAKE"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *'PASS 4/14 status (JSON naming the session)'* ]]
  [[ "$output" == *'smoke: all steps passed'* ]]
}

@test "step 14 fails when the audit log has no status line, as with a broker that does not audit status (amended D19)" {
  export TK_FAKE_STATUS_UNAUDITED=1
  run "$BASH" "$SMOKE" --wrapper "$FAKE"
  [ "$status" -eq 1 ]
  [[ "$output" == *'FAIL 14/14 log -n 20 (audit lines for this session): no audit line with verb status and no session'* ]]
  [[ "$output" != *'smoke: all steps passed'* ]]
}

@test "step 4 rejects output that is not JSON when jq is installed, and matches the name as text without jq" {
  export TK_FAKE_STATUS_BAD=1
  if command -v jq >/dev/null; then
    run "$BASH" "$SMOKE" --wrapper "$FAKE"
    [ "$status" -eq 1 ]
    [[ "$output" == *'FAIL 4/14'* ]]
  fi
  export TK_FAKE_DIR="$BATS_TEST_TMPDIR/fake2"
  mkdir -p "$TK_FAKE_DIR"
  export TK_SMOKE_JQ=no-such-jq-program
  run "$BASH" "$SMOKE" --wrapper "$FAKE"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *'PASS 4/14 status (JSON naming the session)'* ]]
}
