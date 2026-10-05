#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -eq 0 ]; then
  echo 'Usage: scripts/e2e/phase1_postgres.sh <command> [args...]' >&2
  exit 64
fi

for tool in initdb pg_ctl createdb python3; do
  command -v "$tool" >/dev/null
done

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/yellow-dog-phase1-pg.XXXXXX")
port=$(python3 -c 'import socket; listener = socket.socket(); listener.bind(("127.0.0.1", 0)); print(listener.getsockname()[1]); listener.close()')

cleanup() {
  local status=$?
  trap - EXIT
  if [ -f "$work_dir/data/postmaster.pid" ]; then
    pg_ctl -D "$work_dir/data" -m immediate -w stop >> "$work_dir/server.log" 2>&1 || status=1
  fi
  echo "PostgreSQL artifacts: $work_dir"
  exit "$status"
}
trap cleanup EXIT

initdb -D "$work_dir/data" -A trust -U postgres --no-locale --encoding=UTF8 > "$work_dir/init.log" 2>&1
pg_ctl -D "$work_dir/data" -l "$work_dir/server.log" -o "-h 127.0.0.1 -p $port -k $work_dir" -w start
createdb -h 127.0.0.1 -p "$port" -U postgres yellow_dog_phase1
export YELLOW_DOG_MANAGEMENT_DATABASE_URL="postgres://postgres@127.0.0.1:$port/yellow_dog_phase1"
export YELLOW_DOG_PHASE1_PG_DATA_DIR="$work_dir/data"
export YELLOW_DOG_PHASE1_PG_PORT="$port"
export ERL_FLAGS="${ERL_FLAGS:-+S 2:2 +A 2}"
"$@"
