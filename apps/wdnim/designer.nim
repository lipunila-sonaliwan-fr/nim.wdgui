# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
# Form designer of wdnim.
#
# * Palette (left): drag a layout or a control onto the form (or click it to add it to the
#   selected container). Custom controls derived from existing ones come from the project's
#   wdnim_palette.json (Custom Control… adds one).
# * Canvas (center): a live preview built with the real wdgui controls. Click to select, drag
#   to move (reorder / reparent in layouts, free position in absolute layouts), handles to
#   resize. Magenta guides snap to the edges and centers of the other controls, to their
#   widths / heights and to proportions of the container (¼, ⅓, ½, ⅔, ¾, full).
# * Hierarchy (right, top): the tree of the form; Up / Down change the display order,
#   Out moves a control out of its container.
# * Inspector (right): every property is edited directly; the Events section associates an
#   existing handler of the edited code, removes an association, or creates a new handler
#   stub in the code.
# * Every change regenerates form_<name>.nim and the registrations in the edited code.
import std/[strutils, os, math]
import ../../src/wdgui
import formmodel, editor

type
  DragMode = enum
    dmNone, dmMove, dmResize, dmNew
  Guide = tuple[x1, y1, x2, y2: float]

  FormCanvas* = ref object of Container
    model*: FormModel
    selected*: DNode
    hoverNode: DNode
    formRoot: Container
    links: seq[tuple[ctl: Control, node: DNode]]
    drag: DragMode
    handle: int
    startX, startY: float
    startRect: Rect
    moved: bool
    newKind: string
    ghost: Rect
    dropParent: DNode
    dropIndex: int
    dropDock: string
    dropPos: Point
    dropMark: Rect
    dropValid: bool
    guides: seq[Guide]
    sizeLabel: string

  PaletteView* = ref object of Control
    canvas*: FormCanvas
    hoverIdx, pressIdx: int
    pressX, pressY: float
    dragging: bool
    scroll: float

const
  originX = 40.0
  originY = 66.0
  titleH = 28.0
  snapDist = 6.0
  guideColor = Color(r: 255, g: 45, b: 149, a: 255)
  selColor = Color(r: 59, g: 130, b: 246, a: 255)

# property parsing (preview)

proc pf(n: DNode, k: string): float =
  try:
    result = parseFloat(n.getProp(k).strip)
  except ValueError:
    result = 0

proc pi(n: DNode, k: string): int =
  try:
    result = parseInt(n.getProp(k).strip)
  except ValueError:
    result = 0

proc pb(n: DNode, k: string): bool = n.getProp(k).strip.toLowerAscii in ["true", "1", "yes"]

proc plist(n: DNode, k: string): seq[string] =
  for x in n.getProp(k).split(';'):
    if x.strip.len > 0: result.add x.strip

proc layoutOf(s: string): LayoutKind =
  case s
  of "lkHorizontal": lkHorizontal
  of "lkGrid": lkGrid
  of "lkFlow": lkFlow
  of "lkBorder": lkBorder
  of "lkStack": lkStack
  of "lkAbsolute": lkAbsolute
  else: lkVertical

proc alignOf(s: string): Alignment =
  case s
  of "alCenter": alCenter
  of "alRight": alRight
  else: alLeft

proc inputKindOf(s: string): InputKind =
  case s
  of "ikInteger": ikInteger
  of "ikReal": ikReal
  of "ikPassword": ikPassword
  else: ikText

proc shapeOf(s: string): ShapeKind =
  case s
  of "skRectangle": skRectangle
  of "skEllipse": skEllipse
  of "skHLine": skHLine
  of "skVLine": skVLine
  of "skDiagonal": skDiagonal
  else: skRoundRect

proc imageModeOf(s: string): ImageMode =
  case s
  of "imCenter": imCenter
  of "imStretch": imStretch
  else: imFit

proc chartOf(s: string): ChartKind =
  case s
  of "ckLine": ckLine
  of "ckArea": ckArea
  of "ckPie": ckPie
  else: ckColumn

proc scrollbarsOf(s: string): ScrollbarMode =
  case s
  of "smAutomatic": smAutomatic
  of "smHidden": smHidden
  else: smAlways

proc dockOf(s: string): Dock =
  case s
  of "dkTop": dkTop
  of "dkBottom": dkBottom
  of "dkLeft": dkLeft
  of "dkRight": dkRight
  else: dkCenter

proc validColor(s: string): bool =
  let h = s.strip
  h.startsWith("#") and h.len in [7, 9] and h[1 .. ^1].allCharsInSet(HexDigits)

proc nodeLayout(n: DNode): string =
  case baseOf(n.kind)
  of "Toolbar": "lkHorizontal"
  of "Tab": "tab"
  of "Splitter": "splitter"
  else: (if n.kind == "Window" or isContainerKind(n.kind): n.getProp("layout") else: "")

# preview construction

proc makeControl(n: DNode): Control =
  case baseOf(n.kind)
  of "Container": result = newContainer(layoutOf(n.getProp("layout")), n.pf("margin"), n.pf("spacing"), n.pi("columns"))
  of "Cell": result = newCell(layoutOf(n.getProp("layout")), n.getProp("caption"), n.pi("columns"))
  of "Panel": result = newPanel(layoutOf(n.getProp("layout")), scrollbarsOf(n.getProp("scrollbars")),
                                n.pf("margin"), n.pf("spacing"), n.pi("columns"))
  of "Splitter": result = newSplitter(n.pb("vertical"), n.pf("position"))
  of "Tab": result = newTab()
  of "Toolbar": result = newToolbar()
  of "Label": result = newLabel(n.getProp("caption"), alignOf(n.getProp("alignment")), n.pb("isLink"))
  of "Button":
    let b = newButton(n.getProp("caption"), isDefault = n.pb("isDefault"), isCancel = n.pb("isCancel"))
    b.flat = n.pb("flat")
    result = b
  of "Edit": result = newEdit(n.getProp("text"), inputKindOf(n.getProp("inputKind")), n.pb("multiline"),
                              n.getProp("placeholder"))
  of "Spin": result = newSpin(n.pf("value"), n.pf("minValue"), n.pf("maxValue"), n.pf("step"))
  of "CheckBox": result = newCheckBox(n.getProp("caption"), n.pb("checked"), n.pb("switchStyle"))
  of "RadioButton": result = newRadioButton(n.plist("options"), n.pi("selection"), n.pb("horizontal"))
  of "ComboBox": result = newComboBox(n.plist("items"), n.pi("selection"))
  of "ListBox": result = newListBox(n.plist("items"), n.pb("multiSelection"))
  of "Slider": result = newSlider(n.pf("value"), n.pf("minValue"), n.pf("maxValue"), n.pf("step"), n.pb("vertical"))
  of "RangeSlider": result = newRangeSlider(n.pf("lower"), n.pf("upper"), n.pf("minValue"), n.pf("maxValue"))
  of "ProgressBar": result = newProgressBar(n.pf("value"), n.pf("minValue"), n.pf("maxValue"), n.pb("showText"))
  of "Rating": result = newRating(n.pf("value"), max(1, n.pi("maxValue")))
  of "Scrollbar": result = newScrollbar(n.pb("vertical"), n.pf("minValue"), n.pf("maxValue"), n.pf("pageSize"))
  of "Shape": result = newShape(shapeOf(n.getProp("shapeKind")), max(1.0, n.pf("thickness")))
  of "Image": result = newImage(n.getProp("path"), imageModeOf(n.getProp("mode")))
  of "BarCode": result = newBarCode(n.getProp("text"))
  of "Calendar": result = newCalendar(n.getProp("date"))
  of "Chart": result = newChart(chartOf(n.getProp("chartKind")), n.getProp("title"))
  of "TreeView": result = newTreeView()
  of "Table":
    let t = newTable(multiSelection = n.pb("multiSelection"))
    for c in n.plist("tableColumns"): t.addColumn(c)
    result = t
  of "Grid":
    let g = newGrid(multiSelection = n.pb("multiSelection"), editable = n.pb("editable"))
    for c in n.plist("gridColumns"):
      let parts = c.split(':')
      discard g.addColumn(parts[0].strip, (if parts.len > 1: parts[1].strip else: parts[0].strip))
    result = g
  else: result = newLabel(n.kind)

proc applyCommon(ctl: Control, n: DNode, parentAbsolute: bool) =
  ctl.focusable = false                         # the preview never takes the focus
  if n.getProp("state") == "csGrayed": ctl.state = csGrayed
  if n.pf("fixedWidth") > 0: ctl.fixedWidth = n.pf("fixedWidth")
  if n.pf("fixedHeight") > 0: ctl.fixedHeight = n.pf("fixedHeight")
  if parentAbsolute:
    ctl.fixedX = n.pf("fixedX")
    ctl.fixedY = n.pf("fixedY")
  if n.pf("weight") > 0: ctl.weight = n.pf("weight")
  if n.getProp("stretch").len > 0: ctl.stretch = n.pb("stretch")
  if n.getProp("dock").len > 0: ctl.dock = dockOf(n.getProp("dock"))
  if validColor(n.getProp("textColor")): ctl.style.text = some(hex(n.getProp("textColor")))
  if validColor(n.getProp("backgroundColor")): ctl.style.background = some(hex(n.getProp("backgroundColor")))
  if ctl of Container:
    let k = Container(ctl)
    if n.getProp("margin").len > 0 and baseOf(n.kind) notin ["Toolbar", "Splitter", "Tab"]:
      k.margin = n.pf("margin")
      k.spacing = n.pf("spacing")

proc buildChildren(c: FormCanvas, parentCtl: Control, parentNode: DNode) =
  let absolute = nodeLayout(parentNode) == "lkAbsolute"
  for ch in parentNode.children:
    var ctl: Control
    if baseOf(ch.kind) == "TabPage":
      if not (parentCtl of Tab): continue
      let page = Tab(parentCtl).addPage(ch.getProp("caption"), layoutOf(ch.getProp("layout")), ch.pi("columns"))
      ctl = page
    else:
      if not (parentCtl of Container): continue
      ctl = makeControl(ch)
      discard Container(parentCtl).addChild(ctl)
    applyCommon(ctl, ch, absolute)
    c.links.add((ctl, ch))
    if isContainerKind(ch.kind): c.buildChildren(ctl, ch)

proc ctlOf(c: FormCanvas, n: DNode): Control =
  for l in c.links:
    if l.node == n: return l.ctl

proc rebuild*(c: FormCanvas) =
  # Rebuilds the preview from the model (after any structural change).
  c.children.setLen(0)
  c.links.setLen(0)
  let r = c.model.root
  let root = newContainer(layoutOf(r.getProp("layout")), r.pf("margin"), r.pf("spacing"), max(1, r.pi("columns")))
  discard c.addChild(root)
  c.formRoot = root
  c.links.add((Control(root), r))
  c.buildChildren(root, r)
  if c.selected != nil and c.selected notin c.model.allNodes: c.selected = nil
  markDirty(c)

proc newFormCanvas*(model: FormModel): FormCanvas =
  result = FormCanvas(model: model, layout: lkAbsolute, margin: 0, spacing: 0, dropIndex: -1)
  initControl(result)
  result.focusable = true
  result.rebuild()

# geometry and hit testing

proc windowRect(c: FormCanvas): Rect =
  let r = c.model.root
  rect(c.rect.x + originX, c.rect.y + originY, float(max(120, r.pi("width"))), float(max(80, r.pi("height"))))

proc rectOf(c: FormCanvas, n: DNode): Rect =
  if n == c.model.root: return c.windowRect
  let ctl = c.ctlOf(n)
  if ctl != nil: ctl.rect else: rect(0, 0, 0, 0)

proc contentOf(c: FormCanvas, n: DNode): Rect =
  let ctl = c.ctlOf(n)
  if ctl == nil or c.win == nil: return c.rectOf(n)
  if ctl of Container: Container(ctl).contentArea(c.win.theme) else: ctl.rect

method preferredSize*(c: FormCanvas, d: Drawing, t: Theme): tuple[w, h: float] =
  let r = c.model.root
  (float(r.pi("width")) + originX * 2 + 40, float(r.pi("height")) + originY + 60)

method layoutChildren*(c: FormCanvas, d: Drawing, t: Theme) =
  if c.formRoot != nil: layoutControl(c.formRoot, c.windowRect, d, t)

method hitChildren*(c: FormCanvas, x, y: float): bool = false    # the canvas handles every click

proc nodeAt(c: FormCanvas, x, y: float): DNode =
  if c.formRoot == nil: return nil
  let wr = c.windowRect
  if rect(wr.x, wr.y - titleH, wr.w, titleH).containsPoint(x, y): return c.model.root
  var ctl = controlAt(c.formRoot, x, y)
  while ctl != nil:
    for l in c.links:
      if l.ctl == ctl: return l.node
    ctl = ctl.parent
  nil

proc containerNodeAt(c: FormCanvas, x, y: float, exclude: DNode, forPage: bool): DNode =
  var n = c.nodeAt(x, y)
  while n != nil:
    if exclude != nil and isAncestor(exclude, n):
      n = n.parent
      continue
    let base = baseOf(n.kind)
    if forPage:
      if base == "Tab": return n
    elif n.kind == "Window" or isContainerKind(n.kind):
      if base == "Tab":                                   # controls go into the active page
        let tctl = c.ctlOf(n)
        if tctl != nil and tctl of Tab:
          let ap = Tab(tctl).activePage
          if ap >= 0 and ap < n.children.len: return n.children[ap]
      else:
        return n
    n = n.parent
  nil

proc handleRects(r: Rect): array[8, Rect] =
  let s = 7.0
  let xs = [r.x, r.x + r.w / 2, r.x + r.w]
  let ys = [r.y, r.y + r.h / 2, r.y + r.h]
  let order = [(0, 0), (1, 0), (2, 0), (2, 1), (2, 2), (1, 2), (0, 2), (0, 1)]
  for i in 0 .. 7:
    let (ix, iy) = order[i]
    result[i] = rect(xs[ix] - s / 2, ys[iy] - s / 2, s, s)

proc handleAt(c: FormCanvas, x, y: float): int =
  if c.selected == nil: return -1
  let hs = handleRects(c.rectOf(c.selected))
  for i in countdown(7, 0):
    if hs[i].shrink(-3).containsPoint(x, y): return i
  -1

# drop targets

proc computeDrop(c: FormCanvas, kind: string, x, y: float, exclude: DNode) =
  c.dropValid = false
  let forPage = baseOf(kind) == "TabPage"
  let target = c.containerNodeAt(x, y, exclude, forPage)
  if target == nil: return
  let ca = c.contentOf(target)
  var kids: seq[DNode]
  for k in target.children:
    if k != exclude: kids.add k
  let layout = nodeLayout(target)
  if layout == "splitter" and kids.len >= 2: return
  c.dropParent = target
  c.dropValid = true
  c.dropDock = ""
  c.dropIndex = kids.len
  case layout
  of "lkAbsolute":
    c.dropPos = (x - ca.x, y - ca.y)
    c.dropMark = rect(0, 0, 0, 0)
  of "lkBorder":
    let fx = (x - ca.x) / max(1.0, ca.w)
    let fy = (y - ca.y) / max(1.0, ca.h)
    if fy < 0.25:
      c.dropDock = "dkTop"
      c.dropMark = rect(ca.x, ca.y, ca.w, ca.h * 0.25)
    elif fy > 0.75:
      c.dropDock = "dkBottom"
      c.dropMark = rect(ca.x, ca.y + ca.h * 0.75, ca.w, ca.h * 0.25)
    elif fx < 0.25:
      c.dropDock = "dkLeft"
      c.dropMark = rect(ca.x, ca.y, ca.w * 0.25, ca.h)
    elif fx > 0.75:
      c.dropDock = "dkRight"
      c.dropMark = rect(ca.x + ca.w * 0.75, ca.y, ca.w * 0.25, ca.h)
    else:
      c.dropDock = "dkCenter"
      c.dropMark = rect(ca.x + ca.w * 0.25, ca.y + ca.h * 0.25, ca.w * 0.5, ca.h * 0.5)
  of "tab", "lkStack":
    c.dropMark = ca
  else:
    let across = layout in ["lkHorizontal", "lkFlow"] or
                 (layout == "splitter" and target.pb("vertical"))
    for i, k in kids:
      let r = c.rectOf(k)
      let before = if across: x < r.x + r.w / 2
                   elif layout == "lkGrid": y < r.y or (y < r.y + r.h and x < r.x + r.w / 2)
                   else: y < r.y + r.h / 2
      if before:
        c.dropIndex = i
        break
    if kids.len == 0:
      c.dropMark = rect(ca.x, ca.y, ca.w, 3)
    elif c.dropIndex < kids.len:
      let r = c.rectOf(kids[c.dropIndex])
      c.dropMark = if across: rect(r.x - 2, r.y, 3, r.h) else: rect(r.x, r.y - 2, r.w, 3)
    else:
      let r = c.rectOf(kids[^1])
      c.dropMark = if across: rect(r.x + r.w - 1, r.y, 3, r.h) else: rect(r.x, r.y + r.h - 1, r.w, 3)

# guides (snapping)

proc siblingsRects(c: FormCanvas, n: DNode): seq[tuple[node: DNode, r: Rect]] =
  if n.parent == nil: return
  for s in n.parent.children:
    if s != n: result.add((s, c.rectOf(s)))

proc snapMove(c: FormCanvas, n: DNode, r: var Rect) =
  # Aligns the moving rectangle's edges / center with siblings and the container.
  c.guides.setLen(0)
  let ca = c.contentOf(n.parent)
  var xs, ys: seq[tuple[v: float, a, b: float]]
  for v in [ca.x, ca.x + ca.w / 2, ca.x + ca.w]: xs.add((v, ca.y, ca.y + ca.h))
  for v in [ca.y, ca.y + ca.h / 2, ca.y + ca.h]: ys.add((v, ca.x, ca.x + ca.w))
  for s in c.siblingsRects(n):
    for v in [s.r.x, s.r.x + s.r.w / 2, s.r.x + s.r.w]: xs.add((v, s.r.y, s.r.y + s.r.h))
    for v in [s.r.y, s.r.y + s.r.h / 2, s.r.y + s.r.h]: ys.add((v, s.r.x, s.r.x + s.r.w))
  var best = snapDist + 1
  var bestD = 0.0
  var bestG: Guide
  for e in [0.0, 0.5, 1.0]:
    let ex = r.x + r.w * e
    for cand in xs:
      let dd = cand.v - ex
      if abs(dd) < best:
        best = abs(dd)
        bestD = dd
        bestG = (cand.v, min(cand.a, r.y), cand.v, max(cand.b, r.y + r.h))
  if best <= snapDist:
    r.x += bestD
    c.guides.add bestG
  best = snapDist + 1
  for e in [0.0, 0.5, 1.0]:
    let ey = r.y + r.h * e
    for cand in ys:
      let dd = cand.v - ey
      if abs(dd) < best:
        best = abs(dd)
        bestD = dd
        bestG = (min(cand.a, r.x), cand.v, max(cand.b, r.x + r.w), cand.v)
  if best <= snapDist:
    r.y += bestD
    c.guides.add bestG

proc snapSize(c: FormCanvas, n: DNode, r: var Rect, horiz, vert, fromLeft, fromTop: bool) =
  # Snaps the width / height to a sibling's size or to a proportion of the container.
  c.guides.setLen(0)
  c.sizeLabel = ""
  let ca = c.contentOf(n.parent)
  const fracs = [(0.25, "1/4"), (1.0 / 3, "1/3"), (0.5, "1/2"), (2.0 / 3, "2/3"), (0.75, "3/4"), (1.0, "full")]
  var note = ""
  if horiz:
    var best = snapDist + 1
    var target = r.w
    var what = ""
    var other: Rect
    for s in c.siblingsRects(n):
      if abs(s.r.w - r.w) < best:
        best = abs(s.r.w - r.w)
        target = s.r.w
        what = "= " & s.node.name
        other = s.r
    for (f, label) in fracs:
      if abs(ca.w * f - r.w) < best:
        best = abs(ca.w * f - r.w)
        target = ca.w * f
        what = label & " width"
        other = rect(0, 0, 0, 0)
    if best <= snapDist:
      if fromLeft: r.x -= target - r.w
      r.w = target
      note.add " " & what
      c.guides.add((r.x, r.y + r.h + 6, r.x + r.w, r.y + r.h + 6))
      if other.w > 0: c.guides.add((other.x, other.y + other.h + 6, other.x + other.w, other.y + other.h + 6))
  if vert:
    var best = snapDist + 1
    var target = r.h
    var what = ""
    var other: Rect
    for s in c.siblingsRects(n):
      if abs(s.r.h - r.h) < best:
        best = abs(s.r.h - r.h)
        target = s.r.h
        what = "= " & s.node.name
        other = s.r
    for (f, label) in fracs:
      if abs(ca.h * f - r.h) < best:
        best = abs(ca.h * f - r.h)
        target = ca.h * f
        what = label & " height"
        other = rect(0, 0, 0, 0)
    if best <= snapDist:
      if fromTop: r.y -= target - r.h
      r.h = target
      note.add " " & what
      c.guides.add((r.x + r.w + 6, r.y, r.x + r.w + 6, r.y + r.h))
      if other.w > 0: c.guides.add((other.x + other.w + 6, other.y, other.x + other.w + 6, other.y + other.h))
  c.sizeLabel = $int(round(r.w)) & " x " & $int(round(r.h)) & note

# model changes

proc select*(c: FormCanvas, n: DNode) =
  c.selected = n
  emit(c, evSelection, text = (if n != nil: n.name else: ""))

proc changed(c: FormCanvas) =
  emit(c, evChange)

proc fmtNum(f: float): string = $int(round(f))

proc dropNew*(c: FormCanvas, kind: string, x, y: float) =
  c.computeDrop(kind, x, y, nil)
  c.drag = dmNone
  if not c.dropValid: return
  let n = newNode(kind, c.model.uniqueName(kind))
  n.parent = c.dropParent
  let layout = nodeLayout(c.dropParent)
  if layout == "lkAbsolute":
    n.setProp("fixedX", fmtNum(max(0.0, c.dropPos.x - 20)))
    n.setProp("fixedY", fmtNum(max(0.0, c.dropPos.y - 12)))
    n.setProp("fixedWidth", (if isContainerKind(kind): "200" else: "120"))
    n.setProp("fixedHeight", (if isContainerKind(kind): "120" else: "30"))
  if c.dropDock.len > 0: n.setProp("dock", c.dropDock)
  c.dropParent.children.insert(n, clamp(c.dropIndex, 0, c.dropParent.children.len))
  if baseOf(kind) == "Tab":                                # a tab starts with one page
    let page = newNode("TabPage", c.model.uniqueName("TabPage"))
    page.parent = n
    page.setProp("caption", "Page 1")
    n.children.add page
  c.dropValid = false
  c.rebuild()
  c.select(n)
  c.changed()

proc deleteSelected*(c: FormCanvas) =
  let n = c.selected
  if n == nil or n == c.model.root or n.parent == nil: return
  let p = n.parent
  let i = p.children.find(n)
  if i >= 0: p.children.delete(i)
  c.rebuild()
  c.select(p)
  c.changed()

proc moveSelected*(c: FormCanvas, delta: int) =
  # Display order among the siblings (and z-order in absolute layouts).
  let n = c.selected
  if n == nil or n.parent == nil: return
  let sibs = n.parent.children
  let i = sibs.find(n)
  let j = i + delta
  if i < 0 or j < 0 or j >= sibs.len: return
  swap(n.parent.children[i], n.parent.children[j])
  c.rebuild()
  c.select(n)
  c.changed()

proc moveOut*(c: FormCanvas) =
  # Moves the selected control out of its container, just after it.
  let n = c.selected
  if n == nil or n.parent == nil or n.parent.parent == nil: return
  let p = n.parent
  let gp = p.parent
  if baseOf(gp.kind) == "Tab" and baseOf(n.kind) != "TabPage": return
  p.children.delete(p.children.find(n))
  gp.children.insert(n, gp.children.find(p) + 1)
  n.parent = gp
  c.rebuild()
  c.select(n)
  c.changed()

proc finishMove(c: FormCanvas, x, y: float) =
  let n = c.selected
  c.computeDrop(n.kind, x, y, n)
  let sameAbsolute = c.dropValid and c.dropParent == n.parent and nodeLayout(n.parent) == "lkAbsolute"
  if not c.dropValid:
    c.rebuild()
    return
  if not sameAbsolute:
    let old = n.parent
    old.children.delete(old.children.find(n))
    c.dropParent.children.insert(n, clamp(c.dropIndex, 0, c.dropParent.children.len))
    n.parent = c.dropParent
    if nodeLayout(c.dropParent) == "lkAbsolute":
      n.setProp("fixedX", fmtNum(max(0.0, c.ghost.x - c.contentOf(c.dropParent).x)))
      n.setProp("fixedY", fmtNum(max(0.0, c.ghost.y - c.contentOf(c.dropParent).y)))
    if c.dropDock.len > 0: n.setProp("dock", c.dropDock)
  c.dropValid = false
  c.rebuild()
  c.select(n)
  c.changed()

# drawing

proc dashedLine(d: Drawing, x1, y1, x2, y2: float, c: Color) =
  let len = hypot(x2 - x1, y2 - y1)
  if len < 1: return
  var t = 0.0
  while t < len:
    let t2 = min(len, t + 4)
    d.line(x1 + (x2 - x1) * t / len, y1 + (y2 - y1) * t / len,
           x1 + (x2 - x1) * t2 / len, y1 + (y2 - y1) * t2 / len, c)
    t += 7

proc dashedRect(d: Drawing, r: Rect, c: Color) =
  d.dashedLine(r.x, r.y, r.x + r.w, r.y, c)
  d.dashedLine(r.x + r.w, r.y, r.x + r.w, r.y + r.h, c)
  d.dashedLine(r.x + r.w, r.y + r.h, r.x, r.y + r.h, c)
  d.dashedLine(r.x, r.y + r.h, r.x, r.y, c)

method draw*(c: FormCanvas, d: Drawing, t: Theme) =
  d.fillRect(c.rect, mix(t.windowBg, t.text, 0.06))
  var y = c.rect.y + 8
  while y < c.rect.y + c.rect.h: # dotted background.
    var x = c.rect.x + 8
    while x < c.rect.x + c.rect.w:
      d.fillRect(rect(x, y, 1.5, 1.5), t.text.withAlpha(35))
      x += 16
    y += 16
  let wr = c.windowRect
  let frame = rect(wr.x, wr.y - titleH, wr.w, wr.h + titleH)
  d.shadow(frame, 10, t.shadow)
  d.fillRoundRect(frame, 10, t.border)
  d.fillRoundRect(frame.shrink(1), 9, t.header)
  d.fillRect(wr, t.windowBg)
  for i, col in [hex"#FF5F57", hex"#FEBC2E", hex"#28C840"]:
    d.fillCircle(wr.x + 16 + float(i) * 20, wr.y - titleH / 2, 6, col)
  d.textIn(rect(wr.x, wr.y - titleH, wr.w, titleH), c.model.root.getProp("title"), t.textSecondary, alCenter)

method drawOverlay*(c: FormCanvas, d: Drawing, t: Theme) =
  let root = c.model.root
  # structure: dashed outlines of the containers.
  for l in c.links:
    if l.node != root and isContainerKind(l.node.kind):
      d.dashedRect(l.ctl.rect, t.textSecondary.withAlpha(110))
  if c.hoverNode != nil and c.hoverNode != c.selected and c.drag == dmNone:
    d.strokeRect(c.rectOf(c.hoverNode), selColor.withAlpha(110), 1)
  # drop indicator
  if c.dropValid:
    let pr = c.rectOf(c.dropParent)
    d.strokeRect(pr, selColor.withAlpha(160), 2)
    if c.dropMark.w > 0: d.fillRect(c.dropMark, selColor.withAlpha(if c.dropMark.h > 4 and c.dropMark.w > 4: 50 else: 230))
  # ghost of the dragged / new control.
  if (c.drag == dmNew or (c.drag == dmMove and c.moved and c.dropValid)) and c.ghost.w > 0:
    d.fillRoundRect(c.ghost, 4, selColor.withAlpha(40))
    d.strokeRect(c.ghost, selColor.withAlpha(200), 1)
    if c.newKind.len > 0: d.textIn(c.ghost, c.newKind, selColor, alCenter)
  # selection and handles.
  if c.selected != nil:
    let r = c.rectOf(c.selected)
    d.strokeRect(r.shrink(-1), selColor, 2)
    let label = c.selected.kind & "  " & c.selected.name
    let lw = d.textWidth(label) + 14
    let lr = rect(r.x - 1, r.y - t.lineHeight - 2, lw, t.lineHeight)
    d.fillRoundRect(lr, 4, selColor)
    d.textIn(lr, label, White, alCenter)
    let hs = handleRects(r)
    for i, h in hs:
      if c.selected == root and i notin [3, 4, 5]: continue
      d.fillRect(h, White)
      d.strokeRect(h, selColor, 1)
  # guides
  for g in c.guides: d.dashedLine(g.x1, g.y1, g.x2, g.y2, guideColor)
  if c.sizeLabel.len > 0 and c.selected != nil:
    let r = c.rectOf(c.selected)
    let w = d.textWidth(c.sizeLabel) + 14
    let lr = rect(r.x + r.w / 2 - w / 2, r.y + r.h + 10, w, t.lineHeight)
    d.fillRoundRect(lr, 4, guideColor)
    d.textIn(lr, c.sizeLabel, White, alCenter)

# mouse and keyboard

method onMouse*(c: FormCanvas, e: MouseEvent) =
  case e.action
  of maPress:
    c.guides.setLen(0)
    c.sizeLabel = ""
    if e.button != mbLeft:
      c.select(c.nodeAt(e.x, e.y))
      return
    let h = c.handleAt(e.x, e.y)
    if h >= 0 and (c.selected != c.model.root or h in [3, 4, 5]):
      c.drag = dmResize
      c.handle = h
      c.startX = e.x
      c.startY = e.y
      c.startRect = c.rectOf(c.selected)
      return
    let n = c.nodeAt(e.x, e.y)
    c.select(n)
    if n != nil and n != c.model.root:
      c.drag = dmMove
      c.startX = e.x
      c.startY = e.y
      c.startRect = c.rectOf(n)
      c.moved = false
  of maMove:
    case c.drag
    of dmResize:
      let n = c.selected
      var r = c.startRect
      let dx = e.x - c.startX
      let dy = e.y - c.startY
      let hh = c.handle
      let left = hh in [0, 6, 7]
      let top = hh in [0, 1, 2]
      let horiz = hh in [0, 2, 3, 4, 6, 7]
      let vert = hh in [0, 1, 2, 4, 5, 6]
      if left:
        r.x += dx
        r.w -= dx
      elif horiz: r.w += dx
      if top:
        r.y += dy
        r.h -= dy
      elif vert: r.h += dy
      r.w = max(12.0, r.w)
      r.h = max(8.0, r.h)
      if n == c.model.root:
        n.setProp("width", fmtNum(r.w))
        n.setProp("height", fmtNum(r.h))
        c.sizeLabel = fmtNum(r.w) & " x " & fmtNum(r.h)
      else:
        c.snapSize(n, r, horiz, vert, left, top)
        let ctl = c.ctlOf(n)
        if horiz:
          n.setProp("fixedWidth", fmtNum(r.w))
          if ctl != nil: ctl.fixedWidth = round(r.w)
        if vert:
          n.setProp("fixedHeight", fmtNum(r.h))
          if ctl != nil: ctl.fixedHeight = round(r.h)
        if nodeLayout(n.parent) == "lkAbsolute" and (left or top):
          let ca = c.contentOf(n.parent)
          n.setProp("fixedX", fmtNum(r.x - ca.x))
          n.setProp("fixedY", fmtNum(r.y - ca.y))
          if ctl != nil:
            ctl.fixedX = round(r.x - ca.x)
            ctl.fixedY = round(r.y - ca.y)
    of dmMove:
      let dx = e.x - c.startX
      let dy = e.y - c.startY
      if not c.moved and abs(dx) + abs(dy) < 4: return
      c.moved = true
      let n = c.selected
      var r = rect(c.startRect.x + dx, c.startRect.y + dy, c.startRect.w, c.startRect.h)
      let under = c.containerNodeAt(e.x, e.y, n, baseOf(n.kind) == "TabPage")
      if under == n.parent and nodeLayout(n.parent) == "lkAbsolute":
        c.snapMove(n, r)         # free placement with guides.
        let ca = c.contentOf(n.parent)
        n.setProp("fixedX", fmtNum(r.x - ca.x))
        n.setProp("fixedY", fmtNum(r.y - ca.y))
        let ctl = c.ctlOf(n)
        if ctl != nil:
          ctl.fixedX = round(r.x - ca.x)
          ctl.fixedY = round(r.y - ca.y)
        c.sizeLabel = fmtNum(r.x - ca.x) & ", " & fmtNum(r.y - ca.y)
        c.dropValid = false
      else:
        c.guides.setLen(0)
        c.sizeLabel = ""
        c.computeDrop(n.kind, e.x, e.y, n)
        c.ghost = rect(e.x - c.startRect.w / 2, e.y - c.startRect.h / 2, c.startRect.w, c.startRect.h)
    else:
      c.hoverNode = c.nodeAt(e.x, e.y)
  of maRelease:
    case c.drag
    of dmMove:
      if c.moved:
        if c.dropValid or nodeLayout(c.selected.parent) != "lkAbsolute": c.finishMove(e.x, e.y)
        else: c.changed()
    of dmResize: c.changed()
    else: discard
    c.drag = dmNone
    c.dropValid = false
    c.guides.setLen(0)
    c.sizeLabel = ""

method onKey*(c: FormCanvas, e: KeyEvent): bool =
  let n = c.selected
  if n == nil: return false
  case e.key
  of SDLK_DELETE, SDLK_BACKSPACE:
    c.deleteSelected()
  of SDLK_ESCAPE:
    if n.parent != nil: c.select(n.parent)
  of SDLK_LEFT, SDLK_RIGHT, SDLK_UP, SDLK_DOWN:
    if n.parent == nil or nodeLayout(n.parent) != "lkAbsolute": return false
    let step = if (e.mods and KMOD_SHIFT) != 0: 10.0 else: 1.0
    var x = n.pf("fixedX")
    var y = n.pf("fixedY")
    case e.key
    of SDLK_LEFT: x -= step
    of SDLK_RIGHT: x += step
    of SDLK_UP: y -= step
    else: y += step
    n.setProp("fixedX", fmtNum(max(0.0, x)))
    n.setProp("fixedY", fmtNum(max(0.0, y)))
    c.rebuild()
    c.changed()
  else: return false
  true

# palette

type PaletteRow = tuple[header: bool, text: string, kind: string]

proc rows(p: PaletteView): seq[PaletteRow] =
  var cats: seq[string]
  {.cast(gcsafe).}:
    if palette.len == 0: discard findEntry("Label")               # initializes the built-in palette.
    for e in palette:
      if e.category notin cats: cats.add e.category
    for cat in cats:
      result.add((true, cat.toUpperAscii, ""))
      for e in palette:
        if e.category == cat: result.add((false, e.kind, e.kind))

proc rowH(t: Theme): float = t.lineHeight + 2

proc rowAt(p: PaletteView, t: Theme, y: float): int =
  let i = int(floor((y - p.rect.y - 4 + p.scroll) / rowH(t)))
  let rs = p.rows
  if i >= 0 and i < rs.len and not rs[i].header: i else: -1

proc newPaletteView*(canvas: FormCanvas): PaletteView =
  result = PaletteView(canvas: canvas, hoverIdx: -1, pressIdx: -1)
  initControl(result)

method preferredSize*(p: PaletteView, d: Drawing, t: Theme): tuple[w, h: float] = (190.0, 400.0)

method draw*(p: PaletteView, d: Drawing, t: Theme) =
  d.fillRect(p.rect, t.header)
  d.pushClip(p.rect)
  let rh = rowH(t)
  if not p.hovered: p.hoverIdx = -1
  for i, r in p.rows:
    let y = p.rect.y + 4 + float(i) * rh - p.scroll
    if y + rh < p.rect.y or y > p.rect.y + p.rect.h: continue
    let rr = rect(p.rect.x + 6, y, p.rect.w - 12, rh)
    if r.header:
      d.textIn(rr, r.text, t.textSecondary, alLeft, 4)
      continue
    if i == p.hoverIdx: d.fillRoundRect(rr, 5, t.surfaceHover)
    let badge = rect(rr.x + 4, y + (rh - 20) / 2, 26, 20)
    d.fillRoundRect(badge, 5, t.accent.withAlpha(50))
    d.textIn(badge, r.kind[0 ..< min(2, r.kind.len)], t.accent, alCenter)
    d.textIn(rect(rr.x + 36, y, rr.w - 36, rh), r.text, t.text)
  d.popClip()

method onMouse*(p: PaletteView, e: MouseEvent) =
  let t = p.win.theme
  let c = p.canvas
  case e.action
  of maPress:
    p.pressIdx = p.rowAt(t, e.y)
    p.pressX = e.x
    p.pressY = e.y
    p.dragging = false
  of maMove:
    if p.pressIdx >= 0 and p.pressed:
      if not p.dragging and abs(e.x - p.pressX) + abs(e.y - p.pressY) > 5: p.dragging = true
      if p.dragging:
        let kind = p.rows[p.pressIdx].kind
        c.drag = dmNew
        c.newKind = kind
        let isCont = isContainerKind(kind)
        let w = if isCont: 200.0 else: 120.0
        let h = if isCont: 110.0 else: 30.0
        c.ghost = rect(e.x - w / 2, e.y - h / 2, w, h)
        if c.rect.containsPoint(e.x, e.y): c.computeDrop(kind, e.x, e.y, nil)
        else: c.dropValid = false
        markDirty(c)
    else:
      p.hoverIdx = p.rowAt(t, e.y)
  of maRelease:
    if p.pressIdx >= 0:
      let kind = p.rows[p.pressIdx].kind
      if p.dragging:
        if c.rect.containsPoint(e.x, e.y): c.dropNew(kind, e.x, e.y)
      elif p.rowAt(t, e.y) == p.pressIdx:
        # click: add to the selected container (or the form), at the end.
        var target = c.selected
        while target != nil and not (target.kind == "Window" or isContainerKind(target.kind)): target = target.parent
        if target == nil: target = c.model.root
        let r = c.contentOf(target)
        c.dropNew(kind, r.x + r.w / 2, r.y + r.h - 4)
    c.drag = dmNone
    c.newKind = ""
    c.dropValid = false
    c.ghost = rect(0, 0, 0, 0)
    p.pressIdx = -1
    p.dragging = false
    markDirty(c)

method onWheel*(p: PaletteView, dx, dy: float): bool =
  let t = p.win.theme
  let total = float(p.rows.len) * rowH(t) + 8
  p.scroll = clamp(p.scroll - dy * 30, 0.0, max(0.0, total - p.rect.h))
  true

# designer window

var
  dWin, dCanvas, dPalette, dTree, dInspector, dTitle, dStatus: ControlId
  dRoot, dCodePath, dFormFile: string
  dEditor: ControlId
  dOpen: bool
  dRows: seq[tuple[id: ControlId, prop: string, kind: PropKind, choices: seq[string]]]
  dEventRows: seq[tuple[id: ControlId, event: string, choices: seq[string]]]
  dColorButtons: seq[tuple[id: ControlId, prop: string, edit: ControlId]]
  dTreePaths: seq[tuple[path: string, uid: int]]
  dTools: seq[tuple[id: ControlId, cmd: string]]
  designerFileCreated*: proc (path: string) {.nimcall, gcsafe.}   # set by wdnim (refreshes the tree).

const newHandlerChoice = "+ new handler…"
const noHandlerChoice = "(none)"

proc status(s: string) = dStatus.caption = s

proc codeText(): string =
  let t = editorTextOf(dEditor, dCodePath)
  if t.found: return t.text
  try: result = readFile(dCodePath)
  except CatchableError: result = ""

proc writeCode(text: string) =
  if not editorSetText(dEditor, dCodePath, text):
    try: writeFile(dCodePath, text)
    except CatchableError: status("Cannot write " & dCodePath)

proc formName(): string =
  readControl(dCanvas, FormCanvas, c): result = c.model.root.name

proc saveForm() =
  var code, name: string
  readControl(dCanvas, FormCanvas, c):
    code = generateCode(c.model, dRoot)
    name = c.model.root.name
  let path = normalizedPath(absolutePath(dRoot / formFileName(name)))
  let isNew = not fileExists(path)
  try:
    writeFile(path, code)
  except CatchableError:
    status("Cannot write " & path)
    return
  discard editorSetText(dEditor, path, code, modified = false)
  guarded: dFormFile = path
  dWin.caption = "Form designer — " & formFileName(name) & " — " & extractFilename(dCodePath)
  status("Saved " & formFileName(name) & " · code: " & extractFilename(dCodePath))
  if isNew and designerFileCreated != nil: designerFileCreated(path)

proc syncWiring(force = false) =
  # Rewrites the registrations of the form in the edited code.
  var regs: seq[tuple[control, event, handler: string]]
  var name: string
  readControl(dCanvas, FormCanvas, c):
    name = c.model.root.name
    for n in c.model.allNodes:
      let ctlName = if n == c.model.root: "window" else: n.name
      for e in n.events:
        regs.add((ctlName, e.event, e.handler))
  let code = codeText()
  if regs.len == 0 and not force and beginMarker(name) notin code: return
  let updated = setRegistrations(code, name, regs)
  if updated != code: writeCode(updated)

proc pathOfNode(n: DNode): string =
  var parts: seq[string]
  var p = n
  while p != nil:
    parts.insert((if p.parent == nil: "form " & p.name else: p.name), 0)
    p = p.parent
  parts.join(TreeSep)

proc rebuildTree() =
  var items: seq[tuple[path: string, uid: int, container: bool]]
  var sel = ""
  readControl(dCanvas, FormCanvas, c):
    for n in c.model.allNodes: items.add((pathOfNode(n), n.uid, n.children.len > 0))
    if c.selected != nil: sel = pathOfNode(c.selected)
  treeDeleteAll(dTree)
  guarded: dTreePaths.setLen(0)
  for it in items:
    treeAdd(dTree, it.path, it.container)
    guarded: dTreePaths.add((it.path, it.uid))
  if sel.len > 0: treeSelectPlus(dTree, sel)

proc addRow(label: string, editorCtl: Control, extra: Control = nil) =
  let row = newSupercontrol(lkHorizontal, 6)
  let l = newLabel(label)
  l.fixedWidth = 118
  discard row.addChild(l)
  editorCtl.weight = 1
  discard row.addChild(editorCtl)
  if extra != nil: discard row.addChild(extra)
  discard addChild(dInspector, row)

proc rebuildInspector() =
  var node: DNode
  var isRoot = false
  readControl(dCanvas, FormCanvas, c):
    node = if c.selected != nil: c.selected else: c.model.root
    isRoot = node == c.model.root
  if node == nil: return
  for id in children(dInspector): deleteControl(id)
  guarded:
    dRows.setLen(0)
    dEventRows.setLen(0)
    dColorButtons.setLen(0)
  dTitle.caption = (if isRoot: "Form  " & node.name else: node.kind & "  " & node.name)
  let hdr = newLabel("PROPERTIES")
  discard addChild(dInspector, hdr)
  # name (form name for the window: gives form_<name>.nim).
  let nameEdit = newEdit(node.name)
  addRow((if isRoot: "name (file)" else: "name"), nameEdit)
  guarded: dRows.add((nameEdit.id, "name", pkString, newSeq[string]()))
  for d in allProps(node.kind):
    let v = node.getProp(d.name)
    var ctl: Control
    var extra: Control = nil
    case d.kind
    of pkBool: ctl = newCheckBox("", v.toLowerAscii in ["true", "1", "yes"])
    of pkEnum:
      var shown: seq[string]
      for ch in d.choices: shown.add(if ch.len == 0: "(default)" else: ch)
      ctl = newComboBox(shown, max(0, d.choices.find(v)))
    of pkInt: ctl = newEdit(v, ikInteger)
    of pkFloat: ctl = newEdit(v, ikReal)
    of pkColor:
      ctl = newEdit(v, placeholder = "#RRGGBB")
      extra = newButton("…")
      extra.fixedWidth = 36
    of pkList: ctl = newEdit(v, placeholder = "a;b;c")
    of pkString: ctl = newEdit(v)
    addRow(d.name, ctl, extra)
    guarded:
      dRows.add((ctl.id, d.name, d.kind, d.choices))
      if extra != nil: dColorButtons.add((extra.id, d.name, ctl.id))
  # events.
  let evHdr = newLabel("EVENTS  (handlers of " & extractFilename(dCodePath) & ")")
  discard addChild(dInspector, evHdr)
  let handlers = handlersBeforeRegistrations(codeText(), formName())
  for ev in eventsOf(node.kind):
    let current = node.handlerFor(ev)
    var choices = @[noHandlerChoice]
    for h in handlers: choices.add h
    if current.len > 0 and current notin choices: choices.add current
    choices.add newHandlerChoice
    let cb = newComboBox(choices, max(0, choices.find(current)))
    addRow(ev, cb)
    guarded: dEventRows.add((cb.id, ev, choices))

proc applyProp(prop: string, kind: PropKind, value: string) =
  var oldForm, newForm: string
  var ok = true
  var msg = ""
  withControl(dCanvas, FormCanvas, c):
    let n = if c.selected != nil: c.selected else: c.model.root
    if prop == "name":
      let v = value.strip
      if n == c.model.root:
        var valid = v.len > 0
        for ch in v:
          if not (ch.isAlphaNumeric or ch == '_'): valid = false
        if not valid:
          ok = false
          msg = "Form name: letters, digits and _ only"
        elif v != n.name:
          oldForm = n.name
          newForm = v
          n.name = v
      else:
        var used = false
        for x in c.model.allNodes:
          if x != n and x.name == v: used = true
        if not isIdent(v) or used:
          ok = false
          msg = if used: "\"" & v & "\" is already used" else: "Not a valid identifier"
        else:
          n.name = v
    elif kind == pkColor and value.strip.len > 0 and not validColor(value):
      ok = false
      msg = "Color: #RRGGBB or #RRGGBBAA"
    else:
      n.setProp(prop, value)
    if ok: c.rebuild()
  if not ok:
    status(msg)
    return
  if newForm.len > 0:            # the form was renamed.
    let oldPath = dRoot / formFileName(oldForm)
    try:
      if fileExists(oldPath): removeFile(oldPath)
    except CatchableError: discard
    let code = codeText()
    let renamed = renameWiring(code, oldForm, newForm)
    if renamed != code: writeCode(renamed)
  saveForm()
  if prop == "name":
    syncWiring()
    rebuildTree()
    dTitle.caption = value.strip

proc applyEvent(event, choice: string) =
  var nodeName, form, handler: string
  readControl(dCanvas, FormCanvas, c):
    let n = if c.selected != nil: c.selected else: c.model.root
    nodeName = if n == c.model.root: "window" else: n.name
    form = c.model.root.name
  var stubLine = 0
  if choice == noHandlerChoice:
    handler = ""
  elif choice == newHandlerChoice:
    let existing = existingHandlers(codeText())
    let base = "on" & capitalizeAscii(nodeName) & event[2 .. ^1]
    handler = base
    var k = 2
    while handler in existing:
      handler = base & $k
      inc k
    let r = insertStub(codeText(), form, handlerStub(handler, event, nodeName, form))
    writeCode(r.text)
    stubLine = r.line
  else:
    handler = choice
  withControl(dCanvas, FormCanvas, c):
    let n = if c.selected != nil: c.selected else: c.model.root
    n.setHandler(event, handler)
  syncWiring(force = handler.len > 0)
  saveForm()
  if stubLine > 0:
    rebuildInspector()
    if editorOpenFile(dEditor, dCodePath):
      editorGotoLine(dEditor, stubLine + 2, 3)
    status("Handler " & handler & " created in " & extractFilename(dCodePath) & " (line " & $stubLine & ")")
  elif handler.len > 0: status(event & " → " & handler)
  else: status(event & ": association removed")

proc designerCommand(cmd: string) =
  case cmd
  of "save":
    saveForm()
    syncWiring()
  of "wire":
    syncWiring(force = true)
    status("show" & typeName(formName()) & "() is available in " & extractFilename(dCodePath))
  of "delete", "up", "down", "out", "form":
    withControl(dCanvas, FormCanvas, c):
      case cmd
      of "delete": c.deleteSelected()
      of "up": c.moveSelected(-1)
      of "down": c.moveSelected(1)
      of "out": c.moveOut()
      else: c.select(c.model.root)
  of "custom":
    let kind = prompt(iconQuestion, "Name of the custom control (its type, e.g. RoundButton):", "", "Custom control")
    if not isIdent(kind): return
    let base = prompt(iconQuestion, "Existing control it derives from (Button, Label, Edit, Container…):",
                      "Button", "Custom control")
    if findEntry(base).base != base:
      alert(iconStop, "Unknown base control \"" & base & "\".")
      return
    let ctor = prompt(iconQuestion, "Constructor expression ($caption, $text… are replaced by the properties):",
                      "new" & kind & "($caption)", "Custom control")
    let module = prompt(iconQuestion, "Module to import in the generated code (empty if none):", "", "Custom control")
    if addCustomEntry(dRoot, kind, base, ctor, module):
      withControl(dPalette, PaletteView, p): discard
      status(kind & " added to the palette (" & extractFilename(customPalettePath(dRoot)) & ")")
  of "code":
    if editorOpenFile(dEditor, dCodePath): status("Code: " & dCodePath)
  else: discard

proc designerHandler(ev: var Event) {.nimcall, gcsafe.} =
  if ev.current != ev.id: return
  {.cast(gcsafe).}:
    if ev.id == dCanvas:
      case ev.kind
      of evSelection:
        rebuildInspector()
        var sel = ""
        readControl(dCanvas, FormCanvas, c):
          if c.selected != nil: sel = pathOfNode(c.selected)
        if sel.len > 0: treeSelectPlus(dTree, sel)
      of evChange:
        saveForm()
        syncWiring()
        rebuildTree()
        rebuildInspector()
      else: discard
      return
    if ev.id == dTree and ev.kind == evSelection:
      var uid = -1
      guarded:
        for p in dTreePaths:
          if p.path == ev.text: uid = p.uid
      withControl(dCanvas, FormCanvas, c):
        for n in c.model.allNodes:
          if n.uid == uid: c.selected = n
      rebuildInspector()
      return
    if ev.kind == evWindowClose and ev.id == dWin:
      guarded: dOpen = false
      return
    if ev.kind == evClick:
      var cmd = ""
      guarded:
        for t in dTools:
          if t.id == ev.id: cmd = t.cmd
      if cmd.len > 0:
        designerCommand(cmd)
        return
      var colorProp = ""
      var colorEdit: ControlId
      guarded:
        for cbt in dColorButtons:
          if cbt.id == ev.id:
            colorProp = cbt.prop
            colorEdit = cbt.edit
      if colorProp.len > 0:
        var col = if validColor(colorEdit.value): hex(colorEdit.value) else: hex"#3B82F6"
        if colorDialog(col) == drOk:
          colorEdit.value = hexOf(col)
          applyProp(colorProp, pkColor, hexOf(col))
      return
    if ev.kind in {evChange, evSelection}:
      var prop = ""
      var kind = pkString
      var choices: seq[string]
      var event = ""
      var evChoices: seq[string]
      guarded:
        for r in dRows:
          if r.id == ev.id:
            prop = r.prop
            kind = r.kind
            choices = r.choices
        for r in dEventRows:
          if r.id == ev.id:
            event = r.event
            evChoices = r.choices
      if prop.len > 0:
        var value = ev.id.value
        case kind
        of pkBool: value = (if value == "1": "true" else: "false")
        of pkEnum:
          let i = listSelect(ev.id) - 1
          value = if i >= 0 and i < choices.len: choices[i] else: ""
        else: discard
        applyProp(prop, kind, value)
      elif event.len > 0 and ev.kind == evSelection:
        let i = listSelect(ev.id) - 1
        if i >= 0 and i < evChoices.len: applyEvent(event, evChoices[i])

proc openDesigner*(root, codePath, formFile: string, editorId: ControlId, theme: Theme): bool =
  # Opens the designer for `codePath` (the code being edited). `formFile` = an existing
  # form_<name>.nim to reopen, or "" for a new form named after the first free number.
  var already = false
  guarded: already = dOpen
  if already: return false
  loadCustomPalette(root)
  var model: FormModel = nil
  if formFile.len > 0: model = loadModel(formFile)
  if model == nil: model = newModel(nextFormName(root))
  guarded:
    dOpen = true
    dRoot = root
    dCodePath = normalizedPath(absolutePath(codePath))
    dEditor = editorId
    dTools.setLen(0)
    let win = newWindow("Form designer", 1320, 820, designerHandler, theme, lkBorder)
    win.root.margin = 0
    win.root.spacing = 0
    dWin = win.id
    # toolbar
    let tb = win.addChild(newToolbar())
    tb.dock = dkTop
    for (caption, cmd, tip) in [("Save", "save", "Regenerate form_<name>.nim"),
                                ("Delete", "delete", "Delete the selected control (Del)"),
                                ("Up", "up", "Earlier in the display order"),
                                ("Down", "down", "Later in the display order"),
                                ("Out", "out", "Move out of its container"),
                                ("Form", "form", "Select the form (window properties)"),
                                ("Wire code", "wire", "Add the import and the registrations block to the code"),
                                ("Custom Control…", "custom", "Add a control derived from an existing one to the palette"),
                                ("Open Code", "code", "Show the edited code in wdnim")]:
      let b = tb.addTool(caption, tip)
      dTools.add((b.id, cmd))
    # status.
    let st = win.addChild(newLabel("Drag from the palette · click to select · handles to resize · Del deletes"))
    st.dock = dkBottom
    dStatus = st.id
    # canvas (scrollable), palette, hierarchy and inspector.
    let canvas = newFormCanvas(model)
    canvas.selected = model.root
    let pal = newPaletteView(canvas)
    let left = win.addChild(newContainer(lkBorder, 0, 0))
    left.dock = dkLeft
    left.fixedWidth = 200
    let lt = left.addChild(newLabel("  PALETTE"))
    lt.dock = dkTop
    pal.dock = dkCenter
    discard left.addChild(pal)
    dPalette = pal.id
    let right = win.addChild(newContainer(lkBorder, 6, 6))
    right.dock = dkRight
    right.fixedWidth = 360
    let top = right.addChild(newContainer(lkVertical, 0, 4))
    top.dock = dkTop
    discard top.addChild(newLabel("HIERARCHY"))
    let tree = top.addChild(newTreeView())
    tree.fixedHeight = 210
    dTree = tree.id
    let title = top.addChild(newLabel(""))
    title.style.text = some(theme.accent)
    dTitle = title.id
    let insp = right.addChild(newPanel(lkVertical, smAutomatic, 2, 4))
    insp.dock = dkCenter
    dInspector = insp.id
    let area = win.addChild(newPanel(lkVertical, smAutomatic, 0, 0))
    area.dock = dkCenter
    discard area.addChild(canvas)
    dCanvas = canvas.id
    win.focusedControl = canvas
    canvas.focus = true
  saveForm()
  rebuildTree()
  rebuildInspector()
  true

proc designerIsOpen*(): bool =
  guarded: result = dOpen
