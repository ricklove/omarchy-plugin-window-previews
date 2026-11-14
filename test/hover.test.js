const test = require('node:test')
const assert = require('node:assert/strict')
const {parsePayload, popupGeometry} = require('../HoverModel.js')
const payload = {address:'0xabc', monitor:'HDMI-A-2', tab:{x:2200,y:100,w:400,h:20},
  window:{w:1600,h:900}, title:'<img src="https://example.invalid/">'}

test('native payload rejects malformed or unbounded geometry and preserves titles as data', () => {
  assert.equal(parsePayload('{}'), null)
  assert.equal(parsePayload('x'.repeat(4097)), null)
  assert.equal(parsePayload(JSON.stringify({...payload, address:'exec(command)'})), null)
  assert.equal(parsePayload(JSON.stringify({...payload, tab:{...payload.tab, x:1e9}})), null)
  assert.equal(parsePayload(JSON.stringify({...payload, window:{w:0,h:900}})), null)
  assert.deepEqual(parsePayload(JSON.stringify(payload)), payload)
})
test('quarter-size previews use logical monitor coordinates and remain inside screen edges', () => {
  const screen = {x:1920,y:0,width:3840,height:2160}
  const g = popupGeometry(payload, screen, 6, 24)
  assert.equal(g.imageWidth,400)
  assert.equal(g.imageHeight,225)
  assert.equal(g.x,274)
  assert.equal(g.y,126)
  const edge = popupGeometry({...payload,tab:{x:5700,y:2100,w:60,h:20}}, screen,6,24)
  assert.ok(edge.x + edge.width <= screen.width - 12)
  assert.ok(edge.y + edge.height < 2100)
  const huge = popupGeometry({...payload,window:{w:20000,h:20000}}, {x:0,y:0,width:800,height:600},6,24)
  assert.ok(huge.width <= 776 && huge.height <= 576)
  assert.equal(huge.imageWidth,huge.imageHeight)
})
