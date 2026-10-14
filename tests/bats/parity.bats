#!/usr/bin/env bats
# Parity (spec 9.3): lists that several files must agree on, extracted with grep and sed and then
# compared. PowerShell files may carry CRLF in a Windows checkout, so their extraction strips CR.
load laptop-helpers

# sorted_words: the words on stdin (separated by spaces or newlines), sorted, on one line.
sorted_words() { tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//'; }
# ps_list: "'a', 'b', 'c'" on stdin becomes "a b c".
ps_list() { tr -d "' " | tr ',' ' '; }
# one_line LABEL TEXT: TEXT must be exactly one non-empty line.
one_line() {
  [ -n "$2" ] || { echo "$1: nothing extracted"; return 1; }
  [ "$(printf '%s\n' "$2" | grep -c .)" -eq 1 ] || { echo "$1: more than one line extracted"; return 1; }
}

gated_broker() { sed -n 's/^GATED_VERBS="\([^"]*\)"$/\1/p' "$REPO/vps/tmuxkeep"; }
gated_ps()     { tr -d '\r' < "$REPO/laptop/tmuxkeep.ps1" | sed -n 's/^\$GatedVerbs = @(\(.*\))$/\1/p' | ps_list; }
gated_bash()   { sed -n 's/^TK_GATED_VERBS="\([^"]*\)"$/\1/p' "$REPO/laptop/tmuxkeep.sh"; }

staged_setup() { sed -n 's/^STAGED_FILES=(\(.*\))$/\1/p' "$REPO/vps/tmuxkeep-setup"; }
staged_ps()    { tr -d '\r' < "$REPO/laptop/deploy.ps1" | sed -n 's/^function Get-TmuxkeepVpsFiles { @(\(.*\)) }$/\1/p' | ps_list; }
staged_bash()  { sed -n 's/^TK_VPS_FILES="\([^"]*\)"$/\1/p' "$REPO/laptop/deploy.sh"; }

broker_verbs()  { sed -n 's/^verb_\([a-z][a-z]*\)() {.*$/\1/p' "$REPO/vps/tmuxkeep" | grep -vx reap; }
ps_verbs()      { tr -d '\r' < "$REPO/laptop/profile-snippet.ps1" | sed -n 's/^ *\$candidates = @(\(.new.*\))$/\1/p' | ps_list; }
ps_name_verbs() { tr -d '\r' < "$REPO/laptop/profile-snippet.ps1" | sed -n 's/^.*-cin @(\(.*\))) {$/\1/p' | ps_list; }
bash_verbs()      { sed -n 's/^_TK_VERBS="\([^"]*\)"$/\1/p' "$REPO/laptop/completion.bash"; }
bash_name_verbs() { sed -n 's/^_TK_NAME_VERBS="\([^"]*\)"$/\1/p' "$REPO/laptop/completion.bash"; }

conf_keys_ps()   { tr -d '\r' < "$REPO/laptop/deploy.ps1" | sed -n 's/^function Get-TmuxkeepConfigKeys { @(\(.*\)) }$/\1/p' | ps_list; }
conf_keys_bash() { sed -n 's/^TK_CONF_KEYS="\([^"]*\)"$/\1/p' "$REPO/laptop/deploy.sh"; }
deploy_conf_keys_setup() { sed -n "s/^DEPLOY_CONF_KEYS='\([^']*\)'\$/\1/p" "$REPO/vps/tmuxkeep-setup"; }
deploy_conf_keys_fixture() { sed -n 's/^\([A-Z_]*\)=.*/\1/p' "$REPO/tests/fixtures/deploy.conf" | tr '\n' ' ' | sed 's/ $//'; }

@test "the gated verb list is the same in the broker and both wrappers" {
  local want='auth go new rename resume rm send unlock' b p s
  b=$(gated_broker); one_line broker "$b"
  p=$(gated_ps); one_line 'PowerShell wrapper' "$p"
  s=$(gated_bash); one_line 'bash wrapper' "$s"
  [ "$(printf '%s' "$b" | sorted_words)" = "$want" ] || { echo "broker: $b"; return 1; }
  [ "$(printf '%s' "$p" | sorted_words)" = "$want" ] || { echo "PowerShell wrapper: $p"; return 1; }
  [ "$(printf '%s' "$s" | sorted_words)" = "$want" ] || { echo "bash wrapper: $s"; return 1; }
}

@test "the staged file list is the same, in the same order, in both deploys and the installer" {
  local want='tmuxkeep tmuxkeep-setup vps-facts.sh sshd.conf.tmpl sudoers.tmpl tmux.conf systemd/tmuxkeep-reaper.service systemd/tmuxkeep-reaper.timer' i p s
  i=$(staged_setup); one_line installer "$i"
  p=$(staged_ps); one_line 'PowerShell deploy' "$p"
  s=$(staged_bash); one_line 'bash deploy' "$s"
  [ "$i" = "$want" ] || { echo "installer: $i"; return 1; }
  [ "$p" = "$want" ] || { echo "PowerShell deploy: $p"; return 1; }
  [ "$s" = "$want" ] || { echo "bash deploy: $s"; return 1; }
}

@test "every staged file exists under vps/, and every file under vps/ is staged" {
  local f listed
  listed=" $(staged_setup) "
  for f in $(staged_setup); do
    [ -f "$REPO/vps/$f" ] || { echo "missing vps/$f"; return 1; }
  done
  while IFS= read -r f; do
    f=${f#"$REPO/vps/"}
    case $listed in
      *" $f "*) ;;
      *) echo "not staged: vps/$f"; return 1 ;;
    esac
  done < <(find "$REPO/vps" -type f ! -name '.*')
}

@test "the completer verb lists are the broker's verbs (reap excluded) plus the local ui, and agree" {
  local want b p s
  want='auth go lock log ls new peek rename restore resume rm send status unlock'
  b=$(broker_verbs | sorted_words)
  [ "$b" = "$want" ] || { echo "broker verb_ functions: $b"; return 1; }
  want=$(printf '%s ui' "$want" | sorted_words)
  p=$(ps_verbs); one_line 'PowerShell completer verbs' "$p"
  s=$(bash_verbs); one_line 'bash completer verbs' "$s"
  [ "$(printf '%s' "$p" | sorted_words)" = "$want" ] || { echo "PowerShell completer: $p"; return 1; }
  [ "$(printf '%s' "$s" | sorted_words)" = "$want" ] || { echo "bash completer: $s"; return 1; }
}

@test "the name-completing verb lists agree, and are the broker verbs that take a session name" {
  local want='go lock peek rename resume rm send unlock' p s
  p=$(ps_name_verbs); one_line 'PowerShell name verbs' "$p"
  s=$(bash_name_verbs); one_line 'bash name verbs' "$s"
  [ "$(printf '%s' "$p" | sorted_words)" = "$want" ] || { echo "PowerShell: $p"; return 1; }
  [ "$(printf '%s' "$s" | sorted_words)" = "$want" ] || { echo "bash: $s"; return 1; }
}

@test "the four deploy fixtures exist and end with a newline" {
  local f
  for f in laptop-config deploy.conf tmuxkeep.conf ssh-block; do
    [ -f "$REPO/tests/fixtures/$f" ] || { echo "missing tests/fixtures/$f"; return 1; }
    [ "$(tail -c 1 "$REPO/tests/fixtures/$f" | od -An -tx1 | tr -d ' ')" = 0a ] || { echo "$f"; return 1; }
  done
}

@test "the laptop config key list is the same, in the same order, in deploy.ps1 and deploy.sh" {
  local p s
  p=$(conf_keys_ps); one_line 'PowerShell deploy config keys' "$p"
  s=$(conf_keys_bash); one_line 'bash deploy config keys' "$s"
  [ "$p" = "$s" ] || { echo "PowerShell deploy: $p"; echo "bash deploy:       $s"; return 1; }
}

@test "the installer's deploy.conf key whitelist matches, in order, the keys of the fixture both deploys must write" {
  local i f
  i=$(deploy_conf_keys_setup); one_line 'installer DEPLOY_CONF_KEYS' "$i"
  f=$(deploy_conf_keys_fixture); [ -n "$f" ] || { echo "fixture deploy.conf: no KEY=value lines"; return 1; }
  [ "$i" = "$f" ] || { echo "installer: $i"; echo "fixture:   $f"; return 1; }
}
