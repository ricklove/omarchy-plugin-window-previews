import QtQuick
import Quickshell.Wayland

// One capture implementation for the overview and group-tab popup. The owner
// detaches/destroys this component when hidden; no persistent frame cache.
ScreencopyView {
  id: capture
  property var windowSource: null
  property bool captureActive: true
  property real fallbackAspect: 16 / 9
  readonly property real aspect: sourceSize.width > 0 && sourceSize.height > 0
    ? sourceSize.width / sourceSize.height : fallbackAspect
  property bool attached: true
  property int retryCount: 0
  property bool streamStopped: false
  captureSource: captureActive && attached ? windowSource : null
  live: captureActive
  paintCursor: false

  function resetCapture() {
    reconnect.stop()
    retryCapture.stop()
    retryCount = 0
    streamStopped = false
    attached = captureActive
    if (captureActive) retryCapture.restart()
  }
  onWindowSourceChanged: resetCapture()
  onCaptureActiveChanged: resetCapture()
  onHasContentChanged: {
    if (hasContent) { streamStopped = false; retryCapture.stop() }
  }
  onStopped: {
    streamStopped = true
    if (captureActive && retryCount < 4 && !retryCapture.running) retryCapture.start()
  }
  Component.onCompleted: resetCapture()
  Component.onDestruction: { captureSource = null }
  Timer {
    id: retryCapture
    interval: 500 * Math.pow(2, capture.retryCount)
    onTriggered: {
      if (!capture.captureActive || (capture.hasContent && !capture.streamStopped) || capture.retryCount >= 4) return
      capture.retryCount++
      capture.attached = false
      reconnect.restart()
    }
  }
  Timer {
    id: reconnect
    interval: 50
    onTriggered: {
      if (!capture.captureActive) return
      capture.streamStopped = false
      capture.attached = true
      if (capture.retryCount < 4 && !capture.hasContent) retryCapture.restart()
    }
  }
}
