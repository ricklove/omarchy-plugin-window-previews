#!/bin/sh
set -eu
native_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
runtime_dir="${XDG_RUNTIME_DIR:?}/window-previews-native"
mkdir -p -m 700 "$runtime_dir"
exec 9>"$runtime_dir/load.lock"
flock 9
loaded_path="$native_dir/build/window-previews-hover.so"
if test -f "$runtime_dir/loaded-path"; then loaded_path=$(cat "$runtime_dir/loaded-path"); fi
if hyprctl plugin list -j | jq -e 'any(.[]; .name == "window-previews-hover")' >/dev/null; then
    hyprctl plugin unload "$loaded_path"
fi
