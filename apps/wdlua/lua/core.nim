# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
#   wdlua - interpréteur Lua (dialecte du manuel) écrit en Nim
#   core : valeurs, tables, arbre syntaxique, état de l'interpréteur
#
# Les nombres suivent Lua 5.4 (entiers 64 bits et flottants distincts).
# Les tables ont une partie tableau (index 1..n) et une partie dictionnaire
# qui conserve l'ordre d'insertion, ce qui donne un `next` stable.

import std/[hashes, tables, sets, locks, atomics, math, strutils]

type
  ValueKind* = enum vkNil, vkBool, vkInt, vkNum, vkStr, vkTable, vkFunc, vkUser

  Value* = object
    case kind*: ValueKind
    of vkNil: discard
    of vkBool: b*: bool
    of vkInt: i*: int64
    of vkNum: n*: float64
    of vkStr: s*: string
    of vkTable: t*: LTable
    of vkFunc: f*: LFunc
    of vkUser: u*: LUser

  LTable* = ref object
    arr*: seq[Value]              # t[1..n]
    hkeys: seq[Value]
    hvals: seq[Value]
    hindex: Table[Value, int]
    hlive: int
    meta*: LTable

  Cell* = ref object              # variable locale capturable (upvalue).
    v*: Value

  NativeProc* = proc (L: Interp, args: seq[Value]): seq[Value] {.closure.}

  LFunc* = ref object
    name*: string
    case native*: bool
    of true:
      nfn*: NativeProc
    of false:
      proto*: Proto
      upvals*: seq[Cell]

  LUser* = ref object of RootObj  # base des données natives exposées à Lua.
    meta*: LTable
    tname*: string

  # arbre syntaxique

  BinOp* = enum
    opAdd = "+", opSub = "-", opMul = "*", opDiv = "/", opIDiv = "//", opMod = "%",
    opPow = "^", opConcat = "..", opEq = "==", opNe = "~=", opLt = "<", opLe = "<=",
    opGt = ">", opGe = ">=", opBAnd = "&", opBOr = "|", opBXor = "~", opShl = "<<",
    opShr = ">>"

  ExprKind* = enum
    ekNil, ekTrue, ekFalse, ekInt, ekNum, ekStr, ekVararg, ekFunc,
    ekLocal, ekUpval, ekGlobal, ekIndex, ekCall, ekMethod, ekBin, ekAnd, ekOr,
    ekNot, ekNeg, ekLen, ekBNot, ekParen, ekTable

  TItem* = object
    keyed*: bool
    key*, val*: Expr

  Expr* = ref object
    line*: int
    case kind*: ExprKind
    of ekInt: ival*: int64
    of ekNum: nval*: float64
    of ekStr: sval*: string
    of ekFunc: fproto*: Proto
    of ekLocal, ekUpval:
      slot*: int
      vname*: string
    of ekGlobal: gname*: string
    of ekIndex:
      obj*, key*: Expr
    of ekCall:
      fn*: Expr
      args*: seq[Expr]
    of ekMethod:
      mobj*: Expr
      mname*: string
      margs*: seq[Expr]
    of ekBin:
      op*: BinOp
      lhs*, rhs*: Expr
    of ekAnd, ekOr:
      a*, b*: Expr
    of ekNot, ekNeg, ekLen, ekBNot, ekParen:
      e*: Expr
    of ekTable: items*: seq[TItem]
    else: discard

  StmtKind* = enum
    skLocal, skAssign, skCompound, skCall, skDo, skWhile, skRepeat, skIf,
    skNumFor, skGenFor, skLocalFunc, skReturn, skBreak

  Stmt* = ref object
    line*: int
    case kind*: StmtKind
    of skLocal:
      lslots*: seq[int]
      lexprs*: seq[Expr]
    of skAssign:
      targets*, values*: seq[Expr]
    of skCompound:
      ctarget*: Expr
      cop*: BinOp
      cval*: Expr
    of skCall: call*: Expr
    of skDo: body*: seq[Stmt]
    of skWhile:
      wcond*: Expr
      wbody*: seq[Stmt]
    of skRepeat:
      rbody*: seq[Stmt]
      rcond*: Expr
    of skIf:
      conds*: seq[Expr]
      blocks*: seq[seq[Stmt]]
      elseBlock*: seq[Stmt]
    of skNumFor:
      fslot*: int
      fstart*, fstop*, fstep*: Expr
      fbody*: seq[Stmt]
    of skGenFor:
      gslots*: seq[int]
      gexprs*: seq[Expr]
      gbody*: seq[Stmt]
    of skLocalFunc:
      lfslot*: int
      lfunc*: Proto
    of skReturn: rexprs*: seq[Expr]
    of skBreak: discard

  UpDesc* = object
    fromLocal*: bool             # true : variable locale de la fonction englobante.
    index*: int
    name*: string

  Proto* = ref object
    name*, source*: string
    line*, lastLine*: int
    nparams*: int
    vararg*: bool
    nslots*: int
    slotNames*: seq[string]
    ups*: seq[UpDesc]
    body*: seq[Stmt]

  # exécution

  Frame* = ref object
    proto*: Proto
    fnName*: string
    slots*: seq[Cell]
    varargs*: seq[Value]
    upvals*: seq[Cell]
    line*: int
    ret*: seq[Value]

  Ctx* = ref object             # pile d'appels d'un fil (programme, coroutine, événement).
    frames*: seq[Frame]
    co*: Coroutine

  Sem* = ref object             # sémaphore (non lié à un thread : utilisable en passage de relais).
    lock: Lock
    cond: Cond
    count: int

  CoStatus* = enum csSuspended = "suspended", csRunning = "running",
                   csNormal = "normal", csDead = "dead"

  Coroutine* = ref object of LUser
    L*: Interp
    fn*: Value
    status*: CoStatus
    ctx*: Ctx
    started*, killed*, errored*: bool
    transfer*: seq[Value]
    errVal*: Value
    resumeSem*, yieldSem*: Sem
    thr*: ptr Thread[Coroutine]

  StepMode* = enum smRun, smInto, smOver, smOut, smPause

  Debugger* = ref object
    lock*: Lock
    cond*: Cond
    active*: bool
    mode*: StepMode
    depth*: int
    cmd*: StepMode
    resumed*: bool
    breakpoints*: Table[string, HashSet[int]]
    lastLine*, lastDepth*: int
    lastSource*: string
    lastStmt*: pointer
    onPause*: proc (L: Interp, ctx: Ctx) {.closure.}

  Interp* = ref object
    globals*, stringMeta*, loaded*, registry*: LTable
    output*: proc (s: string) {.closure.}
    errput*: proc (s: string) {.closure.}
    input*: proc (prompt: string): (bool, string) {.closure.}
    sourceProvider*: proc (path: string): (bool, string) {.closure.}
    onError*: proc (msg: string) {.closure.}     # erreurs dans les gestionnaires d'événements.
    searchDirs*: seq[string]
    dbg*: Debugger
    stopFlag*: Atomic[bool]
    parentStop*: ptr Atomic[bool]                 # arrêt demandé par un thread parent.
    gil*: Sem
    maxDepth*: int
    coroutines*: seq[Coroutine]
    ext*: Table[string, RootRef]                  # données privées des paquets.
    closers*: seq[proc () {.closure.}]
    scriptPath*: string
    args*: seq[string]
    startTime*: float
    hosted*: bool                                 # exécuté dans l'IDE (et non par le runtime).

  LuaError* = object of CatchableError
    value*: Value
    traceback*: string

  LuaStop* = object of CatchableError             # arrêt demandé, coroutine fermée.

var curCtx* {.threadvar.}: Ctx

template nilV*: Value = Value(kind: vkNil)

#
# Sémaphore
#

proc newSem*(initial = 0): Sem =
  result = Sem(count: initial)
  initLock(result.lock)
  initCond(result.cond)

proc wait*(s: Sem) =
  acquire(s.lock)
  while s.count <= 0: wait(s.cond, s.lock)
  dec s.count
  release(s.lock)

proc post*(s: Sem) =
  acquire(s.lock)
  inc s.count
  signal(s.cond)
  release(s.lock)

#
# Constructeurs et prédicats
#

proc boolV*(b: bool): Value {.inline.} = Value(kind: vkBool, b: b)
proc intV*(i: int64): Value {.inline.} = Value(kind: vkInt, i: i)
proc intV*(i: int): Value {.inline.} = Value(kind: vkInt, i: int64(i))
proc numV*(n: float64): Value {.inline.} = Value(kind: vkNum, n: n)
proc strV*(s: string): Value {.inline.} = Value(kind: vkStr, s: s)
proc tableV*(t: LTable): Value {.inline.} =
  if t.isNil: nilV else: Value(kind: vkTable, t: t)
proc funcV*(f: LFunc): Value {.inline.} = Value(kind: vkFunc, f: f)
proc userV*(u: LUser): Value {.inline.} =
  if u.isNil: nilV else: Value(kind: vkUser, u: u)

proc fnV*(name: string, p: NativeProc): Value =
  Value(kind: vkFunc, f: LFunc(name: name, native: true, nfn: p))

proc isNil*(v: Value): bool {.inline.} = v.kind == vkNil
proc truthy*(v: Value): bool {.inline.} =
  not (v.kind == vkNil or (v.kind == vkBool and not v.b))
proc isNumber*(v: Value): bool {.inline.} = v.kind in {vkInt, vkNum}

proc first*(vs: seq[Value]): Value {.inline.} =
  if vs.len > 0: vs[0] else: nilV

proc typeName*(v: Value): string =
  case v.kind
  of vkNil: "nil"
  of vkBool: "boolean"
  of vkInt, vkNum: "number"
  of vkStr: "string"
  of vkTable: "table"
  of vkFunc: "function"
  of vkUser:
    if v.u of Coroutine: "thread" else: "userdata"

#
# Égalité brute et hachage (clés de table)
#

proc rawEquals*(a, b: Value): bool =
  if a.kind != b.kind:
    if a.kind == vkInt and b.kind == vkNum: return float64(a.i) == b.n
    if a.kind == vkNum and b.kind == vkInt: return a.n == float64(b.i)
    return false
  case a.kind
  of vkNil: true
  of vkBool: a.b == b.b
  of vkInt: a.i == b.i
  of vkNum: a.n == b.n
  of vkStr: a.s == b.s
  of vkTable: a.t == b.t
  of vkFunc: a.f == b.f
  of vkUser: a.u == b.u

proc `==`*(a, b: Value): bool = rawEquals(a, b)

proc hash*(v: Value): Hash =
  case v.kind
  of vkNil: hash(0)
  of vkBool: hash(v.b)
  of vkInt: hash(v.i)
  of vkNum: hash(v.n)
  of vkStr: hash(v.s)
  of vkTable: hash(cast[pointer](v.t))
  of vkFunc: hash(cast[pointer](v.f))
  of vkUser: hash(cast[pointer](v.u))

#
# Tables
#

proc newLTable*(narr = 0): LTable =
  result = LTable(hindex: initTable[Value, int]())
  if narr > 0: result.arr = newSeqOfCap[Value](narr)

proc normKey(k: Value): Value {.inline.} =
  if k.kind == vkNum:
    let f = k.n
    if f == floor(f) and f >= -9.2e18 and f <= 9.2e18:
      return Value(kind: vkInt, i: int64(f))
  k

proc hget(t: LTable, k: Value): Value {.inline.} =
  let p = t.hindex.getOrDefault(k, -1)
  if p >= 0: t.hvals[p] else: nilV

proc compact(t: LTable) =
  var ks, vs: seq[Value]
  var idx = initTable[Value, int]()
  for i in 0 ..< t.hkeys.len:
    if t.hvals[i].kind != vkNil:
      idx[t.hkeys[i]] = ks.len
      ks.add t.hkeys[i]
      vs.add t.hvals[i]
  t.hkeys = ks
  t.hvals = vs
  t.hindex = idx
  t.hlive = ks.len

proc hset(t: LTable, k, v: Value) =
  let p = t.hindex.getOrDefault(k, -1)
  if p >= 0:
    if t.hvals[p].kind == vkNil and v.kind != vkNil: inc t.hlive
    elif t.hvals[p].kind != vkNil and v.kind == vkNil: dec t.hlive
    t.hvals[p] = v
  elif v.kind != vkNil:
    if t.hkeys.len > 16 and t.hkeys.len > 2 * t.hlive: t.compact()
    t.hindex[k] = t.hkeys.len
    t.hkeys.add k
    t.hvals.add v
    inc t.hlive

proc rawGet*(t: LTable, key: Value): Value =
  let k = normKey(key)
  case k.kind
  of vkInt:
    if k.i >= 1 and k.i <= t.arr.len: return t.arr[k.i - 1]
  of vkNil: return nilV
  else: discard
  t.hget(k)

proc rawGet*(t: LTable, key: string): Value {.inline.} = t.hget(strV(key))
proc rawGet*(t: LTable, key: int): Value {.inline.} = t.rawGet(intV(key))

proc rawSet*(t: LTable, key, v: Value) =
  let k = normKey(key)
  if k.kind == vkNil: raise newException(ValueError, "index de table nil")
  if k.kind == vkNum and k.n != k.n: raise newException(ValueError, "index de table NaN")
  if k.kind == vkInt:
    let n = t.arr.len
    if k.i >= 1 and k.i <= n:
      t.arr[k.i - 1] = v
      if v.kind == vkNil and k.i == n:
        while t.arr.len > 0 and t.arr[^1].kind == vkNil: t.arr.setLen(t.arr.len - 1)
      return
    if k.i == n + 1 and v.kind != vkNil:
      t.arr.add v
      if t.hlive > 0:
        t.hset(k, nilV)
        var nk = intV(k.i + 1)
        while true:
          let nv = t.hget(nk)
          if nv.kind == vkNil: break
          t.arr.add nv
          t.hset(nk, nilV)
          inc nk.i
      return
  t.hset(k, v)

proc rawSet*(t: LTable, key: string, v: Value) {.inline.} = t.hset(strV(key), v)
proc rawSet*(t: LTable, key: int, v: Value) {.inline.} = t.rawSet(intV(key), v)

proc rawLen*(t: LTable): int =
  result = t.arr.len
  if result == 0 and t.hlive > 0:
    # tableau construit par la partie dictionnaire (t[1] affecté après t[2]).
    var i = 1
    while t.hget(intV(i)).kind != vkNil: inc i
    result = i - 1

proc next*(t: LTable, key: Value, ok: var bool): (Value, Value) =
  ## Paire suivant `key` (nil = début). ok = false si la clé est invalide.
  ok = true
  var start = 0
  var k = normKey(key)
  if k.kind == vkNil:
    start = 0
  elif k.kind == vkInt and k.i >= 1 and k.i <= t.arr.len:
    start = int(k.i)
  else:
    let p = t.hindex.getOrDefault(k, -1)
    if p < 0:
      ok = false
      return (nilV, nilV)
    for j in p + 1 ..< t.hkeys.len:
      if t.hvals[j].kind != vkNil: return (t.hkeys[j], t.hvals[j])
    return (nilV, nilV)
  for i in start ..< t.arr.len:
    if t.arr[i].kind != vkNil: return (intV(i + 1), t.arr[i])
  for j in 0 ..< t.hkeys.len:
    if t.hvals[j].kind != vkNil: return (t.hkeys[j], t.hvals[j])
  (nilV, nilV)

iterator pairs*(t: LTable): (Value, Value) =
  for i in 0 ..< t.arr.len:
    if t.arr[i].kind != vkNil: yield (intV(i + 1), t.arr[i])
  var j = 0
  while j < t.hkeys.len:
    if t.hvals[j].kind != vkNil: yield (t.hkeys[j], t.hvals[j])
    inc j

proc tableFrom*(vals: openArray[Value]): LTable =
  result = newLTable(vals.len)
  for v in vals: result.arr.add v
  while result.arr.len > 0 and result.arr[^1].kind == vkNil: result.arr.setLen(result.arr.len - 1)

#
# Nombres
#

proc c_snprintf*(buf: cstring, n: csize_t, fmt: cstring): cint {.
  importc: "snprintf", header: "<stdio.h>", varargs.}

proc fmtNumber*(f: float64): string =
  if f != f: return (if signbit(f): "-nan" else: "nan")
  if f == Inf: return "inf"
  if f == NegInf: return "-inf"
  var buf: array[64, char]
  discard c_snprintf(cast[cstring](addr buf[0]), 64, "%.14g", f)
  result = $cast[cstring](addr buf[0])
  var looksInt = true
  for c in result:
    if c notin {'0'..'9', '-'}: looksInt = false
  if looksInt: result.add ".0"

proc parseHexFloat(s: string, i: var int): (bool, Value) =
  # s[i..] commence après « 0x ».
  var mant: uint64 = 0
  var fmant = 0.0
  var any = false
  var exp = 0
  var isFloat = false
  var overflowInt = false
  while i < s.len and s[i] in HexDigits:
    let d = uint64(parseHexInt($s[i]))
    mant = mant * 16 + d                         # les entiers hexadécimaux bouclent (Lua).
    fmant = fmant * 16 + float64(d)
    any = true
    inc i
  if i < s.len and s[i] == '.':
    isFloat = true
    inc i
    while i < s.len and s[i] in HexDigits:
      fmant = fmant * 16 + float64(parseHexInt($s[i]))
      exp -= 4
      any = true
      inc i
  if not any: return (false, nilV)
  if i < s.len and s[i] in {'p', 'P'}:
    isFloat = true
    inc i
    var sign = 1
    if i < s.len and s[i] in {'+', '-'}:
      if s[i] == '-': sign = -1
      inc i
    var e = 0
    var anyE = false
    while i < s.len and s[i] in Digits:
      e = e * 10 + (ord(s[i]) - ord('0'))
      anyE = true
      inc i
    if not anyE: return (false, nilV)
    exp += sign * e
  discard overflowInt
  if isFloat: (true, numV(fmant * pow(2.0, float64(exp))))
  else: (true, intV(cast[int64](mant)))

proc str2number*(str: string): (bool, Value) =
  # Conversion texte -> nombre selon Lua (avec 0b... en extension du manuel).
  let s = str.strip()
  if s.len == 0: return (false, nilV)
  var i = 0
  var neg = false
  if s[i] in {'+', '-'}:
    neg = s[i] == '-'
    inc i
  if i + 1 < s.len and s[i] == '0' and s[i + 1] in {'x', 'X'}:
    i += 2
    var (ok, v) = parseHexFloat(s, i)
    if not ok or i != s.len: return (false, nilV)
    if neg:
      if v.kind == vkInt: v.i = cast[int64](0'u64 - cast[uint64](v.i)) else: v.n = -v.n
    return (true, v)
  if i + 1 < s.len and s[i] == '0' and s[i + 1] in {'b', 'B'}:
    i += 2
    var m: uint64 = 0
    var any = false
    while i < s.len and s[i] in {'0', '1'}:
      m = m * 2 + uint64(ord(s[i]) - ord('0'))
      any = true
      inc i
    if not any or i != s.len: return (false, nilV)
    let v = cast[int64](m)
    return (true, intV(if neg: -v else: v))
  let body = s[i .. ^1]
  if body.len == 0: return (false, nilV)
  var isInt = true
  for c in body:
    if c notin Digits: isInt = false
  if isInt:
    try:
      let v = parseBiggestInt(body)
      return (true, intV(if neg: -v else: v))
    except ValueError:
      discard   # dépassement : flottant.
  if body.toLowerAscii in ["inf", "nan", "infinity"]: return (false, nilV)
  for c in body:
    if c notin Digits + {'.', 'e', 'E', '+', '-'}: return (false, nilV)
  try:
    let f = parseFloat(body)
    (true, numV(if neg: -f else: f))
  except ValueError:
    (false, nilV)

proc toInteger*(v: Value, ok: var bool): int64 =
  # Conversion exacte en entier (flottants à valeur entière, chaînes numériques).
  ok = true
  case v.kind
  of vkInt: v.i
  of vkNum:
    if v.n == floor(v.n) and v.n >= -9.2233720368547758e18 and v.n < 9.2233720368547758e18:
      int64(v.n)
    else:
      ok = false
      0
  of vkStr:
    let (good, n) = str2number(v.s)
    if good: toInteger(n, ok)
    else:
      ok = false
      0
  else:
    ok = false
    0

proc toFloat*(v: Value, ok: var bool): float64 =
  ok = true
  case v.kind
  of vkInt: float64(v.i)
  of vkNum: v.n
  of vkStr:
    let (good, n) = str2number(v.s)
    if not good:
      ok = false
      0.0
    elif n.kind == vkInt: float64(n.i)
    else: n.n
  else:
    ok = false
    0.0

proc rawToString*(v: Value): string =
  ## Conversion sans métaméthode.
  case v.kind
  of vkNil: "nil"
  of vkBool: $v.b
  of vkInt: $v.i
  of vkNum: fmtNumber(v.n)
  of vkStr: v.s
  of vkTable: "table: 0x" & toHex(cast[int](v.t), 12).toLowerAscii
  of vkFunc:
    if v.f.native: "builtin: " & v.f.name
    else: "function: 0x" & toHex(cast[int](v.f), 12).toLowerAscii
  of vkUser:
    (if v.u.tname.len > 0: v.u.tname else: typeName(v)) & ": 0x" &
      toHex(cast[int](v.u), 12).toLowerAscii
