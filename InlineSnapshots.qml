import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import "HoverModel.js" as HoverModel
import "SnapshotModel.js" as SnapshotModel

Item {
  id: root
  property bool nativeReady: false
  property var hoverController: null
  property string dragTarget: ""
  property bool ready: false
  property var rows: []
  property var pendingRows: null
  property int pendingCount: 0
  property bool suspended: false
  property bool customLabels: false
  property var savedSnapshots: ({})
  property var cells: []
  property var queue: []
  property var activeShot: null
  property int completed: 0
  property int failed: 0

  function syncNative() {
    if (!ready || !nativeReady) return
    if (!enabled) clear()
    if (!sync.running) sync.running = true
  }
  function clear() {
    shotTimeout.stop()
    nextShot.stop()
    activeShot = null
    suspended = false
    customLabels = false
    queue = []
    rows = []
    savedSnapshots = ({})
    dragTarget = ""
    pendingRows = null
  }
  Component.onCompleted: { ready = true; syncNative() }
  onNativeReadyChanged: syncNative()
  onEnabledChanged: syncNative()
  Process {
    id: sync
    command: ["hyprctl", "windowpreviews", root.enabled ? "tabs-labels" : "snapshots-off"]
  }
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event.name === "windowpreviewsdrag") {
        var drag
        try { drag = JSON.parse(String(event.data)) } catch (e) { return }
        root.dragTarget = typeof drag.target === "string" ? drag.target : ""
        if (root.hoverController) root.hoverController.cancelInline()
        return
      }
      if (event.name === "windowpreviewslabels") { root.customLabels = String(event.data) === "custom"; return }
      if (event.name !== "windowpreviewstabs" || !root.enabled) return
      var text = String(event.data)
      if (text === "paused") {
        root.suspended = true
        if (root.activeShot) {
          root.queue = [root.activeShot].concat(root.queue)
          root.activeShot = null
          shotTimeout.stop()
        }
        return
      }
      if (text === "begin") { root.pendingRows = ({}); root.pendingCount = 0; return }
      if (text === "end") {
        if (root.pendingRows === null) return
        var rows = [], keys = Object.keys(root.pendingRows).sort()
        for (var i = 0; i < keys.length; i++) rows.push(root.pendingRows[keys[i]])
        // Retain only tiny images belonging to currently visible tabs. Reordering
        // delegates transfers these references instead of recapturing full windows.
        var saved = ({})
        for (var r = 0; r < rows.length; r++)
          for (var t = 0; t < rows[r].tabs.length; t++) {
            var address = rows[r].tabs[t].address
            if (root.savedSnapshots[address]) saved[address] = root.savedSnapshots[address]
          }
        root.savedSnapshots = saved
        root.rows = rows
        root.suspended = false
        nextShot.restart()
        root.pendingRows = null
        return
      }
      if (root.pendingRows === null || root.pendingCount >= 128) return
      var tab = SnapshotModel.parseTab(text, HoverModel.parsePayload)
      if (!tab) return
      if (!root.pendingRows[tab.id]) root.pendingRows[tab.id] = {id: tab.id, bar: tab.bar, monitor: tab.monitor, topReserved: tab.topReserved, tabs: []}
      root.pendingRows[tab.id].tabs.push(tab)
      root.pendingCount++
    }
  }
  function registerCell(cell) { cells = cells.concat([cell]); request(cell) }
  function unregisterCell(cell) {
    queue = queue.filter(function(c) { return c && c !== cell })
    cells = cells.filter(function(c) { return c && c !== cell })
    if (activeShot === cell) { activeShot = null; shotTimeout.stop(); nextShot.restart() }
  }
  function request(cell) {
    if (!cell || !cell.windowSource || !cell.wantsShot || activeShot === cell || queue.indexOf(cell) >= 0) return
    queue = queue.concat([cell])
    nextShot.restart()
  }
  function pump() {
    if (activeShot || !enabled || suspended) return
    var rest = queue.slice()
    while (rest.length > 0) {
      var cell = rest.shift()
      if (!cell || !cell.windowSource || !cell.wantsShot) continue
      queue = rest
      activeShot = cell
      shotTimeout.restart()
      return
    }
    queue = []
  }
  function finish(cell, result, address) {
    if (!cell || activeShot !== cell || cell.address !== address) return
    if (result) { cell.snapshot = result; savedSnapshots[address] = result; completed++ }
    else failed++
    cell.wantsShot = false
    activeShot = null // Destroys the capture Loader and its full-size buffers.
    shotTimeout.stop()
    nextShot.restart()
  }
  Timer { id: nextShot; interval: 40; onTriggered: root.pump() }
  Timer {
    id: shotTimeout
    interval: 2000
    onTriggered: { if (root.activeShot) root.finish(root.activeShot, null, root.activeShot.address) }
  }

  Instantiator {
    id: strips
    model: root.enabled ? root.rows.length : 0
    delegate: PanelWindow {
      id: strip
      required property int index
      readonly property var row: root.rows[index]
      readonly property var output: {
        if (!row) return null
        for (var i = 0; i < Quickshell.screens.length; i++)
          if (Quickshell.screens[i].name === row.monitor) return Quickshell.screens[i]
        return null
      }
      readonly property int raisedHeight: output && row ? Math.min(36, Math.max(0, Math.floor(row.bar.y - output.y - row.topReserved))) : 0
      screen: output
      visible: output !== null && row !== undefined && !root.suspended
      anchors { top: true; left: true }
      margins { left: strip.output && strip.row ? Math.round(strip.row.bar.x - strip.output.x) : 0
        top: strip.output && strip.row ? Math.round(strip.row.bar.y - strip.output.y) - strip.raisedHeight : 0 }
      implicitWidth: row ? Math.max(1, Math.ceil(row.bar.w)) : 1
      implicitHeight: row ? Math.max(1, Math.ceil(row.bar.h)) + raisedHeight : 1
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      mask: Region { id: raisedInput }
      WlrLayershell.namespace: "omarchy-window-previews-tab-snapshots"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      Repeater {
        model: strip.row ? strip.row.tabs.length : 0
        delegate: Rectangle {
          id: cell
          required property int index
          readonly property var tab: strip.row.tabs[index]
          readonly property string address: tab ? tab.address : ""
          readonly property bool front: tab ? tab.front : false
          property bool wantsShot: true
          property bool cellReady: false
          property var snapshot: null
          readonly property var toplevel: {
            var windows = Hyprland.toplevels.values
            for (var i = 0; i < windows.length; i++)
              if (String(windows[i].address).toLowerCase().replace(/^0x/, "") === address.replace(/^0x/, "")) return windows[i]
            return null
          }
          readonly property var windowSource: toplevel ? toplevel.wayland : null
          readonly property var thumbSize: SnapshotModel.imageSize(tab ? tab.window : {w:16,h:9},
            Math.min((height - 2) * 2, height + strip.raisedHeight), width - 8)
          property Region inputRegion: Region {
            x: Math.round(cell.x + thumbnail.x)
            y: Math.round(cell.y + thumbnail.y)
            width: Math.ceil(thumbnail.width)
            height: Math.ceil(Math.max(0, -thumbnail.y))
          }
          function diagnostic() {
            return {address: address, retained: snapshot !== null, capturing: !!captureLoader.item,
              imageWidth: thumbnail.sourceSize.width, imageHeight: thumbnail.sourceSize.height,
              pixelBytes: snapshot ? thumbnail.sourceSize.width * thumbnail.sourceSize.height * 4 : 0}
          }
          function invalidate() {
            root.unregisterCell(cell)
            snapshot = root.savedSnapshots[address] || null
            wantsShot = snapshot === null
            root.registerCell(cell)
          }
          onAddressChanged: if (cellReady) invalidate()
          onFrontChanged: if (cellReady && front) { wantsShot = true; root.request(cell) }
          onWindowSourceChanged: if (cellReady) root.request(cell)
          Component.onCompleted: {
            snapshot = root.savedSnapshots[address] || null
            wantsShot = snapshot === null
            cellReady = true
            raisedInput.regions.push(inputRegion)
            root.registerCell(cell)
          }
          Component.onDestruction: {
            var index = raisedInput.regions.indexOf(inputRegion)
            if (index >= 0) raisedInput.regions.splice(index, 1)
            root.unregisterCell(cell)
          }
          x: tab ? tab.tab.x - strip.row.bar.x : 0
          y: tab ? tab.tab.y - strip.row.bar.y + strip.raisedHeight : 0
          width: tab ? Math.max(1, tab.tab.w) : 1
          height: tab ? Math.max(1, tab.tab.h - tab.indicator) : 1
          // Native text is temporarily transparent while these custom labels
          // are mapped. Preserve native tab backgrounds and tint only the front tab.
          color: "transparent"
          border.width: root.dragTarget === cell.address ? 2 : 0
          border.color: Commons.Color.accent
          Rectangle {
            anchors.fill: parent
            visible: cell.front
            color: Util.alpha(Commons.Color.accent, 0.18)
          }
          Image {
            id: thumbnail
            x: 4
            y: cell.height - height
            width: cell.thumbSize.width
            height: cell.thumbSize.height
            source: cell.snapshot ? cell.snapshot.url : ""
            cache: false
            fillMode: Image.PreserveAspectFit
          }
          MouseArea {
            x: thumbnail.x
            y: thumbnail.y
            width: thumbnail.width
            height: Math.max(0, -thumbnail.y)
            property real pressedX: 0
            property real pressedY: 0
            property bool moved: false
            onPressed: function(mouse) {
              if (mouse.modifiers & Qt.MetaModifier) { mouse.accepted = false; return }
              pressedX = mouse.x; pressedY = mouse.y; moved = false
            }
            onPositionChanged: function(mouse) {
              if (pressed && Math.pow(mouse.x-pressedX,2)+Math.pow(mouse.y-pressedY,2) >= 36) moved = true
            }
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton
            onEntered: {
              if (!root.hoverController || !cell.tab) return
              root.hoverController.previewInline({address: cell.address, monitor: cell.tab.monitor,
                tab: cell.tab.tab, window: cell.tab.window,
                title: cell.toplevel ? cell.toplevel.title : ""})
            }
            onExited: if (root.hoverController) root.hoverController.cancelInline()
            onClicked: {
              if (moved) return
              if (root.hoverController) root.hoverController.cancelInline()
              Hyprland.dispatch("hl.dsp.focus({ window = \"address:" + cell.address + "\" })")
            }
          }
          Text {
            visible: root.customLabels
            x: thumbnail.x + thumbnail.width + 6
            width: Math.max(0, cell.width - x - 4)
            height: cell.height
            text: cell.toplevel ? cell.toplevel.title : ""
            textFormat: Text.PlainText
            color: cell.front ? Commons.Color.accent : Commons.Color.menu.text
            font.family: Style.font.menuFamily
            font.pixelSize: Math.min(Style.font.bodySmall, Math.max(8, cell.height - 6))
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
          }
          Loader {
            id: captureLoader
            x: thumbnail.x
            y: thumbnail.y
            width: thumbnail.width
            height: thumbnail.height
            active: root.activeShot === cell && cell.windowSource !== null
            sourceComponent: Component {
              WindowCapture {
                id: capture
                width: captureLoader.width
                height: captureLoader.height
                windowSource: cell.windowSource
                live: false
                property bool grabPending: false
                function grab() {
                  if (!hasContent || grabPending) return
                  grabPending = true
                  var address = cell.address
                  var accepted = grabToImage(function(result) { root.finish(cell, result, address) },
                    Qt.size(Math.max(1, Math.round(width)), Math.max(1, Math.round(height))))
                  if (!accepted) root.finish(cell, null, address)
                }
                onHasContentChanged: if (hasContent) Qt.callLater(grab)
              }
            }
          }
        }
      }
    }
  }
  IpcHandler {
    target: "window-previews-snapshots-debug"
    function status(): string {
      var details = root.cells.filter(function(cell) { return !!cell }).map(function(cell) { return cell.diagnostic() })
      return JSON.stringify({enabled: root.enabled, suspended: root.suspended, customLabels: root.customLabels, groups: root.rows.length, queued: root.queue.length,
        activeCaptures: root.activeShot ? 1 : 0, completed: root.completed, failed: root.failed,
        retainedPixelBytes: details.reduce(function(total, c) { return total + c.pixelBytes }, 0), tabs: details})
    }
  }
}
