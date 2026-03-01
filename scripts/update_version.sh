#!/bin/bash

VER=${1:-1.0.0}

FILES=(
  apps/gsmlg_admin_web/mix.exs
  apps/gsmlg_commander/mix.exs
  apps/gsmlg_component/mix.exs
  apps/gsmlg_couchdb/mix.exs
  apps/gsmlg_logger/mix.exs
  apps/gsmlg_mac/mix.exs
  apps/gsmlg/mix.exs
  apps/gsmlg_mnesia/mix.exs
  apps/gsmlg_socket/mix.exs
  apps/gsmlg_tor/mix.exs
  apps/gsmlg_web/mix.exs
  apps/gsmlg_whois/mix.exs
  mix.exs
)

for n in ${FILES[@]}
do
  echo $n
  sed -i "s;version: \"[^\"]\\+\";version: \"${VER}\";g" $n;
  sed -i "s;@version \"[^\"]\\+\";@version \"${VER}\";g" $n;
done
