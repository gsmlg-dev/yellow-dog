#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$repo_root"

release=${1:-}
case "$release" in
  yellow_dog_management | yellow_dog_worker) ;;
  *) echo 'Usage: scripts/e2e/release_smoke.sh <yellow_dog_management|yellow_dog_worker>' >&2; exit 64 ;;
esac
if [ "$#" -ne 1 ]; then
  exit 64
fi

export MIX_ENV=prod
export ERL_FLAGS="${ERL_FLAGS:-+S 2:2 +A 2}"
if [ "${BUILD_RELEASE:-1}" = 1 ]; then
  args=("$release" --overwrite)
  if [ -n "${RELEASE_VERSION:-}" ]; then
    args+=(--version "$RELEASE_VERSION")
  fi
  mix release "${args[@]}"
fi

binary="${MIX_BUILD_PATH:-$repo_root/_build/prod}/rel/$release/bin/$release"
test -x "$binary"
test ! -e "$(dirname "$binary")/yellow_dog_cli"
if [ "${RELEASE_SMOKE_BUILD_ONLY:-0}" = 1 ]; then
  exit 0
fi

if [ "$release" = yellow_dog_management ]; then
  : "${YELLOW_DOG_MANAGEMENT_DATABASE_URL:?Use a disposable fresh database for the smoke test}"
  "$binary" eval 'YellowDog.Management.Release.migrate()'
fi
python3 "apps/$release/test/release_smoke.py" "$binary"
