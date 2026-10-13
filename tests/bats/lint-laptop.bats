#!/usr/bin/env bats
# Static checks on every laptop-side bash file (plan G19-G23, spec 6.4, 9.5): shellcheck, bash 3.2
# constructs, GNU-only tools, set -u, LF and ASCII, shebangs. Files that do not exist yet are
# skipped by name, so this list already names the files later tasks add.
load laptop-helpers

LAPTOP_FILES='laptop/tmuxkeep.sh laptop/deploy.sh laptop/completion.bash tests/bats/laptop-helpers.bash tests/bats/stubs/ssh tests/bats/stubs/scp tests/bats/stubs/ssh-keygen tests/smoke.sh tests/run-bats.sh'

# each_file: the full path of every listed file that exists, one per line.
each_file() {
  local f
  for f in $LAPTOP_FILES; do
    if [ -f "$REPO/$f" ]; then printf '%s\n' "$REPO/$f"; fi
  done
  return 0
}

# code_hits PATTERN FILE: numbered lines of FILE matching the ERE, comment lines left out.
code_hits() { grep -nE -- "$1" "$2" | grep -vE '^[0-9]+:[[:space:]]*#' || true; }

setup() { laptop_setup; }

@test "every existing laptop bash file passes shellcheck --shell=bash -S warning, with no disable directive" {
  command -v shellcheck >/dev/null || { echo 'shellcheck is not installed'; return 1; }
  local f hits
  while IFS= read -r f; do
    # Plain grep, not code_hits: a directive is a comment line, which code_hits leaves out.
    hits=$(grep -nE 'shellcheck[[:space:]]+disable' "$f" || true)
    [ -z "$hits" ] || { echo "$f has a shellcheck disable directive:"; echo "$hits"; return 1; }
    run shellcheck --shell=bash -S warning "$f"
    [ "$status" -eq 0 ] || { echo "$f"; echo "$output"; return 1; }
  done < <(each_file)
}

@test "no bash 4 constructs (bash 3.2 is /bin/bash on macOS)" {
  local f p hits
  while IFS= read -r f; do
    for p in '(declare|local|typeset)[[:space:]]+-[a-zA-Z]*[Agn]' \
             '(^|[^a-zA-Z_])(mapfile|readarray|coproc)([^a-zA-Z_]|$)' \
             '\$\{[A-Za-z_][A-Za-z0-9_]*(,|\^)' \
             'read[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*-[a-zA-Z]*i' \
             '\|&' ';&' '\[\[[[:space:]]+-v[[:space:]]' '\$\{[A-Za-z_][A-Za-z0-9_]*@' \
             '\[-[0-9]+\]' '%\(' 'EPOCHSECONDS|EPOCHREALTIME|BASHPID' 'wait[[:space:]]+-n' '&>>' \
             'shopt[[:space:]]+-s[[:space:]]+(globstar|lastpipe)'; do
      hits=$(code_hits "$p" "$f")
      [ -z "$hits" ] || { echo "$f matches $p:"; echo "$hits"; return 1; }
    done
  done < <(each_file)
}

@test "no set -u (bash 3.2 treats an empty array as unset)" {
  local f hits
  while IFS= read -r f; do
    hits=$(code_hits 'set[[:space:]]+-[a-zA-Z]*u|set[[:space:]]+-o[[:space:]]+nounset' "$f")
    [ -z "$hits" ] || { echo "$f:"; echo "$hits"; return 1; }
  done < <(each_file)
}

@test "no GNU-only tools or flags; stat only in completion.bash" {
  local f p hits
  while IFS= read -r f; do
    for p in 'sed[[:space:]]+-i' 'grep[[:space:]]+-[a-zA-Z]*P' 'readlink[[:space:]]+-f' 'date[[:space:]]+-d' \
             'base64[[:space:]]+-[wd]' '(^|[^a-zA-Z_])realpath([^a-zA-Z_]|$)' '--suffix' \
             '(^|[[:space:];&|(])timeout[[:space:]]'; do
      hits=$(code_hits "$p" "$f")
      [ -z "$hits" ] || { echo "$f matches $p:"; echo "$hits"; return 1; }
    done
    case $f in
      */laptop/completion.bash) ;;
      *) hits=$(code_hits '(^|[[:space:];&|(])stat[[:space:]]' "$f")
         [ -z "$hits" ] || { echo "$f uses stat:"; echo "$hits"; return 1; } ;;
    esac
  done < <(each_file)
}

@test "LF line endings and ASCII only" {
  local f
  while IFS= read -r f; do
    [ "$(tr -cd '\r' < "$f" | wc -c | tr -d ' ')" = 0 ] || { echo "CR in $f"; return 1; }
    [ "$(LC_ALL=C tr -d '\000-\177' < "$f" | wc -c | tr -d ' ')" = 0 ] || { echo "non-ASCII in $f"; return 1; }
  done < <(each_file)
}

@test "scripts start with #!/usr/bin/env bash; sourced files have no shebang" {
  local f
  for f in laptop/tmuxkeep.sh laptop/deploy.sh tests/bats/stubs/ssh tests/bats/stubs/scp tests/bats/stubs/ssh-keygen tests/smoke.sh tests/run-bats.sh; do
    if [ -f "$REPO/$f" ]; then
      [ "$(sed -n 1p "$REPO/$f")" = '#!/usr/bin/env bash' ] || { echo "$f"; return 1; }
    fi
  done
  for f in laptop/completion.bash tests/bats/laptop-helpers.bash; do
    if [ -f "$REPO/$f" ]; then
      case $(sed -n 1p "$REPO/$f") in '#!'*) echo "$f"; return 1 ;; esac
    fi
  done
}
