#!/bin/sh
# Called once by the WindowPreviews service, not from the mouse handler.
set -eu
native_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
binary="$native_dir/build/window-previews-hover.so"
test -f "$binary"
runtime_dir="${XDG_RUNTIME_DIR:?}/window-previews-native"
mkdir -p -m 700 "$runtime_dir"
# Shell hot reloads can overlap. Serialize loading outside the compositor.
exec 9>"$runtime_dir/load.lock"
flock 9
digest=$(sha256sum "$binary" | cut -d ' ' -f 1)
runtime_plugin="$runtime_dir/window-previews-hover-$digest.so"
loaded_path=""
if test -f "$runtime_dir/loaded-path"; then loaded_path=$(cat "$runtime_dir/loaded-path"); fi
if hyprctl plugin list -j | jq -e 'any(.[]; .name == "window-previews-hover")' >/dev/null; then
    if test "$loaded_path" != "$runtime_plugin"; then
        # Migrate the earlier unversioned loader on this desktop as well.
        hyprctl plugin unload "${loaded_path:-$binary}"
    else
        hyprctl windowpreviews enable
        exit 0
    fi
fi
if ! test -f "$runtime_plugin"; then cp "$binary" "$runtime_plugin"; fi
# Unique ELF paths prevent dlopen from returning a previously cached module.
hyprctl plugin load "$runtime_plugin"
printf '%s\n' "$runtime_plugin" > "$runtime_dir/loaded-path"
hyprctl windowpreviews enable
