# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
#
# canvas.nim - Graphical constraint editor (Node-RED style)
#
# Custom wdgui control (step 9 of the tutorial). It lives on the UI thread:
# drawing and mouse. The graph is in gApp (model.nim), protected by gLock.
##
# Mouse:
#   * drag an output (right side) onto an input (left side): link;
#   * drag from a linked input: detaches and picks the link up again;
#   * click / drag a node: selection / move (Shift: add to selection);
#   * click a link: link selection;
#   * drag the background: pan the view; Shift + drag: selection
#     rectangle; wheel: zoom;
#   * component "armed" from the library: click = place it.
# Changes are reported to the window through evChange:
#   ev.text = "graph" (structure modified) or "select" (selection).

import std/[strutils, tables, times, math]
import ../../src/wdgui
import model, gfx

type
  DragKind = enum dkNone, dkNodes, dkWire, dkPan, dkRubber

  GraphCanvas* = ref object of Control
    drag: DragKind
    downX, downY: float             # screen position when pressed
    lastX, lastY: float             # last mouse position
    wireNode, wirePort, wireTyp: string
    moved: bool
    hoverNode, hoverPort: string
    hoverOut: bool
    flash: string
    flashUntil: float
    stamp: string

  Palette* = object
    bg*, grid*, gridMajor*, body*, bodyBorder*, text*, textDim*, textFaint*,
      accent*, shadow*, badgeBg*, badgeText*, error*, legendBg*: string

var gDark* = true

proc palette*(): Palette =
  var dark = true
  {.cast(gcsafe).}:
    dark = gDark
  if dark:
    Palette(bg: "#171A20", grid: "#1F232B", gridMajor: "#262B35",
            body: "#242832", bodyBorder: "#343A47", text: "#F2F4F8",
            textDim: "#AEB6C4", textFaint: "#6E7787", accent: "#8B6CFF",
            shadow: "#00000070", badgeBg: "#1D3A2E", badgeText: "#7BE0A6",
            error: "#FF6B6B", legendBg: "#1E2229E6")
  else:
    Palette(bg: "#F4F5F9", grid: "#E6E8EF", gridMajor: "#D9DCE6",
            body: "#FFFFFF", bodyBorder: "#D5D9E3", text: "#1C2030",
            textDim: "#555D70", textFaint: "#8A91A3", accent: "#6A4CF0",
            shadow: "#1C203022", badgeBg: "#E3F6EC", badgeText: "#1E8A4F",
            error: "#D63B3B", legendBg: "#FFFFFFE6")

proc newGraphCanvas*(): GraphCanvas =
  result = GraphCanvas()
  initControl(result, "")
  result.stretch = true
  when compiles(result.focusable = true):
    result.focusable = true

method typeName*(c: GraphCanvas): string = "wdreka Graph"

method preferredSize*(c: GraphCanvas, d: Drawing, t: Theme): tuple[w, h: float] =
  (600.0, 400.0)

method valueText*(c: GraphCanvas): string = c.stamp
method setValueText*(c: GraphCanvas, s: string) =
  # used by other threads to request a repaint
  c.stamp = s

#
# Screen <-> world transforms (call while holding gLock)
#

proc toScreen(c: GraphCanvas, wx, wy: float): (float, float) =
  let (rx, ry, _, _) = ctlRect(c)
  (rx + gApp.panX + wx * gApp.zoom, ry + gApp.panY + wy * gApp.zoom)

proc toWorld(c: GraphCanvas, sx, sy: float): (float, float) =
  let (rx, ry, _, _) = ctlRect(c)
  ((sx - rx - gApp.panX) / gApp.zoom, (sy - ry - gApp.panY) / gApp.zoom)

proc compOf(n: Node): ComponentDef =
  if gApp.lib.comps.hasKey(n.comp): gApp.lib.comps[n.comp] else: nil

#
# Hit testing (world coordinates, while holding gLock)
#

proc nodeAt(wx, wy: float): Node =
  for i in countdown(gApp.doc.nodes.high, 0):
    let n = gApp.doc.nodes[i]
    if wx >= n.x and wx <= n.x + nodeW and wy >= n.y and
       wy <= n.y + nodeHeight(n, gApp.lib):
      return n
  result = nil

proc portAt(wx, wy: float): (Node, string, bool) =
  # (node, port, isOutput) under the point, or (nil, "", false)
  let tol = 10.0 / gApp.zoom
  for i in countdown(gApp.doc.nodes.high, 0):
    let n = gApp.doc.nodes[i]
    let cd = compOf(n)
    if cd == nil: continue
    for k, p in cd.inputs:
      let (px, py) = inPortPos(n, k)
      if abs(wx - px) <= tol and abs(wy - py) <= tol:
        return (n, p.name, false)
    for k, p in cd.outputs:
      let (px, py) = outPortPos(n, k)
      if abs(wx - px) <= tol and abs(wy - py) <= tol:
        return (n, p.name, true)
  result = (nil, "", false)

proc portIndex(n: Node, port: string, output: bool): int =
  let cd = compOf(n)
  if cd == nil: return 0
  let ports = (if output: cd.outputs else: cd.inputs)
  for k, p in ports:
    if p.name == port: return k
  result = 0

proc linkPoints(l: Link): seq[(float, float)] =
  let a = gApp.doc.findNode(l.src)
  let b = gApp.doc.findNode(l.dst)
  if a == nil or b == nil: return @[]
  let (x1, y1) = outPortPos(a, portIndex(a, l.srcPort, true))
  let (x2, y2) = inPortPos(b, portIndex(b, l.dstPort, false))
  result = bezierPoints(x1, y1, x2, y2)

proc linkAt(wx, wy: float): int =
  let tol = 6.0 / gApp.zoom
  var best = tol
  result = -1
  for i, l in gApp.doc.links:
    let pts = linkPoints(l)
    for k in 1 ..< pts.len:
      let dd = distToSegment(wx, wy, pts[k-1][0], pts[k-1][1], pts[k][0], pts[k][1])
      if dd < best:
        best = dd
        result = i

#
# Drawing
#

proc drawGrid(c: GraphCanvas, d: Drawing, pal: Palette) =
  let (rx, ry, rw, rh) = ctlRect(c)
  d.gFillRect(rx, ry, rw, rh, pal.bg)
  let stepW = 32.0
  let step = stepW * gApp.zoom
  if step < 6: return
  let (wx0, wy0) = c.toWorld(rx, ry)
  var i = int(floor(wx0 / stepW))
  while true:
    let (sx, _) = c.toScreen(float(i) * stepW, 0)
    if sx > rx + rw: break
    if sx >= rx:
      d.gLine(sx, ry, sx, ry + rh, (if i mod 5 == 0: pal.gridMajor else: pal.grid))
    inc i
  var j = int(floor(wy0 / stepW))
  while true:
    let (_, sy) = c.toScreen(0, float(j) * stepW)
    if sy > ry + rh: break
    if sy >= ry:
      d.gLine(rx, sy, rx + rw, sy, (if j mod 5 == 0: pal.gridMajor else: pal.grid))
    inc j

proc drawLinks(c: GraphCanvas, d: Drawing, pal: Palette) =
  for i, l in gApp.doc.links:
    let pts = linkPoints(l)
    if pts.len == 0: continue
    var sp: seq[(float, float)] = @[]
    for p in pts: sp.add c.toScreen(p[0], p[1])
    let a = gApp.doc.findNode(l.src)
    let typ = gApp.lib.portDef(a, l.srcPort, true).typ
    let colr = portColor(typ)
    let selected = i == gApp.selectedLink
    if selected:
      d.gPolyline(sp, alpha(pal.accent, 0.45), 6.0 * gApp.zoom)
    d.gPolyline(sp, (if selected: lighten(colr, 0.35) else: alpha(colr, 0.9)),
                max(1.5, 2.4 * gApp.zoom))
    # arrow head
    let (ex, ey) = sp[^1]
    let s = 6.0 * gApp.zoom
    d.gTriangle(ex - s - 5 * gApp.zoom, ey - s * 0.7, ex - s - 5 * gApp.zoom, ey + s * 0.7,
                ex - 5 * gApp.zoom, ey, colr)

proc drawNode(c: GraphCanvas, d: Drawing, pal: Palette, n: Node) =
  let z = gApp.zoom
  let cd = compOf(n)
  let (X, Y) = c.toScreen(n.x, n.y)
  let W = nodeW * z
  let H = nodeHeight(n, gApp.lib) * z
  let rad = 10.0 * z
  let color = (if cd == nil: "#828282" else: cd.color)
  let selected = n.id in gApp.selected
  let small = z < 0.6
  # shadow and glow
  d.gFillRound(X + 3 * z, Y + 6 * z, W, H, rad, pal.shadow)
  if selected:
    d.gFillRound(X - 4 * z, Y - 4 * z, W + 8 * z, H + 8 * z, rad + 4 * z, alpha(pal.accent, 0.30))
  # body
  d.gFillRound(X, Y, W, H, rad, pal.body)
  d.gStrokeRound(X, Y, W, H, rad, (if n.error.len > 0: pal.error
                                  elif selected: pal.accent else: pal.bodyBorder),
                 (if selected or n.error.len > 0: 2.0 else: 1.0))
  # colored header
  let hh = headerH * z
  d.gFillRound(X, Y, W, hh, rad, color)
  d.gFillRect(X, Y + hh - rad, W, rad, color)
  d.gFillRect(X, Y, W, hh / 2, "#FFFFFF14")
  # badge (glyph)
  let gx = X + 16 * z
  let gy = Y + hh / 2
  d.gCircle(gx, gy, 10 * z, "#00000033")
  if not small:
    d.gTextCenter(gx, gy, (if cd == nil: "?" else: cd.glyph), "#FFFFFF")
    let title = d.gEllipsize(n.nodeLabel(gApp.lib), W - 64 * z)
    d.gText(X + 32 * z, gy - d.gTextH() / 2 - 1, title, "#FFFFFF")
    d.gTextRight(X + W - 8 * z, gy - d.gTextH() / 2 - 1, n.id, "#FFFFFFAA")
    if n.customCode.len > 0:
      d.gFillRound(X + W - 70 * z, gy - 8 * z, 30 * z, 16 * z, 8 * z, "#00000055")
      d.gTextCenter(X + W - 55 * z, gy, "</>", "#FFD166")
  if cd == nil:
    if not small:
      d.gText(X + 10 * z, Y + hh + 8 * z, "unknown component: " & n.comp, pal.error)
    return
  # ports
  for k, p in cd.inputs:
    let (wx, wy) = inPortPos(n, k)
    let (px, py) = c.toScreen(wx, wy)
    let pc = portColor(p.typ)
    let hov = c.hoverNode == n.id and c.hoverPort == p.name and not c.hoverOut
    let connected = gApp.doc.linksInto(n.id, p.name).len > 0
    d.gCircle(px, py, (if hov: 8.0 else: 6.0) * z, pc)
    if not connected:
      d.gCircle(px, py, 3.0 * z, pal.body)
    if p.multi:
      d.gRing(px, py, 9.0 * z, alpha(pc, 0.7))
    if not small:
      d.gText(px + 11 * z, py - d.gTextH() / 2 - 1, d.gEllipsize(p.label, W / 2 - 16 * z), pal.textDim)
  for k, p in cd.outputs:
    let (wx, wy) = outPortPos(n, k)
    let (px, py) = c.toScreen(wx, wy)
    let pc = portColor(p.typ)
    let hov = c.hoverNode == n.id and c.hoverPort == p.name and c.hoverOut
    d.gCircle(px, py, (if hov: 8.0 else: 6.0) * z, pc)
    if not small:
      d.gTextRight(px - 10 * z, py - d.gTextH() / 2 - 1, d.gEllipsize(p.label, W / 2 - 16 * z), pal.textDim)
  # parameter summary
  if not small:
    let rows = max(1, max(cd.inputs.len, cd.outputs.len))
    var py = Y + (headerH + 8 + float(rows) * portRowH + 2) * z
    var shown = 0
    for p in cd.params:
      if p.kind == "code": continue
      if shown >= maxParamLines: break
      let v = n.params.getOrDefault(p.name, p.default).replace("\n", " ")
      let line = d.gEllipsize(p.label & " : " & v, W - 20 * z)
      d.gText(X + 10 * z, py, line, pal.textFaint)
      py += paramLineH * z
      inc shown
    # result badge
    if n.status.len > 0:
      let bw = min(W - 16 * z, d.gTextW(n.status) + 18)
      let by = Y + H - 26 * z
      d.gFillRound(X + 8 * z, by, bw, 20 * z, 10 * z, pal.badgeBg)
      d.gText(X + 8 * z + 9, by + 10 * z - d.gTextH() / 2 - 1,
              d.gEllipsize(n.status, bw - 14), pal.badgeText)
  # error message below the node
  if n.error.len > 0 and not small:
    let msg = d.gEllipsize(n.error, 420)
    let ew = d.gTextW(msg) + 20
    d.gFillRound(X, Y + H + 6 * z, ew, 24, 8, alpha(pal.error, 0.18))
    d.gText(X + 10, Y + H + 6 * z + 12 - d.gTextH() / 2 - 1, msg, pal.error)

proc drawOverlays(c: GraphCanvas, d: Drawing, pal: Palette) =
  let (rx, ry, rw, rh) = ctlRect(c)
  # title and zoom
  let head = gApp.doc.title & (if gApp.doc.modified: "  •" else: "")
  d.gFillRound(rx + 12, ry + 12, d.gTextW(head) + d.gTextW("100 %") + 44, 30, 15, pal.legendBg)
  d.gText(rx + 26, ry + 27 - d.gTextH() / 2 - 1, head, pal.text)
  d.gText(rx + 34 + d.gTextW(head), ry + 27 - d.gTextH() / 2 - 1,
          $int(round(gApp.zoom * 100)) & " %", pal.textFaint)
  # port type legend
  var lx = rx + 12
  let ly = ry + rh - 34
  var total = 0.0
  for t in portTypes:
    if t == "any": continue
    total += d.gTextW(portTypeLabel(t)) + 30
  d.gFillRound(lx, ly, total + 10, 24, 12, pal.legendBg)
  lx += 12
  for t in portTypes:
    if t == "any": continue
    d.gCircle(lx + 5, ly + 12, 5, portColor(t))
    d.gText(lx + 14, ly + 12 - d.gTextH() / 2 - 1, portTypeLabel(t), pal.textDim)
    lx += d.gTextW(portTypeLabel(t)) + 30
  # armed component
  if gApp.armed.len > 0 and gApp.lib.comps.hasKey(gApp.armed):
    let cd = gApp.lib.comps[gApp.armed]
    let msg = "Click on the canvas to place \"" & cd.label & "\"  -  Esc: cancel"
    let w = d.gTextW(msg) + 40
    d.gFillRound(rx + (rw - w) / 2, ry + 14, w, 32, 16, alpha(cd.color, 0.92))
    d.gTextCenter(rx + rw / 2, ry + 30, msg, "#FFFFFF")
  # transient message
  if c.flash.len > 0 and epochTime() < c.flashUntil:
    let w = d.gTextW(c.flash) + 40
    d.gFillRound(rx + (rw - w) / 2, ry + rh - 80, w, 34, 17, alpha(pal.error, 0.92))
    d.gTextCenter(rx + rw / 2, ry + rh - 63, c.flash, "#FFFFFF")
  # empty document
  if gApp.doc.nodes.len == 0:
    let l1 = "Build your constraint model"
    let l2 = "Pick a component in the library (click it, then click here - or double-click it),"
    let l3 = "then link the outputs (right side) to the inputs (left side)."
    d.gTextCenter(rx + rw / 2, ry + rh / 2 - 28, l1, pal.text)
    d.gTextCenter(rx + rw / 2, ry + rh / 2, l2, pal.textFaint)
    d.gTextCenter(rx + rw / 2, ry + rh / 2 + 22, l3, pal.textFaint)

method draw*(c: GraphCanvas, d: Drawing, t: Theme) =
  let pal = palette()
  let (rx, ry, rw, rh) = ctlRect(c)
  d.gPushClip(rx, ry, rw, rh)
  withApp:
    c.drawGrid(d, pal)
    c.drawLinks(d, pal)
    for n in gApp.doc.nodes:
      c.drawNode(d, pal, n)
    # wire being drawn
    if c.drag == dkWire:
      let n = gApp.doc.findNode(c.wireNode)
      if n != nil:
        let (wx, wy) = outPortPos(n, portIndex(n, c.wirePort, true))
        let (sx, sy) = c.toScreen(wx, wy)
        var pts: seq[(float, float)] = @[]
        for p in bezierPoints(sx, sy, c.lastX, c.lastY, 20): pts.add p
        d.gPolyline(pts, portColor(c.wireTyp), 2.5)
        d.gCircle(c.lastX, c.lastY, 5, portColor(c.wireTyp))
    # selection rectangle
    if c.drag == dkRubber:
      let x = min(c.downX, c.lastX)
      let y = min(c.downY, c.lastY)
      let w = abs(c.lastX - c.downX)
      let h = abs(c.lastY - c.downY)
      d.gFillRect(x, y, w, h, alpha(pal.accent, 0.12))
      d.gStrokeRound(x, y, w, h, 0, alpha(pal.accent, 0.8))
    c.drawOverlays(d, pal)
  d.gPopClip()

#
# Mouse
#

template mousePos(e: untyped): (float, float) =
  when compiles(e.x):
    (float(e.x), float(e.y))
  elif compiles(e.pos.x):
    (float(e.pos.x), float(e.pos.y))
  else:
    {.error: "canvas.mousePos: adapt the access to the MouseEvent position".}

template shiftDown(e: untyped): bool =
  when compiles(e.modifiers):
    (int(e.modifiers) and 0x0003) != 0          # SDL_KMOD_LSHIFT | RSHIFT
  elif compiles(e.shift):
    e.shift
  else:
    false

proc setFlash(c: GraphCanvas, msg: string) =
  c.flash = msg
  c.flashUntil = epochTime() + 3.0

proc snap(v: float): float = round(v / 8.0) * 8.0

method onMouse*(c: GraphCanvas, e: MouseEvent) =
  let (mx, my) = mousePos(e)
  var notify = ""
  withApp:
    let (wx, wy) = c.toWorld(mx, my)
    if e.action == maPress:
      c.downX = mx
      c.downY = my
      c.lastX = mx
      c.lastY = my
      c.moved = false
      if e.button != mbLeft:
        c.drag = dkNone
        # right click: selects the target (context menu comes next)
        let n = nodeAt(wx, wy)
        if n != nil:
          if n.id notin gApp.selected:
            gApp.selected = @[n.id]
            gApp.selectedLink = -1
            notify = "select"
        else:
          let li = linkAt(wx, wy)
          if li >= 0:
            gApp.selectedLink = li
            gApp.selected = @[]
            notify = "select"
      else:
        let (pn, pport, pout) = portAt(wx, wy)
        if pn != nil and pout:
          c.drag = dkWire
          c.wireNode = pn.id
          c.wirePort = pport
          c.wireTyp = gApp.lib.portDef(pn, pport, true).typ
        elif pn != nil and not pout and gApp.doc.linksInto(pn.id, pport).len > 0:
          # pick up an existing link from its input
          let l = gApp.doc.linksInto(pn.id, pport)[^1]
          var kl: seq[Link] = @[]
          for x in gApp.doc.links:
            if x != l: kl.add x
          gApp.doc.links = kl
          gApp.doc.graphDirty = true
          gApp.doc.modified = true
          c.drag = dkWire
          c.wireNode = l.src
          c.wirePort = l.srcPort
          let src = gApp.doc.findNode(l.src)
          c.wireTyp = gApp.lib.portDef(src, l.srcPort, true).typ
          notify = "graph"
        else:
          let n = nodeAt(wx, wy)
          if n != nil:
            if shiftDown(e):
              if n.id in gApp.selected:
                gApp.selected.delete(gApp.selected.find(n.id))
              else:
                gApp.selected.add n.id
            elif n.id notin gApp.selected:
              gApp.selected = @[n.id]
            gApp.selectedLink = -1
            # bring to front
            let idx = gApp.doc.nodes.find(n)
            if idx >= 0:
              gApp.doc.nodes.delete(idx)
              gApp.doc.nodes.add n
            c.drag = dkNodes
            notify = "select"
          else:
            let li = linkAt(wx, wy)
            if li >= 0:
              gApp.selectedLink = li
              gApp.selected = @[]
              c.drag = dkNone
              notify = "select"
            elif gApp.armed.len > 0:
              let n2 = gApp.doc.addNode(gApp.lib, gApp.armed, snap(wx - nodeW / 2), snap(wy - 15))
              gApp.selected = @[n2.id]
              gApp.selectedLink = -1
              gApp.armed = ""
              c.drag = dkNone
              notify = "graph"
            elif shiftDown(e):
              c.drag = dkRubber
            else:
              c.drag = dkPan
              if gApp.selected.len > 0 or gApp.selectedLink >= 0:
                gApp.selected = @[]
                gApp.selectedLink = -1
                notify = "select"
    elif e.action == maMove:
      let dx = mx - c.lastX
      let dy = my - c.lastY
      if abs(mx - c.downX) + abs(my - c.downY) > 3: c.moved = true
      case c.drag
      of dkNodes:
        for id in gApp.selected:
          let n = gApp.doc.findNode(id)
          if n != nil:
            n.x += dx / gApp.zoom
            n.y += dy / gApp.zoom
      of dkPan:
        gApp.panX += dx
        gApp.panY += dy
      else:
        discard
      # port hover
      let (pn, pport, pout) = portAt(wx, wy)
      if pn != nil:
        c.hoverNode = pn.id
        c.hoverPort = pport
        c.hoverOut = pout
      else:
        c.hoverNode = ""
        c.hoverPort = ""
      c.lastX = mx
      c.lastY = my
    elif e.action == maRelease:
      case c.drag
      of dkWire:
        let (pn, pport, pout) = portAt(wx, wy)
        if pn != nil and not pout:
          let err = gApp.doc.addLink(gApp.lib, Link(src: c.wireNode, srcPort: c.wirePort,
                                                    dst: pn.id, dstPort: pport))
          if err.len > 0:
            c.setFlash(err)
            addLog("Link refused: " & err)
          notify = "graph"
      of dkNodes:
        if c.moved:
          for id in gApp.selected:
            let n = gApp.doc.findNode(id)
            if n != nil:
              n.x = snap(n.x)
              n.y = snap(n.y)
          gApp.doc.modified = true
          notify = "graph"
      of dkRubber:
        let (ax, ay) = c.toWorld(min(c.downX, mx), min(c.downY, my))
        let (bx, by) = c.toWorld(max(c.downX, mx), max(c.downY, my))
        var sel: seq[string] = @[]
        for n in gApp.doc.nodes:
          if n.x >= ax and n.x + nodeW <= bx and n.y >= ay and
             n.y + nodeHeight(n, gApp.lib) <= by:
            sel.add n.id
        gApp.selected = sel
        gApp.selectedLink = -1
        notify = "select"
      else:
        discard
      c.drag = dkNone
  if notify.len > 0:
    emit(c, evChange, text = notify)

proc zoomAt*(c: GraphCanvas, sx, sy, factor: float) =
  # zoom centered on a screen point (while holding gLock)
  let (wx, wy) = c.toWorld(sx, sy)
  gApp.zoom = max(0.3, min(2.5, gApp.zoom * factor))
  let (rx, ry, _, _) = ctlRect(c)
  gApp.panX = sx - rx - wx * gApp.zoom
  gApp.panY = sy - ry - wy * gApp.zoom

method onWheel*(c: GraphCanvas, dx, dy: float): bool =
  withApp:
    c.zoomAt(c.lastX, c.lastY, (if dy > 0: 1.1 else: 1.0 / 1.1))
  result = true

proc fitView*(c: GraphCanvas) =
  # frames all the nodes (while holding gLock)
  let (_, _, rw, rh) = ctlRect(c)
  if gApp.doc.nodes.len == 0 or rw < 50 or rh < 50:
    gApp.zoom = 1.0
    gApp.panX = 40
    gApp.panY = 60
    return
  var x0 = 1e9
  var y0 = 1e9
  var x1 = -1e9
  var y1 = -1e9
  for n in gApp.doc.nodes:
    x0 = min(x0, n.x)
    y0 = min(y0, n.y)
    x1 = max(x1, n.x + nodeW)
    y1 = max(y1, n.y + nodeHeight(n, gApp.lib))
  let z = max(0.3, min(1.4, min((rw - 80) / max(1.0, x1 - x0), (rh - 120) / max(1.0, y1 - y0))))
  gApp.zoom = z
  gApp.panX = (rw - (x1 - x0) * z) / 2 - x0 * z
  gApp.panY = (rh - (y1 - y0) * z) / 2 - y0 * z + 10

proc viewCenterWorld*(c: GraphCanvas): (float, float) =
  let (rx, ry, rw, rh) = ctlRect(c)
  result = c.toWorld(rx + rw / 2, ry + rh / 2)

proc flashMessage*(c: GraphCanvas, msg: string) =
  c.setFlash(msg)
