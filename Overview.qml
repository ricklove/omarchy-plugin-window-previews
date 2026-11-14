import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Each monitor shows its own occupied workspaces, scaled to fit its output.
// Group members share a grid in the group's original region. Overlapping
// free windows share a grid in their original combined region.
//
// The board is a snapshot, not a binding: Hyprland.refreshToplevels() is
// asynchronous and blanks every lastIpcObject until the reply lands, so a
// binding over Hyprland.toplevels would render an empty board for half a
// second on every open. settleTimer polls the objects instead and swaps the
// whole board in once they are all populated.
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  property bool opened: false
  property double openedAt: 0
  // board / toplevelByAddress are swapped together: the delegates index the
  // map by the address the board carries.
  property var board: []
  property var toplevelByAddress: ({})
  property var selection: null
  property string selectedAddress: ""
  property var previews: []

  function registerPreview(item) { root.previews = root.previews.concat([item]) }
  function unregisterPreview(item) { root.previews = root.previews.filter(function(p) { return p !== item }) }
  function thumbnailItems() {
    return root.previews.filter(function(p) { return !!p }).map(function(p) { return p.navigationInfo() })
  }
  IpcHandler {
    target: "omaspaces-overview-debug"
    function status(): string {
      return JSON.stringify({opened: root.opened, selectedAddress: root.selectedAddress,
        surfaces: root.surfaceStates(),
        captures: root.previews.filter(function(p) { return !!p }).map(function(p) { return p.captureState() })})
    }
  }
  property int settleTicks: 0
  // Held between dismiss() and the dispatch that follows it; see activate().
  property var pendingTarget: null

  readonly property string manifestId: manifest && manifest.id ? manifest.id : "io.github.terrifiedbug.omaspaces"

  // Overlays are not handed their inline settings (shell.qml only assigns
  // omarchyPath/shell/manifest/registries/service), so read the plugins[]
  // entry out of shell.json directly. watchChanges keeps a live edit honest.
  readonly property var settings: {
    var text = shellConfig.text()
    if (!text) return ({})
    var config = ({})
    try { config = JSON.parse(text) } catch (e) { return ({}) }
    var entries = config && config.plugins && config.plugins.length !== undefined ? config.plugins : []
    for (var i = 0; i < entries.length; i++) if (entries[i] && entries[i].id === root.manifestId) return entries[i]
    return ({})
  }

  readonly property int workspaceCount: Model.normalizeWorkspaceCount(setting("workspaces", Model.DEFAULT_WORKSPACES), Model.DEFAULT_WORKSPACES)

  readonly property color background: Commons.Color.menu.background
  readonly property color foreground: Commons.Color.menu.text
  readonly property color faintForeground: Qt.darker(Commons.Color.menu.text, 1.5)
  readonly property color surfaceBorder: Commons.Color.menu.border
  readonly property string fontFamily: Style.font.menuFamily
  // Nerd Font glyphs come from the bar family; OMARCHY_MENU_FONT may point
  // menuFamily at a text font with no glyph coverage.
  readonly property string glyphFamily: Style.font.family
  readonly property int boardMargin: Style.spacing.panelPadding * 2
  readonly property int tileSpacing: Style.space(16)
  readonly property int columnSpacing: Style.space(8)
  readonly property int thumbRadius: Style.space(4)

  readonly property int windowCount: {
    var total = 0
    for (var m = 0; m < board.length; m++)
      for (var w = 0; w < board[m].workspaces.length; w++) total += board[m].workspaces[w].windows.length
    return total
  }

  readonly property int groupCount: {
    var total = 0
    for (var m = 0; m < board.length; m++)
      for (var w = 0; w < board[m].workspaces.length; w++) total += board[m].workspaces[w].groups.length
    return total
  }

  readonly property string focusedMonitorName: {
    for (var m = 0; m < board.length; m++) if (board[m].monitor.focused) return board[m].monitor.name
    return ""
  }

  // Each physical output has its own surface and only its own board row.
  function focusOverviewKeys() {
    for (var i = 0; i < overviewPanels.count; i++) {
      var instance = overviewPanels.objectAt(i)
      if (instance && instance.ownsKeyboard) instance.focusKeys()
    }
  }

  function surfaceStates() {
    var result = []
    for (var i = 0; i < overviewPanels.count; i++) {
      var host = overviewPanels.objectAt(i)
      if (host) result.push({screen: host.modelData.name, retries: host.retries,
        recycling: host.recycling, alpha: host.lastAlpha, exhausted: host.retries >= 4 && host.lastAlpha < 0.9})
    }
    return result
  }

  // A captured frame does not prove that its output surface was presented.
  // Read compositor mapping/opacity independently before retrying an output.
  Process {
    id: surfaceProbe
    command: ["hyprctl", "layers", "-j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (!root.opened) return
        var layers
        try { layers = JSON.parse(text) } catch (e) { return }
        for (var i = 0; i < overviewPanels.count; i++) {
          var host = overviewPanels.objectAt(i)
          if (host) host.checkSurface(layers[host.modelData.name])
        }
      }
    }
  }
  Timer {
    interval: 500
    running: root.opened
    repeat: true
    onTriggered: { if (!surfaceProbe.running) surfaceProbe.running = true }
  }

  function setting(name, fallback) {
    var value = settings[name]
    return value === undefined || value === null ? fallback : value
  }

  function plural(count, word) {
    return count + " " + word + (count === 1 ? "" : "s")
  }

  // The summon contract passes a JSON string; the board takes no payload keys,
  // so the argument is accepted and ignored rather than parsed into nothing.
  function open(payloadJson) {
    root.openedAt = Date.now()
    root.opened = true
    root.selection = null
    root.selectedAddress = ""
    // Paint immediately from the IPC objects the shell already holds, then
    // refresh: a fresh reply lands ~0.5 s later and swaps the board in place.
    root.applyBoard()
    root.rebuild()
    Qt.callLater(root.focusOverviewKeys)
  }

  function close() {
    root.opened = false
  }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.manifestId)
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  function rebuild() {
    root.settleTicks = 0
    Hyprland.refreshToplevels()
    Hyprland.refreshMonitors()
    settleTimer.restart()
  }

  // Only a complete snapshot is published: refreshToplevels() blanks every
  // lastIpcObject until its reply lands, so assigning a partial tick would
  // swap the board for an emptier one and flicker. `force` is the settle
  // deadline — then draw whatever answered rather than nothing.
  function applyBoard(force) {
    var monitors = [], clients = [], byAddress = ({}), complete = true
    var monitorValues = Hyprland.monitors.values
    for (var m = 0; m < monitorValues.length; m++) {
      var monitorObject = monitorValues[m].lastIpcObject
      if (!monitorObject || monitorObject.id === undefined) complete = false
      else monitors.push(monitorObject)
    }
    var toplevelValues = Hyprland.toplevels.values
    for (var t = 0; t < toplevelValues.length; t++) {
      var clientObject = toplevelValues[t].lastIpcObject
      if (!clientObject || !clientObject.address) {
        complete = false
        continue
      }
      clients.push(clientObject)
      byAddress[String(clientObject.address)] = toplevelValues[t]
    }
    if (monitors.length === 0) return false
    if (!complete && force !== true) return false
    root.toplevelByAddress = byAddress
    root.board = Model.buildBoard(monitors, clients, root.workspaceCount, Model.parseWorkspaceBlocks(workspaceBlocks.text()), true)
    if (!root.validSelection(root.selection)) root.selection = Model.initialSelection(root.board)
    if (!root.selectedAddress || !byAddress[root.selectedAddress]) {
      root.selectedAddress = ""
      var fallback = null
      for (var mi = 0; mi < root.board.length; mi++) {
        for (var wi = 0; wi < root.board[mi].workspaces.length; wi++) {
          var windows = root.board[mi].workspaces[wi].windows
          for (var ti = 0; ti < windows.length; ti++) {
            if (!fallback || windows[ti].focusHistoryID < fallback.focusHistoryID) fallback = windows[ti]
          }
        }
      }
      if (fallback) root.selectedAddress = fallback.address
    }
    return complete
  }

  function validSelection(sel) {
    if (!sel) return false
    var row = root.board[sel.mon]
    if (!row) return false
    var ws = row.workspaces[sel.ws]
    if (!ws) return false
    if (sel.group === -1) return true
    var group = ws.groups[sel.group]
    return !!(group && group.members[sel.member])
  }

  function move(key) {
    var next = Model.nextThumbnail(root.thumbnailItems(), root.selectedAddress, key)
    if (!next) return
    root.selectedAddress = next.address
    root.selection = next.selection
  }

  function activateSelection() {
    if (root.selectedAddress) {
      root.activate({kind: "window", address: root.selectedAddress})
      return
    }
    if (!root.validSelection(root.selection)) return
    root.activate(Model.activationTarget(root.board, root.selection))
  }

  function activateDigit(digit) {
    if (!root.validSelection(root.selection)) return
    var target = Model.digitTarget(root.board, root.selection, digit)
    if (target) root.activate(target)
  }

  // The board takes exclusive keyboard focus, and when its layer surface
  // unmaps Hyprland gives focus back to the window it took it from — which
  // silently undoes a focus dispatched while the board was still up (the
  // workspace switch survived, the tab pick did not). So dismiss first and
  // dispatch once the surface is gone.
  function activate(target) {
    root.pendingTarget = target
    root.dismiss()
    activateTimer.restart()
  }

  function captureFor(address) {
    if (!root.opened) return null
    var toplevel = root.toplevelByAddress[address]
    return toplevel ? toplevel.wayland : null
  }

  // Mirrors services/AppLibrary.qml's fallback chain: the desktop entry's own
  // icon name first, then the app id, then the generic executable icon.
  function appIcon(appId) {
    var entry = DesktopEntries.heuristicLookup(appId)
    var icon = entry && entry.icon ? entry.icon : appId
    var path = Quickshell.iconPath(icon, true)
    return path.length > 0 ? path : Quickshell.iconPath("application-x-executable", true)
  }

  function isTileSelected(monIndex, wsIndex) {
    var sel = root.selection
    return !!sel && sel.group === -1 && sel.mon === monIndex && sel.ws === wsIndex
  }

  function isMemberSelected(monIndex, wsIndex, groupIndex, memberIndex) {
    var sel = root.selection
    return !!sel && sel.mon === monIndex && sel.ws === wsIndex && sel.group === groupIndex && sel.member === memberIndex
  }

  FileView {
    id: workspaceBlocks
    path: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/omarchy/monitor-workspaces"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: { if (root.opened) root.rebuild() }
  }

  FileView {
    id: shellConfig
    path: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
    watchChanges: true
    printErrors: false
  }

  Timer {
    id: settleTimer
    interval: 250
    repeat: true
    // Twelve ticks is three seconds; a toplevel that has not answered by then
    // is drawn without a thumbnail rather than holding the board back.
    onTriggered: {
      root.settleTicks += 1
      var deadline = root.settleTicks >= 12
      if (root.applyBoard(deadline) || deadline) settleTimer.stop()
    }
  }

  // Long enough for the layer surface to unmap and Hyprland to settle its
  // focus; one frame is not.
  Timer {
    id: activateTimer
    interval: 60

    onTriggered: {
      var target = root.pendingTarget
      root.pendingTarget = null
      if (!target) return
      if (target.kind === "workspace") Hyprland.dispatch("hl.dsp.focus({ workspace = " + target.id + " })")
      else Hyprland.dispatch("hl.dsp.focus({ window = \"address:" + target.address + "\" })")
    }
  }

  // Compositor events arrive in bursts (a group move emits three), and each
  // refresh blanks every lastIpcObject, so a refresh per event would never
  // settle. Collapse the burst, then refresh once.
  Timer {
    id: rebuildTimer
    interval: 150
    onTriggered: root.rebuild()
  }

  Connections {
    target: Hyprland

    function onRawEvent(event) {
      if (!root.opened) return
      var names = ["openwindow", "closewindow", "movewindow", "togglegroup", "moveintogroup", "moveoutofgroup", "workspace", "focusedmon"]
      if (names.indexOf(event.name) !== -1) rebuildTimer.restart()
    }
  }

  Instantiator {
    id: overviewPanels
    model: Quickshell.screens
    delegate: Item {
      id: host
      required property var modelData
      property bool recycling: false
      property int retries: 0
      property int invisibleChecks: 0
      property real lastAlpha: -1
      property double lastRetryAt: 0
      readonly property bool ownsKeyboard: panelLoader.item ? panelLoader.item.ownsKeyboard : false
      function focusKeys() { if (panelLoader.item) panelLoader.item.focusKeys() }
      function checkSurface(monitorLayers) {
        if (!root.opened || recycling) return
        var alpha = -1
        var levels = monitorLayers && monitorLayers.levels ? monitorLayers.levels : {}
        Object.keys(levels).forEach(function(level) {
          levels[level].forEach(function(surface) {
            if (surface.namespace === "omarchy-omaspaces" && surface.w > 0 && surface.h > 0)
              alpha = Math.max(alpha, Number(surface.alpha))
          })
        })
        lastAlpha = alpha
        if (alpha >= 0.9) { invisibleChecks = 0; return }
        if (Date.now() - root.openedAt < 1000) return
        invisibleChecks++
        if (!Model.retrySurface(alpha, Date.now(), root.openedAt, lastRetryAt, retries, invisibleChecks)) return
        retries++
        lastRetryAt = Date.now()
        invisibleChecks = 0
        recycling = true
        remap.restart()
      }
      Connections {
        target: root
        function onOpenedChanged() {
          if (!root.opened) { remap.stop(); host.recycling = false }
          else { host.retries = 0; host.invisibleChecks = 0; host.lastRetryAt = 0; host.lastAlpha = -1 }
        }
      }
      Timer {
        id: remap
        interval: 100
        onTriggered: { if (root.opened) host.recycling = false }
      }
      LazyLoader {
        id: panelLoader
        active: root.opened && !host.recycling
        component: Component {
    PanelWindow {
    id: panel
    readonly property var modelData: host.modelData
    readonly property int monitorIndex: {
      for (var i = 0; i < root.board.length; i++)
        if (root.board[i].monitor.name === modelData.name) return i
      return -1
    }
    readonly property var monitorRow: monitorIndex >= 0 ? root.board[monitorIndex] : null
    readonly property bool ownsKeyboard: root.selection
      ? root.selection.mon === monitorIndex : modelData.name === root.focusedMonitorName
    function focusKeys() { keyCatcher.forceActiveFocus() }
    onOwnsKeyboardChanged: { if (ownsKeyboard && root.opened) Qt.callLater(focusKeys) }

    visible: root.opened
    screen: modelData
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-omaspaces"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: ownsKeyboard ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      // The theme's scrim is tuned for a big opaque card floating on top of
      // it; this board is sparse, so the desktop underneath keeps competing
      // with the tiles at that strength. Same colour, dimmed harder.
      color: Util.alpha(Commons.Color.menu.scrim, 0.8)
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true

      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) {
          root.dismiss()
          event.accepted = true
        } else if (event.key === Qt.Key_Left) {
          root.move("left")
          event.accepted = true
        } else if (event.key === Qt.Key_Right) {
          root.move("right")
          event.accepted = true
        } else if (event.key === Qt.Key_Up) {
          root.move("up")
          event.accepted = true
        } else if (event.key === Qt.Key_Down) {
          root.move("down")
          event.accepted = true
        } else if (event.key === Qt.Key_Backtab || (event.key === Qt.Key_Tab && (event.modifiers & Qt.ShiftModifier))) {
          root.move("left")
          event.accepted = true
        } else if (event.key === Qt.Key_Tab) {
          root.move("right")
          event.accepted = true
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
          root.activateSelection()
          event.accepted = true
        } else if (event.key >= Qt.Key_1 && event.key <= Qt.Key_9) {
          root.activateDigit(event.key - Qt.Key_0)
          event.accepted = true
        }
      }
    }

    // ---- Board. The tiles are the surface: no card, so they read as
    //      floating over the desktop the scrim dims.
    Column {
      id: boardColumn
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.margins: root.boardMargin
      spacing: Style.spacing.lg

      Item {
        width: parent.width
        height: headerColumn.height

        Column {
          id: headerColumn
          spacing: Style.space(2)

          Text {
            text: "OVERVIEW"
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.letterSpacing: 2
            color: root.faintForeground
          }

          Text {
            text: "Workspaces"
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            color: root.foreground
          }
        }

        Text {
          anchors.right: parent.right
          anchors.bottom: headerColumn.bottom
          textFormat: Text.PlainText
          text: root.board.length === 0
            ? "Loading…"
            : root.plural(panel.monitorRow ? panel.monitorRow.workspaces.length : 0, "workspace") + " · " + panel.modelData.name
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          color: root.faintForeground
        }
      }

      Text {
        visible: root.board.length > 0 && (!panel.monitorRow || panel.monitorRow.workspaces.length === 0)
        text: "No windows on this monitor"
        textFormat: Text.PlainText
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        color: root.foreground
      }

      // ---- One section per monitor: a row of workspace tiles, then a row of
      //      slots holding the group columns that hang under those tiles.
      Repeater {
        model: panel.monitorRow ? 1 : 0

        delegate: Column {
          id: section
          readonly property var modelData: panel.monitorRow
          required property int index

          readonly property int monIndex: panel.monitorIndex
          readonly property var monitor: modelData.monitor
          readonly property var workspaces: modelData.workspaces
          readonly property real logicalWidth: monitor.width / monitor.scale
          readonly property real logicalHeight: monitor.height / monitor.scale
          readonly property int tileCount: workspaces.length
          readonly property int tileWidth: Model.fitTileWidth(tileCount,
            boardColumn.width,
            Math.max(1, panel.height - root.boardMargin * 2 - headerColumn.height - boardColumn.spacing - Style.space(48)),
            logicalHeight / logicalWidth, root.tileSpacing)
          readonly property int tileHeight: Math.round(tileWidth * logicalHeight / logicalWidth)

          // Several groups on one workspace share the tile's width.
          function columnWidth(groups) {
            return Math.min(Math.round(tileWidth * 0.62),
              Math.floor((tileWidth - root.columnSpacing * (groups - 1)) / groups))
          }

          width: boardColumn.width
          spacing: Style.space(8)

          Row {
            visible: root.board.length > 1
            spacing: Style.space(8)

            Text {
              textFormat: Text.PlainText
              text: section.monitor.name + "  " + Math.round(section.logicalWidth) + "×" + Math.round(section.logicalHeight)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              color: root.faintForeground
            }

            Rectangle {
              visible: section.monitor.focused
              width: focusedChip.implicitWidth + Style.space(8)
              height: focusedChip.implicitHeight + Style.space(2)
              radius: Style.space(3)
              color: "transparent"

              Text {
                id: focusedChip
                anchors.centerIn: parent
                text: "FOCUSED"
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                color: Commons.Color.accent
              }
            }
          }

          Row {
            id: tileRow
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: root.tileSpacing

            Repeater {
              model: section.workspaces.length

              delegate: BorderSurface {
                id: tile
                readonly property var modelData: section.workspaces[index]
                required property int index
                readonly property var areas: Model.spatialAreas(workspace)

                readonly property var workspace: modelData
                readonly property bool selected: root.isTileSelected(section.monIndex, index)

                width: section.tileWidth
                height: section.tileHeight
                radius: Style.cornerRadius
                color: "transparent"
                borderSpec: Border.flat("transparent", 0)

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  onEntered: root.selection = { mon: section.monIndex, ws: tile.index, group: -1, member: -1 }
                  onClicked: root.activate({ kind: "workspace", id: tile.workspace.id })
                }

                Text {
                  anchors.centerIn: parent
                  visible: tile.workspace.windows.length === 0
                  text: "EMPTY"
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: 1
                  color: root.faintForeground
                }

                // ---- Window thumbnails, placed by their share of the monitor.
                Item {
                  id: tileCanvas
                  anchors.fill: parent
                  anchors.margins: tile.borderTop
                  clip: true

                  Repeater {
                    model: tile.areas.length
                    delegate: Rectangle {
                      id: area
                      required property int index
                      readonly property var modelData: tile.areas[index]
                      readonly property var members: modelData.members
                      readonly property int groupIndex: modelData.groupIndex
                      readonly property bool grouped: groupIndex >= 0
                      readonly property real leftEdge: Math.max(0, modelData.rect.x)
                      readonly property real topEdge: Math.max(0, modelData.rect.y)
                      x: Math.round(leftEdge * tileCanvas.width)
                      y: Math.round(topEdge * tileCanvas.height)
                      width: Math.max(1, Math.round((Math.min(1, modelData.rect.x + modelData.rect.w) - leftEdge) * tileCanvas.width))
                      height: Math.max(1, Math.round((Math.min(1, modelData.rect.y + modelData.rect.h) - topEdge) * tileCanvas.height))
                      clip: true
                      color: "transparent"
                      border.width: 0
                      border.color: grouped ? Commons.Color.accent : root.surfaceBorder
                      readonly property int labelHeight: members.length > 1 ? Style.space(22) : 0

                      Text {
                        visible: area.labelHeight > 0
                        x: Style.space(6)
                        height: area.labelHeight
                        width: Math.max(0, parent.width - x * 2)
                        textFormat: Text.PlainText
                        text: (area.grouped ? "GROUP · " : "WINDOWS · ") + area.members.length
                        color: area.grouped ? Commons.Color.accent : root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideRight
                        verticalAlignment: Text.AlignVCenter
                      }

                      Item {
                        id: gridArea
                        x: Style.space(4)
                        y: area.labelHeight + Style.space(4)
                        width: Math.max(1, area.width - x * 2)
                        height: Math.max(1, area.height - y - Style.space(4))
                        readonly property int columns: Model.thumbnailColumns(area.members.length,
                          width, height, area.members.length > 0
                            ? area.members[0].rect.w * section.logicalWidth / Math.max(1, area.members[0].rect.h * section.logicalHeight)
                            : section.logicalWidth / section.logicalHeight)
                        readonly property int rows: Math.max(1, Math.ceil(area.members.length / columns))
                        readonly property real cellWidth: width / columns
                        readonly property real cellHeight: height / rows

                        Repeater {
                          model: area.members.length
                          delegate: Rectangle {
                            id: preview
                            readonly property var modelData: area.members[index]
                            required property int index
                            x: (index % gridArea.columns) * gridArea.cellWidth
                            y: Math.floor(index / gridArea.columns) * gridArea.cellHeight
                            width: Math.max(1, gridArea.cellWidth - Style.space(4))
                            height: Math.max(1, gridArea.cellHeight - Style.space(4))
                            color: "transparent"
                            clip: true
                            readonly property bool selected: root.selectedAddress === modelData.address
                            function captureState() {
                              return {address: modelData.address, selected: selected,
                                sourceAvailable: !!capture.windowSource, hasContent: capture.hasContent,
                                streamStopped: capture.streamStopped, retries: capture.retryCount,
                                width: capture.width, height: capture.height}
                            }
                            function navigationInfo() {
                              var point = preview.mapToItem(keyCatcher, preview.width / 2, preview.height / 2)
                              return {address: modelData.address,
                                x: point.x + section.monitor.x, y: point.y + section.monitor.y,
                                selection: {mon: section.monIndex, ws: tile.index,
                                  group: area.groupIndex, member: area.grouped ? preview.index : -1}}
                            }
                            Component.onCompleted: root.registerPreview(preview)
                            Component.onDestruction: root.unregisterPreview(preview)
                            readonly property int footerHeight: Math.min(Style.space(24), height / 3)
                            border.width: 0
                            border.color: selected || modelData.front ? Commons.Color.accent : root.surfaceBorder

                            ScreencopyView {
                              id: capture
                              readonly property real aspect: sourceSize.width > 0 && sourceSize.height > 0
                                ? sourceSize.width / sourceSize.height : section.logicalWidth / section.logicalHeight
                              x: (parent.width - width) / 2
                              y: (parent.height - preview.footerHeight - height) / 2
                              width: Math.max(1, Math.min(parent.width - 4, (parent.height - preview.footerHeight - 4) * aspect))
                              height: Math.max(1, width / aspect)
                              property bool attached: true
                              property int retryCount: 0
                              property bool streamStopped: false
                              readonly property var windowSource: root.captureFor(preview.modelData.address)
                              captureSource: attached ? windowSource : null
                              live: true
                              paintCursor: false

                              function resetCapture() {
                                reconnect.stop()
                                retryCount = 0
                                streamStopped = false
                                attached = true
                                if (root.opened) retryCapture.restart()
                                else retryCapture.stop()
                              }
                              onWindowSourceChanged: resetCapture()
                              onHasContentChanged: {
                                if (hasContent) {
                                  streamStopped = false
                                  retryCapture.stop()
                                }
                              }
                              onStopped: {
                                streamStopped = true
                                if (root.opened && retryCount < 4 && !retryCapture.running)
                                  retryCapture.start()
                              }
                              Component.onCompleted: resetCapture()
                              Connections {
                                target: root
                                function onOpenedChanged() { capture.resetCapture() }
                              }
                              Timer {
                                id: retryCapture
                                interval: 500 * Math.pow(2, capture.retryCount)
                                onTriggered: {
                                  if (!root.opened || (capture.hasContent && !capture.streamStopped) || capture.retryCount >= 4) return
                                  capture.retryCount++
                                  capture.attached = false
                                  reconnect.restart()
                                }
                              }
                              Timer {
                                id: reconnect
                                interval: 50
                                onTriggered: {
                                  if (!root.opened) return
                                  capture.streamStopped = false
                                  capture.attached = true
                                  if (capture.retryCount < 4 && !capture.hasContent) retryCapture.restart()
                                }
                              }
                            }
                            // Draw above the capture so the preview cannot cover its outline.
                            Rectangle {
                              anchors.fill: capture
                              anchors.margins: -2
                              z: 1
                              visible: preview.selected
                              color: "transparent"
                              border.width: 2
                              border.color: Commons.Color.accent
                            }
                            Image {
                              visible: !capture.hasContent
                              anchors.centerIn: capture
                              width: Math.max(1, Math.min(Style.space(32), capture.width, capture.height))
                              height: width
                              source: root.appIcon(preview.modelData.appId)
                              fillMode: Image.PreserveAspectFit
                              asynchronous: true
                            }
                            Text {
                              x: Style.space(4)
                              y: parent.height - preview.footerHeight
                              width: Math.max(0, parent.width - x * 2)
                              height: preview.footerHeight
                              textFormat: Text.PlainText
                              text: preview.modelData.title
                              color: preview.selected ? Commons.Color.accent : root.foreground
                              font.family: root.fontFamily
                              font.pixelSize: Style.font.bodySmall
                              verticalAlignment: Text.AlignVCenter
                              elide: Text.ElideRight
                            }
                            MouseArea {
                              id: previewMouse
                              anchors.fill: parent
                              hoverEnabled: true
                              onEntered: {
                                root.selectedAddress = preview.modelData.address
                                root.selection = preview.navigationInfo().selection
                              }
                              onClicked: root.activate({kind: "window", address: preview.modelData.address})
                            }
                          }
                        }
                      }
                    }
                  }
                }

                Rectangle {
                  anchors.left: parent.left
                  anchors.top: parent.top
                  anchors.margins: Style.space(4)
                  width: numberChip.implicitWidth + Style.space(10)
                  height: numberChip.implicitHeight + Style.space(4)
                  radius: Style.space(3)
                  color: "transparent"

                  Text {
                    id: numberChip
                    anchors.centerIn: parent
                    textFormat: Text.PlainText
                    text: tile.workspace.id
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                    color: root.foreground
                  }
                }

                Rectangle {
                  visible: tile.workspace.current
                  anchors.right: parent.right
                  anchors.top: parent.top
                  anchors.margins: Style.space(4)
                  width: currentChip.implicitWidth + Style.space(8)
                  height: currentChip.implicitHeight + Style.space(2)
                  radius: Style.space(3)
                  color: "transparent"

                  Text {
                    id: currentChip
                    anchors.centerIn: parent
                    text: "CURRENT"
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    color: Commons.Color.accent
                  }
                }

                // Keyboard cursor, drawn outside the tile so it never eats
                // into the thumbnails.
                Rectangle {
                  visible: tile.selected
                  anchors.fill: parent
                  anchors.margins: -Style.space(4)
                  radius: Style.cornerRadius
                  color: "transparent"
                  border.width: 0
                  border.color: Style.focusStateColor(root.foreground, Commons.Color.accent)
                }
              }
            }
          }

        }
      }
    }
  }
        }
      }
    }
  }
}
