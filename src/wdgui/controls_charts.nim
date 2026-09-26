# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
# Chart controls: Chart (column, line, area, pie), Calendar, Kanban,
# TreeMap and Gantt Chart.
import std/[math, strutils, times]
import ../sdl3, core

# Chart

type
  ChartKind* = enum
    ckColumn = "Column", ckLine = "Line", ckArea = "Area", ckPie = "Pie"
  Chart* = ref object of Control
    chartKind*: ChartKind
    title*: string
    series*: seq[seq[float]]
    seriesNames*: seq[string]
    categories*: seq[string]
    legend*: bool

proc newChart*(chartKind = ckColumn, title = ""): Chart =
  result = Chart(chartKind: chartKind, title: title, legend: true)
  initControl(result)

proc ensureSize*(g: Chart, seriesIdx, index: int) =
  while g.series.len <= seriesIdx: g.series.add @[]
  while g.seriesNames.len <= seriesIdx: g.seriesNames.add("Series " & $(g.seriesNames.len + 1))
  while g.series[seriesIdx].len <= index: g.series[seriesIdx].add 0.0

proc niceStep(extent: float): float =
  let brut = max(1e-9, extent / 5)
  let mag = pow(10.0, floor(log10(brut)))
  let n = brut / mag
  (if n < 1.5: 1.0 elif n < 3: 2.0 elif n < 7: 5.0 else: 10.0) * mag

method typeName*(g: Chart): string = "Chart"

method preferredSize*(g: Chart, d: Drawing, t: Theme): tuple[w, h: float] = (320.0, 220.0)

method draw*(g: Chart, d: Drawing, t: Theme) =
  let r = g.rect
  d.fillRoundRect(r, t.fieldRadius, t.border)
  d.fillRoundRect(r.shrink(1), t.fieldRadius - 1, g.style.background.get(t.fieldBg))
  let lh = t.lineHeight
  var area = r.shrink(10)
  if g.title.len > 0:
    d.textIn(rect(area.x, area.y, area.w, lh), g.title, textColor(g, t), alCenter)
    area.y += lh
    area.h -= lh
  let pal = t.palette
  var names: seq[string]
  if g.chartKind == ckPie: names = g.categories
  elif g.series.len > 1: names = g.seriesNames
  if g.legend and names.len > 0:
    area.h -= lh
    var x = area.x
    for i, n in names:
      d.fillRoundRect(rect(x, area.y + area.h + lh / 2 - 5, 10, 10), 2, pal[i mod pal.len])
      d.text(x + 14, area.y + area.h + (lh - d.textHeight) / 2, n, t.textSecondary)
      x += d.textWidth(n) + 30
  if g.series.len == 0: return
  if g.chartKind == ckPie:
    let s = g.series[0]
    var total = 0.0
    for v in s: total += max(0.0, v)
    if total <= 0: return
    let rad = min(area.w, area.h) / 2 - 4
    let cx = area.x + area.w / 2
    let cy = area.y + area.h / 2
    var a0 = -PI / 2
    for i, v in s:
      if v <= 0: continue
      let a = v / total * 2 * PI
      var pts: seq[Point]
      pts.add((cx, cy))
      let n = max(2, int(a * 40))
      for k in 0 .. n:
        let aa = a0 + a * float(k) / float(n)
        pts.add((cx + rad * cos(aa), cy + rad * sin(aa)))
      d.fillPolygon(pts, pal[i mod pal.len])
      let am = a0 + a / 2
      if a > 0.3:
        let pct = $int(round(v / total * 100)) & "%"
        d.text(cx + rad * 0.62 * cos(am) - d.textWidth(pct) / 2,
                cy + rad * 0.62 * sin(am) - d.textHeight / 2, pct, White)
      a0 += a
    return
  # axes.
  var vmin, vmax = 0.0
  var n = 0
  for s in g.series:
    n = max(n, s.len)
    for v in s:
      vmin = min(vmin, v)
      vmax = max(vmax, v)
  if vmax == vmin: vmax = vmin + 1
  let step = niceStep(vmax - vmin)
  vmin = floor(vmin / step) * step
  vmax = ceil(vmax / step) * step
  let leftPad = 8 + d.textWidth(formatNumber(vmax)) + 6
  let z = rect(area.x + leftPad, area.y + 4, area.w - leftPad, area.h - lh - 4)
  if z.w <= 0 or z.h <= 0 or n == 0: return
  proc yOf(v: float): float = z.y + z.h - (v - vmin) / (vmax - vmin) * z.h
  var v = vmin
  while v <= vmax + step / 2:
    let y = yOf(v)
    d.fillRect(rect(z.x, y, z.w, 1), withAlpha(t.border, 160))
    let s = formatNumber(v)
    d.text(z.x - d.textWidth(s) - 6, y - d.textHeight / 2, s, t.textSecondary)
    v += step
  let slot = z.w / float(n)
  for i in 0 ..< n:
    if i < g.categories.len:
      d.textIn(rect(z.x + float(i) * slot, z.y + z.h + 2, slot, lh), g.categories[i], t.textSecondary, alCenter)
  let y0 = yOf(max(vmin, 0.0))
  for si, s in g.series:
    let col = pal[si mod pal.len]
    case g.chartKind
    of ckColumn:
      let bw = slot * 0.75 / float(g.series.len)
      for i, val in s:
        let x = z.x + float(i) * slot + slot * 0.125 + float(si) * bw
        let y = yOf(val)
        d.fillRoundRect(rect(x + 1, min(y, y0), bw - 2, abs(y0 - y)), 2, col)
    of ckLine, ckArea:
      var pts: seq[Point]
      for i, val in s: pts.add((z.x + (float(i) + 0.5) * slot, yOf(val)))
      if g.chartKind == ckArea and pts.len > 1:
        var poly = pts
        poly.add((pts[^1].x, y0))
        poly.add((pts[0].x, y0))
        d.fillPolygon(poly, withAlpha(col, 70))
      for i in 1 ..< pts.len: d.line(pts[i-1].x, pts[i-1].y, pts[i].x, pts[i].y, col, 2)
      for p in pts: d.fillCircle(p.x, p.y, 3.5, col)
    of ckPie: discard

#  Calendar

const
  monthNames* = ["January", "February", "March", "April", "May", "June", "July", "August",
               "September", "October", "November", "December"]
  dayNames* = ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]

type
  Calendar* = ref object of Control
    year*, month*: int                 # displayed month.
    selYear*, selMonth*, selDay*: int  # selected date (0 = none).
    hoverDay: int

proc newCalendar*(date = ""): Calendar =
  # date format "YYYYMMDD" (empty = today).
  result = Calendar()
  initControl(result)
  result.focusable = true
  let n = now()
  result.year = n.year
  result.month = n.month.ord
  result.selYear = n.year
  result.selMonth = n.month.ord
  result.selDay = n.monthday.int
  if date.len == 8:
    try:
      result.selYear = parseInt(date[0 .. 3])
      result.selMonth = parseInt(date[4 .. 5])
      result.selDay = parseInt(date[6 .. 7])
      result.year = result.selYear
      result.month = result.selMonth
    except ValueError: discard

proc utcDate(a, m, j: int): DateTime = dateTime(a, Month(m), MonthdayRange(j), 0, 0, 0, 0, utc())

proc shiftMonth(c: Calendar, n: int) =
  var m = c.month - 1 + n
  c.year += floorDiv(m, 12)
  c.month = floorMod(m, 12) + 1
proc firstWeekday(c: Calendar): int = ord(getDayOfWeek(1, Month(c.month), c.year))   # 0 = Monday

proc daysInMonth(a, m: int): int = getDaysInMonth(Month(m), a)

proc calGeometry(c: Calendar, t: Theme): tuple[header, dayRow, grid: Rect] =
  let r = c.rect.shrink(6)
  result.header = rect(r.x, r.y, r.w, t.controlHeight)
  result.dayRow = rect(r.x, r.y + t.controlHeight, r.w, t.lineHeight - 4)
  let y = result.dayRow.y + result.dayRow.h
  result.grid = rect(r.x, y, r.w, max(0.0, r.y + r.h - y))

proc selectDate(c: Calendar, dt: DateTime) =
  c.selYear = dt.year
  c.selMonth = dt.month.ord
  c.selDay = dt.monthday.int
  c.year = c.selYear
  c.month = c.selMonth
  emit(c, evChange, text = align($c.selYear, 4, '0') & align($c.selMonth, 2, '0') & align($c.selDay, 2, '0'))

method typeName*(c: Calendar): string = "Calendar"

method valueText*(c: Calendar): string =
  if c.selDay == 0: "" else: align($c.selYear, 4, '0') & align($c.selMonth, 2, '0') & align($c.selDay, 2, '0')

method setValueText*(c: Calendar, v: string) =
  if v.len != 8:
    c.selDay = 0
    return
  try:
    c.selYear = parseInt(v[0 .. 3])
    c.selMonth = parseInt(v[4 .. 5])
    c.selDay = parseInt(v[6 .. 7])
    c.year = c.selYear
    c.month = c.selMonth
  except ValueError: discard

method preferredSize*(c: Calendar, d: Drawing, t: Theme): tuple[w, h: float] =
  (max(260.0, d.textWidth("We") * 7 + 60), t.controlHeight + t.lineHeight + 6 * (t.lineHeight + 2) + 12)

method draw*(c: Calendar, d: Drawing, t: Theme) =
  let r = c.rect
  d.fillRoundRect(r, t.fieldRadius + 2, t.border)
  d.fillRoundRect(r.shrink(1), t.fieldRadius + 1, c.style.background.get(t.fieldBg))
  let g = c.calGeometry(t)
  let acc = c.style.accent.get(t.accent)
  d.textIn(g.header, monthNames[c.month - 1] & " " & $c.year, textColor(c, t), alCenter)
  d.triangle(g.header.x + 14, g.header.y + g.header.h / 2, 9, '<', t.textSecondary)
  d.triangle(g.header.x + g.header.w - 14, g.header.y + g.header.h / 2, 9, '>', t.textSecondary)
  let cw = g.grid.w / 7
  let ch = g.grid.h / 6
  for i, j in dayNames:
    d.textIn(rect(g.dayRow.x + float(i) * cw, g.dayRow.y, cw, g.dayRow.h), j, t.textSecondary, alCenter)
  let n = now()
  let start = utcDate(c.year, c.month, 1) - initDuration(days = c.firstWeekday)
  if not c.hovered: c.hoverDay = -1
  for k in 0 ..< 42:
    let dt = start + initDuration(days = k)
    let cr = rect(g.grid.x + float(k mod 7) * cw, g.grid.y + float(k div 7) * ch, cw, ch)
    let inMonth = dt.month.ord == c.month
    let sel = dt.year == c.selYear and dt.month.ord == c.selMonth and dt.monthday.int == c.selDay
    let isToday = dt.year == n.year and dt.month == n.month and dt.monthday == n.monthday
    let rr = min(cw, ch) / 2 - 2
    var col = if inMonth: textColor(c, t) else: t.textDisabled
    if sel:
      d.fillCircle(cr.x + cw / 2, cr.y + ch / 2, rr, acc)
      col = t.textOnAccent
    elif k == c.hoverDay:
      d.fillCircle(cr.x + cw / 2, cr.y + ch / 2, rr, t.surfaceHover)
    if isToday and not sel: d.strokeCircle(cr.x + cw / 2, cr.y + ch / 2, rr, acc, 1.5)
    d.textIn(cr, $dt.monthday.int, col, alCenter)
  if c.focus: d.drawFocus(t, r, t.fieldRadius + 2)

method onMouse*(c: Calendar, e: MouseEvent) =
  let t = c.win.theme
  let g = c.calGeometry(t)
  let k = if g.grid.containsPoint(e.x, e.y):
            int((e.y - g.grid.y) / (g.grid.h / 6)) * 7 + int((e.x - g.grid.x) / (g.grid.w / 7))
          else: -1
  case e.action
  of maMove: c.hoverDay = k
  of maPress:
    if e.button != mbLeft: return
    if g.header.containsPoint(e.x, e.y):
      if e.x < g.header.x + 30: c.shiftMonth(-1)
      elif e.x > g.header.x + g.header.w - 30: c.shiftMonth(1)
    elif k >= 0 and k < 42:
      let start = utcDate(c.year, c.month, 1) - initDuration(days = c.firstWeekday)
      c.selectDate(start + initDuration(days = k))
  of maRelease: discard

method onKey*(c: Calendar, e: KeyEvent): bool =
  if c.selDay == 0: return false
  let base = utcDate(c.selYear, c.selMonth, min(c.selDay, daysInMonth(c.selYear, c.selMonth)))
  case e.key
  of SDLK_LEFT: c.selectDate(base - initDuration(days = 1))
  of SDLK_RIGHT: c.selectDate(base + initDuration(days = 1))
  of SDLK_UP: c.selectDate(base - initDuration(days = 7))
  of SDLK_DOWN: c.selectDate(base + initDuration(days = 7))
  of SDLK_PAGEUP: c.shiftMonth(-1)
  of SDLK_PAGEDOWN: c.shiftMonth(1)
  else: return false
  true

method onWheel*(c: Calendar, dx, dy: float): bool =
  c.shiftMonth(if dy > 0: -1 else: 1)
  true

# Kanban

type
  KanbanList* = object
    title*: string
    cards*: seq[string]
  Kanban* = ref object of Control
    lists*: seq[KanbanList]
    selList*, selCard*: int
    dragging: bool
    moved: bool
    srcL, srcC: int

proc newKanban*(): Kanban =
  result = Kanban(selList: -1, selCard: -1)
  initControl(result)
  result.focusable = true

proc kanbanGeometry(k: Kanban, t: Theme): tuple[cw, sp, he, hc: float] =
  let n = max(1, k.lists.len)
  result.sp = 8
  result.cw = (k.rect.w - result.sp * float(n + 1)) / float(n)
  result.he = t.lineHeight + 8
  result.hc = 2 * (t.lineHeight - 6) + 14

proc columnRect(k: Kanban, t: Theme, l: int): Rect =
  let g = k.kanbanGeometry(t)
  rect(k.rect.x + g.sp + float(l) * (g.cw + g.sp), k.rect.y + g.sp, g.cw, k.rect.h - 2 * g.sp)

proc cardRect(k: Kanban, t: Theme, l, c: int): Rect =
  let g = k.kanbanGeometry(t)
  let col = k.columnRect(t, l)
  rect(col.x + 6, col.y + g.he + float(c) * (g.hc + 6), col.w - 12, g.hc)

proc cardAt(k: Kanban, t: Theme, x, y: float): (int, int) =
  for l in 0 ..< k.lists.len:
    for c in 0 ..< k.lists[l].cards.len:
      if k.cardRect(t, l, c).containsPoint(x, y): return (l, c)
  (-1, -1)

proc columnAt(k: Kanban, t: Theme, x, y: float): int =
  for l in 0 ..< k.lists.len:
    if k.columnRect(t, l).containsPoint(x, y): return l
  -1

proc moveCard*(k: Kanban, l1, c1, l2: int, pos = -1) =
  if l1 < 0 or l1 >= k.lists.len or l2 < 0 or l2 >= k.lists.len: return
  if c1 < 0 or c1 >= k.lists[l1].cards.len: return
  let s = k.lists[l1].cards[c1]
  k.lists[l1].cards.delete(c1)
  var p = if pos < 0: k.lists[l2].cards.len else: min(pos, k.lists[l2].cards.len)
  k.lists[l2].cards.insert(s, p)
  k.selList = l2
  k.selCard = p

method typeName*(k: Kanban): string = "Kanban"

method preferredSize*(k: Kanban, d: Drawing, t: Theme): tuple[w, h: float] =
  (float(max(1, k.lists.len)) * 180.0, 300.0)

method draw*(k: Kanban, d: Drawing, t: Theme) =
  let g = k.kanbanGeometry(t)
  let acc = k.style.accent.get(t.accent)
  for l, lst in k.lists:
    let col = k.columnRect(t, l)
    d.fillRoundRect(col, t.radius + 2, k.style.background.get(mix(t.windowBg, t.surfacePressed, 0.6)))
    d.textIn(rect(col.x, col.y, col.w, g.he), lst.title & "  (" & $lst.cards.len & ")", t.textSecondary, alLeft, 10)
    d.pushClip(col)
    for c, card in lst.cards:
      if k.dragging and k.moved and l == k.srcL and c == k.srcC: continue
      let cr = k.cardRect(t, l, c)
      let sel = l == k.selList and c == k.selCard
      d.fillRoundRect(rect(cr.x, cr.y + 1, cr.w, cr.h), t.radius + 1, t.shadow)
      d.fillRoundRect(cr, t.radius + 1, if sel: acc else: t.border)
      d.fillRoundRect(cr.shrink(if sel: 2.0 else: 1.0), t.radius, t.fieldBg)
      let rows = card.split('\n')
      for i, s in rows:
        if i > 1: break
        d.textIn(rect(cr.x + 10, cr.y + 7 + float(i) * (t.lineHeight - 6), cr.w - 20, t.lineHeight - 6),
                    s, if i == 0: t.text else: t.textSecondary)
    d.popClip()
  if k.dragging and k.moved and k.win != nil:
    let cr = rect(k.win.mouseX - g.cw / 2 + 6, k.win.mouseY - g.hc / 2, g.cw - 12, g.hc)
    d.fillRoundRect(cr, t.radius + 1, withAlpha(acc, 200))
    d.textIn(cr, k.lists[k.srcL].cards[k.srcC].split('\n')[0], t.textOnAccent, alLeft, 10)

method onMouse*(k: Kanban, e: MouseEvent) =
  let t = k.win.theme
  case e.action
  of maPress:
    let (l, c) = k.cardAt(t, e.x, e.y)
    if l >= 0:
      k.selList = l
      k.selCard = c
      k.dragging = e.button == mbLeft
      k.moved = false
      k.srcL = l
      k.srcC = c
      emit(k, evSelection, index = c + 1, text = k.lists[l].cards[c])
  of maMove:
    if k.dragging: k.moved = true
  of maRelease:
    if k.dragging and k.moved:
      let l2 = k.columnAt(t, e.x, e.y)
      if l2 >= 0:
        let g = k.kanbanGeometry(t)
        let col = k.columnRect(t, l2)
        let pos = max(0, int((e.y - col.y - g.he) / (g.hc + 6) + 0.5))
        let s = k.lists[k.srcL].cards[k.srcC]
        k.moveCard(k.srcL, k.srcC, l2, pos)
        emit(k, evChange, index = l2 + 1, text = s)
    k.dragging = false
    k.moved = false

# TreeMap

type
  TreeMapItem* = object
    caption*: string
    value*: float
  TreeMap* = ref object of Control
    elements*: seq[TreeMapItem]
    selection*: int
    hoverIndex: int
    rects: seq[tuple[i: int, r: Rect]]

proc newTreeMap*(): TreeMap =
  result = TreeMap(selection: -1, hoverIndex: -1)
  initControl(result)

proc splitLayout(items: seq[tuple[i: int, v: float]], r: Rect, acc: var seq[tuple[i: int, r: Rect]]) =
  # Balanced binary split (close to "squarified"), along the longest side.
  if items.len == 0: return
  if items.len == 1:
    acc.add((items[0].i, r))
    return
  var total = 0.0
  for it in items: total += it.v
  var cumulative = 0.0
  var k = 0
  while k < items.len - 1 and cumulative + items[k].v <= total / 2:
    cumulative += items[k].v
    inc k
  k = clamp(k, 1, items.len - 1)
  var s1 = 0.0
  for j in 0 ..< k: s1 += items[j].v
  let f = if total > 0: s1 / total else: 0.5
  if r.w >= r.h:
    splitLayout(items[0 ..< k], rect(r.x, r.y, r.w * f, r.h), acc)
    splitLayout(items[k .. ^1], rect(r.x + r.w * f, r.y, r.w * (1 - f), r.h), acc)
  else:
    splitLayout(items[0 ..< k], rect(r.x, r.y, r.w, r.h * f), acc)
    splitLayout(items[k .. ^1], rect(r.x, r.y + r.h * f, r.w, r.h * (1 - f)), acc)

method typeName*(tm: TreeMap): string = "TreeMap"

method preferredSize*(tm: TreeMap, d: Drawing, t: Theme): tuple[w, h: float] = (320.0, 220.0)

method draw*(tm: TreeMap, d: Drawing, t: Theme) =
  var items: seq[tuple[i: int, v: float]]
  for i, e in tm.elements:
    if e.value > 0: items.add((i, e.value))
  for a in 0 ..< items.len:          # descending sort (small list: simple sort).
    for b in a + 1 ..< items.len:
      if items[b].v > items[a].v: swap(items[a], items[b])
  tm.rects.setLen(0)
  splitLayout(items, tm.rect, tm.rects)
  let pal = t.palette
  if not tm.hovered: tm.hoverIndex = -1
  for (i, r) in tm.rects:
    var col = pal[i mod pal.len]
    if i == tm.hoverIndex: col = mix(col, White, 0.2)
    let rr = r.shrink(1)
    d.fillRoundRect(rr, 3, col)
    if i == tm.selection: d.strokeRoundRect(rr, 3, t.text, 2)
    if rr.w > 40 and rr.h > d.textHeight * 2 + 8:
      d.textIn(rect(rr.x, rr.y + 4, rr.w, d.textHeight + 4), tm.elements[i].caption, White, alLeft, 6)
      d.textIn(rect(rr.x, rr.y + 8 + d.textHeight, rr.w, d.textHeight + 4),
                  formatNumber(tm.elements[i].value), withAlpha(White, 200), alLeft, 6)

method onMouse*(tm: TreeMap, e: MouseEvent) =
  var foundIdx = -1
  for (i, r) in tm.rects:
    if r.containsPoint(e.x, e.y): foundIdx = i
  case e.action
  of maMove: tm.hoverIndex = foundIdx
  of maPress:
    if foundIdx >= 0 and e.button == mbLeft:
      tm.selection = foundIdx
      emit(tm, evSelection, index = foundIdx + 1, text = tm.elements[foundIdx].caption)
  of maRelease: discard

# Gantt Chart

type
  GanttTask* = object
    caption*: string
    start*, duration*: float     # in units (days, hours...).
    progress*: float             # 0..1.
  Gantt* = ref object of Control
    tasks*: seq[GanttTask]
    labelWidth*: float
    selection*: int
    scroll*: int

proc newGantt*(): Gantt =
  result = Gantt(labelWidth: 140, selection: -1)
  initControl(result)
  result.focusable = true

proc bounds(g: Gantt): (float, float) =
  if g.tasks.len == 0: return (0.0, 10.0)
  var a = g.tasks[0].start
  var b = g.tasks[0].start + g.tasks[0].duration
  for tc in g.tasks:
    a = min(a, tc.start)
    b = max(b, tc.start + tc.duration)
  (floor(a), max(ceil(b), floor(a) + 1))

method typeName*(g: Gantt): string = "Gantt Chart"

method preferredSize*(g: Gantt, d: Drawing, t: Theme): tuple[w, h: float] = (480.0, 220.0)

method draw*(g: Gantt, d: Drawing, t: Theme) =
  let r = g.rect
  d.fillRoundRect(r, t.fieldRadius, t.border)
  d.fillRoundRect(r.shrink(1), t.fieldRadius - 1, g.style.background.get(t.fieldBg))
  let lh = t.lineHeight
  let he = lh
  let zl = rect(r.x + 1, r.y + 1 + he, g.labelWidth, r.h - he - 2)
  let zg = rect(r.x + 1 + g.labelWidth, r.y + 1, r.w - g.labelWidth - 2, r.h - 2)
  let (a, b) = g.bounds
  let u = zg.w / (b - a)
  d.fillRect(rect(r.x + 1, r.y + 1, r.w - 2, he), t.header)
  d.fillRect(rect(zg.x, r.y + 1, 1, r.h - 2), t.border)
  let unitStep = max(1.0, ceil(40 / max(1e-6, u)))
  var v = a
  d.pushClip(zg)
  while v <= b:
    let x = zg.x + (v - a) * u
    d.fillRect(rect(x, zg.y + he, 1, zg.h - he), withAlpha(t.border, 120))
    d.text(x + 3, zg.y + (he - d.textHeight) / 2, formatNumber(v), t.textSecondary)
    v += unitStep
  d.popClip()
  let nv = max(1, int(zl.h / lh))
  let acc = g.style.accent.get(t.accent)
  d.pushClip(rect(r.x, zl.y, r.w, zl.h))
  for i in g.scroll ..< min(g.tasks.len, g.scroll + nv + 1):
    let tc = g.tasks[i]
    let y = zl.y + float(i - g.scroll) * lh
    if i == g.selection: d.fillRect(rect(r.x + 1, y, r.w - 2, lh), t.selection)
    let colL = if i == g.selection: t.textSelection else: textColor(g, t)
    d.textIn(rect(zl.x, y, zl.w, lh), tc.caption, colL, alLeft, 8)
    let br = rect(zg.x + (tc.start - a) * u, y + 5, max(4.0, tc.duration * u), lh - 10)
    d.fillRoundRect(br, 4, mix(acc, t.fieldBg, 0.55))
    if tc.progress > 0:
      d.fillRoundRect(rect(br.x, br.y, br.w * clamp(tc.progress, 0.0, 1.0), br.h), 4, acc)
  d.popClip()
  if g.focus: d.drawFocus(t, r, t.fieldRadius)

method onMouse*(g: Gantt, e: MouseEvent) =
  if e.action != maPress: return
  let t = g.win.theme
  let i = int(floor((e.y - g.rect.y - 1 - t.lineHeight) / t.lineHeight)) + g.scroll
  if i >= 0 and i < g.tasks.len and i != g.selection:
    g.selection = i
    emit(g, evSelection, index = i + 1, text = g.tasks[i].caption)

method onKey*(g: Gantt, e: KeyEvent): bool =
  if g.tasks.len == 0: return false
  var i = g.selection
  case e.key
  of SDLK_UP: i = max(0, i - 1)
  of SDLK_DOWN: i = min(g.tasks.high, i + 1)
  else: return false
  if i != g.selection:
    g.selection = i
    emit(g, evSelection, index = i + 1, text = g.tasks[i].caption)
  true

method onWheel*(g: Gantt, dx, dy: float): bool =
  let t = g.win.theme
  let nv = max(1, int((g.rect.h - t.lineHeight) / t.lineHeight))
  g.scroll = clamp(g.scroll - int(dy * 3), 0, max(0, g.tasks.len - nv))
  true
