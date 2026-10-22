#!/usr/bin/env bash
# Run inside devenv locally; CI provides the pinned BEAM/Node toolchains.
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$repo_root"
mode=${1:---check}
if [[ "$mode" != --check && "$mode" != --write ]]; then
  echo 'Usage: scripts/e2e/management_openapi.sh [--check|--write]' >&2
  exit 2
fi
contract=docs/phase1/management-openapi.json
export MANAGEMENT_OPENAPI_OUTPUT
MANAGEMENT_OPENAPI_OUTPUT=$(mktemp /tmp/yellow-dog-openapi.XXXXXX.json)
trap 'rm -f "$MANAGEMENT_OPENAPI_OUTPUT"' EXIT
mix do --app yellow_dog_management run --no-start -e 'YellowDog.Management.OpenAPI.write!(System.fetch_env!("MANAGEMENT_OPENAPI_OUTPUT"))'
node_modules/.bin/redocly lint "$MANAGEMENT_OPENAPI_OUTPUT" --extends spec
if [[ "$mode" == --write ]]; then
  cp "$MANAGEMENT_OPENAPI_OUTPUT" "$contract"
else
  node --input-type=module - "$contract" "$MANAGEMENT_OPENAPI_OUTPUT" <<'JS'
import fs from 'node:fs';
import assert from 'node:assert/strict';
const [checked, generated] = process.argv.slice(2);
assert.deepStrictEqual(JSON.parse(fs.readFileSync(checked)), JSON.parse(fs.readFileSync(generated)),
  'OpenAPI artifact differs from the shared registry; run management_openapi.sh --write');
JS
fi
printf 'OpenAPI 3.1.2 validated and %s: %s\n' "$mode" "$contract"
