# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
#
# solver.nim - CP-SAT core (wdreka version: + progress monitoring)
#
#
# Architecture (same family as Chuffed / OR-Tools CP-SAT):
#
# * CDCL SAT engine: two watched literals, 1-UIP conflict analysis,
#   VSIDS heuristic, phase saving, Luby restarts,
#   periodic cleanup of learnt clauses.
# * Integer variables with *order encoding*: for x ∈ [lo, hi] we create
#   a boolean [x <= v] for every v ∈ [lo, hi-1], linked by the clauses
#   [x <= v] -> [x <= v+1]. The current bounds lb/ub are maintained
#   (and restored on backtracking) whenever one of these booleans is assigned.
# * Equality literals [x == v] created on demand.
# * Propagators (half-reified linear, product): each deduction is
#   explained by a clause ("lazy clause generation", LCG), which lets
#   conflict analysis learn nogoods mixing booleans and integer
#   bounds.
#
# Literals: lit = 2*var + sign (sign 1 = negative).
# Variable 0 is the constant TRUE (litTrue = 0, litFalse = 1).

import std/[tables, hashes, algorithm, math, times]

type
  CpError* = object of CatchableError
    # Modeling or usage error.

  Clause* = ref object
    lits*: seq[int]        # for a reason clause: lits[0] = implied literal
    learnt*: bool
    deleted*: bool
    activity*: float

  PropKind* = enum
    pkLinear,              # reif -> sum(coefs[i] * xs[i]) <= rhs
    pkTimes                # tz = tx * ty

  Propagator* = ref object
    case kind*: PropKind
    of pkLinear:
      coefs*: seq[int]
      xs*: seq[int]
      rhs*: int
      reif*: int
    of pkTimes:
      tx*, ty*, tz*: int

  VarSel* = enum vsInputOrder, vsFirstFail, vsSmallest, vsLargest
  ValSel* = enum vlMin, vlMax, vlSplit

  SearchGroup* = object
    vars*: seq[int]
    varSel*: VarSel
    valSel*: ValSel

  BoundEntry = object
    x: int
    isLb: bool
    old: int

  SolveResult* = enum srSat, srUnsat, srUnknown
  SearchRes = enum sSat, sUnsat, sRestart, sTimeout

  ProgressProc* = proc (s: Solver): bool {.nimcall, gcsafe.}
    # Called periodically during the search; returning false stops it.

  Solver* = ref object
    ok*: bool                      # false once an inconsistency at level 0 is proven
    # --- boolean variables ---
    assigns: seq[int8]             # 0 = free, 1 = true, -1 = false
    level: seq[int]
    reason: seq[Clause]
    polarity: seq[bool]            # true = pick the negative literal
    activity: seq[float]
    heapIdx: seq[int]
    heap: seq[int]
    seen: seq[bool]
    varInt: seq[int]               # integer variable this is an order literal of (-1 otherwise)
    varVal: seq[int]               # value v such that the variable = [x <= v]
    boolWatch: seq[seq[int]]       # propagators woken up when the boolean is assigned
    watches: seq[seq[Clause]]      # indexed by literal
    trail: seq[int]
    trailLim: seq[int]
    qhead: int
    clauses: seq[Clause]
    learnts: seq[Clause]
    # --- integer variables ---
    ivLb0*, ivUb0*: seq[int]       # initial domain
    ivBase: seq[int]               # first order boolean
    lbs*, ubs*: seq[int]           # current bounds
    intWatch: seq[seq[int]]        # propagators woken up by a bound change
    boundTrail: seq[BoundEntry]
    boundLim: seq[int]
    eqCache: Table[(int, int), int]
    # --- propagators ---
    props: seq[Propagator]
    inQueue: seq[bool]
    propQ: seq[int]
    propHead: int
    # --- search ---
    searchGroups*: seq[SearchGroup]
    varInc, claInc: float
    maxLearnts: float
    tick: int
    deadline*: float               # epochTime() limit (0 = none)
    progress*: ProgressProc        # progress monitoring (optional)
    startTime*: float              # epochTime() at the start of solving
    # --- statistics ---
    conflicts*, decisions*, propagations*, restarts*: int
    # --- last solution ---
    solVals*: seq[int]
    solAssigns: seq[int8]

const
  litTrue* = 0
  litFalse* = 1

#
# Integer arithmetic rounded towards -infinity
#

proc floorDivI*(a, b: int): int =
  result = a div b
  if (a mod b != 0) and ((a < 0) != (b < 0)):
    dec result

proc ceilDivI*(a, b: int): int = -floorDivI(-a, b)

proc floorModI*(a, b: int): int = a - b * floorDivI(a, b)

#
# Literals
#

proc mkLit*(v: int, negative = false): int {.inline.} =
  result = 2 * v + (if negative: 1 else: 0)

proc neg*(l: int): int {.inline.} = l xor 1
proc varOf*(l: int): int {.inline.} = l shr 1
proc isNeg*(l: int): bool {.inline.} = (l and 1) == 1

proc numVars*(s: Solver): int = s.assigns.len
proc numIntVars*(s: Solver): int = s.lbs.len
proc numClauses*(s: Solver): int = s.clauses.len
proc numLearnts*(s: Solver): int = s.learnts.len
proc numProps*(s: Solver): int = s.props.len
proc decisionLevel(s: Solver): int {.inline.} = s.trailLim.len

proc litValue*(s: Solver, l: int): int {.inline.} =
  # 1 = true, -1 = false, 0 = unassigned
  let a = int(s.assigns[varOf(l)])
  result = (if isNeg(l): -a else: a)

proc orderInfo*(s: Solver, v: int): (int, int) =
  # (integer variable, value) if boolean v is [x <= value], otherwise (-1, 0)
  result = (s.varInt[v], s.varVal[v])

#
# VSIDS heap (max-heap on activity)
#

proc percUp(s: Solver, i0: int) =
  var i = i0
  let x = s.heap[i]
  while i > 0:
    let p = (i - 1) div 2
    if s.activity[x] > s.activity[s.heap[p]]:
      s.heap[i] = s.heap[p]
      s.heapIdx[s.heap[i]] = i
      i = p
    else:
      break
  s.heap[i] = x
  s.heapIdx[x] = i

proc percDown(s: Solver, i0: int) =
  var i = i0
  let x = s.heap[i]
  let n = s.heap.len
  while true:
    var c = 2 * i + 1
    if c >= n:
      break
    if c + 1 < n and s.activity[s.heap[c + 1]] > s.activity[s.heap[c]]:
      inc c
    if s.activity[s.heap[c]] > s.activity[x]:
      s.heap[i] = s.heap[c]
      s.heapIdx[s.heap[i]] = i
      i = c
    else:
      break
  s.heap[i] = x
  s.heapIdx[x] = i

proc heapInsert(s: Solver, v: int) =
  if s.heapIdx[v] >= 0:
    return
  s.heap.add v
  s.heapIdx[v] = s.heap.len - 1
  s.percUp(s.heap.len - 1)

proc heapPop(s: Solver): int =
  result = s.heap[0]
  let last = s.heap.pop()
  s.heapIdx[result] = -1
  if s.heap.len > 0:
    s.heap[0] = last
    s.heapIdx[last] = 0
    s.percDown(0)

proc bumpVar(s: Solver, v: int) =
  s.activity[v] += s.varInc
  if s.activity[v] > 1e100:
    for i in 0 ..< s.activity.len:
      s.activity[i] *= 1e-100
    s.varInc *= 1e-100
  if s.heapIdx[v] >= 0:
    s.percUp(s.heapIdx[v])

proc bumpClause(s: Solver, c: Clause) =
  c.activity += s.claInc
  if c.activity > 1e20:
    for lc in s.learnts:
      lc.activity *= 1e-20
    s.claInc *= 1e-20

#
# Variables, assignment, propagator queue
#

proc newVar*(s: Solver): int =
  # Creates a "pure" boolean variable.
  result = s.assigns.len
  s.assigns.add 0'i8
  s.level.add 0
  s.reason.add nil
  s.polarity.add false
  s.activity.add 0.0
  s.heapIdx.add(-1)
  s.seen.add false
  s.varInt.add(-1)
  s.varVal.add 0
  s.boolWatch.add @[]
  s.watches.add @[]
  s.watches.add @[]
  s.heapInsert(result)

proc newLitVar*(s: Solver): int =
  # Creates a boolean variable and returns its positive literal.
  result = mkLit(s.newVar())

proc schedule(s: Solver, p: int) {.inline.} =
  if not s.inQueue[p]:
    s.inQueue[p] = true
    s.propQ.add p

proc assign(s: Solver, lit: int, reason: Clause) =
  let v = varOf(lit)
  s.assigns[v] = (if isNeg(lit): -1'i8 else: 1'i8)
  s.level[v] = s.decisionLevel
  s.reason[v] = reason
  s.trail.add lit
  let x = s.varInt[v]
  if x >= 0:
    let val = s.varVal[v]
    if not isNeg(lit):
      # [x <= val] becomes true: ub <= val
      if val < s.ubs[x]:
        s.boundTrail.add BoundEntry(x: x, isLb: false, old: s.ubs[x])
        s.ubs[x] = val
        for p in s.intWatch[x]:
          s.schedule(p)
    else:
      # [x <= val] becomes false: lb >= val + 1
      if val + 1 > s.lbs[x]:
        s.boundTrail.add BoundEntry(x: x, isLb: true, old: s.lbs[x])
        s.lbs[x] = val + 1
        for p in s.intWatch[x]:
          s.schedule(p)
  for p in s.boolWatch[v]:
    s.schedule(p)

proc clearQueue(s: Solver) =
  for i in s.propHead ..< s.propQ.len:
    s.inQueue[s.propQ[i]] = false
  s.propQ.setLen(0)
  s.propHead = 0

proc cancelUntil*(s: Solver, lvl: int) =
  # Backtracks to decision level lvl.
  if s.decisionLevel > lvl:
    let lim = s.trailLim[lvl]
    for i in countdown(s.trail.len - 1, lim):
      let l = s.trail[i]
      let v = varOf(l)
      s.assigns[v] = 0
      s.reason[v] = nil
      s.polarity[v] = isNeg(l)
      s.heapInsert(v)
    s.trail.setLen(lim)
    s.trailLim.setLen(lvl)
    s.qhead = s.trail.len
    let blim = s.boundLim[lvl]
    for i in countdown(s.boundTrail.len - 1, blim):
      let e = s.boundTrail[i]
      if e.isLb:
        s.lbs[e.x] = e.old
      else:
        s.ubs[e.x] = e.old
    s.boundTrail.setLen(blim)
    s.boundLim.setLen(lvl)
    s.clearQueue()

#
# Clauses
#

proc attach(s: Solver, c: Clause) =
  s.watches[c.lits[0]].add c
  s.watches[c.lits[1]].add c

proc addClause*(s: Solver, lits: openArray[int]) =
  # Adds a clause (at level 0 only). Simplifies it with respect to
  # the level-0 assignments.
  if not s.ok:
    return
  doAssert s.decisionLevel == 0, "addClause outside level 0"
  var ls: seq[int] = @[]
  for l in lits:
    let v = s.litValue(l)
    if v == 1:
      return
    if v == -1:
      continue
    if neg(l) in ls:
      return
    if l notin ls:
      ls.add l
  if ls.len == 0:
    s.ok = false
  elif ls.len == 1:
    s.assign(ls[0], nil)
  else:
    let c = Clause(lits: ls)
    s.clauses.add c
    s.attach(c)

#
# Integer variables (order encoding)
#

proc leLit*(s: Solver, x, v: int): int =
  # Literal [x <= v] (possibly the constant true/false).
  if v < s.ivLb0[x]:
    result = litFalse
  elif v >= s.ivUb0[x]:
    result = litTrue
  else:
    result = mkLit(s.ivBase[x] + (v - s.ivLb0[x]))

proc geLit*(s: Solver, x, v: int): int =
  # Literal [x >= v].
  result = neg(s.leLit(x, v - 1))

proc newIntVar*(s: Solver, lo, hi: int): int =
  # Creates an integer variable with domain [lo, hi].
  var h = hi
  if lo > hi:
    s.ok = false
    h = lo
  if h - lo > 5_000_000:
    raise newException(CpError, "domain too large: " & $lo & ".." & $h &
      " (maximum 5,000,000 values)")
  result = s.lbs.len
  s.ivLb0.add lo
  s.ivUb0.add h
  s.lbs.add lo
  s.ubs.add h
  s.ivBase.add s.numVars
  s.intWatch.add @[]
  for v in lo ..< h:
    let b = s.newVar()
    s.varInt[b] = result
    s.varVal[b] = v
  for v in lo ..< h - 1:
    s.addClause([neg(s.leLit(result, v)), s.leLit(result, v + 1)])

proc eqLit*(s: Solver, x, v: int): int =
  # Literal [x == v], created on demand (at level 0).
  if v < s.ivLb0[x] or v > s.ivUb0[x]:
    return litFalse
  if s.ivLb0[x] == s.ivUb0[x]:
    return litTrue
  let key = (x, v)
  if s.eqCache.hasKey(key):
    return s.eqCache[key]
  let e = s.newLitVar()
  s.eqCache[key] = e
  let a = s.leLit(x, v)
  let b = s.leLit(x, v - 1)
  s.addClause([neg(e), a])
  s.addClause([neg(e), neg(b)])
  s.addClause([neg(a), b, e])
  result = e

#
# Propagators
#

proc addPropagator(s: Solver, p: Propagator) =
  let id = s.props.len
  s.props.add p
  s.inQueue.add false
  case p.kind
  of pkLinear:
    for x in p.xs:
      s.intWatch[x].add id
    if p.reif != litTrue:
      s.boolWatch[varOf(p.reif)].add id
  of pkTimes:
    s.intWatch[p.tx].add id
    s.intWatch[p.ty].add id
    s.intWatch[p.tz].add id
  s.schedule(id)

proc postLinearLE*(s: Solver, coefs, xs: seq[int], rhs: int, reif = litTrue) =
  # Posts: reif -> sum(coefs[i] * xs[i]) <= rhs
  if not s.ok or reif == litFalse:
    return
  if xs.len == 0:
    if 0 > rhs:
      s.addClause([neg(reif)])
    return
  if xs.len == 1:
    let a = coefs[0]
    let x = xs[0]
    let l = (if a > 0: s.leLit(x, floorDivI(rhs, a)) else: s.geLit(x, ceilDivI(rhs, a)))
    s.addClause([neg(reif), l])
    return
  s.addPropagator(Propagator(kind: pkLinear, coefs: coefs, xs: xs, rhs: rhs, reif: reif))

proc addTimes*(s: Solver, x, y, z: int) =
  # Posts: z = x * y
  if not s.ok:
    return
  s.addPropagator(Propagator(kind: pkTimes, tx: x, ty: y, tz: z))

proc enqueue(s: Solver, lit: int, reasons: openArray[int]): Clause =
  # Deduces `lit` explained by the conjunction `reasons` (true literals).
  # Returns the conflict clause if `lit` is already false, nil otherwise.
  let v = s.litValue(lit)
  if v == 1:
    return nil
  let c = Clause(lits: newSeqOfCap[int](reasons.len + 1))
  c.lits.add lit
  for r in reasons:
    if r != litTrue:
      c.lits.add neg(r)
  if v == -1:
    return c
  s.assign(lit, c)
  result = nil

proc propLinear(s: Solver, p: Propagator): Clause =
  let rv = s.litValue(p.reif)
  if rv == -1:
    return nil
  let n = p.xs.len
  var bl = newSeq[int](n)       # literal justifying the bound used
  var mins = newSeq[int](n)     # minimal contribution of each term
  var minSum = 0
  for i in 0 ..< n:
    let a = p.coefs[i]
    let x = p.xs[i]
    if a > 0:
      mins[i] = a * s.lbs[x]
      bl[i] = s.geLit(x, s.lbs[x])
    else:
      mins[i] = a * s.ubs[x]
      bl[i] = s.leLit(x, s.ubs[x])
    minSum += mins[i]
  if minSum > p.rhs:
    if rv == 1:
      return s.enqueue(litFalse, bl & @[p.reif])
    return s.enqueue(neg(p.reif), bl)
  if rv != 1:
    return nil
  var reasons = newSeqOfCap[int](n)
  for i in 0 ..< n:
    let a = p.coefs[i]
    let x = p.xs[i]
    let slack = p.rhs - (minSum - mins[i])
    var lit = -1
    if a > 0:
      let nu = floorDivI(slack, a)
      if nu < s.ubs[x]:
        lit = s.leLit(x, nu)
    else:
      let nl = ceilDivI(slack, a)
      if nl > s.lbs[x]:
        lit = s.geLit(x, nl)
    if lit >= 0:
      reasons.setLen(0)
      for j in 0 ..< n:
        if j != i:
          reasons.add bl[j]
      reasons.add p.reif
      let c = s.enqueue(lit, reasons)
      if c != nil:
        return c
  result = nil

proc tighten(s: Solver, x, newLb, newUb: int, reasons: openArray[int]): Clause =
  if newLb > s.lbs[x]:
    let c = s.enqueue(s.geLit(x, newLb), reasons)
    if c != nil:
      return c
  if newUb < s.ubs[x]:
    let c = s.enqueue(s.leLit(x, newUb), reasons)
    if c != nil:
      return c
  result = nil

proc propTimes(s: Solver, p: Propagator): Clause =
  let x = p.tx
  let y = p.ty
  let z = p.tz
  # z from x and y
  block:
    let lx = s.lbs[x]
    let ux = s.ubs[x]
    let ly = s.lbs[y]
    let uy = s.ubs[y]
    let c1 = lx * ly
    let c2 = lx * uy
    let c3 = ux * ly
    let c4 = ux * uy
    let zl = min(min(c1, c2), min(c3, c4))
    let zu = max(max(c1, c2), max(c3, c4))
    let rs = [s.geLit(x, lx), s.leLit(x, ux), s.geLit(y, ly), s.leLit(y, uy)]
    let c = s.tighten(z, zl, zu, rs)
    if c != nil:
      return c
  # x (resp. y) from z when the other factor is fixed and non-zero
  for (a, b) in [(x, y), (y, x)]:
    if s.lbs[b] == s.ubs[b] and s.lbs[b] != 0:
      let k = s.lbs[b]
      let lz = s.lbs[z]
      let uz = s.ubs[z]
      var nl, nu: int
      if k > 0:
        nl = ceilDivI(lz, k)
        nu = floorDivI(uz, k)
      else:
        nl = ceilDivI(uz, k)
        nu = floorDivI(lz, k)
      let rs = [s.geLit(b, k), s.leLit(b, k), s.geLit(z, lz), s.leLit(z, uz)]
      let c = s.tighten(a, nl, nu, rs)
      if c != nil:
        return c
  result = nil

proc runProp(s: Solver, id: int): Clause =
  let p = s.props[id]
  case p.kind
  of pkLinear:
    result = s.propLinear(p)
  of pkTimes:
    result = s.propTimes(p)

#
# Propagation (BCP + propagators)
#

proc bcp(s: Solver): Clause =
  while s.qhead < s.trail.len:
    let p = s.trail[s.qhead]
    inc s.qhead
    inc s.propagations
    let falseLit = neg(p)
    var ws: seq[Clause] = @[]
    swap(ws, s.watches[falseLit])
    var conflict: Clause = nil
    for c in ws:
      if c.deleted:
        continue
      if conflict != nil:
        s.watches[falseLit].add c
        continue
      if c.lits[0] == falseLit:
        swap(c.lits[0], c.lits[1])
      if s.litValue(c.lits[0]) == 1:
        s.watches[falseLit].add c
        continue
      var found = false
      for k in 2 ..< c.lits.len:
        if s.litValue(c.lits[k]) != -1:
          swap(c.lits[1], c.lits[k])
          s.watches[c.lits[1]].add c
          found = true
          break
      if found:
        continue
      s.watches[falseLit].add c
      if s.litValue(c.lits[0]) == -1:
        conflict = c
      else:
        s.assign(c.lits[0], c)
    if conflict != nil:
      s.qhead = s.trail.len
      return conflict
  result = nil

proc propagate(s: Solver): Clause =
  while true:
    let c = s.bcp()
    if c != nil:
      return c
    if s.propHead >= s.propQ.len:
      s.propQ.setLen(0)
      s.propHead = 0
      return nil
    let id = s.propQ[s.propHead]
    inc s.propHead
    s.inQueue[id] = false
    let c2 = s.runProp(id)
    if c2 != nil:
      return c2

#
# Conflict analysis (1-UIP)
#

proc analyze(s: Solver, confl: Clause): (seq[int], int) =
  var learnt = @[-1]
  var pathC = 0
  var p = -1
  var idx = s.trail.len - 1
  var c = confl
  let dl = s.decisionLevel
  while true:
    if c.learnt:
      s.bumpClause(c)
    let start = (if p == -1: 0 else: 1)
    for j in start ..< c.lits.len:
      let q = c.lits[j]
      let v = varOf(q)
      if not s.seen[v] and s.level[v] > 0:
        s.seen[v] = true
        s.bumpVar(v)
        if s.level[v] >= dl:
          inc pathC
        else:
          learnt.add q
    while not s.seen[varOf(s.trail[idx])]:
      dec idx
    p = s.trail[idx]
    dec idx
    s.seen[varOf(p)] = false
    dec pathC
    if pathC <= 0:
      break
    c = s.reason[varOf(p)]
  learnt[0] = neg(p)
  var bt = 0
  if learnt.len > 1:
    var maxI = 1
    for i in 2 ..< learnt.len:
      if s.level[varOf(learnt[i])] > s.level[varOf(learnt[maxI])]:
        maxI = i
    swap(learnt[1], learnt[maxI])
    bt = s.level[varOf(learnt[1])]
  for i in 1 ..< learnt.len:
    s.seen[varOf(learnt[i])] = false
  result = (learnt, bt)

#
# Search
#

proc pickBranchLit(s: Solver): int =
  # 1) strategies declared by the user (`search` statement)
  for g in s.searchGroups:
    var best = -1
    var bestKey = high(int)
    for x in g.vars:
      let l = s.lbs[x]
      let u = s.ubs[x]
      if l == u:
        continue
      var key = 0
      case g.varSel
      of vsInputOrder: key = 0
      of vsFirstFail: key = u - l
      of vsSmallest: key = l
      of vsLargest: key = -u
      if key < bestKey:
        best = x
        bestKey = key
        if g.varSel == vsInputOrder:
          break
    if best >= 0:
      let l = s.lbs[best]
      let u = s.ubs[best]
      case g.valSel
      of vlMin: return s.leLit(best, l)
      of vlMax: return s.geLit(best, u)
      of vlSplit: return s.leLit(best, floorDivI(l + u, 2))
  # 2) VSIDS + phase saving
  while s.heap.len > 0:
    let v = s.heapPop()
    if s.assigns[v] == 0:
      return mkLit(v, s.polarity[v])
  result = -1

proc luby(y: float, x0: int): float =
  var size = 1
  var sq = 0
  while size < x0 + 1:
    inc sq
    size = 2 * size + 1
  var x = x0
  while size - 1 != x:
    size = (size - 1) shr 1
    dec sq
    x = x mod size
  result = pow(y, float(sq))

proc reduceDB(s: Solver) =
  s.learnts.sort(proc (a, b: Clause): int = cmp(a.activity, b.activity))
  let half = s.learnts.len div 2
  var kept: seq[Clause] = @[]
  for i in 0 ..< s.learnts.len:
    let c = s.learnts[i]
    let v0 = varOf(c.lits[0])
    let locked = s.reason[v0] == c and s.litValue(c.lits[0]) == 1
    if i < half and not locked and c.lits.len > 2:
      c.deleted = true
    else:
      kept.add c
  s.learnts = kept

proc search(s: Solver, budget: int): SearchRes =
  var nConfl = 0
  while true:
    inc s.tick
    if (s.tick and 1023) == 0:
      if s.deadline > 0.0 and epochTime() > s.deadline:
        s.cancelUntil(0)
        return sTimeout
      if s.progress != nil and not s.progress(s):
        s.cancelUntil(0)
        return sTimeout
    let confl = s.propagate()
    if confl != nil:
      inc s.conflicts
      inc nConfl
      if s.decisionLevel == 0:
        return sUnsat
      var maxL = 0
      for l in confl.lits:
        maxL = max(maxL, s.level[varOf(l)])
      if maxL == 0:
        return sUnsat
      if maxL < s.decisionLevel:
        s.cancelUntil(maxL)
      let (learnt, bt) = s.analyze(confl)
      s.cancelUntil(bt)
      if learnt.len == 1:
        s.assign(learnt[0], nil)
      else:
        let lc = Clause(lits: learnt, learnt: true)
        s.attach(lc)
        s.learnts.add lc
        s.bumpClause(lc)
        s.assign(learnt[0], lc)
      s.varInc /= 0.95
      s.claInc /= 0.999
    else:
      if nConfl >= budget:
        s.cancelUntil(0)
        return sRestart
      if float(s.learnts.len - s.trail.len) >= s.maxLearnts:
        s.reduceDB()
      let d = s.pickBranchLit()
      if d < 0:
        return sSat
      inc s.decisions
      s.trailLim.add s.trail.len
      s.boundLim.add s.boundTrail.len
      s.assign(d, nil)

proc solve*(s: Solver): SolveResult =
  # Looks for a solution. On return the solver is at level 0:
  # clauses/constraints can be added and `solve` called again
  # (enumeration, optimization).
  if not s.ok:
    return srUnsat
  if s.deadline > 0.0 and epochTime() > s.deadline:
    return srUnknown
  if s.startTime == 0.0:
    s.startTime = epochTime()
  if s.maxLearnts == 0.0:
    s.maxLearnts = max(2000.0, float(s.clauses.len) / 3.0)
  while true:
    let budget = int(luby(2.0, s.restarts) * 100.0)
    let r = s.search(budget)
    case r
    of sSat:
      s.solVals = s.lbs
      s.solAssigns = s.assigns
      s.cancelUntil(0)
      return srSat
    of sUnsat:
      s.cancelUntil(0)
      s.ok = false
      return srUnsat
    of sTimeout:
      return srUnknown
    of sRestart:
      inc s.restarts
      s.maxLearnts *= 1.05

proc solLit*(s: Solver, l: int): bool =
  # Value of a literal in the last solution.
  let a = int(s.solAssigns[varOf(l)])
  result = (if isNeg(l): -a else: a) == 1

proc newSolver*(): Solver =
  result = Solver(ok: true, varInc: 1.0, claInc: 1.0)
  result.eqCache = initTable[(int, int), int]()
  let v = result.newVar()          # variable 0 = constant TRUE
  result.assign(mkLit(v), nil)

proc statsString*(s: Solver): string =
  result = "% booleans: " & $s.numVars & ", integers: " & $s.numIntVars &
    ", clauses: " & $s.clauses.len & ", propagators: " & $s.props.len & "\n" &
    "% conflicts: " & $s.conflicts & ", decisions: " & $s.decisions &
    ", propagations: " & $s.propagations & ", restarts: " & $s.restarts &
    ", learnt clauses: " & $s.learnts.len
