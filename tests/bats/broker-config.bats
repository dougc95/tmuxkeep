#!/usr/bin/env bats
# Broker configuration (spec 4.1, 4.4, 4.5, plan Q1, Q5): --check-conf, the parser rules,
# local-mode loading and the values taking effect. Remote-mode cases are in broker-remote.bats.
load helpers

FIX=/src/tests/fixtures/tmuxkeep.conf

setup() {
  setup_local
  C="$BATS_TEST_TMPDIR/c"
}
teardown() {
  teardown_local
  rm -f /etc/tmuxkeep/tmuxkeep.conf
}

check() { bash "$TMUXKEEP_BIN" --check-conf "$@" </dev/null; }
fresh() { cp "$FIX" "$C"; }

# rejects FILE REASON: --check-conf exits 1 and stderr is exactly "tmuxkeep: config invalid: FILE: REASON".
rejects() {
  run --separate-stderr check "$1"
  [ "$status" -eq 1 ] || { echo "status $status, wanted 1, for: $2"; return 1; }
  [[ "$stderr" == "tmuxkeep: config invalid: $1: $2" ]] || { echo "stderr: $stderr"; echo "wanted: tmuxkeep: config invalid: $1: $2"; return 1; }
}

fails_file() { printf '%s' "$TMUXKEEP_HOME/otp-fails"; }

# accepts FILE: --check-conf exits 0 and prints nothing.
accepts() {
  run --separate-stderr check "$1"
  [ "$status" -eq 0 ] || { echo "rejected: $stderr"; return 1; }
  [ -z "$output" ] && [ -z "$stderr" ]
}

@test "the fixture passes --check-conf silently" {
  accepts "$FIX"
}

@test "--check-conf needs exactly one argument (2)" {
  run --separate-stderr check
  [ "$status" -eq 2 ]
  [ "$stderr" = "tmuxkeep: usage: tmuxkeep --check-conf <file>" ]
  run --separate-stderr check "$FIX" extra
  [ "$status" -eq 2 ]
  [ "$stderr" = "tmuxkeep: usage: tmuxkeep --check-conf <file>" ]
}

@test "a relative path that starts with a hyphen is read as a file, not as options" {
  cd "$BATS_TEST_TMPDIR"
  { printf '\xef\xbb\xbf'; cat "$FIX"; } > ./-bom.conf
  rejects -bom.conf 'byte order mark found (save without BOM)'
  sed 's/$/\r/' "$FIX" > ./-cr.conf
  rejects -cr.conf 'carriage return found (use LF line endings)'
  cp "$FIX" ./-ok.conf
  accepts -ok.conf
}

@test "a missing file is 1 with 'cannot read'" {
  run --separate-stderr check "$BATS_TEST_TMPDIR/none"
  [ "$status" -eq 1 ]
  [ "$stderr" = "tmuxkeep: config invalid: $BATS_TEST_TMPDIR/none: cannot read" ]
}

@test "blank lines, comments, padding and a repeated key (the last wins) are accepted" {
  { printf '\n# a comment\n \t \n'
    sed 's/^\([A-Z_]*\)=\(.*\)$/  \1 =\t\2 \t/' "$FIX"
    printf 'SEND_MAX_BYTES=1\nSEND_MAX_BYTES=5\n'
  } > "$C"
  accepts "$C"
  export TMUXKEEP_CONF=$C
  mk_session api
  mk_lease t -
  run --separate-stderr tmuxkeep send api 123456
  [ "$status" -eq 2 ]
  [ "$stderr" = "tmuxkeep: text longer than 5 bytes" ]
}

@test "a BOM, a CR, a line without =, an unknown key and a non-printable value are rejected (1)" {
  local n=$(( $(wc -l < "$FIX") + 1 ))
  { printf '\xef\xbb\xbf'; cat "$FIX"; } > "$C"
  rejects "$C" 'byte order mark found (save without BOM)'
  sed 's/$/\r/' "$FIX" > "$C"
  rejects "$C" 'carriage return found (use LF line endings)'
  { cat "$FIX"; printf 'just words\n'; } > "$C"
  rejects "$C" "line $n: expected KEY=value"
  { cat "$FIX"; printf 'FROB=1\n'; } > "$C"
  rejects "$C" "line $n: unknown key FROB"
  { cat "$FIX"; printf 'user=claude\n'; } > "$C"
  rejects "$C" "line $n: unknown key user"
  { cat "$FIX"; printf 'B@D=1\n'; } > "$C"
  rejects "$C" "line $n: unknown key"
  fresh; conf_set_in "$C" LAUNCH_CMD "$(printf 'caf\xc3\xa9')"
  rejects "$C" 'line 8: non-printable or non-ASCII character in LAUNCH_CMD'
  fresh; conf_set_in "$C" LAUNCH_CMD "$(printf 'a\tb')"
  rejects "$C" 'line 8: non-printable or non-ASCII character in LAUNCH_CMD'
  fresh; conf_set_in "$C" LAUNCH_CMD "$(printf 'claude\xe3\x80\x80')"
  rejects "$C" 'line 8: non-printable or non-ASCII character in LAUNCH_CMD'
}

@test "a NUL byte anywhere in the file is rejected (1)" {
  { grep -v '^LAUNCH_CMD=' "$FIX"; printf 'LAUNCH_CMD=cla\0ude\n'; } > "$C"
  rejects "$C" 'NUL byte found'
  { printf '\0'; cat "$FIX"; } > "$C"
  rejects "$C" 'NUL byte found'
}

@test "every key is required" {
  local k
  for k in USER USER_HOME STATE_DIR WORK_DIR AUDIT_LOG LAUNCH_CMD RESUME_CMD LEASE_SECS TOMBSTONE_TTL \
           OTP_FAIL_MAX OTP_FAIL_WINDOW OTP_COOLDOWN OTP_HARD_MAX OTP_READ_TIMEOUT SEND_MAX_BYTES; do
    grep -v "^$k=" "$FIX" > "$C"
    rejects "$C" "$k: required" || return 1
  done
}

@test "error precedence: file checks, then lines, then required keys, then validation in list order" {
  local n
  # BOM before CR, CR before NUL.
  { printf '\xef\xbb\xbf'; sed 's/$/\r/' "$FIX"; } > "$C"
  rejects "$C" 'byte order mark found (save without BOM)'
  { sed 's/$/\r/' "$FIX"; printf '\0'; } > "$C"
  rejects "$C" 'carriage return found (use LF line endings)'
  # A bad line beats a missing key, and the first bad line is the one reported.
  { grep -v '^USER=' "$FIX"; printf 'FROB=1\n'; } > "$C"
  n=$(wc -l < "$C")
  rejects "$C" "line $n: unknown key FROB"
  n=$(( $(wc -l < "$FIX") + 1 ))
  { cat "$FIX"; printf 'FROB=1\njust words\n'; } > "$C"
  rejects "$C" "line $n: unknown key FROB"
  # A missing key beats an invalid value.
  { grep -v '^SEND_MAX_BYTES=' "$FIX"; printf 'USER=Bob\n'; } > "$C"
  rejects "$C" 'SEND_MAX_BYTES: required'
  # Values are validated in key-list order, not in file order.
  { cat "$FIX"; printf 'LEASE_SECS=5\nUSER=Bob\n'; } > "$C"
  rejects "$C" 'USER: must match ^[a-z_][a-z0-9_-]{0,31}$'
  # Validation sees the last of a repeated key.
  { cat "$FIX"; printf 'LEASE_SECS=5\nLEASE_SECS=60\n'; } > "$C"
  accepts "$C"
  { cat "$FIX"; printf 'LEASE_SECS=60\nLEASE_SECS=5\n'; } > "$C"
  rejects "$C" 'LEASE_SECS: must be an integer from 60 to 86400'
}

@test "each tunable is accepted at its bounds and rejected just outside them" {
  local row k lo hi
  for row in LEASE_SECS:60:86400 TOMBSTONE_TTL:3600:2592000 OTP_FAIL_WINDOW:60:86400 OTP_COOLDOWN:10:86400 \
             OTP_READ_TIMEOUT:10:600 SEND_MAX_BYTES:1:65536 OTP_HARD_MAX:3:100; do
    IFS=: read -r k lo hi <<< "$row"
    fresh; conf_set_in "$C" "$k" "$lo"; accepts "$C" || { echo "$k=$lo"; return 1; }
    fresh; conf_set_in "$C" "$k" "$hi"; accepts "$C" || { echo "$k=$hi"; return 1; }
    fresh; conf_set_in "$C" "$k" "$(( lo - 1 ))"; rejects "$C" "$k: must be an integer from $lo to $hi" || return 1
    fresh; conf_set_in "$C" "$k" "$(( hi + 1 ))"; rejects "$C" "$k: must be an integer from $lo to $hi" || return 1
  done
}

@test "OTP_FAIL_MAX is 1-20 and OTP_HARD_MAX may not be below it" {
  fresh
  conf_set_in "$C" OTP_HARD_MAX 100
  conf_set_in "$C" OTP_FAIL_MAX 1; accepts "$C"
  conf_set_in "$C" OTP_FAIL_MAX 20; accepts "$C"
  conf_set_in "$C" OTP_FAIL_MAX 0; rejects "$C" 'OTP_FAIL_MAX: must be an integer from 1 to 20'
  conf_set_in "$C" OTP_FAIL_MAX 21; rejects "$C" 'OTP_FAIL_MAX: must be an integer from 1 to 20'
  conf_set_in "$C" OTP_FAIL_MAX 12
  conf_set_in "$C" OTP_HARD_MAX 11
  rejects "$C" 'OTP_HARD_MAX: must be an integer from 12 to 100'
}

@test "integers are 1-7 decimal digits; signs, inner spaces and other text are rejected" {
  local v
  fresh; conf_set_in "$C" LEASE_SECS 0060; accepts "$C"
  fresh; conf_set_in "$C" LEASE_SECS 0000099; accepts "$C"
  for v in '' abc -60 +60 '6 0' 1e3 12345678 0x40; do
    fresh; conf_set_in "$C" LEASE_SECS "$v"
    rejects "$C" 'LEASE_SECS: must be an integer from 60 to 86400' || { echo "value '$v'"; return 1; }
  done
}

@test "USER, the four paths and the two commands are validated" {
  local v k
  for v in claude _svc a-b x "$(printf 'a%.0s' $(seq 1 32))"; do
    fresh; conf_set_in "$C" USER "$v"; accepts "$C" || { echo "USER=$v"; return 1; }
  done
  for v in '' Bob 1abc -x 'a b' "$(printf 'a%.0s' $(seq 1 33))"; do
    fresh; conf_set_in "$C" USER "$v"
    rejects "$C" 'USER: must match ^[a-z_][a-z0-9_-]{0,31}$' || { echo "USER=$v"; return 1; }
  done
  for k in USER_HOME STATE_DIR WORK_DIR AUDIT_LOG; do
    for v in '' home/claude / /home/../etc /home/./x '/home/cl aude' /home/x//y "/$(printf 'a%.0s' $(seq 1 255))"; do
      fresh; conf_set_in "$C" "$k" "$v"
      rejects "$C" "$k: must be an absolute path made of letters, digits, dot, underscore, hyphen and slash" || { echo "$k=$v"; return 1; }
    done
    fresh; conf_set_in "$C" "$k" /srv/tk-1/x_y.z; accepts "$C" || { echo "$k"; return 1; }
  done
  for k in LAUNCH_CMD RESUME_CMD; do
    fresh; conf_set_in "$C" "$k" ''; accepts "$C" || return 1
    fresh; conf_set_in "$C" "$k" "$(printf 'x%.0s' $(seq 1 200))"; accepts "$C" || return 1
    fresh; conf_set_in "$C" "$k" "$(printf 'x%.0s' $(seq 1 201))"
    rejects "$C" "$k: at most 200 characters" || return 1
  done
}

@test "SEND_MAX_BYTES, LEASE_SECS and TOMBSTONE_TTL from TMUXKEEP_CONF take effect" {
  conf_set SEND_MAX_BYTES 5
  conf_set LEASE_SECS 60
  conf_set TOMBSTONE_TTL 3600
  mk_session api
  mk_lease t - $(( FIXED_NOW - 59 ))
  run tmuxkeep send api 12345
  [ "$status" -eq 0 ]
  run --separate-stderr tmuxkeep send api 123456
  [ "$status" -eq 2 ]
  [ "$stderr" = "tmuxkeep: text longer than 5 bytes" ]
  mk_lease t - $(( FIXED_NOW - 61 ))
  run tmuxkeep send api 12345
  [ "$status" -eq 4 ]
  mk_session "zz~old~$(( FIXED_NOW - 3601 ))"
  mk_session "zz~new~$(( FIXED_NOW - 3599 ))"
  run tmuxkeep reap
  [ "$status" -eq 0 ]
  run session_names
  [[ "$output" == *"zz~new~$(( FIXED_NOW - 3599 ))"* ]]
  [[ "$output" != *zz~old~* ]]
}

@test "OTP_FAIL_MAX from TMUXKEEP_CONF takes effect: one wrong code starts the cooldown" {
  conf_set OTP_FAIL_MAX 1
  run with_tty 000001 --key t auth
  [ "$status" -eq 4 ]
  run --separate-stderr tmuxkeep auth
  [ "$status" -eq 4 ]
  [ "$stderr" = "tmuxkeep: cooldown, retry in 300s" ]
}

@test "OTP_COOLDOWN from TMUXKEEP_CONF takes effect: the cooldown lasts exactly that long" {
  conf_set OTP_FAIL_MAX 1
  conf_set OTP_FAIL_WINDOW 3000
  conf_set OTP_COOLDOWN 1000
  printf '%s\n' "$FIXED_NOW" > "$(fails_file)"
  export TMUXKEEP_NOW=$(( FIXED_NOW + 999 ))
  run --separate-stderr tmuxkeep auth
  [ "$status" -eq 4 ]
  [ "$stderr" = "tmuxkeep: cooldown, retry in 1s" ]
  export TMUXKEEP_NOW=$(( FIXED_NOW + 1000 ))
  run --separate-stderr tmuxkeep auth
  [ "$status" -eq 4 ]
  [[ "$stderr" == *"TOTP required"* ]]
}

@test "OTP_FAIL_WINDOW from TMUXKEEP_CONF takes effect: only failures inside it count" {
  # A narrow window: three failures 80-100s old fall outside 60s, so there is no cooldown.
  conf_set OTP_FAIL_WINDOW 60
  printf '%s\n' $(( FIXED_NOW - 100 )) $(( FIXED_NOW - 90 )) $(( FIXED_NOW - 80 )) > "$(fails_file)"
  run --separate-stderr tmuxkeep auth
  [ "$status" -eq 4 ]
  [[ "$stderr" == *"TOTP required"* ]]
  # A wide window: failures 2500s and 2400s old still count together with the one 100s old.
  conf_set OTP_FAIL_WINDOW 3000
  printf '%s\n' $(( FIXED_NOW - 2500 )) $(( FIXED_NOW - 2400 )) $(( FIXED_NOW - 100 )) > "$(fails_file)"
  run --separate-stderr tmuxkeep auth
  [ "$status" -eq 4 ]
  [ "$stderr" = "tmuxkeep: cooldown, retry in 200s" ]
}

@test "OTP_HARD_MAX from TMUXKEEP_CONF takes effect: otp-locked appears at that many recorded failures" {
  conf_set OTP_HARD_MAX 4
  printf '%s\n' $(( FIXED_NOW - 5000 )) $(( FIXED_NOW - 4000 )) > "$(fails_file)"
  run with_tty 000001 --key t auth
  [ "$status" -eq 4 ]
  [ ! -e "$TMUXKEEP_HOME/otp-locked" ]
  run with_tty 000001 --key t auth
  [ "$status" -eq 4 ]
  [ -e "$TMUXKEEP_HOME/otp-locked" ]
  run --separate-stderr tmuxkeep auth
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"OTP locked"* ]]
}

# OTP_READ_TIMEOUT only feeds "read -t" in the gate, and the smallest allowed value is 10s, so
# a behavioural test would have to wait that long. This one checks the mapping itself instead,
# for all eleven runtime globals, with leading zeros that octal would misread (011 is 9).
@test "apply_conf maps every config value to its runtime global, read as decimal" {
  fresh
  conf_set_in "$C" STATE_DIR /srv/tk/state
  conf_set_in "$C" WORK_DIR /srv/tk/work
  conf_set_in "$C" AUDIT_LOG /srv/tk/audit.log
  conf_set_in "$C" LEASE_SECS 0061
  conf_set_in "$C" TOMBSTONE_TTL 3601
  conf_set_in "$C" OTP_FAIL_MAX 02
  conf_set_in "$C" OTP_FAIL_WINDOW 0061
  conf_set_in "$C" OTP_COOLDOWN 011
  conf_set_in "$C" OTP_HARD_MAX 012
  conf_set_in "$C" OTP_READ_TIMEOUT 013
  conf_set_in "$C" SEND_MAX_BYTES 0014
  run bash -c 'source "$1"; parse_conf "$2" && apply_conf && echo "$STATE_DIR $WORK_DIR $AUDIT_FILE $LEASE_SECS $TOMBSTONE_TTL $OTP_FAIL_MAX $OTP_FAIL_WINDOW $OTP_COOLDOWN $OTP_HARD_MAX $OTP_READ_TIMEOUT $SEND_MAX_BYTES"' _ "$TMUXKEEP_BIN" "$C"
  [ "$status" -eq 0 ]
  [ "$output" = "/srv/tk/state /srv/tk/work /srv/tk/audit.log 61 3601 2 61 11 12 13 14" ]
}

@test "AUDIT_LOG, STATE_DIR and WORK_DIR come from the config when no TMUXKEEP_* override is set" {
  local d="$BATS_TEST_TMPDIR/cfgpaths"
  mkdir -p "$d/state/leases" "$d/work"
  cp "$TMUXKEEP_HOME/totp.secret" "$TMUXKEEP_HOME/last-otp" "$d/state/"
  printf '%s\n' "$FIXED_NOW" > "$d/state/leases/t@-"
  conf_set AUDIT_LOG "$d/audit.log"
  conf_set STATE_DIR "$d/state"
  conf_set WORK_DIR "$d/work"
  unset TMUXKEEP_AUDIT TMUXKEEP_HOME TMUXKEEP_WORK
  run tmuxkeep new api
  [ "$status" -eq 0 ]
  [ "$output" = "created api in $d/work/api" ]
  [ "$(wc -l < "$d/audit.log")" -eq 1 ]
}

@test "local mode without TMUXKEEP_CONF reads /etc/tmuxkeep/tmuxkeep.conf when it exists (plan Q1)" {
  cp "$FIX" /etc/tmuxkeep/tmuxkeep.conf
  conf_set_in /etc/tmuxkeep/tmuxkeep.conf AUDIT_LOG "$BATS_TEST_TMPDIR/sys.log"
  unset TMUXKEEP_CONF TMUXKEEP_AUDIT
  run tmuxkeep log
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$BATS_TEST_TMPDIR/sys.log")" -eq 1 ]
}

@test "local mode with no config file at all uses the built-in defaults" {
  rm -f /etc/tmuxkeep/tmuxkeep.conf
  unset TMUXKEEP_CONF TMUXKEEP_AUDIT
  mkdir -p /var/log/tmuxkeep
  : > /var/log/tmuxkeep/audit.log
  run tmuxkeep log
  [ "$status" -eq 0 ]
  [ "$(wc -l < /var/log/tmuxkeep/audit.log)" -eq 1 ]
  : > /var/log/tmuxkeep/audit.log
}

@test "local mode: an invalid TMUXKEEP_CONF or system file is 1 and writes no audit line" {
  printf 'FROB=1\n' > "$TMUXKEEP_CONF"
  run --separate-stderr tmuxkeep log
  [ "$status" -eq 1 ]
  [ "$stderr" = "tmuxkeep: config invalid: $TMUXKEEP_CONF: line 1: unknown key FROB" ]
  [ "$(audit_count)" -eq 0 ]
  printf 'FROB=1\n' > /etc/tmuxkeep/tmuxkeep.conf
  unset TMUXKEEP_CONF
  run --separate-stderr tmuxkeep log
  [ "$status" -eq 1 ]
  [ "$stderr" = "tmuxkeep: config invalid: /etc/tmuxkeep/tmuxkeep.conf: line 1: unknown key FROB" ]
  [ "$(audit_count)" -eq 0 ]
}

@test "an empty TMUXKEEP_CONF counts as unset" {
  rm -f /etc/tmuxkeep/tmuxkeep.conf
  export TMUXKEEP_CONF=
  run tmuxkeep log
  [ "$status" -eq 0 ]
  [ "$(audit_count)" -eq 1 ]
}

@test "--check-conf never writes an audit line" {
  run check "$FIX"
  printf 'FROB=1\n' > "$C"
  run check "$C"
  [ "$(audit_count)" -eq 0 ]
}
