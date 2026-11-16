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
sh native/unload.sh
make -C native all check
sh native/load.sh
```

The build replaces the binary atomically, so it never truncates a loaded ELF.
The compiled files in `native/build/` are ignored by Git.
The loader uses a content-addressed copy in `$XDG_RUNTIME_DIR/omaspaces-native/`
and records its path there. This avoids loading stale code from the dynamic
linker's module cache. Native builds disable GNU-unique symbols to permit
clean unloading; `unload.sh` uses the recorded runtime path.

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

## Still snapshots on native tabs

`InlineSnapshots.qml` draws tiny snapshots and custom labels on a transparent,
click-through strip over each visible groupbar. Hyprland still handles clicks,
switching, dragging and its groupbar indicators. Native title rendering stays
enabled so the bar's reserved height does not collapse.

While the custom strips are mapped, textured and visible, the plugin saves
the four native text colors and temporarily sets their alpha to zero. It
notifies QML to show custom labels only after suppressing the original text.
The saved values are restored if the strips disappear, the feature is disabled,
dragging begins, the compositor config reloads, or the plugin unloads. No
configuration files are changed. Runtime color updates are preserved for
restoration. The background remains fully transparent throughout.
During window drags or resizes the strip temporarily hides, retaining only
the tiny images, then returns at the new geometry when the operation ends.
Occluded tabs are omitted to avoid drawing over a window above their group.

Geometry is checked on existing compositor render events at most ten times a
second, with no render requests or polling process. An inexpensive position/
z-order fingerprint skips occlusion checks and IPC when nothing has changed.
Changed geometry is sent as begin/tab/end packets, each below Hyprland's
1024-byte event limit. At most 128 visible tabs are included.

The QML snapshot queue captures just one window at a time. `grabToImage` renders
it directly into an image capped at 60 × 36 pixels. The completed grab result
is retained as a small `QImage` for `Image`, and the capture loader is destroyed.
The next capture starts after a short yield. A two-second deadline releases a
failed capture and advances the queue; no permanent live streams are used for
these inline images. Snapshots refresh when a tab becomes current. Hidden or
closed groups release their images and strip surfaces.

The raised images are bottom-aligned with the tab and rise above it. Only
the raised image regions accept input; native tab areas and transparent gaps
remain click-through. Raised images select their tab on click and use the
same 250 ms delay for a live popup. The popup uses its existing capture path.

`tabSnapshots: false` disables inline snapshots while retaining the hover
preview. `tabPreviews: false` disables both. The service initializes the native
geometry subscription automatically after loading the detector.

```sh
omarchy-shell omaspaces-snapshots-debug status
```

Status includes active capture count, retained image pixel dimensions and
their raw pixel-byte total. That total excludes Qt object, GPU texture and
small strip-surface overhead. Once the initial queue is complete, the inline
feature should report zero active captures.

## Tab reordering

Plain left-button drag over the native bar or raised thumbnail arms reordering.
Motion below six logical pixels remains an ordinary click. A destination outline
appears during the drag; releasing over the same group's bar inserts the source
at that index using Hyprland's public group methods. Releasing away cancels.
The selected source stays active. Existing small snapshots are reused by address.

The handler observes the native event bus and never cancels mouse events or
replaces mouse bindings. Super, Alt, Ctrl and Shift bypass reordering; Caps/Num
lock do not. Super + drag remains Hyprland's existing move/detach operation.
Only an armed gesture adds motion processing; there is no idle polling or
additional capture stream. Native status includes `reorderActive`, `reordered`
and `superBypassed` for verification.
