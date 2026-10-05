#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$repo_root"
export MIX_ENV=prod
export ERL_FLAGS="${ERL_FLAGS:-+S 2:2 +A 2}"
if [ "${BUILD_RELEASE:-1}" = 1 ]; then
  mix compile --warnings-as-errors
  for release in yellow_dog_management yellow_dog_worker; do
    mix release "$release" --overwrite
  done
fi
build_root="${MIX_BUILD_PATH:-$repo_root/_build/prod}/rel"
mix run --no-start scripts/e2e/check_release_boundary.exs "$build_root"
scripts/e2e/phase1_postgres.sh python3 scripts/e2e/file_gate.py \
  "$build_root/yellow_dog_management/bin/yellow_dog_management" \
  "$build_root/yellow_dog_worker/bin/yellow_dog_worker"
