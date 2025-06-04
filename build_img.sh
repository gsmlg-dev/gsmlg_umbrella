#!/usr/bin/env bash

VERSION=$1

if test -z $VERSION
then
  echo VERSION must be set
  exit 255
fi

docker buildx build \
  . \
  --build-arg SOURCE_DATE_EPOCH=$(date +%s) \
  --build-arg RELEASE_VERSION=${VERSION} \
  -t ghcr.io/gsmlg-dev/gsmlg-umbrella:v${VERSION} \
  -t ghcr.io/gsmlg-dev/gsmlg-umbrella:latest \
  --push
