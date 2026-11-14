# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
#
# model.nim - wdreka data model
#
# * ComponentDef : definition of a library component (ports,
#   parameters, CP-SAT/NCP code template).
# * Library      : set of components, read at startup from
#   library/*.wdrk (base library + user library).
# * Document     : the graph (nodes + links) and its settings.
# * AppState     : state shared between the UI thread (drawing, mouse) and
#   the worker threads (menus, solver), protected by `gLock`.
#
# Golden rule: NEVER call the wdgui API (ControlId...) while holding gLock.

import std/[tables, strutils, locks, os, algorithm, math]

type
  PortDef* = object
    name*, typ*, label*: string
    multi*: bool                      # input accepting several links

  ParamDef* = object
    name*, kind*, default*, label*: string   # kind: int | expr | text | code

  ComponentDef* = ref object
    id*, label*, category*, color*, glyph*, doc*: string
    params*: seq[ParamDef]
    inputs*, outputs*: seq[PortDef]
    code*: string
    user*: bool                       # component created by the user

  Library* = ref object
    comps*: OrderedTable[string, ComponentDef]
    categoryOrder*: seq[string]

  Node* = ref object
    id*: string                       # n1, n2...
    comp*: string
    title*: string
    x*, y*: float
    params*: OrderedTable[string, string]
    customCode*: string               # hand-edited code (text -> visual)
    status*: string                   # result badge
    error*: string

  Link* = object
    src*, srcPort*, dst*, dstPort*: string

  Document* = ref object
    title*: string
    horizon*: int
    unit*: string
    timeout*: int
    maxSolutions*: int
    path*: string
    nodes*: seq[Node]
    links*: seq[Link]
    nextId*: int
    graphDirty*: bool                 # graph modified since the last compilation
    textDirty*: bool                  # NCP text edited by hand
    modified*: bool                   # not saved

  # ---- results (filled by the solver, read by the views) ----
  TaskRes* = object
    node*, name*, color*: string
    start*, dur*: int
    agents*: seq[string]
  AgentRes* = object
    node*, name*, color*: string
    capacity*: int
    windows*: seq[(int, int)]
    uses*: seq[(int, int, int)]       # (start, duration, quantity)
  StockRes* = object
    node*, name*, color*: string
    init*, lo*, hi*: int
    events*: seq[(int, int)]          # (time, change)
  VarRes* = object
    node*, name*, value*: string

  SolveStatus* = enum
    ssIdle, ssCompiling, ssSearching, ssOptimal, ssFeasible, ssAllFound,
    ssInfeasible, ssStopped, ssTimeout, ssError

  Results* = object
    status*: SolveStatus
    message*: string
    kind*: string
    startTime*, elapsed*: float
    timeout*: float
    solutions*: int
    hasObjective*: bool
    objective*: int
    bestBound*: int                   # objective bound proven at the root
    curve*: seq[(float, int)]         # (time, objective) of each improvement
    conflicts*, decisions*, propagations*, restarts*: int
    boolVars*, intVars*, clauses*, props*: int
    horizon*: int
    unit*: string
    tasks*: seq[TaskRes]
    agents*: seq[AgentRes]
    stocks*: seq[StockRes]
    vars*: seq[VarRes]

  AppState* = object
    lib*: Library
    doc*: Document
    selected*: seq[string]            # selected nodes
    selectedLink*: int                # -1 = none
    armed*: string                    # component to place on the next click
    panX*, panY*, zoom*: float
    res*: Results
    solving*: bool
    stopRequested*: bool
    libDir*: string
    log*: seq[string]

var
  gLock*: Lock
  gApp*: AppState

initLock(gLock)

template withApp*(body: untyped) =
  # Exclusive access to the shared state (forced gcsafe: protected by gLock).
  {.cast(gcsafe).}:
    withLock gLock:
      body

#
# Port types
#

const portTypes* = ["task", "usage", "flow", "time", "agent", "stock", "int", "bool", "any"]

proc portColor*(typ: string): string =
  case typ
  of "task": "#4F8EF7"
  of "usage": "#F2994A"
  of "flow": "#E86AF0"
  of "time": "#27AE60"
  of "agent": "#9B7BFF"
  of "stock": "#F2C94C"
  of "int": "#56CCF2"
  of "bool": "#EB5757"
  else: "#BDBDBD"

proc portTypeLabel*(typ: string): string =
  case typ
  of "task": "task"
  of "usage": "usage"
  of "flow": "flow"
  of "time": "schedule"
  of "agent": "agent"
  of "stock": "stock"
  of "int": "integer"
  of "bool": "boolean"
  else: "any"

proc canConnect*(outTyp, inTyp: string): bool =
  result = outTyp == inTyp or inTyp == "any" or outTyp == "any" or
           (inTyp == "int" and outTyp == "bool")

#
# Library: .wdrk format
#
# [composant tache]
# libelle   = Task
# categorie = Tasks
# couleur   = #4F8EF7
# glyphe    = T
# doc       = Fixed-duration activity
# param  duree     | int  | 2 | Duration
# entree avant     | task | Predecessor
# entrees taches   | task | Tasks          (multiple input)
# sortie task      | task | Task
# code <<<
# ... NCP template ...
# >>>

proc newLibrary*(): Library =
  result = Library(comps: initOrderedTable[string, ComponentDef]())

proc splitBar(s: string): seq[string] =
  for p in s.split('|'):
    result.add p.strip()

proc parseLibrary*(lib: Library, text: string, user: bool): seq[string] =
  # Adds the components found in the text; returns the list of errors.
  var cur: ComponentDef = nil
  var inCode = false
  var code: seq[string] = @[]
  var lineNo = 0
  for raw in text.splitLines():
    inc lineNo
    if inCode:
      if raw.strip() == ">>>":
        cur.code = code.join("\n")
        code = @[]
        inCode = false
      else:
        code.add raw
      continue
    let line = raw.strip()
    if line.len == 0 or line.startsWith("#"):
      continue
    if line.startsWith("[composant") and line.endsWith("]"):
      let id = line[10 .. ^2].strip()
      if id.len == 0:
        result.add "line " & $lineNo & ": missing component identifier"
        cur = nil
        continue
      cur = ComponentDef(id: id, label: id, category: "Misc",
                         color: "#7C5CFF", glyph: id[0 .. 0].toUpperAscii, user: user)
      lib.comps[id] = cur
      if cur.category notin lib.categoryOrder:
        discard
      continue
    if cur == nil:
      result.add "line " & $lineNo & ": statement outside a [composant] block"
      continue
    if line == "code <<<":
      inCode = true
      continue
    let sp = line.find({' ', '\t', '='})
    let key = (if sp < 0: line else: line[0 ..< sp]).strip()
    var rest = (if sp < 0: "" else: line[sp .. ^1]).strip()
    if rest.startsWith("="):
      rest = rest[1 .. ^1].strip()
    case key
    of "libelle": cur.label = rest
    of "categorie": cur.category = rest
    of "couleur": cur.color = rest
    of "glyphe": cur.glyph = rest
    of "doc": cur.doc = (if cur.doc.len > 0: cur.doc & " " else: "") & rest
    of "param":
      let f = splitBar(rest)
      if f.len < 3:
        result.add "line " & $lineNo & ": param name | type | default | label"
      else:
        cur.params.add ParamDef(name: f[0], kind: f[1], default: f[2],
                                label: (if f.len > 3: f[3] else: f[0]))
    of "entree", "entrees":
      let f = splitBar(rest)
      if f.len < 2:
        result.add "line " & $lineNo & ": entree name | type | label"
      else:
        cur.inputs.add PortDef(name: f[0], typ: f[1], multi: key == "entrees",
                               label: (if f.len > 2: f[2] else: f[0]))
    of "sortie":
      let f = splitBar(rest)
      if f.len < 2:
        result.add "line " & $lineNo & ": sortie name | type | label"
      else:
        cur.outputs.add PortDef(name: f[0], typ: f[1],
                                label: (if f.len > 2: f[2] else: f[0]))
    else:
      result.add "line " & $lineNo & ": unknown keyword '" & key & "'"
  if inCode:
    result.add "unterminated code <<< block (missing >>>)"
  for c in lib.comps.values:
    if c.category notin lib.categoryOrder:
      lib.categoryOrder.add c.category

proc componentToText*(c: ComponentDef): string =
  var lines = @["[composant " & c.id & "]",
                "libelle   = " & c.label,
                "categorie = " & c.category,
                "couleur   = " & c.color,
                "glyphe    = " & c.glyph]
  if c.doc.len > 0: lines.add "doc       = " & c.doc
  for p in c.params:
    lines.add "param   " & p.name & " | " & p.kind & " | " & p.default & " | " & p.label
  for p in c.inputs:
    lines.add (if p.multi: "entrees " else: "entree  ") & p.name & " | " & p.typ & " | " & p.label
  for p in c.outputs:
    lines.add "sortie  " & p.name & " | " & p.typ & " | " & p.label
  lines.add "code <<<"
  lines.add c.code
  lines.add ">>>"
  result = lines.join("\n") & "\n"

proc saveUserLibrary*(lib: Library, path: string) =
  var txt = "# wdreka user library (generated by the component editor)\n\n"
  for c in lib.comps.values:
    if c.user:
      txt.add componentToText(c) & "\n"
  writeFile(path, txt)

proc loadLibrary*(dir: string): (Library, seq[string]) =
  # Loads library/base.wdrk then every other *.wdrk (user.wdrk...).
  let lib = newLibrary()
  var errs: seq[string] = @[]
  let base = dir / "base.wdrk"
  if fileExists(base):
    for e in lib.parseLibrary(readFile(base), false):
      errs.add "base.wdrk " & e
  else:
    errs.add "base library not found: " & base
  var others: seq[string] = @[]
  if dirExists(dir):
    for f in walkFiles(dir / "*.wdrk"):
      if extractFilename(f) != "base.wdrk":
        others.add f
  others.sort()
  for f in others:
    for e in lib.parseLibrary(readFile(f), true):
      errs.add extractFilename(f) & " " & e
  result = (lib, errs)

#
# Document and graph
#

proc newDocument*(): Document =
  result = Document(title: "Untitled", horizon: 48, unit: "h", timeout: 30,
                    maxSolutions: 0, nextId: 1)

proc findNode*(d: Document, id: string): Node =
  for n in d.nodes:
    if n.id == id:
      return n
  result = nil

proc nodeLabel*(n: Node, lib: Library): string =
  if n.title.len > 0:
    return n.title
  if lib.comps.hasKey(n.comp):
    return lib.comps[n.comp].label
  result = n.comp

proc addNode*(d: Document, lib: Library, comp: string, x, y: float): Node =
  let id = "n" & $d.nextId
  inc d.nextId
  result = Node(id: id, comp: comp, x: x, y: y,
                params: initOrderedTable[string, string]())
  if lib.comps.hasKey(comp):
    for p in lib.comps[comp].params:
      result.params[p.name] = p.default
  d.nodes.add result
  d.graphDirty = true
  d.modified = true

proc removeNode*(d: Document, id: string) =
  var keep: seq[Node] = @[]
  for n in d.nodes:
    if n.id != id: keep.add n
  d.nodes = keep
  var kl: seq[Link] = @[]
  for l in d.links:
    if l.src != id and l.dst != id: kl.add l
  d.links = kl
  d.graphDirty = true
  d.modified = true

proc portDef*(lib: Library, n: Node, name: string, output: bool): PortDef =
  if lib.comps.hasKey(n.comp):
    let c = lib.comps[n.comp]
    for p in (if output: c.outputs else: c.inputs):
      if p.name == name:
        return p
  result = PortDef(name: name, typ: "any", label: name)

proc linksInto*(d: Document, node, port: string): seq[Link] =
  for l in d.links:
    if l.dst == node and l.dstPort == port:
      result.add l

proc addLink*(d: Document, lib: Library, l: Link): string =
  # Adds a link; returns "" or an error message.
  let a = d.findNode(l.src)
  let b = d.findNode(l.dst)
  if a == nil or b == nil:
    return "unknown node"
  if l.src == l.dst:
    return "a node cannot be linked to itself"
  let po = lib.portDef(a, l.srcPort, true)
  let pi = lib.portDef(b, l.dstPort, false)
  if not canConnect(po.typ, pi.typ):
    return "incompatible types: " & portTypeLabel(po.typ) & " → " & portTypeLabel(pi.typ)
  for x in d.links:
    if x == l:
      return "link already exists"
  if not pi.multi:
    var kl: seq[Link] = @[]
    for x in d.links:
      if not (x.dst == l.dst and x.dstPort == l.dstPort): kl.add x
    d.links = kl
  d.links.add l
  d.graphDirty = true
  d.modified = true
  result = ""

proc duplicateNodes*(d: Document, lib: Library, ids: seq[string]): seq[string] =
  for id in ids:
    let n = d.findNode(id)
    if n == nil: continue
    let m = d.addNode(lib, n.comp, n.x + 30, n.y + 30)
    m.title = n.title
    for k, v in n.params.pairs: m.params[k] = v
    m.customCode = n.customCode
    result.add m.id

proc clearStatuses*(d: Document) =
  for n in d.nodes:
    n.status = ""
    n.error = ""

#
# Node geometry ("world" coordinates, without zoom)
#

const
  nodeW* = 200.0
  headerH* = 30.0
  portRowH* = 22.0
  paramLineH* = 17.0
  maxParamLines* = 3

proc nodeHeight*(n: Node, lib: Library): float =
  var rows = 0
  var nparams = 0
  if lib.comps.hasKey(n.comp):
    let c = lib.comps[n.comp]
    rows = max(c.inputs.len, c.outputs.len)
    for p in c.params:
      if p.kind != "code": inc nparams
  result = headerH + 8 + float(max(rows, 1)) * portRowH +
           float(min(nparams, maxParamLines)) * paramLineH + 10
  if n.status.len > 0:
    result += 24

proc inPortPos*(n: Node, idx: int): (float, float) =
  result = (n.x, n.y + headerH + 8 + portRowH * (float(idx) + 0.5))

proc outPortPos*(n: Node, idx: int): (float, float) =
  result = (n.x + nodeW, n.y + headerH + 8 + portRowH * (float(idx) + 0.5))

proc bezierPoints*(x1, y1, x2, y2: float, steps = 24): seq[(float, float)] =
  let dx = max(50.0, abs(x2 - x1) * 0.5)
  let (cx1, cy1, cx2, cy2) = (x1 + dx, y1, x2 - dx, y2)
  for i in 0 .. steps:
    let t = float(i) / float(steps)
    let u = 1.0 - t
    let x = u*u*u*x1 + 3*u*u*t*cx1 + 3*u*t*t*cx2 + t*t*t*x2
    let y = u*u*u*y1 + 3*u*u*t*cy1 + 3*u*t*t*cy2 + t*t*t*y2
    result.add((x, y))

proc distToSegment*(px, py, ax, ay, bx, by: float): float =
  let dx = bx - ax
  let dy = by - ay
  let l2 = dx*dx + dy*dy
  var t = (if l2 == 0: 0.0 else: ((px - ax) * dx + (py - ay) * dy) / l2)
  t = max(0.0, min(1.0, t))
  let qx = ax + t * dx
  let qy = ay + t * dy
  result = sqrt((px - qx) * (px - qx) + (py - qy) * (py - qy))

proc addLog*(msg: string) =
  # must be called while holding gLock
  gApp.log.add msg
  if gApp.log.len > 500:
    gApp.log.delete(0)
