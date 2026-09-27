# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
# Grid control demo: typed columns, entry, footers, conditional formatting, breaks,
# sorting, search, column show/move/resize, CSV / JSON export and import.
#
# nim c -r --threads:on --mm:atomicArc -d:sdlttf examples/grid_demo.nim
import std/strutils
import ../src/wdgui

var
  gGrid, gStatus, gSearch: ControlId
  gBtnAdd, gBtnDelete, gBtnSort, gBtnFind, gBtnCsv, gBtnJson, gBtnImport: ControlId
  gEditSwitch, gBreakSwitch, gDateSwitch: ControlId

proc say(s: string) {.gcsafe.} = gStatus.caption = s

proc handler(ev: var Event) {.nimcall, gcsafe.} =
  if ev.current != ev.id: return            # handle each event once, at target level
  if ev.id == gGrid:
    case ev.kind
    of evSelection:
      say("Row " & $ev.index & " selected: " & gridCell(gGrid, ev.index, "customer"))
    of evChange:
      if ev.index == 0 or ev.column == 0: say("Rows changed: " & ev.text)
      else: say("Cell (" & $ev.index & ", " & gridColumn(gGrid, ev.column).caption & ") = " & ev.text)
    of evValidate:
      say("Row " & $ev.index & " validated")
    of evClick:
      # button column: the click carries the row and the column
      if ev.index > 0 and ev.column == gridColumnIndex(gGrid, "action"):
        say("Details of " & gridCell(gGrid, ev.index, "customer") & " - amount " &
            gridCell(gGrid, ev.index, "amount"))
    else: discard
    return
  case ev.kind
  of evClick:
    if ev.id == gBtnAdd:
      let r = gridAddLine(gGrid, $(gridCount(gGrid) + 1), "New customer", "Paris", "20260926",
                          "0", "0", "examples/logo.bmp", "")
      gridSelectPlus(gGrid, r)
      gridSetEditable(gGrid, true)
      gEditSwitch.value = "1"
      gridStartEdit(gGrid, r, "customer")
    elif ev.id == gBtnDelete:
      let r = gridSelect(gGrid)
      if r > 0: gridDeleteLine(gGrid, r)
    elif ev.id == gBtnSort:
      gridSort(gGrid, "amount", ascending = false)
    elif ev.id == gBtnFind:
      let f = gridFind(gGrid, gSearch.value)
      if f.row > 0: say("Found at row " & $f.row & ", column " & $f.column)
      else: say("Not found: " & gSearch.value)
    elif ev.id == gBtnCsv:
      discard gridSaveCsv(gGrid, "grid_export.csv")
      say("Saved grid_export.csv (" & $gridCount(gGrid) & " rows)")
    elif ev.id == gBtnJson:
      discard gridSaveJson(gGrid, "grid_export.json")
      say("Saved grid_export.json")
    elif ev.id == gBtnImport:
      let n = gridLoadJson(gGrid, "grid_export.json")
      say(if n < 0: "Export to JSON first" else: "Imported " & $n & " rows from grid_export.json")
  of evChange:
    if ev.id == gEditSwitch: gridSetEditable(gGrid, gEditSwitch.value == "1")
    elif ev.id == gBreakSwitch: gridSetBreak(gGrid, (if gBreakSwitch.value == "1": "city" else: ""))
    elif ev.id == gDateSwitch: gridShowColumn(gGrid, "date", gDateSwitch.value == "1")
  else: discard

proc main() =
  let win = newWindow("wdgui - Grid control", 1100, 640, handler, layout = lkBorder)
  win.root.margin = 0
  win.root.spacing = 0

  # toolbar (top).
  let tb = win.addChild(newToolbar())
  tb.dock = dkTop
  gBtnAdd = tb.addTool("Add", "Add a line and edit it").id
  gBtnDelete = tb.addTool("Delete", "Delete the selected line").id
  gBtnSort = tb.addTool("Sort by amount", "Descending amount").id
  let search = tb.addChild(newEdit(placeholder = "Search…"))
  search.fixedWidth = 160
  gSearch = search.id
  gBtnFind = tb.addTool("Find").id
  gBtnCsv = tb.addTool("Export CSV").id
  gBtnJson = tb.addTool("Export JSON").id
  gBtnImport = tb.addTool("Import JSON").id

  # options + status (bottom).
  let bottom = win.addChild(newContainer(lkHorizontal, 8))
  bottom.dock = dkBottom
  gEditSwitch = bottom.addChild(newCheckBox("Entry mode", switchStyle = true)).id
  gBreakSwitch = bottom.addChild(newCheckBox("Group by city", switchStyle = true)).id
  gDateSwitch = bottom.addChild(newCheckBox("Show date", checked = true, switchStyle = true)).id
  let st = bottom.addChild(newLabel("Double-click a cell (entry mode) · Insert / Delete keys add / remove lines"))
  st.weight = 1
  gStatus = st.id

  # the grid (center).
  let grid = win.addChild(newGrid(multiSelection = true, fillMode = fmManual))
  grid.dock = dkCenter
  grid.name = "GRD_Orders"
  gGrid = grid.id

  discard gridAddColumn(gGrid, "id", "#", gcNumber, 50, decimals = 0)
  discard gridAddColumn(gGrid, "customer", "Customer", gcText, 180)
  discard gridAddColumn(gGrid, "city", "City", gcCombo, 130,
                        choices = ["Paris", "Lyon", "Nantes", "Lille", "Bordeaux"])
  discard gridAddColumn(gGrid, "date", "Order date", gcDate, 120)
  discard gridAddColumn(gGrid, "amount", "Amount", gcNumber, 120, decimals = 2)
  discard gridAddColumn(gGrid, "paid", "Paid", gcCheck, 60)
  discard gridAddColumn(gGrid, "logo", "Logo", gcImage, 70)
  let action = gridAddColumn(gGrid, "action", "Action", gcButton, 100)
  gridSetButtonCaption(gGrid, "action", "Details")
  action.tooltip = "Column sub-control: it has its own id"

  # the "#" column is never editable, even in entry mode.
  gridSetColumnEdit(gGrid, "id", emReadOnly)

  # footers.
  gridSetFooter(gGrid, "amount", fkSum)
  gridSetFooter(gGrid, "customer", fkCount)

  # conditional formatting.
  gridAddFormat(gGrid, "amount", coGreater, "1000", background = hex"#DFF6DD")
  gridAddFormat(gGrid, "paid", coEquals, "0", text = hex"#C42B1C", wholeRow = true)

  let data = [
    ("Alice Smith", "Paris", "20260903", "1250.00", "1"),
    ("Bob Jones", "Lyon", "20260905", "320.50", "0"),
    ("Carol Brown", "Nantes", "20260911", "780.00", "1"),
    ("David Taylor", "Paris", "20260912", "2100.00", "1"),
    ("Emma Wilson", "Lille", "20260914", "95.90", "0"),
    ("Frank Moore", "Lyon", "20260918", "1540.00", "1"),
    ("Grace Clark", "Nantes", "20260920", "410.00", "1"),
    ("Henry Hall", "Bordeaux", "20260922", "660.00", "0")]
  for i in 0 ..< data.len:
    let (cust, city, date, amount, paid) = data[i]
    discard gridAddLine(gGrid, $(i + 1), cust, city, date, amount, paid, "examples/logo.bmp", "")

  # one cell forced editable even in consultation mode, one line forced read-only.
  gridSetCellEdit(gGrid, 1, "paid", emEditable)
  gridSetLineEdit(gGrid, 4, emReadOnly)

  runApplication()

main()
