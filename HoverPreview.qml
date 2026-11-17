import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import "HoverModel.js" as HoverModel

Item {
  id: root
  property var target: null
  property bool ready: false
  property bool nativeLoaded: false
  property var inlineTarget: null
  readonly property int padding: Style.space(6)
  readonly property int footer: Style.space(24)
  readonly property var monitorScreen: {
    if (!target) return null
    for (var i = 0; i < Quickshell.screens.length; i++)
      if (Quickshell.screens[i].name === target.monitor) return Quickshell.screens[i]
    return null
  }
  readonly property var toplevel: {
    if (!target) return null
    var windows = Hyprland.toplevels.values
    for (var i = 0; i < windows.length; i++) {
      var address = String(windows[i].address).toLowerCase().replace(/^0x/, "")
      if (address === target.address.replace(/^0x/, "")) return windows[i]
    }
    return null
  }
  readonly property var source: toplevel ? toplevel.wayland : null
  readonly property var geometry: HoverModel.popupGeometry(target, monitorScreen, padding, footer)

  function hide() {
    // Detach before destroying the view, so no capture survives an unmap.
    if (popup.item) popup.item.releaseCapture()
    target = null
  }
  function previewInline(data) {
    if (!enabled || !data) return
    hide()
    inlineTarget = data
    inlineDwell.restart()
  }
  function cancelInline() {
    inlineDwell.stop()
    inlineTarget = null
    hide()
  }
  Timer {
    id: inlineDwell
    interval: 250
    onTriggered: if (root.enabled && root.inlineTarget) root.target = root.inlineTarget
  }
  function syncNative() {
    if (!ready) return
    cancelInline()
    if (enabled) {
      if (!loadNative.running) loadNative.running = true
    } else if (!disableNative.running) disableNative.running = true
  }
  Component.onCompleted: { ready = true; syncNative() }
  onEnabledChanged: syncNative()

  // The existing service starts at login and after a shell restart. No
  // additional Hyprland configuration or compositor reload is needed.
  Process {
    id: loadNative
    command: ["sh", Qt.resolvedUrl("native/load.sh").toString().replace(/^file:\/\//, "")]
    onExited: function(exitCode, exitStatus) {
      root.nativeLoaded = exitCode === 0
      if (exitCode !== 0) console.warn("window-previews: native hover detector could not load; see native/README.md")
    }
  }
  Process {
    id: disableNative
    command: ["hyprctl", "windowpreviews", "disable"]
  }
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event.name !== "windowpreviews") return
      if (root.inlineTarget) return // Raised thumbnail hover is owned by QML.
      var next = root.enabled ? HoverModel.parsePayload(String(event.data)) : null
      root.hide()
      root.target = next
    }
  }
  // Address removal invalidates the source binding and destroys the popup.
  LazyLoader {
    id: popup
    active: root.enabled && root.target !== null && root.monitorScreen !== null && root.source !== null
    component: Component {
      PanelWindow {
        id: panel
        screen: root.monitorScreen
        anchors { left: true; top: true }
        margins { left: root.geometry.x; top: root.geometry.y }
        implicitWidth: root.geometry.width
        implicitHeight: root.geometry.height
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"
        mask: Region {} // Preview is a tooltip: all pointer input passes through.
        WlrLayershell.namespace: "omarchy-window-previews-tab-preview"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        property bool capturing: true
        function releaseCapture() { capturing = false }
        function captureStatus() {
          return {hasContent: capture.hasContent, sourceAvailable: !!capture.windowSource,
            retries: capture.retryCount, sourceWidth: capture.sourceSize.width,
            sourceHeight: capture.sourceSize.height}
        }
        Rectangle {
          anchors.fill: parent
          color: Commons.Color.menu.background
          radius: Style.cornerRadius
          border.width: 1
          border.color: Commons.Color.accent
        }
        WindowCapture {
          id: capture
          x: root.padding
          y: root.padding
          width: root.geometry.imageWidth
          height: root.geometry.imageHeight
          fallbackAspect: root.target ? root.target.window.w / root.target.window.h : 16 / 9
          windowSource: root.source
          captureActive: panel.capturing
        }
        Image {
          anchors.centerIn: capture
          width: Math.min(Style.space(32), capture.width, capture.height)
          height: width
          visible: !capture.hasContent
          source: {
            var appId = root.source ? root.source.appId : ""
            var entry = DesktopEntries.heuristicLookup(appId)
            return Quickshell.iconPath(entry && entry.icon ? entry.icon : "application-x-executable", true)
          }
          fillMode: Image.PreserveAspectFit
        }
        Text {
          x: root.padding
          y: panel.height - root.padding - root.footer
          width: panel.width - root.padding * 2
          height: root.footer
          text: root.target ? root.target.title : ""
          textFormat: Text.PlainText
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.bodySmall
          color: Commons.Color.menu.text
          elide: Text.ElideRight
          verticalAlignment: Text.AlignVCenter
        }
      }
    }
  }
  IpcHandler {
    target: "window-previews-hover-debug"
    function status(): string {
      return JSON.stringify({enabled: root.enabled, nativeLoaded: root.nativeLoaded,
        opened: !!popup.item, address: root.target ? root.target.address : "",
        geometry: root.target ? root.geometry : null,
        capture: popup.item ? popup.item.captureStatus() : null})
    }
  }
}
