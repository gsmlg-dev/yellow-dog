#!/usr/bin/env bash

VERSION=$1

IMAGE_NAME="ghcr.io/gsmlg-dev/yellow-dog"

if test -z $VERSION
then
  echo VERSION must be set
  exit 255
fi

docker buildx build \
  . \
  --build-arg SOURCE_DATE_EPOCH=$(date +%s) \
  --build-arg RELEASE_VERSION=${VERSION} \
  -t ${IMAGE_NAME}:v${VERSION} \
  -t ${IMAGE_NAME}:latest \
  --push

