function parseTab(text, parsePayload) {
  var base = parsePayload(text)
  if (!base) return null
  var data = JSON.parse(text)
  if (typeof data.id !== "string" || !/^0x[0-9a-f]+$/i.test(data.id) || !data.bar) return null
  for (var key of ["x", "y", "w", "h"])
    if (typeof data.bar[key] !== "number" || !isFinite(data.bar[key]) || Math.abs(data.bar[key]) > 1000000) return null
  if (data.bar.w <= 0 || data.bar.h <= 0) return null
  base.id = data.id
  base.bar = data.bar
  base.front = data.front === true
  base.topReserved = typeof data.topReserved === "number" ? Math.max(0, Math.min(100000, data.topReserved)) : 0
  base.indicator = typeof data.indicator === "number" ? Math.max(0, Math.min(64, data.indicator)) : 3
  return base
}

function imageSize(window, availableHeight, availableWidth) {
  var maxWidth = availableWidth === undefined ? 60 : Math.max(1, Math.min(60, availableWidth))
  var scale = Math.min(maxWidth / Math.max(1, window.w), Math.max(1, Math.min(36, availableHeight)) / Math.max(1, window.h))
  return {width: Math.max(1, Math.round(window.w * scale)), height: Math.max(1, Math.round(window.h * scale))}
}
if (typeof module !== "undefined") module.exports = {parseTab, imageSize}
