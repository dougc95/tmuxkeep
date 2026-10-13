#!/usr/bin/env bash
# run-bats.sh - build the tmuxkeep test image and run bats in Docker (macOS, Linux; Git Bash works too).
# Usage: bash tests/run-bats.sh [path-in-repo] [filter-regex]     (default path: tests/bats)
# Exit code: bats' own; 2 when Docker is unavailable, the path is wrong, or the build fails.
# Mirrors tests/run-bats.ps1. bash 3.2.
rel=${1:-tests/bats}
filter=${2:-}
repo=$(cd "$(dirname "$0")/.." && pwd) || exit 2
image=tmuxkeep-bats:latest

if ! docker info --format '{{.ServerVersion}}' >/dev/null; then
  echo 'run-bats: Docker is not available. Start Docker and retry.'
  exit 2
fi
rel=${rel#./}
if [ ! -e "$repo/$rel" ]; then
  echo "run-bats: no such path in the repo: $rel"
  exit 2
fi
if ! docker build --quiet --tag "$image" "$repo/tests/docker" >/dev/null; then
  echo 'run-bats: docker build failed'
  exit 2
fi
src=$repo
case $(uname -s) in
  MINGW*|MSYS*|CYGWIN*) src=$(cd "$repo" && pwd -W); export MSYS_NO_PATHCONV=1 ;;
esac
set -- bats
if [ -n "$filter" ]; then set -- "$@" --filter "$filter"; fi
docker run --rm --mount "type=bind,source=$src,target=/src,readonly" "$image" "$@" "/src/$rel"
exit $?
