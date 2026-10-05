#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$repo_root"
: "${YELLOW_DOG_MANAGEMENT_DATABASE_URL:?Run through scripts/e2e/phase1_postgres.sh with an empty disposable database}"
: "${YELLOW_DOG_PHASE1_PG_DATA_DIR:?Use scripts/e2e/phase1_postgres.sh, not the development database}"

export MIX_ENV=prod
export ERL_FLAGS="${ERL_FLAGS:-+S 2:2 +A 2}"
if [ "${BUILD_RELEASE:-1}" = 1 ]; then
  mix release yellow_dog_management --overwrite
fi

release="${MIX_BUILD_PATH:-$repo_root/_build/prod}/rel/yellow_dog_management/bin/yellow_dog_management"
test -x "$release"
artifact_dir=$(mktemp -d "${TMPDIR:-/tmp}/yellow-dog-management-browser.XXXXXX")
server_pid=""
cleanup() {
  status=$?
  trap - EXIT
  if [ -n "$server_pid" ]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  python3 -c 'import pathlib, sys; [pathlib.Path(name).unlink(missing_ok=True) for name in sys.argv[1:]]' \
    "$artifact_dir/city.mmdb" "$artifact_dir/mac-browser-fixture.txt"
  if [ "$status" -ne 0 ] && [ -f "$artifact_dir/server.log" ]; then
    tail -60 "$artifact_dir/server.log"
  fi
  echo "Management browser artifacts: $artifact_dir"
  exit "$status"
}
trap cleanup EXIT

base64 -d apps/yellow_dog_management/test/fixtures/geoip/GeoIP2-City-Test.mmdb.base64 > "$artifact_dir/city.mmdb"
echo "ed972738e4e03a3e56e12041a6af4d91592249d110f7e4a647e5f2fa0e639c09  $artifact_dir/city.mmdb" | sha256sum --check
printf '00:00:0A\tOmronTat\tOmron Tateisi Electronics Co.\n02:01:02\tFixture\tManagement Browser OUI Fixture\n' > "$artifact_dir/mac-browser-fixture.txt"

export RELEASE_DISTRIBUTION=none
export YELLOW_DOG_MANAGEMENT_BIND_ADDRESS=127.0.0.1
export YELLOW_DOG_MANAGEMENT_PORT
YELLOW_DOG_MANAGEMENT_PORT=$(python3 -c 'import socket; listener = socket.socket(); listener.bind(("127.0.0.1", 0)); print(listener.getsockname()[1]); listener.close()')
export YELLOW_DOG_MANAGEMENT_GEOIP_CITY_PATH="$artifact_dir/city.mmdb"
export YELLOW_DOG_MANAGEMENT_MAC_DATABASE_PATH="$artifact_dir/mac-browser-fixture.txt"
export MANAGEMENT_MAC_SMOKE_PATH="$YELLOW_DOG_MANAGEMENT_MAC_DATABASE_PATH"
export MANAGEMENT_UI_URL="http://127.0.0.1:$YELLOW_DOG_MANAGEMENT_PORT"
unset YELLOW_DOG_MANAGEMENT_GEOIP_COUNTRY_PATH YELLOW_DOG_MANAGEMENT_OPERATOR_TOKEN

"$release" eval 'YellowDog.Management.Release.migrate()' > "$artifact_dir/migration.log" 2>&1
"$release" start > "$artifact_dir/server.log" 2>&1 &
server_pid=$!
for attempt in $(seq 1 100); do
  if curl -fsS --max-time 1 "$MANAGEMENT_UI_URL/management" >/dev/null 2>&1; then
    break
  fi
  kill -0 "$server_pid"
  sleep 0.1
done
curl -fsS --max-time 5 "$MANAGEMENT_UI_URL/management" >/dev/null
timeout 120 node apps/yellow_dog_management/test/live_browser_smoke.mjs
