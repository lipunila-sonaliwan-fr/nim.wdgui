# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
# Form model of the wdnim designer: nodes, properties, events, palette (built-in and
# custom entries), JSON persistence and generation of the `form_<name>.nim` module.
import std/[json, strutils, os]

type
  PropKind* = enum
    pkString, pkInt, pkFloat, pkBool, pkEnum, pkColor, pkList
  PropDef* = object
    name*: string
    kind*: PropKind
    default*: string
    choices*: seq[string]

  PaletteEntry* = object
    kind*: string                # name shown in the palette and stored in the model.
    category*: string
    base*: string                # built-in kind used for the preview (and the code of built-ins).
    container*: bool
    props*: seq[PropDef]         # specific properties (common ones are added automatically).
    ctor*: string                # custom entries: constructor expression, "$prop" = property value.
    module*: string              # custom entries: module to import in the generated code.
    events*: seq[string]
    letter*: string              # palette badge.

  DNode* = ref object
    uid*: int
    kind*: string
    name*: string
    props*: seq[tuple[key, value: string]]
    events*: seq[tuple[event, handler: string]]
    children*: seq[DNode]
    parent*: DNode

  FormModel* = ref object
    root*: DNode                 # kind "Window"; its name is the form name.

var
  palette*: seq[PaletteEntry]
  uidCounter = 0

const
  layoutChoices* = ["lkVertical", "lkHorizontal", "lkGrid", "lkFlow", "lkBorder", "lkStack", "lkAbsolute"]
  commonEvents = @["evClick", "evDoubleClick", "evRightClick", "evMouseEnter", "evMouseLeave",
                   "evFocusGained", "evFocusLost", "evKeyDown"]
  themeChoices* = ["themeNative()", "themeNative(dark = true)", "themeWindows11()", "themeWindows11(dark = true)",
                   "themeMacOS()", "themeMacOS(dark = true)", "themeLinux()", "themeLinux(dark = true)"]

proc prop(name: string, kind: PropKind, default = "", choices: openArray[string] = []): PropDef =
  PropDef(name: name, kind: kind, default: default, choices: @choices)

# built-in palette

proc entry(kind, category, letter: string, container: bool, props: seq[PropDef],
           events: seq[string] = @[]): PaletteEntry =
  PaletteEntry(kind: kind, category: category, base: kind, container: container, props: props,
               letter: letter, events: commonEvents & events)

proc containerProps(layout = "lkVertical"): seq[PropDef] =
  @[prop("layout", pkEnum, layout, layoutChoices), prop("margin", pkFloat, "-1"),
    prop("spacing", pkFloat, "-1"), prop("columns", pkInt, "2")]

proc initPalette() =
  let al = ["alLeft", "alCenter", "alRight"]
  palette = @[
    entry("Container", "Layouts", "▭", true, containerProps()),
    entry("Cell", "Layouts", "▢", true, @[prop("caption", pkString, "Group")] & containerProps()),
    entry("Panel", "Layouts", "⇕", true, containerProps() &
          @[prop("scrollbars", pkEnum, "smAlways", ["smAlways", "smAutomatic", "smHidden"])]),
    entry("Splitter", "Layouts", "‖", true, @[prop("vertical", pkBool, "true"), prop("position", pkFloat, "0.5")],
          @["evChange"]),
    entry("Tab", "Layouts", "⊓", true, @[], @["evChange"]),
    entry("TabPage", "Layouts", "⊔", true, @[prop("caption", pkString, "Page")] & containerProps()),
    entry("Toolbar", "Layouts", "≡", true, @[]),
    entry("Label", "Controls", "A", false, @[prop("caption", pkString, "Label"),
          prop("alignment", pkEnum, "alLeft", al), prop("isLink", pkBool, "false")]),
    entry("Button", "Controls", "B", false, @[prop("caption", pkString, "Button"),
          prop("isDefault", pkBool, "false"), prop("isCancel", pkBool, "false"), prop("flat", pkBool, "false")]),
    entry("Edit", "Controls", "E", false, @[prop("text", pkString, ""),
          prop("inputKind", pkEnum, "ikText", ["ikText", "ikInteger", "ikReal", "ikPassword"]),
          prop("multiline", pkBool, "false"), prop("placeholder", pkString, "")], @["evChange", "evTextInput"]),
    entry("Spin", "Controls", "S", false, @[prop("value", pkFloat, "0"), prop("minValue", pkFloat, "0"),
          prop("maxValue", pkFloat, "100"), prop("step", pkFloat, "1")], @["evChange"]),
    entry("CheckBox", "Controls", "✓", false, @[prop("caption", pkString, "Option"),
          prop("checked", pkBool, "false"), prop("switchStyle", pkBool, "false")], @["evChange"]),
    entry("RadioButton", "Controls", "◉", false, @[prop("options", pkList, "One;Two;Three"),
          prop("selection", pkInt, "0"), prop("horizontal", pkBool, "false")], @["evChange"]),
    entry("ComboBox", "Controls", "▾", false, @[prop("items", pkList, "First;Second;Third"),
          prop("selection", pkInt, "0")], @["evSelection"]),
    entry("ListBox", "Controls", "☰", false, @[prop("items", pkList, "Item 1;Item 2;Item 3"),
          prop("multiSelection", pkBool, "false")], @["evSelection"]),
    entry("Slider", "Controls", "—", false, @[prop("value", pkFloat, "50"), prop("minValue", pkFloat, "0"),
          prop("maxValue", pkFloat, "100"), prop("step", pkFloat, "1"), prop("vertical", pkBool, "false")],
          @["evChange"]),
    entry("RangeSlider", "Controls", "↔", false, @[prop("lower", pkFloat, "20"), prop("upper", pkFloat, "80"),
          prop("minValue", pkFloat, "0"), prop("maxValue", pkFloat, "100")], @["evChange"]),
    entry("ProgressBar", "Controls", "▰", false, @[prop("value", pkFloat, "40"), prop("minValue", pkFloat, "0"),
          prop("maxValue", pkFloat, "100"), prop("showText", pkBool, "true")]),
    entry("Rating", "Controls", "★", false, @[prop("value", pkFloat, "3"), prop("maxValue", pkInt, "5")],
          @["evChange"]),
    entry("Scrollbar", "Controls", "↕", false, @[prop("vertical", pkBool, "true"), prop("minValue", pkFloat, "0"),
          prop("maxValue", pkFloat, "100"), prop("pageSize", pkFloat, "10")], @["evChange"]),
    entry("Shape", "Controls", "◆", false, @[prop("shapeKind", pkEnum, "skRoundRect",
          ["skRectangle", "skRoundRect", "skEllipse", "skHLine", "skVLine", "skDiagonal"]),
          prop("thickness", pkFloat, "1")]),
    entry("Image", "Controls", "▣", false, @[prop("path", pkString, ""),
          prop("mode", pkEnum, "imFit", ["imCenter", "imStretch", "imFit"])]),
    entry("BarCode", "Controls", "║", false, @[prop("text", pkString, "WDGUI")]),
    entry("Calendar", "Data", "▦", false, @[prop("date", pkString, "")], @["evChange"]),
    entry("Chart", "Data", "▮", false, @[prop("chartKind", pkEnum, "ckColumn", ["ckColumn", "ckLine", "ckArea", "ckPie"]),
          prop("title", pkString, "Chart")]),
    entry("TreeView", "Data", "⌥", false, @[], @["evSelection", "evExpand", "evCollapse"]),
    entry("Table", "Data", "▤", false, @[prop("multiSelection", pkBool, "false"),
          prop("tableColumns", pkList, "Name;Value")], @["evSelection"]),
    entry("Grid", "Data", "▦", false, @[prop("multiSelection", pkBool, "false"), prop("editable", pkBool, "true"),
          prop("gridColumns", pkList, "name:Name;value:Value")], @["evSelection", "evChange", "evValidate"])]

proc windowEntry*(): PaletteEntry =
  PaletteEntry(kind: "Window", category: "", base: "Window", container: true, letter: "▢",
               events: @["evWindowOpen", "evWindowClose", "evWindowResize", "evKeyDown"],
               props: @[prop("title", pkString, "Form"), prop("width", pkInt, "640"), prop("height", pkInt, "480"),
                        prop("layout", pkEnum, "lkVertical", layoutChoices), prop("margin", pkFloat, "-1"),
                        prop("spacing", pkFloat, "-1"), prop("columns", pkInt, "2"),
                        prop("theme", pkEnum, "themeNative()", themeChoices),
                        prop("resizable", pkBool, "true"), prop("manualClose", pkBool, "false")])

proc commonProps*(): seq[PropDef] =
  @[prop("tooltip", pkString, ""), prop("visible", pkBool, "true"),
    prop("state", pkEnum, "csActive", ["csActive", "csGrayed", "csReadOnly"]),
    prop("fixedWidth", pkFloat, "0"), prop("fixedHeight", pkFloat, "0"),
    prop("fixedX", pkFloat, "0"), prop("fixedY", pkFloat, "0"),
    prop("weight", pkFloat, "0"), prop("stretch", pkEnum, "", ["", "true", "false"]),
    prop("dock", pkEnum, "", ["", "dkTop", "dkBottom", "dkLeft", "dkRight", "dkCenter"]),
    prop("textColor", pkColor, ""), prop("backgroundColor", pkColor, "")]

proc findEntry*(kind: string): PaletteEntry =
  if kind == "Window": return windowEntry()
  if palette.len == 0: initPalette()
  for e in palette:
    if e.kind == kind: return e
  result = PaletteEntry(kind: kind, base: "Label", letter: "?")

proc allProps*(kind: string): seq[PropDef] =
  # Properties shown by the inspector: specific (custom entries also get their base's), then the common ones.
  let e = findEntry(kind)
  if kind == "Window": return e.props
  if e.base != e.kind:
    for p in findEntry(e.base).props: result.add p
  for p in e.props:
    var dup = false
    for q in result:
      if q.name == p.name: dup = true
    if not dup: result.add p
  result.add commonProps()

proc eventsOf*(kind: string): seq[string] =
  let e = findEntry(kind)
  if e.base != e.kind and kind != "Window": findEntry(e.base).events else: e.events

proc isContainerKind*(kind: string): bool =
  let e = findEntry(kind)
  e.container or (e.base != e.kind and findEntry(e.base).container)

proc baseOf*(kind: string): string = findEntry(kind).base

# custom palette entries

proc customPalettePath*(root: string): string = root / "wdnim_palette.json"

proc loadCustomPalette*(root: string) =
  # Custom controls of the project (wdnim_palette.json):
  # [{"kind": "RoundButton", "base": "Button", "ctor": "newRoundButton($caption)",
  #   "module": "mycontrols", "category": "Custom", "letter": "R",
  #   "props": [{"name": "counter", "type": "int", "default": "0"}]}]
  initPalette()
  let f = customPalettePath(root)
  if not fileExists(f): return
  try:
    for it in parseJson(readFile(f)):
      var e = PaletteEntry(kind: it{"kind"}.getStr, base: it{"base"}.getStr("Label"),
                           ctor: it{"ctor"}.getStr, module: it{"module"}.getStr,
                           category: it{"category"}.getStr("Custom"), letter: it{"letter"}.getStr("★"))
      if e.kind.len == 0: continue
      e.container = findEntry(e.base).container
      let props = it{"props"}
      if props != nil and props.kind == JArray:
        for p in props:
          var k = pkString
          case p{"type"}.getStr("string")
          of "int": k = pkInt
          of "float": k = pkFloat
          of "bool": k = pkBool
          of "color": k = pkColor
          of "list": k = pkList
          else: discard
          e.props.add PropDef(name: p{"name"}.getStr, kind: k, default: p{"default"}.getStr)
      palette.add e
  except CatchableError: discard

proc addCustomEntry*(root, kind, base, ctor, module: string): bool =
  # Appends a custom control to wdnim_palette.json and reloads the palette.
  let f = customPalettePath(root)
  var arr = newJArray()
  try:
    if fileExists(f): arr = parseJson(readFile(f))
  except CatchableError: arr = newJArray()
  arr.add %*{"kind": kind, "base": base, "ctor": ctor, "module": module, "category": "Custom",
             "letter": (if kind.len > 0: $kind[0] else: "★"), "props": []}
  try:
    writeFile(f, arr.pretty)
    loadCustomPalette(root)
    result = true
  except CatchableError: result = false

# nodes

proc newNode*(kind, name: string): DNode =
  inc uidCounter
  DNode(uid: uidCounter, kind: kind, name: name)

proc getProp*(n: DNode, key: string): string =
  for p in n.props:
    if p.key == key: return p.value
  for d in allProps(n.kind):
    if d.name == key: return d.default
  ""

proc setProp*(n: DNode, key, value: string) =
  for p in n.props.mitems:
    if p.key == key:
      p.value = value
      return
  n.props.add((key, value))

proc handlerFor*(n: DNode, event: string): string =
  for e in n.events:
    if e.event == event: return e.handler

proc setHandler*(n: DNode, event, handler: string) =
  for i in countdown(n.events.high, 0):
    if n.events[i].event == event: n.events.delete(i)
  if handler.len > 0: n.events.add((event, handler))

proc walk*(n: DNode, acc: var seq[DNode]) =
  acc.add n
  for c in n.children: walk(c, acc)

proc allNodes*(m: FormModel): seq[DNode] = walk(m.root, result)

proc isAncestor*(a, b: DNode): bool =
  # True if `a` is `b` or one of its ancestors.
  var p = b
  while p != nil:
    if p == a: return true
    p = p.parent

proc namePrefix(kind: string): string =
  case kind
  of "Button": "btn"
  of "Label": "lbl"
  of "Edit": "edt"
  of "CheckBox": "chk"
  of "RadioButton": "rad"
  of "ComboBox": "cbo"
  of "ListBox": "lst"
  of "Spin": "spn"
  of "Slider": "sld"
  of "RangeSlider": "rng"
  of "ProgressBar": "prg"
  of "Rating": "rat"
  of "Scrollbar": "scr"
  of "Shape": "shp"
  of "Image": "img"
  of "BarCode": "bcd"
  of "Calendar": "cal"
  of "Chart": "cht"
  of "TreeView": "tree"
  of "Table": "tbl"
  of "Grid": "grd"
  of "Container": "box"
  of "Cell": "cell"
  of "Panel": "pnl"
  of "Splitter": "spl"
  of "Tab": "tab"
  of "TabPage": "page"
  of "Toolbar": "tbar"
  else: (if kind.len >= 3: kind[0 .. 2].toLowerAscii else: "ctl")

proc uniqueName*(m: FormModel, kind: string): string =
  let prefix = namePrefix(kind)
  var n = 1
  while true:
    let cand = prefix & $n
    var used = false
    for x in m.allNodes:
      if x.name == cand: used = true
    if not used: return cand
    inc n

proc isIdent*(s: string): bool =
  if s.len == 0 or not (s[0].isAlphaAscii): return false
  for c in s:
    if not (c.isAlphaNumeric or c == '_'): return false
  not s.endsWith("_") and "__" notin s

proc newModel*(formName: string): FormModel =
  result = FormModel(root: newNode("Window", formName))
  result.root.setProp("title", "Form " & formName)

# JSON

proc toJson(n: DNode): JsonNode =
  var props = newJObject()
  for p in n.props: props[p.key] = %p.value
  var evs = newJArray()
  for e in n.events: evs.add %*[e.event, e.handler]
  var ch = newJArray()
  for c in n.children: ch.add toJson(c)
  %*{"kind": n.kind, "name": n.name, "props": props, "events": evs, "children": ch}

proc fromJson(j: JsonNode, parent: DNode): DNode =
  result = newNode(j{"kind"}.getStr("Label"), j{"name"}.getStr)
  result.parent = parent
  if j{"props"} != nil:
    for k, v in j{"props"}.pairs: result.props.add((k, v.getStr))
  if j{"events"} != nil:
    for e in j{"events"}:
      if e.len >= 2: result.events.add((e[0].getStr, e[1].getStr))
  if j{"children"} != nil:
    for c in j{"children"}: result.children.add fromJson(c, result)

proc modelToJson*(m: FormModel): string = toJson(m.root).pretty

proc loadModel*(formFile: string): FormModel =
  # Reads the design kept at the end of a generated form (#[wdform … ]#); nil if none.
  try:
    let s = readFile(formFile)
    let a = s.find("#[wdform")
    let b = s.rfind("]#")
    if a < 0 or b < a: return nil
    let js = s[a + "#[wdform".len ..< b]
    result = FormModel(root: fromJson(parseJson(js), nil))
  except CatchableError:
    result = nil

# names and files

proc formFileName*(name: string): string = "form_" & name & ".nim"

proc nextFormName*(root: string): string =
  # First number N such that form_N.nim does not exist in the project folder.
  var n = 1
  while fileExists(root / formFileName($n)): inc n
  $n

proc typeName*(formName: string): string =
  var s = ""
  var up = true
  for c in formName:
    if c.isAlphaNumeric:
      s.add(if up: c.toUpperAscii else: c)
      up = false
    else: up = true
  "Form" & s

proc varName*(formName: string): string =
  let t = typeName(formName)
  "form" & t[4 .. ^1]

proc wdguiImport*(root: string): string =
  # Import path of wdgui from the project folder: a src/wdgui.nim found in the project
  # or one of its parents (relative path), else the installed package "wdgui".
  var d = absolutePath(root)
  while true:
    if fileExists(d / "src" / "wdgui.nim"):
      return relativePath(d / "src" / "wdgui", root).replace('\\', '/')
    let p = d.parentDir
    if p == d or p.len == 0: break
    d = p
  "wdgui"

# code generation

proc lit(s: string): string = s.escape

proc listLit(s: string): string =
  var parts: seq[string]
  for x in s.split(';'):
    if x.strip.len > 0: parts.add x.strip.escape
  if parts.len == 0: "newSeq[string]()" else: "@[" & parts.join(", ") & "]"

proc floatLit(s: string, default: string): string =
  try:
    let f = parseFloat(s.strip)
    result = formatFloat(f, ffDecimal, 3).strip(leading = false, chars = {'0'})
    if result.endsWith("."): result.add "0"
  except ValueError:
    result = if s == default: "0.0" else: floatLit(default, "0")

proc intLit(s: string): string =
  try:
    result = $parseInt(s.strip)
  except ValueError:
    result = "0"

proc boolLit(s: string): string = (if s.strip.toLowerAscii in ["true", "1", "yes"]: "true" else: "false")

proc valueLit(n: DNode, key: string): string =
  # Nim literal for a property, according to its definition.
  let v = n.getProp(key)
  for d in allProps(n.kind):
    if d.name == key:
      return case d.kind
             of pkString, pkColor: lit(v)
             of pkInt: intLit(v)
             of pkFloat: floatLit(v, d.default)
             of pkBool: boolLit(v)
             of pkEnum: (if v.len > 0: v else: d.default)
             of pkList: listLit(v)
  lit(v)

proc ctorExpr*(n: DNode): string =
  # Constructor expression of a node (custom entries: `ctor` with "$prop" substituted).
  let e = findEntry(n.kind)
  if e.ctor.len > 0:
    result = e.ctor
    for d in allProps(n.kind): result = result.replace("$" & d.name, valueLit(n, d.name))
    return
  template v(k: string): string = valueLit(n, k)
  case e.base
  of "Container": "newContainer(" & v("layout") & ", " & v("margin") & ", " & v("spacing") & ", " & v("columns") & ")"
  of "Cell": "newCell(" & v("layout") & ", " & v("caption") & ", " & v("columns") & ")"
  of "Panel": "newPanel(" & v("layout") & ", " & v("scrollbars") & ", " & v("margin") & ", " & v("spacing") &
              ", " & v("columns") & ")"
  of "Splitter": "newSplitter(" & v("vertical") & ", " & v("position") & ")"
  of "Tab": "newTab()"
  of "Toolbar": "newToolbar()"
  of "Label": "newLabel(" & v("caption") & ", " & v("alignment") & ", " & v("isLink") & ")"
  of "Button": "newButton(" & v("caption") & ", isDefault = " & v("isDefault") & ", isCancel = " & v("isCancel") & ")"
  of "Edit": "newEdit(" & v("text") & ", " & v("inputKind") & ", " & v("multiline") & ", " & v("placeholder") & ")"
  of "Spin": "newSpin(" & v("value") & ", " & v("minValue") & ", " & v("maxValue") & ", " & v("step") & ")"
  of "CheckBox": "newCheckBox(" & v("caption") & ", " & v("checked") & ", " & v("switchStyle") & ")"
  of "RadioButton": "newRadioButton(" & v("options") & ", " & v("selection") & ", " & v("horizontal") & ")"
  of "ComboBox": "newComboBox(" & v("items") & ", " & v("selection") & ")"
  of "ListBox": "newListBox(" & v("items") & ", " & v("multiSelection") & ")"
  of "Slider": "newSlider(" & v("value") & ", " & v("minValue") & ", " & v("maxValue") & ", " & v("step") &
               ", " & v("vertical") & ")"
  of "RangeSlider": "newRangeSlider(" & v("lower") & ", " & v("upper") & ", " & v("minValue") & ", " & v("maxValue") & ")"
  of "ProgressBar": "newProgressBar(" & v("value") & ", " & v("minValue") & ", " & v("maxValue") & ", " & v("showText") & ")"
  of "Rating": "newRating(" & v("value") & ", " & v("maxValue") & ")"
  of "Scrollbar": "newScrollbar(" & v("vertical") & ", " & v("minValue") & ", " & v("maxValue") & ", " & v("pageSize") & ")"
  of "Shape": "newShape(" & v("shapeKind") & ", " & v("thickness") & ")"
  of "Image": "newImage(" & v("path") & ", " & v("mode") & ")"
  of "BarCode": "newBarCode(" & v("text") & ")"
  of "Calendar": "newCalendar(" & v("date") & ")"
  of "Chart": "newChart(" & v("chartKind") & ", " & v("title") & ")"
  of "TreeView": "newTreeView()"
  of "Table": "newTable(multiSelection = " & v("multiSelection") & ")"
  of "Grid": "newGrid(multiSelection = " & v("multiSelection") & ", editable = " & v("editable") & ")"
  else: "newLabel(" & lit(n.name) & ")"

proc genNode(n: DNode, parentVar, parentLayout: string, lines: var seq[string]) =
  let v = n.name
  if n.kind == "TabPage" or baseOf(n.kind) == "TabPage":
    lines.add "  let " & v & " = " & parentVar & ".addPage(" & valueLit(n, "caption") & ", " &
              valueLit(n, "layout") & ", " & valueLit(n, "columns") & ")"
  else:
    lines.add "  let " & v & " = " & parentVar & ".addChild(" & ctorExpr(n) & ")"
  lines.add "  " & v & ".name = " & lit(v)
  let base = baseOf(n.kind)
  proc fnum(k: string): float =
    try:
      result = parseFloat(n.getProp(k).strip)
    except ValueError:
      result = 0.0
  if n.getProp("tooltip").len > 0: lines.add "  " & v & ".tooltip = " & valueLit(n, "tooltip")
  if boolLit(n.getProp("visible")) == "false": lines.add "  " & v & ".visible = false"
  if n.getProp("state") notin ["", "csActive"]: lines.add "  " & v & ".state = " & n.getProp("state")
  if fnum("fixedWidth") > 0: lines.add "  " & v & ".fixedWidth = " & valueLit(n, "fixedWidth")
  if fnum("fixedHeight") > 0: lines.add "  " & v & ".fixedHeight = " & valueLit(n, "fixedHeight")
  if parentLayout == "lkAbsolute":
    lines.add "  " & v & ".fixedX = " & valueLit(n, "fixedX")
    lines.add "  " & v & ".fixedY = " & valueLit(n, "fixedY")
  if fnum("weight") > 0: lines.add "  " & v & ".weight = " & valueLit(n, "weight")
  if n.getProp("stretch").len > 0: lines.add "  " & v & ".stretch = " & boolLit(n.getProp("stretch"))
  if n.getProp("dock").len > 0: lines.add "  " & v & ".dock = " & n.getProp("dock")
  if n.getProp("textColor").len > 0:
    lines.add "  " & v & ".style.text = some(hex(" & lit(n.getProp("textColor")) & "))"
  if n.getProp("backgroundColor").len > 0:
    lines.add "  " & v & ".style.background = some(hex(" & lit(n.getProp("backgroundColor")) & "))"
  if base == "Button" and boolLit(n.getProp("flat")) == "true": lines.add "  " & v & ".flat = true"
  if base == "Grid":
    for c in n.getProp("gridColumns").split(';'):
      if c.strip.len == 0: continue
      let parts = c.split(':')
      let nm = parts[0].strip
      let title = if parts.len > 1: parts[1].strip else: nm
      lines.add "  discard " & v & ".addColumn(" & lit(nm) & ", " & lit(title) & ")"
  if base == "Table":
    for c in n.getProp("tableColumns").split(';'):
      if c.strip.len > 0: lines.add "  " & v & ".addColumn(" & lit(c.strip) & ")"
  lines.add "  result." & v & " = " & v & ".id"
  let layout = if isContainerKind(n.kind): n.getProp("layout") else: ""
  for c in n.children: genNode(c, v, layout, lines)

proc generateCode*(m: FormModel, root: string): string =
  # Complete form_<name>.nim module (design kept in a #[wdform … ]# block).
  let name = m.root.name
  let T = typeName(name)
  let imp = wdguiImport(root)
  let modName = imp.split('/')[^1]
  var modules: seq[string]
  for n in m.allNodes:
    let e = findEntry(n.kind)
    if e.module.len > 0 and e.module notin modules: modules.add e.module
  var o: seq[string]
  o.add "# Form \"" & name & "\" - generated by the wdnim form designer."
  o.add "# Regenerated on every change made in the designer: edit the design there, not this file."
  o.add "# The design is kept in the #[wdform ... ]# block at the end of the file."
  o.add "import " & imp
  o.add "export " & modName
  for mo in modules: o.add "import " & mo
  o.add ""
  o.add "type"
  o.add "  " & T & "* = object"
  o.add "    window*: ControlId"
  let nodes = m.allNodes
  for n in nodes:
    if n != m.root: o.add "    " & n.name & "*: ControlId"
  o.add ""
  o.add "proc build" & T & "*(dispatch: DispatchProc = nil): " & T & " ="
  o.add "  # Creates the window of the form (from the main thread or from an event handler)."
  let r = m.root
  o.add "  let win = newWindow(" & valueLit(r, "title") & ", " & valueLit(r, "width") & ", " &
        valueLit(r, "height") & ", dispatch, " & r.getProp("theme") & ", " & valueLit(r, "layout") & ")"
  o.add "  win.root.margin = " & valueLit(r, "margin")
  o.add "  win.root.spacing = " & valueLit(r, "spacing")
  o.add "  win.root.columns = " & valueLit(r, "columns")
  if boolLit(r.getProp("resizable")) == "false": o.add "  win.resizable = false"
  if boolLit(r.getProp("manualClose")) == "true": o.add "  win.manualClose = true"
  o.add "  result.window = win.id"
  var body: seq[string]
  for c in r.children: genNode(c, "win", r.getProp("layout"), body)
  o.add body
  o.add ""
  let fv = varName(name)
  o.add "proc controlOf*(f: " & T & ", control: string): ControlId ="
  o.add "  # Id of a control of the form from its name."
  o.add "  case control"
  o.add "  of \"window\": f.window"
  for n in nodes:
    if n != m.root: o.add "  of " & lit(n.name) & ": f." & n.name
  o.add "  else: NoControl"
  o.add ""
  o.add "var " & fv & "*: " & T & "   ## ids of the controls once show" & T & "() has run"
  o.add "var " & fv & "Routes: seq[tuple[control: string, kind: EventKind, handler: proc (ev: var Event) {.nimcall.}]]"
  o.add ""
  o.add "proc on" & T & "*(control: string, kind: EventKind, handler: proc (ev: var Event) {.nimcall.}) ="
  o.add "  # Associates a handler with an event of a control (written by the designer in your code)."
  o.add "  " & fv & "Routes.add((control, kind, handler))"
  o.add ""
  o.add "proc dispatch" & T & "*(ev: var Event) {.nimcall, gcsafe.} ="
  o.add "  {.cast(gcsafe).}:"
  o.add "    if ev.current != ev.id: return"
  o.add "    for r in " & fv & "Routes:"
  o.add "      if r.kind == ev.kind and controlOf(" & fv & ", r.control) == ev.id: r.handler(ev)"
  o.add ""
  o.add "proc show" & T & "*(): " & T & " {.discardable.} ="
  o.add "  # Creates and shows the window (before runApplication, or from an event handler)."
  o.add "  " & fv & " = build" & T & "(dispatch" & T & ")"
  o.add "  " & fv
  o.add ""
  var js = modelToJson(m).replace("#[", "\\u0023[").replace("]#", "]\\u0023")
  o.add "#[wdform"
  o.add js
  o.add "]#"
  o.join("\n") & "\n"

# user code: handlers and wiring
#
# In the code edited with the designer:
# * `import form_<name>` is added after the last top-level import;
# * a marked block is inserted before the program start (`when isMainModule`, or a top-level
#   call such as `main()`), else at the end. It holds the handler stubs created by the
#   designer and the registrations `onForm…("control", evKind, handler)`, regenerated on
#   every change. Handlers must be declared before the block's registrations.

proc beginMarker*(name: string): string =
  "# ---- wdnim form \"" & name & "\": begin (generated by the designer, keep these markers) ----"
proc endMarker*(name: string): string = "# ---- wdnim form \"" & name & "\": end ----"
proc importLine*(name: string): string = "import " & formFileName(name)[0 ..< ^4]

proc existingHandlers*(code: string): seq[string] =
  # Procs with an `(ev: var Event)` parameter found in the code.
  for raw in code.splitLines:
    let l = raw.strip
    if not l.startsWith("proc "): continue
    if "var Event" notin l: continue
    var name = ""
    for c in l[5 .. ^1]:
      if c.isAlphaNumeric or c == '_': name.add c
      else: break
    if name.len > 0 and name notin result: result.add name

proc handlerStub*(handler, event, nodeName, formName: string): string =
  "proc " & handler & "(ev: var Event) =\n" &
  "  # " & event & " on " & nodeName & " (form \"" & formName & "\")\n" &
  "  discard  # TODO\n"

proc blockRange(lines: seq[string], name: string): tuple[a, b: int] =
  result = (-1, -1)
  for i, l in lines:
    if l == beginMarker(name): result.a = i
    elif l == endMarker(name) and result.a >= 0:
      result.b = i
      return

proc startLine(lines: seq[string]): int =
  # Where the program starts: `when isMainModule`, or a top-level call like `main()`.
  for i, l in lines:
    if l.startsWith("when isMainModule"): return i
  for i, l in lines:
    if l.len > 0 and l[0].isAlphaAscii and l.endsWith(")") and "(" in l and not l.startsWith("proc ") and
       not l.startsWith("import") and not l.startsWith("from") and '=' notin l.split('(')[0]:
      return i
  lines.len

proc ensureWiring*(code, name: string): string =
  # Adds the import and the (empty) block if they are missing.
  var lines = code.split('\n')
  if importLine(name) notin lines:
    var at = -1
    for i, l in lines:
      if l.startsWith("import ") or l.startsWith("from "): at = i
    lines.insert(importLine(name), at + 1)
  if blockRange(lines, name).a < 0:
    let at = startLine(lines)
    let tip = "# call show" & typeName(name) & "() to open the form"
    for l in [endMarker(name), "", tip, beginMarker(name), ""]:
      lines.insert(l, at)
  lines.join("\n")

proc handlersBeforeRegistrations*(code, name: string): seq[string] =
  # Handlers usable by the form: those declared before the end of its block (or before
  # the program start when the block does not exist yet).
  let lines = code.split('\n')
  let r = blockRange(lines, name)
  let limit = if r.b >= 0: r.b else: startLine(lines)
  existingHandlers(lines[0 ..< min(limit, lines.len)].join("\n"))

proc setRegistrations*(code, name: string, regs: seq[tuple[control, event, handler: string]]): string =
  # Rewrites the `onForm…(…)` lines of the block from the model's associations.
  var lines = ensureWiring(code, name).split('\n')
  let prefix = "on" & typeName(name) & "("
  var r = blockRange(lines, name)
  var i = r.b - 1
  while i > r.a:
    if lines[i].startsWith(prefix): lines.delete(i)
    dec i
  r = blockRange(lines, name)
  var at = r.b
  while at - 1 > r.a and lines[at - 1].strip.len == 0: dec at
  for k in countdown(regs.high, 0):
    let g = regs[k]
    lines.insert(prefix & g.control.escape & ", " & g.event & ", " & g.handler & ")", at)
  lines.join("\n")

proc insertStub*(code, name, stub: string): tuple[text: string, line: int] =
  # Inserts a handler stub in the block, before the registrations; returns the new text
  # and the stub's first line (1-based).
  var lines = ensureWiring(code, name).split('\n')
  let r = blockRange(lines, name)
  let prefix = "on" & typeName(name) & "("
  var at = r.b
  for i in r.a + 1 ..< r.b:
    if lines[i].startsWith(prefix):
      at = i
      break
  let stubLines = stub.strip(leading = false).split('\n') & @[""]
  for k in countdown(stubLines.high, 0): lines.insert(stubLines[k], at)
  (lines.join("\n"), at + 1)

proc renameWiring*(code, oldName, newName: string): string =
  # Follows a form rename in the user code (import, markers, registrations, show call).
  result = code.replace(beginMarker(oldName), beginMarker(newName))
  result = result.replace(endMarker(oldName), endMarker(newName))
  result = result.replace(importLine(oldName), importLine(newName))
  result = result.replace("on" & typeName(oldName) & "(", "on" & typeName(newName) & "(")
  result = result.replace("show" & typeName(oldName) & "(", "show" & typeName(newName) & "(")
