#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
validation_root=${1:?Usage: prepare-validation.sh /absolute/temporary-build-directory}
case "$validation_root" in /tmp/*) ;; *) echo 'Use a temporary directory under /tmp' >&2; exit 1 ;; esac
cd "$repo_root"
export MIX_BUILD_PATH="$validation_root/_build/prod"
mix deps.get
MIX_ENV=prod mix release yellow_dog_management --overwrite
printf 'Release binary: %s/rel/yellow_dog_management/bin/yellow_dog_management\n' "$MIX_BUILD_PATH"
