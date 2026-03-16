FROM ghcr.io/gsmlg-dev/phoenix:1.8.5 AS builder

ARG MIX_ENV=prod
ARG NAME=gsmlg_umbrella
ARG RELEASE_VERSION=1.0.0

ARG http_proxy
ARG https_proxy

ARG NPM_CONFIG_REGISTRY=https://nexus.gsmlg.net/repository/npm/
ARG HEX_MIRROR=https://nexus.gsmlg.net/repository/hex-pm

ARG MIX_TAILWIND_PATH=/usr/bin/tailwind
ARG MIX_BUN_PATH=/usr/bin/bun

ARG TAILWIND_URL_AMD64=https://github.com/tailwindlabs/tailwindcss/releases/download/v4.1.11/tailwindcss-linux-x64
ARG TAILWIND_URL_ARM64=https://github.com/tailwindlabs/tailwindcss/releases/download/v4.1.11/tailwindcss-linux-arm64

ARG TARGETARCH

COPY . /build

WORKDIR /build

RUN <<EOF
set -evx
cd /build

mix deps.get
bun install
install -m 755 -D $MIX_TAILWIND_PATH /build/_build/tailwind-linux-x64
install -m 755 -D $MIX_BUN_PATH /build/_build/bun

bash scripts/update_version.sh $RELEASE_VERSION

mix release gsmlg_umbrella --version "${RELEASE_VERSION}" --overwrite

cp -r _build/prod/rel/gsmlg_umbrella /app
EOF


FROM debian:latest

ARG RELEASE_VERSION=1.0.0

LABEL org.opencontainers.image.source="https://github.com/gsmlg-dev/gsmlg_umbrella"
LABEL org.opencontainers.image.version="${RELEASE_VERSION}"
LABEL org.opencontainers.image.title="GSMLG Umbrella Project"
LABEL org.opencontainers.image.authors="Jonathan Gao <gsmlg.com@gmail.com>"
LABEL org.opencontainers.image.description="GSMLG Umbrella Project, running on Elixir/Phoenix"
LABEL maintainer="Jonathan Gao <gsmlg.com@gmail.com>"
LABEL RELEASE_VERSION="${RELEASE_VERSION}"

ENV REPLACE_OS_VARS=true
ENV ERL_EPMD_PORT=4369
ENV ERLCOOKIE=erlang_cookie
ENV BUN_BIN=/usr/bin/bun
ENV BUN_SERVER_JS=/app/lib/gsmlg_component-$RELEASE_VERSION/priv/server.js
ENV GSMLG_CONFIG_PATH=/etc/gsmlg_umbrella.toml

ENV ELIXIR_ERL_OPTIONS="+fnu"

COPY apps/gsmlg_config/priv/gsmlg.toml /etc/gsmlg_umbrella.toml

COPY --from=builder /app /app
COPY --from=builder /usr/bin/bun /usr/bin/bun

RUN <<EOF
apt-get update
apt-get install -y --no-install-recommends openssl ca-certificates procps
rm -rf /var/lib/apt/lists/*
mkdir -p /var/lib/mnesia
EOF

VOLUME ["/var/lib/mnesia"]

ENV PATH="/app/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

EXPOSE 80 1080 4369

CMD ["/app/bin/gsmlg_umbrella", "start"]
