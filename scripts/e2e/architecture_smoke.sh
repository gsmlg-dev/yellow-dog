#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$repo_root"
export MIX_ENV=prod
export ERL_FLAGS="${ERL_FLAGS:-+S 2:2 +A 2}"

mix compile --warnings-as-errors
for release in yellow_dog_management yellow_dog_worker; do
  mix release "$release" --overwrite
done

mix run --no-start scripts/e2e/check_release_boundary.exs \
  "${MIX_BUILD_PATH:-$repo_root/_build/prod}/rel"

python3 scripts/e2e/architecture_negative_smoke.py \
  "${MIX_BUILD_PATH:-$repo_root/_build/prod}/rel"
