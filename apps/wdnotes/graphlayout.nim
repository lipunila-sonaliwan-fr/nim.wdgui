# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
#   _._
# o|- -|o  wdnotes - graph layout
#  ( l )   Fruchterman-Reingold force layout, deterministic (no random),
#    =     so the same project always produces the same picture.

import std/[math, tables, strutils]
import project, mdmodel

type
  GNode* = object
    id*, title*, color*, excerpt*: string
    x*, y*: float
    degree*, depth*: int
    main*: bool

  GEdge* = object
    a*, b*: int
    kind*: string                # "link" (wiki link) or "tree" (parent/child).

  Graph* = object
    nodes*: seq[GNode]
    edges*: seq[GEdge]

const Palette = ["#3b6ea5", "#c9a227", "#0f7b6c", "#7a2e2e", "#7b3fa0", "#e3740f", "#2d6cdf"]

proc buildGraph*(p: Project, withTree = true, iterations = 350): Graph =
  var index = initTable[string, int]()
  let order = p.preorder
  for id in order:
    if id == p.lexiconNote: continue
    let n = p.notes[id]
    index[id] = result.nodes.len
    let d = p.depth(id)
    var color = p.labelColor(id)
    if color.len == 0:
      # colour of the root branch.
      let root = p.chain(id)[0]
      color = Palette[max(0, p.roots.find(root)) mod Palette.len]
    result.nodes.add GNode(id: id, title: n.title, color: color, depth: d,
                           excerpt: excerpt(n.text, 220), main: id == p.mainNote)
  for (a, b) in p.links:
    if a in index and b in index:
      result.edges.add GEdge(a: index[a], b: index[b], kind: "link")
  if withTree:
    for id in order:
      let par = p.notes[id].parent
      if par.len > 0 and id in index and par in index:
        result.edges.add GEdge(a: index[par], b: index[id], kind: "tree")
  for e in result.edges:
    inc result.nodes[e.a].degree
    inc result.nodes[e.b].degree

  let n = result.nodes.len
  if n == 0: return
  # initial positions.
  let golden = PI * (3.0 - sqrt(5.0))
  for i in 0 ..< n:
    let r = 30.0 * sqrt(float(i) + 0.5)
    result.nodes[i].x = r * cos(float(i) * golden)
    result.nodes[i].y = r * sin(float(i) * golden)
  let area = 260_000.0 + 18_000.0 * float(n)
  let k = sqrt(area / float(n))
  var temp = sqrt(area) / 8
  var dx = newSeq[float](n)
  var dy = newSeq[float](n)
  for it in 0 ..< iterations:
    for i in 0 ..< n:
      dx[i] = 0; dy[i] = 0
    # repulsion
    for i in 0 ..< n:
      for j in i + 1 ..< n:
        var ddx = result.nodes[i].x - result.nodes[j].x
        var ddy = result.nodes[i].y - result.nodes[j].y
        var d2 = ddx * ddx + ddy * ddy
        if d2 < 0.01:
          ddx = 0.1 * float(i - j); ddy = 0.1; d2 = ddx * ddx + ddy * ddy
        let d = sqrt(d2)
        let f = k * k / d
        dx[i] += ddx / d * f; dy[i] += ddy / d * f
        dx[j] -= ddx / d * f; dy[j] -= ddy / d * f
    # attraction.
    for e in result.edges:
      let ddx = result.nodes[e.a].x - result.nodes[e.b].x
      let ddy = result.nodes[e.a].y - result.nodes[e.b].y
      let d = max(sqrt(ddx * ddx + ddy * ddy), 0.01)
      let w = if e.kind == "link": 1.0 else: 0.6
      let f = d * d / k * w
      dx[e.a] -= ddx / d * f; dy[e.a] -= ddy / d * f
      dx[e.b] += ddx / d * f; dy[e.b] += ddy / d * f
    # gravity towards the centre keeps islands close.
    for i in 0 ..< n:
      dx[i] -= result.nodes[i].x * 0.02 * k / 10
      dy[i] -= result.nodes[i].y * 0.02 * k / 10
    for i in 0 ..< n:
      let d = max(sqrt(dx[i] * dx[i] + dy[i] * dy[i]), 0.01)
      result.nodes[i].x += dx[i] / d * min(d, temp)
      result.nodes[i].y += dy[i] / d * min(d, temp)
    temp = max(temp * 0.985, 1.0)
  # centre on (0, 0)
  var cx, cy: float
  for nd in result.nodes:
    cx += nd.x; cy += nd.y
  cx /= float(n); cy /= float(n)
  for i in 0 ..< n:
    result.nodes[i].x -= cx
    result.nodes[i].y -= cy

proc encode*(g: Graph): string =
  # compact text form sent to the graph control:
  # N<TAB>id<TAB>title<TAB>color<TAB>x<TAB>y<TAB>degree<TAB>main<TAB>excerpt
  # E<TAB>a<TAB>b<TAB>kind
  proc clean(s: string): string =
    for ch in s:
      result.add(if ch in {'\t', '\n', '\r'}: ' ' else: ch)
  for nd in g.nodes:
    result.add "N\t" & clean(nd.id) & "\t" & clean(nd.title) & "\t" & nd.color & "\t" &
      formatFloat(nd.x, ffDecimal, 1) & "\t" & formatFloat(nd.y, ffDecimal, 1) & "\t" &
      $nd.degree & "\t" & (if nd.main: "1" else: "0") & "\t" & clean(nd.excerpt) & "\n"
  for e in g.edges:
    result.add "E\t" & $e.a & "\t" & $e.b & "\t" & e.kind & "\n"
