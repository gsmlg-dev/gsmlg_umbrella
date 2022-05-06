#!/bin/bash

figlet "Get deps"
mix do deps.get, compile
figlet "Building web assets"
cd apps/gsmlg_web
npm install --prefix assets
mix assets.deploy
cd ../..
figlet "Download website"
curl -Lf $(npm info --json @gsmlg/website | jq -r .dist.tarball) -o website.tgz
tar xzf website.tgz --strip-components=2 -C apps/gsmlg_web/priv/static
figlet "Building release ..."
mix release gsmlg_umbrella --version ${RELEASE_VERSION}
cp -r _build/prod/rel/gsmlg_umbrella gsmlg
tar zcf gsmlg.tar.gz gsmlg
