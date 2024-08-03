FROM docker-io.gsmlg.dev/library/elixir:1.16-alpine AS builder

ARG MIX_ENV=prod
ARG NAME=gsmlg
ARG RELEASE_VERSION=1.0.0

ARG NPM_CONFIG_REGISTRY=https://nexus.gsmlg.net/repository/npm/
ARG HEX_MIRROR=https://nexus.gsmlg.net/repository/hex-pm/

COPY . /build

WORKDIR /build

RUN apk update && apk add nodejs curl git npm \
    && mix do deps.get, compile \
    && cd apps/gsmlg_web && npm install --prefix assets && mix assets.deploy && cd ../.. \
    && cd apps/gsmlg_admin_web && npm install --prefix assets && mix assets.deploy && cd ../.. \
    && mix release gsmlg_umbrella --version "${RELEASE_VERSION}" \
    && cp -r _build/prod/rel/gsmlg_umbrella /app


FROM docker-io.gsmlg.dev/library/alpine:3.19

ARG RELEASE_VERSION=1.0.0

LABEL maintainer="GSMLG <gsmlg.com@gmail.com>"
LABEL RELEASE_VERSION="${RELEASE_VERSION}"

ENV PORT=80 \
    ADMIN_PORT=1080 \
    REPLACE_OS_VARS=true \
    ERL_EPMD_PORT=4369 \
    POD_IP=127.0.0.1 \
    ERLCOOKIE=erlang_cookie \
    HOST=gsmlg.org \
    HOST_PORT=80 \
    ADMIN_HOST=admin.gsmlg.org \
    ADMIN_HOST_PORT=80 \
    DATABASE_URL=ecto://USER:PASS@HOST/DATABASE \
    POOL_SIZE=10 \
    ADMIN_SECRET_KEY_BASE=gsmlg-admin \
    MNESIA_DIR=/var/lib/mnesia \
    SECRET_KEY_BASE=gsmlg_umbrella

RUN apk update \
    && apk add openssl bash libstdc++ \
    && ln -s /app/bin/gsmlg_umbrella /usr/local/bin/gsmlg \
    && mkdir -p /var/lib/mnesia \
    && rm -rf /var/cache/apk/*

COPY --from=builder /app /app

EXPOSE 80 1080 4369

CMD ["/app/bin/gsmlg_umbrella", "start"]
