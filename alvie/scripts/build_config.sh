#!/usr/bin/env bash

if [[ "$OSTYPE" == darwin* ]]; then
    shopt -s expand_aliases
    alias sed='gsed'
fi

SCG_DIR="$1"
SECURITY="$2"
MASTER_KEY="$3"

cd $SCG_DIR

rm -rf build/
mkdir -p build
cd build
cmake  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DRESET_ON_VIOLATION=1 -DNEMESIS_RESISTANT=1 -DSECURITY=$SECURITY -DMASTER_KEY=$MASTER_KEY ..
