# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
#   wdlua - évaluateur
#
# Interpréteur par parcours d'arbre. Points notables :
#   - chaque variable locale vit dans une cellule (capturable par les closures) ;
#   - les coroutines s'exécutent chacune sur un thread, avec passage de relais
#     par sémaphores : une seule s'exécute à la fois ;
#   - un « verrou global » (gil) sérialise l'accès à l'interpréteur entre le
#     programme principal et les gestionnaires d'événements wdgui ;
#   - le débogueur est appelé avant chaque instruction (points d'arrêt,
#     pas à pas, pas principal, sortie de fonction).

import std/[tables, sets, locks, atomics, math, strutils, times, os]
import core, parser, lexer

export core

type
  ExecResult = enum erNormal, erBreak, erReturn

#
# Erreurs
#

proc ctx*(): Ctx =
  if curCtx.isNil: curCtx = Ctx()
  curCtx

proc where*(): string =
  # " source:ligne: " de la fonction Lua en cours.
  let c = ctx()
  for i in countdown(c.frames.high, 0):
    let f = c.frames[i]
    if not f.proto.isNil: return f.proto.source & ":" & $f.line & ": "
  ""

proc traceback*(c: Ctx = nil): string =
  let c = if c.isNil: ctx() else: c
  result = "pile d'appels :"
  var n = 0
  for i in countdown(c.frames.high, 0):
    let f = c.frames[i]
    if f.proto.isNil:
      result.add "\n  [natif] " & f.fnName
    else:
      result.add "\n  " & f.proto.source & ":" & $f.line & " dans " &
        (if f.fnName.len > 0: f.fnName else: f.proto.name)
    inc n
    if n > 30:
      result.add "\n  ..."
      break

proc raiseValue*(v: Value) {.noreturn.} =
  var e = newException(LuaError, rawToString(v))
  e.value = v
  e.traceback = traceback()
  raise e

proc rtError*(msg: string) {.noreturn.} =
  # Erreur d'exécution avec position, comme `error` de niveau 1.
  raiseValue(strV(where() & msg))

#
# Interpréteur
#

proc newInterp*(): Interp =
  result = Interp(globals: newLTable(), stringMeta: newLTable(), loaded: newLTable(),
                  registry: newLTable(), maxDepth: 200, gil: newSem(1),
                  ext: initTable[string, RootRef](), startTime: epochTime())
  result.output = proc (s: string) = stdout.write s
  result.errput = proc (s: string) = stderr.write s
  result.input = proc (prompt: string): (bool, string) =
    if prompt.len > 0: stdout.write prompt
    try: (true, stdin.readLine()) except EOFError, IOError: (false, "")
  result.onError = proc (msg: string) = stderr.writeLine msg
  result.globals.rawSet("_G", tableV(result.globals))
  result.globals.rawSet("_VERSION", strV("Lua 5.4 (wdlua)"))

proc enter*(L: Interp) = L.gil.wait()
proc leave*(L: Interp) = L.gil.post()

template blocking*(L: Interp, body: untyped) =
  # Libère l'interpréteur pendant une attente (sleep, réseau, boucle UI...).
  L.leave()
  try:
    body
  finally:
    L.enter()

proc stopRequested*(L: Interp): bool {.inline.} =
  L.stopFlag.load(moRelaxed) or (not L.parentStop.isNil and L.parentStop[].load(moRelaxed))

proc requestStop*(L: Interp) =
  # Demande l'arrêt du programme (vérifié avant chaque instruction).
  L.stopFlag.store(true)

proc checkStop*(L: Interp) {.inline.} =
  if L.stopRequested(): raise newException(LuaStop, "exécution arrêtée")

#
# Métatables
#

proc getMeta*(L: Interp, v: Value): LTable =
  case v.kind
  of vkTable: v.t.meta
  of vkUser: v.u.meta
  of vkStr: L.stringMeta
  else: nil

proc metaField*(L: Interp, v: Value, name: string): Value =
  let m = L.getMeta(v)
  if m.isNil: nilV else: m.rawGet(name)

proc call*(L: Interp, f: Value, args: seq[Value]): seq[Value]

proc describe(e: Expr): string =
  if e.isNil: return ""
  case e.kind
  of ekGlobal: " (globale « " & e.gname & " »)"
  of ekLocal: " (locale « " & e.vname & " »)"
  of ekUpval: " (upvalue « " & e.vname & " »)"
  of ekIndex:
    if e.key.kind == ekStr: " (champ « " & e.key.sval & " »)" else: ""
  of ekMethod: " (méthode « " & e.mname & " »)"
  of ekStr, ekInt, ekNum: " (constante)"
  else: ""

proc index*(L: Interp, obj, key: Value, src: Expr = nil): Value =
  var o = obj
  for loop in 0 ..< 100:
    if o.kind == vkTable:
      let v = o.t.rawGet(key)
      if v.kind != vkNil: return v
      let mt = o.t.meta
      if mt.isNil: return nilV
      let h = mt.rawGet("__index")
      if h.kind == vkNil: return nilV
      if h.kind == vkFunc: return first(L.call(h, @[o, key]))
      o = h
    else:
      let h = L.metaField(o, "__index")
      if h.kind == vkNil:
        let what = if key.kind == vkStr: "le champ « " & key.s & " »" else: "une valeur"
        rtError("tentative d'indexer " & what & " d'une valeur " & typeName(o) & describe(src))
      if h.kind == vkFunc: return first(L.call(h, @[o, key]))
      o = h
  rtError("boucle de __index")

proc setIndex*(L: Interp, obj, key, val: Value, src: Expr = nil) =
  var o = obj
  for loop in 0 ..< 100:
    if o.kind == vkTable:
      let mt = o.t.meta
      if mt.isNil or o.t.rawGet(key).kind != vkNil:
        try: o.t.rawSet(key, val)
        except ValueError as e: rtError(e.msg)
        return
      let h = mt.rawGet("__newindex")
      if h.kind == vkNil:
        try: o.t.rawSet(key, val)
        except ValueError as e: rtError(e.msg)
        return
      if h.kind == vkFunc:
        discard L.call(h, @[o, key, val])
        return
      o = h
    else:
      let h = L.metaField(o, "__newindex")
      if h.kind == vkNil:
        rtError("tentative d'indexer une valeur " & typeName(o) & describe(src))
      if h.kind == vkFunc:
        discard L.call(h, @[o, key, val])
        return
      o = h
  rtError("boucle de __newindex")

proc tostr*(L: Interp, v: Value): string =
  let h = L.metaField(v, "__tostring")
  if h.kind != vkNil:
    let r = first(L.call(h, @[v]))
    if r.kind != vkStr: rtError("'__tostring' doit renvoyer une chaîne")
    return r.s
  let nm = L.metaField(v, "__name")
  if nm.kind == vkStr and v.kind in {vkTable, vkUser}:
    return nm.s & ": 0x" & toHex(cast[int](if v.kind == vkTable: cast[pointer](v.t) else: cast[pointer](v.u)), 12).toLowerAscii
  rawToString(v)

#
# Arithmétique
#

proc wrapAdd(a, b: int64): int64 {.inline.} = cast[int64](cast[uint64](a) + cast[uint64](b))
proc wrapSub(a, b: int64): int64 {.inline.} = cast[int64](cast[uint64](a) - cast[uint64](b))
proc wrapMul(a, b: int64): int64 {.inline.} = cast[int64](cast[uint64](a) * cast[uint64](b))

proc ifloordiv(a, b: int64): int64 =
  if b == -1: return wrapSub(0, a)
  result = a div b
  if (a mod b != 0) and ((a < 0) != (b < 0)): dec result

proc imod(a, b: int64): int64 =
  if b == -1: return 0
  result = a mod b
  if result != 0 and ((result < 0) != (b < 0)): result += b

proc fmod2(a, b: float64): float64 =
  if b == Inf and a >= 0: return a
  if b == NegInf and a <= 0: return a
  result = a mod b
  if result != 0 and ((result < 0) != (b < 0)): result += b

proc shiftLeft(a: int64, n: int64): int64 =
  if n <= -64 or n >= 64: return 0
  if n >= 0: cast[int64](cast[uint64](a) shl n)
  else: cast[int64](cast[uint64](a) shr (-n))

const metaNames: array[BinOp, string] = ["__add", "__sub", "__mul", "__div", "__idiv",
  "__mod", "__pow", "__concat", "__eq", "", "__lt", "__le", "", "", "__band", "__bor",
  "__bxor", "__shl", "__shr"]

proc tryMeta(L: Interp, a, b: Value, ev: string, res: var Value): bool =
  var h = L.metaField(a, ev)
  if h.kind == vkNil: h = L.metaField(b, ev)
  if h.kind == vkNil: return false
  res = first(L.call(h, @[a, b]))
  true

proc arith*(L: Interp, op: BinOp, a, b: Value, src: Expr = nil): Value =
  if a.kind == vkInt and b.kind == vkInt:
    let x = a.i
    let y = b.i
    case op
    of opAdd: return intV(wrapAdd(x, y))
    of opSub: return intV(wrapSub(x, y))
    of opMul: return intV(wrapMul(x, y))
    of opIDiv:
      if y == 0: rtError("tentative d'effectuer 'n//0'")
      return intV(ifloordiv(x, y))
    of opMod:
      if y == 0: rtError("tentative d'effectuer 'n%0'")
      return intV(imod(x, y))
    of opDiv: return numV(float64(x) / float64(y))
    of opPow: return numV(pow(float64(x), float64(y)))
    else: discard
  if op in {opBAnd, opBOr, opBXor, opShl, opShr}:
    var oka, okb: bool
    let x = toInteger(a, oka)
    let y = toInteger(b, okb)
    if oka and okb and a.kind != vkStr and b.kind != vkStr:
      case op
      of opBAnd: return intV(x and y)
      of opBOr: return intV(x or y)
      of opBXor: return intV(x xor y)
      of opShl: return intV(shiftLeft(x, y))
      else: return intV(shiftLeft(x, wrapSub(0, y)))
    var r: Value
    if L.tryMeta(a, b, metaNames[op], r): return r
    let bad = if a.isNumber and not oka: a elif b.isNumber and not okb: b else: (if a.isNumber: b else: a)
    if bad.kind == vkNum: rtError("le nombre n'a pas de représentation entière")
    rtError("tentative d'opération bit à bit sur une valeur " & typeName(bad) & describe(src))
  # flottants (avec conversion des chaînes numériques).
  var oka, okb: bool
  var x, y: float64
  if a.kind in {vkInt, vkNum, vkStr} and b.kind in {vkInt, vkNum, vkStr}:
    if a.kind == vkStr or b.kind == vkStr:
      # chaîne numérique : arithmétique entière possible.
      let (ga, va) = if a.kind == vkStr: str2number(a.s) else: (true, a)
      let (gb, vb) = if b.kind == vkStr: str2number(b.s) else: (true, b)
      if ga and gb: return L.arith(op, va, vb, src)
    x = toFloat(a, oka)
    y = toFloat(b, okb)
  if oka and okb:
    case op
    of opAdd: return numV(x + y)
    of opSub: return numV(x - y)
    of opMul: return numV(x * y)
    of opDiv: return numV(x / y)
    of opPow: return numV(pow(x, y))
    of opIDiv: return numV(floor(x / y))
    of opMod: return numV(fmod2(x, y))
    else: discard
  var r: Value
  if L.tryMeta(a, b, metaNames[op], r): return r
  let bad = if a.isNumber or (a.kind == vkStr and oka): b else: a
  rtError("tentative d'arithmétique sur une valeur " & typeName(bad) & describe(src))

proc luaEquals*(L: Interp, a, b: Value): bool =
  if rawEquals(a, b): return true
  if a.kind == b.kind and a.kind in {vkTable, vkUser}:
    var r: Value
    if L.tryMeta(a, b, "__eq", r): return truthy(r)
  false

proc lessThan*(L: Interp, a, b: Value, orEqual: bool, src: Expr = nil): bool =
  if a.isNumber and b.isNumber:
    if a.kind == vkInt and b.kind == vkInt: return (if orEqual: a.i <= b.i else: a.i < b.i)
    let x = if a.kind == vkInt: float64(a.i) else: a.n
    let y = if b.kind == vkInt: float64(b.i) else: b.n
    return (if orEqual: x <= y else: x < y)
  if a.kind == vkStr and b.kind == vkStr:
    return (if orEqual: a.s <= b.s else: a.s < b.s)
  var r: Value
  if L.tryMeta(a, b, (if orEqual: "__le" else: "__lt"), r): return truthy(r)
  if typeName(a) == typeName(b):
    rtError("tentative de comparer deux valeurs " & typeName(a) & describe(src))
  rtError("tentative de comparer " & typeName(a) & " avec " & typeName(b) & describe(src))

proc concat*(L: Interp, a, b: Value, src: Expr = nil): Value =
  if a.kind in {vkStr, vkInt, vkNum} and b.kind in {vkStr, vkInt, vkNum}:
    return strV(rawToString(a) & rawToString(b))
  var r: Value
  if L.tryMeta(a, b, "__concat", r): return r
  let bad = if a.kind in {vkStr, vkInt, vkNum}: b else: a
  rtError("tentative de concaténer une valeur " & typeName(bad) & describe(src))

proc length*(L: Interp, v: Value, src: Expr = nil): Value =
  if v.kind == vkStr: return intV(v.s.len)
  let h = L.metaField(v, "__len")
  if h.kind != vkNil: return first(L.call(h, @[v]))
  if v.kind == vkTable: return intV(v.t.rawLen)
  rtError("tentative de prendre la longueur d'une valeur " & typeName(v) & describe(src))

proc negate(L: Interp, v: Value, src: Expr): Value =
  case v.kind
  of vkInt: intV(wrapSub(0, v.i))
  of vkNum: numV(-v.n)
  else:
    if v.kind == vkStr:
      let (ok, n) = str2number(v.s)
      if ok: return L.negate(n, src)
    let h = L.metaField(v, "__unm")
    if h.kind != vkNil: return first(L.call(h, @[v, v]))
    rtError("tentative d'arithmétique sur une valeur " & typeName(v) & describe(src))

#
# Débogueur
#

proc newDebugger*(): Debugger =
  result = Debugger(breakpoints: initTable[string, HashSet[int]]())
  initLock(result.lock)
  initCond(result.cond)

proc setBreakpoints*(d: Debugger, source: string, lines: seq[int]) =
  withLock d.lock:
    d.breakpoints[source] = toHashSet(lines)

proc command*(d: Debugger, mode: StepMode) =
  # Reprise après une pause (smRun, smInto, smOver, smOut).
  withLock d.lock:
    d.cmd = mode
    d.resumed = true
    broadcast(d.cond)

proc requestPause*(d: Debugger) =
  withLock d.lock: d.mode = smPause

proc debugLine(L: Interp, fr: Frame, s: Stmt) =
  let d = L.dbg
  let c = ctx()
  let depth = c.frames.len
  let src = fr.proto.source
  var pause = false
  withLock d.lock:
    let sp = cast[pointer](s)
    let fresh = fr.line != d.lastLine or depth != d.lastDepth or src != d.lastSource or sp == d.lastStmt
    d.lastStmt = sp
    if fresh:
      d.lastLine = fr.line
      d.lastDepth = depth
      d.lastSource = src
      let bp = d.breakpoints.hasKey(src) and fr.line in d.breakpoints[src]
      case d.mode
      of smRun: pause = bp
      of smInto, smPause: pause = true
      of smOver: pause = bp or depth <= d.depth
      of smOut: pause = bp or depth < d.depth
  if not pause: return
  if not d.onPause.isNil: d.onPause(L, c)
  withLock d.lock:
    d.resumed = false
    while not d.resumed and not L.stopRequested(): wait(d.cond, d.lock)
    d.mode = d.cmd
    d.depth = depth
  L.checkStop()

#
# Évaluation
#

proc eval(L: Interp, fr: Frame, e: Expr): Value
proc evalMulti(L: Interp, fr: Frame, e: Expr): seq[Value]
proc execBlock(L: Interp, fr: Frame, body: seq[Stmt]): ExecResult

proc evalList(L: Interp, fr: Frame, exprs: seq[Expr]): seq[Value] =
  for i, e in exprs:
    if i == exprs.high and e.kind in {ekCall, ekMethod, ekVararg}:
      result.add L.evalMulti(fr, e)
    else:
      result.add L.eval(fr, e)

proc makeClosure(L: Interp, fr: Frame, p: Proto): Value =
  let f = LFunc(name: p.name, native: false, proto: p)
  f.upvals = newSeq[Cell](p.ups.len)
  for i, u in p.ups:
    if u.fromLocal:
      if fr.slots[u.index].isNil: fr.slots[u.index] = Cell()
      f.upvals[i] = fr.slots[u.index]
    else:
      f.upvals[i] = fr.upvals[u.index]
  funcV(f)

proc callLua(L: Interp, fn: LFunc, args: seq[Value]): seq[Value] =
  let c = ctx()
  if c.frames.len >= L.maxDepth: rtError("débordement de pile (récursion trop profonde)")
  let p = fn.proto
  let fr = Frame(proto: p, fnName: fn.name, slots: newSeq[Cell](p.nslots),
                 upvals: fn.upvals, line: p.line)
  for i in 0 ..< p.nparams:
    fr.slots[i] = Cell(v: (if i < args.len: args[i] else: nilV))
  if p.vararg and args.len > p.nparams: fr.varargs = args[p.nparams .. ^1]
  c.frames.add fr
  try:
    if L.execBlock(fr, p.body) == erReturn: result = move fr.ret
  finally:
    discard c.frames.pop()

proc call*(L: Interp, f: Value, args: seq[Value]): seq[Value] =
  if f.kind == vkFunc:
    if f.f.native:
      let c = ctx()
      if c.frames.len >= L.maxDepth: rtError("débordement de pile")
      c.frames.add Frame(fnName: f.f.name, line: 0)
      try:
        result = f.f.nfn(L, args)
      finally:
        discard c.frames.pop()
    else:
      result = L.callLua(f.f, args)
    return
  let h = L.metaField(f, "__call")
  if h.kind != vkNil:
    return L.call(h, @[f] & args)
  rtError("tentative d'appeler une valeur " & typeName(f))

proc callExpr(L: Interp, fr: Frame, e: Expr): seq[Value] =
  if e.kind == ekMethod:
    let o = L.eval(fr, e.mobj)
    let m = L.index(o, strV(e.mname), e.mobj)
    let args = @[o] & L.evalList(fr, e.margs)
    if m.kind != vkFunc and L.metaField(m, "__call").kind == vkNil:
      rtError("tentative d'appeler une valeur " & typeName(m) & " (méthode « " & e.mname & " »)")
    return L.call(m, args)
  let f = L.eval(fr, e.fn)
  let args = L.evalList(fr, e.args)
  if f.kind != vkFunc and L.metaField(f, "__call").kind == vkNil:
    rtError("tentative d'appeler une valeur " & typeName(f) & describe(e.fn))
  L.call(f, args)

proc evalMulti(L: Interp, fr: Frame, e: Expr): seq[Value] =
  case e.kind
  of ekCall, ekMethod: L.callExpr(fr, e)
  of ekVararg: fr.varargs
  else: @[L.eval(fr, e)]

proc eval(L: Interp, fr: Frame, e: Expr): Value =
  case e.kind
  of ekNil: nilV
  of ekTrue: boolV(true)
  of ekFalse: boolV(false)
  of ekInt: intV(e.ival)
  of ekNum: numV(e.nval)
  of ekStr: strV(e.sval)
  of ekVararg: first(fr.varargs)
  of ekFunc: L.makeClosure(fr, e.fproto)
  of ekLocal:
    let c = fr.slots[e.slot]
    if c.isNil: nilV else: c.v
  of ekUpval: fr.upvals[e.slot].v
  of ekGlobal: L.index(tableV(L.globals), strV(e.gname))
  of ekIndex: L.index(L.eval(fr, e.obj), L.eval(fr, e.key), e.obj)
  of ekCall, ekMethod: first(L.callExpr(fr, e))
  of ekParen: L.eval(fr, e.e)
  of ekAnd:
    let a = L.eval(fr, e.a)
    if not truthy(a): a else: L.eval(fr, e.b)
  of ekOr:
    let a = L.eval(fr, e.a)
    if truthy(a): a else: L.eval(fr, e.b)
  of ekNot: boolV(not truthy(L.eval(fr, e.e)))
  of ekNeg: L.negate(L.eval(fr, e.e), e.e)
  of ekLen: L.length(L.eval(fr, e.e), e.e)
  of ekBNot:
    let v = L.eval(fr, e.e)
    var ok: bool
    let x = toInteger(v, ok)
    if ok and v.kind != vkStr: intV(not x)
    else:
      let h = L.metaField(v, "__bnot")
      if h.kind == vkNil: rtError("tentative d'opération bit à bit sur une valeur " & typeName(v) & describe(e.e))
      first(L.call(h, @[v, v]))
  of ekBin:
    let a = L.eval(fr, e.lhs)
    let b = L.eval(fr, e.rhs)
    case e.op
    of opEq: boolV(L.luaEquals(a, b))
    of opNe: boolV(not L.luaEquals(a, b))
    of opLt: boolV(L.lessThan(a, b, false, e))
    of opLe: boolV(L.lessThan(a, b, true, e))
    of opGt: boolV(L.lessThan(b, a, false, e))
    of opGe: boolV(L.lessThan(b, a, true, e))
    of opConcat: L.concat(a, b, (if a.kind in {vkStr, vkInt, vkNum}: e.rhs else: e.lhs))
    else: L.arith(e.op, a, b, (if a.isNumber: e.rhs else: e.lhs))
  of ekTable:
    let t = newLTable()
    var n = 1
    for i, it in e.items:
      if it.keyed:
        let k = L.eval(fr, it.key)
        if k.kind == vkNil: rtError("index de table nil")
        try: t.rawSet(k, L.eval(fr, it.val))
        except ValueError as ex: rtError(ex.msg)
      elif i == e.items.high and it.val.kind in {ekCall, ekMethod, ekVararg}:
        for v in L.evalMulti(fr, it.val):
          t.rawSet(intV(n), v)
          inc n
      else:
        t.rawSet(intV(n), L.eval(fr, it.val))
        inc n
    tableV(t)

proc assign(L: Interp, fr: Frame, target: Expr, v: Value) =
  case target.kind
  of ekLocal:
    if fr.slots[target.slot].isNil: fr.slots[target.slot] = Cell(v: v)
    else: fr.slots[target.slot].v = v
  of ekUpval: fr.upvals[target.slot].v = v
  of ekGlobal: L.setIndex(tableV(L.globals), strV(target.gname), v)
  of ekIndex: L.setIndex(L.eval(fr, target.obj), L.eval(fr, target.key), v, target.obj)
  else: rtError("affectation impossible")

proc forNum(L: Interp, v: Value, what: string): Value =
  if v.kind in {vkInt, vkNum}: return v
  if v.kind == vkStr:
    let (ok, n) = str2number(v.s)
    if ok: return n
  rtError("la valeur " & what & " de 'for' doit être un nombre")

proc execStmt(L: Interp, fr: Frame, s: Stmt): ExecResult =
  fr.line = s.line
  if not L.dbg.isNil and L.dbg.active: L.debugLine(fr, s)
  if L.stopRequested(): raise newException(LuaStop, "exécution arrêtée")
  case s.kind
  of skLocal:
    let vals = L.evalList(fr, s.lexprs)
    for i, slot in s.lslots:
      fr.slots[slot] = Cell(v: (if i < vals.len: vals[i] else: nilV))
  of skLocalFunc:
    fr.slots[s.lfslot] = Cell()
    fr.slots[s.lfslot].v = L.makeClosure(fr, s.lfunc)
  of skAssign:
    if s.targets.len == 1 and s.values.len == 1:
      L.assign(fr, s.targets[0], L.eval(fr, s.values[0]))
    else:
      # évaluer d'abord les objets et clés des cibles, puis les valeurs.
      var objs, keys: seq[Value]
      for t in s.targets:
        if t.kind == ekIndex:
          objs.add L.eval(fr, t.obj)
          keys.add L.eval(fr, t.key)
        else:
          objs.add nilV
          keys.add nilV
      let vals = L.evalList(fr, s.values)
      for i, t in s.targets:
        let v = if i < vals.len: vals[i] else: nilV
        if t.kind == ekIndex: L.setIndex(objs[i], keys[i], v, t.obj)
        else: L.assign(fr, t, v)
  of skCompound:
    let t = s.ctarget
    if t.kind == ekIndex:
      let o = L.eval(fr, t.obj)
      let k = L.eval(fr, t.key)
      let old = L.index(o, k, t.obj)
      let rhs = L.eval(fr, s.cval)
      let nv = if s.cop == opConcat: L.concat(old, rhs, t) else: L.arith(s.cop, old, rhs, t)
      L.setIndex(o, k, nv, t.obj)
    else:
      let old = L.eval(fr, t)
      let rhs = L.eval(fr, s.cval)
      L.assign(fr, t, (if s.cop == opConcat: L.concat(old, rhs, t) else: L.arith(s.cop, old, rhs, t)))
  of skCall:
    discard L.callExpr(fr, s.call)
  of skDo:
    return L.execBlock(fr, s.body)
  of skWhile:
    while truthy(L.eval(fr, s.wcond)):
      let r = L.execBlock(fr, s.wbody)
      if r == erBreak: break
      if r == erReturn: return erReturn
      fr.line = s.line
  of skRepeat:
    while true:
      let r = L.execBlock(fr, s.rbody)
      if r == erBreak: break
      if r == erReturn: return erReturn
      if truthy(L.eval(fr, s.rcond)): break
  of skIf:
    for i, c in s.conds:
      if truthy(L.eval(fr, c)): return L.execBlock(fr, s.blocks[i])
    return L.execBlock(fr, s.elseBlock)
  of skNumFor:
    let a = L.forNum(L.eval(fr, s.fstart), "initiale")
    let b = L.forNum(L.eval(fr, s.fstop), "limite")
    let st = if s.fstep.isNil: intV(1) else: L.forNum(L.eval(fr, s.fstep), "du pas")
    if a.kind == vkInt and st.kind == vkInt and b.kind in {vkInt, vkNum}:
      if st.i == 0: rtError("le pas de 'for' vaut zéro")
      var lim: int64
      if b.kind == vkInt: lim = b.i
      elif st.i > 0: lim = (if b.n >= 9.2e18: high(int64) else: int64(floor(b.n)))
      else: lim = (if b.n <= -9.2e18: low(int64) else: int64(ceil(b.n)))
      var i = a.i
      while (st.i > 0 and i <= lim) or (st.i < 0 and i >= lim):
        fr.slots[s.fslot] = Cell(v: intV(i))
        let r = L.execBlock(fr, s.fbody)
        if r == erBreak: break
        if r == erReturn: return erReturn
        let nxt = wrapAdd(i, st.i)
        if (st.i > 0 and nxt < i) or (st.i < 0 and nxt > i): break   # dépassement.
        i = nxt
    else:
      var ok: bool
      let x0 = toFloat(a, ok)
      let x1 = toFloat(b, ok)
      let dx = toFloat(st, ok)
      if dx == 0: rtError("le pas de 'for' vaut zéro")
      var x = x0
      while (dx > 0 and x <= x1) or (dx < 0 and x >= x1):
        fr.slots[s.fslot] = Cell(v: numV(x))
        let r = L.execBlock(fr, s.fbody)
        if r == erBreak: break
        if r == erReturn: return erReturn
        x += dx
  of skGenFor:
    let init = L.evalList(fr, s.gexprs)
    let f = if init.len > 0: init[0] else: nilV
    let state = if init.len > 1: init[1] else: nilV
    var control = if init.len > 2: init[2] else: nilV
    while true:
      let rs = L.call(f, @[state, control])
      let v0 = first(rs)
      if v0.kind == vkNil: break
      control = v0
      for i, slot in s.gslots:
        fr.slots[slot] = Cell(v: (if i < rs.len: rs[i] else: nilV))
      let r = L.execBlock(fr, s.gbody)
      if r == erBreak: break
      if r == erReturn: return erReturn
      fr.line = s.line
  of skReturn:
    if s.rexprs.len == 1 and s.rexprs[0].kind in {ekCall, ekMethod}:
      fr.ret = L.callExpr(fr, s.rexprs[0])
    else:
      fr.ret = L.evalList(fr, s.rexprs)
    return erReturn
  of skBreak:
    return erBreak
  erNormal

proc execBlock(L: Interp, fr: Frame, body: seq[Stmt]): ExecResult =
  for s in body:
    let r = L.execStmt(fr, s)
    if r != erNormal: return r
  erNormal

#
# Chargement
#

proc load*(L: Interp, src, source: string): Value =
  # Compile un morceau de code ; lève SyntaxError.
  let p = parseChunk(src, source)
  funcV(LFunc(name: source, native: false, proto: p))

proc readSource*(L: Interp, path: string): string =
  if not L.sourceProvider.isNil:
    let (ok, s) = L.sourceProvider(path)
    if ok: return s
  readFile(path)

proc runFile*(L: Interp, path: string, args: seq[Value] = @[]): seq[Value] =
  # Exécute un fichier (le verrou global doit être détenu).
  let f = L.load(L.readSource(path), path)
  L.call(f, args)

#
# Coroutines (une par thread, une seule active à la fois)
#

proc coMain(co: Coroutine) {.thread.} =
  {.cast(gcsafe).}:
    curCtx = co.ctx
    try:
      co.transfer = co.L.call(co.fn, co.transfer)
    except LuaStop:
      co.killed = true
    except LuaError as e:
      co.errored = true
      co.errVal = e.value
    except SyntaxError as e:
      co.errored = true
      co.errVal = strV(e.msg)
    except CatchableError as e:
      co.errored = true
      co.errVal = strV(e.msg)
    co.status = csDead
    co.yieldSem.post()

proc newCoroutine*(L: Interp, fn: Value): Coroutine =
  result = Coroutine(L: L, fn: fn, status: csSuspended, tname: "thread",
                     resumeSem: newSem(), yieldSem: newSem())
  result.ctx = Ctx(co: result)
  L.coroutines.add result

proc resume*(L: Interp, co: Coroutine, args: seq[Value]): (bool, seq[Value]) =
  if co.status == csDead: return (false, @[strV("impossible de reprendre une coroutine terminée")])
  if co.status != csSuspended: return (false, @[strV("impossible de reprendre une coroutine non suspendue")])
  let caller = ctx()
  if not caller.co.isNil: caller.co.status = csNormal
  co.status = csRunning
  co.transfer = args
  if not co.started:
    co.started = true
    co.thr = createShared(Thread[Coroutine])
    createThread(co.thr[], coMain, co)
  else:
    co.resumeSem.post()
  co.yieldSem.wait()
  if not caller.co.isNil: caller.co.status = csRunning
  if co.killed: raise newException(LuaStop, "exécution arrêtée")
  if co.errored:
    co.errored = false
    return (false, @[co.errVal])
  (true, move co.transfer)

proc yieldCo*(L: Interp, vals: seq[Value]): seq[Value] =
  let co = ctx().co
  if co.isNil: rtError("tentative de yield hors d'une coroutine")
  co.transfer = vals
  co.status = csSuspended
  co.yieldSem.post()
  co.resumeSem.wait()
  if co.killed or L.stopRequested(): raise newException(LuaStop, "coroutine fermée")
  co.status = csRunning
  move co.transfer

proc closeCoroutine*(co: Coroutine) =
  ## Termine le thread d'une coroutine suspendue.
  if co.started and co.status == csSuspended:
    co.killed = true
    co.resumeSem.post()
    co.yieldSem.wait()
  if not co.thr.isNil:
    joinThread(co.thr[])
    deallocShared(co.thr)
    co.thr = nil
  co.status = csDead

proc shutdown*(L: Interp) =
  # Libère coroutines et ressources des paquets (fin d'exécution).
  for co in L.coroutines: closeCoroutine(co)
  L.coroutines.setLen(0)
  for c in L.closers:
    try: c() except CatchableError: discard
  L.closers.setLen(0)

proc elapsed*(L: Interp): float = epochTime() - L.startTime
