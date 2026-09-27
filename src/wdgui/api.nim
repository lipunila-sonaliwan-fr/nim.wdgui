# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
# Id-based API callable from any thread
# (in particular from a window's event handler).
#
# Properties: `id.value`, `id.caption = "..."`, `id.visible = false`, `id.state = csGrayed`...
# (equivalent to ..Value, ..Caption, ..Visible, ..State).
# Functions: listAdd, tableAddLine, treeAdd, grAddData... (1-based indexes).
import std/[strutils]
import core, controls_basic, controls_lists, controls_charts

# generic properties

proc caption*(id: ControlId): string =
  readControl(id, Control, c):
    result = if c of Window: Window(c).title else: c.caption

proc `caption=`*(id: ControlId, v: string) =
  withControl(id, Control, c):
    c.caption = v
    if c of Window: Window(c).title = v

proc value*(id: ControlId): string =
  # ..Value (as a string; 1-based index for lists / radio buttons / tabs,
  # "YYYYMMDD" for a calendar, bit mask for a multi-option check box).
  readControl(id, Control, c): result = c.valueText
proc `value=`*(id: ControlId, v: string) =
  withControl(id, Control, c): c.setValueText(v)

proc valueNum*(id: ControlId): float =
  readControl(id, Control, c): result = c.valueNum

proc `valueNum=`*(id: ControlId, v: float) =
  withControl(id, Control, c): c.setValueNum(v)

proc visible*(id: ControlId): bool =
  readControl(id, Control, c): result = c.visible

proc `visible=`*(id: ControlId, v: bool) =
  withControl(id, Control, c): c.visible = v

proc state*(id: ControlId): ControlState =
  readControl(id, Control, c): result = c.state

proc `state=`*(id: ControlId, v: ControlState) =
  withControl(id, Control, c): c.state = v

proc tooltip*(id: ControlId): string =
  readControl(id, Control, c): result = c.tooltip

proc `tooltip=`*(id: ControlId, v: string) =
  withControl(id, Control, c): c.tooltip = v

proc name*(id: ControlId): string =
  readControl(id, Control, c): result = c.name

proc `name=`*(id: ControlId, v: string) =
  withControl(id, Control, c): c.name = v

proc x*(id: ControlId): float =
  readControl(id, Control, c): result = c.rect.x

proc y*(id: ControlId): float =
  readControl(id, Control, c): result = c.rect.y

proc width*(id: ControlId): float =
  readControl(id, Control, c): result = c.rect.w

proc height*(id: ControlId): float =
  readControl(id, Control, c): result = c.rect.h

proc `x=`*(id: ControlId, v: float) =
  withControl(id, Control, c): c.fixedX = v

proc `y=`*(id: ControlId, v: float) =
  withControl(id, Control, c): c.fixedY = v

proc `width=`*(id: ControlId, v: float) =
  withControl(id, Control, c): c.fixedWidth = v

proc `height=`*(id: ControlId, v: float) =
  withControl(id, Control, c): c.fixedHeight = v

proc `weight=`*(id: ControlId, v: float) =
  withControl(id, Control, c): c.weight = v

proc color*(id: ControlId): Color =
  readControl(id, Control, c): result = c.style.text.get(Black)

proc `color=`*(id: ControlId, v: Color) =
  withControl(id, Control, c): c.style.text = some(v)

proc `backgroundColor=`*(id: ControlId, v: Color) =
  withControl(id, Control, c): c.style.background = some(v)

proc `borderColor=`*(id: ControlId, v: Color) =
  withControl(id, Control, c): c.style.border = some(v)

proc `accentColor=`*(id: ControlId, v: Color) =
  withControl(id, Control, c): c.style.accent = some(v)

proc `radius=`*(id: ControlId, v: float) =
  withControl(id, Control, c): c.style.radius = some(v)

proc style*(id: ControlId): Style =
  readControl(id, Control, c): result = c.style

proc `style=`*(id: ControlId, v: Style) =
  withControl(id, Control, c): c.style = v

proc controlType*(id: ControlId): string =
  readControl(id, Control, c): result = c.typeName

proc parentControl*(id: ControlId): ControlId =
  readControl(id, Control, c):
    result = if c.parent != nil: c.parent.id elif c.win != nil and Control(c.win) != c: c.win.id else: NoControl

proc windowOf*(id: ControlId): ControlId =
  readControl(id, Control, c):
    if c.win != nil: result = c.win.id

proc children*(id: ControlId): seq[ControlId] =
  readControl(id, Control, c):
    let k = if c of Window: Window(c).root elif c of Container: Container(c) else: nil
    if k != nil:
      for e in k.children: result.add e.id

proc findByName(c: Control, n: string): Control =
  if c.name == n: return c
  if c of Container:
    for e in Container(c).children:
      let r = findByName(e, n)
      if r != nil: return r

proc controlByName*(winId: ControlId, n: string): ControlId =
  # Finds a control by name (e.g. "EDT_Name") inside a window.
  readControl(winId, Window, f):
    let r = findByName(f.root, n)
    if r != nil: result = r.id

proc setFocus*(id: ControlId) =
  withControl(id, Control, c):
    if c.win != nil and c.focusable: setFocusInternal(c.win, c)

proc currentControl*(winId: ControlId): ControlId =
  # Id of the control that has the focus.
  readControl(winId, Window, f):
    if f.focusedControl != nil: result = f.focusedControl.id

proc deleteControl*(id: ControlId) =
  withControl(id, Control, c):
    if c.parent != nil:
      let i = c.parent.children.find(c)
      if i >= 0: c.parent.children.delete(i)
      if c.win != nil:
        if c.win.focusedControl == c: c.win.focusedControl = nil
        if c.win.hoveredControl == c: c.win.hoveredControl = nil
        if c.win.capturedControl == c: c.win.capturedControl = nil
      c.parent = nil

proc theme*(winId: ControlId): Theme =
  readControl(winId, Window, f): result = f.theme
proc `theme=`*(winId: ControlId, t: Theme) =
  # Changes a window's look & feel on the fly.
  withControl(winId, Window, f): f.theme = t

proc closeWindow*(winId: ControlId) =
  # Closes (Close) a window.
  withControl(winId, Window, f): f.closeRequested = true

proc refresh*(id: ControlId) =
  # Forces a redraw (equivalent to Refresh / grDraw).
  withControl(id, Control, c): discard

proc openContextMenu*(id: ControlId, options: openArray[string], x = -1.0, y = -1.0) =
  # Opens a context menu attached to the control; the choice emits evSelection on it
  # (ev.index = 1-based option, ev.text = caption). "-" = separator.
  let opts = @options
  withControl(id, Control, c):
    if c.win != nil:
      let px = if x < 0: c.win.mouseX else: x
      let py = if y < 0: c.win.mouseY else: y
      openPopupList(c, opts, px, py, 160)

# List Box / Combo Box

proc listAdd*(id: ControlId, s: string): int =
  # ListAdd: returns the 1-based index of the added item, -1 on error.
  result = -1
  withControl(id, ListBase, l): result = l.addItem(s)

proc listInsert*(id: ControlId, s: string, index: int) =
  withControl(id, ListBase, l): l.insertItem(index - 1, s)

proc listDelete*(id: ControlId, index: int) =
  withControl(id, ListBase, l): l.deleteItem(index - 1)

proc listDeleteAll*(id: ControlId) =
  withControl(id, ListBase, l): l.clearItems()

proc listSelect*(id: ControlId, rank = 1): int =
  # ListSelect: 1-based index of the rank-th selected item, -1 if none.
  result = -1
  readControl(id, ListBase, l):
    var n = 0
    for i, s in l.selections:
      if s:
        inc n
        if n == rank: return i + 1

proc listSelectPlus*(id: ControlId, index: int) =
  withControl(id, ListBase, l): l.selectItem(index - 1, extend = true)

proc listSelectMinus*(id: ControlId, index: int) =
  withControl(id, ListBase, l):
    if index - 1 in 0 ..< l.selections.len: l.selections[index - 1] = false

proc listCount*(id: ControlId): int =
  readControl(id, ListBase, l): result = l.elements.len

proc listItem*(id: ControlId, index: int): string =
  # Equivalent to LIST[index] / ListInfoXY.
  readControl(id, ListBase, l):
    if index - 1 in 0 ..< l.elements.len: result = l.elements[index - 1]

proc listModify*(id: ControlId, s: string, index: int) =
  withControl(id, ListBase, l):
    if index - 1 in 0 ..< l.elements.len: l.elements[index - 1] = s

proc listSeek*(id: ControlId, s: string, exact = true): int =
  result = -1
  readControl(id, ListBase, l):
    for i, e in l.elements:
      if (exact and e == s) or (not exact and e.toLowerAscii.startsWith(s.toLowerAscii)):
        return i + 1

# Check Box / Radio Button

proc checkBoxValue*(id: ControlId, index: int): bool =
  readControl(id, CheckBox, c):
    if index - 1 in 0 ..< c.checked.len: result = c.checked[index - 1]

proc checkBoxSet*(id: ControlId, index: int, v: bool) =
  withControl(id, CheckBox, c):
    if index - 1 in 0 ..< c.checked.len: c.checked[index - 1] = v

proc checkBoxAdd*(id: ControlId, caption: string, checked = false) =
  withControl(id, CheckBox, c):
    c.options.add caption
    c.checked.add checked

proc radioAdd*(id: ControlId, caption: string) =
  withControl(id, RadioButton, c): c.options.add caption

# bounds (progress bar, sliders, spin, scrollbar)

proc minBound*(id: ControlId): float =
  readControl(id, Control, c):
    if c of ProgressBar: result = ProgressBar(c).minValue
    elif c of Slider: result = Slider(c).minValue
    elif c of RangeSlider: result = RangeSlider(c).minValue
    elif c of Spin: result = Spin(c).minValue
    elif c of Scrollbar: result = Scrollbar(c).minValue

proc maxBound*(id: ControlId): float =
  readControl(id, Control, c):
    if c of ProgressBar: result = ProgressBar(c).maxValue
    elif c of Slider: result = Slider(c).maxValue
    elif c of RangeSlider: result = RangeSlider(c).maxValue
    elif c of Spin: result = Spin(c).maxValue
    elif c of Scrollbar: result = Scrollbar(c).maxValue

proc `minBound=`*(id: ControlId, v: float) =
  withControl(id, Control, c):
    if c of ProgressBar: ProgressBar(c).minValue = v
    elif c of Slider: Slider(c).minValue = v
    elif c of RangeSlider: RangeSlider(c).minValue = v
    elif c of Spin: Spin(c).minValue = v
    elif c of Scrollbar: Scrollbar(c).minValue = v

proc `maxBound=`*(id: ControlId, v: float) =
  withControl(id, Control, c):
    if c of ProgressBar: ProgressBar(c).maxValue = v
    elif c of Slider: Slider(c).maxValue = v
    elif c of RangeSlider: RangeSlider(c).maxValue = v
    elif c of Spin: Spin(c).maxValue = v
    elif c of Scrollbar: Scrollbar(c).maxValue = v

proc rangeValues*(id: ControlId): tuple[lower, upper: float] =
  readControl(id, RangeSlider, c): result = (c.lowValue, c.highValue)

proc rangeSet*(id: ControlId, lower, upper: float) =
  withControl(id, RangeSlider, c):
    c.lowValue = clamp(min(lower, upper), c.minValue, c.maxValue)
    c.highValue = clamp(max(lower, upper), c.minValue, c.maxValue)

# Table

proc tableAddColumn*(id: ControlId, title: string, width = 120.0, alignment = alLeft) =
  withControl(id, TableControl, tb): tb.addColumn(title, width, alignment)

proc tableAddLine*(id: ControlId, vals: varargs[string]): int =
  # TableAddLine: returns the 1-based index of the added line.
  result = -1
  let v = @vals
  withControl(id, TableControl, tb): result = tb.addLine(v)

proc tableInsertLine*(id: ControlId, index: int, vals: varargs[string]) =
  let v = @vals
  withControl(id, TableControl, tb):
    let i = clamp(index - 1, 0, tb.rows.len)
    tb.rows.insert(v, i)
    tb.selections.insert(false, i)

proc tableDelete*(id: ControlId, index: int) =
  withControl(id, TableControl, tb):
    if index - 1 in 0 ..< tb.rows.len:
      tb.rows.delete(index - 1)
      tb.selections.delete(index - 1)
      tb.current = min(tb.current, tb.rows.high)

proc tableDeleteAll*(id: ControlId) =
  withControl(id, TableControl, tb):
    tb.rows.setLen(0)
    tb.selections.setLen(0)
    tb.current = -1
    tb.scroll = 0

proc tableSelect*(id: ControlId, rank = 1): int =
  result = -1
  readControl(id, TableControl, tb):
    var n = 0
    for i, s in tb.selections:
      if s:
        inc n
        if n == rank: return i + 1

proc tableSelectPlus*(id: ControlId, index: int) =
  withControl(id, TableControl, tb): tb.selectRow(index - 1, extend = true)

proc tableCount*(id: ControlId): int =
  readControl(id, TableControl, tb): result = tb.rows.len

proc tableCell*(id: ControlId, line, column: int): string =
  readControl(id, TableControl, tb):
    if line - 1 in 0 ..< tb.rows.len and column - 1 in 0 ..< tb.rows[line - 1].len:
      result = tb.rows[line - 1][column - 1]

proc tableSetCell*(id: ControlId, line, column: int, v: string) =
  withControl(id, TableControl, tb):
    if line - 1 in 0 ..< tb.rows.len and column >= 1:
      while tb.rows[line - 1].len < column: tb.rows[line - 1].add ""
      tb.rows[line - 1][column - 1] = v

proc tableLine*(id: ControlId, line: int): seq[string] =
  readControl(id, TableControl, tb):
    if line - 1 in 0 ..< tb.rows.len: result = tb.rows[line - 1]

proc tableSort*(id: ControlId, column: int, ascending = true) =
  withControl(id, TableControl, tb): tb.sortBy(column - 1, ascending)

# TreeView

proc treeAdd*(id: ControlId, path: string, expanded = false) =
  # TreeAdd: TAB-separated path (TreeSep), e.g. "Root" & TreeSep & "Child".
  withControl(id, TreeView, a):
    let n = a.addPath(path)
    if expanded and n != nil: n.expanded = true

proc treeDelete*(id: ControlId, path: string) =
  withControl(id, TreeView, a): a.deleteNode(a.findPath(path))

proc treeDeleteAll*(id: ControlId) =
  withControl(id, TreeView, a):
    a.roots.setLen(0)
    a.selection = nil
    a.scroll = 0

proc treeExpand*(id: ControlId, path: string) =
  withControl(id, TreeView, a):
    var n = a.findPath(path)
    while n != nil:
      n.expanded = true
      n = n.parent

proc treeCollapse*(id: ControlId, path: string) =
  withControl(id, TreeView, a):
    let n = a.findPath(path)
    if n != nil: n.expanded = false

proc treeIsExpanded*(id: ControlId, path: string): bool =
  # True if the node is expanded.
  readControl(id, TreeView, a):
    let n = a.findPath(path)
    result = n != nil and n.expanded

proc treeSelect*(id: ControlId): string =
  readControl(id, TreeView, a):
    if a.selection != nil: result = pathOf(a.selection)

proc treeSelectPlus*(id: ControlId, path: string) =
  withControl(id, TreeView, a):
    let n = a.findPath(path)
    if n != nil:
      a.selection = n
      var p = n.parent
      while p != nil:
        p.expanded = true
        p = p.parent

proc treeCount*(id: ControlId): int =
  readControl(id, TreeView, a): result = a.visibleNodes.len

# Tab

proc tabAdd*(id: ControlId, title: string, layout = lkVertical): ControlId =
  # Adds a pane; returns the id of its container.
  var o: Tab
  readControl(id, Tab, c): o = c
  if o != nil: result = o.addPage(title, layout).id

# Chart

proc grAddData*(id: ControlId, seriesIdx, index: int, v: float) =
  # 1-based series and index.
  withControl(id, Chart, g):
    if seriesIdx >= 1 and index >= 1:
      g.ensureSize(seriesIdx - 1, index - 1)
      g.series[seriesIdx - 1][index - 1] = v

proc grCategoryLabel*(id: ControlId, index: int, s: string) =
  withControl(id, Chart, g):
    if index >= 1:
      while g.categories.len < index: g.categories.add ""
      g.categories[index - 1] = s

proc grSeriesLabel*(id: ControlId, seriesIdx: int, s: string) =
  withControl(id, Chart, g):
    if seriesIdx >= 1:
      g.ensureSize(seriesIdx - 1, 0)
      g.seriesNames[seriesIdx - 1] = s

proc grType*(id: ControlId, t: ChartKind) =
  withControl(id, Chart, g): g.chartKind = t

proc grTitle*(id: ControlId, s: string) =
  withControl(id, Chart, g): g.title = s

proc grLegend*(id: ControlId, v: bool) =
  withControl(id, Chart, g): g.legend = v

proc grDeleteAll*(id: ControlId) =
  withControl(id, Chart, g):
    g.series.setLen(0)
    g.seriesNames.setLen(0)
    g.categories.setLen(0)

proc grDraw*(id: ControlId) = refresh(id)

# Looper

proc looperAdd*(id: ControlId, vals: varargs[string]): int =
  result = -1
  let v = @vals
  withControl(id, Looper, z):
    z.rows.add v
    result = z.rows.len

proc looperDelete*(id: ControlId, index: int) =
  withControl(id, Looper, z):
    if index - 1 in 0 ..< z.rows.len:
      z.rows.delete(index - 1)
      z.selection = min(z.selection, z.rows.high)

proc looperDeleteAll*(id: ControlId) =
  withControl(id, Looper, z):
    z.rows.setLen(0)
    z.selection = -1
    z.scroll = 0

proc looperSelect*(id: ControlId): int =
  readControl(id, Looper, z): result = z.selection + 1
  if result == 0: result = -1

proc looperSelectPlus*(id: ControlId, index: int) =
  withControl(id, Looper, z): z.selection = clamp(index - 1, -1, z.rows.high)

proc looperCount*(id: ControlId): int =
  readControl(id, Looper, z): result = z.rows.len

proc looperValue*(id: ControlId, line, attribute: int): string =
  readControl(id, Looper, z):
    if line - 1 in 0 ..< z.rows.len and attribute - 1 in 0 ..< z.rows[line - 1].len:
      result = z.rows[line - 1][attribute - 1]

# Kanban

proc kanbanAddList*(id: ControlId, title: string): int =
  result = -1
  withControl(id, Kanban, k):
    k.lists.add KanbanList(title: title)
    result = k.lists.len

proc kanbanAdd*(id: ControlId, list: int, card: string): int =
  # Adds a card ("title\ndescription") to the list (1-based).
  result = -1
  withControl(id, Kanban, k):
    if list - 1 in 0 ..< k.lists.len:
      k.lists[list - 1].cards.add card
      result = k.lists[list - 1].cards.len

proc kanbanDelete*(id: ControlId, list, card: int) =
  withControl(id, Kanban, k):
    if list - 1 in 0 ..< k.lists.len and card - 1 in 0 ..< k.lists[list - 1].cards.len:
      k.lists[list - 1].cards.delete(card - 1)

proc kanbanMove*(id: ControlId, list, card, destList: int, position = -1) =
  withControl(id, Kanban, k):
    k.moveCard(list - 1, card - 1, destList - 1, if position < 0: -1 else: position - 1)

proc kanbanCard*(id: ControlId, list, card: int): string =
  readControl(id, Kanban, k):
    if list - 1 in 0 ..< k.lists.len and card - 1 in 0 ..< k.lists[list - 1].cards.len:
      result = k.lists[list - 1].cards[card - 1]

proc kanbanCount*(id: ControlId, list: int): int =
  readControl(id, Kanban, k):
    if list - 1 in 0 ..< k.lists.len: result = k.lists[list - 1].cards.len

proc kanbanSelect*(id: ControlId): tuple[list, card: int] =
  readControl(id, Kanban, k): result = (k.selList + 1, k.selCard + 1)

# Menu

proc menuAdd*(id: ControlId, path: string) =
  # path: "File" & TreeSep & "Open"; option "-" = separator.
  withControl(id, MenuBar, m): m.addMenuPath(path)

# TreeMap / Gantt / Calendar

proc treeMapAdd*(id: ControlId, caption: string, v: float) =
  withControl(id, TreeMap, tm): tm.elements.add TreeMapItem(caption: caption, value: v)

proc treeMapDeleteAll*(id: ControlId) =
  withControl(id, TreeMap, tm):
    tm.elements.setLen(0)
    tm.selection = -1

proc ganttAddTask*(id: ControlId, caption: string, start, duration: float, progress = 0.0): int =
  result = -1
  withControl(id, Gantt, g):
    g.tasks.add GanttTask(caption: caption, start: start, duration: duration, progress: progress)
    result = g.tasks.len

proc ganttSetProgress*(id: ControlId, task: int, progress: float) =
  withControl(id, Gantt, g):
    if task - 1 in 0 ..< g.tasks.len: g.tasks[task - 1].progress = clamp(progress, 0.0, 1.0)

proc ganttDeleteAll*(id: ControlId) =
  withControl(id, Gantt, g):
    g.tasks.setLen(0)
    g.selection = -1

proc calendarShow*(id: ControlId, year, month: int) =
  withControl(id, Calendar, c):
    c.year = year
    c.month = clamp(month, 1, 12)

# Edit

proc `placeholder=`*(id: ControlId, v: string) =
  withControl(id, Edit, s): s.placeholder = v

proc editSelection*(id: ControlId): tuple[start, stop: int] =
  # Selection (UTF-8 byte positions, 0-based).
  readControl(id, Edit, s): result = (min(s.cursor, s.anchor), max(s.cursor, s.anchor))
