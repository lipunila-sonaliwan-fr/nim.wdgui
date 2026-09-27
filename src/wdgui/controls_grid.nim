# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
# Grid control: display and entry of tabular data.
#
# * Rows, columns, header and optional column footers (sum, average, min, max, count).
# * Each column is a sub-control with its own ControlId (caption, visible, width, state…).
# * Read-only or editable at grid, column, row or cell level.
# * Single or multiple row selection.
# * Column kinds: text, number, date ("YYYYMMDD"), image (file path), button, combo, check.
# * Programmed, manual (user inserts / deletes rows) or automatic (columns created on import) filling.
# * Cell access by index or by column name, sorting (header click or code), search.
# * Hidden, moved (drag the header) and resized (drag the header edge) columns.
# * Conditional formatting, breaks (grouping) with per-group aggregates.
# * CSV and JSON import / export.
#
# Events emitted on the grid (ev.index = row, ev.column = column, both 1-based):
# evSelection (current row changed), evChange (cell modified by the user; index 0 = rows
# inserted / deleted), evValidate (a modified row is left or Enter is pressed), and the
# generic evClick / evDoubleClick / evRightClick… which also carry index and column.
import std/[strutils, algorithm, sequtils, json, tables, math]
import ../sdl3, core, controls_basic, controls_lists

type
  GridColumnKind* = enum
    gcText = "Text", gcNumber = "Number", gcDate = "Date", gcImage = "Image",
    gcButton = "Button", gcCombo = "Combo", gcCheck = "Check"

  FooterKind* = enum
    fkNone = "None", fkSum = "Sum", fkAverage = "Average", fkMin = "Min", fkMax = "Max", fkCount = "Count"

  EditMode* = enum
    emInherit = "Inherit", emReadOnly = "ReadOnly", emEditable = "Editable"

  FillMode* = enum
    fmProgrammed = "Programmed"  # rows only come from code (default).
    fmManual = "Manual"          # the user may insert (Insert key) and delete (Delete key) rows.
    fmAutomatic = "Automatic"    # CSV / JSON import creates missing columns automatically.

  ConditionOp* = enum
    coEquals, coNotEquals, coLess, coLessOrEqual, coGreater, coGreaterOrEqual,
    coContains, coEmpty, coNotEmpty

  ConditionalFormat* = object
    column*: int                 # 0-based column tested.
    op*: ConditionOp
    value*: string
    background*, text*: Color    # alpha 0 = unchanged.
    wholeRow*: bool              # apply to the whole row instead of the tested cell.

  GridRow* = object
    cells*: seq[string]
    editMode*: EditMode
    cellModes*: seq[EditMode]
    cellBackground*, cellText*: seq[Color]
    selected*: bool
    modified*: bool

  VisualRow = object
    isBreak: bool
    row, groupEnd: int

  GridColumn* = ref object of Control
    grid*: Grid
    kind*: GridColumnKind
    editMode*: EditMode
    alignment*: Alignment
    decimals*: int               # -1 = raw value.
    choices*: seq[string]        # combo columns.
    buttonCaption*: string       # button columns (empty = cell value).
    footer*: FooterKind
    sortable*: bool

  Grid* = ref object of Control
    columns*: seq[GridColumn]    # data order.
    order*: seq[int]             # display order (column indexes).
    rows*: seq[GridRow]
    current*: int                # current row (0-based, -1 = none).
    currentColumn*: int
    multiSelection*: bool
    editable*: bool
    fillMode*: FillMode
    formats*: seq[ConditionalFormat]
    breakColumn*: int            # -1 = no break.
    sortColumn*: int
    sortAscending*: bool
    striped*: bool
    scroll*: int
    scrollX*: float
    editing*: bool
    editRow, editCol: int
    editor: Edit
    comboPending: bool
    resizeCol: int
    resizeX0, resizeW0: float
    dragCol: int
    dragX: float
    dragMoved: bool
    shiftAnchor: int
    visual: seq[VisualRow]
    textures: Table[string, tuple[tex: SDL_Texture, w, h: float]]

# construction.
proc newGrid*(multiSelection = false, editable = false, fillMode = fmProgrammed): Grid =
  result = Grid(multiSelection: multiSelection, editable: editable, fillMode: fillMode,
                current: -1, breakColumn: -1, sortColumn: -1, sortAscending: true,
                striped: true, resizeCol: -1, dragCol: -1)
  initControl(result)
  result.focusable = true
  result.editor = newEdit()

method typeName*(g: Grid): string = "Grid"
method typeName*(c: GridColumn): string = "Grid Column"

method onAttach*(g: Grid, w: Window) =
  for c in g.columns: attach(c, w)

proc columnIndex*(g: Grid, name: string): int =
  # 0-based index of the column whose name (or title) matches, -1 if none.
  for i, c in g.columns:
    if cmpIgnoreCase(c.name, name) == 0: return i
  for i, c in g.columns:
    if cmpIgnoreCase(c.caption, name) == 0: return i
  -1

proc ensureCells(g: Grid, r: var GridRow) =
  while r.cells.len < g.columns.len: r.cells.add ""

proc newRow(g: Grid, values: openArray[string]): GridRow =
  result.cells = @values
  g.ensureCells(result)

proc addColumn*(g: Grid, name: string, title = "", kind = gcText, width = 120.0,
                choices: openArray[string] = [], decimals = -1): GridColumn =
  let cap = if title.len > 0: title else: name
  result = GridColumn(grid: g, kind: kind, decimals: decimals, choices: @choices, sortable: true)
  initControl(result, cap)
  result.name = name
  result.fixedWidth = width
  result.alignment = case kind
                     of gcNumber: alRight
                     of gcCheck, gcImage, gcButton: alCenter
                     else: alLeft
  g.columns.add result
  g.order.add g.columns.high
  for r in g.rows.mitems: r.cells.add ""
  attach(result, g.win)

proc deleteColumn*(g: Grid, c: int) =
  if c < 0 or c >= g.columns.len: return
  g.columns.delete(c)
  for r in g.rows.mitems:
    if c < r.cells.len: r.cells.delete(c)
    if c < r.cellModes.len: r.cellModes.delete(c)
    if c < r.cellBackground.len: r.cellBackground.delete(c)
    if c < r.cellText.len: r.cellText.delete(c)
  var newOrder: seq[int]
  for k in g.order:
    if k < c: newOrder.add k
    elif k > c: newOrder.add k - 1
  g.order = newOrder
  if g.breakColumn == c: g.breakColumn = -1
  elif g.breakColumn > c: dec g.breakColumn
  if g.sortColumn == c: g.sortColumn = -1
  elif g.sortColumn > c: dec g.sortColumn
  var fs: seq[ConditionalFormat]
  for f in g.formats:
    if f.column != c:
      var f2 = f
      if f2.column > c: dec f2.column
      fs.add f2
  g.formats = fs
  g.currentColumn = clamp(g.currentColumn, 0, max(0, g.columns.high))

proc moveColumn*(g: Grid, c, position: int) =
  # Moves column c (0-based) to display position `position` (0-based).
  let p = g.order.find(c)
  if p < 0: return
  g.order.delete(p)
  g.order.insert(c, clamp(position, 0, g.order.len))

proc addLine*(g: Grid, values: openArray[string]): int =
  g.rows.add g.newRow(values)
  g.rows.len

# values, formats, aggregates.
proc parseNum(s: string, v: var float): bool =
  try:
    v = parseFloat(s.strip.replace(",", "."))
    result = true
  except ValueError:
    result = false

proc displayValue*(col: GridColumn, s: string): string =
  # Text shown in a cell for the stored value `s`.
  result = s
  case col.kind
  of gcNumber:
    var v: float
    if col.decimals >= 0 and parseNum(s, v): result = formatFloat(v, ffDecimal, col.decimals)
  of gcDate:
    if s.len == 8 and s.allCharsInSet(Digits): result = s[0 .. 3] & "-" & s[4 .. 5] & "-" & s[6 .. 7]
  of gcCheck, gcImage: result = ""
  of gcButton:
    if col.buttonCaption.len > 0: result = col.buttonCaption
  else: discard

proc aggregate*(g: Grid, c: int, kind: FooterKind, first = 0, last = -1): float =
  # Aggregate of column c over rows first..last (0-based, last = -1: until the end).
  if c < 0 or c >= g.columns.len: return 0
  let hi = if last < 0: g.rows.high else: min(last, g.rows.high)
  var n = 0
  var s = 0.0
  var mn = Inf
  var mx = NegInf
  for r in max(0, first) .. hi:
    let v0 = g.rows[r].cells[c]
    if kind == fkCount:
      if v0.strip.len > 0: inc n
      continue
    var v: float
    if parseNum(v0, v):
      s += v
      mn = min(mn, v)
      mx = max(mx, v)
      inc n
  case kind
  of fkSum: result = s
  of fkAverage: result = (if n > 0: s / float(n) else: 0.0)
  of fkMin: result = (if n > 0: mn else: 0.0)
  of fkMax: result = (if n > 0: mx else: 0.0)
  of fkCount: result = float(n)
  of fkNone: result = 0.0

proc formatAggregate(col: GridColumn, kind: FooterKind, v: float): string =
  if kind == fkCount: return $int(v)
  if col.decimals >= 0: return formatFloat(v, ffDecimal, col.decimals)
  formatNumber(round(v * 100) / 100)

proc matches(f: ConditionalFormat, s: string): bool =
  var a, b: float
  let numeric = parseNum(s, a) and parseNum(f.value, b)
  let cmpRes = if numeric: cmp(a, b) else: cmpIgnoreCase(s, f.value)
  case f.op
  of coEquals: cmpRes == 0
  of coNotEquals: cmpRes != 0
  of coLess: cmpRes < 0
  of coLessOrEqual: cmpRes <= 0
  of coGreater: cmpRes > 0
  of coGreaterOrEqual: cmpRes >= 0
  of coContains: s.toLowerAscii.contains(f.value.toLowerAscii)
  of coEmpty: s.strip.len == 0
  of coNotEmpty: s.strip.len > 0

proc cellColors(g: Grid, r, c: int): tuple[bg, fg: Color] =
  result = (Transparent, Transparent)
  let row = g.rows[r]
  for f in g.formats:
    if f.column < 0 or f.column >= g.columns.len: continue
    if (f.wholeRow or f.column == c) and f.matches(row.cells[f.column]):
      if f.background.a > 0: result.bg = f.background
      if f.text.a > 0: result.fg = f.text
  if c < row.cellBackground.len and row.cellBackground[c].a > 0: result.bg = row.cellBackground[c]
  if c < row.cellText.len and row.cellText[c].a > 0: result.fg = row.cellText[c]

# edit modes.
proc columnEditable(g: Grid, c: int): bool =
  let col = g.columns[c]
  if col.state != csActive or col.kind in {gcImage, gcButton}: return false
  case col.editMode
  of emEditable: true
  of emReadOnly: false
  of emInherit: g.editable

proc cellEditable*(g: Grid, r, c: int): bool =
  # Effective edit mode: cell, else row, else column, else grid.
  if r < 0 or r >= g.rows.len or c < 0 or c >= g.columns.len: return false
  if g.state != csActive or g.columns[c].kind in {gcImage, gcButton}: return false
  let row = g.rows[r]
  if c < row.cellModes.len and row.cellModes[c] != emInherit: return row.cellModes[c] == emEditable
  if row.editMode != emInherit: return row.editMode == emEditable
  g.columnEditable(c)

# sorting, breaks, search, selection.
proc compareCells(col: GridColumn, a, b: string): int =
  var x, y: float
  if col.kind in {gcNumber, gcCheck} and parseNum(a, x) and parseNum(b, y): return cmp(x, y)
  cmpIgnoreCase(a, b)

proc sortBy*(g: Grid, c: int, ascending = true) =
  # Sorts by column c (0-based, -1 = only the break column). The break column, if any,
  # always stays the primary key so that groups remain contiguous.
  let old = g.rows
  let bc = g.breakColumn
  var idx = toSeq(0 ..< old.len)
  idx.sort(proc (a, b: int): int =
    if bc >= 0 and bc < g.columns.len:
      let r0 = compareCells(g.columns[bc], old[a].cells[bc], old[b].cells[bc])
      if r0 != 0: return r0
    if c >= 0 and c < g.columns.len:
      let r1 = compareCells(g.columns[c], old[a].cells[c], old[b].cells[c])
      return (if ascending: r1 else: -r1)
    0)
  g.rows = idx.mapIt(old[it])
  g.current = idx.find(g.current)
  if c >= 0:
    g.sortColumn = c
    g.sortAscending = ascending

proc setBreak*(g: Grid, c: int) =
  # Groups rows by column c (0-based, -1 = no break).
  g.breakColumn = if c >= 0 and c < g.columns.len: c else: -1
  if g.breakColumn >= 0: g.sortBy(g.sortColumn, g.sortAscending)

proc seek*(g: Grid, c: int, value: string, exact = true, start = 0): int =
  # First row (0-based) from `start` whose cell in column c equals (or contains) value.
  if c < 0 or c >= g.columns.len: return -1
  let q = value.toLowerAscii
  for r in max(0, start) ..< g.rows.len:
    let s = g.rows[r].cells[c].toLowerAscii
    if (exact and s == q) or (not exact and s.contains(q)): return r
  -1

proc shownColumns*(g: Grid): seq[int] =
  for c in g.order:
    if c < g.columns.len and g.columns[c].visible: result.add c

proc findText*(g: Grid, text: string, start = 0): tuple[row, column: int] =
  # First cell (0-based) from row `start` containing `text` in any visible column.
  result = (-1, -1)
  let q = text.toLowerAscii
  for r in max(0, start) ..< g.rows.len:
    for c in g.shownColumns:
      let raw = g.rows[r].cells[c]
      if raw.toLowerAscii.contains(q) or g.columns[c].displayValue(raw).toLowerAscii.contains(q):
        return (r, c)

proc selectRow*(g: Grid, r: int, extend = false) =
  if not (g.multiSelection and extend):
    for x in g.rows.mitems: x.selected = false
  if r >= 0 and r < g.rows.len: g.rows[r].selected = true
  g.current = r

proc validateRow(g: Grid, r: int) =
  if r >= 0 and r < g.rows.len and g.rows[r].modified:
    g.rows[r].modified = false
    emit(g, evValidate, index = r + 1, text = g.rows[r].cells.join("\t"))

proc changeCell(g: Grid, r, c: int, v: string) =
  # Change made by the user: marks the row modified and emits evChange.
  if g.rows[r].cells[c] == v: return
  g.rows[r].cells[c] = v
  g.rows[r].modified = true
  emit(g, evChange, index = r + 1, column = c + 1, text = v)

# geometry.
proc headerH(t: Theme): float =
  t.lineHeight + 4

proc hasFooter(g: Grid): bool =
  for c in g.columns:
    if c.visible and c.footer != fkNone: return true

proc footerH(g: Grid, t: Theme): float =
  (if g.hasFooter: t.lineHeight + 2 else: 0.0)

proc inner(g: Grid): Rect = g.rect.shrink(2)

proc headerRect(g: Grid, t: Theme): Rect =
  let z = g.inner
  rect(z.x, z.y, z.w, headerH(t))

proc bodyRect(g: Grid, t: Theme): Rect =
  let z = g.inner
  rect(z.x, z.y + headerH(t), z.w, max(0.0, z.h - headerH(t) - g.footerH(t)))

proc visibleRowCount(g: Grid, t: Theme): int =
  max(1, int(g.bodyRect(t).h / t.lineHeight))

proc colWidth(g: Grid, c: int): float =
  max(24.0, g.columns[c].fixedWidth)

proc totalWidth(g: Grid): float =
  for c in g.shownColumns: result += g.colWidth(c)

proc colLeft(g: Grid, c: int): float =
  result = g.rect.x + 2 - g.scrollX
  for k in g.shownColumns:
    if k == c: return
    result += g.colWidth(k)
proc columnAtX(g: Grid, x: float): int =
  for c in g.shownColumns:
    let l = g.colLeft(c)
    if x >= l and x < l + g.colWidth(c): return c
  -1
proc columnEdgeAtX(g: Grid, x: float): int =
  for c in g.shownColumns:
    if abs(x - (g.colLeft(c) + g.colWidth(c))) <= 4: return c
  -1

proc buildVisual(g: Grid) =
  g.visual.setLen(0)
  let bc = g.breakColumn
  if bc < 0 or bc >= g.columns.len:
    for i in 0 ..< g.rows.len: g.visual.add VisualRow(row: i, groupEnd: i)
    return
  var i = 0
  while i < g.rows.len:
    let key = g.rows[i].cells[bc]
    var j = i
    while j + 1 < g.rows.len and g.rows[j + 1].cells[bc] == key: inc j
    g.visual.add VisualRow(isBreak: true, row: i, groupEnd: j)
    for k in i .. j: g.visual.add VisualRow(row: k, groupEnd: k)
    i = j + 1

proc visualIndexOf(g: Grid, r: int): int =
  for i, v in g.visual:
    if not v.isBreak and v.row == r: return i
  -1

proc visualAtY(g: Grid, t: Theme, y: float): int =
  let b = g.bodyRect(t)
  if y < b.y or y >= b.y + b.h: return -1
  let i = int((y - b.y) / t.lineHeight) + g.scroll
  if i >= 0 and i < g.visual.len: i else: -1

proc cellRect(g: Grid, t: Theme, r, c: int): Rect =
  let b = g.bodyRect(t)
  let vi = g.visualIndexOf(r)
  rect(g.colLeft(c), b.y + float(vi - g.scroll) * t.lineHeight, g.colWidth(c), t.lineHeight)

proc ensureRowVisible(g: Grid, t: Theme, r: int) =
  g.buildVisual()
  let vi = g.visualIndexOf(r)
  if vi < 0: return
  let n = g.visibleRowCount(t)
  if vi < g.scroll: g.scroll = vi
  if vi >= g.scroll + n: g.scroll = vi - n + 1
  # keep the break header of the first group visible when possible
  if g.scroll > 0 and g.visual[g.scroll - 1].isBreak and vi - (g.scroll - 1) < n: dec g.scroll

proc ensureColVisible(g: Grid, c: int) =
  if c < 0 or c >= g.columns.len: return
  let x = g.colLeft(c) + g.scrollX - (g.rect.x + 2)
  let w = g.colWidth(c)
  let vw = max(10.0, g.rect.w - 14)
  if x < g.scrollX: g.scrollX = x
  if x + w > g.scrollX + vw: g.scrollX = x + w - vw
  g.scrollX = max(0.0, g.scrollX)

# in-place editing.
proc cancelEdit(g: Grid) =
  g.editing = false
  g.editor.focus = false

proc commitEdit(g: Grid) =
  if not g.editing: return
  g.editing = false
  g.editor.focus = false
  let r = g.editRow
  let c = g.editCol
  if r >= g.rows.len or c >= g.columns.len: return
  var v = g.editor.text
  case g.columns[c].kind
  of gcDate:
    var digits = ""
    for ch in v:
      if ch in Digits: digits.add ch
    if digits.len != 8 and v.strip.len > 0: return      # invalid date: keep the old value.
    v = digits
  of gcNumber: v = v.strip.replace(",", ".")
  else: discard
  g.changeCell(r, c, v)

proc startEdit*(g: Grid, r, c: int, initial = "", replace = false) =
  # Starts editing cell (r, c) (0-based) if it is editable.
  if not g.cellEditable(r, c) or g.win == nil: return
  g.commitEdit()
  let col = g.columns[c]
  let t = g.win.theme
  g.ensureRowVisible(t, r)
  g.ensureColVisible(c)
  g.current = r
  g.currentColumn = c
  case col.kind
  of gcCheck:
    g.changeCell(r, c, (if g.rows[r].cells[c] == "1": "0" else: "1"))
    return
  of gcCombo:
    let cr = g.cellRect(t, r, c)
    g.comboPending = true
    g.editRow = r
    g.editCol = c
    openPopupList(g, col.choices, cr.x, cr.y + cr.h, cr.w, col.choices.find(g.rows[r].cells[c]))
    return
  of gcImage, gcButton: return
  else: discard
  g.editing = true
  g.editRow = r
  g.editCol = c
  let e = g.editor
  e.win = g.win
  e.inputKind = (if col.kind == gcNumber: ikReal else: ikText)
  e.multiline = false
  e.setValueText(if replace: initial else: col.displayValue(g.rows[r].cells[c]))
  if not replace: e.anchor = 0         # select everything.
  e.focus = true

proc moveTo(g: Grid, r: int, extend = false) =
  if g.rows.len == 0: return
  let nr = clamp(r, 0, g.rows.high)
  if nr != g.current: g.validateRow(g.current)
  if g.multiSelection and extend and g.current >= 0:
    for x in g.rows.mitems: x.selected = false
    for k in min(g.shiftAnchor, nr) .. max(g.shiftAnchor, nr): g.rows[k].selected = true
    g.current = nr
  else:
    g.selectRow(nr)
    g.shiftAnchor = nr
  if g.win != nil: g.ensureRowVisible(g.win.theme, nr)
  emit(g, evSelection, index = nr + 1, column = g.currentColumn + 1, text = g.rows[nr].cells.join("\t"))

# drawing.
proc texture(g: Grid, d: Drawing, path: string): tuple[tex: SDL_Texture, w, h: float] =
  if path in g.textures: return g.textures[path]
  when defined(sdlimage):
    let s = IMG_Load(path.cstring)
  else:
    let s = SDL_LoadBMP(path.cstring)
  if s != nil:
    result.tex = SDL_CreateTextureFromSurface(d.ren, s)
    SDL_DestroySurface(s)
    if result.tex != nil:
      var w, h: cfloat
      discard SDL_GetTextureSize(result.tex, addr w, addr h)
      result.w = float(w)
      result.h = float(h)
  g.textures[path] = result

proc drawCell(g: Grid, d: Drawing, t: Theme, col: GridColumn, cr: Rect, v: string, fg: Color) =
  case col.kind
  of gcCheck:
    let s = min(t.checkSize, cr.h - 6)
    let bx = rect(cr.x + (cr.w - s) / 2, cr.y + (cr.h - s) / 2, s, s)
    if v == "1" or v.toLowerAscii == "true":
      d.fillRoundRect(bx, t.checkRadius, col.style.accent.get(t.accent))
      d.drawCheckMark(bx.shrink(s * 0.12), t.textOnAccent, 2)
    else:
      d.fillRoundRect(bx, t.checkRadius, t.border)
      d.fillRoundRect(bx.shrink(1), max(0.0, t.checkRadius - 1), t.fieldBg)
  of gcImage:
    if v.len == 0: return
    let e = g.texture(d, v)
    if e.tex == nil: return
    let k = min((cr.w - 4) / max(1.0, e.w), (cr.h - 4) / max(1.0, e.h))
    d.drawTexture(e.tex, rect(cr.x + (cr.w - e.w * k) / 2, cr.y + (cr.h - e.h * k) / 2, e.w * k, e.h * k))
  of gcButton:
    let br = cr.shrink(4, 3)
    d.fillRoundRect(br, t.radius, t.border)
    d.fillRoundRect(br.shrink(1), max(0.0, t.radius - 1), t.surface)
    d.textIn(br, col.displayValue(v), t.text, alCenter, 4)
  of gcCombo:
    d.textIn(rect(cr.x, cr.y, cr.w - 16, cr.h), v, fg, col.alignment, 8)
    d.triangle(cr.x + cr.w - 10, cr.y + cr.h / 2, 7, 'v', t.textSecondary)
  else:
    d.textIn(cr, col.displayValue(v), fg, col.alignment, 8)

method preferredSize*(g: Grid, d: Drawing, t: Theme): tuple[w, h: float] =
  (max(300.0, g.totalWidth + 4), headerH(t) + t.lineHeight * 8 + g.footerH(t) + 4)

method draw*(g: Grid, d: Drawing, t: Theme) =
  g.buildVisual()
  drawFieldFrame(d, t, g, g.rect)
  let z = g.inner
  let hh = headerH(t)
  let fh = g.footerH(t)
  let b = g.bodyRect(t)
  let lh = t.lineHeight
  let cols = g.shownColumns
  let acc = g.style.accent.get(t.accent)
  for c in cols: g.columns[c].rect = rect(g.colLeft(c), z.y, g.colWidth(c), hh)
  d.pushClip(z)
  # header.
  d.fillRect(rect(z.x, z.y, z.w, hh), t.header)
  d.fillRect(rect(z.x, z.y + hh - 1, z.w, 1), t.border)
  for c in cols:
    let col = g.columns[c]
    let hr = col.rect
    if g.dragCol == c and g.dragMoved: d.fillRect(hr, withAlpha(acc, 50))
    let hc = if col.isGrayed: t.textDisabled else: col.style.text.get(t.textSecondary)
    let ha = if col.alignment == alRight: alRight else: alLeft
    d.textIn(rect(hr.x, hr.y, hr.w - 14, hr.h), col.caption, hc, ha, 8)
    if g.sortColumn == c:
      d.triangle(hr.x + hr.w - 10, hr.y + hh / 2, 7, (if g.sortAscending: '^' else: 'v'), t.textSecondary)
    d.fillRect(rect(hr.x + hr.w - 1, hr.y + 5, 1, hh - 10), t.border)
  if g.dragCol >= 0 and g.dragMoved and g.win != nil:
    let target = g.columnAtX(g.win.mouseX)
    if target >= 0: d.fillRect(rect(g.colLeft(target), z.y, 2, z.h), acc)
  # rows.
  d.pushClip(b)
  let n = g.visibleRowCount(t)
  for vi in g.scroll ..< min(g.visual.len, g.scroll + n + 1):
    let vr = g.visual[vi]
    let y = b.y + float(vi - g.scroll) * lh
    let lr = rect(z.x, y, z.w, lh)
    if vr.isBreak:
      let bc = g.breakColumn
      d.fillRect(lr, mix(t.header, acc, 0.12))
      d.fillRect(rect(lr.x, lr.y + lh - 1, lr.w, 1), t.border)
      let key = g.columns[bc].displayValue(g.rows[vr.row].cells[bc])
      let shownKey = if key.len > 0: key else: "-"
      let label = g.columns[bc].caption & ": " & shownKey & "  (" & $(vr.groupEnd - vr.row + 1) & ")"
      d.text(lr.x + 8, y + (lh - d.textHeight) / 2, label, t.text)
      let labelEnd = lr.x + 16 + d.textWidth(label)
      for c in cols:
        let col = g.columns[c]
        if col.footer != fkNone and g.colLeft(c) >= labelEnd:
          let v = g.aggregate(c, col.footer, vr.row, vr.groupEnd)
          d.textIn(rect(g.colLeft(c), y, g.colWidth(c), lh), formatAggregate(col, col.footer, v),
                   t.textSecondary, alRight, 8)
      continue
    let r = vr.row
    let row = g.rows[r]
    var fg = textColor(g, t)
    if row.selected: fg = drawSelectedRow(d, t, g, lr.shrink(2, 1))
    elif g.striped and r mod 2 == 1: d.fillRect(lr, withAlpha(t.text, 8))
    for c in cols:
      let col = g.columns[c]
      let cr = rect(g.colLeft(c), y, g.colWidth(c), lh)
      let cc = g.cellColors(r, c)
      if cc.bg.a > 0: d.fillRect(cr.shrink(1, 0), cc.bg)
      let colr = if cc.fg.a > 0: cc.fg elif col.isGrayed: t.textDisabled else: fg
      g.drawCell(d, t, col, cr, row.cells[c], colr)
      d.fillRect(rect(cr.x + cr.w - 1, cr.y, 1, cr.h), withAlpha(t.border, 90))
      if g.focus and r == g.current and c == g.currentColumn and not g.editing:
        d.strokeRect(cr.shrink(1), acc, 2)
  if g.editing and g.editRow < g.rows.len:
    g.editor.rect = g.cellRect(t, g.editRow, g.editCol)
    g.editor.draw(d, t)
  d.popClip()
  # footer.
  if fh > 0:
    let fr = rect(z.x, z.y + z.h - fh, z.w, fh)
    d.fillRect(fr, t.header)
    d.fillRect(rect(fr.x, fr.y, fr.w, 1), t.border)
    for c in cols:
      let col = g.columns[c]
      if col.footer == fkNone: continue
      let v = g.aggregate(c, col.footer)
      d.textIn(rect(g.colLeft(c), fr.y, g.colWidth(c), fh),
               $col.footer & ": " & formatAggregate(col, col.footer, v), t.text, alRight, 8)
  d.popClip()
  drawScrollIndicator(d, t, rect(g.rect.x + g.rect.w - 10, b.y, 8, b.h),
                      float(g.visual.len), float(n), float(g.scroll))

# interaction.
method hitInfo*(g: Grid, x, y: float): tuple[index, column: int] =
  if g.win == nil: return (0, 0)
  let t = g.win.theme
  g.buildVisual()
  let c = g.columnAtX(x)
  if g.headerRect(t).containsPoint(x, y): return (0, c + 1)
  let vi = g.visualAtY(t, y)
  if vi < 0 or g.visual[vi].isBreak: return (0, c + 1)
  (g.visual[vi].row + 1, c + 1)

method mouseCursor*(g: Grid, x, y: float): int =
  if g.win == nil: return SDL_SYSTEM_CURSOR_DEFAULT
  let t = g.win.theme
  if g.resizeCol >= 0 or (g.headerRect(t).containsPoint(x, y) and g.columnEdgeAtX(x) >= 0):
    SDL_SYSTEM_CURSOR_EW_RESIZE
  elif g.editing and g.editor.rect.containsPoint(x, y): SDL_SYSTEM_CURSOR_TEXT
  else: SDL_SYSTEM_CURSOR_DEFAULT

method acceptsText*(g: Grid): bool =
  g.editing or g.cellEditable(g.current, g.currentColumn)

method onFocus*(g: Grid, gained: bool) =
  if not gained:
    g.commitEdit()
    g.validateRow(g.current)

method onMouse*(g: Grid, e: MouseEvent) =
  if g.win == nil: return
  let t = g.win.theme
  g.buildVisual()
  if g.editing and g.editor.rect.containsPoint(e.x, e.y):
    g.editor.pressed = g.pressed
    g.editor.onMouse(e)
    return
  case e.action
  of maPress:
    g.comboPending = false
    if g.headerRect(t).containsPoint(e.x, e.y):
      g.commitEdit()
      let edge = g.columnEdgeAtX(e.x)
      if edge >= 0:
        g.resizeCol = edge
        g.resizeX0 = e.x
        g.resizeW0 = g.colWidth(edge)
      else:
        g.dragCol = g.columnAtX(e.x)
        g.dragX = e.x
        g.dragMoved = false
      return
    g.commitEdit()
    let vi = g.visualAtY(t, e.y)
    if vi < 0 or g.visual[vi].isBreak: return
    let r = g.visual[vi].row
    let c = g.columnAtX(e.x)
    if c >= 0: g.currentColumn = c
    let wasCurrent = r == g.current
    if g.multiSelection and (e.mods and KMOD_CMD) != 0:
      if r != g.current: g.validateRow(g.current)
      g.rows[r].selected = not g.rows[r].selected
      g.current = r
      g.shiftAnchor = r
      emit(g, evSelection, index = r + 1, column = c + 1, text = g.rows[r].cells.join("\t"))
    else:
      g.moveTo(r, (e.mods and KMOD_SHIFT) != 0)
    if c < 0 or e.button != mbLeft: return
    let col = g.columns[c]
    if col.kind == gcCheck and e.clicks < 2 and g.cellEditable(r, c):
      g.changeCell(r, c, (if g.rows[r].cells[c] == "1": "0" else: "1"))
    elif col.kind == gcCombo and g.cellEditable(r, c) and (wasCurrent or e.clicks >= 2):
      g.startEdit(r, c)
    elif col.kind in {gcText, gcNumber, gcDate} and e.clicks >= 2:
      g.startEdit(r, c)
  of maMove:
    if g.resizeCol >= 0:
      g.columns[g.resizeCol].fixedWidth = max(24.0, g.resizeW0 + e.x - g.resizeX0)
    elif g.dragCol >= 0 and abs(e.x - g.dragX) > 6:
      g.dragMoved = true
  of maRelease:
    if g.dragCol >= 0:
      if g.dragMoved:
        let target = g.columnAtX(e.x)
        if target >= 0 and target != g.dragCol:
          g.moveColumn(g.dragCol, g.order.find(target))
      elif g.columns[g.dragCol].sortable and e.button == mbLeft:
        let c = g.dragCol
        g.sortBy(c, (if g.sortColumn == c: not g.sortAscending else: true))
    g.dragCol = -1
    g.dragMoved = false
    g.resizeCol = -1

method onKey*(g: Grid, e: KeyEvent): bool =
  if g.win == nil: return false
  let t = g.win.theme
  g.buildVisual()
  if g.editing:
    case e.key
    of SDLK_RETURN, SDLK_KP_ENTER:
      g.commitEdit()
      return true
    of SDLK_ESCAPE:
      g.cancelEdit()
      return true
    of SDLK_UP, SDLK_DOWN:
      let r = g.editRow
      g.commitEdit()
      g.moveTo(r + (if e.key == SDLK_UP: -1 else: 1))
      return true
    else:
      return g.editor.onKey(e)
  let shift = (e.mods and KMOD_SHIFT) != 0
  let cols = g.shownColumns
  let n = g.visibleRowCount(t)
  if g.rows.len == 0 and e.key != SDLK_INSERT: return false
  case e.key
  of SDLK_UP: g.moveTo(g.current - 1, shift)
  of SDLK_DOWN: g.moveTo(g.current + 1, shift)
  of SDLK_PAGEUP: g.moveTo(g.current - n, shift)
  of SDLK_PAGEDOWN: g.moveTo(g.current + n, shift)
  of SDLK_HOME: g.moveTo(0, shift)
  of SDLK_END: g.moveTo(g.rows.high, shift)
  of SDLK_LEFT, SDLK_RIGHT:
    if cols.len == 0: return true
    var p = cols.find(g.currentColumn)
    p = clamp(p + (if e.key == SDLK_LEFT: -1 else: 1), 0, cols.high)
    g.currentColumn = cols[p]
    g.ensureColVisible(g.currentColumn)
  of SDLK_RETURN, SDLK_KP_ENTER, SDLK_F2:
    if g.cellEditable(g.current, g.currentColumn):
      g.startEdit(g.current, g.currentColumn)
    else:
      g.validateRow(g.current)
      return e.key == SDLK_F2    # let Enter reach the default button.
  of SDLK_SPACE:
    if g.current >= 0 and g.currentColumn < g.columns.len and
       g.columns[g.currentColumn].kind == gcCheck and g.cellEditable(g.current, g.currentColumn):
      g.startEdit(g.current, g.currentColumn)
    elif g.multiSelection and g.current >= 0:
      g.rows[g.current].selected = not g.rows[g.current].selected
    else: return false
  of SDLK_DELETE:
    if g.fillMode != fmManual or g.state != csActive: return false
    var removed = 0
    var i = g.rows.high
    while i >= 0:
      if g.rows[i].selected:
        g.rows.delete(i)
        inc removed
      dec i
    if removed > 0:
      g.current = min(g.current, g.rows.high)
      if g.current >= 0: g.rows[g.current].selected = true
      emit(g, evChange, index = 0, column = 0, text = "delete " & $removed)
  of SDLK_INSERT:
    if g.fillMode != fmManual or g.state != csActive: return false
    g.rows.add g.newRow(newSeq[string]())
    let r = g.rows.high
    g.rows[r].modified = true
    g.moveTo(r)
    emit(g, evChange, index = r + 1, column = 0, text = "insert")
    for c in cols:
      if g.cellEditable(r, c) and g.columns[c].kind in {gcText, gcNumber, gcDate}:
        g.startEdit(r, c)
        break
  of SDLK_A:
    if (e.mods and KMOD_CMD) == 0 or not g.multiSelection: return false
    for x in g.rows.mitems: x.selected = true
  else: return false
  true

method onText*(g: Grid, s: string) =
  if g.editing:
    g.editor.onText(s)
  elif s != " " and g.cellEditable(g.current, g.currentColumn) and
       g.columns[g.currentColumn].kind in {gcText, gcNumber, gcDate}:
    g.startEdit(g.current, g.currentColumn, s, replace = true)

method onWheel*(g: Grid, dx, dy: float): bool =
  if g.win == nil: return false
  let t = g.win.theme
  g.buildVisual()
  if dx != 0:
    g.scrollX = clamp(g.scrollX - dx * 30, 0.0, max(0.0, g.totalWidth - g.rect.w + 14))
  g.scroll = clamp(g.scroll - int(dy * 3), 0, max(0, g.visual.len - g.visibleRowCount(t)))
  true

method onPopupChoice*(g: Grid, i: int, text: string) =
  if g.comboPending:
    g.comboPending = false
    if g.editRow < g.rows.len and g.editCol < g.columns.len: g.changeCell(g.editRow, g.editCol, text)
  else:
    procCall onPopupChoice(Control(g), i, text)

method valueText*(g: Grid): string = $(g.current + 1)

method setValueText*(g: Grid, v: string) =
  try: g.selectRow(parseInt(v.strip) - 1)
  except ValueError: discard

# CSV / JSON.
proc csvField(s: string, sep: char): string =
  if s.contains(sep) or s.contains('"') or s.contains('\n') or s.contains('\r'):
    "\"" & s.replace("\"", "\"\"") & "\""
  else: s

proc parseCsvText*(text: string, sep = ','): seq[seq[string]] =
  # RFC 4180 parser (quoted fields, doubled quotes, CRLF / LF line ends).
  var row: seq[string]
  var field = ""
  var inQuotes = false
  var pending = false
  var i = 0
  while i < text.len:
    let ch = text[i]
    if inQuotes:
      if ch == '"':
        if i + 1 < text.len and text[i + 1] == '"':
          field.add '"'
          inc i
        else:
          inQuotes = false
      else:
        field.add ch
    elif ch == '"':
      inQuotes = true
      pending = true
    elif ch == sep:
      row.add field
      field = ""
      pending = true
    elif ch == '\r':
      discard
    elif ch == '\n':
      row.add field
      result.add row
      row = @[]
      field = ""
      pending = false
    else:
      field.add ch
      pending = true
    inc i
  if pending or field.len > 0 or row.len > 0:
    row.add field
    result.add row

proc guessKind(values: seq[string]): GridColumnKind =
  var num, total = 0
  for v in values:
    if v.strip.len == 0: continue
    inc total
    var f: float
    if parseNum(v, f): inc num
  if total > 0 and num == total: gcNumber else: gcText

proc mapColumns(g: Grid, names: seq[string], data: seq[seq[string]]): seq[int] =
  let autoCreate = g.columns.len == 0 or g.fillMode == fmAutomatic
  for k, n in names:
    var c = g.columnIndex(n)
    if c < 0 and autoCreate and n.len > 0:
      var vals: seq[string]
      for row in data:
        if k < row.len: vals.add row[k]
      discard g.addColumn(n, n, guessKind(vals))
      c = g.columns.high
    result.add c

proc clearRows(g: Grid) =
  g.rows.setLen(0)
  g.current = -1
  g.scroll = 0
  g.cancelEdit()

proc toCsv*(g: Grid, sep = ',', header = true): string =
  # Exports every column (data order); the header line holds the column names.
  var lines: seq[string]
  if header: lines.add g.columns.mapIt(csvField(it.name, sep)).join($sep)
  for r in g.rows:
    var fields: seq[string]
    for c in 0 ..< g.columns.len: fields.add csvField(r.cells[c], sep)
    lines.add fields.join($sep)
  lines.join("\n") & "\n"

proc fromCsv*(g: Grid, text: string, sep = ',', header = true, append = false): int =
  # Imports CSV; returns the number of rows read. Columns are matched by name (header) or
  # position; missing ones are created when the grid has no column or fillMode = fmAutomatic.
  var data = parseCsvText(text, sep)
  if data.len == 0: return 0
  var names: seq[string]
  if header:
    names = data[0]
    data.delete(0)
  else:
    var w = 0
    for row in data: w = max(w, row.len)
    for k in 0 ..< w:
      names.add(if k < g.columns.len: g.columns[k].name else: "Column" & $(k + 1))
  if not append: g.clearRows()
  let mapping = g.mapColumns(names, data)
  for row in data:
    var nr = g.newRow(newSeq[string]())
    for k, c in mapping:
      if c >= 0 and k < row.len: nr.cells[c] = row[k]
    g.rows.add nr
  data.len

proc jsonToCell(n: JsonNode): string =
  case n.kind
  of JString: n.getStr
  of JInt: $n.getInt
  of JFloat: formatNumber(n.getFloat)
  of JBool: (if n.getBool: "1" else: "0")
  of JNull: ""
  else: $n

proc kindFromJson(n: JsonNode): GridColumnKind =
  case n.kind
  of JInt, JFloat: gcNumber
  of JBool: gcCheck
  else: gcText

proc toJson*(g: Grid, pretty = true): string =
  # Array of objects keyed by column name; numbers and check boxes keep their JSON type.
  var arr = newJArray()
  for r in g.rows:
    var o = newJObject()
    for c, col in g.columns:
      let key = if col.name.len > 0: col.name else: col.caption
      let v = r.cells[c]
      var f: float
      case col.kind
      of gcNumber:
        if parseNum(v, f):
          if f == floor(f) and abs(f) < 1e15: o[key] = newJInt(BiggestInt(f))
          else: o[key] = newJFloat(f)
        else: o[key] = newJString(v)
      of gcCheck: o[key] = newJBool(v == "1")
      else: o[key] = newJString(v)
    arr.add o
  if pretty: arr.pretty else: $arr

proc fromJson*(g: Grid, text: string, append = false): int =
  # Imports an array of objects (or of arrays), or {"rows": [...]}. Returns the number
  # of rows read, -1 if the text is not valid JSON.
  var root: JsonNode
  try:
    root = parseJson(text)
  except CatchableError:
    return -1
  if root.kind == JObject and root.hasKey("rows"): root = root["rows"]
  if root.kind != JArray: return -1
  let autoCreate = g.columns.len == 0 or g.fillMode == fmAutomatic
  if not append: g.clearRows()
  for item in root:
    var nr = g.newRow(newSeq[string]())
    if item.kind == JObject:
      for key, val in item.pairs:
        var c = g.columnIndex(key)
        if c < 0 and autoCreate:
          discard g.addColumn(key, key, kindFromJson(val))
          c = g.columns.high
        if c >= 0:
          g.ensureCells(nr)
          nr.cells[c] = jsonToCell(val)
    elif item.kind == JArray:
      var k = 0
      for val in item:
        if k < g.columns.len: nr.cells[k] = jsonToCell(val)
        inc k
    g.ensureCells(nr)
    g.rows.add nr
    inc result

proc writeText(path, s: string): bool =
  try:
    writeFile(path, s)
    result = true
  except IOError:
    result = false

proc readText(path: string, s: var string): bool =
  try:
    s = readFile(path)
    result = true
  except IOError:
    result = false

# id-based API (thread-safe).
# Rows and columns are 1-based, as in WINDEV. Every column-taking function also exists
# with the column name (string) instead of its index.

proc gridColumnIndex*(id: ControlId, name: string): int =
  # 1-based index of the column named `name` (or titled), 0 if not found.
  readControl(id, Grid, g): result = g.columnIndex(name) + 1

proc gridAddColumn*(id: ControlId, name: string, title = "", kind = gcText, width = 120.0,
                    choices: openArray[string] = [], decimals = -1): ControlId =
  # Adds a column; returns its own ControlId (a sub-control: caption, visible, width, state...).
  let ch = @choices
  withControl(id, Grid, g):
    result = g.addColumn(name, title, kind, width, ch, decimals).id

proc gridColumn*(id: ControlId, col: int): ControlId =
  readControl(id, Grid, g):
    if col - 1 in 0 ..< g.columns.len: result = g.columns[col - 1].id

proc gridColumn*(id: ControlId, col: string): ControlId =
  gridColumn(id, gridColumnIndex(id, col))

proc gridColumnCount*(id: ControlId): int =
  readControl(id, Grid, g): result = g.columns.len

proc gridDeleteColumn*(id: ControlId, col: int) =
  withControl(id, Grid, g): g.deleteColumn(col - 1)

proc gridDeleteColumn*(id: ControlId, col: string) =
  gridDeleteColumn(id, gridColumnIndex(id, col))

proc gridMoveColumn*(id: ControlId, col, position: int) =
  # Moves a column to a 1-based display position.
  withControl(id, Grid, g): g.moveColumn(col - 1, position - 1)

proc gridMoveColumn*(id: ControlId, col: string, position: int) =
  gridMoveColumn(id, gridColumnIndex(id, col), position)

proc gridShowColumn*(id: ControlId, col: int, visible = true) =
  withControl(id, Grid, g):
    if col - 1 in 0 ..< g.columns.len: g.columns[col - 1].visible = visible

proc gridShowColumn*(id: ControlId, col: string, visible = true) =
  gridShowColumn(id, gridColumnIndex(id, col), visible)

proc gridSetColumnWidth*(id: ControlId, col: int, width: float) =
  withControl(id, Grid, g):
    if col - 1 in 0 ..< g.columns.len: g.columns[col - 1].fixedWidth = width

proc gridSetColumnWidth*(id: ControlId, col: string, width: float) =
  gridSetColumnWidth(id, gridColumnIndex(id, col), width)

proc gridSetChoices*(id: ControlId, col: int, choices: openArray[string]) =
  let ch = @choices
  withControl(id, Grid, g):
    if col - 1 in 0 ..< g.columns.len: g.columns[col - 1].choices = ch

proc gridSetChoices*(id: ControlId, col: string, choices: openArray[string]) =
  gridSetChoices(id, gridColumnIndex(id, col), choices)

proc gridSetButtonCaption*(id: ControlId, col: int, caption: string) =
  withControl(id, Grid, g):
    if col - 1 in 0 ..< g.columns.len: g.columns[col - 1].buttonCaption = caption

proc gridSetButtonCaption*(id: ControlId, col: string, caption: string) =
  gridSetButtonCaption(id, gridColumnIndex(id, col), caption)

proc gridSetDecimals*(id: ControlId, col: int, decimals: int) =
  withControl(id, Grid, g):
    if col - 1 in 0 ..< g.columns.len: g.columns[col - 1].decimals = decimals

proc gridSetDecimals*(id: ControlId, col: string, decimals: int) =
  gridSetDecimals(id, gridColumnIndex(id, col), decimals)

proc gridSetFooter*(id: ControlId, col: int, kind: FooterKind) =
  withControl(id, Grid, g):
    if col - 1 in 0 ..< g.columns.len: g.columns[col - 1].footer = kind

proc gridSetFooter*(id: ControlId, col: string, kind: FooterKind) =
  gridSetFooter(id, gridColumnIndex(id, col), kind)

proc gridFooterValue*(id: ControlId, col: int, kind = fkNone): float =
  # Aggregate of a column (its footer kind when `kind` = fkNone).
  readControl(id, Grid, g):
    if col - 1 in 0 ..< g.columns.len:
      let k = if kind == fkNone: g.columns[col - 1].footer else: kind
      result = g.aggregate(col - 1, k)

proc gridFooterValue*(id: ControlId, col: string, kind = fkNone): float =
  gridFooterValue(id, gridColumnIndex(id, col), kind)

# rows.
proc gridAddLine*(id: ControlId, values: varargs[string]): int =
  # Adds a line (values in column order); returns its 1-based index.
  result = -1
  let v = @values
  withControl(id, Grid, g): result = g.addLine(v)

proc gridInsertLine*(id: ControlId, row: int, values: varargs[string]) =
  let v = @values
  withControl(id, Grid, g):
    let i = clamp(row - 1, 0, g.rows.len)
    g.rows.insert(g.newRow(v), i)
    if g.current >= i: inc g.current

proc gridModifyLine*(id: ControlId, row: int, values: varargs[string]) =
  let v = @values
  withControl(id, Grid, g):
    if row - 1 in 0 ..< g.rows.len:
      for c in 0 ..< min(v.len, g.columns.len): g.rows[row - 1].cells[c] = v[c]

proc gridDeleteLine*(id: ControlId, row: int) =
  withControl(id, Grid, g):
    if row - 1 in 0 ..< g.rows.len:
      g.cancelEdit()
      g.rows.delete(row - 1)
      if g.current >= g.rows.len: g.current = g.rows.high

proc gridDeleteAll*(id: ControlId) =
  withControl(id, Grid, g): g.clearRows()

proc gridLine*(id: ControlId, row: int): seq[string] =
  readControl(id, Grid, g):
    if row - 1 in 0 ..< g.rows.len: result = g.rows[row - 1].cells

proc gridCount*(id: ControlId): int =
  readControl(id, Grid, g): result = g.rows.len

# cells.
proc gridCell*(id: ControlId, row, col: int): string =
  readControl(id, Grid, g):
    if row - 1 in 0 ..< g.rows.len and col - 1 in 0 ..< g.columns.len:
      result = g.rows[row - 1].cells[col - 1]

proc gridCell*(id: ControlId, row: int, col: string): string =
  gridCell(id, row, gridColumnIndex(id, col))

proc gridSetCell*(id: ControlId, row, col: int, value: string) =
  # Programmatic change (no evChange).
  withControl(id, Grid, g):
    if row - 1 in 0 ..< g.rows.len and col - 1 in 0 ..< g.columns.len:
      g.rows[row - 1].cells[col - 1] = value

proc gridSetCell*(id: ControlId, row: int, col: string, value: string) =
  gridSetCell(id, row, gridColumnIndex(id, col), value)

proc gridSetCellColor*(id: ControlId, row, col: int, background = Transparent, text = Transparent) =
  withControl(id, Grid, g):
    if row - 1 in 0 ..< g.rows.len and col - 1 in 0 ..< g.columns.len:
      var r = addr g.rows[row - 1]
      while r.cellBackground.len < g.columns.len: r.cellBackground.add Transparent
      while r.cellText.len < g.columns.len: r.cellText.add Transparent
      r.cellBackground[col - 1] = background
      r.cellText[col - 1] = text
proc gridSetCellColor*(id: ControlId, row: int, col: string, background = Transparent, text = Transparent) =
  gridSetCellColor(id, row, gridColumnIndex(id, col), background, text)

# selection.
proc gridSelect*(id: ControlId, rank = 1): int =
  # 1-based index of the rank-th selected line, -1 if none.
  result = -1
  readControl(id, Grid, g):
    var n = 0
    for i, r in g.rows:
      if r.selected:
        inc n
        if n == rank: return i + 1

proc gridSelectCount*(id: ControlId): int =
  readControl(id, Grid, g):
    for r in g.rows:
      if r.selected: inc result

proc gridSelectPlus*(id: ControlId, row: int) =
  # Selects a line (added to the selection in multi-selection mode) and makes it current.
  withControl(id, Grid, g):
    if row - 1 in 0 ..< g.rows.len:
      g.selectRow(row - 1, extend = true)
      if g.win != nil: g.ensureRowVisible(g.win.theme, row - 1)

proc gridSelectMinus*(id: ControlId, row: int) =
  withControl(id, Grid, g):
    if row - 1 in 0 ..< g.rows.len: g.rows[row - 1].selected = false

proc gridSelectAll*(id: ControlId) =
  withControl(id, Grid, g):
    if g.multiSelection:
      for r in g.rows.mitems: r.selected = true

proc gridCurrentColumn*(id: ControlId): int =
  readControl(id, Grid, g): result = g.currentColumn + 1

# edit modes and fill mode.
proc gridSetEditable*(id: ControlId, editable: bool) =
  # Grid-level mode: consultation (false) or entry (true).
  withControl(id, Grid, g):
    g.editable = editable
    if not editable: g.cancelEdit()

proc gridSetColumnEdit*(id: ControlId, col: int, mode: EditMode) =
  withControl(id, Grid, g):
    if col - 1 in 0 ..< g.columns.len: g.columns[col - 1].editMode = mode

proc gridSetColumnEdit*(id: ControlId, col: string, mode: EditMode) =
  gridSetColumnEdit(id, gridColumnIndex(id, col), mode)

proc gridSetLineEdit*(id: ControlId, row: int, mode: EditMode) =
  withControl(id, Grid, g):
    if row - 1 in 0 ..< g.rows.len: g.rows[row - 1].editMode = mode

proc gridSetCellEdit*(id: ControlId, row, col: int, mode: EditMode) =
  withControl(id, Grid, g):
    if row - 1 in 0 ..< g.rows.len and col - 1 in 0 ..< g.columns.len:
      var r = addr g.rows[row - 1]
      while r.cellModes.len < g.columns.len: r.cellModes.add emInherit
      r.cellModes[col - 1] = mode

proc gridSetCellEdit*(id: ControlId, row: int, col: string, mode: EditMode) =
  gridSetCellEdit(id, row, gridColumnIndex(id, col), mode)

proc gridStartEdit*(id: ControlId, row, col: int) =
  withControl(id, Grid, g): g.startEdit(row - 1, col - 1)

proc gridStartEdit*(id: ControlId, row: int, col: string) =
  gridStartEdit(id, row, gridColumnIndex(id, col))

proc gridSetFillMode*(id: ControlId, mode: FillMode) =
  withControl(id, Grid, g): g.fillMode = mode

# sort, search, breaks, formats.
proc gridSort*(id: ControlId, col: int, ascending = true) =
  withControl(id, Grid, g): g.sortBy(col - 1, ascending)

proc gridSort*(id: ControlId, col: string, ascending = true) =
  gridSort(id, gridColumnIndex(id, col), ascending)

proc gridSeek*(id: ControlId, col: int, value: string, exact = true, start = 1): int =
  # 1-based line whose cell equals (exact) or contains the value, -1 if not found.
  result = -1
  readControl(id, Grid, g):
    let r = g.seek(col - 1, value, exact, start - 1)
    result = if r >= 0: r + 1 else: -1

proc gridSeek*(id: ControlId, col: string, value: string, exact = true, start = 1): int =
  gridSeek(id, gridColumnIndex(id, col), value, exact, start)

proc gridFind*(id: ControlId, text: string, start = 1, select = true): tuple[row, column: int] =
  # Searches every visible column; optionally selects the line found. (-1, -1) if not found.
  result = (-1, -1)
  withControl(id, Grid, g):
    let f = g.findText(text, start - 1)
    if f.row >= 0:
      result = (f.row + 1, f.column + 1)
      if select:
        g.selectRow(f.row)
        g.currentColumn = f.column
        if g.win != nil: g.ensureRowVisible(g.win.theme, f.row)
        g.ensureColVisible(f.column)

proc gridSetBreak*(id: ControlId, col: int) =
  # Groups lines by a column (0 = no break).
  withControl(id, Grid, g): g.setBreak(col - 1)

proc gridSetBreak*(id: ControlId, col: string) =
  gridSetBreak(id, (if col.len == 0: 0 else: gridColumnIndex(id, col)))

proc gridAddFormat*(id: ControlId, col: int, op: ConditionOp, value = "",
                    background = Transparent, text = Transparent, wholeRow = false) =
  # Conditional formatting: when the cell of `col` matches, colors the cell (or the row).
  withControl(id, Grid, g):
    g.formats.add ConditionalFormat(column: col - 1, op: op, value: value,
                                    background: background, text: text, wholeRow: wholeRow)

proc gridAddFormat*(id: ControlId, col: string, op: ConditionOp, value = "",
                    background = Transparent, text = Transparent, wholeRow = false) =
  gridAddFormat(id, gridColumnIndex(id, col), op, value, background, text, wholeRow)

proc gridClearFormats*(id: ControlId) =
  withControl(id, Grid, g): g.formats.setLen(0)

# import / export.
proc gridToCsv*(id: ControlId, sep = ',', header = true): string =
  readControl(id, Grid, g): result = g.toCsv(sep, header)

proc gridFromCsv*(id: ControlId, text: string, sep = ',', header = true, append = false): int =
  withControl(id, Grid, g): result = g.fromCsv(text, sep, header, append)

proc gridSaveCsv*(id: ControlId, path: string, sep = ',', header = true): bool =
  writeText(path, gridToCsv(id, sep, header))

proc gridLoadCsv*(id: ControlId, path: string, sep = ',', header = true, append = false): int =
  # Returns the number of lines read, -1 if the file cannot be read.
  var s: string
  if not readText(path, s): return -1
  gridFromCsv(id, s, sep, header, append)

proc gridToJson*(id: ControlId, pretty = true): string =
  readControl(id, Grid, g): result = g.toJson(pretty)

proc gridFromJson*(id: ControlId, text: string, append = false): int =
  withControl(id, Grid, g): result = g.fromJson(text, append)

proc gridSaveJson*(id: ControlId, path: string, pretty = true): bool =
  writeText(path, gridToJson(id, pretty))

proc gridLoadJson*(id: ControlId, path: string, append = false): int =
  var s: string
  if not readText(path, s): return -1
  gridFromJson(id, s, append)
