#!/usr/bin/env bash
set -euo pipefail

version=${1:-}
release=${2:-}
mode=${3:---load}
if [ "$#" -lt 2 ] || [ "$#" -gt 3 ] || [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
  echo 'Usage: build_img.sh <version> <yellow_dog_management|yellow_dog_worker> [--load|--push]' >&2
  exit 64
fi
case "$release" in yellow_dog_management | yellow_dog_worker) ;; *) exit 64 ;; esac
case "$mode" in --load | --push) ;; *) exit 64 ;; esac

image="ghcr.io/gsmlg-dev/yellow-dog-${release#yellow_dog_}"
docker buildx build . \
  --build-arg "MIX_RELEASE_NAME=$release" \
  --build-arg "RELEASE_VERSION=$version" \
  -t "$image:v$version" -t "$image:latest" "$mode"
