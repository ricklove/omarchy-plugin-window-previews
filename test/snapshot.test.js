const test = require('node:test')
const assert = require('node:assert/strict')
const {parsePayload} = require('../HoverModel.js')
const {parseTab, imageSize} = require('../SnapshotModel.js')
test('snapshot packets preserve group geometry and reject invalid rectangles', () => {
  const record = {id:'0x123',address:'0xabc',monitor:'DP-1',tab:{x:2,y:4,w:400,h:28},
    window:{w:1600,h:900},bar:{x:0,y:0,w:1200,h:32},front:true,indicator:3}
  assert.equal(parseTab(JSON.stringify(record),parsePayload).id,'0x123')
  assert.equal(parseTab(JSON.stringify({...record,bar:{...record.bar,w:-1}}),parsePayload),null)
  assert.equal(parseTab(JSON.stringify({...record,id:'../not-a-group'}),parsePayload),null)
  assert.equal(parseTab('{}',parsePayload),null)
})
test('retained snapshot dimensions stay tiny for large, portrait and unusual windows', () => {
  for (const window of [{w:3840,h:2160},{w:1080,h:1920},{w:30000,h:100},{w:100,h:30000}]) {
    const size = imageSize(window,36)
    assert.ok(size.width <= 60 && size.height <= 36)
    assert.ok(size.width >= 1 && size.height >= 1)
    assert.ok(size.width * size.height * 4 <= 8640)
  }
  assert.deepEqual(imageSize({w:1600,h:900},36),{width:60,height:34})
  assert.ok(imageSize({w:1600,h:900},36,30).width <= 30)
})
