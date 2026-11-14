# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
#
# runner.nim - Visual <-> text compilation and solver control
#
# These procedures are called from wdgui event handlers, each of which
# runs in its own thread: solving may take time without freezing the
# interface. Progress is published in gApp.res, then the views are
# invalidated (refreshResults).

import std/[strutils, tables, times, atomics, algorithm]
import ../../src/wdgui
import model, codegen, canvas, uistate, views, compat
import cpsat/solver, cpsat/lang

const
  taskComps = ["tache", "tache_variable"]
  agentComps = ["personnel", "equipement", "lieu"]
  stockComps = ["matiere", "consommable"]
  objectiveComps = ["min_fin", "min_somme_fins", "minimiser", "maximiser"]
  taskPalette = ["#4F8EF7", "#9B7BFF", "#27AE60", "#F2994A", "#EB5757",
                 "#2D9CDB", "#BB6BD9", "#6FCF97", "#E86AF0", "#F2C94C"]

var gLastProgress: float

#
# Visual -> text, text -> visual
#

proc leadingNodeId(msg: string): string =
  # "n3 (Task): ..." -> "n3"
  var i = 0
  while i < msg.len and msg[i] notin {' ', '(', ':'}: inc i
  let tok = msg[0 ..< i]
  if tok.len > 1 and tok[0] == 'n' and tok[1 .. ^1].allCharsInSet(Digits):
    result = tok

proc compileVisual*(quiet = false): bool =
  # Graph -> NCP text in the editor. Returns false on error.
  # quiet: automatic compilation (no message while the graph is still
  # incomplete; the faulty nodes are still highlighted in red).
  var text, err: string
  var nlines = 0
  withApp:
    for n in gApp.doc.nodes: n.error = ""
    try:
      let (t, _) = compileGraph(gApp.doc, gApp.lib)
      text = t
      nlines = t.countLines()
      gApp.doc.graphDirty = false
      gApp.doc.textDirty = false
    except CodegenError as e:
      err = e.msg
      let id = leadingNodeId(err)
      if id.len > 0:
        let n = gApp.doc.findNode(id)
        if n != nil: n.error = err
  refreshCanvas()
  if err.len > 0:
    setStatus("Incomplete visual: " & err)
    if not quiet:
      logMsg("Cannot compile the visual: " & err)
      flash(err)
    return false
  {.cast(gcsafe).}:
    ui.ncp.value = text
  if not quiet:
    logMsg("Visual compiled to NCP (" & $nlines & " lines)")
  setStatus("Visual compiled to NCP (" & $nlines & " lines)")
  result = true

proc importTextToVisual*() =
  # NCP text of the editor -> graph.
  var text: string
  {.cast(gcsafe).}:
    text = ui.ncp.value
  var notes: seq[string]
  var count = 0
  withApp:
    let (d, ns) = importText(text, gApp.lib)
    notes = ns
    d.path = gApp.doc.path
    d.modified = true
    gApp.doc = d
    gApp.selected = @[]
    gApp.selectedLink = -1
    count = d.nodes.len
    if gCanvas != nil: gCanvas.fitView()
  for n in notes: logMsg("Import: " & n)
  logMsg("Text imported into the visual: " & $count & " node(s)")
  setStatus("Text imported into the visual (" & $count & " nodes)")
  refreshCanvas()

#
# Result extraction (while holding gLock; does not call wdgui)
#

proc parseIntOr(s: string, d: int): int =
  try:
    result = parseInt(s.strip())
  except ValueError:
    result = d

proc extractResults(c: Compiler) =
  let doc = gApp.doc
  let lib = gApp.lib
  var r = addr gApp.res
  r.tasks = @[]
  r.agents = @[]
  r.stocks = @[]
  var ti = 0
  var taskColor = initTable[string, string]()
  for n in doc.nodes:
    if n.comp in taskComps and c.hasName(n.id & "_task_s"):
      let s = c.intValueOf(n.id & "_task_s")
      let d = c.intValueOf(n.id & "_task_d")
      var agents: seq[string] = @[]
      for l in doc.links:
        if l.src == n.id:
          let u = doc.findNode(l.dst)
          if u != nil and u.comp == "utilise":
            for l2 in doc.links:
              if l2.src == u.id:
                let a = doc.findNode(l2.dst)
                if a != nil: agents.add a.nodeLabel(lib)
      let colr = taskPalette[ti mod taskPalette.len]
      taskColor[n.id] = colr
      inc ti
      r.tasks.add TaskRes(node: n.id, name: n.nodeLabel(lib), color: colr,
                          start: s, dur: d, agents: agents)
      n.status = "start " & $s & "  ·  end " & $(s + d)
  r.tasks.sort(proc (a, b: TaskRes): int =
    result = cmp(a.start, b.start)
    if result == 0: result = cmp(a.name, b.name))
  for n in doc.nodes:
    if n.comp in agentComps and c.hasName(n.id & "_cap"):
      var a = AgentRes(node: n.id, name: n.nodeLabel(lib),
                       color: (if lib.comps.hasKey(n.comp): lib.comps[n.comp].color else: "#9B7BFF"),
                       capacity: c.intValueOf(n.id & "_cap", 1))
      for l in doc.linksInto(n.id, "horaire"):
        let A = c.intListOf(l.src & "_" & l.srcPort & "_a")
        let B = c.intListOf(l.src & "_" & l.srcPort & "_b")
        for k in 0 ..< min(A.len, B.len): a.windows.add((A[k], B[k]))
      for l in doc.linksInto(n.id, "usages"):
        let p = l.src & "_" & l.srcPort
        a.uses.add((c.intValueOf(p & "_s"), c.intValueOf(p & "_d"), c.intValueOf(p & "_q")))
      var peak = 0
      for u in a.uses:
        var load = 0
        for v in a.uses:
          if v[0] <= u[0] and u[0] < v[0] + v[1]: load += v[2]
        peak = max(peak, load)
      n.status = "peak " & $peak & " / " & $a.capacity
      r.agents.add a
  for n in doc.nodes:
    if n.comp in stockComps:
      var s = StockRes(node: n.id, name: n.nodeLabel(lib),
                       color: (if lib.comps.hasKey(n.comp): lib.comps[n.comp].color else: "#F2C94C"))
      s.init = parseIntOr(n.params.getOrDefault("initial", "0"), 0)
      if n.comp == "matiere":
        s.lo = parseIntOr(n.params.getOrDefault("min", "0"), 0)
        s.hi = parseIntOr(n.params.getOrDefault("max", "0"), 0)
      else:
        s.lo = 0
        s.hi = 1_000_000
      var level = s.init
      for l in doc.linksInto(n.id, "flux"):
        let p = l.src & "_" & l.srcPort
        let ev = (c.intValueOf(p & "_t"), c.intValueOf(p & "_dq"))
        s.events.add ev
        level += ev[1]
      n.status = "final level " & $level
      r.stocks.add s
  for n in doc.nodes:
    if n.comp in objectiveComps and r.hasObjective:
      n.status = "objective = " & $r.objective
  # named variables
  r.vars = @[]
  var names = c.topLevelNames()
  names.sort()
  for name in names:
    let prefix = name.split('_')[0]
    let n = doc.findNode(prefix)
    r.vars.add VarRes(node: (if n != nil: n.nodeLabel(lib) & " (" & n.id & ")" else: "-"),
                      name: name, value: c.valueOf(name))
    if r.vars.len >= 3000: break

proc fillVarsGrid() =
  var vars: seq[VarRes]
  withApp:
    vars = gApp.res.vars
  {.cast(gcsafe).}:
    ignore(gridDeleteAll(ui.vars))
    for v in vars:
      discard gridAddLine(ui.vars, v.node, v.name, v.value)

#
# Solver callbacks
#

proc progressCb(s: Solver): bool {.nimcall, gcsafe.} =
  {.cast(gcsafe).}:
    let stop = gStop.load()
    let now = epochTime()
    if now - gLastProgress < 0.08:
      return not stop
    gLastProgress = now
    var pct = -1.0
    withApp:
      gApp.res.conflicts = s.conflicts
      gApp.res.decisions = s.decisions
      gApp.res.propagations = s.propagations
      gApp.res.restarts = s.restarts
      gApp.res.elapsed = now - gApp.res.startTime
      if gApp.res.timeout > 0:
        pct = gApp.res.elapsed / gApp.res.timeout * 100
    if pct >= 0: setProgress(pct)
    refreshResults()
    result = not stop

proc solutionCb(c: Compiler, index, objective: int, hasObjective: bool) {.nimcall, gcsafe.} =
  {.cast(gcsafe).}:
    let now = epochTime()
    var msg = ""
    withApp:
      let r = addr gApp.res
      r.solutions = index
      r.elapsed = now - r.startTime
      r.conflicts = c.s.conflicts
      r.decisions = c.s.decisions
      r.propagations = c.s.propagations
      if hasObjective:
        r.hasObjective = true
        r.objective = objective
        r.curve.add((r.elapsed, objective))
        let (lo, hi) = c.objectiveBounds()
        r.bestBound = (if r.kind == "maximize": hi else: lo)
        # the bound cannot be "better" than the optimum found
        if r.kind == "minimize": r.bestBound = min(r.bestBound, objective)
        else: r.bestBound = max(r.bestBound, objective)
        msg = "Solution " & $index & ": objective = " & $objective &
              " (" & formatFloat(r.elapsed, ffDecimal, 2) & " s)"
      else:
        msg = "Solution " & $index & " (" & formatFloat(r.elapsed, ffDecimal, 2) & " s)"
      extractResults(c)
    logMsg(msg)
    setStatus(msg)
    refreshCanvas()
    refreshResults()

#
# Full solve
#

proc finish(status: SolveStatus, message: string) =
  withApp:
    gApp.res.status = status
    gApp.res.message = message
    gApp.res.elapsed = epochTime() - gApp.res.startTime
    gApp.solving = false
  {.cast(gcsafe).}:
    ui.btnSolve.state = csActive
    ui.btnStop.state = csGrayed
  setProgress(if status in {ssOptimal, ssAllFound, ssFeasible, ssInfeasible}: 100.0 else: 0.0)
  setStatus(statusLabel(status) & (if message.len > 0: " - " & message else: ""))
  refreshResults()
  refreshCanvas()

proc runSolve*() =
  var busy = false
  var needCompile = false
  var timeout = 0.0
  var maxSol = 0
  withApp:
    if gApp.solving:
      busy = true
    else:
      gApp.solving = true
      needCompile = gApp.doc.graphDirty and not gApp.doc.textDirty
      timeout = float(gApp.doc.timeout)
      maxSol = gApp.doc.maxSolutions
      gApp.res = Results(status: ssCompiling, startTime: epochTime(), timeout: timeout,
                         horizon: gApp.doc.horizon, unit: gApp.doc.unit)
      gApp.doc.clearStatuses()
  if busy:
    flash("A solve is already running")
    return
  gStop.store(false)
  gLastProgress = 0
  {.cast(gcsafe).}:
    ui.btnSolve.state = csGrayed
    ui.btnStop.state = csActive
  showTab(tabSolve)
  setProgress(0)
  refreshResults()
  logMsg("Solve requested")
  # 1) visual -> text if the graph has changed
  if needCompile:
    if not compileVisual():
      finish(ssError, "the visual does not compile (see the node in red)")
      return
  var text: string
  {.cast(gcsafe).}:
    text = ui.ncp.value
  if text.strip().len == 0:
    finish(ssError, "empty model")
    return
  # 2) text -> solver
  var comp: Compiler = nil
  try:
    comp = compileModel(text)
  except CpError as e:
    let line = errorLine(e.msg)
    let nodeId = nodeAtLine(text, line)
    var where = ""
    withApp:
      let n = gApp.doc.findNode(nodeId)
      if n != nil:
        n.error = e.msg
        where = " [" & n.nodeLabel(gApp.lib) & " / " & n.id & "]"
    logMsg("Model error" & where & ": " & e.msg)
    finish(ssError, e.msg & where)
    return
  except CatchableError as e:
    logMsg("Unexpected error: " & e.msg)
    finish(ssError, e.msg)
    return
  let s = comp.s
  let kind = comp.solveKindOf()
  withApp:
    gApp.res.kind = kind
    gApp.res.status = ssSearching
    gApp.res.boolVars = s.numVars
    gApp.res.intVars = s.numIntVars
    gApp.res.clauses = s.numClauses
    gApp.res.props = s.numProps
  logMsg("Model compiled: " & $s.numIntVars & " integer variables, " & $s.numVars &
         " booleans, " & $s.numClauses & " clauses, " & $s.numProps & " propagators")
  setStatus("Searching (" & kind & ")…")
  refreshResults()
  if not s.ok:
    finish(ssInfeasible, "inconsistency detected while posting the constraints")
    return
  s.progress = progressCb
  # 3) search
  var summary: RunSummary
  try:
    summary = comp.runInteractive(solutionCb, timeout, maxSol)
  except CatchableError as e:
    logMsg("Error during the search: " & e.msg)
    finish(ssError, e.msg)
    return
  let stopped = gStop.load()
  var status: SolveStatus
  if summary.solutions == 0:
    status = (if summary.complete: ssInfeasible elif stopped: ssStopped else: ssTimeout)
  else:
    case kind
    of "minimize", "maximize":
      status = (if summary.complete: ssOptimal elif stopped: ssStopped else: ssTimeout)
    of "all":
      status = (if summary.complete: ssAllFound elif stopped: ssStopped else: ssFeasible)
    else:
      status = ssFeasible
  withApp:
    gApp.res.conflicts = s.conflicts
    gApp.res.decisions = s.decisions
    gApp.res.propagations = s.propagations
    gApp.res.restarts = s.restarts
    if status == ssOptimal and gApp.res.hasObjective:
      gApp.res.bestBound = gApp.res.objective
  fillVarsGrid()
  var msg = $summary.solutions & " solution(s)"
  case status
  of ssOptimal:
    msg = "optimum = " & $summary.lastObjective
  of ssInfeasible:
    msg = "the constraints are contradictory"
  of ssTimeout, ssStopped:
    msg = (if summary.solutions > 0: "best solution kept" else: "no solution found")
  else:
    discard
  logMsg("End: " & statusLabel(status) & " - " & msg)
  finish(status, msg)

proc requestStop*() =
  gStop.store(true)
  logMsg("Stop requested")
