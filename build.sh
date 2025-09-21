#!/usr/bin/env bash

	# --build-arg https_proxy=http://10.100.0.1:3128 \
	# --build-arg http_proxy=http://10.100.0.1:3128 \

docker buildx build \
	--build-arg DATABASE_URL=ecto://USER:PASS@HOST/DATABASE \
	--build-arg TAILWIND_URL_AMD64=https://nexus.gsmlg.net/repository/tailwindcss/download/v4.0.6/tailwindcss-linux-x64-musl \
	--build-arg RELEASE_VERSION=4.21.4 \
	. \
	-t ghcr.io/gsmlg-dev/gsmlg-umbrella:latest \
	-t ghcr.io/gsmlg-dev/gsmlg-umbrella:v4.21.4 \
	--push



