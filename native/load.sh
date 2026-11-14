#!/bin/sh
# Called once by the OmaSpaces service, not from the mouse handler.
set -eu
native_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if ! hyprctl plugin list -j | jq -e 'any(.[]; .name == "omaspaces-hover")' >/dev/null; then
    test -f "$native_dir/build/omaspaces-hover.so"
    hyprctl plugin load "$native_dir/build/omaspaces-hover.so"
fi
hyprctl omaspaceshover enable
