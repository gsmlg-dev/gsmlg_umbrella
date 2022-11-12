#!/bin/bash

VER=${1:-1.0.0}

FILES=(
    apps/gsmlg_socket/mix.exs
    apps/gsmlg_mnesia/mix.exs
    apps/gsmlg_web/mix.exs
    apps/gsmlg/mix.exs
    mix.exs
)

for n in ${FILES[@]}
do
    echo $n
    sed -i "s;version: \"[^\"]\\+\";version: \"${VER}\";g" $n;
done
