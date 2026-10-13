#!/usr/bin/env bats
# rename, rm (soft and --now) and restore (spec 6, 7.2).
load helpers
setup() { setup_local; mk_lease t -; }
teardown() { teardown_local; }

no_lease() { rm -f "$TMUXKEEP_HOME"/leases/*; }
pane_pid() { tm display-message -p -t "=$1:" '#{pane_pid}'; }

# ---- rename ----
@test "rename keeps the work directory and the processes" {
  mkdir -p "$TMUXKEEP_WORK/api"
  mk_session api "$TMUXKEEP_WORK/api"
  local pid
  pid=$(pane_pid api)
  run tmuxkeep rename api web
  [ "$status" -eq 0 ]
  [ "$output" = "renamed api to web" ]
  [ "$(session_names)" = web ]
  [ "$(tm display-message -p -t '=web:' '#{session_path}')" = "$TMUXKEEP_WORK/api" ]
  [ "$(pane_pid web)" = "$pid" ]
  [ -d "$TMUXKEEP_WORK/api" ]
  [ ! -e "$TMUXKEEP_WORK/web" ]
}

@test "after a rename, new with the old name is refused: directory in use (3)" {
  mkdir -p "$TMUXKEEP_WORK/api"
  mk_session api "$TMUXKEEP_WORK/api"
  tmuxkeep rename api web
  run --separate-stderr tmuxkeep new api
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"in use"* ]]
}

@test "rename refuses a live or tombstoned target name (3)" {
  mk_session api
  mk_session web
  mk_session 'zz~old~1789990000'
  run tmuxkeep rename api web
  [ "$status" -eq 3 ]
  run tmuxkeep rename api old
  [ "$status" -eq 3 ]
  [ "$(session_names | sort | tr '\n' ' ')" = "api web zz~old~1789990000 " ]
}

@test "rename: missing source (5), bad names (2), wrong arity (2), no lease (4)" {
  mk_session api
  run tmuxkeep rename nosuch web
  [ "$status" -eq 5 ]
  run tmuxkeep rename api 1web
  [ "$status" -eq 2 ]
  run tmuxkeep rename 'zz~api~1' web
  [ "$status" -eq 2 ]
  run tmuxkeep rename api
  [ "$status" -eq 2 ]
  run tmuxkeep rename api web extra
  [ "$status" -eq 2 ]
  no_lease
  run tmuxkeep rename api web
  [ "$status" -eq 4 ]
}

# ---- rm ----
@test "rm tombstones the session and leaves its process running" {
  mk_session_cmd api 'exec sleep 300'
  local pid
  pid=$(pane_pid api)
  run tmuxkeep rm api
  [ "$status" -eq 0 ]
  [ "$output" = "tombstoned api; still running, reaped after 24h; restore with: tmuxkeep restore api" ]
  [ "$(session_names)" = "zz~api~$TMUXKEEP_NOW" ]
  kill -0 "$pid"
  [ "$(audit_field detail)" = tombstoned ]
  [ "$(audit_field session)" = api ]
}

@test "rm says how long the tombstone lives, from TOMBSTONE_TTL: hours when it is a multiple of 3600, else seconds" {
  local ttl want
  for ttl in 3600:1h 7200:2h 86400:24h 2592000:720h 3601:3601s 5400:5400s 86399:86399s; do
    conf_set TOMBSTONE_TTL "${ttl%%:*}"
    want="tombstoned api; still running, reaped after ${ttl#*:}; restore with: tmuxkeep restore api"
    mk_session api
    run tmuxkeep rm api
    [ "$status" -eq 0 ]
    [ "$output" = "$want" ] || { echo "ttl ${ttl%%:*}: $output"; return 1; }
    tm kill-server
  done
}

@test "rm refuses a locked session, with or without --now (3)" {
  mk_session api
  tm set-option -t '=api:' @tmuxkeep_locked 1
  run --separate-stderr tmuxkeep rm api
  [ "$status" -eq 3 ]
  [[ "$stderr" == *locked* ]]
  run tmuxkeep rm api --now --confirm api
  [ "$status" -eq 3 ]
  [ "$(session_names)" = api ]
}

@test "rm --now needs --confirm equal to the name (2)" {
  mk_session api
  run tmuxkeep rm api --now
  [ "$status" -eq 2 ]
  run tmuxkeep rm api --now --confirm apix
  [ "$status" -eq 2 ]
  run tmuxkeep rm api --now --confirm
  [ "$status" -eq 2 ]
  run tmuxkeep rm api --confirm api
  [ "$status" -eq 2 ]
  [ "$(session_names)" = api ]
}

@test "rm --now kills a live session; option order is free" {
  mk_session api
  mk_session web
  run tmuxkeep rm api --now --confirm api
  [ "$status" -eq 0 ]
  [ "$output" = "killed api" ]
  run tmuxkeep rm --now --confirm web web
  [ "$status" -eq 0 ]
  [ -z "$(session_names)" ]
}

@test "rm --now <base> kills only the newest tombstone" {
  mk_session 'zz~api~1789990000'
  mk_session 'zz~api~1789995000'
  run tmuxkeep rm api --now --confirm api
  [ "$status" -eq 0 ]
  [ "$output" = "killed zz~api~1789995000" ]
  [ "$(session_names)" = 'zz~api~1789990000' ]
}

@test "rm --now <tombstone> kills that tombstone" {
  mk_session 'zz~api~1789990000'
  run tmuxkeep rm 'zz~api~1789990000' --now --confirm 'zz~api~1789990000'
  [ "$status" -eq 0 ]
  [ -z "$(session_names)" ]
}

@test "rm without --now rejects a tombstone name (2)" {
  mk_session 'zz~api~1789990000'
  run tmuxkeep rm 'zz~api~1789990000'
  [ "$status" -eq 2 ]
}

@test "rm: missing session (5) with and without --now; no lease (4)" {
  run tmuxkeep rm api
  [ "$status" -eq 5 ]
  run tmuxkeep rm api --now --confirm api
  [ "$status" -eq 5 ]
  mk_session api
  no_lease
  run tmuxkeep rm api
  [ "$status" -eq 4 ]
  [ "$(session_names)" = api ]
}

# ---- restore ----
@test "rm then restore round-trips the same running session, without a lease" {
  mk_session_cmd api 'exec sleep 300'
  local pid
  pid=$(pane_pid api)
  tmuxkeep rm api
  no_lease
  run tmuxkeep restore api
  [ "$status" -eq 0 ]
  [ "$output" = "restored api" ]
  [ "$(session_names)" = api ]
  [ "$(pane_pid api)" = "$pid" ]
  [ "$(audit_field detail)" = "restored from zz~api~$TMUXKEEP_NOW" ]
}

@test "restore picks the greatest epoch" {
  mk_session_cmd 'zz~api~1789990000' 'exec sleep 300'
  mk_session_cmd 'zz~api~1789995000' 'exec sleep 301'
  run tmuxkeep restore api
  [ "$status" -eq 0 ]
  [ "$(session_names | sort | tr '\n' ' ')" = "api zz~api~1789990000 " ]
}

@test "restore: no tombstone (5), live name exists (3), tombstone name as input (2)" {
  run tmuxkeep restore api
  [ "$status" -eq 5 ]
  mk_session api
  mk_session 'zz~api~1789990000'
  run tmuxkeep restore api
  [ "$status" -eq 3 ]
  run tmuxkeep restore 'zz~api~1789990000'
  [ "$status" -eq 2 ]
}
