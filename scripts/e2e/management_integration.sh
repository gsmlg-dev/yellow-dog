#!/usr/bin/env bash
set -euo pipefail
umask 077
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$repo_root"
: "${YELLOW_DOG_MANAGEMENT_DATABASE_URL:?Run through scripts/e2e/phase1_postgres.sh}"
: "${YELLOW_DOG_PHASE1_PG_DATA_DIR:?Use a disposable PostgreSQL database}"
export MIX_ENV=prod
export ERL_FLAGS="${ERL_FLAGS:-+S 2:2 +A 2}"
export MANAGEMENT_INTEGRATION_DIR
MANAGEMENT_INTEGRATION_DIR=$(mktemp -d /tmp/yellow-dog-management-integration.XXXXXX)
server_pid=""
issuer_pid=""
source_pid=""
cleanup() {
  status=$?
  trap - EXIT
  for pid in "$server_pid" "$issuer_pid" "$source_pid"; do
    if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
  done
  # Never retain signing keys or OAuth client credentials in test evidence.
  rm -f "$MANAGEMENT_INTEGRATION_DIR/issuer.json"
  if [ "$status" -ne 0 ] && [ -f "$MANAGEMENT_INTEGRATION_DIR/server.log" ]; then tail -70 "$MANAGEMENT_INTEGRATION_DIR/server.log"; fi
  echo "Management integration artifacts: $MANAGEMENT_INTEGRATION_DIR"
  exit "$status"
}
trap cleanup EXIT
free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }
export YELLOW_DOG_MANAGEMENT_PORT
YELLOW_DOG_MANAGEMENT_PORT=$(free_port)
issuer_port=$(free_port)
source_port=$(free_port)
export MANAGEMENT_UI_URL="http://127.0.0.1:$YELLOW_DOG_MANAGEMENT_PORT"
export MANAGEMENT_OAUTH_FIXTURE_URL="http://127.0.0.1:$issuer_port"
node apps/yellow_dog_management/test/mcp_fixture.mjs prepare
node apps/yellow_dog_management/test/mcp_fixture.mjs serve > "$MANAGEMENT_INTEGRATION_DIR/issuer.log" 2>&1 &
issuer_pid=$!
mkdir "$MANAGEMENT_INTEGRATION_DIR/source"
base64 -d apps/yellow_dog_management/test/fixtures/geoip/GeoIP2-City-Test.mmdb.base64 > "$MANAGEMENT_INTEGRATION_DIR/city.mmdb"
export MANAGEMENT_DATA_SOURCE_FILE="$MANAGEMENT_INTEGRATION_DIR/source/city.mmdb.gz"
gzip -c "$MANAGEMENT_INTEGRATION_DIR/city.mmdb" > "$MANAGEMENT_DATA_SOURCE_FILE"
python3 -u -m http.server "$source_port" --bind 127.0.0.1 --directory "$MANAGEMENT_INTEGRATION_DIR/source" > "$MANAGEMENT_INTEGRATION_DIR/source.log" 2>&1 &
source_pid=$!
export RELEASE_DISTRIBUTION=none
export YELLOW_DOG_MANAGEMENT_BIND_ADDRESS=127.0.0.1
export YELLOW_DOG_MANAGEMENT_AUTH_MODE=protected_remote
export YELLOW_DOG_MANAGEMENT_API_ENABLED=1
export YELLOW_DOG_MANAGEMENT_MCP_ENABLED=1
export YELLOW_DOG_MANAGEMENT_REMOTE_WRITES_ENABLED=1
export YELLOW_DOG_MANAGEMENT_RESOURCE="$MANAGEMENT_UI_URL"
export YELLOW_DOG_MANAGEMENT_OAUTH_ISSUER="$MANAGEMENT_OAUTH_FIXTURE_URL"
export YELLOW_DOG_MANAGEMENT_OAUTH_JWKS_FILE="$MANAGEMENT_INTEGRATION_DIR/access-jwks.json"
export YELLOW_DOG_MANAGEMENT_GATEWAY_ISSUER="$MANAGEMENT_OAUTH_FIXTURE_URL/gateway"
export YELLOW_DOG_MANAGEMENT_GATEWAY_AUDIENCE=management-ui-fixture
export YELLOW_DOG_MANAGEMENT_GATEWAY_JWKS_FILE="$MANAGEMENT_INTEGRATION_DIR/gateway-jwks.json"
export YELLOW_DOG_MANAGEMENT_SECRET_KEY_BASE
YELLOW_DOG_MANAGEMENT_SECRET_KEY_BASE=$(python3 -c 'import secrets; print(secrets.token_hex(64))')
export YELLOW_DOG_MANAGEMENT_GEOIP_CITY_URL="http://127.0.0.1:$source_port/city.mmdb.gz"
export YELLOW_DOG_MANAGEMENT_ARTIFACT_DIRECTORY="$MANAGEMENT_INTEGRATION_DIR/artifacts"
unset YELLOW_DOG_MANAGEMENT_EXTERNAL_ORIGIN YELLOW_DOG_MANAGEMENT_TRUSTED_PROXY_IP YELLOW_DOG_MANAGEMENT_OPERATOR_TOKEN YELLOW_DOG_MANAGEMENT_GEOIP_CITY_PATH YELLOW_DOG_MANAGEMENT_GEOIP_COUNTRY_PATH
if [ "${BUILD_RELEASE:-1}" = 1 ]; then mix release yellow_dog_management --overwrite; fi
release="${MIX_BUILD_PATH:-$repo_root/_build/prod}/rel/yellow_dog_management/bin/yellow_dog_management"
"$release" eval 'YellowDog.Management.Release.migrate()' > "$MANAGEMENT_INTEGRATION_DIR/migration.log" 2>&1
start_management() {
  "$release" start >> "$MANAGEMENT_INTEGRATION_DIR/server.log" 2>&1 &
  server_pid=$!
  for attempt in $(seq 1 150); do
    if curl -fsS --max-time 1 "$MANAGEMENT_UI_URL/.well-known/oauth-protected-resource" > /dev/null 2>&1; then return; fi
    kill -0 "$server_pid"
    sleep 0.1
  done
  return 1
}
for attempt in $(seq 1 100); do
  if curl -fsS --max-time 1 "$MANAGEMENT_OAUTH_FIXTURE_URL/.well-known/oauth-authorization-server" > /dev/null 2>&1; then break; fi
  kill -0 "$issuer_pid"
  sleep 0.1
done
start_management
timeout 240 node apps/yellow_dog_management/test/mcp_integration.mjs
kill "$server_pid"
wait "$server_pid" || true
server_pid=""
start_management
timeout 120 node apps/yellow_dog_management/test/mcp_integration.mjs restart
