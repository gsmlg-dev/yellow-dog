#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$repo_root"
: "${YELLOW_DOG_PHASE1_PG_DATA_DIR:?Run with scripts/e2e/phase1_postgres.sh}"
export MIX_ENV=prod
export ERL_FLAGS="${ERL_FLAGS:-+S 2:2 +A 2}"
if [ "${BUILD_RELEASE:-1}" = 1 ]; then
  mix compile --warnings-as-errors
  mix release yellow_dog_management --overwrite
  mix release yellow_dog_worker --overwrite
fi
release_root="${MIX_BUILD_PATH:-$repo_root/_build/prod}/rel"
python3 scripts/e2e/worker_connection_smoke.py "$release_root/yellow_dog_management/bin/yellow_dog_management" "$release_root/yellow_dog_worker/bin/yellow_dog_worker"
