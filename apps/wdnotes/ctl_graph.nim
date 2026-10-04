# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
#   _._
# o|- -|o  wdnotes - GraphView, the links graph (custom control)
#  ( l )   points = notes (size by degree, colour by label or branch),
#    =     lines = [[wiki links]] (solid) and hierarchy (dashed).
#          Wheel: zoom around the pointer. Drag the background: pan.
#          Drag a point: move it. Click: select and show an excerpt.
#          Double-click: open the note.
#
# Commands: load <encoded graph>  fit  zoomin  zoomout  select <id>
#           tree 0|1  theme dark|light
# Events:   evSelection "sel:<id>" on click, "open:<id>" on double click.

import std/[strutils, tables, math, sequtils]
import wdcompat

const Sep = "\x1F"

type
  VNode = object
    id, title, color, excerpt: string
    x, y: float
    degree: int
    main: bool

  VEdge = object
    a, b: int
    tree: bool

  GraphView* = ref object of Control
    nodes: seq[VNode]
    edges: seq[VEdge]
    scale, offX, offY: float
    selected, hover, dragNode: int
    panning, moved, dark, showTree, needFit: bool
    lastX, lastY, lastClick: float
    lastClickNode: int
    colors: Table[string, Color]

proc newGraphView*(): GraphView =
  result = GraphView(scale: 1.0, selected: -1, hover: -1, dragNode: -1, showTree: true,
                     lastClickNode: -1)
  initControl(result, "")
  result.colors = initTable[string, Color]()

proc cc(g: GraphView, s: string): Color =
  let k = if s.len == 0: "#3b6ea5" else: s
  if k notin g.colors: g.colors[k] = col(k)
  g.colors[k]

proc radius(n: VNode): float = 5.0 + sqrt(float(n.degree)) * 2.6 + (if n.main: 3 else: 0)

proc toScreen(g: GraphView, x, y: float): (float, float) =
  let r = g.rect
  (r.x + r.w / 2 + (x + g.offX) * g.scale, r.y + r.h / 2 + (y + g.offY) * g.scale)

proc toWorld(g: GraphView, sx, sy: float): (float, float) =
  let r = g.rect
  ((sx - r.x - r.w / 2) / g.scale - g.offX, (sy - r.y - r.h / 2) / g.scale - g.offY)

proc fit(g: GraphView) =
  if g.nodes.len == 0: return
  var minX, minY = 1e9
  var maxX, maxY = -1e9
  for n in g.nodes:
    minX = min(minX, n.x); maxX = max(maxX, n.x)
    minY = min(minY, n.y); maxY = max(maxY, n.y)
  let r = g.rect
  let w = max(maxX - minX, 1.0)
  let h = max(maxY - minY, 1.0)
  g.scale = clamp(min((r.w - 120) / w, (r.h - 120) / h), 0.15, 2.5)
  g.offX = -(minX + maxX) / 2
  g.offY = -(minY + maxY) / 2

proc nodeAt(g: GraphView, sx, sy: float): int =
  result = -1
  var best = 1e9
  for i, n in g.nodes:
    let (x, y) = g.toScreen(n.x, n.y)
    let d = sqrt((x - sx) * (x - sx) + (y - sy) * (y - sy))
    let rr = max(radius(n) * max(g.scale, 0.6), 7.0) + 3
    if d <= rr and d < best:
      best = d
      result = i

method typeName*(g: GraphView): string = "GraphView"

method preferredSize*(g: GraphView, d: Drawing, t: Theme): tuple[w, h: float] = (420.0, 320.0)

proc wrapText(d: Drawing, s: string, maxW: float, maxLines: int): seq[string] =
  var line = ""
  for w in s.splitWhitespace:
    let cand = if line.len == 0: w else: line & " " & w
    if d.gfxTextW(cand) > maxW and line.len > 0:
      result.add line
      line = w
      if result.len == maxLines: break
    else: line = cand
  if result.len < maxLines and line.len > 0: result.add line
  if result.len == maxLines and result.len > 0: result[^1] = d.truncate(result[^1] & " …", maxW)

method draw*(g: GraphView, d: Drawing, t: Theme) =
  let r = g.rect
  if g.needFit and r.w > 10:
    g.fit()
    g.needFit = false
  let bg = if g.dark: col("#15171b") else: col("#f7f6f2")
  let dot = if g.dark: col("#23262b") else: col("#e4e1d8")
  let ink = if g.dark: col("#d7dbe0") else: col("#2b2f36")
  let muted = if g.dark: col("#7d838d") else: col("#8a8f98")
  d.gfxFill(r.x, r.y, r.w, r.h, bg)
  d.gfxClip(r.x, r.y, r.w, r.h)
  # dotted grid following pan/zoom.
  let step = 32.0 * g.scale
  if step > 9:
    let (ox, oy) = g.toScreen(0, 0)
    var gx = r.x + floorMod(ox - r.x, step)
    while gx < r.x + r.w:
      var gy = r.y + floorMod(oy - r.y, step)
      while gy < r.y + r.h:
        d.gfxFill(gx, gy, 1.5, 1.5, dot)
        gy += step
      gx += step
  if g.nodes.len == 0:
    d.gfxFontReset(t)
    d.gfxText(r.x + 24, r.y + 24, 24, "Aucune note : créez des notes et reliez-les avec [[Titre]].",
              muted)
    d.gfxUnclip()
    return
  # edges
  let focus = if g.hover >= 0: g.hover else: g.selected
  for e in g.edges:
    if e.tree and not g.showTree: continue
    let (x1, y1) = g.toScreen(g.nodes[e.a].x, g.nodes[e.a].y)
    let (x2, y2) = g.toScreen(g.nodes[e.b].x, g.nodes[e.b].y)
    let lit = focus >= 0 and (e.a == focus or e.b == focus)
    if e.tree:
      d.gfxDashed(x1, y1, x2, y2, if lit: colA("#c9a227", 230) else: colA("#9aa0aa", 120), 4)
    else:
      let c = if lit: col("#c9a227") else: colA(if g.dark: "#8fb3e0" else: "#3b6ea5", 150)
      d.gfxLine(x1, y1, x2, y2, c)
      if lit:
        d.gfxLine(x1 + 0.8, y1 + 0.8, x2 + 0.8, y2 + 0.8, c)
      # arrow head: small dot near the target
      let dd = max(sqrt((x2 - x1) * (x2 - x1) + (y2 - y1) * (y2 - y1)), 1.0)
      let rb = radius(g.nodes[e.b]) * max(g.scale, 0.6) + 4
      d.gfxCircle(x2 - (x2 - x1) / dd * rb, y2 - (y2 - y1) / dd * rb, 2.5, c)
  # nodes
  d.gfxFontReset(t)
  let showAll = g.scale >= 0.55 or g.nodes.len <= 25
  for i, n in g.nodes:
    let (x, y) = g.toScreen(n.x, n.y)
    if x < r.x - 40 or x > r.x + r.w + 40 or y < r.y - 40 or y > r.y + r.h + 40: continue
    let rad = max(radius(n) * max(g.scale, 0.6), 4.0)
    let neighbour = focus >= 0 and i != focus and g.edges.anyIt(
      (it.a == focus and it.b == i) or (it.b == focus and it.a == i))
    let dim = focus >= 0 and i != focus and not neighbour
    if i == g.selected:
      d.gfxCircle(x, y, rad + 7, colA("#c9a227", 70))
    if n.main:
      d.gfxCircle(x, y, rad + 3, col("#c9a227"))
    d.gfxCircle(x, y, rad + 1.5, bg)
    d.gfxCircle(x, y, rad, if dim: colA(n.color, 90) else: g.cc(n.color))
    if showAll or i == focus or neighbour or n.main:
      let label = d.truncate(n.title, 180)
      d.gfxText(x + rad + 6, y - 9, 18, label, if dim: muted else: ink)
  # excerpt bubble of the selected note.
  if g.selected >= 0 and g.selected < g.nodes.len:
    let n = g.nodes[g.selected]
    let (x, y) = g.toScreen(n.x, n.y)
    let bw = min(320.0, r.w - 40)
    let lines = wrapText(d, n.excerpt, bw - 28, 6)
    let bh = 54.0 + float(lines.len) * 18
    var bx = x + 18
    var by = y + 16
    if bx + bw > r.x + r.w - 10: bx = x - bw - 18
    if by + bh > r.y + r.h - 10: by = y - bh - 16
    bx = max(bx, r.x + 10)
    by = max(by, r.y + 10)
    d.gfxShadow(bx, by, bw, bh, 10)
    d.gfxRound(bx, by, bw, bh, 10, if g.dark: col("#23262c") else: col("#ffffff"))
    d.gfxRound(bx, by, 4, bh, 2, g.cc(n.color))
    d.gfxFont("Sans", float(t.fontSize) + 1, true, false)
    d.gfxText(bx + 16, by + 8, 22, d.truncate(n.title, bw - 30), ink)
    d.gfxFontReset(t)
    var ly = by + 32
    for l in lines:
      d.gfxText(bx + 16, ly, 18, l, muted)
      ly += 18
    d.gfxText(bx + 16, by + bh - 22, 18, "Double-clic : ouvrir · boutons à droite", colA("#c9a227", 230))
  # legend.
  d.gfxText(r.x + 12, r.y + r.h - 26, 18,
            $g.nodes.len & " notes · " & $g.edges.len & " liens · zoom " &
            $int(g.scale * 100) & " %", muted)
  d.gfxUnclip()

method onWheel*(g: GraphView, dx, dy: float): bool =
  let (wx, wy) = g.toWorld(g.lastX, g.lastY)
  let factor = pow(1.12, float(dy))
  g.scale = clamp(g.scale * factor, 0.1, 5.0)
  # keep the point under the pointer still.
  let (nx, ny) = g.toWorld(g.lastX, g.lastY)
  g.offX += nx - wx
  g.offY += ny - wy
  true

method onMouse*(g: GraphView, e: MouseEvent) =
  let x = mouseX(e)
  let y = mouseY(e)
  if e.action == maPress and e.button == mbLeft:
    g.dragNode = g.nodeAt(x, y)
    g.panning = g.dragNode < 0
    g.moved = false
  elif e.action == maMove:
    let dx = x - g.lastX
    let dy = y - g.lastY
    if g.dragNode >= 0:
      g.nodes[g.dragNode].x += dx / g.scale
      g.nodes[g.dragNode].y += dy / g.scale
      if abs(dx) + abs(dy) > 0: g.moved = true
    elif g.panning:
      g.offX += dx / g.scale
      g.offY += dy / g.scale
      if abs(dx) + abs(dy) > 0: g.moved = true
    else:
      g.hover = g.nodeAt(x, y)
  elif e.action == maRelease and e.button == mbLeft:
    if not g.moved:
      let n = g.nodeAt(x, y)
      let tnow = nowSec()
      if n >= 0 and n == g.lastClickNode and tnow - g.lastClick < 0.4:
        emit(g, evSelection, text = "open:" & g.nodes[n].id)
      elif n >= 0:
        g.selected = n
        emit(g, evSelection, text = "sel:" & g.nodes[n].id)
      else:
        g.selected = -1
      g.lastClickNode = n
      g.lastClick = tnow
    g.dragNode = -1
    g.panning = false
  g.lastX = x
  g.lastY = y

method valueText*(g: GraphView): string =
  if g.selected >= 0: g.nodes[g.selected].id else: ""

method setValueText*(g: GraphView, s: string) =
  let k = s.find(Sep)
  let cmd = if k >= 0: s[0 ..< k] else: s
  let arg = if k >= 0: s[k + 1 .. ^1] else: ""
  case cmd
  of "load":
    let prevSel = if g.selected >= 0 and g.selected < g.nodes.len: g.nodes[g.selected].id else: ""
    g.nodes.setLen(0)
    g.edges.setLen(0)
    g.selected = -1
    g.hover = -1
    for line in arg.splitLines:
      let f = line.split('\t')
      if f.len >= 9 and f[0] == "N":
        var n = VNode(id: f[1], title: f[2], color: f[3], main: f[7] == "1", excerpt: f[8])
        try:
          n.x = parseFloat(f[4]); n.y = parseFloat(f[5]); n.degree = parseInt(f[6])
        except ValueError: discard
        if n.id == prevSel: g.selected = g.nodes.len
        g.nodes.add n
      elif f.len >= 4 and f[0] == "E":
        try:
          g.edges.add VEdge(a: parseInt(f[1]), b: parseInt(f[2]), tree: f[3] == "tree")
        except ValueError: discard
    g.needFit = true
  of "fit": g.needFit = true
  of "zoomin": g.scale = min(5.0, g.scale * 1.2)
  of "zoomout": g.scale = max(0.1, g.scale / 1.2)
  of "tree": g.showTree = arg == "1"
  of "theme": g.dark = arg == "dark"
  of "select":
    g.selected = -1
    for i, n in g.nodes:
      if n.id == arg:
        g.selected = i
        g.offX = -n.x
        g.offY = -n.y
  else: discard
