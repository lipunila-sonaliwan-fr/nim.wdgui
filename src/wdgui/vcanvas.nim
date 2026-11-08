# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
#   wdgui - vector canvas: direct editing of an SVG scene (vscene).
#
# * Tools: selection (click, Shift+click, selection marquee), rectangle, ellipse,
#   line, arrow, pen (Bézier: click = corner node, click-and-drag = smooth node,
#   click on the first node = close path, Enter/double-click = finish), text (mouse-defined
#   box, direct input), image and component (mouse-defined box), hand, nodes (editing
#   path nodes and handles; double-click a node to toggle between corner/smooth).
# * Handles: 8 resizing handles (hold Shift to maintain proportions).
#   Snapping: to grid, neighboring shapes (edges and centers, smart guides),
#   and user-defined guides. Arrow keys: move by 1 unit (hold Shift to move by 10).
# * Keyboard: Delete, Cmd/Ctrl+A, C, X, V, D (duplicate), Z, Y (Shift+Z), G (group),
#   Shift+G (ungroup), Esc (deselect, finish input), Space + drag (pan/hand tool).
#   Mouse wheel: scroll (hold Shift for horizontal); Cmd/Ctrl + wheel: zoom at pointer location.
# * Modes: edit, gallery (clickable cards, vertical scrolling), board (movable cards:
#   storyboard), and presentation (slide scaled to fit, without interface elements).
# * Rendering: the scene is rasterized by vscene into a cached texture; during a
#   drag operation, the selected element is rendered separately (allowing movement
#   without triggering a full re-render). # * Events: evSelection (text: comma-separated identifiers; in gallery and
#   grid views: the group), evChange (text: action; details provided in lastAction and lastIds),
#   evDoubleClick (text: identifier or group).

import std/[math, strutils, tables, sets, algorithm, sequtils, os]
import ../sdl3, colors_themes, drawing, core, vscene

type
  VTool* = enum
    vtSelect = "selection", vtRect = "rectangle", vtEllipse = "ellipse", vtLine = "ligne",
    vtArrow = "fleche", vtPen = "plume", vtText = "texte", vtImage = "image", vtHand = "main",
    vtNodes = "noeuds"

  VMode* = enum
    vmEdit = "edition", vmGallery = "galerie", vmBoard = "plateau", vmView = "lecture"

  VDrag = enum
    vdNone, vdMove, vdResize, vdRubber, vdCreate, vdPan, vdNode, vdHandleIn, vdHandleOut, vdPenHandle

  VectorCanvas* = ref object of Control
    scene*: VScene
    zoom*, panX*, panY*: float
    tool*: VTool
    mode*: VMode
    selection*: seq[string]
    gridSize*: float
    showGrid*, snapGrid*, snapObjects*: bool
    guides*: seq[tuple[vertical: bool, pos: float]]
    pendingHref*, pendingData*: string     # image or component to be placed (image tool)
    pendingRatio*: float                   # width / height of the image to be placed (0: flexible)
    newFill*, newStroke*, newFont*: string # style of new forms
    newStrokeWidth*, newFontSize*: float
    lastAction*: string
    lastIds*: seq[string]
    needFit*: bool
    fitWidth*: bool                        # gallery: fit to width
    stickyTool*: bool                      # the tool remains active after a creation
    editText*: string                      # text format currently being entered
    caret*: int
    undoStack, redoStack: seq[VScene]
    undoTag: string
    undoTime: uint64
    tex: SDL_Texture
    texW, texH: int
    texKey: string
    texX, texY: float                      # texture position (relative to the control)
    selTex: SDL_Texture
    selW, selH: int
    selX, selY: float                      # position of the selection texture at the start
    selKey: string
    drag: VDrag
    startX, startY, curX, curY: float      # screen (related to control)
    origPanX, origPanY: float
    origShapes: seq[VShape]
    origBox: tuple[x, y, w, h: float]
    handle: int
    moved: bool
    created: VShape
    snapLines: seq[tuple[vertical: bool, pos: float]]
    hoverId: string
    nodeId*: string
    nodeSub, nodeIdx: int
    penShape: VShape
    clipboard: seq[VShape]
    spaceDown: bool
    dragGroup: string

const
  HandleR = 4.5
  SnapPx = 6.0
  Accent = Color(r: 79, g: 124, b: 255, a: 255)
  GuideCol = Color(r: 236, g: 72, b: 153, a: 230)
  UserGuideCol = Color(r: 6, g: 182, b: 212, a: 200)

proc newVectorCanvas*(mode = vmEdit): VectorCanvas =
  result = VectorCanvas(scene: newScene(1280, 720), zoom: 1, tool: vtSelect, mode: mode, gridSize: 10,
                        snapObjects: true, newFill: "#4f7cff", newStroke: "none", newFont: "Poppins",
                        newStrokeWidth: 2, newFontSize: 32, needFit: true, nodeIdx: -1)
  result.focusable = mode == vmEdit
  initControl(result)

method typeName*(c: VectorCanvas): string = "Toile"
method preferredSize*(c: VectorCanvas, d: Drawing, t: Theme): tuple[w, h: float] = (400.0, 300.0)
method acceptsText*(c: VectorCanvas): bool = c.editText.len > 0
method acceptsTab*(c: VectorCanvas): bool = false

#
# rreference
#

proc toScene*(c: VectorCanvas, sx, sy: float): FPoint =
  ((sx - c.rect.x - c.panX) / c.zoom, (sy - c.rect.y - c.panY) / c.zoom)

proc toScreen*(c: VectorCanvas, x, y: float): FPoint =
  (c.rect.x + c.panX + x * c.zoom, c.rect.y + c.panY + y * c.zoom)

proc viewMatrix(c: VectorCanvas): Affine = [c.zoom, 0, 0, c.zoom, c.rect.x + c.panX, c.rect.y + c.panY]

proc fit*(c: VectorCanvas) =
  # The entire scene in view (gallery: the width).
  let r = c.rect
  if r.w < 10 or r.h < 10 or c.scene.width <= 0 or c.scene.height <= 0: return
  let m = if c.mode == vmView: 0.0 elif c.mode in {vmGallery, vmBoard}: 8.0 else: 32.0
  if c.fitWidth or c.mode in {vmGallery, vmBoard}:
    c.zoom = max(0.05, (r.w - 2 * m) / c.scene.width)
    c.panX = m
    c.panY = m
  else:
    c.zoom = clamp(min((r.w - 2 * m) / c.scene.width, (r.h - 2 * m) / c.scene.height), 0.02, 64)
    c.panX = (r.w - c.scene.width * c.zoom) / 2
    c.panY = (r.h - c.scene.height * c.zoom) / 2
  c.needFit = false

proc setZoomAt*(c: VectorCanvas, z: float, sx, sy: float) =
  ## Zoom autour du point écran (sx, sy) (relatif à la fenêtre).
  let nz = clamp(z, 0.02, 64)
  let p = c.toScene(sx, sy)
  c.zoom = nz
  c.panX = sx - c.rect.x - p.x * nz
  c.panY = sy - c.rect.y - p.y * nz

proc invalidate*(c: VectorCanvas) =
  inc c.scene.version
  markDirty(c)

# undo / redo

proc pushUndo*(c: VectorCanvas, tag = "") =
  # Snapshot before modification; successive modifications with the same label
  # (entered in the inspector) within less than a second are treated as a single modification.
  let now = SDL_GetTicks()
  if tag.len > 0 and tag == c.undoTag and now - c.undoTime < 1000:
    c.undoTime = now
    return
  c.undoTag = tag
  c.undoTime = now
  c.undoStack.add c.scene.cloneScene
  if c.undoStack.len > 80: c.undoStack.delete(0)
  c.redoStack.setLen(0)

proc canUndo*(c: VectorCanvas): bool = c.undoStack.len > 0
proc canRedo*(c: VectorCanvas): bool = c.redoStack.len > 0

proc emitChange*(c: VectorCanvas, action: string, ids: seq[string] = @[]) =
  c.lastAction = action
  c.lastIds = ids
  emit(c, evChange, text = action)

proc emitSelection(c: VectorCanvas) =
  emit(c, evSelection, text = c.selection.join(","))

proc undo*(c: VectorCanvas) =
  if c.undoStack.len == 0: return
  c.redoStack.add c.scene.cloneScene
  let base = c.scene.base
  let v = c.scene.version
  c.scene = c.undoStack.pop
  c.scene.base = base
  c.scene.version = v + 1
  c.selection = c.selection.filterIt(c.scene.findShape(it) != nil)
  c.editText = ""
  c.undoTag = ""
  markDirty(c)
  c.emitChange("annuler")

proc redo*(c: VectorCanvas) =
  if c.redoStack.len == 0: return
  c.undoStack.add c.scene.cloneScene
  let base = c.scene.base
  let v = c.scene.version
  c.scene = c.redoStack.pop
  c.scene.base = base
  c.scene.version = v + 1
  c.selection = c.selection.filterIt(c.scene.findShape(it) != nil)
  c.undoTag = ""
  markDirty(c)
  c.emitChange("retablir")

proc clearHistory*(c: VectorCanvas) =
  c.undoStack.setLen(0)
  c.redoStack.setLen(0)

#
# selection
#

proc selectedShapes*(c: VectorCanvas): seq[VShape] =
  for s in c.scene.shapes:
    if s.id in c.selection: result.add s

proc groupMembers(c: VectorCanvas, s: VShape): seq[VShape] =
  if s.group.len == 0: return @[s]
  for x in c.scene.shapes:
    if x.group == s.group: result.add x

proc selectionBox*(c: VectorCanvas): tuple[x, y, w, h: float] =
  var x0 = Inf
  var y0 = Inf
  var x1 = -Inf
  var y1 = -Inf
  for s in c.selectedShapes:
    let b = s.bounds
    x0 = min(x0, b.x); y0 = min(y0, b.y); x1 = max(x1, b.x + b.w); y1 = max(y1, b.y + b.h)
  if x0 == Inf: return (0.0, 0.0, 0.0, 0.0)
  (x0, y0, x1 - x0, y1 - y0)

proc setSelection*(c: VectorCanvas, ids: seq[string], notify = true) =
  var res: seq[string]
  for id in ids:
    if c.scene.findShape(id) != nil and id notin res: res.add id
  if res == c.selection: return
  c.selection = res
  if c.editText.len > 0 and c.editText notin res: c.editText = ""
  markDirty(c)
  if notify: c.emitSelection

proc shapeAt*(c: VectorCanvas, sx, sy: float, includeLocked = false): VShape =
  let p = c.toScene(sx, sy)
  let tol = 4 / c.zoom
  for i in countdown(c.scene.shapes.high, 0):
    let s = c.scene.shapes[i]
    if not c.scene.layerVisible(s): continue
    if not includeLocked and c.mode == vmEdit and c.scene.layerLocked(s): continue
    if s.hitShape(p.x, p.y, tol): return s

proc selectableIds(c: VectorCanvas, s: VShape): seq[string] =
  for m in c.groupMembers(s): result.add m.id

#
# render cache
#

proc uploadRaster(d: Drawing, tex: var SDL_Texture, tw, th: var int, w, h: int, px: seq[uint8]) =
  if tex == nil or tw != w or th != h:
    if tex != nil: SDL_DestroyTexture(tex)
    tex = SDL_CreateTexture(d.ren, 0x16762004'u32, SDL_TEXTUREACCESS_STATIC, cint(w), cint(h))
    tw = w
    th = h
    if tex != nil:
      discard SDL_SetTextureBlendMode(tex, SDL_BLENDMODE_BLEND)
      discard SDL_SetTextureScaleMode(tex, 1)
  if tex != nil and px.len >= w * h * 4:
    discard SDL_UpdateTexture(tex, nil, unsafeAddr px[0], cint(w * 4))

proc skipSet(c: VectorCanvas): HashSet[string] =
  result = initHashSet[string]()
  if c.drag in {vdMove, vdResize, vdNode, vdHandleIn, vdHandleOut} and c.moved:
    for id in c.selection: result.incl id
    if c.nodeId.len > 0: result.incl c.nodeId
  if c.editText.len > 0: discard

proc refreshTexture(c: VectorCanvas, d: Drawing) =
  # Rasterizes the visible part of the scene (excluding the selection during a drag operation).
  let r = c.rect
  let ax = c.panX
  let ay = c.panY
  let aw = c.scene.width * c.zoom
  let ah = c.scene.height * c.zoom
  # visible area of ​​the board (coordinates relative to the control)
  var vx0 = max(0.0, ax)
  var vy0 = max(0.0, ay)
  var vx1 = min(r.w, ax + aw)
  var vy1 = min(r.h, ay + ah)
  if c.mode in {vmGallery, vmBoard}:
    vx0 = 0; vx1 = r.w
  if vx1 <= vx0 or vy1 <= vy0: return
  let skip = c.skipSet
  var skipKey = ""
  for id in skip: skipKey.add id & ","
  let full = ax >= 0 and ay >= 0 and ax + aw <= r.w and ay + ah <= r.h
  let key = $c.scene.version & "|" & $c.zoom & "|" & skipKey & "|" & $c.editText & "|" & $c.caret &
            (if full: "" else: "|" & $round(vx0) & "," & $round(vy0) & "," & $round(vx1) & "," & $round(vy1) &
             "|" & $c.panX & "," & $c.panY)
  if key == c.texKey and c.tex != nil:
    if full:
      c.texX = ax
      c.texY = ay
    return
  let w = int(ceil(vx1 - vx0))
  let h = int(ceil(vy1 - vy0))
  if w <= 0 or h <= 0: return
  var ras = newRaster(w, h)
  let m: Affine = [c.zoom, 0, 0, c.zoom, ax - floor(vx0), ay - floor(vy0)]
  renderScene(c.scene, ras, m, skip)
  uploadRaster(d, c.tex, c.texW, c.texH, w, h, ras.toRgba8)
  c.texKey = key
  c.texX = floor(vx0)
  c.texY = floor(vy0)

proc refreshSelTexture(c: VectorCanvas, d: Drawing) =
  # Rendering of the selection only (moved during a drag operation).
  let b = c.selectionBox
  if b.w <= 0 and b.h <= 0 and c.drag != vdMove: return
  var extra = 0.0
  for s in c.selectedShapes: extra = max(extra, s.strokeWidth * 2 + 14 + (if s.shadow: 20 else: 0))
  let x0 = (b.x - extra) * c.zoom
  let y0 = (b.y - extra) * c.zoom
  let w = int(ceil((b.w + 2 * extra) * c.zoom)) + 2
  let h = int(ceil((b.h + 2 * extra) * c.zoom)) + 2
  if w <= 0 or h <= 0 or w * h > 16_000_000: return
  var key = $c.scene.version & "|" & $c.zoom & "|" & c.selection.join(",") & "|" & $round(b.w * 100) & "," & $round(b.h * 100)
  if c.drag == vdMove: key = $c.zoom & "|" & c.selection.join(",") & "|mv"
  if key == c.selKey and c.selTex != nil: return
  var ras = newRaster(w, h)
  let m: Affine = [c.zoom, 0, 0, c.zoom, -floor(x0), -floor(y0)]
  var sub = VScene(width: c.scene.width, height: c.scene.height, layers: c.scene.layers, base: c.scene.base)
  for s in c.selectedShapes: sub.shapes.add s
  renderScene(sub, ras, m)
  uploadRaster(d, c.selTex, c.selW, c.selH, w, h, ras.toRgba8)
  c.selKey = key
  c.selX = floor(x0)
  c.selY = floor(y0)

#
# drawing
#

proc handlesOf(b: tuple[x, y, w, h: float]): array[8, FPoint] =
  [(b.x, b.y), (b.x + b.w / 2, b.y), (b.x + b.w, b.y), (b.x + b.w, b.y + b.h / 2),
   (b.x + b.w, b.y + b.h), (b.x + b.w / 2, b.y + b.h), (b.x, b.y + b.h), (b.x, b.y + b.h / 2)]

proc drawRectOutline(d: Drawing, x0, y0, x1, y1: float, col: Color, ep = 1.0) =
  d.line(x0, y0, x1, y0, col, ep)
  d.line(x1, y0, x1, y1, col, ep)
  d.line(x1, y1, x0, y1, col, ep)
  d.line(x0, y1, x0, y0, col, ep)

proc drawShapeOutline(c: VectorCanvas, d: Drawing, s: VShape, col: Color, ep = 1.0) =
  let m = c.viewMatrix
  let polys = s.outline(m)
  for i, p in polys:
    if p.len < 2: continue
    let closed = s.kind notin {vkLine, vkPath} or (i < s.subs.len and s.subs[i].closed)
    let n = if closed: p.len else: p.len - 1
    for k in 0 ..< n:
      let a = p[k]
      let b = p[(k + 1) mod p.len]
      d.line(a.x, a.y, b.x, b.y, col, ep)

proc drawHandle(d: Drawing, x, y: float, square = true, fillCol = Color(r: 255, g: 255, b: 255, a: 255),
                border = Accent) =
  if square:
    d.fillRect(rect(x - HandleR, y - HandleR, HandleR * 2, HandleR * 2), border)
    d.fillRect(rect(x - HandleR + 1.5, y - HandleR + 1.5, HandleR * 2 - 3, HandleR * 2 - 3), fillCol)
  else:
    d.fillCircle(x, y, HandleR, border)
    d.fillCircle(x, y, HandleR - 1.5, fillCol)

proc caretPos(c: VectorCanvas, s: VShape): (float, float, float) =
  # Input cursor position (scene): x, line top, height.
  let prefix = s.text[0 ..< clamp(c.caret, 0, s.text.len)]
  var t = s.clone
  t.text = prefix
  var lines = t.wrapLines
  if lines.len == 0: lines = @[""]
  let full = s.wrapLines
  let lineIdx = lines.len - 1
  let lw = measureText(s.font, s.fontSize, s.bold, s.italic, lines[^1])
  let bw = s.textBoxWidth
  var lineW = lw
  if lineIdx < full.len: lineW = measureText(s.font, s.fontSize, s.bold, s.italic, full[lineIdx])
  let x0 = case s.align
           of "centre", "center": s.x + (bw - lineW) / 2
           of "droite", "right": s.x + bw - lineW
           else: s.x
  (x0 + lw, s.y + lineIdx.float * s.lineStep, s.lineStep)

method draw*(c: VectorCanvas, d: Drawing, t: Theme) =
  let r = c.rect
  if c.needFit: c.fit
  let bgCol = if c.mode == vmView: Color(r: 12, g: 12, b: 14, a: 255)
              elif c.mode in {vmGallery, vmBoard}: t.windowBg
              else: Color(r: max(0, t.windowBg.r.int - 10).uint8, g: max(0, t.windowBg.g.int - 10).uint8,
                          b: max(0, t.windowBg.b.int - 8).uint8, a: 255)
  d.fillRect(r, bgCol)
  d.pushClip(r)
  # planche
  let a0 = c.toScreen(0, 0)
  let a1 = c.toScreen(c.scene.width, c.scene.height)
  if c.mode == vmEdit:
    for k in 1 .. 4:
      d.fillRect(rect(a0.x + k.float, a0.y + k.float * 1.5, a1.x - a0.x, a1.y - a0.y),
                 Color(r: 0, g: 0, b: 0, a: uint8(22 - k * 4)))
  if c.mode notin {vmGallery, vmBoard}:
    var paper = Color(r: 255, g: 255, b: 255, a: 255)
    if c.scene.background.len > 0: paper = Color(r: 255, g: 255, b: 255, a: 255)
    d.fillRect(rect(a0.x, a0.y, a1.x - a0.x, a1.y - a0.y), paper)
  # scene
  c.refreshTexture(d)
  if c.tex != nil:
    d.drawTexture(c.tex, rect(r.x + c.texX, r.y + c.texY, c.texW.float, c.texH.float))
  # selection in motion
  if c.drag in {vdMove, vdResize} and c.moved and c.selection.len > 0:
    c.refreshSelTexture(d)
    if c.selTex != nil:
      var dx, dy = 0.0
      if c.drag == vdMove and c.origShapes.len > 0:
        let cur = c.scene.findShape(c.origShapes[0].id)
        if cur != nil:
          let b0 = c.origShapes[0].bounds
          let b1 = cur.bounds
          dx = (b1.x - b0.x) * c.zoom
          dy = (b1.y - b0.y) * c.zoom
      d.drawTexture(c.selTex, rect(r.x + c.panX + c.selX + dx, r.y + c.panY + c.selY + dy, c.selW.float, c.selH.float))
  # grid
  if c.showGrid and c.mode == vmEdit and c.gridSize * c.zoom >= 6:
    let gc = Color(r: 100, g: 116, b: 139, a: 34)
    let gc2 = Color(r: 100, g: 116, b: 139, a: 70)
    var x = 0.0
    var k = 0
    while x <= c.scene.width + 0.01:
      let sx = c.toScreen(x, 0).x
      if sx >= r.x and sx <= r.x + r.w: d.line(sx, max(a0.y, r.y), sx, min(a1.y, r.y + r.h), (if k mod 5 == 0: gc2 else: gc))
      x += c.gridSize
      inc k
    var y = 0.0
    k = 0
    while y <= c.scene.height + 0.01:
      let sy = c.toScreen(0, y).y
      if sy >= r.y and sy <= r.y + r.h: d.line(max(a0.x, r.x), sy, min(a1.x, r.x + r.w), sy, (if k mod 5 == 0: gc2 else: gc))
      y += c.gridSize
      inc k
  if c.mode == vmView:
    d.popClip()
    return
  # user guides
  for g in c.guides:
    if g.vertical:
      let sx = c.toScreen(g.pos, 0).x
      d.line(sx, r.y, sx, r.y + r.h, UserGuideCol)
    else:
      let sy = c.toScreen(0, g.pos).y
      d.line(r.x, sy, r.x + r.w, sy, UserGuideCol)
  # overview
  if c.hoverId.len > 0 and c.hoverId notin c.selection and c.drag == vdNone:
    let s = c.scene.findShape(c.hoverId)
    if s != nil:
      if c.mode in {vmGallery, vmBoard} and s.group.len > 0:
        var x0 = Inf
        var y0 = Inf
        var x1 = -Inf
        var y1 = -Inf
        for m in c.groupMembers(s):
          let b = m.bounds
          x0 = min(x0, b.x); y0 = min(y0, b.y); x1 = max(x1, b.x + b.w); y1 = max(y1, b.y + b.h)
        let p0 = c.toScreen(x0, y0)
        let p1 = c.toScreen(x1, y1)
        d.strokeRoundRect(rect(p0.x - 3, p0.y - 3, p1.x - p0.x + 6, p1.y - p0.y + 6), 8,
                          Color(r: Accent.r, g: Accent.g, b: Accent.b, a: 140), 2)
      else:
        c.drawShapeOutline(d, s, Color(r: Accent.r, g: Accent.g, b: Accent.b, a: 150))
  # selection
  let sel = c.selectedShapes
  if sel.len > 0 and c.mode in {vmGallery, vmBoard}:
    let b = c.selectionBox
    let p0 = c.toScreen(b.x, b.y)
    let p1 = c.toScreen(b.x + b.w, b.y + b.h)
    d.strokeRoundRect(rect(p0.x - 4, p0.y - 4, p1.x - p0.x + 8, p1.y - p0.y + 8), 10, Accent, 2.5)
  elif sel.len > 0 and c.tool != vtNodes:
    if not (c.drag in {vdMove, vdResize} and c.moved):
      for s in sel: c.drawShapeOutline(d, s, Accent)
    let b = c.selectionBox
    let p0 = c.toScreen(b.x, b.y)
    let p1 = c.toScreen(b.x + b.w, b.y + b.h)
    if sel.len > 1 or (sel.len == 1 and sel[0].rotation != 0):
      drawRectOutline(d, p0.x, p0.y, p1.x, p1.y, Color(r: Accent.r, g: Accent.g, b: Accent.b, a: 160))
    let locked = sel.len == 1 and c.scene.layerLocked(sel[0])
    if c.editText.len == 0 and not locked:
      let hs = handlesOf((p0.x, p0.y, p1.x - p0.x, p1.y - p0.y))
      let lineSel = sel.len == 1 and sel[0].kind == vkLine
      if lineSel and sel[0].subs.len > 0 and sel[0].subs[0].pts.len >= 2:
        let pa = c.toScreen(sel[0].subs[0].pts[0].x, sel[0].subs[0].pts[0].y)
        let pb = c.toScreen(sel[0].subs[0].pts[^1].x, sel[0].subs[0].pts[^1].y)
        drawHandle(d, pa.x, pa.y, false)
        drawHandle(d, pb.x, pb.y, false)
      else:
        for h in hs: drawHandle(d, h.x, h.y)
  # node editing
  if c.tool == vtNodes or c.nodeId.len > 0:
    let s = c.scene.findShape(if c.nodeId.len > 0: c.nodeId elif sel.len == 1: sel[0].id else: "")
    if s != nil and s.kind in {vkPath, vkLine}:
      c.drawShapeOutline(d, s, Accent)
      for si, sub in s.subs:
        for pi, p in sub.pts:
          let q = c.toScreen(p.x, p.y)
          let active = si == c.nodeSub and pi == c.nodeIdx and c.nodeId == s.id
          if active or p.ix != 0 or p.iy != 0 or p.ox != 0 or p.oy != 0:
            if p.ix != 0 or p.iy != 0:
              let hi = c.toScreen(p.x + p.ix, p.y + p.iy)
              d.line(q.x, q.y, hi.x, hi.y, Color(r: Accent.r, g: Accent.g, b: Accent.b, a: 180))
              drawHandle(d, hi.x, hi.y, false, Accent, Accent)
            if p.ox != 0 or p.oy != 0:
              let ho = c.toScreen(p.x + p.ox, p.y + p.oy)
              d.line(q.x, q.y, ho.x, ho.y, Color(r: Accent.r, g: Accent.g, b: Accent.b, a: 180))
              drawHandle(d, ho.x, ho.y, false, Accent, Accent)
          drawHandle(d, q.x, q.y, true, (if active: Accent else: Color(r: 255, g: 255, b: 255, a: 255)))
  # pen in progress
  if c.penShape != nil and c.penShape.subs.len > 0:
    let sub = c.penShape.subs[0]
    c.drawShapeOutline(d, c.penShape, Accent, 1.5)
    if sub.pts.len > 0 and c.drag == vdNone:
      let last = c.toScreen(sub.pts[^1].x, sub.pts[^1].y)
      d.line(last.x, last.y, r.x + c.curX, r.y + c.curY, Color(r: Accent.r, g: Accent.g, b: Accent.b, a: 140))
    for i, p in sub.pts:
      let q = c.toScreen(p.x, p.y)
      drawHandle(d, q.x, q.y, true, (if i == 0: Accent else: Color(r: 255, g: 255, b: 255, a: 255)))
  # selection rectangle and creation
  if c.drag == vdRubber and c.moved:
    let x0 = min(c.startX, c.curX) + r.x
    let y0 = min(c.startY, c.curY) + r.y
    let w = abs(c.curX - c.startX)
    let h = abs(c.curY - c.startY)
    d.fillRect(rect(x0, y0, w, h), Color(r: Accent.r, g: Accent.g, b: Accent.b, a: 30))
    drawRectOutline(d, x0, y0, x0 + w, y0 + h, Accent)
  if c.drag == vdCreate and c.created != nil:
    c.drawShapeOutline(d, c.created, Accent, 1.5)
  # smart guides
  for g in c.snapLines:
    if g.vertical:
      let sx = c.toScreen(g.pos, 0).x
      d.line(sx, r.y, sx, r.y + r.h, GuideCol)
    else:
      let sy = c.toScreen(0, g.pos).y
      d.line(r.x, sy, r.x + r.w, sy, GuideCol)
  # input cursor
  if c.editText.len > 0:
    let s = c.scene.findShape(c.editText)
    if s != nil:
      let b = s.bounds
      let p0 = c.toScreen(b.x, b.y)
      let p1 = c.toScreen(b.x + max(b.w, 20), b.y + b.h)
      drawRectOutline(d, p0.x - 2, p0.y - 2, p1.x + 2, p1.y + 2, Color(r: Accent.r, g: Accent.g, b: Accent.b, a: 120))
      let (cx, cy, ch) = c.caretPos(s)
      let q0 = c.toScreen(cx, cy + ch * 0.12)
      let q1 = c.toScreen(cx, cy + ch * 0.92)
      if (SDL_GetTicks() div 530) mod 2 == 0 or true:
        d.line(q0.x, q0.y, q1.x, q1.y, Accent, 2)
  # zoom
  if c.mode == vmEdit:
    let label = $int(round(c.zoom * 100)) & " %"
    let tw = d.textWidth(label) + 14
    d.fillRoundRect(rect(r.x + r.w - tw - 8, r.y + r.h - 26, tw, 20), 6, Color(r: 15, g: 23, b: 42, a: 150))
    d.text(r.x + r.w - tw - 1, r.y + r.h - 26 + (20 - d.textHeight) / 2, label, Color(r: 255, g: 255, b: 255, a: 230))
  d.popClip()

#
# magnetism
#

proc snapMove(c: VectorCanvas, b: tuple[x, y, w, h: float], dx, dy: var float) =
  # Adjust the displacement (dx, dy) of box b relative to the grid, guides, and neighboring shapes.
  c.snapLines.setLen(0)
  let tol = SnapPx / c.zoom
  var bestX = tol + 1
  var bestY = tol + 1
  var adjX, adjY = 0.0
  var lineX, lineY = NaN
  let xs = [b.x + dx, b.x + dx + b.w / 2, b.x + dx + b.w]
  let ys = [b.y + dy, b.y + dy + b.h / 2, b.y + dy + b.h]
  proc tryX(target: float) =
    for v in xs:
      let dd = target - v
      if abs(dd) < bestX:
        bestX = abs(dd); adjX = dd; lineX = target
  proc tryY(target: float) =
    for v in ys:
      let dd = target - v
      if abs(dd) < bestY:
        bestY = abs(dd); adjY = dd; lineY = target
  if c.snapObjects:
    tryX(0); tryX(c.scene.width / 2); tryX(c.scene.width)
    tryY(0); tryY(c.scene.height / 2); tryY(c.scene.height)
    for s in c.scene.shapes:
      if s.id in c.selection or not c.scene.layerVisible(s): continue
      let o = s.bounds
      tryX(o.x); tryX(o.x + o.w / 2); tryX(o.x + o.w)
      tryY(o.y); tryY(o.y + o.h / 2); tryY(o.y + o.h)
  for g in c.guides:
    if g.vertical: tryX(g.pos) else: tryY(g.pos)
  if bestX <= tol:
    dx += adjX
    c.snapLines.add (true, lineX)
  elif c.snapGrid and c.gridSize > 0:
    dx = round((b.x + dx) / c.gridSize) * c.gridSize - b.x
  if bestY <= tol:
    dy += adjY
    c.snapLines.add (false, lineY)
  elif c.snapGrid and c.gridSize > 0:
    dy = round((b.y + dy) / c.gridSize) * c.gridSize - b.y

proc snapPoint(c: VectorCanvas, p: FPoint): FPoint =
  # Point (creation, node): grid and shape guides.
  result = p
  c.snapLines.setLen(0)
  let tol = SnapPx / c.zoom
  var bx = tol + 1
  var by = tol + 1
  if c.snapObjects:
    for s in c.scene.shapes:
      if s.id in c.selection or not c.scene.layerVisible(s) or (c.created != nil and s.id == c.created.id): continue
      let o = s.bounds
      for v in [o.x, o.x + o.w / 2, o.x + o.w]:
        if abs(v - p.x) < bx:
          bx = abs(v - p.x); result.x = v
      for v in [o.y, o.y + o.h / 2, o.y + o.h]:
        if abs(v - p.y) < by:
          by = abs(v - p.y); result.y = v
  for g in c.guides:
    if g.vertical and abs(g.pos - p.x) < bx:
      bx = abs(g.pos - p.x); result.x = g.pos
    if not g.vertical and abs(g.pos - p.y) < by:
      by = abs(g.pos - p.y); result.y = g.pos
  if bx <= tol: c.snapLines.add (true, result.x)
  elif c.snapGrid and c.gridSize > 0: result.x = round(p.x / c.gridSize) * c.gridSize
  if by <= tol: c.snapLines.add (false, result.y)
  elif c.snapGrid and c.gridSize > 0: result.y = round(p.y / c.gridSize) * c.gridSize

#
# operations
#

proc addShape*(c: VectorCanvas, s: VShape, select = true) =
  if s.layer.len == 0:
    s.layer = if c.scene.layers.len > 0: c.scene.layers[^1].name else: "Calque 1"
  c.scene.ensureLayer(s.layer)
  # insérée à la fin de son calque (au premier plan de ce calque)
  var at = c.scene.shapes.len
  let li = c.scene.layerOf(s.layer)
  for i in countdown(c.scene.shapes.high, 0):
    let k = c.scene.layerOf(c.scene.shapes[i].layer)
    if k > li:
      at = i
  c.scene.shapes.insert(s, min(at, c.scene.shapes.len))
  if s.kind == vkText: s.fitTextHeight
  c.invalidate
  if select: c.setSelection(@[s.id])

proc deleteSelection*(c: VectorCanvas) =
  if c.selection.len == 0: return
  c.pushUndo
  let ids = c.selection
  c.scene.shapes = c.scene.shapes.filterIt(it.id notin ids)
  c.selection.setLen(0)
  c.editText = ""
  c.invalidate
  c.emitChange("suppression", ids)
  c.emitSelection

proc duplicateSelection*(c: VectorCanvas, dx = 16.0, dy = 16.0) =
  if c.selection.len == 0: return
  c.pushUndo
  var ids: seq[string]
  var groupMap: Table[string, string]
  for s in c.selectedShapes:
    let n = s.clone
    n.id = newId()
    if n.group.len > 0:
      if not groupMap.hasKey(n.group): groupMap[n.group] = newId("g")
      n.group = groupMap[n.group]
    n.moveShape(dx, dy)
    c.scene.shapes.add n
    ids.add n.id
  c.invalidate
  c.setSelection(ids)
  c.emitChange("duplication", ids)

proc copySelection*(c: VectorCanvas) =
  c.clipboard.setLen(0)
  for s in c.selectedShapes: c.clipboard.add s.clone

proc paste*(c: VectorCanvas) =
  if c.clipboard.len == 0: return
  c.pushUndo
  var ids: seq[string]
  for s in c.clipboard:
    let n = s.clone
    n.id = newId()
    n.moveShape(20, 20)
    c.scene.shapes.add n
    ids.add n.id
  for s in c.clipboard: s.moveShape(20, 20)
  c.invalidate
  c.setSelection(ids)
  c.emitChange("collage", ids)

proc groupSelection*(c: VectorCanvas) =
  if c.selection.len < 2: return
  c.pushUndo
  let g = newId("g")
  # les membres deviennent contigus (au rang du plus haut)
  var members: seq[VShape]
  var rest: seq[VShape]
  var top = -1
  for i, s in c.scene.shapes:
    if s.id in c.selection:
      members.add s
      top = i
    else: rest.add s
  var insertAt = 0
  for i, s in c.scene.shapes:
    if i > top: break
    if s.id notin c.selection: inc insertAt
  for m in members: m.group = g
  c.scene.shapes = rest
  for i, m in members: c.scene.shapes.insert(m, insertAt + i)
  c.invalidate
  c.emitChange("groupe", c.selection)

proc ungroupSelection*(c: VectorCanvas) =
  if c.selection.len == 0: return
  c.pushUndo
  for s in c.selectedShapes: s.group = ""
  c.invalidate
  c.emitChange("degroupe", c.selection)

proc reorder*(c: VectorCanvas, how: string) =
  ## avant, arriere, premierplan, arriereplan.
  if c.selection.len == 0: return
  c.pushUndo
  var sh = c.scene.shapes
  case how
  of "premierplan":
    var keep, moved: seq[VShape]
    for s in sh:
      if s.id in c.selection: moved.add s else: keep.add s
    sh = keep & moved
  of "arriereplan":
    var keep, moved: seq[VShape]
    for s in sh:
      if s.id in c.selection: moved.add s else: keep.add s
    sh = moved & keep
  of "avant":
    var i = sh.high - 1
    while i >= 0:
      if sh[i].id in c.selection and sh[i + 1].id notin c.selection: swap(sh[i], sh[i + 1])
      dec i
  of "arriere":
    var i = 1
    while i < sh.len:
      if sh[i].id in c.selection and sh[i - 1].id notin c.selection: swap(sh[i], sh[i - 1])
      inc i
  else: discard
  c.scene.shapes = sh
  c.invalidate
  c.emitChange("ordre", c.selection)

proc alignSelection*(c: VectorCanvas, how: string) =
  # left, center, right, top, middle, bottom (single selection: relative to the board),
  # repartirh, repartirv (at least three shapes).
  let sel = c.selectedShapes
  if sel.len == 0: return
  c.pushUndo
  let ref0 = if sel.len == 1: (x: 0.0, y: 0.0, w: c.scene.width, h: c.scene.height) else: c.selectionBox
  case how
  of "repartirh", "repartirv":
    if sel.len < 3: return
    var items = sel
    let horiz = how == "repartirh"
    items.sort(proc (a, b: VShape): int = cmp(if horiz: a.bounds.x else: a.bounds.y, if horiz: b.bounds.x else: b.bounds.y))
    var total = 0.0
    for s in items: total += (if horiz: s.bounds.w else: s.bounds.h)
    let span = if horiz: ref0.w else: ref0.h
    let gap = (span - total) / float(items.len - 1)
    var pos = if horiz: ref0.x else: ref0.y
    for s in items:
      let b = s.bounds
      if horiz: s.moveShape(pos - b.x, 0) else: s.moveShape(0, pos - b.y)
      pos += (if horiz: b.w else: b.h) + gap
  else:
    for s in sel:
      let b = s.bounds
      case how
      of "gauche": s.moveShape(ref0.x - b.x, 0)
      of "centre": s.moveShape(ref0.x + ref0.w / 2 - (b.x + b.w / 2), 0)
      of "droite": s.moveShape(ref0.x + ref0.w - (b.x + b.w), 0)
      of "haut": s.moveShape(0, ref0.y - b.y)
      of "milieu": s.moveShape(0, ref0.y + ref0.h / 2 - (b.y + b.h / 2))
      of "bas": s.moveShape(0, ref0.y + ref0.h - (b.y + b.h))
      else: discard
  c.invalidate
  c.emitChange("alignement", c.selection)

proc nudge(c: VectorCanvas, dx, dy: float) =
  if c.selection.len == 0: return
  c.pushUndo("nudge")
  for s in c.selectedShapes:
    if not c.scene.layerLocked(s): s.moveShape(dx, dy)
  c.invalidate
  c.emitChange("deplace", c.selection)

proc finishPen(c: VectorCanvas, close = false) =
  let p = c.penShape
  c.penShape = nil
  if p == nil or p.subs.len == 0 or p.subs[0].pts.len < 2:
    markDirty(c)
    return
  p.subs[0].closed = close
  if not close: p.fill = "none"
  if p.stroke == "none" or p.stroke.len == 0:
    p.stroke = "#1f2937"
    p.strokeWidth = max(2.0, c.newStrokeWidth)
  p.syncPathBox
  c.pushUndo
  c.addShape(p)
  c.emitChange("creation", @[p.id])
  if not c.stickyTool: c.tool = vtSelect

proc beginTextEdit*(c: VectorCanvas, id: string) =
  let s = c.scene.findShape(id)
  if s == nil or s.kind != vkText: return
  c.pushUndo
  c.editText = id
  c.caret = s.text.len
  c.setSelection(@[id])
  markDirty(c)

proc endTextEdit*(c: VectorCanvas) =
  if c.editText.len == 0: return
  let id = c.editText
  c.editText = ""
  c.invalidate
  c.emitChange("texte", @[id])

proc toolCursorKind(c: VectorCanvas): int =
  case c.tool
  of vtSelect, vtNodes: 0
  of vtHand: 9
  of vtText: 1
  else: 3

#
# mouse
#

proc handleAt(c: VectorCanvas, sx, sy: float): int =
  # Resizing handle under the pointer (0..7), -1 otherwise; lines: 10 / 11.
  if c.selection.len == 0 or c.mode != vmEdit or c.editText.len > 0: return -1
  let sel = c.selectedShapes
  if sel.len == 1 and c.scene.layerLocked(sel[0]): return -1
  if sel.len == 1 and sel[0].kind == vkLine and sel[0].subs.len > 0 and sel[0].subs[0].pts.len >= 2:
    let pa = c.toScreen(sel[0].subs[0].pts[0].x, sel[0].subs[0].pts[0].y)
    let pb = c.toScreen(sel[0].subs[0].pts[^1].x, sel[0].subs[0].pts[^1].y)
    if hypot(pa.x - sx, pa.y - sy) <= HandleR + 3: return 10
    if hypot(pb.x - sx, pb.y - sy) <= HandleR + 3: return 11
    return -1
  let b = c.selectionBox
  let p0 = c.toScreen(b.x, b.y)
  let p1 = c.toScreen(b.x + b.w, b.y + b.h)
  let hs = handlesOf((p0.x, p0.y, p1.x - p0.x, p1.y - p0.y))
  for i, h in hs:
    if abs(h.x - sx) <= HandleR + 3 and abs(h.y - sy) <= HandleR + 3: return i
  -1

method mouseCursor*(c: VectorCanvas, x, y: float): int =
  if c.mode == vmView: return SDL_SYSTEM_CURSOR_DEFAULT
  if c.mode in {vmGallery, vmBoard}:
    return (if c.shapeAt(x, y, true) != nil: (if c.mode == vmBoard: 9 else: SDL_SYSTEM_CURSOR_POINTER) else: 0)
  if c.spaceDown or c.drag == vdPan: return 9
  case c.handleAt(x, y)
  of 0, 4: return 5
  of 2, 6: return 6
  of 1, 5: return 8
  of 3, 7: return 7
  of 10, 11: return 3
  else: discard
  if c.tool == vtSelect:
    let s = c.shapeAt(x, y)
    if s != nil:
      if s.id == c.editText: return 1
      return 9
    return 0
  c.toolCursorKind

proc nodeHit(c: VectorCanvas, s: VShape, sx, sy: float): tuple[sub, idx, part: int] =
  # Node (part 0) or handle (1: input, 2: output) under the pointer.
  for si, sub in s.subs:
    for pi, p in sub.pts:
      let hi = c.toScreen(p.x + p.ix, p.y + p.iy)
      let ho = c.toScreen(p.x + p.ox, p.y + p.oy)
      if (p.ix != 0 or p.iy != 0) and hypot(hi.x - sx, hi.y - sy) <= HandleR + 3: return (si, pi, 1)
      if (p.ox != 0 or p.oy != 0) and hypot(ho.x - sx, ho.y - sy) <= HandleR + 3: return (si, pi, 2)
  for si, sub in s.subs:
    for pi, p in sub.pts:
      let q = c.toScreen(p.x, p.y)
      if abs(q.x - sx) <= HandleR + 3 and abs(q.y - sy) <= HandleR + 3: return (si, pi, 0)
  (-1, -1, -1)

proc insertNodeAt(c: VectorCanvas, s: VShape, sx, sy: float): bool =
  # Double-click on a segment: adds a node (straight or curved segment).
  let p = c.toScene(sx, sy)
  let tol = 6 / c.zoom
  for si, sub in s.subs.mpairs:
    let n = sub.pts.len
    let segs = if sub.closed: n else: n - 1
    for i in 0 ..< segs:
      let a = sub.pts[i]
      let b = sub.pts[(i + 1) mod n]
      let p0 = (a.x, a.y)
      let p1 = (a.x + a.ox, a.y + a.oy)
      let p2 = (b.x + b.ix, b.y + b.iy)
      let p3 = (b.x, b.y)
      var best = Inf
      var bt = 0.0
      for k in 0 .. 40:
        let t = k.float / 40
        let q = cubicPtPub(p0, p1, p2, p3, t)
        let dd = hypot(q.x - p.x, q.y - p.y)
        if dd < best:
          best = dd; bt = t
      if best <= tol:
        # de Casteljau subdivision
        let t = bt
        proc lerp(u, v: FPoint, t: float): FPoint = (u.x + (v.x - u.x) * t, u.y + (v.y - u.y) * t)
        let q01 = lerp(p0, p1, t)
        let q12 = lerp(p1, p2, t)
        let q23 = lerp(p2, p3, t)
        let q012 = lerp(q01, q12, t)
        let q123 = lerp(q12, q23, t)
        let m = lerp(q012, q123, t)
        let curve = a.ox != 0 or a.oy != 0 or b.ix != 0 or b.iy != 0
        var np = VPt(x: m.x, y: m.y, smooth: curve)
        if curve:
          sub.pts[i].ox = q01.x - a.x
          sub.pts[i].oy = q01.y - a.y
          np.ix = q012.x - m.x
          np.iy = q012.y - m.y
          np.ox = q123.x - m.x
          np.oy = q123.y - m.y
          sub.pts[(i + 1) mod n].ix = q23.x - b.x
          sub.pts[(i + 1) mod n].iy = q23.y - b.y
        sub.pts.insert(np, i + 1)
        c.nodeSub = si
        c.nodeIdx = i + 1
        return true
  false

method onMouse*(c: VectorCanvas, e: MouseEvent) =
  let lx = e.x - c.rect.x
  let ly = e.y - c.rect.y
  case e.action
  of maPress:
    c.startX = lx
    c.startY = ly
    c.curX = lx
    c.curY = ly
    c.moved = false
    c.snapLines.setLen(0)
    if c.mode == vmEdit and c.win != nil: setFocusInternal(c.win, c)
    # main : bouton du milieu, Espace, outil main, fond en galerie
    if e.button == mbMiddle or (e.button == mbLeft and (c.spaceDown or c.tool == vtHand)):
      c.drag = vdPan
      c.origPanX = c.panX
      c.origPanY = c.panY
      return
    if e.button == mbRight:
      let s = c.shapeAt(e.x, e.y, c.mode != vmEdit)
      if s != nil and s.id notin c.selection:
        c.setSelection(if c.mode == vmEdit: c.selectableIds(s) else: @[s.id])
      emit(c, evRightClick, text = (if s == nil: "" elif c.mode in {vmGallery, vmBoard} and s.group.len > 0: s.group else: s.id),
           x = e.x, y = e.y, button = mbRight)
      return
    if e.button != mbLeft: return
    case c.mode
    of vmView:
      let s = c.shapeAt(e.x, e.y, true)
      emit(c, evSelection, text = (if s == nil: "" else: (if s.data.len > 0: s.data else: s.id)))
      return
    of vmGallery, vmBoard:
      let s = c.shapeAt(e.x, e.y, true)
      if s == nil:
        c.setSelection(@[])
        c.drag = vdPan
        c.origPanX = c.panX
        c.origPanY = c.panY
        return
      let ids = c.selectableIds(s)
      if ids != c.selection:
        c.selection = ids
        markDirty(c)
      emit(c, evSelection, text = (if s.group.len > 0: s.group else: s.id))
      if e.clicks >= 2:
        emit(c, evDoubleClick, text = (if s.group.len > 0: s.group else: s.id))
        return
      if c.mode == vmBoard:
        c.drag = vdMove
        c.dragGroup = s.group
        c.origShapes.setLen(0)
        for x in c.selectedShapes: c.origShapes.add x.clone
        c.origBox = c.selectionBox
      return
    of vmEdit: discard
    let p = c.toScene(e.x, e.y)
    # text entry in progress: click outside the text = finish
    if c.editText.len > 0:
      let s = c.scene.findShape(c.editText)
      if s != nil and s.hitShape(p.x, p.y, 2 / c.zoom):
        # place le curseur en fin de ligne cliquée (approximation)
        return
      c.endTextEdit
    # pen
    if c.tool == vtPen:
      let q = c.snapPoint(p)
      if c.penShape == nil:
        c.penShape = newShape(vkPath)
        c.penShape.fill = c.newFill
        c.penShape.stroke = (if c.newStroke == "none": "#1f2937" else: c.newStroke)
        c.penShape.strokeWidth = max(1.0, c.newStrokeWidth)
        c.penShape.subs = @[VSub(pts: @[VPt(x: q.x, y: q.y)])]
      else:
        let first = c.penShape.subs[0].pts[0]
        let fs = c.toScreen(first.x, first.y)
        if c.penShape.subs[0].pts.len >= 3 and hypot(fs.x - e.x, fs.y - e.y) <= HandleR + 4:
          c.finishPen(true)
          c.drag = vdNone
          return
        if e.clicks >= 2:
          c.finishPen(false)
          return
        c.penShape.subs[0].pts.add VPt(x: q.x, y: q.y)
      c.drag = vdPenHandle
      markDirty(c)
      return
    #  nodes
    if c.tool == vtNodes or c.nodeId.len > 0:
      let target = c.scene.findShape(if c.nodeId.len > 0: c.nodeId elif c.selection.len == 1: c.selection[0] else: "")
      if target != nil and target.kind in {vkPath, vkLine}:
        let h = c.nodeHit(target, e.x, e.y)
        if h.part >= 0:
          if e.clicks >= 2 and h.part == 0:
            c.pushUndo
            var pt = addr target.subs[h.sub].pts[h.idx]
            if pt.ix != 0 or pt.iy != 0 or pt.ox != 0 or pt.oy != 0:
              pt.ix = 0; pt.iy = 0; pt.ox = 0; pt.oy = 0; pt.smooth = false
            else:
              # smoothed: handles aligned with the tangent of the neighbors
              let sub = target.subs[h.sub]
              let n = sub.pts.len
              let prv = sub.pts[(h.idx - 1 + n) mod n]
              let nxt = sub.pts[(h.idx + 1) mod n]
              let tx = (nxt.x - prv.x) / 6
              let ty = (nxt.y - prv.y) / 6
              pt.ix = -tx; pt.iy = -ty; pt.ox = tx; pt.oy = ty; pt.smooth = true
            target.syncPathBox
            c.invalidate
            c.emitChange("noeud", @[target.id])
            return
          c.nodeId = target.id
          c.nodeSub = h.sub
          c.nodeIdx = h.idx
          c.drag = case h.part
                   of 1: vdHandleIn
                   of 2: vdHandleOut
                   else: vdNode
          c.origShapes = @[target.clone]
          markDirty(c)
          return
        if e.clicks >= 2 and target.hitShape(p.x, p.y, 5 / c.zoom):
          c.pushUndo
          if c.insertNodeAt(target, e.x, e.y):
            target.syncPathBox
            c.invalidate
            c.emitChange("noeud", @[target.id])
          return
      let s = c.shapeAt(e.x, e.y)
      if s != nil and s.kind in {vkPath, vkLine}:
        c.nodeId = s.id
        c.nodeIdx = -1
        c.setSelection(@[s.id])
        return
      if c.tool != vtNodes:
        c.nodeId = ""
        c.nodeIdx = -1
    # creation
    if c.tool in {vtRect, vtEllipse, vtLine, vtArrow, vtText, vtImage}:
      let q = c.snapPoint(p)
      var s: VShape
      case c.tool
      of vtRect:
        s = newShape(vkRect)
      of vtEllipse:
        s = newShape(vkEllipse)
      of vtLine, vtArrow:
        s = newShape(vkLine)
        s.subs = @[VSub(pts: @[VPt(x: q.x, y: q.y), VPt(x: q.x, y: q.y)])]
        s.fill = "none"
        s.stroke = (if c.newStroke == "none" or c.newStroke.len == 0: "#1f2937" else: c.newStroke)
        s.strokeWidth = max(1.0, c.newStrokeWidth)
        s.arrowEnd = c.tool == vtArrow
      of vtText:
        s = newShape(vkText)
        s.text = ""
        s.font = c.newFont
        s.fontSize = c.newFontSize
        s.fill = "#1f2937"
      of vtImage:
        s = newShape(vkImage)
        s.href = c.pendingHref
        s.data = c.pendingData
        s.fill = "none"
      else: discard
      if s.kind in {vkRect, vkEllipse}:
        s.fill = c.newFill
        s.stroke = c.newStroke
        s.strokeWidth = c.newStrokeWidth
      s.x = q.x
      s.y = q.y
      s.w = 0
      s.h = 0
      s.layer = if c.scene.layers.len > 0: c.scene.layers[^1].name else: "Calque 1"
      c.created = s
      c.drag = vdCreate
      markDirty(c)
      return
    # selection
    let hi = c.handleAt(e.x, e.y)
    if hi >= 0:
      c.drag = vdResize
      c.handle = hi
      c.origBox = c.selectionBox
      c.origShapes.setLen(0)
      for s in c.selectedShapes: c.origShapes.add s.clone
      return
    let s = c.shapeAt(e.x, e.y)
    if e.clicks >= 2 and s != nil:
      if s.kind == vkText:
        c.beginTextEdit(s.id)
      elif s.kind in {vkPath, vkLine} and s.group.len == 0:
        c.nodeId = s.id
        c.nodeIdx = -1
        c.setSelection(@[s.id])
      emit(c, evDoubleClick, text = s.id)
      return
    if s == nil:
      if (e.mods and KMOD_SHIFT) == 0: c.setSelection(@[])
      c.drag = vdRubber
      return
    let ids = c.selectableIds(s)
    if (e.mods and KMOD_SHIFT) != 0:
      var cur = c.selection
      if s.id in cur:
        cur = cur.filterIt(it notin ids)
      else:
        for id in ids:
          if id notin cur: cur.add id
      c.setSelection(cur)
      return
    if s.id notin c.selection: c.setSelection(ids)
    c.drag = vdMove
    c.origShapes.setLen(0)
    for x in c.selectedShapes: c.origShapes.add x.clone
    c.origBox = c.selectionBox
  of maMove:
    c.curX = lx
    c.curY = ly
    if abs(lx - c.startX) + abs(ly - c.startY) > 2: c.moved = true
    case c.drag
    of vdNone:
      let s = c.shapeAt(e.x, e.y, c.mode != vmEdit)
      let hid = if s == nil: "" else: s.id
      if hid != c.hoverId:
        c.hoverId = hid
        markDirty(c)
      if c.penShape != nil: markDirty(c)
    of vdPan:
      c.panX = c.origPanX + (lx - c.startX)
      c.panY = c.origPanY + (ly - c.startY)
      if c.mode in {vmGallery, vmBoard}: c.panX = c.origPanX
      markDirty(c)
    of vdMove:
      if not c.moved or c.origShapes.len == 0: return
      var dx = (lx - c.startX) / c.zoom
      var dy = (ly - c.startY) / c.zoom
      if c.mode == vmEdit:
        if (SDL_GetModState() and KMOD_SHIFT) != 0:
          if abs(dx) > abs(dy): dy = 0 else: dx = 0
        c.snapMove(c.origBox, dx, dy)
      for o in c.origShapes:
        let s = c.scene.findShape(o.id)
        if s == nil or (c.mode == vmEdit and c.scene.layerLocked(s)): continue
        let b0 = o.bounds
        let b1 = s.bounds
        s.moveShape(b0.x + dx - b1.x, b0.y + dy - b1.y)
      markDirty(c)
    of vdResize:
      if not c.moved: return
      let p = c.toScene(e.x, e.y)
      var b = c.origBox
      let keep = (SDL_GetModState() and KMOD_SHIFT) != 0
      if c.handle in [10, 11]:
        let s = c.scene.findShape(c.selection[0])
        if s != nil and s.subs.len > 0:
          var q = c.snapPoint(p)
          let other = if c.handle == 10: s.subs[0].pts[^1] else: s.subs[0].pts[0]
          if keep:
            let ang = round(arctan2(q.y - other.y, q.x - other.x) / (PI / 4)) * (PI / 4)
            let L = hypot(q.x - other.x, q.y - other.y)
            q = (other.x + L * cos(ang), other.y + L * sin(ang))
          if c.handle == 10:
            s.subs[0].pts[0].x = q.x; s.subs[0].pts[0].y = q.y
          else:
            s.subs[0].pts[^1].x = q.x; s.subs[0].pts[^1].y = q.y
          s.syncPathBox
          inc c.scene.version
        markDirty(c)
        return
      let q = c.snapPoint(p)
      var x0 = b.x
      var y0 = b.y
      var x1 = b.x + b.w
      var y1 = b.y + b.h
      if c.handle in [0, 6, 7]: x0 = q.x
      if c.handle in [2, 3, 4]: x1 = q.x
      if c.handle in [0, 1, 2]: y0 = q.y
      if c.handle in [4, 5, 6]: y1 = q.y
      if keep and b.w > 0 and b.h > 0 and c.handle in [0, 2, 4, 6]:
        let ratio = b.w / b.h
        let nw = abs(x1 - x0)
        let nh = abs(y1 - y0)
        if nw / max(nh, 1e-9) > ratio:
          let hh = nw / ratio
          if c.handle in [0, 2]: y0 = y1 - hh * sgn(y1 - y0).float else: y1 = y0 + hh * sgn(y1 - y0).float
        else:
          let ww = nh * ratio
          if c.handle in [0, 6]: x0 = x1 - ww * sgn(x1 - x0).float else: x1 = x0 + ww * sgn(x1 - x0).float
      let nb = (x: min(x0, x1), y: min(y0, y1), w: max(1.0, abs(x1 - x0)), h: max(1.0, abs(y1 - y0)))
      for o in c.origShapes:
        let s = c.scene.findShape(o.id)
        if s == nil: continue
        let ob = o.rawBounds
        # shape box within the new selection box (proportional)
        let fx = (ob.x - b.x) / max(b.w, 1e-9)
        let fy = (ob.y - b.y) / max(b.h, 1e-9)
        let fw = ob.w / max(b.w, 1e-9)
        let fh = ob.h / max(b.h, 1e-9)
        let dst = (x: nb.x + fx * nb.w, y: nb.y + fy * nb.h, w: max(0.5, fw * nb.w), h: max(0.5, fh * nb.h))
        s[] = o[]
        if s.kind == vkText:
          s.x = dst.x
          s.y = dst.y
          if o.w > 0 or c.handle in [2, 3, 4, 0, 6, 7]: s.w = max(10.0, dst.w)
          if keep and o.textBoxWidth > 0: s.fontSize = o.fontSize * dst.w / o.textBoxWidth
          s.fitTextHeight
        else:
          s.scaleShape(ob, dst)
      inc c.scene.version
      markDirty(c)
    of vdRubber:
      markDirty(c)
    of vdCreate:
      let s = c.created
      if s == nil: return
      var q = c.snapPoint(c.toScene(e.x, e.y))
      let p0 = c.toScene(c.startX + c.rect.x, c.startY + c.rect.y)
      let keep = (SDL_GetModState() and KMOD_SHIFT) != 0
      if s.kind == vkLine:
        if keep:
          let o = s.subs[0].pts[0]
          let ang = round(arctan2(q.y - o.y, q.x - o.x) / (PI / 4)) * (PI / 4)
          let L = hypot(q.x - o.x, q.y - o.y)
          q = (o.x + L * cos(ang), o.y + L * sin(ang))
        s.subs[0].pts[1].x = q.x
        s.subs[0].pts[1].y = q.y
        s.syncPathBox
      else:
        var w = q.x - s.subs.len.float * 0 - p0.x
        var h = q.y - p0.y
        if keep or (s.kind == vkImage and c.pendingRatio > 0):
          let ratio = if s.kind == vkImage and c.pendingRatio > 0: c.pendingRatio else: 1.0
          let m = max(abs(w), abs(h) * ratio)
          w = m * float(sgn(w) + (if w == 0: 1 else: 0))
          h = m / ratio * float(sgn(h) + (if h == 0: 1 else: 0))
        let sp = c.snapPoint(p0)
        s.x = min(sp.x, sp.x + w)
        s.y = min(sp.y, sp.y + h)
        s.w = abs(w)
        s.h = abs(h)
      markDirty(c)
    of vdNode, vdHandleIn, vdHandleOut:
      let s = c.scene.findShape(c.nodeId)
      if s == nil or c.nodeSub < 0 or c.nodeSub >= s.subs.len: return
      if c.nodeIdx < 0 or c.nodeIdx >= s.subs[c.nodeSub].pts.len: return
      var pt = addr s.subs[c.nodeSub].pts[c.nodeIdx]
      let p = c.toScene(e.x, e.y)
      if c.drag == vdNode:
        let q = c.snapPoint(p)
        pt.x = q.x
        pt.y = q.y
      elif c.drag == vdHandleIn:
        pt.ix = p.x - pt.x
        pt.iy = p.y - pt.y
        if pt.smooth and (SDL_GetModState() and KMOD_ALT) == 0:
          let L = hypot(pt.ox, pt.oy)
          let k = hypot(pt.ix, pt.iy)
          if k > 1e-9:
            pt.ox = -pt.ix / k * L
            pt.oy = -pt.iy / k * L
      else:
        pt.ox = p.x - pt.x
        pt.oy = p.y - pt.y
        if pt.smooth and (SDL_GetModState() and KMOD_ALT) == 0:
          let L = hypot(pt.ix, pt.iy)
          let k = hypot(pt.ox, pt.oy)
          if k > 1e-9:
            pt.ix = -pt.ox / k * L
            pt.iy = -pt.oy / k * L
      s.syncPathBox
      inc c.scene.version
      markDirty(c)
    of vdPenHandle:
      if c.penShape == nil or not c.moved: return
      let p = c.toScene(e.x, e.y)
      var pt = addr c.penShape.subs[0].pts[^1]
      pt.ox = p.x - pt.x
      pt.oy = p.y - pt.y
      pt.ix = -pt.ox
      pt.iy = -pt.oy
      pt.smooth = true
      markDirty(c)
  of maRelease:
    let drag = c.drag
    c.drag = vdNone
    c.snapLines.setLen(0)
    case drag
    of vdMove:
      if c.moved and c.origShapes.len > 0:
        # The undo operation restores the state that existed before the drag.
        let after = c.scene.cloneScene
        for o in c.origShapes:
          let s = c.scene.findShape(o.id)
          if s != nil: s[] = o[]
        c.pushUndo
        c.scene = after
        c.scene.base = c.scene.base
        c.invalidate
        if c.mode == vmBoard:
          c.emitChange("deplace:" & c.dragGroup, c.selection)
        else:
          c.emitChange("deplace", c.selection)
      c.origShapes.setLen(0)
      markDirty(c)
    of vdResize:
      if c.moved:
        let after = c.scene.cloneScene
        for o in c.origShapes:
          let s = c.scene.findShape(o.id)
          if s != nil: s[] = o[]
        c.pushUndo
        c.scene = after
        c.invalidate
        c.emitChange("redimension", c.selection)
      c.origShapes.setLen(0)
      markDirty(c)
    of vdNode, vdHandleIn, vdHandleOut:
      if c.moved and c.origShapes.len > 0:
        let s = c.scene.findShape(c.nodeId)
        if s != nil:
          let after = s.clone
          s[] = c.origShapes[0][]
          c.pushUndo
          s[] = after[]
        c.invalidate
        c.emitChange("noeud", @[c.nodeId])
      c.origShapes.setLen(0)
    of vdRubber:
      if c.moved:
        let a = c.toScene(min(c.startX, c.curX) + c.rect.x, min(c.startY, c.curY) + c.rect.y)
        let b = c.toScene(max(c.startX, c.curX) + c.rect.x, max(c.startY, c.curY) + c.rect.y)
        var ids = if (e.mods and KMOD_SHIFT) != 0: c.selection else: @[]
        for s in c.scene.shapes:
          if not c.scene.layerVisible(s) or c.scene.layerLocked(s): continue
          let o = s.bounds
          if o.x >= a.x and o.y >= a.y and o.x + o.w <= b.x and o.y + o.h <= b.y:
            for id in c.selectableIds(s):
              if id notin ids: ids.add id
        c.setSelection(ids)
      markDirty(c)
    of vdCreate:
      let s = c.created
      c.created = nil
      if s == nil: return
      if not c.moved:
        # single click: default size
        case s.kind
        of vkText: s.w = 0
        of vkLine:
          s.subs[0].pts[1].x = s.subs[0].pts[0].x + 160
          s.syncPathBox
        of vkImage:
          s.w = 240
          s.h = if c.pendingRatio > 0: 240 / c.pendingRatio else: 160
        else:
          s.w = 160
          s.h = 100
      elif s.kind == vkText and s.w < 20: s.w = 0
      c.pushUndo
      c.addShape(s)
      c.emitChange("creation", @[s.id])
      if s.kind == vkText:
        c.editText = s.id
        c.caret = 0
        c.tool = vtSelect
      elif not c.stickyTool:
        c.tool = vtSelect
      markDirty(c)
    of vdPenHandle:
      markDirty(c)
    else: markDirty(c)

method onWheel*(c: VectorCanvas, dx, dy: float): bool =
  let mods = SDL_GetModState()
  if c.mode == vmView: return false
  if c.mode == vmEdit and (mods and (KMOD_CTRL or KMOD_GUI)) != 0:
    let f = if dy > 0: 1.12 elif dy < 0: 1 / 1.12 else: 1.0
    if f == 1.0: return false
    c.setZoomAt(c.zoom * f, c.rect.x + c.curX, c.rect.y + c.curY)
    markDirty(c)
    return true
  if (mods and KMOD_SHIFT) != 0 or (dx != 0 and dy == 0):
    c.panX += (if dx != 0: dx else: dy) * 40
  else:
    c.panY += dy * 40
    c.panX += dx * 40
  if c.mode in {vmGallery, vmBoard}:
    let maxPan = 8.0
    let minPan = min(8.0, c.rect.h - c.scene.height * c.zoom - 8)
    c.panY = clamp(c.panY, minPan, maxPan)
    if c.mode == vmGallery: c.panX = c.panX.clamp(min(8.0, c.rect.w - c.scene.width * c.zoom - 8), 8)
  markDirty(c)
  true

#
# keyboard
#

proc prevRune(s: string, i: int): int =
  var k = i - 1
  while k > 0 and (ord(s[k]) and 0xC0) == 0x80: dec k
  max(0, k)

proc nextRune(s: string, i: int): int =
  var k = i + 1
  while k < s.len and (ord(s[k]) and 0xC0) == 0x80: inc k
  min(s.len, k)

method onText*(c: VectorCanvas, s: string) =
  if c.editText.len == 0: return
  let sh = c.scene.findShape(c.editText)
  if sh == nil: return
  c.caret = clamp(c.caret, 0, sh.text.len)
  sh.text.insert(s, c.caret)
  c.caret += s.len
  sh.fitTextHeight
  c.invalidate

method onKey*(c: VectorCanvas, e: KeyEvent): bool =
  if c.mode != vmEdit: return false
  let cmd = (e.mods and (KMOD_CTRL or KMOD_GUI)) != 0
  let shift = (e.mods and KMOD_SHIFT) != 0
  # text entry
  if c.editText.len > 0:
    let sh = c.scene.findShape(c.editText)
    if sh == nil:
      c.editText = ""
      return false
    case e.key
    of SDLK_ESCAPE:
      c.endTextEdit
      return true
    of SDLK_BACKSPACE:
      if c.caret > 0:
        let k = prevRune(sh.text, c.caret)
        sh.text.delete(k .. c.caret - 1)
        c.caret = k
        sh.fitTextHeight
        c.invalidate
      return true
    of SDLK_DELETE:
      if c.caret < sh.text.len:
        let k = nextRune(sh.text, c.caret)
        sh.text.delete(c.caret .. k - 1)
        sh.fitTextHeight
        c.invalidate
      return true
    of SDLK_LEFT:
      c.caret = prevRune(sh.text, c.caret)
      markDirty(c)
      return true
    of SDLK_RIGHT:
      c.caret = nextRune(sh.text, c.caret)
      markDirty(c)
      return true
    of SDLK_HOME:
      c.caret = 0
      markDirty(c)
      return true
    of SDLK_END:
      c.caret = sh.text.len
      markDirty(c)
      return true
    of SDLK_RETURN, SDLK_KP_ENTER:
      if cmd:
        c.endTextEdit
      else:
        sh.text.insert("\n", c.caret)
        inc c.caret
        sh.fitTextHeight
        c.invalidate
      return true
    of SDLK_A:
      if cmd:
        c.caret = sh.text.len
        return true
    else: discard
    return false
  case e.key
  of SDLK_SPACE:
    if not c.spaceDown:
      c.spaceDown = true
      markDirty(c)
    return true
  of SDLK_ESCAPE:
    if c.penShape != nil:
      c.finishPen(false)
      return true
    if c.nodeId.len > 0:
      c.nodeId = ""
      c.nodeIdx = -1
      markDirty(c)
      return true
    if c.tool != vtSelect:
      c.tool = vtSelect
      emit(c, evChange, text = "outil")
      c.lastAction = "outil"
      return true
    c.setSelection(@[])
    return true
  of SDLK_RETURN, SDLK_KP_ENTER:
    if c.penShape != nil:
      c.finishPen(false)
      return true
    if c.selection.len == 1:
      let s = c.scene.findShape(c.selection[0])
      if s != nil and s.kind == vkText:
        c.beginTextEdit(s.id)
        return true
  of SDLK_DELETE, SDLK_BACKSPACE:
    if c.nodeId.len > 0 and c.nodeIdx >= 0:
      let s = c.scene.findShape(c.nodeId)
      if s != nil and c.nodeSub < s.subs.len and s.subs[c.nodeSub].pts.len > 2:
        c.pushUndo
        s.subs[c.nodeSub].pts.delete(c.nodeIdx)
        c.nodeIdx = -1
        s.syncPathBox
        c.invalidate
        c.emitChange("noeud", @[s.id])
        return true
    if c.selection.len > 0:
      c.deleteSelection
      return true
  of SDLK_LEFT:
    c.nudge(if shift: -10 else: -1, 0)
    return true
  of SDLK_RIGHT:
    c.nudge(if shift: 10 else: 1, 0)
    return true
  of SDLK_UP:
    if cmd:
      c.reorder(if shift: "premierplan" else: "avant")
    else:
      c.nudge(0, if shift: -10 else: -1)
    return true
  of SDLK_DOWN:
    if cmd:
      c.reorder(if shift: "arriereplan" else: "arriere")
    else:
      c.nudge(0, if shift: 10 else: 1)
    return true
  else: discard
  if cmd:
    case e.key
    of SDLK_A:
      var ids: seq[string]
      for s in c.scene.shapes:
        if c.scene.layerVisible(s) and not c.scene.layerLocked(s): ids.add s.id
      c.setSelection(ids)
      return true
    of SDLK_C:
      c.copySelection
      return true
    of SDLK_X:
      c.copySelection
      c.deleteSelection
      return true
    of SDLK_V:
      c.paste
      return true
    of 0x64'u32:   # d
      c.duplicateSelection
      return true
    of 0x7A'u32:   # z
      if shift: c.redo else: c.undo
      return true
    of 0x79'u32:   # y
      c.redo
      return true
    of 0x67'u32:   # g
      if shift: c.ungroupSelection else: c.groupSelection
      return true
    of 0x30'u32:   # 0 : ajuster
      c.fit
      markDirty(c)
      return true
    of 0x31'u32:   # 1 : 100 %
      c.setZoomAt(1, c.rect.x + c.rect.w / 2, c.rect.y + c.rect.h / 2)
      markDirty(c)
      return true
    else: discard
  false

method onKeyUp*(c: VectorCanvas, e: KeyEvent) =
  if e.key == SDLK_SPACE and c.spaceDown:
    c.spaceDown = false
    markDirty(c)

method onFocus*(c: VectorCanvas, gained: bool) =
  if not gained:
    c.spaceDown = false

method dispose*(c: VectorCanvas) =
  if c.tex != nil: SDL_DestroyTexture(c.tex)
  if c.selTex != nil: SDL_DestroyTexture(c.selTex)
  c.tex = nil
  c.selTex = nil

#
# pages, thumbnails
#

proc loadPages*(c: VectorCanvas, pages: seq[VScene], cols = 1, gap = 28.0, captions: seq[string] = @[],
                selected = -1) =
  # Arrange pages (or slides) into a layout: each page is a group
  # named "page-N" (white background with a drop shadow, content, and an optional caption).
  let sc = newScene(100, 100)
  sc.background = ""
  var maxW, maxH = 0.0
  for p in pages:
    maxW = max(maxW, p.width)
    maxH = max(maxH, p.height)
  let ncol = max(1, cols)
  let capH = if captions.len > 0: max(18.0, maxW * 0.06) * 1.9 else: 0.0
  for i, p in pages:
    let col = i mod ncol
    let row = i div ncol
    let ox = gap + col.float * (maxW + gap) + (maxW - p.width) / 2
    let oy = gap + row.float * (maxH + gap + capH)
    let g = "page-" & $(i + 1)
    let bg = newShape(vkRect)
    bg.x = ox; bg.y = oy; bg.w = p.width; bg.h = p.height
    bg.fill = (if p.background.len > 0: p.background else: "#ffffff")
    bg.stroke = (if i == selected: "#4f7cff" else: "#e2e8f0")
    bg.strokeWidth = (if i == selected: max(3.0, maxW * 0.006) else: 0.8)
    bg.shadow = true
    bg.group = g
    bg.layer = "Calque 1"
    bg.data = "page:" & $(i + 1)
    sc.shapes.add bg
    for s in p.shapes:
      if not p.layerVisible(s): continue
      let n = s.clone
      n.moveShape(ox, oy)
      n.group = g
      n.layer = "Calque 1"
      n.locked = false
      if n.kind == vkImage and n.href.len > 0 and not n.href.startsWith("data:") and not n.href.isAbsolute and p.base.len > 0:
        n.href = p.base / n.href
      sc.shapes.add n
    if i < captions.len and captions[i].len > 0:
      let t = newShape(vkText)
      t.text = captions[i]
      t.font = "Poppins"
      t.fontSize = max(14.0, maxW * 0.06)
      t.fill = "#CBD5E1"
      t.x = ox
      t.y = oy + p.height + capH * 0.18
      t.w = p.width
      t.lineHeight = 1.2
      t.group = g
      t.layer = "Calque 1"
      t.fitTextHeight
      # legend too long: reduce the font size rather than cutting off the second line
      var essais = 0
      while t.h > capH * 0.8 and essais < 6:
        t.fontSize = t.fontSize * 0.85
        t.fitTextHeight
        inc essais
      if t.h > capH * 0.8:
        t.h = capH * 0.8
      sc.shapes.add t
  let rows = (pages.len + ncol - 1) div ncol
  sc.width = gap + ncol.float * (maxW + gap)
  sc.height = gap + rows.float * (maxH + gap + capH)
  let v = c.scene.version
  c.scene = sc
  c.scene.version = v + 1
  c.selection.setLen(0)
  c.clearHistory
  c.needFit = true
