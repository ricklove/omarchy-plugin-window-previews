# Group-tab hover bridge

This small C++ Hyprland plugin belongs to the same repository as the OmaSpaces
overview. It only detects native tab hover; QML owns all preview rendering.

## Build and load

Build against the headers matching the running Hyprland:

```sh
make -C native all check
```

The compiler uses `pkg-config` for Hyprland, pixman, libinput, Wayland, and
json-c. No additional desktop service or Hyprland config file is required.
`Service.qml` starts `native/load.sh` once at shell startup; it loads the
binary if needed and enables the detector. A header/Hyprland ABI mismatch
refuses to load. After a Hyprland update, rebuild before loading again.

After changing native code while it is loaded:

```sh
hyprctl plugin unload "$HOME/.config/omarchy/plugins/io.github.terrifiedbug.omaspaces/native/build/omaspaces-hover.so"
make -C native all check
sh native/load.sh
```

The build replaces the binary atomically, so it never truncates a loaded ELF.
The compiled files in `native/build/` are ignored by Git.

## Hover and resource lifetime

The detector subscribes to native mouse movement without function hooks. It
uses Hyprland's window/layer hit-testing and decoration geometry, including
monitor offsets, overlapping windows, padding and stacked groupbars. Button
presses, scrolling, locking and workspace changes cancel hover.

The motion path performs in-memory geometry checks. It does not start
processes, serialize IPC, request renders, or allocate capture resources.
One reusable native timer starts when the hovered tab changes. Moving within
that same tab does not restart it. After 250 ms, the target is checked again
and one JSON event is posted through Hyprland's existing nonblocking IPC
socket. Leaving a published tab sends one dismiss event. While a tab is
pending or shown, existing monitor render events also check for geometry or
group changes with a stationary pointer. No periodic idle poll is used.

`HoverPreview.qml` creates a small, click-through layer window only after the
dwell completes. It does not focus or activate the target window. It uses
`WindowCapture.qml`, the same live capture and bounded retry implementation
as the overview. The popup starts at 25% of the source window dimensions,
fits within the monitor, and flips above a tab if necessary.

Dismissal detaches the capture source immediately and deactivates a
`LazyLoader`, destroying the popup, capture context and its swapchain.
There is no application-owned thumbnail cache or delayed-release pool.
Qt and the graphics driver may keep shared renderer resources independently;
overall process RSS/VRAM need not return to the exact startup value.

## Settings and diagnostics

Set `"tabPreviews": false` on the OmaSpaces entry in `shell.json` to disable
the feature. Native detection is disabled and the popup is destroyed.

```sh
hyprctl omaspaceshover status
omarchy-shell omaspaces-hover-debug status
hyprctl omaspaceshover probe 2200 100  # read-only hit test at global coordinates
hyprctl omaspaceshover profile       # opt-in timing of subsequent mouse events
hyprctl omaspaceshover status
hyprctl omaspaceshover unprofile
```

Profiling is off normally. The status reports motion/message counts, pending
dwell, current target, and measured average/maximum check time when enabled.
The QML status reports whether a popup/capture currently exists. Unloading
the native plugin unregisters its listeners and command, removes its timer,
and dismisses an open preview.
