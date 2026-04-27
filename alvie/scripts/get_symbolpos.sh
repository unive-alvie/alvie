#!/usr/bin/env bash

if [[ "$OSTYPE" == darwin* ]]; then
    shopt -s expand_aliases
    alias sed='gsed'
fi

nm "$1" | grep -w "$2" | cut -d " " -f 1
