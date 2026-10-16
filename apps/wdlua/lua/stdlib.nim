# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
#   wdlua - bibliothèque standard
#
#   base       print, type, pairs, ipairs, pcall, error, require... (Lua 5.4)
#              + fonctions du manuel (§10.5 Strings, §10.6 Tables) :
#                add, del, deli, count, all, foreach, split, sub, chr, ord,
#                et flr, ceil, rnd, srand, mid, sgn, tostr, tonum, time / t
#   string     bibliothèque de chaînes, avec les motifs Lua
#   table      insert, remove, concat, sort, unpack, pack, move
#   math       fonctions mathématiques de Lua 5.4
#   coroutine  create, resume, yield, status, wrap, running, isyieldable, close
#   utf8       char, charpattern, codepoint, len, codes, offset

import std/[strutils, math, random, algorithm, os, tables, times]
from std/unicode import Rune, runeLen, runeLenAt, validateUtf8, fastRuneAt, `$`
import api, lpattern, lexer, parser

var rng {.threadvar.}: Rand
var rngInit {.threadvar.}: bool

proc theRng(): var Rand =
  if not rngInit:
    rng = initRand(int64(epochTime() * 1e6))
    rngInit = true
  rng

#
# base
#

proc luaPrint(L: Interp, a: seq[Value]): seq[Value] =
  var parts: seq[string]
  for v in a: parts.add L.tostr(v)
  L.output(parts.join("\t") & "\n")

proc ipairsIter(L: Interp, a: seq[Value]): seq[Value] =
  let i = arg(a, 2).i + 1
  let v = L.index(arg(a, 1), intV(i))
  if v.kind == vkNil: return @[nilV]
  @[intV(i), v]

proc nextFn(L: Interp, a: seq[Value]): seq[Value] =
  let t = L.checkTable(a, 1, "next")
  var ok: bool
  let (k, v) = t.next(arg(a, 2), ok)
  if not ok: rtError("clé invalide pour 'next'")
  if k.kind == vkNil: @[nilV] else: @[k, v]

proc protectedCall(L: Interp, f: Value, args: seq[Value], handler: Value): seq[Value] =
  let c = ctx()
  let depth = c.frames.len
  try:
    result = @[boolV(true)] & L.call(f, args)
  except LuaStop as e:
    raise e
  except LuaError as e:
    c.frames.setLen(depth)
    var v = e.value
    if handler.kind != vkNil: v = first(L.call(handler, @[v]))
    result = @[boolV(false), v]
  except SyntaxError as e:
    c.frames.setLen(depth)
    result = @[boolV(false), strV(e.msg)]
  except PatternError as e:
    c.frames.setLen(depth)
    result = @[boolV(false), strV(where() & e.msg)]
  except ValueError, IOError, OSError, KeyError, IndexDefect, RangeDefect:
    c.frames.setLen(depth)
    result = @[boolV(false), strV(where() & getCurrentExceptionMsg())]

proc findModule(L: Interp, name: string): string =
  let rel = name.replace('.', DirSep)
  var dirs = L.searchDirs
  if L.scriptPath.len > 0: dirs.add L.scriptPath.parentDir
  dirs.add getCurrentDir()
  for d in dirs:
    for cand in [d / rel & ".lua", d / rel / "init.lua"]:
      if fileExists(cand): return cand
      if not L.sourceProvider.isNil and L.sourceProvider(cand)[0]: return cand
  ""

proc loadChunk(L: Interp, src, name: string): seq[Value] =
  try:
    @[L.load(src, name)]
  except SyntaxError as e:
    @[nilV, strV(e.msg)]

proc openBase(L: Interp): Value =
  let g = L.globals
  g.fn "print", luaPrint
  g.fn "printh", proc (L: Interp, a: seq[Value]): seq[Value] =
    L.errput(L.checkStr(a, 1, "printh") & "\n")
  g.fn "type", proc (L: Interp, a: seq[Value]): seq[Value] =
    discard L.checkAny(a, 1, "type")
    @[strV(typeName(a[0]))]
  g.fn "tostring", proc (L: Interp, a: seq[Value]): seq[Value] =
    @[strV(L.tostr(L.checkAny(a, 1, "tostring")))]
  g.fn "tonumber", proc (L: Interp, a: seq[Value]): seq[Value] =
    let v = arg(a, 1)
    if arg(a, 2).kind == vkNil:
      if v.isNumber: return @[v]
      if v.kind == vkStr:
        let (ok, n) = str2number(v.s)
        if ok: return @[n]
      return @[nilV]
    let base = int(L.checkInt(a, 2, "tonumber"))
    if base < 2 or base > 36: argError(2, "tonumber", "base hors limites")
    let s = L.checkStr(a, 1, "tonumber").strip().toLowerAscii
    var neg = false
    var body = s
    if body.startsWith("-"):
      neg = true
      body = body[1 .. ^1]
    if body.len == 0: return @[nilV]
    var r: int64 = 0
    for ch in body:
      let d = if ch in Digits: ord(ch) - ord('0') elif ch in {'a'..'z'}: ord(ch) - ord('a') + 10 else: 99
      if d >= base: return @[nilV]
      r = r * base + d
    @[intV(if neg: -r else: r)]
  g.fn "ipairs", proc (L: Interp, a: seq[Value]): seq[Value] =
    discard L.checkAny(a, 1, "ipairs")
    @[fnV("ipairs_iter", ipairsIter), a[0], intV(0)]
  g.fn "next", nextFn
  g.fn "pairs", proc (L: Interp, a: seq[Value]): seq[Value] =
    let v = L.checkAny(a, 1, "pairs")
    let h = L.metaField(v, "__pairs")
    if h.kind != vkNil:
      let r = L.call(h, @[v])
      return @[arg(r, 1), arg(r, 2), arg(r, 3)]
    if v.kind != vkTable: argError(1, "pairs", "table attendue, " & typeName(v) & " reçu")
    @[fnV("next", nextFn), v, nilV]
  g.fn "select", proc (L: Interp, a: seq[Value]): seq[Value] =
    let n = arg(a, 1)
    if n.kind == vkStr and n.s == "#": return @[intV(a.len - 1)]
    var i = L.checkInt(a, 1, "select")
    if i < 0: i = a.len - 1 + i + 1
    elif i == 0: argError(1, "select", "index hors limites")
    if i >= a.len: return @[]
    a[int(i) .. ^1]
  g.fn "rawget", proc (L: Interp, a: seq[Value]): seq[Value] =
    @[L.checkTable(a, 1, "rawget").rawGet(arg(a, 2))]
  g.fn "rawset", proc (L: Interp, a: seq[Value]): seq[Value] =
    let t = L.checkTable(a, 1, "rawset")
    try: t.rawSet(arg(a, 2), arg(a, 3))
    except ValueError as e: rtError(e.msg)
    @[a[0]]
  g.fn "rawequal", proc (L: Interp, a: seq[Value]): seq[Value] =
    @[boolV(rawEquals(arg(a, 1), arg(a, 2)))]
  g.fn "rawlen", proc (L: Interp, a: seq[Value]): seq[Value] =
    let v = arg(a, 1)
    if v.kind == vkTable: @[intV(v.t.rawLen)]
    elif v.kind == vkStr: @[intV(v.s.len)]
    else: argError(1, "rawlen", "table ou chaîne attendue")
  g.fn "setmetatable", proc (L: Interp, a: seq[Value]): seq[Value] =
    let t = L.checkTable(a, 1, "setmetatable")
    let m = arg(a, 2)
    if m.kind notin {vkNil, vkTable}: argError(2, "setmetatable", "nil ou table attendu")
    if not t.meta.isNil and t.meta.rawGet("__metatable").kind != vkNil:
      rtError("impossible de modifier une métatable protégée")
    t.meta = if m.kind == vkNil: nil else: m.t
    @[a[0]]
  g.fn "getmetatable", proc (L: Interp, a: seq[Value]): seq[Value] =
    let m = L.getMeta(arg(a, 1))
    if m.isNil: return @[nilV]
    let prot = m.rawGet("__metatable")
    if prot.kind != vkNil: return @[prot]
    @[tableV(m)]
  g.fn "assert", proc (L: Interp, a: seq[Value]): seq[Value] =
    if a.len == 0 or not truthy(a[0]):
      if a.len >= 2: raiseValue(a[1])
      rtError("échec de l'assertion !")
    a
  g.fn "error", proc (L: Interp, a: seq[Value]): seq[Value] =
    var v = arg(a, 1)
    let level = L.optInt(a, 2, "error", 1)
    if v.kind == vkStr and level > 0: v = strV(where() & v.s)
    raiseValue(v)
  g.fn "pcall", proc (L: Interp, a: seq[Value]): seq[Value] =
    let f = L.checkAny(a, 1, "pcall")
    L.protectedCall(f, (if a.len > 1: a[1 .. ^1] else: @[]), nilV)
  g.fn "xpcall", proc (L: Interp, a: seq[Value]): seq[Value] =
    let f = L.checkAny(a, 1, "xpcall")
    L.protectedCall(f, (if a.len > 2: a[2 .. ^1] else: @[]), arg(a, 2))
  g.fn "load", proc (L: Interp, a: seq[Value]): seq[Value] =
    let c = arg(a, 1)
    let name = L.optStr(a, 2, "load", "=(load)")
    if c.kind == vkStr: return L.loadChunk(c.s, name)
    if c.kind == vkFunc:
      var src = ""
      while true:
        let piece = first(L.call(c, @[]))
        if piece.kind != vkStr or piece.s.len == 0: break
        src.add piece.s
      return L.loadChunk(src, name)
    argError(1, "load", "chaîne ou fonction attendue")
  g.fn "dofile", proc (L: Interp, a: seq[Value]): seq[Value] =
    let path = L.checkStr(a, 1, "dofile")
    try:
      L.runFile(path)
    except SyntaxError as e:
      rtError(e.msg)
    except IOError, OSError:
      rtError("impossible de lire « " & path & " »")
  g.fn "require", proc (L: Interp, a: seq[Value]): seq[Value] =
    let name = L.checkStr(a, 1, "require")
    let cached = L.loaded.rawGet(name)
    if cached.kind != vkNil: return @[cached]
    let p = L.openPackage(name)
    if p.kind != vkNil: return @[p]
    let path = L.findModule(name)
    if path.len == 0:
      rtError("module « " & name & " » introuvable (ni paquet, ni fichier " & name & ".lua)")
    var r: Value
    try:
      r = first(L.runFile(path, @[strV(name), strV(path)]))
    except SyntaxError as e:
      rtError(e.msg)
    if r.kind == vkNil: r = boolV(true)
    L.loaded.rawSet(name, r)
    @[r, strV(path)]
  g.fn "collectgarbage", proc (L: Interp, a: seq[Value]): seq[Value] =
    let opt = L.optStr(a, 1, "collectgarbage", "collect")
    if opt == "count": @[numV(float(getOccupiedMem()) / 1024.0)] else: @[intV(0)]
  g.fn "unpack", proc (L: Interp, a: seq[Value]): seq[Value] =
    let t = L.checkTable(a, 1, "unpack")
    let i = L.optInt(a, 2, "unpack", 1)
    let j = L.optInt(a, 3, "unpack", int64(t.rawLen))
    if j - i >= 1_000_000: rtError("trop de résultats à dépaqueter")
    var k = i
    while k <= j:
      result.add t.rawGet(intV(k))
      inc k

  # --- fonctions décrites par le manuel (§10.5, §10.6) ---
  g.fn "add", proc (L: Interp, a: seq[Value]): seq[Value] =
    let t = L.checkTable(a, 1, "add")
    let v = arg(a, 2)
    let n = t.rawLen
    if arg(a, 3).kind == vkNil:
      t.rawSet(intV(n + 1), v)
    else:
      let idx = int(L.checkInt(a, 3, "add"))
      if idx < 1 or idx > n + 1: argError(3, "add", "index hors limites")
      var k = n
      while k >= idx:
        t.rawSet(intV(k + 1), t.rawGet(intV(k)))
        dec k
      t.rawSet(intV(idx), v)
    @[v]
  g.fn "del", proc (L: Interp, a: seq[Value]): seq[Value] =
    let t = L.checkTable(a, 1, "del")
    let v = arg(a, 2)
    let n = t.rawLen
    for i in 1 .. n:
      if L.luaEquals(t.rawGet(intV(i)), v):
        let removed = t.rawGet(intV(i))
        for k in i ..< n: t.rawSet(intV(k), t.rawGet(intV(k + 1)))
        t.rawSet(intV(n), nilV)
        return @[removed]
    @[]
  g.fn "deli", proc (L: Interp, a: seq[Value]): seq[Value] =
    let t = L.checkTable(a, 1, "deli")
    let n = t.rawLen
    let i = int(L.optInt(a, 2, "deli", n))
    if i < 1 or i > n: return @[]
    let removed = t.rawGet(intV(i))
    for k in i ..< n: t.rawSet(intV(k), t.rawGet(intV(k + 1)))
    t.rawSet(intV(n), nilV)
    @[removed]
  g.fn "count", proc (L: Interp, a: seq[Value]): seq[Value] =
    let t = L.checkTable(a, 1, "count")
    if a.len < 2: return @[intV(t.rawLen)]
    var c = 0
    for i in 1 .. t.rawLen:
      if L.luaEquals(t.rawGet(intV(i)), a[1]): inc c
    @[intV(c)]
  g.fn "all", proc (L: Interp, a: seq[Value]): seq[Value] =
    let t = L.checkTable(a, 1, "all")
    var i = 0
    @[fnV("all_iter", proc (L: Interp, x: seq[Value]): seq[Value] =
      while i < t.rawLen:
        inc i
        let v = t.rawGet(intV(i))
        if v.kind != vkNil: return @[v]
      @[nilV])]
  g.fn "foreach", proc (L: Interp, a: seq[Value]): seq[Value] =
    let t = L.checkTable(a, 1, "foreach")
    let f = L.checkAny(a, 2, "foreach")
    var items: seq[Value]
    for i in 1 .. t.rawLen: items.add t.rawGet(intV(i))
    for v in items:
      if v.kind != vkNil: discard L.call(f, @[v])
  g.fn "split", proc (L: Interp, a: seq[Value]): seq[Value] =
    let s = L.checkStr(a, 1, "split")
    let sepV = arg(a, 2)
    let conv = optBool(a, 3, true)
    var parts: seq[string]
    if sepV.kind in {vkInt, vkNum}:
      let n = max(1, int(L.checkInt(a, 2, "split")))
      var i = 0
      while i < s.len:
        parts.add s[i ..< min(s.len, i + n)]
        i += n
    else:
      let sep = if sepV.kind == vkNil: "," else: L.checkStr(a, 2, "split")
      if sep.len == 0:
        for c in s: parts.add $c
      else: parts = s.split(sep)
    let t = newLTable(parts.len)
    for p in parts:
      if conv:
        let (ok, n) = str2number(p)
        t.arr.add(if ok and p.strip().len > 0: n else: strV(p))
      else: t.arr.add strV(p)
    @[tableV(t)]
  g.fn "chr", proc (L: Interp, a: seq[Value]): seq[Value] =
    var s = ""
    for i in 1 .. a.len: s.add chr(int(L.checkInt(a, i, "chr")) and 255)
    @[strV(s)]
  g.fn "ord", proc (L: Interp, a: seq[Value]): seq[Value] =
    let s = L.checkStr(a, 1, "ord")
    let i = int(L.optInt(a, 2, "ord", 1))
    let n = int(L.optInt(a, 3, "ord", 1))
    for k in 0 ..< n:
      let p = i - 1 + k
      if p < 0 or p >= s.len: result.add nilV
      else: result.add intV(ord(s[p]))
  g.fn "flr", proc (L: Interp, a: seq[Value]): seq[Value] =
    let v = arg(a, 1)
    if v.kind == vkInt: return @[v]
    let f = floor(L.optNum(a, 1, "flr", 0))
    if f >= -9.2e18 and f <= 9.2e18: @[intV(int64(f))] else: @[numV(f)]
  g.fn "ceil", proc (L: Interp, a: seq[Value]): seq[Value] =
    let v = arg(a, 1)
    if v.kind == vkInt: return @[v]
    let f = ceil(L.optNum(a, 1, "ceil", 0))
    if f >= -9.2e18 and f <= 9.2e18: @[intV(int64(f))] else: @[numV(f)]
  g.fn "rnd", proc (L: Interp, a: seq[Value]): seq[Value] =
    let v = arg(a, 1)
    if v.kind == vkTable:
      let n = v.t.rawLen
      if n == 0: return @[nilV]
      return @[v.t.rawGet(intV(theRng().rand(1 .. n)))]
    let x = L.optNum(a, 1, "rnd", 1.0)
    @[numV(theRng().rand(1.0) * x)]
  g.fn "srand", proc (L: Interp, a: seq[Value]): seq[Value] =
    rng = initRand(L.checkInt(a, 1, "srand"))
    rngInit = true
  g.fn "mid", proc (L: Interp, a: seq[Value]): seq[Value] =
    var xs = @[L.checkNum(a, 1, "mid"), L.checkNum(a, 2, "mid"), L.checkNum(a, 3, "mid")]
    xs.sort()
    let m = xs[1]
    for v in a:
      var ok: bool
      if toFloat(v, ok) == m and ok: return @[v]
    @[numV(m)]
  g.fn "sgn", proc (L: Interp, a: seq[Value]): seq[Value] =
    @[intV(if L.checkNum(a, 1, "sgn") < 0: -1 else: 1)]
  g.fn "tostr", proc (L: Interp, a: seq[Value]): seq[Value] =
    let v = arg(a, 1)
    if optBool(a, 2, false) and v.kind == vkInt: return @[strV("0x" & toHex(v.i, 8).toLowerAscii)]
    @[strV(if v.kind == vkNil: "" else: L.tostr(v))]
  g.fn "tonum", proc (L: Interp, a: seq[Value]): seq[Value] =
    let v = arg(a, 1)
    if v.isNumber: return @[v]
    if v.kind == vkStr:
      let (ok, n) = str2number(v.s)
      if ok: return @[n]
    @[]
  let timeFn = proc (L: Interp, a: seq[Value]): seq[Value] = @[numV(L.elapsed())]
  g.fn "time", timeFn
  g.fn "t", timeFn
  nilV

#
# string
#

proc posrelat(pos: int64, len: int): int64 =
  if pos >= 0: pos
  elif -pos > len: 0
  else: len + pos + 1

proc strSub(L: Interp, a: seq[Value], fname: string): seq[Value] =
  let s = L.checkStr(a, 1, fname)
  var i = posrelat(L.optInt(a, 2, fname, 1), s.len)
  var j = posrelat(L.optInt(a, 3, fname, -1), s.len)
  if i < 1: i = 1
  if j > s.len: j = s.len
  if i > j: @[strV("")] else: @[strV(s[int(i - 1) .. int(j - 1)])]

proc capToValue(c: Capture): Value =
  if c.isPos: intV(c.pos) else: strV(c.str)

proc strFind(L: Interp, a: seq[Value], find: bool): seq[Value] =
  let fname = if find: "find" else: "match"
  let s = L.checkStr(a, 1, fname)
  let pat = L.checkStr(a, 2, fname)
  var init = posrelat(L.optInt(a, 3, fname, 1), s.len)
  if init < 1: init = 1
  if init > s.len + 1: return @[nilV]
  if find and (optBool(a, 4, false) or not hasSpecials(pat)):
    let idx = s.find(pat, int(init - 1))
    if idx < 0: return @[nilV]
    return @[intV(idx + 1), intV(idx + pat.len)]
  var ms = initMatch(s, pat)
  let anchor = pat.len > 0 and pat[0] == '^'
  let p0 = if anchor: 1 else: 0
  var s1 = int(init - 1)
  try:
    while true:
      let e = ms.matchAt(s1, p0)
      if e != -1:
        if find:
          result = @[intV(s1 + 1), intV(e)]
          for c in ms.captures(s1, e, false): result.add capToValue(c)
        else:
          for c in ms.captures(s1, e, true): result.add capToValue(c)
        return
      inc s1
      if anchor or s1 > s.len: break
  except PatternError as e:
    rtError(e.msg)
  @[nilV]

proc gsubImpl(L: Interp, a: seq[Value]): seq[Value] =
  let s = L.checkStr(a, 1, "gsub")
  let pat = L.checkStr(a, 2, "gsub")
  let repl = arg(a, 3)
  if repl.kind notin {vkStr, vkInt, vkNum, vkTable, vkFunc}:
    argError(3, "gsub", "chaîne, table ou fonction attendue")
  let maxN = L.optInt(a, 4, "gsub", int64(s.len + 1))
  let anchor = pat.len > 0 and pat[0] == '^'
  let p0 = if anchor: 1 else: 0
  var ms = initMatch(s, pat)
  var src = 0
  var lastMatch = -1
  var n = 0
  var outp = ""
  try:
    while n < maxN:
      let e = ms.matchAt(src, p0)
      if e != -1 and e != lastMatch:
        inc n
        let whole = s[src ..< e]
        var rv: Value
        case repl.kind
        of vkStr, vkInt, vkNum:
          let r = rawToString(repl)
          var res = ""
          var i = 0
          while i < r.len:
            if r[i] == '%' and i + 1 < r.len:
              inc i
              let d = r[i]
              if d == '0': res.add whole
              elif d in Digits:
                let c = ms.getCapture(ord(d) - ord('1'), src, e)
                res.add(if c.isPos: $c.pos else: c.str)
              elif d == '%': res.add '%'
              else: rtError("utilisation invalide de '%' dans la chaîne de remplacement")
            else: res.add r[i]
            inc i
          rv = strV(res)
        of vkTable:
          rv = L.index(repl, capToValue(ms.getCapture(0, src, e)))
        else:
          var caps: seq[Value]
          for c in ms.captures(src, e, true): caps.add capToValue(c)
          rv = first(L.call(repl, caps))
        if not truthy(rv): outp.add whole
        elif rv.kind in {vkStr, vkInt, vkNum}: outp.add rawToString(rv)
        else: rtError("valeur de remplacement invalide (" & typeName(rv) & ")")
        src = e
        lastMatch = e
      elif src < s.len:
        outp.add s[src]
        inc src
      else: break
      if anchor: break
  except PatternError as ex:
    rtError(ex.msg)
  if src < s.len: outp.add s[src .. ^1]
  @[strV(outp), intV(n)]

proc formatImpl(L: Interp, a: seq[Value]): seq[Value] =
  let fmt = L.checkStr(a, 1, "format")
  var outp = ""
  var argi = 1
  var i = 0
  var buf: array[512, char]
  while i < fmt.len:
    let c = fmt[i]
    if c != '%':
      outp.add c
      inc i
      continue
    inc i
    if i < fmt.len and fmt[i] == '%':
      outp.add '%'
      inc i
      continue
    var spec = "%"
    while i < fmt.len and fmt[i] in {'-', '+', ' ', '#', '0'}:
      spec.add fmt[i]
      inc i
    while i < fmt.len and fmt[i] in Digits:
      spec.add fmt[i]
      inc i
    if i < fmt.len and fmt[i] == '.':
      spec.add '.'
      inc i
      while i < fmt.len and fmt[i] in Digits:
        spec.add fmt[i]
        inc i
    if i >= fmt.len: rtError("format invalide (se termine par '%')")
    let conv = fmt[i]
    inc i
    inc argi
    if argi > a.len and conv != '%': argError(argi, "format", "valeur attendue")
    let bufp = cast[cstring](addr buf[0])
    case conv
    of 'd', 'i':
      let n = L.checkInt(a, argi, "format")
      discard c_snprintf(bufp, 512, cstring(spec & "lld"), clonglong(n))
      outp.add $bufp
    of 'x', 'X', 'o':
      let n = L.checkInt(a, argi, "format")
      discard c_snprintf(bufp, 512, cstring(spec & "ll" & conv), clonglong(n))
      outp.add $bufp
    of 'c':
      outp.add chr(int(L.checkInt(a, argi, "format")) and 255)
    of 'a', 'A', 'e', 'E', 'f', 'F', 'g', 'G':
      let f = L.checkNum(a, argi, "format")
      discard c_snprintf(bufp, 512, cstring(spec & conv), cdouble(f))
      outp.add $bufp
    of 's':
      let s = L.tostr(a[argi - 1])
      if spec == "%": outp.add s
      else:
        discard c_snprintf(bufp, 512, cstring(spec & "s"), cstring(s))
        outp.add $bufp
    of 'q':
      let v = a[argi - 1]
      case v.kind
      of vkStr:
        var q = "\""
        for ch in v.s:
          case ch
          of '"': q.add "\\\""
          of '\\': q.add "\\\\"
          of '\n': q.add "\\n"
          of '\r': q.add "\\r"
          of '\0': q.add "\\0"
          else:
            if ord(ch) < 32 or ord(ch) == 127: q.add "\\" & $ord(ch)
            else: q.add ch
        q.add '"'
        outp.add q
      of vkInt: outp.add $v.i
      of vkNum:
        if v.n == floor(v.n) and abs(v.n) < 1e15: outp.add $int64(v.n) & ".0"
        else: outp.add fmtNumber(v.n)
      of vkNil, vkBool: outp.add rawToString(v)
      else: argError(argi, "format", "valeur sans forme littérale")
    else:
      rtError("conversion invalide '%" & $conv & "' dans le format")
  @[strV(outp)]

proc openString(L: Interp): Value =
  let m = newLib()
  m.fn "len", proc (L: Interp, a: seq[Value]): seq[Value] = @[intV(L.checkStr(a, 1, "len").len)]
  m.fn "sub", proc (L: Interp, a: seq[Value]): seq[Value] = L.strSub(a, "sub")
  m.fn "upper", proc (L: Interp, a: seq[Value]): seq[Value] = @[strV(L.checkStr(a, 1, "upper").toUpperAscii)]
  m.fn "lower", proc (L: Interp, a: seq[Value]): seq[Value] = @[strV(L.checkStr(a, 1, "lower").toLowerAscii)]
  m.fn "rep", proc (L: Interp, a: seq[Value]): seq[Value] =
    let s = L.checkStr(a, 1, "rep")
    let n = L.checkInt(a, 2, "rep")
    let sep = L.optStr(a, 3, "rep", "")
    if n <= 0: return @[strV("")]
    if (s.len + sep.len) * n > 100_000_000: rtError("chaîne résultante trop grande")
    var parts = newSeq[string](int(n))
    for i in 0 ..< int(n): parts[i] = s
    @[strV(parts.join(sep))]
  m.fn "reverse", proc (L: Interp, a: seq[Value]): seq[Value] =
    var s = L.checkStr(a, 1, "reverse")
    var r = newString(s.len)
    for i in 0 ..< s.len: r[i] = s[s.high - i]
    @[strV(r)]
  m.fn "byte", proc (L: Interp, a: seq[Value]): seq[Value] =
    let s = L.checkStr(a, 1, "byte")
    let i = posrelat(L.optInt(a, 2, "byte", 1), s.len)
    let j = posrelat(L.optInt(a, 3, "byte", i), s.len)
    var k = max(i, 1)
    while k <= min(j, int64(s.len)):
      result.add intV(ord(s[int(k - 1)]))
      inc k
  m.fn "char", proc (L: Interp, a: seq[Value]): seq[Value] =
    var s = ""
    for i in 1 .. a.len:
      let c = L.checkInt(a, i, "char")
      if c < 0 or c > 255: argError(i, "char", "valeur hors limites")
      s.add chr(int(c))
    @[strV(s)]
  m.fn "format", formatImpl
  m.fn "find", proc (L: Interp, a: seq[Value]): seq[Value] = L.strFind(a, true)
  m.fn "match", proc (L: Interp, a: seq[Value]): seq[Value] = L.strFind(a, false)
  m.fn "gsub", gsubImpl
  m.fn "gmatch", proc (L: Interp, a: seq[Value]): seq[Value] =
    let s = L.checkStr(a, 1, "gmatch")
    let pat = L.checkStr(a, 2, "gmatch")
    var src = 0
    var lastMatch = -1
    @[fnV("gmatch_iter", proc (L: Interp, x: seq[Value]): seq[Value] =
      var ms = initMatch(s, pat)
      try:
        while src <= s.len:
          let e = ms.matchAt(src, 0)
          if e != -1 and e != lastMatch:
            let start = src
            src = e
            lastMatch = e
            for c in ms.captures(start, e, true): result.add capToValue(c)
            return
          inc src
      except PatternError as ex:
        rtError(ex.msg)
      @[nilV])]
  L.stringMeta.rawSet("__index", tableV(m))
  tableV(m)

#
# table
#

proc openTable(L: Interp): Value =
  let m = newLib()
  m.fn "insert", proc (L: Interp, a: seq[Value]): seq[Value] =
    let t = L.checkTable(a, 1, "insert")
    let n = t.rawLen
    if a.len == 2:
      t.rawSet(intV(n + 1), a[1])
    elif a.len == 3:
      let pos = int(L.checkInt(a, 2, "insert"))
      if pos < 1 or pos > n + 1: argError(2, "insert", "position hors limites")
      var k = n
      while k >= pos:
        t.rawSet(intV(k + 1), t.rawGet(intV(k)))
        dec k
      t.rawSet(intV(pos), a[2])
    else: rtError("nombre d'arguments incorrect pour 'insert'")
  m.fn "remove", proc (L: Interp, a: seq[Value]): seq[Value] =
    let t = L.checkTable(a, 1, "remove")
    let n = t.rawLen
    let pos = int(L.optInt(a, 2, "remove", n))
    if n == 0 and arg(a, 2).kind == vkNil: return @[nilV]
    if n + 1 == pos:
      let v = t.rawGet(intV(pos))
      t.rawSet(intV(pos), nilV)
      return @[v]
    if pos < 1 or pos > n + 1: argError(2, "remove", "position hors limites")
    let v = t.rawGet(intV(pos))
    for k in pos ..< n: t.rawSet(intV(k), t.rawGet(intV(k + 1)))
    t.rawSet(intV(n), nilV)
    @[v]
  m.fn "concat", proc (L: Interp, a: seq[Value]): seq[Value] =
    let t = L.checkTable(a, 1, "concat")
    let sep = L.optStr(a, 2, "concat", "")
    let i = L.optInt(a, 3, "concat", 1)
    let j = L.optInt(a, 4, "concat", int64(t.rawLen))
    var parts: seq[string]
    var k = i
    while k <= j:
      let v = t.rawGet(intV(k))
      if v.kind notin {vkStr, vkInt, vkNum}:
        rtError("valeur invalide (à l'index " & $k & ") dans la table pour 'concat'")
      parts.add rawToString(v)
      inc k
    @[strV(parts.join(sep))]
  m.fn "sort", proc (L: Interp, a: seq[Value]): seq[Value] =
    let t = L.checkTable(a, 1, "sort")
    let cmpF = arg(a, 2)
    let n = t.rawLen
    var items = newSeq[Value](n)
    for i in 0 ..< n: items[i] = t.rawGet(intV(i + 1))
    let less = proc (x, y: Value): bool =
      if cmpF.kind != vkNil: truthy(first(L.call(cmpF, @[x, y])))
      else: L.lessThan(x, y, false)
    items.sort(proc (x, y: Value): int =
      if less(x, y): -1 elif less(y, x): 1 else: 0)
    for i in 0 ..< n: t.rawSet(intV(i + 1), items[i])
  m.fn "unpack", L.globals.rawGet("unpack").f.nfn
  m.fn "pack", proc (L: Interp, a: seq[Value]): seq[Value] =
    let t = tableFrom(a)
    for i, v in a: t.rawSet(intV(i + 1), v)
    t.rawSet("n", intV(a.len))
    @[tableV(t)]
  m.fn "move", proc (L: Interp, a: seq[Value]): seq[Value] =
    let a1 = L.checkTable(a, 1, "move")
    let f = L.checkInt(a, 2, "move")
    let e = L.checkInt(a, 3, "move")
    let t = L.checkInt(a, 4, "move")
    let a2 = if arg(a, 5).kind == vkTable: a[4].t else: a1
    if e >= f:
      if t > f or t > e or a1 != a2:
        for i in 0'i64 .. e - f: a2.rawSet(intV(t + i), a1.rawGet(intV(f + i)))
      else:
        var i = e - f
        while i >= 0:
          a2.rawSet(intV(t + i), a1.rawGet(intV(f + i)))
          dec i
    @[tableV(a2)]
  tableV(m)

#
# math
#

proc openMath(L: Interp): Value =
  let m = newLib()
  m.set "pi", numV(PI)
  m.set "huge", numV(Inf)
  m.set "maxinteger", intV(high(int64))
  m.set "mininteger", intV(low(int64))
  template f1(name: string, op: untyped) =
    m.fn name, proc (L: Interp, a: seq[Value]): seq[Value] =
      let x {.inject.} = L.checkNum(a, 1, name)
      @[numV(op)]
  f1("sqrt", sqrt(x))
  f1("sin", sin(x))
  f1("cos", cos(x))
  f1("tan", tan(x))
  f1("asin", arcsin(x))
  f1("acos", arccos(x))
  f1("exp", exp(x))
  m.fn "atan", proc (L: Interp, a: seq[Value]): seq[Value] =
    @[numV(arctan2(L.checkNum(a, 1, "atan"), L.optNum(a, 2, "atan", 1.0)))]
  m.fn "log", proc (L: Interp, a: seq[Value]): seq[Value] =
    let x = L.checkNum(a, 1, "log")
    if arg(a, 2).kind == vkNil: return @[numV(ln(x))]
    let b = L.checkNum(a, 2, "log")
    @[numV(if b == 2.0: log2(x) elif b == 10.0: log10(x) else: ln(x) / ln(b))]
  m.fn "floor", proc (L: Interp, a: seq[Value]): seq[Value] =
    let v = arg(a, 1)
    if v.kind == vkInt: return @[v]
    let f = floor(L.checkNum(a, 1, "floor"))
    if f >= -9.2e18 and f <= 9.2e18: @[intV(int64(f))] else: @[numV(f)]
  m.fn "ceil", proc (L: Interp, a: seq[Value]): seq[Value] =
    let v = arg(a, 1)
    if v.kind == vkInt: return @[v]
    let f = ceil(L.checkNum(a, 1, "ceil"))
    if f >= -9.2e18 and f <= 9.2e18: @[intV(int64(f))] else: @[numV(f)]
  m.fn "abs", proc (L: Interp, a: seq[Value]): seq[Value] =
    let v = arg(a, 1)
    if v.kind == vkInt: return @[intV(if v.i < 0: cast[int64](0'u64 - cast[uint64](v.i)) else: v.i)]
    @[numV(abs(L.checkNum(a, 1, "abs")))]
  m.fn "fmod", proc (L: Interp, a: seq[Value]): seq[Value] =
    let x = arg(a, 1)
    let y = arg(a, 2)
    if x.kind == vkInt and y.kind == vkInt:
      if y.i == 0: argError(2, "fmod", "zéro")
      return @[intV(if y.i == -1: 0'i64 else: x.i mod y.i)]
    @[numV(L.checkNum(a, 1, "fmod") mod L.checkNum(a, 2, "fmod"))]
  m.fn "modf", proc (L: Interp, a: seq[Value]): seq[Value] =
    let x = L.checkNum(a, 1, "modf")
    let ip = if x >= 0: floor(x) else: ceil(x)
    let ipv = if ip >= -9.2e18 and ip <= 9.2e18: numV(ip) else: numV(ip)
    @[ipv, numV(if x == Inf or x == NegInf: 0.0 else: x - ip)]
  m.fn "tointeger", proc (L: Interp, a: seq[Value]): seq[Value] =
    let v = arg(a, 1)
    var ok: bool
    let n = toInteger(v, ok)
    if ok and v.kind != vkStr: @[intV(n)] else: @[nilV]
  m.fn "type", proc (L: Interp, a: seq[Value]): seq[Value] =
    let v = L.checkAny(a, 1, "type")
    case v.kind
    of vkInt: @[strV("integer")]
    of vkNum: @[strV("float")]
    else: @[nilV]
  m.fn "ult", proc (L: Interp, a: seq[Value]): seq[Value] =
    @[boolV(cast[uint64](L.checkInt(a, 1, "ult")) < cast[uint64](L.checkInt(a, 2, "ult")))]
  let minmax = proc (isMax: bool): NativeProc =
    result = proc (L: Interp, a: seq[Value]): seq[Value] =
      let name = if isMax: "max" else: "min"
      var best = arg(a, 1)
      discard L.checkNum(a, 1, name)
      for i in 2 .. a.len:
        discard L.checkNum(a, i, name)
        let better = if isMax: L.lessThan(best, a[i - 1], false) else: L.lessThan(a[i - 1], best, false)
        if better: best = a[i - 1]
      @[best]
  m.fn "max", minmax(true)
  m.fn "min", minmax(false)
  m.fn "random", proc (L: Interp, a: seq[Value]): seq[Value] =
    if a.len == 0: return @[numV(theRng().rand(1.0 - 1e-17))]
    var lo = 1'i64
    var hi: int64
    if a.len == 1: hi = L.checkInt(a, 1, "random")
    else:
      lo = L.checkInt(a, 1, "random")
      hi = L.checkInt(a, 2, "random")
    if lo > hi: argError(a.len, "random", "intervalle vide")
    @[intV(theRng().rand(lo .. hi))]
  m.fn "randomseed", proc (L: Interp, a: seq[Value]): seq[Value] =
    rng = initRand(if a.len > 0: L.checkInt(a, 1, "randomseed") else: int64(epochTime() * 1e6))
    rngInit = true
  # alias PICO-8 utilisés par le manuel
  for nm in ["sqrt", "sin", "cos", "abs", "min", "max"]:
    if L.globals.rawGet(nm).kind == vkNil: L.globals.rawSet(nm, m.rawGet(nm))
  L.globals.rawSet("atan2", fnV("atan2", proc (L: Interp, a: seq[Value]): seq[Value] =
    @[numV(arctan2(L.checkNum(a, 2, "atan2"), L.checkNum(a, 1, "atan2")))]))
  tableV(m)

#
# coroutine
#

proc checkCo(L: Interp, a: seq[Value], i: int, fname: string): Coroutine =
  let v = arg(a, i)
  if v.kind != vkUser or not (v.u of Coroutine): argError(i, fname, "coroutine attendue")
  Coroutine(v.u)

proc openCoroutine(L: Interp): Value =
  let m = newLib()
  let coMeta = newLTable()
  coMeta.rawSet("__name", strV("thread"))
  m.fn "create", proc (L: Interp, a: seq[Value]): seq[Value] =
    let co = L.newCoroutine(L.checkFunc(a, 1, "create"))
    co.meta = coMeta
    @[userV(co)]
  m.fn "resume", proc (L: Interp, a: seq[Value]): seq[Value] =
    let co = L.checkCo(a, 1, "resume")
    let (ok, vals) = L.resume(co, (if a.len > 1: a[1 .. ^1] else: @[]))
    @[boolV(ok)] & vals
  m.fn "yield", proc (L: Interp, a: seq[Value]): seq[Value] = L.yieldCo(a)
  m.fn "status", proc (L: Interp, a: seq[Value]): seq[Value] =
    let co = L.checkCo(a, 1, "status")
    @[strV($co.status)]
  m.fn "running", proc (L: Interp, a: seq[Value]): seq[Value] =
    let co = ctx().co
    if co.isNil: @[nilV, boolV(true)] else: @[userV(co), boolV(false)]
  m.fn "isyieldable", proc (L: Interp, a: seq[Value]): seq[Value] =
    @[boolV(not ctx().co.isNil)]
  m.fn "close", proc (L: Interp, a: seq[Value]): seq[Value] =
    let co = L.checkCo(a, 1, "close")
    if co.status notin {csSuspended, csDead}: rtError("impossible de fermer une coroutine active")
    closeCoroutine(co)
    @[boolV(true)]
  m.fn "wrap", proc (L: Interp, a: seq[Value]): seq[Value] =
    let co = L.newCoroutine(L.checkFunc(a, 1, "wrap"))
    co.meta = coMeta
    @[fnV("wrap", proc (L: Interp, x: seq[Value]): seq[Value] =
      let (ok, vals) = L.resume(co, x)
      if not ok:
        let e = first(vals)
        raiseValue(e)
      vals)]
  tableV(m)

#
# utf8
#

proc openUtf8(L: Interp): Value =
  let m = newLib()
  m.set "charpattern", strV("[\x00-\x7F\xC2-\xFD][\x80-\xBF]*")
  m.fn "char", proc (L: Interp, a: seq[Value]): seq[Value] =
    var s = ""
    for i in 1 .. a.len: s.add $Rune(int(L.checkInt(a, i, "char")))
    @[strV(s)]
  m.fn "len", proc (L: Interp, a: seq[Value]): seq[Value] =
    let s = L.checkStr(a, 1, "len")
    if validateUtf8(s) >= 0: return @[nilV, intV(validateUtf8(s) + 1)]
    @[intV(s.runeLen)]
  m.fn "codepoint", proc (L: Interp, a: seq[Value]): seq[Value] =
    let s = L.checkStr(a, 1, "codepoint")
    let i = int(posrelat(L.optInt(a, 2, "codepoint", 1), s.len))
    let j = int(posrelat(L.optInt(a, 3, "codepoint", i), s.len))
    var p = i - 1
    while p < j and p < s.len:
      var r: Rune
      var q = p
      fastRuneAt(s, q, r, true)
      result.add intV(int(r))
      p = q
  m.fn "offset", proc (L: Interp, a: seq[Value]): seq[Value] =
    let s = L.checkStr(a, 1, "offset")
    let n = int(L.checkInt(a, 2, "offset"))
    if n <= 0: return @[nilV]
    var p = 0
    var k = 1
    while k < n and p < s.len:
      p += s.runeLenAt(p)
      inc k
    if k == n and p <= s.len: @[intV(p + 1)] else: @[nilV]
  m.fn "codes", proc (L: Interp, a: seq[Value]): seq[Value] =
    let s = L.checkStr(a, 1, "codes")
    var p = 0
    @[fnV("codes_iter", proc (L: Interp, x: seq[Value]): seq[Value] =
      if p >= s.len: return @[nilV]
      var r: Rune
      let start = p
      fastRuneAt(s, p, r, true)
      @[intV(start + 1), intV(int(r))])]
  tableV(m)

#
# Enregistrement
#

registerPackage PackageDef(name: "base", global: true, open: openBase,
  description: "Fonctions de base de Lua et fonctions décrites par le manuel",
  docs: docs("base", [
    "print(...)", "Affiche les valeurs séparées par des tabulations, puis un saut de ligne.",
    "type(v)", "Type de v : \"nil\", \"number\", \"string\", \"boolean\", \"table\", \"function\", \"thread\", \"userdata\".",
    "tostring(v)", "Conversion en chaîne (utilise __tostring).",
    "tonumber(v, [base])", "Conversion en nombre ; nil si impossible.",
    "pairs(tbl)", "Itère sur toutes les paires clé/valeur d'une table (§10.6).",
    "ipairs(tbl)", "Itère sur t[1], t[2]... jusqu'au premier nil.",
    "next(tbl, [key])", "Paire suivante d'une table.",
    "select(n, ...)", "Arguments à partir du n-ième, ou leur nombre avec \"#\".",
    "error(message, [level])", "Lève une erreur (§10.9).",
    "assert(condition, [message])", "Lève une erreur si la condition est fausse (§10.9).",
    "pcall(f, ...)", "Appel protégé : true et les résultats, ou false et l'erreur.",
    "xpcall(f, handler, ...)", "Appel protégé avec gestionnaire d'erreur.",
    "setmetatable(tbl, mt)", "Associe une métatable.",
    "getmetatable(v)", "Renvoie la métatable.",
    "rawget(tbl, k)", "Accès sans métaméthode.",
    "rawset(tbl, k, v)", "Affectation sans métaméthode.",
    "rawequal(a, b)", "Égalité sans métaméthode.",
    "rawlen(v)", "Longueur sans métaméthode.",
    "load(chunk, [name])", "Compile du code ; renvoie une fonction, ou nil et l'erreur.",
    "dofile(path)", "Exécute un fichier Lua.",
    "require(name)", "Charge un paquet natif (io, file, json, net, sqlite, ui...) ou un fichier name.lua.",
    "unpack(tbl, [i], [j])", "Renvoie les éléments t[i]..t[j].",
    "add(tbl, val, [index])", "Ajoute val à la fin de tbl, ou à l'index donné (§10.6).",
    "del(tbl, val)", "Supprime la première occurrence de val et décale la suite (§10.6).",
    "deli(tbl, [index])", "Supprime l'élément à l'index (le dernier par défaut) et le renvoie (§10.6).",
    "count(tbl, [val])", "Longueur de tbl, ou nombre d'occurrences de val (§10.6).",
    "all(tbl)", "Itérateur sur les valeurs d'une table à index 1..n : for v in all(t) do (§10.6).",
    "foreach(tbl, func)", "Appelle func pour chaque élément de tbl (§10.6).",
    "split(str, [separator], [convert_numbers])", "Découpe une chaîne (séparateur \",\" par défaut) (§10.5).",
    "chr(val0, val1, ...)", "Convertit des codes de caractères en chaîne (§10.5).",
    "ord(str, [index], [num_results])", "Codes des caractères de str (§10.5).",
    "flr(x)", "Partie entière inférieure.",
    "ceil(x)", "Partie entière supérieure.",
    "rnd([x])", "Nombre aléatoire dans [0, x[, ou élément au hasard d'une table.",
    "srand(x)", "Initialise le générateur aléatoire.",
    "mid(x, y, z)", "Valeur médiane.",
    "sgn(x)", "Signe : -1 ou 1.",
    "tostr(val, [hex])", "Conversion en chaîne.",
    "tonum(val)", "Conversion en nombre.",
    "time()", "Secondes écoulées depuis le lancement du programme (§10.9).",
    "t()", "Alias de time()."]))

registerPackage PackageDef(name: "string", global: true, open: openString,
  description: "Chaînes et motifs Lua",
  docs: docs("string", [
    "string.len(s)", "Longueur en octets.",
    "string.sub(s, i, [j])", "Sous-chaîne de i à j (inclus) ; indices négatifs depuis la fin.",
    "string.upper(s)", "Majuscules.", "string.lower(s)", "Minuscules.",
    "string.rep(s, n, [sep])", "Répète s n fois.",
    "string.reverse(s)", "Inverse la chaîne.",
    "string.byte(s, [i], [j])", "Codes des octets.",
    "string.char(...)", "Chaîne à partir de codes.",
    "string.format(fmt, ...)", "Formatage à la printf : %d %s %f %g %x %q...",
    "string.find(s, pattern, [init], [plain])", "Position d'un motif : début, fin, captures.",
    "string.match(s, pattern, [init])", "Captures du premier motif trouvé.",
    "string.gmatch(s, pattern)", "Itérateur sur les correspondances.",
    "string.gsub(s, pattern, repl, [n])", "Remplacement (chaîne, table ou fonction) ; renvoie la chaîne et le nombre de remplacements."]))

registerPackage PackageDef(name: "table", global: true, open: openTable,
  description: "Manipulation des tables",
  docs: docs("table", [
    "table.insert(t, [pos], value)", "Insère une valeur.",
    "table.remove(t, [pos])", "Retire et renvoie un élément.",
    "table.concat(t, [sep], [i], [j])", "Concatène les éléments.",
    "table.sort(t, [comp])", "Trie sur place.",
    "table.unpack(t, [i], [j])", "Renvoie les éléments.",
    "table.pack(...)", "Table des arguments, avec le champ n.",
    "table.move(a1, f, e, t, [a2])", "Copie des éléments."]))

registerPackage PackageDef(name: "math", global: true, open: openMath,
  description: "Fonctions mathématiques",
  docs: docs("math", [
    "math.abs(x)", "Valeur absolue.", "math.ceil(x)", "Entier supérieur.", "math.floor(x)", "Entier inférieur.",
    "math.sqrt(x)", "Racine carrée.", "math.sin(x)", "Sinus (radians).", "math.cos(x)", "Cosinus (radians).",
    "math.tan(x)", "Tangente.", "math.asin(x)", "Arc sinus.", "math.acos(x)", "Arc cosinus.",
    "math.atan(y, [x])", "Arc tangente.", "math.exp(x)", "Exponentielle.", "math.log(x, [base])", "Logarithme.",
    "math.fmod(x, y)", "Reste de la division tronquée.", "math.modf(x)", "Partie entière et fractionnaire.",
    "math.max(x, ...)", "Maximum.", "math.min(x, ...)", "Minimum.",
    "math.random([m], [n])", "Nombre aléatoire.", "math.randomseed([x])", "Initialise le générateur.",
    "math.tointeger(x)", "Conversion en entier si possible.", "math.type(x)", "\"integer\", \"float\" ou nil.",
    "math.ult(m, n)", "Comparaison non signée.", "math.pi", "π.", "math.huge", "Infini.",
    "math.maxinteger", "Plus grand entier.", "math.mininteger", "Plus petit entier.",
    "atan2(dx, dy)", "Angle du vecteur (dx, dy)."]))

registerPackage PackageDef(name: "coroutine", global: true, open: openCoroutine,
  description: "Coroutines",
  docs: docs("coroutine", [
    "coroutine.create(f)", "Crée une coroutine.",
    "coroutine.resume(co, ...)", "Démarre ou reprend ; renvoie true et les valeurs, ou false et l'erreur.",
    "coroutine.yield(...)", "Suspend la coroutine courante.",
    "coroutine.status(co)", "\"suspended\", \"running\", \"normal\" ou \"dead\".",
    "coroutine.wrap(f)", "Fonction qui reprend la coroutine à chaque appel.",
    "coroutine.running()", "Coroutine courante.",
    "coroutine.isyieldable()", "Vrai dans une coroutine.",
    "coroutine.close(co)", "Termine une coroutine suspendue."]))

registerPackage PackageDef(name: "utf8", global: true, open: openUtf8,
  description: "UTF-8",
  docs: docs("utf8", [
    "utf8.char(...)", "Chaîne UTF-8 à partir de points de code.",
    "utf8.len(s)", "Nombre de caractères.",
    "utf8.codepoint(s, [i], [j])", "Points de code.",
    "utf8.offset(s, n)", "Position du n-ième caractère.",
    "utf8.codes(s)", "Itérateur (position, point de code).",
    "utf8.charpattern", "Motif d'un caractère UTF-8."]))

proc newFullInterp*(): Interp =
  # Interpréteur avec tous les paquets globaux ouverts.
  result = newInterp()
  openGlobals(result)
