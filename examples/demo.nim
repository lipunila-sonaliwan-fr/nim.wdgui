# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
# wdgui demo: every control, live theme switching, non-blocking long process,
# event propagation to parents, context menu.
#
#   nim c -r --threads:on --mm:atomicArc -d:sdlttf examples/demo.nim
import std/[os, strutils]
import ../src/wdgui

var
  gWin, gStatus, gProgress, gBtnLong, gBtnQuit, gTheme, gDark, gCell: ControlId
  gList, gTable, gTree, gChart, gGantt, gNameEdit: ControlId

proc applyTheme() {.gcsafe.} =
  let dark = gDark.value == "1"
  let t = case listSelect(gTheme)
          of 1: themeWindows11(dark)
          of 2: themeMacOS(dark)
          of 3: themeLinux(dark)
          else: themeNative(dark)
  gWin.theme = t

proc handler(ev: var Event) {.nimcall, gcsafe.} =
  # Window handler: called on a dedicated thread, for the target and then for each of its parents up to the window (ev.current).
  if ev.current == ev.id and ev.kind notin {evMouseEnter, evMouseLeave, evButtonDown,
      evButtonUp, evKeyUp, evWheel, evFocusGained, evFocusLost} and
      ev.id != gStatus:
    var info = "[" & $ev.kind & "] " & controlType(ev.id)
    let n = name(ev.id)
    if n.len > 0: info &= " " & n
    if ev.index != 0: info &= "  index=" & $ev.index
    if ev.text.len > 0: info &= "  \"" & ev.text.replace("\t", " > ").replace("\n", " ") & "\""
    gStatus.caption = info

  case ev.kind
  of evClick:
    if ev.id == gBtnLong:
      # Long process: the UI stays responsive (we are on a dedicated thread).
      gBtnLong.state = csGrayed
      for i in 0 .. 100:
        gProgress.valueNum = float(i)
        sleep(30)
      gBtnLong.state = csActive
      ev.stopPropagation()
    elif ev.id == gBtnQuit:
      quitApplication()
    elif ev.current == gCell:
      # Propagation: a click on a button inside the cell bubbles up to here.
      echo "Click propagated up to the cell from ", name(ev.id)
  of evSelection:
    if ev.id == gTheme and ev.current == ev.id: applyTheme()
    elif ev.id == gList and ev.current == ev.id and ev.text == "Delete":
      let s = listSelect(gList)
      if s > 0: listDelete(gList, s)
    elif ev.current == gWin and controlType(ev.id) == "Menu":
      if ev.text.endsWith("Quit"): quitApplication()
  of evChange:
    if ev.id == gDark and ev.current == ev.id: applyTheme()
  of evRightClick:
    if ev.id == gList and ev.current == ev.id:
      openContextMenu(gList, ["Delete", "Duplicate", "-", "Properties"])
  of evDoubleClick:
    if ev.id == gTable and ev.current == ev.id:
      let l = tableSelect(gTable)
      if l > 0: gStatus.caption = "Double-click on " & tableCell(gTable, l, 1)
  of evWindowClose:
    echo "Window closing"
  else: discard

proc labeled(p: Container, caption: string, c: Control): Control =
  discard p.addChild(newLabel(caption))
  p.addChild(c)

proc main() =
  let f = newWindow("wdgui - controls demo", 1180, 800, handler, layout = lkBorder)
  gWin = f.id
  let r = f.root
  r.margin = 0
  r.spacing = 0

  # menu + toolbar (top dock).
  let menu = r.addChild(newMenuBar())
  for ch in ["File" & TreeSep & "New", "File" & TreeSep & "Open...",
             "File" & TreeSep & "-", "File" & TreeSep & "Quit",
             "Edit" & TreeSep & "Copy", "Edit" & TreeSep & "Paste",
             "Help" & TreeSep & "About"]:
    menuAdd(menu.id, ch)
  let bar = r.addChild(newToolbar())
  bar.dock = dkTop
  discard bar.addTool("New", "Create a document")
  discard bar.addTool("Open", "Open a document")
  discard bar.addTool("Save", "Save")

  # status bar (bottom dock).
  let statusBar = r.addChild(newContainer(lkHorizontal, 8))
  statusBar.dock = dkBottom
  let status = statusBar.addChild(newLabel("Ready."))
  status.weight = 1
  gStatus = status.id
  discard statusBar.addChild(newLabel("Theme:"))
  gTheme = statusBar.addChild(newComboBox(["Native", "Windows 11", "macOS", "Linux (Adwaita)"], 0)).id
  gDark = statusBar.addChild(newCheckBox("Dark", switchStyle = true)).id
  let q = statusBar.addChild(newButton("Quit", isCancel = true))
  gBtnQuit = q.id

  # tabs (center).
  let tabs = r.addChild(newTab())
  tabs.dock = dkCenter

  # Pane 1: input

  let p1 = tabs.addPage("Input", lkHorizontal)
  let g = p1.addChild(newContainer(lkGrid, 0, -1, 2))
  g.weight = 1
  let nameEdit = newEdit(placeholder = "Your name")
  nameEdit.name = "EDT_Name"
  nameEdit.tooltip = "Type your name"
  gNameEdit = g.labeled("Name", nameEdit).id
  discard g.labeled("Password", newEdit(inputKind = ikPassword))
  discard g.labeled("Age", newSpin(30, 0, 120))
  discard g.labeled("Country", newComboBox(["France", "Belgium", "Switzerland", "Canada", "Luxembourg"], 0))
  discard g.labeled("Options", newCheckBox(["Newsletter", "Partner offers", "Expert mode"]))
  discard g.labeled("Delivery", newRadioButton(["Standard", "Express", "In-store pickup"]))
  discard g.labeled("Volume", newSlider(40))
  discard g.labeled("Price range", newRangeSlider(20, 70))
  discard g.labeled("Satisfaction", newRating(3))
  discard g.labeled("Comment", newEdit(multiline = true, placeholder = "Comment..."))
  let cell = p1.addChild(newCell(lkVertical, "Processing"))
  cell.fixedWidth = 300
  cell.name = "CEL_Processing"
  gCell = cell.id
  let bl = cell.addChild(newButton("Long process (3 s)", isDefault = true))
  bl.name = "BTN_Long"
  gBtnLong = bl.id
  gProgress = cell.addChild(newProgressBar()).id
  let bp = cell.addChild(newButton("Propagated button"))
  bp.name = "BTN_Propagate"
  discard cell.addChild(newLabel("A clickable link", isLink = true))

  # Pane 2: lists

  let p2 = tabs.addPage("Lists", lkHorizontal)
  let li = p2.addChild(newListBox(["Apple", "Pear", "Cherry", "Apricot", "Banana", "Kiwi",
                                    "Mango", "Strawberry", "Raspberry", "Blueberry"], multiSelection = true))
  li.weight = 1
  li.tooltip = "Right-click: context menu"
  gList = li.id
  let tb = p2.addChild(newTable())
  tb.weight = 2
  gTable = tb.id
  tableAddColumn(gTable, "Name", 140)
  tableAddColumn(gTable, "City", 120)
  tableAddColumn(gTable, "Revenue (k€)", 90, alRight)
  for (n, v, ca) in [("Smith", "Boston", "120"), ("Jones", "Chicago", "85"), ("Brown", "New York", "310"),
                     ("Taylor", "Denver", "42"), ("Wilson", "Seattle", "150"), ("Clark", "Austin", "77")]:
    discard tableAddLine(gTable, n, v, ca)
  let ar = p2.addChild(newTreeView())
  ar.weight = 1
  gTree = ar.id
  for ch in ["Europe\tFrance\tBrittany", "Europe\tFrance\tNormandy", "Europe\tBelgium",
             "America\tCanada\tQuebec", "America\tMexico"]:
    treeAdd(gTree, ch)
  treeExpand(gTree, "Europe\tFrance")

  # Pane 3: charts
  let p3 = tabs.addPage("Charts", lkGrid, 2)
  let gr = p3.addChild(newChart(ckColumn, "Quarterly sales"))
  gr.fixedHeight = 280
  gChart = gr.id
  for i, m in ["T1", "T2", "T3", "T4"]:
    grCategoryLabel(gChart, i + 1, m)
    grAddData(gChart, 1, i + 1, [12.0, 18, 9, 22][i])
    grAddData(gChart, 2, i + 1, [8.0, 11, 14, 17][i])
  grSeriesLabel(gChart, 1, "2025")
  grSeriesLabel(gChart, 2, "2026")
  let gs = p3.addChild(newChart(ckPie, "Breakdown"))
  gs.fixedHeight = 280
  let parts = [("Web", 45.0), ("Store", 30.0), ("Phone", 25.0)]
  for i in 0 ..< parts.len:
    grCategoryLabel(gs.id, i + 1, parts[i][0])
    grAddData(gs.id, 1, i + 1, parts[i][1])
  discard p3.addChild(newCalendar())
  let tm = p3.addChild(newTreeMap())
  for (n, v) in [("Boston", 320.0), ("Denver", 155.0), ("Lyon", 145.0), ("Marseille", 72.0),
                 ("Toulouse", 54.0), ("Nice", 56.0), ("Lille", 49.0)]:
    treeMapAdd(tm.id, n, v)

  # Pane 4: planning
  let p4 = tabs.addPage("Planning", lkVertical)
  let kb = p4.addChild(newKanban())
  kb.weight = 1
  for l in ["To do", "In progress", "Done"]: discard kanbanAddList(kb.id, l)
  discard kanbanAdd(kb.id, 1, "Mock-ups\nMain screens")
  discard kanbanAdd(kb.id, 1, "Tests\nAcceptance scenarios")
  discard kanbanAdd(kb.id, 2, "Rendering engine\nSDL3")
  discard kanbanAdd(kb.id, 3, "Specifications")
  let gt = p4.addChild(newGantt())
  gt.weight = 1
  gGantt = gt.id
  discard ganttAddTask(gGantt, "Analysis", 0, 5, 1.0)
  discard ganttAddTask(gGantt, "Design", 4, 6, 0.6)
  discard ganttAddTask(gGantt, "Development", 9, 14, 0.2)
  discard ganttAddTask(gGantt, "Acceptance", 22, 5)

  # Pane 5: miscellaneous
  let p5 = tabs.addPage("Misc", lkVertical)
  let sep = p5.addChild(newSplitter(vertical = true, position = 0.4))
  sep.weight = 1
  let zr = sep.addChild(newLooper())
  for (a, b) in [("Alice Smith", "Project manager"), ("Bob Jones", "Developer"),
                 ("Carol Brown", "Designer"), ("David Taylor", "Tester")]:
    discard looperAdd(zr.id, a, b)
  let rightPane = sep.addChild(newContainer(lkVertical))
  let shapes = rightPane.addChild(newSupercontrol(lkHorizontal))
  discard shapes.addChild(newShape(skRoundRect))
  let el = shapes.addChild(newShape(skEllipse))
  el.style.background = some(hex"#FFB900")
  discard shapes.addChild(newShape(skRectangle))
  discard rightPane.addChild(newShape(skHLine))
  discard rightPane.addChild(newBarCode("WDGUI-2026"))
  discard rightPane.addChild(newScrollbar(vertical = false))
  let img = rightPane.addChild(newImage("examples/wdgui.bmp"))
  img.weight = 1

  runApplication()

main()
