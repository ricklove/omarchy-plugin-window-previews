// Native IPC is bounded and validated before it reaches window geometry.
function parsePayload(text) {
  if (typeof text !== "string" || text.length > 4096) return null
  var value
  try { value = JSON.parse(text) } catch (e) { return null }
  if (!value || typeof value.address !== "string" || !/^0x[0-9a-f]+$/i.test(value.address)
      || typeof value.monitor !== "string" || value.monitor.length > 128
      || !value.tab || !value.window) return null
  var keys = ["x", "y", "w", "h"]
  for (var i = 0; i < keys.length; i++)
    if (typeof value.tab[keys[i]] !== "number" || !isFinite(value.tab[keys[i]])
        || Math.abs(value.tab[keys[i]]) > 1000000) return null
  if (value.tab.w <= 0 || value.tab.h <= 0) return null
  if (!(value.window.w > 0 && value.window.w <= 100000)
      || !(value.window.h > 0 && value.window.h <= 100000)) return null
  return {address: value.address.toLowerCase(), monitor: value.monitor,
    tab: value.tab, window: value.window,
    title: typeof value.title === "string" ? value.title.slice(0, 512) : ""}
}

function popupGeometry(target, screen, padding, footer) {
  if (!target || !screen) return {x: 0, y: 0, width: 1, height: 1, imageWidth: 1, imageHeight: 1}
  var margin = 12
  var scale = Math.max(0.001, Math.min(0.25,
    (screen.width - margin * 2 - padding * 2) / target.window.w,
    (screen.height - margin * 2 - padding * 2 - footer) / target.window.h))
  var imageWidth = Math.max(1, Math.round(target.window.w * scale))
  var imageHeight = Math.max(1, Math.round(target.window.h * scale))
  var width = imageWidth + padding * 2, height = imageHeight + padding * 2 + footer
  var x = target.tab.x + target.tab.w / 2 - screen.x - width / 2
  var y = target.tab.y + target.tab.h - screen.y + 6
  if (y + height > screen.height - margin) y = target.tab.y - screen.y - height - 6
  return {x: Math.round(Math.max(margin, Math.min(screen.width - width - margin, x))),
    y: Math.round(Math.max(margin, Math.min(screen.height - height - margin, y))),
    width: width, height: height, imageWidth: imageWidth, imageHeight: imageHeight}
}

if (typeof module !== "undefined") module.exports = {parsePayload: parsePayload, popupGeometry: popupGeometry}
