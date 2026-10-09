#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 2 || ! $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
  echo 'Usage: scripts/release/build_worker_linux.sh <version> <output-directory>' >&2
  exit 64
fi

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
version=$1
mkdir -p "$2"
output_dir=$(cd "$2" && pwd)
source_commit=$(git -C "$repo_root" rev-parse HEAD)
source_context=$(mktemp -d -t yellow-dog-worker-source-XXXXXX)
trap 'rm -rf "$source_context"' EXIT
# Package committed source only; local edits and credentials must not enter a release.
git -C "$repo_root" archive "$source_commit" | tar -x -C "$source_context"

docker build --platform linux/amd64 \
  --file "$source_context/scripts/release/worker-linux.Dockerfile" \
  --build-arg "RELEASE_VERSION=$version" \
  --build-arg "SOURCE_COMMIT=$source_commit" \
  --output "type=local,dest=$output_dir" "$source_context"

(cd "$output_dir" && sha256sum -c "yellow-dog-worker-v${version}-linux-x86_64.tar.gz.sha256")
