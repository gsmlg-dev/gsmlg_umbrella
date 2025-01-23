ARG IMAGE_REGISTRY="docker-io.gsmlg.dev"
FROM ${IMAGE_REGISTRY}/library/elixir:1.17-alpine AS builder

ARG MIX_ENV=prod
ARG NAME=gsmlg
ARG RELEASE_VERSION=1.0.0

ARG NPM_CONFIG_REGISTRY=https://nexus.gsmlg.net/repository/npm
ARG HEX_MIRROR=https://nexus.gsmlg.net/repository/hex-pm

COPY . /build

WORKDIR /build

RUN <<EOF
apk add --no-cache nodejs curl git npm
mix deps.get

cd /build/apps/gsmlg_web
npm install --prefix assets
mix assets.deploy

cd /build/apps/gsmlg_admin_web
npm install --prefix assets
mix assets.deploy

cd /build
MIX_ENV=prod mix release gsmlg_umbrella --version "${RELEASE_VERSION}" --overwrite

cp -r _build/prod/rel/gsmlg_umbrella /app
EOF


FROM ${IMAGE_REGISTRY}/library/alpine:3.20

ARG RELEASE_VERSION=1.0.0

LABEL org.opencontainers.image.source="https://github.com/gsmlg-dev/gsmlg_umbrella"
LABEL org.opencontainers.image.version="${RELEASE_VERSION}"
LABEL org.opencontainers.image.title="GSMLG Umbrella Project"
LABEL org.opencontainers.image.authors="Jonathan Gao <gsmlg.com@gmail.com>"
LABEL org.opencontainers.image.description="GSMLG Umbrella Project, running on Elixir/Phoenix"
LABEL maintainer="Jonathan Gao <gsmlg.com@gmail.com>"
LABEL RELEASE_VERSION="${RELEASE_VERSION}"

ENV PORT=80
ENV ADMIN_PORT=1080
ENV REPLACE_OS_VARS=true
ENV ERL_EPMD_PORT=4369
ENV POD_IP=127.0.0.1
ENV ERLCOOKIE=erlang_cookie
ENV HOST=gsmlg.org
ENV HOST_PORT=80
ENV ADMIN_HOST=admin.gsmlg.org
ENV ADMIN_HOST_PORT=80
ENV DATABASE_URL=ecto://USER:PASS@HOST/DATABASE
ENV POOL_SIZE=10
ENV ADMIN_SECRET_KEY_BASE=gsmlg-admin
ENV MNESIA_DIR=/var/lib/mnesia
ENV SECRET_KEY_BASE=gsmlg_umbrella

COPY --from=builder /app /app

RUN <<EOF
apk update
apk add --no-cache openssl bash libstdc++
mkdir -p /var/lib/mnesia
EOF

VOLUME ["/var/lib/mnesia"]

ENV PATH="/app/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

EXPOSE 80 1080 4369

CMD ["/app/bin/gsmlg_umbrella", "start"]
