#!/usr/bin/env bash
# Validate the downloadable Linux x86_64 archive without source, Nix, or system Elixir.
set -euo pipefail

if [ "$#" -ne 1 ] || [ ! -f "$1" ]; then
  echo 'Usage: scripts/e2e/worker_linux_package.sh <worker-linux-x86_64.tar.gz>' >&2
  exit 64
fi
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
smoke_context=$(mktemp -d -t yellow-dog-worker-package-XXXXXX)
smoke_image="yellow-dog-worker-package-smoke:$(date +%s)-$$"
smoke_container="yellow-dog-worker-package-$(date +%s)-$$"
cleanup() {
  docker rm -f "$smoke_container" >/dev/null 2>&1 || true
  docker image rm "$smoke_image" >/dev/null 2>&1 || true
  rm -rf "$smoke_context"
}
trap cleanup EXIT
cp "$1" "$smoke_context/worker.tar.gz"
cp "$repo_root/scripts/e2e/worker_linux_package.py" "$smoke_context/smoke.py"
cat > "$smoke_context/Dockerfile" <<'DOCKERFILE'
FROM debian:bookworm-slim
ENV LANG=C.UTF-8
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates libstdc++6 libncurses6 libatomic1 openssl util-linux coreutils python3 && \
    rm -rf /var/lib/apt/lists/*
COPY worker.tar.gz /tmp/worker.tar.gz
COPY smoke.py /smoke.py
RUN mkdir -p /opt/worker && tar -xzf /tmp/worker.tar.gz -C /opt/worker && \
    rm /tmp/worker.tar.gz && \
    ! command -v elixir && ! command -v mix && test ! -e /nix
CMD ["python3", "-u", "/smoke.py", "/opt/worker"]
DOCKERFILE
docker build --platform linux/amd64 --tag "$smoke_image" "$smoke_context"
docker run --rm --name "$smoke_container" --platform linux/amd64 --init "$smoke_image"
