# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
# List-type controls: List Box, Combo Box, Table, TreeView, Looper, Menu (menu bar)
# and the popup list used by combo boxes, menus and context menus.
import std/[math, strutils, sequtils, algorithm]
import ../sdl3, core, controls_basic

# Popup list

type
  PopupList* = ref object of Control
    elements*: seq[string]   # "-" = separator.
    owner*: Control
    hoverIndex*: int
    scroll*: int

proc visibleCount(p: PopupList, t: Theme): int = max(1, int((p.rect.h - 8) / t.lineHeight))

proc indexAt(p: PopupList, t: Theme, y: float): int =
  let i = int(floor((y - p.rect.y - 4) / t.lineHeight)) + p.scroll
  if i >= 0 and i < p.elements.len: i else: -1

proc choose(p: PopupList, i: int) =
  if i < 0 or i >= p.elements.len or p.elements[i] == "-": return
  let f = p.win
  let s = p.elements[i]
  closePopup(f)
  p.owner.onPopupChoice(i, s)

method draw*(p: PopupList, d: Drawing, t: Theme) =
  let r = p.rect
  d.shadow(r, t.radius, t.shadow)
  d.fillRoundRect(r, t.radius, t.border)
  let inner = r.shrink(1)
  d.fillRoundRect(inner, t.radius - 1, if t.look == lfMacOS: t.fieldBg else: t.surface)
  d.pushClip(inner)
  let lh = t.lineHeight
  for i in p.scroll ..< min(p.elements.len, p.scroll + p.visibleCount(t)):
    let y = r.y + 4 + float(i - p.scroll) * lh
    let ir = rect(r.x + 4, y, r.w - 8, lh)
    if p.elements[i] == "-":
      d.fillRect(rect(ir.x + 4, y + lh / 2, ir.w - 8, 1), t.border)
      continue
    var col = t.text
    if i == p.hoverIndex:
      if t.accentSelection:
        d.fillRoundRect(ir, 4, t.accent)
        col = t.textOnAccent
      else:
        d.fillRoundRect(ir, 4, t.surfaceHover)
        if t.look == lfWindows: d.fillRoundRect(rect(ir.x, ir.y + lh * 0.3, 3, lh * 0.4), 1.5, t.accent)
    d.textIn(ir, p.elements[i], col, alLeft, 10)
  d.popClip()
  drawScrollIndicator(d, t, rect(r.x + r.w - 8, r.y + 4, 8, r.h - 8),
                    float(p.elements.len), float(p.visibleCount(t)), float(p.scroll))

method onMouse*(p: PopupList, e: MouseEvent) =
  let t = p.win.theme
  case e.action
  of maMove: p.hoverIndex = p.indexAt(t, e.y)
  of maRelease: p.choose(p.indexAt(t, e.y))
  of maPress: discard

method onKey*(p: PopupList, e: KeyEvent): bool =
  let n = p.elements.len
  if n == 0: return false
  let t = p.win.theme
  case e.key
  of SDLK_UP, SDLK_DOWN:
    let s = if e.key == SDLK_UP: -1 else: 1
    var i = p.hoverIndex
    for _ in 0 ..< n:
      i = (i + s + n) mod n
      if p.elements[i] != "-": break
    p.hoverIndex = i
    if i < p.scroll: p.scroll = i
    if i >= p.scroll + p.visibleCount(t): p.scroll = i - p.visibleCount(t) + 1
  of SDLK_RETURN, SDLK_KP_ENTER, SDLK_SPACE: p.choose(p.hoverIndex)
  else: return false
  true

method onWheel*(p: PopupList, dx, dy: float): bool =
  let t = p.win.theme
  p.scroll = clamp(p.scroll - int(dy * 3), 0, max(0, p.elements.len - p.visibleCount(t)))
  true

proc openPopupList*(owner: Control, elements: seq[string], x, y, minWidth: float, sel = -1) =
  # Opens a popup list below (x, y); the choice calls owner.onPopupChoice.
  let f = owner.win
  if f == nil or elements.len == 0: return
  let t = f.theme
  let d = f.drawing
  var w = minWidth
  for e in elements:
    w = max(w, (if d != nil: d.textWidth(e) else: float(e.len) * 16) + 36)
  let n = min(elements.len, 12)
  let h = float(n) * t.lineHeight + 8
  var py = y
  if py + h > float(f.height): py = max(0.0, y - h - t.controlHeight - 4)
  let px = max(0.0, min(x, float(f.width) - w))
  let p = PopupList(elements: elements, owner: owner, hoverIndex: sel)
  initControl(p)
  if sel >= n: p.scroll = sel - n + 1
  openPopup(f, p, rect(px, py, w, h))

# common base for List Box / Combo Box

type
  ListBase* = ref object of Control
    elements*: seq[string]
    selections*: seq[bool]
    current*: int                # 0-based, -1 = none.
    multiSelection*: bool

proc addItem*(l: ListBase, s: string): int =
  l.elements.add s
  l.selections.add false
  l.elements.len

proc insertItem*(l: ListBase, i: int, s: string) =
  let j = clamp(i, 0, l.elements.len)
  l.elements.insert(s, j)
  l.selections.insert(false, j)
  if l.current >= j: inc l.current

proc deleteItem*(l: ListBase, i: int) =
  if i < 0 or i >= l.elements.len: return
  l.elements.delete(i)
  l.selections.delete(i)
  if l.current == i: l.current = min(i, l.elements.high)
  elif l.current > i: dec l.current

proc clearItems*(l: ListBase) =
  l.elements.setLen(0)
  l.selections.setLen(0)
  l.current = -1

proc selectItem*(l: ListBase, i: int, extend = false) =
  if not (l.multiSelection and extend):
    for j in 0 ..< l.selections.len: l.selections[j] = false
  if i >= 0 and i < l.elements.len: l.selections[i] = true
  l.current = i

proc firstSelected*(l: ListBase): int =
  for i, s in l.selections:
    if s: return i
  -1

method valueText*(l: ListBase): string = $(l.firstSelected + 1)

method setValueText*(l: ListBase, v: string) =
  try: l.selectItem(parseInt(v.strip) - 1)
  except ValueError:
    let i = l.elements.find(v)
    if i >= 0: l.selectItem(i)

# List Box

type
  ListBox* = ref object of ListBase
    scroll*: int
    draggingBar: bool
    shiftAnchor: int

proc newListBox*(elements: openArray[string] = [], multiSelection = false): ListBox =
  result = ListBox(multiSelection: multiSelection, current: -1)
  initControl(result)
  result.focusable = true
  for e in elements: discard result.addItem(e)

proc listVisibleCount(l: ListBox, t: Theme): int = max(1, int((l.rect.h - 4) / t.lineHeight))

proc barArea(l: ListBox): Rect = rect(l.rect.x + l.rect.w - 10, l.rect.y + 2, 8, l.rect.h - 4)

proc ensureVisible(l: ListBox, t: Theme) =
  let v = l.listVisibleCount(t)
  if l.current < l.scroll: l.scroll = max(0, l.current)
  if l.current >= l.scroll + v: l.scroll = l.current - v + 1
  l.scroll = clamp(l.scroll, 0, max(0, l.elements.len - v))

proc drawSelectedRow*(d: Drawing, t: Theme, c: Control, r: Rect): Color =
  # Selected-row background according to the platform; returns the text color to use.
  if t.accentSelection and (c.focus or t.look == lfMacOS):
    d.fillRoundRect(r, 4, if c.focus: t.selection else: mix(t.selection, t.border, 0.6))
    return t.textSelection
  d.fillRoundRect(r, 4, t.selection)
  if t.look == lfWindows:
    d.fillRoundRect(rect(r.x + 1, r.y + r.h * 0.25, 3, r.h * 0.5), 1.5, c.style.accent.get(t.accent))
  t.textSelection

method typeName*(l: ListBox): string = "List Box"

method preferredSize*(l: ListBox, d: Drawing, t: Theme): tuple[w, h: float] = (200.0, t.lineHeight * 6 + 4)

method draw*(l: ListBox, d: Drawing, t: Theme) =
  drawFieldFrame(d, t, l, l.rect)
  let z = l.rect.shrink(2)
  let lh = t.lineHeight
  let v = l.listVisibleCount(t)
  let overflows = l.elements.len > v
  d.pushClip(z)
  for i in l.scroll ..< min(l.elements.len, l.scroll + v + 1):
    let rr = rect(z.x + 2, z.y + float(i - l.scroll) * lh, z.w - 4 - (if overflows: 10.0 else: 0.0), lh)
    var col = textColor(l, t)
    if l.selections[i]: col = drawSelectedRow(d, t, l, rr)
    d.textIn(rr, l.elements[i], col, alLeft, 10)
  d.popClip()
  drawScrollIndicator(d, t, l.barArea, float(l.elements.len), float(v), float(l.scroll))

method onMouse*(l: ListBox, e: MouseEvent) =
  let t = l.win.theme
  let v = l.listVisibleCount(t)
  case e.action
  of maPress:
    if l.elements.len > v and l.barArea.containsPoint(e.x, e.y):
      l.draggingBar = true
      l.scroll = int(scrollFromBar(l.barArea, float(l.elements.len), float(v), e.y))
      return
    let i = int(floor((e.y - l.rect.y - 2) / t.lineHeight)) + l.scroll
    if i < 0 or i >= l.elements.len: return
    let ctrl = (e.mods and KMOD_CMD) != 0
    let shift = (e.mods and KMOD_SHIFT) != 0
    if l.multiSelection and shift and l.current >= 0:
      for j in 0 ..< l.selections.len: l.selections[j] = false
      for j in min(l.shiftAnchor, i) .. max(l.shiftAnchor, i): l.selections[j] = true
      l.current = i
    elif l.multiSelection and ctrl:
      l.selections[i] = not l.selections[i]
      l.current = i
      l.shiftAnchor = i
    else:
      l.selectItem(i)
      l.shiftAnchor = i
    emit(l, evSelection, index = i + 1, text = l.elements[i])
  of maMove:
    if l.draggingBar:
      l.scroll = int(scrollFromBar(l.barArea, float(l.elements.len), float(v), e.y))
  of maRelease: l.draggingBar = false

method onKey*(l: ListBox, e: KeyEvent): bool =
  if l.elements.len == 0: return false
  let t = l.win.theme
  let v = l.listVisibleCount(t)
  var i = l.current
  case e.key
  of SDLK_UP: i = max(0, i - 1)
  of SDLK_DOWN: i = min(l.elements.high, i + 1)
  of SDLK_HOME: i = 0
  of SDLK_END: i = l.elements.high
  of SDLK_PAGEUP: i = max(0, i - v)
  of SDLK_PAGEDOWN: i = min(l.elements.high, i + v)
  of SDLK_SPACE:
    if l.multiSelection and i >= 0:
      l.selections[i] = not l.selections[i]
      emit(l, evSelection, index = i + 1, text = l.elements[i])
    return true
  else: return false
  let extend = (e.mods and KMOD_SHIFT) != 0
  l.selectItem(i, extend)
  l.ensureVisible(t)
  emit(l, evSelection, index = i + 1, text = l.elements[i])
  true

method onWheel*(l: ListBox, dx, dy: float): bool =
  let v = l.listVisibleCount(l.win.theme)
  l.scroll = clamp(l.scroll - int(dy * 3), 0, max(0, l.elements.len - v))
  true

# Combo Box

type
  ComboBox* = ref object of ListBase

proc newComboBox*(elements: openArray[string] = [], selection = 0): ComboBox =
  result = ComboBox(current: -1)
  initControl(result)
  result.focusable = true
  for e in elements: discard result.addItem(e)
  if selection >= 0 and selection < elements.len: result.selectItem(selection)

proc openList(c: ComboBox) =
  openPopupList(c, c.elements, c.rect.x, c.rect.y + c.rect.h + 2, c.rect.w, c.current)

method typeName*(c: ComboBox): string = "Combo Box"

method preferredSize*(c: ComboBox, d: Drawing, t: Theme): tuple[w, h: float] =
  var w = 120.0
  for e in c.elements: w = max(w, d.textWidth(e) + 48)
  (w, t.controlHeight)

method draw*(c: ComboBox, d: Drawing, t: Theme) =
  let r = c.rect
  let opened = c.win != nil and c.win.popup != nil and c.win.popup of PopupList and
                PopupList(c.win.popup).owner == Control(c)
  drawPanel(d, t, c, r)
  let s = c.firstSelected
  d.textIn(rect(r.x, r.y, r.w - 28, r.h), (if s >= 0: c.elements[s] else: ""), textColor(c, t), alLeft, 10)
  let col = if c.isGrayed: t.textDisabled else: t.textSecondary
  if t.look == lfMacOS:
    let b = rect(r.x + r.w - 22, r.y + 4, 18, r.h - 8)
    d.fillRoundRect(b, 4, if c.isGrayed: t.textDisabled else: t.accent)
    d.triangle(b.x + b.w / 2, b.y + b.h * 0.32, 7, '^', t.textOnAccent)
    d.triangle(b.x + b.w / 2, b.y + b.h * 0.68, 7, 'v', t.textOnAccent)
  else:
    d.triangle(r.x + r.w - 16, r.y + r.h / 2, 9, (if opened: '^' else: 'v'), col)
  if c.focus: d.drawFocus(t, r, radiusOf(c, t))

method onMouse*(c: ComboBox, e: MouseEvent) =
  if e.action == maPress and e.button == mbLeft: c.openList()

method onPopupChoice*(c: ComboBox, i: int, text: string) =
  c.selectItem(i)
  emit(c, evSelection, index = i + 1, text = text)

method onKey*(c: ComboBox, e: KeyEvent): bool =
  var i = c.current
  case e.key
  of SDLK_SPACE, SDLK_RETURN:
    c.openList()
    return true
  of SDLK_UP: i = max(0, i - 1)
  of SDLK_DOWN:
    if (e.mods and KMOD_ALT) != 0:
      c.openList()
      return true
    i = min(c.elements.high, i + 1)
  else: return false
  if i != c.current and i >= 0:
    c.selectItem(i)
    emit(c, evSelection, index = i + 1, text = c.elements[i])
  true

#  Table

type
  TableColumn* = object
    title*: string
    width*: float
    alignment*: Alignment
  TableControl* = ref object of Control
    columns*: seq[TableColumn]
    rows*: seq[seq[string]]
    selections*: seq[bool]
    current*: int
    multiSelection*: bool
    scroll*: int
    scrollX*: float
    sortColumn*: int             # -1 = not sorted
    sortAscending*: bool
    striped*: bool
    resizeCol: int
    resizeX0, resizeW0: float

proc newTable*(multiSelection = false): TableControl =
  result = TableControl(multiSelection: multiSelection, current: -1, sortColumn: -1,
                      sortAscending: true, striped: true, resizeCol: -1)
  initControl(result)
  result.focusable = true

proc addColumn*(tb: TableControl, title: string, width = 120.0, alignment = alLeft) =
  tb.columns.add TableColumn(title: title, width: width, alignment: alignment)

proc addLine*(tb: TableControl, vals: openArray[string]): int =
  tb.rows.add @vals
  tb.selections.add false
  tb.rows.len

proc selectRow*(tb: TableControl, i: int, extend = false) =
  if not (tb.multiSelection and extend):
    for j in 0 ..< tb.selections.len: tb.selections[j] = false
  if i >= 0 and i < tb.rows.len: tb.selections[i] = true
  tb.current = i

proc sortBy*(tb: TableControl, col: int, ascending = true) =
  # Numeric sort when possible, otherwise alphabetical (case-insensitive).
  let rows = tb.rows
  var idx = toSeq(0 ..< rows.len)
  proc sortKey(i: int): string = (if col < rows[i].len: rows[i][col] else: "")
  idx.sort(proc (a, b: int): int =
    let x = sortKey(a)
    let y = sortKey(b)
    var r = 0
    try: r = cmp(parseFloat(x), parseFloat(y))
    except ValueError: r = cmpIgnoreCase(x, y)
    if ascending: r else: -r)
  let oldSelections = tb.selections
  tb.rows = idx.mapIt(rows[it])
  tb.selections = idx.mapIt(oldSelections[it])
  tb.current = idx.find(tb.current)
  tb.sortColumn = col
  tb.sortAscending = ascending

proc headerHeight(t: Theme): float = t.lineHeight + 2

proc tableVisibleCount(tb: TableControl, t: Theme): int =
  max(1, int((tb.rect.h - headerHeight(t) - 4) / t.lineHeight))

proc totalWidth(tb: TableControl): float =
  for c in tb.columns: result += c.width

proc ensureVisible(tb: TableControl, t: Theme) =
  let v = tb.tableVisibleCount(t)
  if tb.current < tb.scroll: tb.scroll = max(0, tb.current)
  if tb.current >= tb.scroll + v: tb.scroll = tb.current - v + 1

method typeName*(tb: TableControl): string = "Table"

method valueText*(tb: TableControl): string =
  for i, s in tb.selections:
    if s: return $(i + 1)
  "0"

method setValueText*(tb: TableControl, v: string) =
  try: tb.selectRow(parseInt(v.strip) - 1)
  except ValueError: discard

method preferredSize*(tb: TableControl, d: Drawing, t: Theme): tuple[w, h: float] =
  (max(240.0, tb.totalWidth + 4), headerHeight(t) + t.lineHeight * 8 + 4)

method draw*(tb: TableControl, d: Drawing, t: Theme) =
  drawFieldFrame(d, t, tb, tb.rect)
  let z = tb.rect.shrink(2)
  let he = headerHeight(t)
  let lh = t.lineHeight
  let v = tb.tableVisibleCount(t)
  d.pushClip(z)
  # header.
  d.fillRect(rect(z.x, z.y, z.w, he), tb.style.background.get(t.header))
  d.fillRect(rect(z.x, z.y + he - 1, z.w, 1), t.border)
  var x = z.x - tb.scrollX
  for j, c in tb.columns:
    let cr = rect(x, z.y, c.width, he)
    d.textIn(rect(cr.x, cr.y, cr.w - 14, cr.h), c.title, t.textSecondary, c.alignment, 8)
    if tb.sortColumn == j:
      d.triangle(cr.x + cr.w - 10, cr.y + he / 2, 7, (if tb.sortAscending: '^' else: 'v'), t.textSecondary)
    d.fillRect(rect(cr.x + cr.w - 1, cr.y + 5, 1, he - 10), t.border)
    x += c.width
  # rows.
  d.pushClip(rect(z.x, z.y + he, z.w, z.h - he))
  for i in tb.scroll ..< min(tb.rows.len, tb.scroll + v + 1):
    let y = z.y + he + float(i - tb.scroll) * lh
    let lr = rect(z.x, y, z.w, lh)
    var col = textColor(tb, t)
    if tb.selections[i]: col = drawSelectedRow(d, t, tb, lr.shrink(2, 1))
    elif tb.striped and i mod 2 == 1: d.fillRect(lr, withAlpha(t.text, 8))
    var cx = z.x - tb.scrollX
    for j, c in tb.columns:
      if j < tb.rows[i].len:
        d.textIn(rect(cx, y, c.width, lh), tb.rows[i][j], col, c.alignment, 8)
      cx += c.width
  d.popClip()
  d.popClip()
  drawScrollIndicator(d, t, rect(tb.rect.x + tb.rect.w - 10, z.y + he, 8, z.h - he),
                    float(tb.rows.len), float(v), float(tb.scroll))

proc columnEdgeAt(tb: TableControl, x: float): int =
  var cx = tb.rect.x + 2 - tb.scrollX
  for j, c in tb.columns:
    cx += c.width
    if abs(x - cx) <= 4: return j
  -1

proc columnAt(tb: TableControl, x: float): int =
  var cx = tb.rect.x + 2 - tb.scrollX
  for j, c in tb.columns:
    if x >= cx and x < cx + c.width: return j
    cx += c.width
  -1

method mouseCursor*(tb: TableControl, x, y: float): int =
  let t = tb.win.theme
  if (y < tb.rect.y + 2 + headerHeight(t) and tb.columnEdgeAt(x) >= 0) or tb.resizeCol >= 0:
    SDL_SYSTEM_CURSOR_EW_RESIZE
  else: SDL_SYSTEM_CURSOR_DEFAULT

method onMouse*(tb: TableControl, e: MouseEvent) =
  let t = tb.win.theme
  let he = headerHeight(t)
  case e.action
  of maPress:
    if e.y < tb.rect.y + 2 + he:
      let b = tb.columnEdgeAt(e.x)
      if b >= 0:
        tb.resizeCol = b
        tb.resizeX0 = e.x
        tb.resizeW0 = tb.columns[b].width
      else:
        let c = tb.columnAt(e.x)
        if c >= 0 and e.button == mbLeft:
          tb.sortBy(c, if tb.sortColumn == c: not tb.sortAscending else: true)
      return
    let i = int(floor((e.y - tb.rect.y - 2 - he) / t.lineHeight)) + tb.scroll
    if i < 0 or i >= tb.rows.len: return
    if tb.multiSelection and (e.mods and KMOD_CMD) != 0:
      tb.selections[i] = not tb.selections[i]
      tb.current = i
    else:
      tb.selectRow(i)
    emit(tb, evSelection, index = i + 1, text = tb.rows[i].join("\t"))
  of maMove:
    if tb.resizeCol >= 0:
      tb.columns[tb.resizeCol].width = max(24.0, tb.resizeW0 + e.x - tb.resizeX0)
  of maRelease: tb.resizeCol = -1

method onKey*(tb: TableControl, e: KeyEvent): bool =
  if tb.rows.len == 0: return false
  let t = tb.win.theme
  let v = tb.tableVisibleCount(t)
  var i = tb.current
  case e.key
  of SDLK_UP: i = max(0, i - 1)
  of SDLK_DOWN: i = min(tb.rows.high, i + 1)
  of SDLK_HOME: i = 0
  of SDLK_END: i = tb.rows.high
  of SDLK_PAGEUP: i = max(0, i - v)
  of SDLK_PAGEDOWN: i = min(tb.rows.high, i + v)
  of SDLK_LEFT: tb.scrollX = max(0.0, tb.scrollX - 40); return true
  of SDLK_RIGHT: tb.scrollX = min(max(0.0, tb.totalWidth - tb.rect.w + 4), tb.scrollX + 40); return true
  else: return false
  tb.selectRow(i, (e.mods and KMOD_SHIFT) != 0)
  tb.ensureVisible(t)
  emit(tb, evSelection, index = i + 1, text = tb.rows[i].join("\t"))
  true

method onWheel*(tb: TableControl, dx, dy: float): bool =
  let t = tb.win.theme
  let v = tb.tableVisibleCount(t)
  if dx != 0:
    tb.scrollX = clamp(tb.scrollX - dx * 30, 0.0, max(0.0, tb.totalWidth - tb.rect.w + 4))
  tb.scroll = clamp(tb.scroll - int(dy * 3), 0, max(0, tb.rows.len - v))
  true

# TreeView

const TreeSep* = "\t"   # path separator ( TAB, Habit formed with a French IDE ;-) ).

type
  TreeNode* = ref object
    caption*: string
    children*: seq[TreeNode]
    expanded*: bool
    parent*: TreeNode
  TreeView* = ref object of Control
    roots*: seq[TreeNode]
    selection*: TreeNode
    scroll*: int

proc newTreeView*(): TreeView =
  result = TreeView()
  initControl(result)
  result.focusable = true

proc walkTree(ns: seq[TreeNode], lvl: int, acc: var seq[tuple[n: TreeNode, level: int]]) =
  for n in ns:
    acc.add((n, lvl))
    if n.expanded: walkTree(n.children, lvl + 1, acc)

proc visibleNodes*(a: TreeView): seq[tuple[n: TreeNode, level: int]] = walkTree(a.roots, 0, result)

proc pathOf*(n: TreeNode): string =
  var p = n
  var parts: seq[string]
  while p != nil:
    parts.insert(p.caption, 0)
    p = p.parent
  parts.join(TreeSep)

proc findPath*(a: TreeView, path: string): TreeNode =
  var level = a.roots
  for part in path.split(TreeSep):
    result = nil
    for n in level:
      if n.caption == part:
        result = n
        break
    if result == nil: return nil
    level = result.children

proc addPath*(a: TreeView, path: string): TreeNode =
  var parent: TreeNode = nil
  for part in path.split(TreeSep):
    let list = if parent == nil: a.roots else: parent.children
    var found: TreeNode = nil
    for n in list:
      if n.caption == part:
        found = n
        break
    if found == nil:
      found = TreeNode(caption: part, parent: parent)
      if parent == nil: a.roots.add found else: parent.children.add found
    parent = found
  parent

proc deleteNode*(a: TreeView, n: TreeNode) =
  if n == nil: return
  if n.parent == nil:
    let i = a.roots.find(n)
    if i >= 0: a.roots.delete(i)
  else:
    let i = n.parent.children.find(n)
    if i >= 0: n.parent.children.delete(i)
  var p = a.selection
  while p != nil:
    if p == n:
      a.selection = n.parent
      break
    p = p.parent

proc toggle*(a: TreeView, n: TreeNode) =
  if n == nil or n.children.len == 0: return
  n.expanded = not n.expanded
  if not n.expanded:
    var p = a.selection
    while p != nil:
      if p.parent == n:
        a.selection = n
        break
      p = p.parent
  let kind = if n.expanded: evExpand else: evCollapse
  emit(a, kind, text = pathOf(n))

proc treeVisibleCount(a: TreeView, t: Theme): int = max(1, int((a.rect.h - 4) / t.lineHeight))

method typeName*(a: TreeView): string = "TreeView"

method valueText*(a: TreeView): string = (if a.selection != nil: pathOf(a.selection) else: "")

method setValueText*(a: TreeView, v: string) = a.selection = a.findPath(v)

method preferredSize*(a: TreeView, d: Drawing, t: Theme): tuple[w, h: float] = (220.0, t.lineHeight * 8 + 4)

method draw*(a: TreeView, d: Drawing, t: Theme) =
  drawFieldFrame(d, t, a, a.rect)
  let z = a.rect.shrink(2)
  let lh = t.lineHeight
  let vis = a.visibleNodes
  let nv = a.treeVisibleCount(t)
  d.pushClip(z)
  for i in a.scroll ..< min(vis.len, a.scroll + nv + 1):
    let (n, lvl) = vis[i]
    let y = z.y + float(i - a.scroll) * lh
    let lr = rect(z.x + 2, y, z.w - 12, lh)
    var col = textColor(a, t)
    if n == a.selection: col = drawSelectedRow(d, t, a, lr)
    let x = z.x + 6 + float(lvl) * 18
    if n.children.len > 0:
      d.triangle(x + 5, y + lh / 2, 8, (if n.expanded: 'v' else: '>'),
                 if n == a.selection and t.accentSelection: col else: t.textSecondary)
    d.textIn(rect(x + 16, y, max(0.0, lr.x + lr.w - x - 16), lh), n.caption, col)
  d.popClip()
  drawScrollIndicator(d, t, rect(a.rect.x + a.rect.w - 10, z.y, 8, z.h), float(vis.len), float(nv), float(a.scroll))

method onMouse*(a: TreeView, e: MouseEvent) =
  if e.action != maPress: return
  let t = a.win.theme
  let vis = a.visibleNodes
  let i = int(floor((e.y - a.rect.y - 2) / t.lineHeight)) + a.scroll
  if i < 0 or i >= vis.len: return
  let (n, lvl) = vis[i]
  let x = a.rect.x + 2 + 6 + float(lvl) * 18
  if n.children.len > 0 and (e.clicks >= 2 or (e.x >= x - 4 and e.x <= x + 14)):
    a.toggle(n)
    return
  if a.selection != n:
    a.selection = n
    emit(a, evSelection, index = i + 1, text = pathOf(n))

method onKey*(a: TreeView, e: KeyEvent): bool =
  let vis = a.visibleNodes
  if vis.len == 0: return false
  let t = a.win.theme
  var i = 0
  for j, v in vis:
    if v.n == a.selection: i = j
  let n = vis[i].n
  case e.key
  of SDLK_UP: i = max(0, i - 1)
  of SDLK_DOWN: i = min(vis.high, i + 1)
  of SDLK_RIGHT:
    if n.children.len > 0 and not n.expanded:
      a.toggle(n)
      return true
    i = min(vis.high, i + 1)
  of SDLK_LEFT:
    if n.expanded:
      a.toggle(n)
      return true
    if n.parent != nil:
      for j, v in vis:
        if v.n == n.parent: i = j
  of SDLK_SPACE, SDLK_RETURN:
    a.toggle(n)
    return true
  else: return false
  let nv = a.treeVisibleCount(t)
  if i < a.scroll: a.scroll = i
  if i >= a.scroll + nv: a.scroll = i - nv + 1
  if vis[i].n != a.selection:
    a.selection = vis[i].n
    emit(a, evSelection, index = i + 1, text = pathOf(a.selection))
  true

method onWheel*(a: TreeView, dx, dy: float): bool =
  let nv = a.treeVisibleCount(a.win.theme)
  a.scroll = clamp(a.scroll - int(dy * 3), 0, max(0, a.visibleNodes.len - nv))
  true

# Looper

type
  Looper* = ref object of Control
    rows*: seq[seq[string]]    # each row: list of values (1st = title).
    selection*: int
    scroll*: float
    rowHeight*: float          # 0 = automatic.

proc newLooper*(rowHeight = 0.0): Looper =
  result = Looper(selection: -1, rowHeight: rowHeight)
  initControl(result)
  result.focusable = true

proc rowHeightOf(z: Looper, t: Theme): float =
  if z.rowHeight > 0: return z.rowHeight
  var n = 1
  for l in z.rows: n = max(n, l.len)
  float(n) * (t.lineHeight - 6) + 14

method typeName*(z: Looper): string = "Looper"

method valueText*(z: Looper): string = $(z.selection + 1)

method setValueText*(z: Looper, v: string) =
  try: z.selection = clamp(parseInt(v.strip) - 1, -1, z.rows.high)
  except ValueError: discard

method preferredSize*(z: Looper, d: Drawing, t: Theme): tuple[w, h: float] = (260.0, 300.0)

method draw*(z: Looper, d: Drawing, t: Theme) =
  let r = z.rect
  d.fillRoundRect(r, t.fieldRadius, z.style.background.get(mix(t.windowBg, t.surfacePressed, 0.3)))
  let hr = z.rowHeightOf(t)
  let sp = 6.0
  d.pushClip(r)
  for i, l in z.rows:
    let y = r.y + sp + float(i) * (hr + sp) - z.scroll
    if y + hr < r.y or y > r.y + r.h: continue
    let cr = rect(r.x + sp, y, r.w - 2*sp - 8, hr)
    let sel = i == z.selection
    d.fillRoundRect(cr, t.radius + 2, if sel: z.style.accent.get(t.accent) else: t.border)
    d.fillRoundRect(cr.shrink(if sel: 2.0 else: 1.0), t.radius + 1, if sel: t.selection.mix(t.surface, 0.5) else: t.surface)
    for j, v in l:
      let lr = rect(cr.x + 10, cr.y + 7 + float(j) * (t.lineHeight - 6), cr.w - 20, t.lineHeight - 6)
      d.textIn(lr, v, if j == 0: textColor(z, t) else: t.textSecondary)
  d.popClip()
  drawScrollIndicator(d, t, rect(r.x + r.w - 10, r.y + 2, 8, r.h - 4),
                    float(z.rows.len) * (hr + sp) + sp, r.h, z.scroll)
  if z.focus: d.drawFocus(t, r, t.fieldRadius)

method onMouse*(z: Looper, e: MouseEvent) =
  if e.action != maPress: return
  let t = z.win.theme
  let hr = z.rowHeightOf(t)
  let i = int(floor((e.y - z.rect.y - 6 + z.scroll) / (hr + 6)))
  if i >= 0 and i < z.rows.len and i != z.selection:
    z.selection = i
    emit(z, evSelection, index = i + 1, text = z.rows[i].join("\t"))

method onKey*(z: Looper, e: KeyEvent): bool =
  if z.rows.len == 0: return false
  var i = z.selection
  case e.key
  of SDLK_UP: i = max(0, i - 1)
  of SDLK_DOWN: i = min(z.rows.high, i + 1)
  else: return false
  if i != z.selection:
    z.selection = i
    let t = z.win.theme
    let hr = z.rowHeightOf(t) + 6
    let y = float(i) * hr
    if y < z.scroll: z.scroll = y
    if y + hr > z.scroll + z.rect.h: z.scroll = y + hr - z.rect.h + 6
    emit(z, evSelection, index = i + 1, text = z.rows[i].join("\t"))
  true

method onWheel*(z: Looper, dx, dy: float): bool =
  let t = z.win.theme
  let total = float(z.rows.len) * (z.rowHeightOf(t) + 6) + 6
  z.scroll = clamp(z.scroll - dy * 40, 0.0, max(0.0, total - z.rect.h))
  true

# Menu (menu bar)

type
  MenuItem* = object
    caption*: string
    options*: seq[string]     # "-" = separator.
  MenuBar* = ref object of Control
    menus*: seq[MenuItem]
    openIndex*: int
    hoverIndex: int

proc newMenuBar*(): MenuBar =
  result = MenuBar(openIndex: -1, hoverIndex: -1)
  initControl(result)
  result.dock = dkTop

proc addMenuPath*(m: MenuBar, path: string) =
  # path: "File" & TAB & "Open" (or "File" alone to create the menu).
  let p = path.split(TreeSep)
  var i = -1
  for j, e in m.menus:
    if e.caption == p[0]: i = j
  if i < 0:
    m.menus.add MenuItem(caption: p[0])
    i = m.menus.high
  if p.len > 1: m.menus[i].options.add p[1 .. ^1].join(" ")

proc menuRects(m: MenuBar, d: Drawing): seq[Rect] =
  var x = m.rect.x + 4
  for e in m.menus:
    let w = d.textWidth(e.caption) + 20
    result.add rect(x, m.rect.y + 2, w, m.rect.h - 4)
    x += w

proc openMenu(m: MenuBar, i: int) =
  let rs = m.menuRects(m.win.drawing)
  m.openIndex = i
  openPopupList(m, m.menus[i].options, rs[i].x, rs[i].y + rs[i].h + 2, 180)

method typeName*(m: MenuBar): string = "Menu"

method preferredSize*(m: MenuBar, d: Drawing, t: Theme): tuple[w, h: float] = (200.0, t.lineHeight + 6)

method draw*(m: MenuBar, d: Drawing, t: Theme) =
  d.fillRect(m.rect, m.style.background.get(t.header))
  d.fillRect(rect(m.rect.x, m.rect.y + m.rect.h - 1, m.rect.w, 1), t.border)
  let menuOpen = m.win != nil and m.win.popup != nil and m.win.popup of PopupList and
                    PopupList(m.win.popup).owner == Control(m)
  if not m.hovered: m.hoverIndex = -1
  for i, r in m.menuRects(d):
    if (menuOpen and i == m.openIndex) or i == m.hoverIndex:
      d.fillRoundRect(r, t.radius, if menuOpen and i == m.openIndex: t.surfacePressed else: t.surfaceHover)
    d.textIn(r, m.menus[i].caption, textColor(m, t), alCenter)

method onMouse*(m: MenuBar, e: MouseEvent) =
  let rs = m.menuRects(m.win.drawing)
  for i, r in rs:
    if r.containsPoint(e.x, e.y):
      if e.action == maMove: m.hoverIndex = i
      elif e.action == maPress and e.button == mbLeft: m.openMenu(i)
      return
  m.hoverIndex = -1

method onPopupChoice*(m: MenuBar, i: int, text: string) =
  if m.openIndex < 0: return
  emit(m, evSelection, index = i + 1, text = m.menus[m.openIndex].caption & TreeSep & text)
