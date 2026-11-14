# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
#
# wdreka.nim - Visual CP-SAT constraint editor (wdgui application)
#
# Availabilities (schedules), resources (material, places, consumables),
# agents (equipment, staff) producing or consuming resources: the model is
# built graphically (Node-RED style), compiled to NCP (the language of the
# cpsat solver) and solved, with progress monitoring.
#
# Build (from the wdgui root folder):
#   nim c -r --threads:on --mm:atomicArc -d:sdlttf \
#         -o:apps/wdreka/wdreka apps/wdreka/wdreka.nim
# or: nimble wdreka   (see README.md for the nimble task)

import std/[os, strutils, tables, times, atomics, options]
import ../../src/wdgui
import model, codegen, gfx, canvas, views, uistate, runner, compat, compeditor

var
  gMenu: ControlId
  gPropRows: seq[string]         # grid line -> parameter name.
  gPropNode: string              # node shown in the properties panel.
  gAppDir: string

const
  menuItems = [
    "File\tNew", "File\tOpen…", "File\tOpen the \"Workshop\" example",
    "File\t-", "File\tSave", "File\tSave as…",
    "File\tExport NCP model…", "File\t-", "File\tQuit",
    "Edit\tDuplicate", "Edit\tDelete", "Edit\tSelect all",
    "Edit\t-", "Edit\tReset node code",
    "Model\tCompile visual → text", "Model\tImport text → visual",
    "Model\t-", "Model\tSolve", "Model\tStop solving",
    "Library\tNew component…", "Library\tEdit / duplicate component…",
    "Library\tReload library",
    "View\tFit view", "View\tZoom in", "View\tZoom out",
    "View\t-", "View\tLight / dark theme",
    "Help\tAbout wdreka"]

proc appTheme(dark: bool): Theme =
  result = themeMacOS(dark = dark)
  result.name = "wdreka"
  result.accent = hex"#7C5CFF"
  result.accentHover = hex"#8F74FF"
  result.radius = 8

var
  btnNew, btnOpen, btnSave, btnCompile, btnImport, btnFit, btnZoomIn, btnZoomOut: ControlId
  btnNewComp, btnEditComp, btnDup, btnDel, btnResetCode: ControlId
  btnCompile2, btnImport2: ControlId

proc updateZoomLabel() =
  var z = 1.0
  withApp:
    z = gApp.zoom
  {.cast(gcsafe).}:
    ui.zoomLbl.caption = $int(z * 100 + 0.5) & " %"

proc parseIntOr0(s: string, d: int): int =
  try:
    result = parseInt(s.strip())
  except ValueError:
    result = d

#
# Component palette
#

proc fillPalette(filter = "") =
  var items: seq[string] = @[]
  var cats: seq[string] = @[]
  let f = filter.toLowerAscii.strip()
  withApp:
    for cat in gApp.lib.categoryOrder:
      var any = false
      for c in gApp.lib.comps.values:
        if c.category != cat: continue
        if f.len > 0 and f notin c.label.toLowerAscii and f notin c.id and
           f notin c.doc.toLowerAscii: continue
        items.add cat & TreeSep & c.label & (if c.user: "  ★" else: "")
        any = true
      if any: cats.add cat
  {.cast(gcsafe).}:
    ignore(treeDeleteAll(ui.tree))
    for it in items: ignore(treeAdd(ui.tree, it))
    for c in cats: ignore(treeExpand(ui.tree, c))

proc compByPath(path: string): string =
  # "Category\tLabel" -> component identifier.
  let parts = path.split(TreeSep)
  if parts.len < 2: return ""
  let label = parts[1].replace("  ★", "").strip()
  withApp:
    for c in gApp.lib.comps.values:
      if c.category == parts[0] and c.label == label:
        result = c.id
        break

proc showCompDoc(id: string) =
  var txt = ""
  withApp:
    if gApp.lib.comps.hasKey(id):
      let c = gApp.lib.comps[id]
      txt = c.label & (if c.user: "  (user component)" else: "") & "\n" & c.doc
      if c.inputs.len > 0:
        var ins: seq[string] = @[]
        for p in c.inputs:
          ins.add p.label & " : " & portTypeLabel(p.typ) & (if p.multi: " (multiple)" else: "")
        txt.add "\nInputs: " & ins.join(", ")
      if c.outputs.len > 0:
        var outs: seq[string] = @[]
        for p in c.outputs: outs.add p.label & " : " & portTypeLabel(p.typ)
        txt.add "\nOutputs: " & outs.join(", ")
  {.cast(gcsafe).}:
    ui.compDoc.value = txt

proc reloadLibrary() =
  var dir = ""
  withApp:
    dir = gApp.libDir
  let (lib, errs) = loadLibrary(dir)
  withApp:
    gApp.lib = lib
  for e in errs: logMsg("Library: " & e)
  logMsg("Library loaded: " & $lib.comps.len & " components")
  var filter = ""
  {.cast(gcsafe).}:
    filter = ui.search.value
  fillPalette(filter)
  refreshCanvas()

proc libraryChanged() {.nimcall, gcsafe.} =
  {.cast(gcsafe).}:
    var filter = ui.search.value
    fillPalette(filter)
    refreshCanvas()

#
# Properties panel
#

proc fillProps() =
  var title, docTxt, code: string
  var rows: seq[(string, string, string, string)] = @[]
  withApp:
    gPropNode = ""
    if gApp.selected.len == 1:
      let n = gApp.doc.findNode(gApp.selected[0])
      if n != nil:
        gPropNode = n.id
        let cd = (if gApp.lib.comps.hasKey(n.comp): gApp.lib.comps[n.comp] else: nil)
        title = n.nodeLabel(gApp.lib) & "   ·   " & (if cd != nil: cd.label else: n.comp) &
                "   ·   " & n.id
        docTxt = (if cd != nil: cd.doc else: "Component unknown to the library.")
        if n.customCode.len > 0:
          docTxt.add "\n⚠ Custom code: the component template is replaced by the code below."
        rows.add(("__titre", "Title", n.title, "text"))
        if cd != nil:
          for p in cd.params:
            if p.kind == "code": continue
            rows.add((p.name, p.label, n.params.getOrDefault(p.name, p.default), p.kind))
          if n.comp == "ncp":
            code = n.params.getOrDefault("code", "")
          else:
            try:
              code = nodeCode(gApp.doc, gApp.lib, n)
            except CodegenError as e:
              code = "// Code unavailable: " & e.msg
        else:
          code = n.customCode
    elif gApp.selected.len > 1:
      title = $gApp.selected.len & " nodes selected"
      docTxt = "Drag to move them together; Del to delete them."
    else:
      title = "Document: " & gApp.doc.title
      docTxt = "Document settings. The horizon (HORIZON constant) bounds every date; " &
               "the time unit is free (h, min, day…)."
      rows.add(("__doc_titre", "Title", gApp.doc.title, "text"))
      rows.add(("__horizon", "Horizon", $gApp.doc.horizon, "integer"))
      rows.add(("__unite", "Time unit", gApp.doc.unit, "text"))
      rows.add(("__timeout", "Time limit (s)", $gApp.doc.timeout, "integer"))
      rows.add(("__solutions", "Max solutions (0 = all)", $gApp.doc.maxSolutions, "integer"))
    gPropRows = @[]
    for r in rows: gPropRows.add r[0]
  {.cast(gcsafe).}:
    ui.propTitle.caption = title
    ui.propDoc.value = docTxt
    ignore(gridDeleteAll(ui.props))
    for r in rows:
      discard gridAddLine(ui.props, r[0], r[1], r[2], r[3])
    ui.nodeCode.value = code

proc refreshNodeCode() =
  # refreshes the node code preview without rebuilding the grid.
  var code = ""
  withApp:
    let n = gApp.doc.findNode(gPropNode)
    if n != nil and n.comp != "ncp":
      try:
        code = nodeCode(gApp.doc, gApp.lib, n)
      except CodegenError as e:
        code = "// Code unavailable: " & e.msg
  if code.len > 0:
    {.cast(gcsafe).}:
      ui.nodeCode.value = code

proc autoCompileOn(): bool =
  {.cast(gcsafe).}:
    result = ui.autoCompile.value == "1"

proc graphChanged() =
  withApp:
    gApp.doc.graphDirty = true
    gApp.doc.modified = true
  if autoCompileOn():
    discard compileVisual(quiet = true)
  refreshCanvas()

proc applyProp(row: int, value: string) =
  if row < 1: return
  var name = ""
  var docChanged = false
  withApp:
    if row > gPropRows.len: return
    name = gPropRows[row - 1]
    let d = gApp.doc
    case name
    of "__doc_titre": d.title = value
    of "__horizon": d.horizon = max(1, parseIntOr0(value, d.horizon))
    of "__unite": d.unit = value
    of "__timeout": d.timeout = max(0, parseIntOr0(value, d.timeout))
    of "__solutions": d.maxSolutions = max(0, parseIntOr0(value, d.maxSolutions))
    of "__titre":
      let n = d.findNode(gPropNode)
      if n != nil: n.title = value
    else:
      let n = d.findNode(gPropNode)
      if n != nil: n.params[name] = value
    docChanged = true
  if docChanged:
    graphChanged()
    refreshNodeCode()

proc applyNodeCode(code: string) =
  var changed = false
  withApp:
    let n = gApp.doc.findNode(gPropNode)
    if n != nil:
      if n.comp == "ncp":
        n.params["code"] = code
      else:
        n.customCode = code
      changed = true
  if changed: graphChanged()

#
# Actions
#

proc selectAll() =
  withApp:
    gApp.selected = @[]
    for n in gApp.doc.nodes: gApp.selected.add n.id
  fillProps()
  refreshCanvas()

proc deleteSelection() =
  var count = 0
  withApp:
    if gApp.selectedLink >= 0 and gApp.selectedLink < gApp.doc.links.len:
      gApp.doc.links.delete(gApp.selectedLink)
      gApp.selectedLink = -1
      inc count
    for id in gApp.selected:
      gApp.doc.removeNode(id)
      inc count
    gApp.selected = @[]
  if count > 0:
    graphChanged()
    fillProps()

proc duplicateSelection() =
  withApp:
    gApp.selected = gApp.doc.duplicateNodes(gApp.lib, gApp.selected)
  graphChanged()
  fillProps()

proc resetNodeCode() =
  withApp:
    for id in gApp.selected:
      let n = gApp.doc.findNode(id)
      if n != nil: n.customCode = ""
  graphChanged()
  fillProps()

proc addComponentAtCenter(comp: string) =
  withApp:
    var (x, y) = (200.0, 150.0)
    if gCanvas != nil: (x, y) = gCanvas.viewCenterWorld()
    let n = gApp.doc.addNode(gApp.lib, comp, x - nodeW / 2, y - 40)
    gApp.selected = @[n.id]
    gApp.armed = ""
  graphChanged()
  fillProps()

proc zoomBy(factor: float) =
  withApp:
    if gCanvas != nil:
      let (rx, ry, rw, rh) = ctlRect(gCanvas)
      gCanvas.zoomAt(rx + rw / 2, ry + rh / 2, factor)
  refreshCanvas()
  updateZoomLabel()

proc fitAll() =
  withApp:
    if gCanvas != nil: gCanvas.fitView()
  refreshCanvas()

proc updateTitle() =
  var t = ""
  withApp:
    t = gApp.doc.title & (if gApp.doc.path.len > 0: "  -  " & extractFilename(gApp.doc.path) else: "")
  {.cast(gcsafe).}:
    ui.win.caption = "wdreka  ·  " & t

proc confirmDiscard(): bool =
  var modified = false
  withApp:
    modified = gApp.doc.modified
  if not modified: return true
  result = confirm(iconQuestion, "The current model is not saved.\nContinue without saving?") == drOk

proc resetResults() =
  withApp:
    gApp.res = Results(status: ssIdle)
  refreshResults()

proc newDoc() =
  if not confirmDiscard(): return
  withApp:
    gApp.doc = newDocument()
    gApp.selected = @[]
    gApp.selectedLink = -1
    gApp.zoom = 1.0
    gApp.panX = 40
    gApp.panY = 60
  {.cast(gcsafe).}:
    ui.ncp.value = ""
  resetResults()
  fillProps()
  updateTitle()
  refreshCanvas()
  logMsg("New model")

proc loadFile(path: string) =
  var text = ""
  try:
    text = readFile(path)
  except IOError, OSError:
    alert(iconStop, "Cannot read:\n" & path)
    return
  {.cast(gcsafe).}:
    ui.ncp.value = text
  importTextToVisual()
  withApp:
    gApp.doc.path = path
    gApp.doc.modified = false
    gApp.doc.graphDirty = false
    gApp.doc.textDirty = false
  resetResults()
  fillProps()
  updateTitle()
  logMsg("Opened: " & path)

proc openDoc() =
  if not confirmDiscard(): return
  let path = openFileDialog(title = "Open a model",
                            filter = "wdreka models|*.wdreka;*.ncp\nAll files|*")
  if path.len > 0: loadFile(path)

proc saveDoc(saveAs: bool) =
  var textDirty, graphDirty: bool
  withApp:
    textDirty = gApp.doc.textDirty
    graphDirty = gApp.doc.graphDirty
  if textDirty and not graphDirty:
    if confirm(iconQuestion, "The NCP text was edited by hand.\n" &
               "Import it into the visual before saving?\n" &
               "(otherwise these changes will be lost)") == drOk:
      importTextToVisual()
  var path, title, content: string
  withApp:
    path = gApp.doc.path
    title = gApp.doc.title
    try:
      content = compileGraph(gApp.doc, gApp.lib)[0]
    except CodegenError as e:
      # incomplete graph: save the description only.
      content = annotationLines(gApp.doc).join("\n") &
                "\n\n// Incomplete model (does not compile): " & e.msg & "\n"
  if path.len == 0 or saveAs:
    path = saveFileDialog(defaultName = title, filter = "wdreka models|*.wdreka\nAll files|*")
    if path.len == 0: return
    if path.splitFile.ext.len == 0: path.add ".wdreka"
  try:
    writeFile(path, content)
  except IOError, OSError:
    alert(iconStop, "Cannot write:\n" & path)
    return
  withApp:
    gApp.doc.path = path
    gApp.doc.modified = false
  updateTitle()
  refreshCanvas()
  logMsg("Saved: " & path)
  setStatus("Saved: " & path)

proc exportNcp() =
  var title = ""
  withApp:
    title = gApp.doc.title
  var needCompile = false
  withApp:
    needCompile = gApp.doc.graphDirty and not gApp.doc.textDirty
  if needCompile and not compileVisual(): return
  let path = saveFileDialog(defaultName = title & ".ncp", filter = "NCP model|*.ncp\nAll files|*")
  if path.len == 0: return
  var text = ""
  {.cast(gcsafe).}:
    text = ui.ncp.value
  try:
    writeFile(path, text)
    logMsg("NCP model exported: " & path & "  (run it with: cpsat " & extractFilename(path) & ")")
  except IOError, OSError:
    alert(iconStop, "Cannot write:\n" & path)

proc toggleTheme() =
  var dark = false
  {.cast(gcsafe).}:
    gDark = not gDark
    dark = gDark
    ui.win.theme = appTheme(dark)
  refreshCanvas()
  refreshResults()

proc currentTheme(): Theme =
  {.cast(gcsafe).}:
    result = appTheme(gDark)

proc editSelectedComponent() =
  var path = ""
  {.cast(gcsafe).}:
    path = ui.tree.value
  var id = compByPath(path)
  if id.len == 0:
    withApp:
      if gApp.selected.len == 1:
        let n = gApp.doc.findNode(gApp.selected[0])
        if n != nil: id = n.comp
  if id.len == 0:
    alert(iconInformation, "First select a component in the library (or a node).")
    return
  var isUser = false
  withApp:
    isUser = gApp.lib.comps.hasKey(id) and gApp.lib.comps[id].user
  if isUser:
    openComponentEditor(id, duplicate = false, theme = currentTheme())
  else:
    if confirm(iconQuestion, "\"" & id & "\" is a base component (read-only).\n" &
               "Create a new user component from it?") == drOk:
      openComponentEditor(id, duplicate = true, theme = currentTheme())

proc about() =
  alert(
    iconInformation,
    "wdreka 1.0.2 - visual CP-SAT constraint editor\nSoftware written by Jean-Marc Quéré\n◎ https://sonaliwan.fr\nLPCS, Lab'Oratoire, ✉ metalab (à) sonaliwan.fr\n\n" &
    "Project: " & gApp.doc.title,
    title = "About wdreka")

proc menuAction(item: string) =
  case item
  of "New": newDoc()
  of "Open…": openDoc()
  of "Open the \"Workshop\" example":
    if confirmDiscard(): loadFile(gAppDir / "examples" / "workshop.wdreka")
  of "Save": saveDoc(false)
  of "Save as…": saveDoc(true)
  of "Export NCP model…": exportNcp()
  of "Quit":
    if confirmDiscard(): quitApplication()
  of "Duplicate": duplicateSelection()
  of "Delete": deleteSelection()
  of "Select all": selectAll()
  of "Reset node code": resetNodeCode()
  of "Compile visual → text":
    if compileVisual(): showTab(tabModel)
  of "Import text → visual":
    importTextToVisual()
    fillProps()
  of "Solve": runSolve()
  of "Stop solving": requestStop()
  of "New component…": openComponentEditor("", theme = currentTheme())
  of "Edit / duplicate component…": editSelectedComponent()
  of "Reload library": reloadLibrary()
  of "Fit view", "Fit": fitAll()
  of "Zoom in": zoomBy(1.2)
  of "Zoom out": zoomBy(1 / 1.2)
  of "Light / dark theme": toggleTheme()
  of "About wdreka": about()
  else: discard

#
# Event handler
#

proc keyIs(ev: Event, name: static string): bool =
  # Del / Backspace / Esc (SDL codes: 127, 8, 27).
  let k = int(ev.key)
  when name == "delete":
    result = k == 127 or k == 8
  elif name == "escape":
    result = k == 27
  else:
    result = false

proc ctrlDown(ev: Event): bool =
  # Ctrl (or Cmd on macOS).
  result = (int(ev.modifiers) and (0x00C0 or 0x0C00)) != 0

proc handle(ev: var Event) =
  if ev.current != ev.id: return
  let id = ev.id
  case ev.kind
  of evSelection:
    if id == gMenu:
      let parts = ev.text.split(TreeSep)
      menuAction(parts[^1])
    elif id == ui.canvas:
      # choice in the canvas context menu.
      case ev.text
      of "Delete": deleteSelection()
      of "Duplicate": duplicateSelection()
      of "Reset node code": resetNodeCode()
      of "Select all": selectAll()
      of "Fit view": fitAll()
      of "Compile visual → text":
        if compileVisual(): showTab(tabModel)
      of "Solve": runSolve()
      else: discard
    elif id == ui.tree:
      let comp = compByPath(ev.text)
      if comp.len > 0:
        withApp:
          gApp.armed = comp
        showCompDoc(comp)
        refreshCanvas()
  of evDoubleClick:
    if id == ui.tree:
      var path = ""
      {.cast(gcsafe).}:
        path = ui.tree.value
      let comp = compByPath(path)
      if comp.len > 0: addComponentAtCenter(comp)
    elif id == ui.canvas:
      setFocus(ui.props)
  of evRightClick:
    if id == ui.canvas:
      var hasSel = false
      withApp:
        hasSel = gApp.selected.len > 0 or gApp.selectedLink >= 0
      if hasSel:
        ignore(openContextMenu(ui.canvas, ["Duplicate", "Delete", "-", "Reset node code",
                                    "-", "Compile visual → text", "Solve"]))
      else:
        ignore(openContextMenu(ui.canvas, ["Select all", "Fit view", "-",
                                    "Compile visual → text", "Solve"]))
  of evChange:
    if id == ui.canvas:
      if ev.text == "graph":
        graphChanged()
      fillProps()
      updateZoomLabel()
    elif id == ui.search:
      var f = ""
      {.cast(gcsafe).}:
        f = ui.search.value
      fillPalette(f)
    elif id == ui.props:
      if ev.column > 0:
        applyProp(ev.index, ev.text)
    elif id == ui.nodeCode:
      var code = ""
      {.cast(gcsafe).}:
        code = ui.nodeCode.value
      applyNodeCode(code)
    elif id == ui.ncp:
      withApp:
        gApp.doc.textDirty = true
        gApp.doc.modified = true
      setStatus("NCP text modified - use \"Text → visual\" to import it, or solve directly")
    elif id == ui.autoCompile:
      if autoCompileOn(): discard compileVisual(quiet = true)
  of evClick:
    if id == btnNew: newDoc()
    elif id == btnOpen: openDoc()
    elif id == btnSave: saveDoc(false)
    elif id == btnCompile or id == btnCompile2:
      if compileVisual(): showTab(tabModel)
    elif id == btnImport or id == btnImport2:
      importTextToVisual()
      fillProps()
    elif id == ui.btnSolve: runSolve()
    elif id == ui.btnStop: requestStop()
    elif id == btnFit: fitAll()
    elif id == btnZoomIn: zoomBy(1.2)
    elif id == btnZoomOut: zoomBy(1 / 1.2)
    elif id == btnNewComp: openComponentEditor("", theme = currentTheme())
    elif id == btnEditComp: editSelectedComponent()
    elif id == btnDup: duplicateSelection()
    elif id == btnDel: deleteSelection()
    elif id == btnResetCode: resetNodeCode()
  of evKeyDown:
    # shortcuts active when the canvas has the focus
    if id == ui.canvas:
      if keyIs(ev, "delete"): deleteSelection()
      elif keyIs(ev, "escape"):
        withApp:
          gApp.armed = ""
          gApp.selected = @[]
          gApp.selectedLink = -1
        fillProps()
        refreshCanvas()
    if ctrlDown(ev):
      # SDL letter codes = lowercase ASCII code.
      let k = int(ev.key)
      if k == ord('s'): saveDoc(false)
      elif k == ord('d') and id == ui.canvas: duplicateSelection()
      elif k == ord('r'): runSolve()
  of evWindowOpen:
    fitAll()
  else:
    discard

proc handler(ev: var Event) {.nimcall, gcsafe.} =
  {.cast(gcsafe).}:
    try:
      handle(ev)
    except CatchableError as e:
      logMsg("Internal error: " & e.msg)

#
# Building the interface
#

proc toolButton(parent: Container, caption, tip: string): ControlId =
  result = parent.addChild(newFlatButton(caption, tip)).id

proc separator(parent: Container) =
  let s = parent.addChild(newLabel("  "))
  s.fixedWidth = 10

proc buildUi() =
  let win = newWindow("wdreka  ·  CP-SAT constraints", 1500, 920, handler,
                      layout = lkBorder, theme = appTheme(true))
  ui.win = win.id

  # menu.
  let mb = win.addChild(newMenuBar())
  mb.dock = dkTop
  gMenu = mb.id
  for it in menuItems: ignore(menuAdd(gMenu, it))

  # toolbar.
  let tb = win.addChild(newSupercontrol(lkHorizontal))
  tb.dock = dkTop
  btnNew = toolButton(tb, "New", "New model")
  btnOpen = toolButton(tb, "Open", "Open a .wdreka / .ncp model")
  btnSave = toolButton(tb, "Save", "Save the model")
  separator(tb)
  btnCompile = toolButton(tb, "Visual → NCP", "Compile the graph into NCP text")
  btnImport = toolButton(tb, "NCP → Visual", "Rebuild the graph from the text")
  separator(tb)
  let bs = tb.addChild(newButton("▶  Solve", isDefault = true))
  bs.style.background = some(hex"#7C5CFF")
  bs.style.text = some(hex"#FFFFFF")
  ui.btnSolve = bs.id
  let bt = tb.addChild(newButton("■  Stop"))
  bt.style.background = some(hex"#C0392B")
  bt.style.text = some(hex"#FFFFFF")
  ui.btnStop = bt.id
  ui.btnStop.state = csGrayed
  separator(tb)
  btnZoomOut = toolButton(tb, "−", "Zoom out")
  btnZoomIn = toolButton(tb, "+", "Zoom in")
  btnFit = toolButton(tb, "Fit", "Frame the whole graph")
  let spacer = tb.addChild(newLabel(""))
  spacer.weight = 1
  let brand = tb.addChild(newLabel("wdreka  "))
  brand.style.text = some(hex"#8B6CFF")

  # status bar.
  let sb = win.addChild(newSupercontrol(lkHorizontal))
  sb.dock = dkBottom
  let st = sb.addChild(newLabel("Ready"))
  st.weight = 1
  ui.status = st.id
  let pb = sb.addChild(newProgressBar())
  pb.fixedWidth = 220
  ui.progress = pb.id
  let zl = sb.addChild(newLabel("100 %"))
  zl.fixedWidth = 70
  ui.zoomLbl = zl.id

  # body: library | (canvas / tabs) | properties.
  let sp1 = win.addChild(newSplit(true, 0.17))
  sp1.dock = dkCenter

  let lib = sp1.addChild(newCell(lkVertical, "Library"))
  let se = lib.addChild(newEdit(placeholder = "Search a component…"))
  ui.search = se.id
  let tr = lib.addChild(newTreeView())
  tr.weight = 1
  ui.tree = tr.id
  let cdoc = lib.addChild(newMultiEdit(
    "Click a component, then click on the canvas to place it - or double-click it."))
  cdoc.fixedHeight = 130
  ui.compDoc = cdoc.id
  setReadOnly(ui.compDoc)
  let lrow = lib.addChild(newSupercontrol(lkHorizontal))
  btnNewComp = lrow.addChild(newButton("+ Component")).id
  btnEditComp = lrow.addChild(newButton("Edit…")).id

  let sp2 = sp1.addChild(newSplit(true, 0.76))
  let sp3 = sp2.addChild(newSplit(false, 0.60))

  gCanvas = newGraphCanvas()
  ui.canvas = sp3.addChild(gCanvas).id

  let tabs = newTab()
  ui.tabs = sp3.addChild(tabs).id
  # tab 1: NCP model.
  let pModel = tabs.addPage("NCP model", lkBorder)
  let mbar = pModel.addChild(newSupercontrol(lkHorizontal))
  mbar.dock = dkTop
  btnCompile2 = mbar.addChild(newButton("⬇  Compile the visual")).id
  btnImport2 = mbar.addChild(newButton("⬆  Text → visual")).id
  let ac = mbar.addChild(newCheckBox(["Automatic compilation"]))
  ui.autoCompile = ac.id
  let hint = mbar.addChild(newLabel("  The text is also the save format; it runs as is with cpsat."))
  hint.weight = 1
  let ncp = pModel.addChild(newMultiEdit(""))
  ncp.dock = dkCenter
  ui.ncp = ncp.id
  # tab 2: solving.
  let pSolve = tabs.addPage("Solving", lkBorder)
  let dash = newSolveDashboard()
  dash.fixedHeight = 196
  dash.dock = dkTop
  ui.dash = pSolve.addChild(dash).id
  let panel = pSolve.addChild(newPanel(lkVertical, scrollbars = smAutomatic))
  panel.dock = dkCenter
  let sched = newScheduleView()
  ui.sched = panel.addChild(sched).id
  # tab 3: variables.
  let pVars = tabs.addPage("Variables", lkVertical)
  let gv = pVars.addChild(newGrid())
  gv.weight = 1
  ui.vars = gv.id
  discard gridAddColumn(ui.vars, "noeud", "Node", gcText, 220)
  discard gridAddColumn(ui.vars, "nom", "NCP name", gcText, 220)
  discard gridAddColumn(ui.vars, "valeur", "Value", gcText, 260)
  # tab 4: log
  let pLog = tabs.addPage("Log", lkVertical)
  let lb = pLog.addChild(newListBox())
  lb.weight = 1
  ui.log = lb.id

  # properties.
  let props = sp2.addChild(newCell(lkVertical, "Properties"))
  let pt = props.addChild(newLabel("Document"))
  ui.propTitle = pt.id
  let pd = props.addChild(newMultiEdit(""))
  pd.fixedHeight = 86
  ui.propDoc = pd.id
  setReadOnly(ui.propDoc)
  let gpr = props.addChild(newGrid())
  gpr.weight = 1
  ui.props = gpr.id
  discard gridAddColumn(ui.props, "nom", "name", gcText, 60)
  discard gridAddColumn(ui.props, "libelle", "Parameter", gcText, 150)
  discard gridAddColumn(ui.props, "valeur", "Value", gcText, 150)
  discard gridAddColumn(ui.props, "type", "Type", gcText, 60)
  ignore(gridShowColumn(ui.props, "nom", false))
  ignore(gridSetEditable(ui.props, true))
  ignore(gridSetColumnEdit(ui.props, "libelle", emReadOnly))
  ignore(gridSetColumnEdit(ui.props, "type", emReadOnly))
  discard props.addChild(newLabel("Node NCP code (editable)"))
  let nc = props.addChild(newMultiEdit(""))
  nc.weight = 1
  ui.nodeCode = nc.id
  let prow = props.addChild(newSupercontrol(lkHorizontal))
  btnDup = prow.addChild(newButton("Duplicate")).id
  btnDel = prow.addChild(newButton("Delete")).id
  btnResetCode = prow.addChild(newButton("Original code")).id

#
# Startup
#

proc main() =
  gAppDir = currentSourcePath().parentDir()
  if not dirExists(gAppDir / "library"):
    gAppDir = getAppDir()
  withApp:
    gApp.doc = newDocument()
    gApp.lib = newLibrary()
    gApp.zoom = 1.0
    gApp.panX = 40
    gApp.panY = 60
    gApp.selectedLink = -1
    gApp.libDir = gAppDir / "library"
  onLibraryChanged = libraryChanged
  buildUi()
  reloadLibrary()
  let example = gAppDir / "examples" / "workshop.wdreka"
  if fileExists(example):
    loadFile(example)
    discard compileVisual(quiet = true)
  fillProps()
  updateTitle()
  logMsg("wdreka ready - " & $gAppDir)
  runApplication()

when isMainModule:
  main()
