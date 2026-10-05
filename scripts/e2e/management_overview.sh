#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$repo_root"
: "${YELLOW_DOG_PHASE1_PG_DATA_DIR:?Use scripts/e2e/phase1_postgres.sh with disposable PostgreSQL}"
export MIX_ENV=prod
export ERL_FLAGS="${ERL_FLAGS:-+S 2:2 +A 2}"
if [ "${BUILD_RELEASE:-1}" = 1 ]; then
  mix release yellow_dog_management --overwrite
fi
release="${MIX_BUILD_PATH:-$repo_root/_build/prod}/rel/yellow_dog_management/bin/yellow_dog_management"
"$release" eval 'YellowDog.Management.Release.migrate()'
python3 apps/yellow_dog_management/test/overview_release_smoke.py "$release"
