const test = require("node:test")
const assert = require("node:assert/strict")
const Model = require("../Model.js")

// Shapes copied from live `hyprctl monitors -j` / `clients -j` on a 2880x1800
// @ scale 2 panel (logical 1440x900): every tiled window reports the same
// at/size, `grouped` lists tab order and has length 1 when ungrouped.
const MONITOR = {
  id: 0,
  name: "eDP-1",
  x: 0,
  y: 0,
  width: 2880,
  height: 1800,
  scale: 2,
  focused: true,
  activeWorkspace: { id: 2, name: "2" }
}

const GROUP = ["0xA", "0xB"]

function client(overrides) {
  return Object.assign({
    address: "0xA",
    class: "google-chrome",
    title: "Tab",
    workspace: { id: 1, name: "1" },
    monitor: 0,
    at: [12, 66],
    size: [1416, 822],
    mapped: true,
    hidden: false,
    visible: true,
    grouped: ["0xA"],
    focusHistoryID: 0
  }, overrides)
}

// Client order deliberately puts the background tab first so the group's
// member order can only come from `grouped`.
const CLIENTS = [
  client({ address: "0xB", title: "Background tab", visible: false, grouped: GROUP, focusHistoryID: 2 }),
  client({ address: "0xA", title: "Front tab", visible: true, grouped: GROUP, focusHistoryID: 1 }),
  client({ address: "0xC", title: "Terminal", class: "com.mitchellh.ghostty", workspace: { id: 2, name: "2" }, grouped: ["0xC"] }),
  client({ address: "0xD", title: "Notes", workspace: { id: 7, name: "7" }, grouped: ["0xD"] })
]

const BOARD = Model.buildBoard([MONITOR], CLIENTS, 5)

test("asList unwraps a QVariantList-shaped value and tolerates nothing", () => {
  assert.deepEqual(Model.asList({ length: 2, 0: "a", 1: "b" }), ["a", "b"])
  assert.deepEqual(Model.asList(undefined), [])
})

test("buildBoard lists 1..count plus any populated higher workspace", () => {
  assert.deepEqual(BOARD[0].workspaces.map(ws => ws.id), [1, 2, 3, 4, 5, 7])
})

test("buildBoard groups the tabs in `grouped` order, not client order", () => {
  const ws1 = BOARD[0].workspaces[0]
  assert.equal(ws1.windows.length, 2)
  assert.equal(ws1.groups.length, 1)
  assert.deepEqual(ws1.groups[0].members.map(w => w.address), ["0xA", "0xB"])
  assert.equal(ws1.groups[0].members[0].front, true)
  assert.equal(ws1.groups[0].members[1].front, false)
  assert.equal(ws1.groups[0].members[1].groupSize, 2)
})

test("buildBoard marks the monitor's active workspace and leaves empties empty", () => {
  assert.equal(BOARD[0].workspaces[1].current, true)
  assert.equal(BOARD[0].workspaces[0].current, false)
  assert.equal(BOARD[0].workspaces[2].windows.length, 0)
  assert.equal(BOARD[0].workspaces[2].groups.length, 0)
})

test("normalizedRect maps window geometry into the monitor's logical frame", () => {
  const rect = BOARD[0].workspaces[0].windows[0].rect
  assert.ok(Math.abs(rect.x - 12 / 1440) < 1e-9)
  assert.ok(Math.abs(rect.y - 66 / 900) < 1e-9)
  assert.ok(Math.abs(rect.w - 1416 / 1440) < 1e-9)
  assert.ok(Math.abs(rect.h - 822 / 900) < 1e-9)
})

test("groupKey is member-order independent and blank for a lone window", () => {
  assert.equal(Model.groupKey(["0xB", "0xA"]), Model.groupKey(["0xA", "0xB"]))
  assert.equal(Model.groupKey(["0xC"]), "")
})

test("isBoardWindow rejects unmapped, hidden, and special-workspace clients", () => {
  assert.equal(Model.isBoardWindow(client({})), true)
  assert.equal(Model.isBoardWindow(client({ mapped: false })), false)
  assert.equal(Model.isBoardWindow(client({ hidden: true })), false)
  assert.equal(Model.isBoardWindow(client({ workspace: { id: -99, name: "special" } })), false)
})

test("initialSelection starts on the focused monitor's current workspace", () => {
  assert.deepEqual(Model.initialSelection(BOARD), { mon: 0, ws: 1, group: -1, member: -1 })
})

test("moveSelection wraps along the tile row", () => {
  const last = { mon: 0, ws: 5, group: -1, member: -1 }
  assert.equal(Model.moveSelection(BOARD, last, "right").ws, 0)
  assert.equal(Model.moveSelection(BOARD, { mon: 0, ws: 0, group: -1, member: -1 }, "left").ws, 5)
})

test("moveSelection enters a column at the front tab and returns to the tile", () => {
  const tile = { mon: 0, ws: 0, group: -1, member: -1 }
  const entered = Model.moveSelection(BOARD, tile, "down")
  assert.deepEqual(entered, { mon: 0, ws: 0, group: 0, member: 0 })
  assert.deepEqual(Model.moveSelection(BOARD, entered, "up"), tile)
})

test("moveSelection is a no-op on a groupless tile and at the last tab", () => {
  const groupless = { mon: 0, ws: 1, group: -1, member: -1 }
  assert.deepEqual(Model.moveSelection(BOARD, groupless, "down"), groupless)
  const lastTab = { mon: 0, ws: 0, group: 0, member: 1 }
  assert.deepEqual(Model.moveSelection(BOARD, lastTab, "down"), lastTab)
})

test("digitTarget picks tiles on the row and tabs inside a column", () => {
  const tile = { mon: 0, ws: 0, group: -1, member: -1 }
  assert.equal(Model.digitTarget(BOARD, tile, 9), null)
  assert.deepEqual(Model.digitTarget(BOARD, tile, 2), { kind: "workspace", id: 2 })
  const inColumn = { mon: 0, ws: 0, group: 0, member: 0 }
  assert.deepEqual(Model.digitTarget(BOARD, inColumn, 2), { kind: "window", address: "0xB" })
})

test("activationTarget resolves the tile or the selected tab", () => {
  assert.deepEqual(Model.activationTarget(BOARD, { mon: 0, ws: 3, group: -1, member: -1 }), { kind: "workspace", id: 4 })
  assert.deepEqual(Model.activationTarget(BOARD, { mon: 0, ws: 0, group: 0, member: 1 }), { kind: "window", address: "0xB" })
})

test("normalizeWorkspaceCount falls back and clamps to Hyprland's ten", () => {
  assert.equal(Model.normalizeWorkspaceCount("abc", 5), 5)
  assert.equal(Model.normalizeWorkspaceCount(0), 1)
  assert.equal(Model.normalizeWorkspaceCount(99), 10)
})


test("each monitor gets its assigned block, independent of monitor id or order", () => {
  const blocks = Model.parseWorkspaceBlocks("0\tDP-1\tSamsung\n1\tHDMI-A-2\tTCL\n")
  const monitors = [
    {...MONITOR, id: 7, name: "HDMI-A-2", activeWorkspace: {id: 11}},
    {...MONITOR, id: 3, name: "DP-1", activeWorkspace: {id: 1}}
  ]
  const board = Model.buildBoard(monitors, [client({monitor: 7, workspace: {id: 11}})], 5, blocks)
  assert.deepEqual(board[0].workspaces.map(w => w.id), [11,12,13,14,15])
  assert.deepEqual(board[1].workspaces.map(w => w.id), [1,2,3,4,5])
  assert.equal(board[0].workspaces[0].windows.length, 1)
  assert.equal(board[0].workspaces[0].current, true)
})

test("block state wins when an empty active workspace is outside its usual range", () => {
  const mon = {...MONITOR, name: "DP-1", activeWorkspace: {id: 21}}
  const board = Model.buildBoard([mon], [], 5, {"DP-1": 0})
  assert.deepEqual(board[0].workspaces.map(w => w.id), [1,2,3,4,5,21])
  assert.equal(board[0].workspaces[5].current, true)
})

test("missing state falls back to the active workspace block", () => {
  const mon = {...MONITOR, activeWorkspace: {id: 13}}
  const board = Model.buildBoard([mon], [], 5, {})
  assert.deepEqual(board[0].workspaces.map(w => w.id), [11,12,13,14,15])
})

test("block parser ignores malformed rows", () => {
  assert.deepEqual(Model.parseWorkspaceBlocks("bad\tDP-1\tfoo\n-1\tDP-2\tbar\n0\tDP-3\tvalid\n"), {"DP-3": 0})
})


test("occupied-only mode keeps each monitor but omits empty tiles", () => {
 const mons=[{...MONITOR,name:"DP-1",id:0,activeWorkspace:{id:1}},
 {...MONITOR,name:"HDMI-A-2",id:1,activeWorkspace:{id:11}}]
 const board=Model.buildBoard(mons,[client({monitor:1,workspace:{id:11}})],5,{"DP-1":0,"HDMI-A-2":1},true)
 assert.equal(board.length,2)
 assert.deepEqual(board[0].workspaces,[])
 assert.deepEqual(board[1].workspaces.map(w=>w.id),[11])
 assert.equal(Model.initialSelection(board).mon,1)
 assert.equal(Model.initialSelection(Model.buildBoard(mons,[],5,{},true)),null)
})


test("spatial areas retain groups and collect overlapping free windows", () => {
 const a={address:"a",groupKey:"a|b",front:true,rect:{x:0,y:0,w:.4,h:.4}}
 const b={...a,address:"b",front:false}
 const c={address:"c",groupKey:"",rect:{x:.5,y:.5,w:.3,h:.3}}
 const d={address:"d",groupKey:"",rect:{x:.6,y:.6,w:.3,h:.3}}
 const e={address:"e",groupKey:"",rect:{x:.1,y:.7,w:.2,h:.2}}
 const areas=Model.spatialAreas({groups:[{members:[a,b]}],windows:[a,b,c,d,e]})
 assert.equal(areas.length,3)
 assert.deepEqual(areas[0].rect,a.rect)
 assert.deepEqual(areas[0].members.map(w=>w.address),["a","b"])
 assert.deepEqual(areas[1].members.map(w=>w.address),["c","d"])
 assert.equal(areas[2].members[0].address,"e")
 assert.deepEqual(c.rect,{x:.5,y:.5,w:.3,h:.3})
})

test("thumbnail grids fit all members and screen sizing uses both dimensions", () => {
 for(const n of [1,2,3,4,9,17]) {
  const columns=Model.thumbnailColumns(n,600,400,16/9)
  assert.ok(columns>=1 && columns<=n)
  assert.ok(Math.ceil(n/columns)*columns>=n)
 }
 for(const n of [1,2,5]) {
  const w=Model.fitTileWidth(n,3760,1900,9/16,16)
  assert.ok(w*n+16*(n-1)<=3760)
  assert.ok(w*9/16<=1900)
  if(n===1) assert.ok(w>3000)
 }
})


test("arrow navigation crosses groups and free windows by thumbnail position", () => {
 const a={address:"a",x:0,y:0,group:0}, b={address:"b",x:100,y:0,group:1},
 c={address:"c",x:0,y:100,group:-1}, d={address:"d",x:100,y:100,group:0}
 const items=[a,b,c,d]
 assert.equal(Model.nextThumbnail(items,"a","right"),b)
 assert.equal(Model.nextThumbnail(items,"b","down"),d)
 assert.equal(Model.nextThumbnail(items,"d","left"),c)
 assert.equal(Model.nextThumbnail(items,"c","up"),a)
 assert.equal(Model.nextThumbnail(items,"a","left"),a)
 assert.equal(Model.nextThumbnail([],"a","up"),null)
})

test("surface recovery ignores normal fades and visible outputs, then backs off", () => {
 assert.equal(Model.retrySurface(0,500,0,0,0,2),false)
 assert.equal(Model.retrySurface(1,2000,0,0,0,4),false)
 assert.equal(Model.retrySurface(0,2000,0,0,0,1),false)
 assert.equal(Model.retrySurface(0,2000,0,0,0,2),true)
 assert.equal(Model.retrySurface(0,2500,0,2000,1,2),false)
 assert.equal(Model.retrySurface(0,3000,0,2000,1,2),true)
 assert.equal(Model.retrySurface(-1,9000,0,5000,3,2),true)
 assert.equal(Model.retrySurface(0,99999,0,5000,4,20),false)
})
