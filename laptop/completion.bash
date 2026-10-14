# completion.bash - tab completion for the tmuxkeep command (bash 3.2 and later; zsh through
# bashcompinit). Installed by laptop/deploy.sh as ~/.tmuxkeep/completion.bash and sourced from
# ~/.bashrc or ~/.zshrc. First word: the verbs. Second word: session names for the verbs that take
# one, tombstone base names after restore. Names come from "ssh tmuxkeep ls --names" (or
# --tombstones), cached for 60 seconds under ${TMPDIR:-/tmp}; a failed fetch caches an empty file so
# an offline laptop does not wait at every Tab. That ssh is the only place on the laptop's bash side
# that discards stderr.

_TK_VERBS="new ls peek go send rename lock unlock rm restore resume log auth status"
_TK_NAME_VERBS="peek go send rename lock unlock rm resume"

# _tmuxkeep_mtime FILE: modification time in epoch seconds (GNU stat on Linux, BSD stat elsewhere).
_tmuxkeep_mtime() {
  case $(uname -s) in
    Linux) stat -c %Y "$1" ;;
    *) stat -f %m "$1" ;;
  esac
}

# _tmuxkeep_names KIND: names or tombstones, one per line, from a cache younger than 60 seconds or
# from the broker. A cache path that is a symlink or belongs to another user is never used.
_tmuxkeep_names() {
  local kind=$1 file now mtime out trusted=1
  file=${TMPDIR:-/tmp}
  file="${file%/}/tmuxkeep-$kind-$(id -u).txt"
  if [ -L "$file" ] || { [ -e "$file" ] && [ ! -O "$file" ]; }; then trusted=0; fi
  if [ "$trusted" = 1 ] && [ -f "$file" ]; then
    now=$(date +%s)
    mtime=$(_tmuxkeep_mtime "$file")
    case $mtime in ''|*[!0-9]*) mtime=0 ;; esac
    if [ $(( now - mtime )) -ge 0 ] && [ $(( now - mtime )) -lt 60 ]; then
      cat "$file"
      return 0
    fi
  fi
  out=$(ssh -n -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=2 -o ServerAliveCountMax=2 tmuxkeep ls "--$kind" 2>/dev/null) || out=''
  if [ "$trusted" = 1 ]; then
    if [ -n "$out" ]; then printf '%s\n' "$out" > "$file"; else : > "$file"; fi
  fi
  if [ -n "$out" ]; then printf '%s\n' "$out"; fi
  return 0
}

_tmuxkeep() {
  local cur words w nl='
'
  COMPREPLY=()
  cur=${COMP_WORDS[COMP_CWORD]}
  if [ "$COMP_CWORD" -eq 1 ]; then
    words=${_TK_VERBS// /$nl}
  elif [ "$COMP_CWORD" -eq 2 ]; then
    case " $_TK_NAME_VERBS " in
      *" ${COMP_WORDS[1]} "*) words=$(_tmuxkeep_names names) ;;
      *)
        if [ "${COMP_WORDS[1]}" = restore ]; then
          words=$(_tmuxkeep_names tombstones)
        else
          return 0
        fi ;;
    esac
  else
    return 0
  fi
  while IFS= read -r w; do
    [ -n "$w" ] || continue
    case $w in "$cur"*) COMPREPLY+=("$w") ;; esac
  done <<EOF
$words
EOF
}

complete -F _tmuxkeep tmuxkeep
