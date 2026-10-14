# tests/bats/laptop-helpers.bash: helpers for the laptop-side suites. Load with: load laptop-helpers
# Runs under /bin/bash 3.2 on macOS and bash 5 in Docker (plan G19-G22): no bash 4 features, no
# set -u, no GNU-only tools. The repo may be read-only (/src in Docker): write under BATS_TEST_TMPDIR.
bats_require_minimum_version 1.5.0

REPO=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
STUBS=$REPO/tests/bats/stubs
export WRAPPER=$REPO/laptop/tmuxkeep.sh

# laptop_setup: a private HOME, TMPDIR and stub log; the stub ssh, scp and ssh-keygen first on PATH.
laptop_setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$HOME" "$TMPDIR"
  export TK_STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
  : > "$TK_STUB_LOG"
  unset TK_STUB_SSH_RC TK_STUB_SCP_RC TK_STUB_KEYGEN_RC TK_STUB_SSH_OUT TK_STUB_SSH_ERR TK_STUB_SSH_G TK_STUB_SSH_G_RC TK_STUB_SCP_DEST
  export PATH="$STUBS:$PATH"
  export SHELL=/bin/bash
}

# stub_calls: the stub log, one line per call: "<tool> [arg] [arg]...".
stub_calls() { cat "$TK_STUB_LOG"; }

# b64 WORD: the token the wrapper sends for WORD.
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

# mk_repo_copy: prints the path of a fresh one-commit git repository holding copies of laptop/, vps/
# and dashboard/. deploy.sh runs from there, so no test depends on the real checkout's .git (a
# worktree's .git file points at a Windows path that does not exist inside Docker).
mk_repo_copy() {
  local r="$BATS_TEST_TMPDIR/repo"
  rm -rf "$r"
  mkdir -p "$r"
  cp -R "$REPO/laptop" "$REPO/vps" "$REPO/dashboard" "$r/"
  git -c init.defaultBranch=main init -q "$r"
  git -C "$r" add -A
  git -C "$r" -c user.email=test@example.invalid -c user.name=test commit -q -m test
  printf '%s' "$r"
}
