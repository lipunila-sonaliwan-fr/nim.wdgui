# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
#
# compeditor.nim - Library component editor
#
# Secondary window: component identity, typed input / output ports,
# parameters, NCP (CP-SAT) code template. "Test" compiles the template
# with stub inputs; "Save" adds it to the user library
# (library/user.wdrk) and refreshes the palette.

import std/[strutils, tables, os]
import ../../src/wdgui
import model, codegen, compat, uistate
import cpsat/solver, cpsat/lang

type
  EditorIds = object
    win, ident, label, category, color, glyph, doc: ControlId
    ports, params, code: ControlId
    btnColor, btnAddPort, btnDelPort, btnAddParam, btnDelParam: ControlId
    btnTest, btnSave, btnCancel: ControlId

var
  ed: EditorIds
  gEditing: string                  # identifier of the edited component ("" = new)
  onLibraryChanged*: proc () {.nimcall, gcsafe.}

const helpText = """Template tags:
  {{id}}  node identifier (prefix of all your names)
  {{titre}}  node title
  {{p:name}}  value of parameter "name"
  {{in:port}}  output linked to input "port"  ({{in:port?default}} if optional)
  {{list:port:_s}}  list of the outputs linked to a multiple input, with a suffix
  {{count:port}}  number of links of the input
  {{expr:param}}  expression in which input names are replaced
  {{if:port}} … {{fi}}   /   {{ifnot:port}} … {{fi}}   conditional block
An output "s" is named {{id}}_s. Conventions: task (_s,_d,_e), usage (_s,_d,_q),
flow (_t,_dq), time (_a,_b arrays), int / bool (the name itself)."""

const defaultCode = """// Example: a task must start after a given instant
constraint {{in:task}}_s >= {{p:instant}};
"""

#
# Reading the form
#

proc isIdent(s: string): bool =
  result = s.len > 0 and s[0] in IdentStartChars and s.allCharsInSet(IdentChars)

proc readForm(): (ComponentDef, seq[string]) =
  var errs: seq[string] = @[]
  let c = ComponentDef(user: true)
  c.id = ed.ident.value.strip()
  c.label = ed.label.value.strip()
  c.category = ed.category.value.strip()
  c.color = ed.color.value.strip()
  c.glyph = ed.glyph.value.strip()
  c.doc = ed.doc.value.strip().replace("\n", " ")
  c.code = ed.code.value
  if not isIdent(c.id):
    errs.add "invalid identifier (letters, digits, _; must start with a letter)"
  if c.label.len == 0: c.label = c.id
  if c.category.len == 0: c.category = "My components"
  if not c.color.startsWith("#") or c.color.len notin [7, 9]:
    errs.add "color expected in the form #RRGGBB"
  if c.glyph.len == 0: c.glyph = (if c.id.len > 0: c.id[0 .. 0].toUpperAscii else: "?")
  var names: seq[string] = @[]
  for i in 1 .. gridCount(ed.ports):
    let sens = gridCell(ed.ports, i, "sens")
    let p = PortDef(name: gridCell(ed.ports, i, "nom").strip(),
                    typ: gridCell(ed.ports, i, "type").strip(),
                    label: gridCell(ed.ports, i, "libelle").strip(),
                    multi: gridCell(ed.ports, i, "multiple") == "1")
    if p.name.len == 0: continue
    if not isIdent(p.name): errs.add "port \"" & p.name & "\": invalid name"
    if p.typ notin portTypes: errs.add "port \"" & p.name & "\": unknown type " & p.typ
    if p.name in names: errs.add "port \"" & p.name & "\" defined twice"
    names.add p.name
    var q = p
    if q.label.len == 0: q.label = q.name
    if sens == "output":
      q.multi = false
      c.outputs.add q
    else:
      c.inputs.add q
  var pnames: seq[string] = @[]
  for i in 1 .. gridCount(ed.params):
    let p = ParamDef(name: gridCell(ed.params, i, "nom").strip(),
                     kind: gridCell(ed.params, i, "type").strip(),
                     default: gridCell(ed.params, i, "defaut"),
                     label: gridCell(ed.params, i, "libelle").strip())
    if p.name.len == 0: continue
    if not isIdent(p.name): errs.add "parameter \"" & p.name & "\": invalid name"
    if p.kind notin ["int", "expr", "text", "code"]:
      errs.add "parameter \"" & p.name & "\": type int, expr, text or code"
    if p.name in pnames: errs.add "parameter \"" & p.name & "\" defined twice"
    pnames.add p.name
    var q = p
    if q.label.len == 0: q.label = q.name
    c.params.add q
  if c.code.strip().len == 0:
    errs.add "the code template is empty"
  result = (c, errs)

#
# Testing the template with stub inputs
#

proc stubDecl(prefix, typ: string): string =
  case typ
  of "task":
    "var " & prefix & "_s : 0..HORIZON;\nlet " & prefix & "_d = 2;\nlet " & prefix &
      "_e = " & prefix & "_s + " & prefix & "_d;\n"
  of "usage":
    "var " & prefix & "_s : 0..HORIZON;\nlet " & prefix & "_d = 2;\nlet " & prefix & "_q = 1;\n"
  of "flow":
    "var " & prefix & "_t : 0..HORIZON;\nlet " & prefix & "_dq = 1;\n"
  of "time":
    "const " & prefix & "_a = [0];\nconst " & prefix & "_b = [HORIZON];\n"
  of "bool":
    "var " & prefix & " : bool;\n"
  else:
    "var " & prefix & " : 0..10;\n"

proc testTemplate(c: ComponentDef): (bool, string) =
  let lib = newLibrary()
  lib.comps[c.id] = c
  let d = newDocument()
  d.horizon = 24
  let stub = Node(id: "stub", comp: "stub", params: initOrderedTable[string, string]())
  d.nodes.add stub
  let n = d.addNode(lib, c.id, 0, 100)
  var decls = "const HORIZON = 24;\n"
  for p in c.inputs:
    let count = (if p.multi: 2 else: 1)
    for k in 1 .. count:
      let port = (if p.multi: p.name & $k else: p.name)
      decls.add stubDecl("stub_" & port, p.typ)
      d.links.add Link(src: "stub", srcPort: port, dst: n.id, dstPort: p.name)
  var code = ""
  try:
    code = nodeCode(d, lib, n)
  except CodegenError as e:
    return (false, "Template: " & e.msg)
  let text = decls & code & "\n"
  try:
    let comp = compileModel(text)
    var info = "Valid template: the generated code compiles.\n\n" &
               $comp.s.numIntVars & " integer variable(s), " & $comp.s.numProps &
               " propagator(s), " & $comp.s.numClauses & " clause(s).\n\nGenerated code (stub inputs):\n\n" & code
    result = (true, info)
  except CpError as e:
    let ln = errorLine(e.msg)
    var ctx = ""
    let lines = text.splitLines()
    if ln >= 1 and ln <= lines.len: ctx = "\n\n→ " & lines[ln - 1].strip()
    result = (false, "NCP error: " & e.msg & ctx & "\n\nGenerated code:\n\n" & code)

#
# Window event handler
#

proc handleEditor(ev: var Event) =
  if ev.current != ev.id: return
  if ev.kind != evClick: return
  if ev.id == ed.btnAddPort:
    discard gridAddLine(ed.ports, "input", "port" & $(gridCount(ed.ports) + 1), "task", "", "0")
  elif ev.id == ed.btnDelPort:
    let r = gridSelect(ed.ports)
    if r > 0: ignore(gridDeleteLine(ed.ports, r))
  elif ev.id == ed.btnAddParam:
    discard gridAddLine(ed.params, "param" & $(gridCount(ed.params) + 1), "expr", "0", "")
  elif ev.id == ed.btnDelParam:
    let r = gridSelect(ed.params)
    if r > 0: ignore(gridDeleteLine(ed.params, r))
  elif ev.id == ed.btnColor:
    var colr = hex(if ed.color.value.startsWith("#"): ed.color.value else: "#7C5CFF")
    if colorDialog(colr) == drOk:
      ed.color.value = hexOf(colr)[0 .. 6]
  elif ev.id == ed.btnTest:
    let (c, errs) = readForm()
    if errs.len > 0:
      alert(iconExclamation, "The form contains errors:\n• " & errs.join("\n• "))
      return
    let (ok, msg) = testTemplate(c)
    alert((if ok: iconInformation else: iconStop), msg, title = "Testing component \"" & c.label & "\"")
  elif ev.id == ed.btnSave:
    let (c, errs) = readForm()
    if errs.len > 0:
      alert(iconExclamation, "The form contains errors:\n• " & errs.join("\n• "))
      return
    var conflict = ""
    var libDir = ""
    withApp:
      libDir = gApp.libDir
      if gApp.lib.comps.hasKey(c.id) and c.id != gEditing:
        conflict = (if gApp.lib.comps[c.id].user: "a user component" else: "a base component")
    if conflict.len > 0:
      alert(iconStop, "The identifier \"" & c.id & "\" is already used by " & conflict & ".")
      return
    let (ok, msg) = testTemplate(c)
    if not ok:
      if confirm(iconExclamation, "The template test fails:\n\n" & msg &
                 "\n\nSave anyway?") != drOk:
        return
    var saveErr = ""
    withApp:
      if gEditing.len > 0 and gEditing != c.id and gApp.lib.comps.hasKey(gEditing):
        gApp.lib.comps.del(gEditing)
      gApp.lib.comps[c.id] = c
      if c.category notin gApp.lib.categoryOrder:
        gApp.lib.categoryOrder.add c.category
      try:
        saveUserLibrary(gApp.lib, libDir / "user.wdrk")
      except IOError, OSError:
        saveErr = getCurrentExceptionMsg()
    if saveErr.len > 0:
      alert(iconStop, "Cannot write the user library:\n" & saveErr)
    else:
      logMsg("Component \"" & c.label & "\" saved to the user library")
    if onLibraryChanged != nil: onLibraryChanged()
    closeWindow(ed.win)
  elif ev.id == ed.btnCancel:
    closeWindow(ed.win)

proc editorHandler(ev: var Event) {.nimcall, gcsafe.} =
  {.cast(gcsafe).}:
    handleEditor(ev)

#
# Building the window
#

proc labeled(parent: Container, caption: string, ctl: Control): Control =
  discard parent.addChild(newLabel(caption))
  result = parent.addChild(ctl)

proc openComponentEditor*(sourceId = "", duplicate = false, theme: Theme) =
  # empty sourceId: new component; otherwise edit (user component)
  # or duplicate (base component).
  var src: ComponentDef = nil
  withApp:
    if sourceId.len > 0 and gApp.lib.comps.hasKey(sourceId):
      src = gApp.lib.comps[sourceId]
  gEditing = (if src != nil and not duplicate: src.id else: "")
  let title = (if src == nil: "New component"
               elif duplicate: "New component (copy of \"" & src.label & "\")"
               else: "Edit \"" & src.label & "\"")
  let win = newWindow(title & " - wdreka", 1080, 760, editorHandler,
                      layout = lkBorder, theme = theme)
  ed.win = win.id
  # --- identity ---
  let topCell = win.addChild(newCell(lkVertical, "Component identity"))
  topCell.dock = dkTop
  let top = topCell.addChild(newContainer(lkGrid, columns = 4))
  ed.ident = labeled(top, "Identifier", newEdit(placeholder = "my_component")).id
  ed.label = labeled(top, "Label", newEdit(placeholder = "My component")).id
  ed.category = labeled(top, "Category", newEdit(placeholder = "My components")).id
  ed.glyph = labeled(top, "Glyph", newEdit(placeholder = "M")).id
  let colRow = newSupercontrol(lkHorizontal)
  discard labeled(top, "Color", colRow)
  let ce = colRow.addChild(newEdit("#7C5CFF"))
  ce.weight = 1
  ed.color = ce.id
  ed.btnColor = colRow.addChild(newButton("Choose…")).id
  ed.doc = labeled(top, "Documentation", newEdit(placeholder = "Purpose of the component")).id
  # --- center: ports + parameters | code ---
  let center = win.addChild(newContainer(lkHorizontal))
  center.dock = dkCenter
  let left = center.addChild(newContainer(lkVertical))
  left.weight = 1
  let cPorts = left.addChild(newCell(lkVertical, "Inputs / outputs"))
  cPorts.weight = 1
  let gp = cPorts.addChild(newGrid())
  gp.weight = 1
  ed.ports = gp.id
  discard gridAddColumn(ed.ports, "sens", "Direction", gcCombo, 90, choices = ["input", "output"])
  discard gridAddColumn(ed.ports, "nom", "Name", gcText, 110)
  var typeChoices: seq[string] = @[]
  for t in portTypes: typeChoices.add t
  discard gridAddColumn(ed.ports, "type", "Type", gcCombo, 90, choices = typeChoices)
  discard gridAddColumn(ed.ports, "libelle", "Label", gcText, 130)
  discard gridAddColumn(ed.ports, "multiple", "Multiple", gcCheck, 70)
  ignore(gridSetEditable(ed.ports, true))
  let rowP = cPorts.addChild(newSupercontrol(lkHorizontal))
  ed.btnAddPort = rowP.addChild(newButton("+ Port")).id
  ed.btnDelPort = rowP.addChild(newButton("− Port")).id
  let cParams = left.addChild(newCell(lkVertical, "Parameters"))
  cParams.weight = 1
  let gpa = cParams.addChild(newGrid())
  gpa.weight = 1
  ed.params = gpa.id
  discard gridAddColumn(ed.params, "nom", "Name", gcText, 110)
  discard gridAddColumn(ed.params, "type", "Type", gcCombo, 80, choices = ["int", "expr", "text", "code"])
  discard gridAddColumn(ed.params, "defaut", "Default", gcText, 110)
  discard gridAddColumn(ed.params, "libelle", "Label", gcText, 150)
  ignore(gridSetEditable(ed.params, true))
  let rowQ = cParams.addChild(newSupercontrol(lkHorizontal))
  ed.btnAddParam = rowQ.addChild(newButton("+ Parameter")).id
  ed.btnDelParam = rowQ.addChild(newButton("− Parameter")).id
  let right = center.addChild(newCell(lkVertical, "CP-SAT code (NCP template)"))
  right.weight = 1
  let code = right.addChild(newMultiEdit(defaultCode))
  code.weight = 3
  ed.code = code.id
  let help = right.addChild(newMultiEdit(helpText))
  help.weight = 2
  setReadOnly(help.id)
  # --- buttons ---
  let bottom = win.addChild(newSupercontrol(lkHorizontal))
  bottom.dock = dkBottom
  ed.btnTest = bottom.addChild(newButton("Test the template")).id
  let spacer = bottom.addChild(newLabel(""))
  spacer.weight = 1
  ed.btnCancel = bottom.addChild(newButton("Cancel", isCancel = true)).id
  ed.btnSave = bottom.addChild(newButton("Save to the library", isDefault = true)).id
  # --- pre-filling ---
  if src == nil:
    ed.category.value = "My components"
    discard gridAddLine(ed.ports, "input", "task", "task", "Task", "0")
    discard gridAddLine(ed.params, "instant", "expr", "0", "Minimum instant")
  else:
    ed.ident.value = (if duplicate: src.id & "_custom" else: src.id)
    ed.label.value = (if duplicate: src.label & " (custom)" else: src.label)
    ed.category.value = src.category
    ed.glyph.value = src.glyph
    ed.color.value = src.color
    ed.doc.value = src.doc
    ed.code.value = src.code
    for p in src.inputs:
      discard gridAddLine(ed.ports, "input", p.name, p.typ, p.label, (if p.multi: "1" else: "0"))
    for p in src.outputs:
      discard gridAddLine(ed.ports, "output", p.name, p.typ, p.label, "0")
    for p in src.params:
      discard gridAddLine(ed.params, p.name, p.kind, p.default, p.label)
