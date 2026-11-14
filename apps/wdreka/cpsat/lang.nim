# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
#
# lang.nim - NCP language (wdreka version: + cumulative, disjunctive,
# reservoir, windows and interactive solving API)
#
# lexer -> parser (AST) -> compiler (evaluation + posting of the constraints
# in the solver) -> execution (satisfaction, enumeration, optimization).

import std/[tables, hashes, strutils, times]
import solver

#
# Types
#

type
  TokKind = enum tkInt, tkIdent, tkStr, tkSym, tkEof

  Token = object
    kind: TokKind
    text: string
    ival: int
    line: int

  NodeKind = enum
    nkInt, nkBool, nkStr, nkIdent, nkBin, nkUn, nkCall, nkIndex,
    nkList, nkCompr, nkAggr

  Gen = object
    name: string
    lo, hi: Node

  Node = ref object
    line: int
    case kind: NodeKind
    of nkInt:
      ival: int
    of nkBool:
      bval: bool
    of nkStr:
      sval: string
    of nkIdent:
      name: string
    of nkBin:
      op: string
      lhs, rhs: Node
    of nkUn:
      uop: string
      arg: Node
    of nkCall:
      fname: string
      args: seq[Node]
    of nkIndex:
      base: Node
      idx: seq[Node]
    of nkList:
      items: seq[Node]
    of nkCompr:
      body: Node
      gens: seq[Gen]
      cond: Node
    of nkAggr:
      aname: string
      agens: seq[Gen]
      acond: Node
      abody: Node

  StmtKind = enum
    skConst, skLet, skVar, skConstraint, skForall, skIf, skSolve,
    skOutput, skSearch, skOption

  Stmt = ref object
    sline: int
    case kind: StmtKind
    of skConst, skLet:
      cname: string
      cval: Node
    of skVar:
      vname: string
      vdims: seq[Node]
      visBool: bool
      vlo, vhi: Node
      vset: seq[Node]
    of skConstraint:
      cexpr: Node
    of skForall:
      fgens: seq[Gen]
      fcond: Node
      fbody: seq[Stmt]
    of skIf:
      ifCond: Node
      thenB, elseB: seq[Stmt]
    of skSolve:
      skind: string
      sobj: Node
    of skOutput:
      oitems: seq[Node]
    of skSearch:
      svars: Node
      svarSel, svalSel: string
    of skOption:
      oname: string
      oval: Node

  Term = tuple[a, x: int]          # a * x

  LinExpr = object                 # sum(terms) + k
    terms: seq[Term]
    k: int

  VKind = enum vkInt, vkBool, vkLin, vkLit, vkArr

  Value = object
    case kind: VKind
    of vkInt:
      i: int
    of vkBool:
      b: bool
    of vkLin:
      lin: LinExpr
    of vkLit:
      lit: int
    of vkArr:
      elems: seq[Value]
      dims: seq[int]

  OutItem = object
    isText: bool
    text: string
    val: Value

  Compiler* = ref object
    s*: Solver
    scopes: seq[Table[string, Value]]
    outputs: seq[OutItem]
    hasOutput: bool
    userVars: seq[(string, Value)]
    decisionVars: seq[int]
    solveKind: string
    objective: LinExpr
    timeout*: float
    maxSolutions*: int
    showStats*: bool
    litIntCache: Table[int, int]

const
  keywords = ["const", "let", "var", "bool", "constraint", "forall", "if",
              "else", "solve", "satisfy", "all", "minimize", "maximize",
              "output", "search", "option", "in", "where", "and", "or",
              "not", "xor", "div", "mod", "true", "false"]
  aggrNames = ["sum", "min", "max", "forall", "exists"]
  syms2 = ["->", "..", "==", "!=", "<=", ">=", "&&", "||"]
  cmpOps = ["==", "!=", "<", "<=", ">", ">="]

proc err(line: int, msg: string) {.noreturn.} =
  raise newException(CpError, "line " & $line & ": " & msg)

#
# Lexical analysis
#

proc lex(src: string): seq[Token] =
  var i = 0
  var line = 1
  while i < src.len:
    let ch = src[i]
    if ch == '\n':
      inc line
      inc i
    elif ch in {' ', '\t', '\r'}:
      inc i
    elif ch == '#' or (ch == '/' and i + 1 < src.len and src[i + 1] == '/'):
      while i < src.len and src[i] != '\n':
        inc i
    elif ch == '/' and i + 1 < src.len and src[i + 1] == '*':
      let startLine = line
      i += 2
      while i + 1 < src.len and not (src[i] == '*' and src[i + 1] == '/'):
        if src[i] == '\n':
          inc line
        inc i
      if i + 1 >= src.len:
        err(startLine, "unterminated /* comment")
      i += 2
    elif ch in Digits:
      var j = i
      while j < src.len and src[j] in Digits:
        inc j
      let txt = src[i ..< j]
      var v = 0
      try:
        v = parseInt(txt)
      except ValueError:
        err(line, "integer too large: " & txt)
      result.add Token(kind: tkInt, text: txt, ival: v, line: line)
      i = j
    elif ch in IdentStartChars:
      var j = i
      while j < src.len and src[j] in IdentChars:
        inc j
      result.add Token(kind: tkIdent, text: src[i ..< j], line: line)
      i = j
    elif ch == '"':
      let startLine = line
      var j = i + 1
      var s = ""
      while j < src.len and src[j] != '"':
        if src[j] == '\\' and j + 1 < src.len:
          inc j
          case src[j]
          of 'n': s.add '\n'
          of 't': s.add '\t'
          of '\\': s.add '\\'
          of '"': s.add '"'
          else: s.add src[j]
        else:
          if src[j] == '\n':
            inc line
          s.add src[j]
        inc j
      if j >= src.len:
        err(startLine, "unterminated string")
      result.add Token(kind: tkStr, text: s, line: startLine)
      i = j + 1
    else:
      var matched = ""
      if i + 3 <= src.len and src[i ..< i + 3] == "<->":
        matched = "<->"
      elif i + 2 <= src.len and src[i ..< i + 2] in syms2:
        matched = src[i ..< i + 2]
      elif ch in "()[]{},;:+-*/%<>=!|":
        matched = $ch
      else:
        err(line, "unexpected character '" & $ch & "'")
      result.add Token(kind: tkSym, text: matched, line: line)
      i += matched.len
  result.add Token(kind: tkEof, text: "end of file", line: line)

#
# Parsing
#

type Parser = object
  toks: seq[Token]
  pos: int

proc peek(p: Parser, k = 0): Token =
  result = p.toks[min(p.pos + k, p.toks.len - 1)]

proc adv(p: var Parser): Token =
  result = p.toks[p.pos]
  if p.pos < p.toks.len - 1:
    inc p.pos

proc isSym(p: Parser, s: string): bool =
  let t = p.peek()
  result = t.kind == tkSym and t.text == s

proc isKw(p: Parser, s: string): bool =
  let t = p.peek()
  result = t.kind == tkIdent and t.text == s

proc accept(p: var Parser, s: string): bool =
  result = false
  if p.isSym(s) or p.isKw(s):
    discard p.adv()
    result = true

proc expect(p: var Parser, s: string) =
  if not p.accept(s):
    let t = p.peek()
    err(t.line, "'" & s & "' expected, found '" & t.text & "'")

proc expectIdent(p: var Parser): string =
  let t = p.peek()
  if t.kind != tkIdent or t.text in keywords:
    err(t.line, "identifier expected, found '" & t.text & "'")
  discard p.adv()
  result = t.text

proc mkBin(op: string, a, b: Node, line: int): Node =
  result = Node(kind: nkBin, op: op, lhs: a, rhs: b, line: line)

proc parseExpr(p: var Parser): Node
proc parseAdd(p: var Parser): Node
proc parseStmt(p: var Parser): Stmt

proc parseGens(p: var Parser): (seq[Gen], Node) =
  # i in a..b, j in c..d where cond
  var gens: seq[Gen] = @[]
  while true:
    let name = p.expectIdent()
    p.expect("in")
    let lo = p.parseAdd()
    p.expect("..")
    let hi = p.parseAdd()
    gens.add Gen(name: name, lo: lo, hi: hi)
    if p.isSym(",") and p.peek(1).kind == tkIdent and
       p.peek(2).kind == tkIdent and p.peek(2).text == "in":
      discard p.adv()
    else:
      break
  var cond: Node = nil
  if p.accept("where"):
    cond = p.parseExpr()
  result = (gens, cond)

proc parsePrimary(p: var Parser): Node =
  let t = p.peek()
  case t.kind
  of tkInt:
    discard p.adv()
    result = Node(kind: nkInt, ival: t.ival, line: t.line)
  of tkStr:
    discard p.adv()
    result = Node(kind: nkStr, sval: t.text, line: t.line)
  of tkIdent:
    if t.text == "true" or t.text == "false":
      discard p.adv()
      result = Node(kind: nkBool, bval: t.text == "true", line: t.line)
    elif t.text in aggrNames and p.peek(1).kind == tkSym and
         p.peek(1).text == "(" and p.peek(2).kind == tkIdent and
         p.peek(3).kind == tkIdent and p.peek(3).text == "in":
      # aggregate: sum(i in a..b where c)(expr)
      discard p.adv()
      discard p.adv()
      let (gens, cond) = p.parseGens()
      p.expect(")")
      p.expect("(")
      let body = p.parseExpr()
      p.expect(")")
      result = Node(kind: nkAggr, aname: t.text, agens: gens, acond: cond,
                    abody: body, line: t.line)
    else:
      let name = p.expectIdent()
      if p.isSym("("):
        discard p.adv()
        var args: seq[Node] = @[]
        if not p.isSym(")"):
          args.add p.parseExpr()
          while p.accept(","):
            args.add p.parseExpr()
        p.expect(")")
        result = Node(kind: nkCall, fname: name, args: args, line: t.line)
      else:
        result = Node(kind: nkIdent, name: name, line: t.line)
  of tkSym:
    if t.text == "(":
      discard p.adv()
      result = p.parseExpr()
      p.expect(")")
    elif t.text == "[":
      discard p.adv()
      if p.accept("]"):
        return Node(kind: nkList, items: @[], line: t.line)
      let first = p.parseExpr()
      if p.accept("|"):
        let (gens, cond) = p.parseGens()
        p.expect("]")
        result = Node(kind: nkCompr, body: first, gens: gens, cond: cond,
                      line: t.line)
      else:
        var items = @[first]
        while p.accept(","):
          items.add p.parseExpr()
        p.expect("]")
        result = Node(kind: nkList, items: items, line: t.line)
    else:
      err(t.line, "expression expected, found '" & t.text & "'")
  of tkEof:
    err(t.line, "unexpected end of file")

proc parsePostfix(p: var Parser): Node =
  result = p.parsePrimary()
  while p.isSym("["):
    let line = p.peek().line
    discard p.adv()
    var idx = @[p.parseExpr()]
    while p.accept(","):
      idx.add p.parseExpr()
    p.expect("]")
    result = Node(kind: nkIndex, base: result, idx: idx, line: line)

proc parseUnary(p: var Parser): Node =
  let t = p.peek()
  if p.isSym("-"):
    discard p.adv()
    let a = p.parseUnary()
    result = Node(kind: nkUn, uop: "neg", arg: a, line: t.line)
  elif p.isSym("+"):
    discard p.adv()
    result = p.parseUnary()
  else:
    result = p.parsePostfix()

proc parseMul(p: var Parser): Node =
  result = p.parseUnary()
  while true:
    let t = p.peek()
    var op = ""
    if p.isSym("*"):
      op = "*"
    elif p.isSym("/") or p.isKw("div"):
      op = "div"
    elif p.isSym("%") or p.isKw("mod"):
      op = "mod"
    else:
      break
    discard p.adv()
    let r = p.parseUnary()
    result = mkBin(op, result, r, t.line)

proc parseAdd(p: var Parser): Node =
  result = p.parseMul()
  while p.isSym("+") or p.isSym("-"):
    let t = p.adv()
    let r = p.parseMul()
    result = mkBin(t.text, result, r, t.line)

proc parseCmp(p: var Parser): Node =
  result = p.parseAdd()
  let t = p.peek()
  if t.kind == tkSym and (t.text in cmpOps or t.text == "="):
    discard p.adv()
    let op = (if t.text == "=": "==" else: t.text)
    let r = p.parseAdd()
    result = mkBin(op, result, r, t.line)

proc parseNot(p: var Parser): Node =
  let t = p.peek()
  if p.isSym("!") or p.isKw("not"):
    discard p.adv()
    let a = p.parseNot()
    result = Node(kind: nkUn, uop: "not", arg: a, line: t.line)
  else:
    result = p.parseCmp()

proc parseAnd(p: var Parser): Node =
  result = p.parseNot()
  while p.isKw("and") or p.isSym("&&"):
    let t = p.adv()
    let r = p.parseNot()
    result = mkBin("and", result, r, t.line)

proc parseOr(p: var Parser): Node =
  result = p.parseAnd()
  while p.isKw("or") or p.isSym("||") or p.isKw("xor"):
    let t = p.adv()
    let op = (if t.text == "xor": "xor" else: "or")
    let r = p.parseAnd()
    result = mkBin(op, result, r, t.line)

proc parseImpl(p: var Parser): Node =
  result = p.parseOr()
  if p.isSym("->"):
    let t = p.adv()
    let r = p.parseImpl()          # right-associative
    result = mkBin("->", result, r, t.line)

proc parseExpr(p: var Parser): Node =
  result = p.parseImpl()
  while p.isSym("<->"):
    let t = p.adv()
    let r = p.parseImpl()
    result = mkBin("<->", result, r, t.line)

proc parseBlock(p: var Parser): seq[Stmt] =
  p.expect("{")
  result = @[]
  while not p.isSym("}"):
    if p.peek().kind == tkEof:
      err(p.peek().line, "missing '}'")
    result.add p.parseStmt()
  p.expect("}")

proc parseStmt(p: var Parser): Stmt =
  let t = p.peek()
  if t.kind != tkIdent:
    err(t.line, "statement expected, found '" & t.text & "'")
  case t.text
  of "const", "let":
    discard p.adv()
    let name = p.expectIdent()
    p.expect("=")
    let v = p.parseExpr()
    p.expect(";")
    if t.text == "const":
      result = Stmt(kind: skConst, cname: name, cval: v, sline: t.line)
    else:
      result = Stmt(kind: skLet, cname: name, cval: v, sline: t.line)
  of "var":
    discard p.adv()
    let name = p.expectIdent()
    var dims: seq[Node] = @[]
    if p.accept("["):
      dims.add p.parseExpr()
      while p.accept(","):
        dims.add p.parseExpr()
      p.expect("]")
    p.expect(":")
    let st = Stmt(kind: skVar, vname: name, vdims: dims, sline: t.line)
    if p.accept("bool"):
      st.visBool = true
    elif p.accept("{"):
      st.vset.add p.parseExpr()
      while p.accept(","):
        st.vset.add p.parseExpr()
      p.expect("}")
    else:
      st.vlo = p.parseAdd()
      p.expect("..")
      st.vhi = p.parseAdd()
    p.expect(";")
    result = st
  of "constraint":
    discard p.adv()
    let e = p.parseExpr()
    p.expect(";")
    result = Stmt(kind: skConstraint, cexpr: e, sline: t.line)
  of "forall":
    discard p.adv()
    let (gens, cond) = p.parseGens()
    let body = p.parseBlock()
    result = Stmt(kind: skForall, fgens: gens, fcond: cond, fbody: body,
                  sline: t.line)
  of "if":
    discard p.adv()
    let c = p.parseExpr()
    let th = p.parseBlock()
    var el: seq[Stmt] = @[]
    if p.accept("else"):
      if p.isKw("if"):
        el = @[p.parseStmt()]
      else:
        el = p.parseBlock()
    result = Stmt(kind: skIf, ifCond: c, thenB: th, elseB: el, sline: t.line)
  of "solve":
    discard p.adv()
    let st = Stmt(kind: skSolve, sline: t.line)
    if p.accept("satisfy"):
      st.skind = "satisfy"
    elif p.accept("all"):
      st.skind = "all"
    elif p.accept("minimize"):
      st.skind = "minimize"
      st.sobj = p.parseExpr()
    elif p.accept("maximize"):
      st.skind = "maximize"
      st.sobj = p.parseExpr()
    else:
      err(t.line, "'satisfy', 'all', 'minimize' or 'maximize' expected after 'solve'")
    p.expect(";")
    result = st
  of "output":
    discard p.adv()
    var items = @[p.parseExpr()]
    while p.accept(","):
      items.add p.parseExpr()
    p.expect(";")
    result = Stmt(kind: skOutput, oitems: items, sline: t.line)
  of "search":
    discard p.adv()
    let v = p.parseExpr()
    p.expect(":")
    let vs = p.expectIdent()
    p.expect(",")
    let vl = p.expectIdent()
    p.expect(";")
    result = Stmt(kind: skSearch, svars: v, svarSel: vs, svalSel: vl,
                  sline: t.line)
  of "option":
    discard p.adv()
    let name = p.expectIdent()
    p.expect("=")
    let v = p.parseExpr()
    p.expect(";")
    result = Stmt(kind: skOption, oname: name, oval: v, sline: t.line)
  else:
    err(t.line, "unknown statement '" & t.text & "'")

#
# Values and linear expressions
#

proc vInt(i: int): Value = Value(kind: vkInt, i: i)
proc vBool(b: bool): Value = Value(kind: vkBool, b: b)

proc vLit(l: int): Value =
  if l == litTrue:
    result = vBool(true)
  elif l == litFalse:
    result = vBool(false)
  else:
    result = Value(kind: vkLit, lit: l)

proc vLin(e: LinExpr): Value =
  if e.terms.len == 0:
    result = vInt(e.k)
  else:
    result = Value(kind: vkLin, lin: e)

proc vArr(elems: seq[Value], dims: seq[int]): Value =
  result = Value(kind: vkArr, elems: elems, dims: dims)

proc isConst(v: Value): bool = v.kind in {vkInt, vkBool}
proc isBoolish(v: Value): bool = v.kind in {vkBool, vkLit}

proc constVal(v: Value): int =
  if v.kind == vkInt:
    result = v.i
  else:
    result = (if v.b: 1 else: 0)

proc isConstValue(v: Value): bool =
  case v.kind
  of vkInt, vkBool:
    result = true
  of vkLin, vkLit:
    result = false
  of vkArr:
    result = true
    for e in v.elems:
      if not isConstValue(e):
        return false

proc linConst(k: int): LinExpr = LinExpr(terms: @[], k: k)
proc linVar(x: int, a = 1): LinExpr = LinExpr(terms: @[(a: a, x: x)], k: 0)

proc normLin(e: LinExpr): LinExpr =
  var coef = initTable[int, int]()
  var order: seq[int] = @[]
  for t in e.terms:
    if not coef.hasKey(t.x):
      coef[t.x] = 0
      order.add t.x
    coef[t.x] = coef[t.x] + t.a
  result.k = e.k
  for x in order:
    let a = coef[x]
    if a != 0:
      result.terms.add((a: a, x: x))

proc linAdd(a, b: LinExpr, sb = 1): LinExpr =
  var r = LinExpr(terms: a.terms, k: a.k + sb * b.k)
  for t in b.terms:
    r.terms.add((a: sb * t.a, x: t.x))
  result = normLin(r)

proc linScale(e: LinExpr, f: int): LinExpr =
  if f == 0:
    return linConst(0)
  result.k = e.k * f
  for t in e.terms:
    result.terms.add((a: t.a * f, x: t.x))

proc negTerms(ts: seq[Term]): seq[Term] =
  for t in ts:
    result.add((a: -t.a, x: t.x))

#
# Compiler: environment
#

proc lookup(c: Compiler, name: string, line: int): Value =
  for i in countdown(c.scopes.high, 0):
    if c.scopes[i].hasKey(name):
      return c.scopes[i][name]
  err(line, "unknown identifier: " & name)

proc declare(c: Compiler, name: string, v: Value, line: int) =
  if c.scopes[^1].hasKey(name):
    err(line, "'" & name & "' is already declared")
  c.scopes[^1][name] = v

#
# Compiler: conversions
#

proc linBounds(c: Compiler, e: LinExpr): (int, int) =
  var lo = e.k
  var hi = e.k
  for t in e.terms:
    let l = c.s.lbs[t.x]
    let u = c.s.ubs[t.x]
    if t.a > 0:
      lo += t.a * l
      hi += t.a * u
    else:
      lo += t.a * u
      hi += t.a * l
  result = (lo, hi)

proc litToLin(c: Compiler, l: int): LinExpr =
  # 0/1 expression equal to the truth value of the literal.
  if l == litTrue:
    return linConst(1)
  if l == litFalse:
    return linConst(0)
  let v = varOf(l)
  let (x, _) = c.s.orderInfo(v)
  if x >= 0 and c.s.ivLb0[x] == 0 and c.s.ivUb0[x] == 1:
    # order boolean [x <= 0] of a 0..1 variable
    if isNeg(l):
      return linVar(x)
    return LinExpr(terms: @[(a: -1, x: x)], k: 1)
  var xb: int
  if c.litIntCache.hasKey(v):
    xb = c.litIntCache[v]
  else:
    xb = c.s.newIntVar(0, 1)
    let p = mkLit(v)
    c.s.addClause([neg(p), c.s.geLit(xb, 1)])
    c.s.addClause([p, c.s.leLit(xb, 0)])
    c.litIntCache[v] = xb
  if isNeg(l):
    result = LinExpr(terms: @[(a: -1, x: xb)], k: 1)
  else:
    result = linVar(xb)

proc toLin(c: Compiler, v: Value, line: int): LinExpr =
  case v.kind
  of vkInt: result = linConst(v.i)
  of vkBool: result = linConst(if v.b: 1 else: 0)
  of vkLin: result = v.lin
  of vkLit: result = c.litToLin(v.lit)
  of vkArr: err(line, "an array cannot be used as a scalar value")

proc toLit(c: Compiler, v: Value, line: int): int =
  case v.kind
  of vkBool: result = (if v.b: litTrue else: litFalse)
  of vkLit: result = v.lit
  of vkInt: err(line, "integer value used as a boolean")
  of vkLin: err(line, "integer expression used as a boolean")
  of vkArr: err(line, "array used as a boolean")

#
# Compiler: posting elementary constraints
#

proc postLE(c: Compiler, terms: seq[Term], rhs: int, r: int) =
  # r -> sum(terms) <= rhs
  var cs, xs: seq[int]
  for t in terms:
    cs.add t.a
    xs.add t.x
  c.s.postLinearLE(cs, xs, rhs, r)

proc reifyLE(c: Compiler, terms: seq[Term], rhs: int): int =
  # literal r such that r <-> sum(terms) <= rhs
  if terms.len == 0:
    return (if 0 <= rhs: litTrue else: litFalse)
  if terms.len == 1:
    let t = terms[0]
    if t.a > 0:
      return c.s.leLit(t.x, floorDivI(rhs, t.a))
    return c.s.geLit(t.x, ceilDivI(rhs, t.a))
  let r = c.s.newLitVar()
  c.postLE(terms, rhs, r)
  c.postLE(negTerms(terms), -rhs - 1, neg(r))
  result = r

proc mkAndN(c: Compiler, lits: seq[int]): int =
  # literal r <-> AND(lits)  (Tseitin encoding)
  var ls: seq[int] = @[]
  for l in lits:
    if l == litFalse:
      return litFalse
    if l == litTrue:
      continue
    if neg(l) in ls:
      return litFalse
    if l notin ls:
      ls.add l
  if ls.len == 0:
    return litTrue
  if ls.len == 1:
    return ls[0]
  let r = c.s.newLitVar()
  var big = @[r]
  for l in ls:
    c.s.addClause([neg(r), l])
    big.add neg(l)
  c.s.addClause(big)
  result = r

proc mkOrN(c: Compiler, lits: seq[int]): int =
  var nl: seq[int] = @[]
  for l in lits:
    nl.add neg(l)
  result = neg(c.mkAndN(nl))

proc mkXor(c: Compiler, a, b: int): int =
  if a == litFalse: return b
  if a == litTrue: return neg(b)
  if b == litFalse: return a
  if b == litTrue: return neg(a)
  if a == b: return litFalse
  if a == neg(b): return litTrue
  let r = c.s.newLitVar()
  c.s.addClause([neg(r), a, b])
  c.s.addClause([neg(r), neg(a), neg(b)])
  c.s.addClause([r, neg(a), b])
  c.s.addClause([r, a, neg(b)])
  result = r

proc reifyCmp(c: Compiler, op: string, e: LinExpr): int =
  # literal r <-> (e op 0)
  case op
  of "<=": result = c.reifyLE(e.terms, -e.k)
  of "<": result = c.reifyLE(e.terms, -e.k - 1)
  of ">=": result = c.reifyLE(negTerms(e.terms), e.k)
  of ">": result = c.reifyLE(negTerms(e.terms), e.k - 1)
  of "==":
    if e.terms.len == 0:
      result = (if e.k == 0: litTrue else: litFalse)
    elif e.terms.len == 1:
      let t = e.terms[0]
      if (-e.k) mod t.a != 0:
        result = litFalse
      else:
        result = c.s.eqLit(t.x, (-e.k) div t.a)
    else:
      result = c.mkAndN(@[c.reifyLE(e.terms, -e.k),
                          c.reifyLE(negTerms(e.terms), e.k)])
  of "!=":
    result = neg(c.reifyCmp("==", e))
  else:
    raise newException(CpError, "unknown comparison operator: " & op)

proc postCmp(c: Compiler, op: string, e: LinExpr, r: int) =
  # r -> (e op 0)
  case op
  of "<=":
    c.postLE(e.terms, -e.k, r)
  of "<":
    c.postLE(e.terms, -e.k - 1, r)
  of ">=":
    c.postLE(negTerms(e.terms), e.k, r)
  of ">":
    c.postLE(negTerms(e.terms), e.k - 1, r)
  of "==":
    c.postLE(e.terms, -e.k, r)
    c.postLE(negTerms(e.terms), e.k, r)
  of "!=":
    if e.terms.len <= 1:
      c.s.addClause([neg(r), neg(c.reifyCmp("==", e))])
    else:
      let l1 = c.s.newLitVar()
      let l2 = c.s.newLitVar()
      c.postLE(e.terms, -e.k - 1, l1)
      c.postLE(negTerms(e.terms), e.k - 1, l2)
      c.s.addClause([neg(r), l1, l2])
  else:
    raise newException(CpError, "unknown comparison operator: " & op)

proc toVar(c: Compiler, v: Value, line: int): int =
  # Integer variable equal to the value (creates an auxiliary variable if needed).
  let e = c.toLin(v, line)
  if e.terms.len == 1 and e.terms[0].a == 1 and e.k == 0:
    return e.terms[0].x
  let (lo, hi) = c.linBounds(e)
  result = c.s.newIntVar(lo, hi)
  c.postCmp("==", linAdd(e, linVar(result), -1), litTrue)

proc atMostOne(c: Compiler, lits: seq[int]) =
  var ls: seq[int] = @[]
  for l in lits:
    if l != litFalse:
      ls.add l
  let n = ls.len
  if n <= 1:
    return
  if n <= 5:
    for i in 0 ..< n:
      for j in i + 1 ..< n:
        c.s.addClause([neg(ls[i]), neg(ls[j])])
    return
  # sequential encoding (Sinz): aux[i] = "one of ls[0..i] is true"
  var aux: seq[int] = @[]
  for i in 0 ..< n - 1:
    aux.add c.s.newLitVar()
  for i in 0 ..< n:
    if i < n - 1:
      c.s.addClause([neg(ls[i]), aux[i]])
    if i > 0 and i < n - 1:
      c.s.addClause([neg(aux[i - 1]), aux[i]])
    if i > 0:
      c.s.addClause([neg(aux[i - 1]), neg(ls[i])])

proc assertLit(c: Compiler, l: int) =
  c.s.addClause([l])

#
# Compiler: expression evaluation
#

proc eval(c: Compiler, n: Node): Value

proc evalInt(c: Compiler, n: Node): int =
  let v = c.eval(n)
  if not v.isConst:
    err(n.line, "integer constant expected")
  result = v.constVal

proc evalBool(c: Compiler, n: Node): bool =
  let v = c.eval(n)
  if v.kind != vkBool:
    err(n.line, "constant boolean condition expected")
  result = v.b

proc iterGens(c: Compiler, gens: seq[Gen], k: int, cond: Node,
              action: proc ()) =
  if k == gens.len:
    if cond == nil or c.evalBool(cond):
      action()
    return
  let g = gens[k]
  let lo = c.evalInt(g.lo)
  let hi = c.evalInt(g.hi)
  c.scopes.add initTable[string, Value]()
  for i in lo .. hi:
    c.scopes[^1][g.name] = vInt(i)
    c.iterGens(gens, k + 1, cond, action)
  discard c.scopes.pop()

proc sumValues(c: Compiler, vals: seq[Value], line: int): Value =
  var e = linConst(0)
  for v in vals:
    let l = c.toLin(v, line)
    e.k += l.k
    for t in l.terms:
      e.terms.add t
  result = vLin(normLin(e))

proc arith(c: Compiler, op: string, a, b: Value, line: int): Value =
  if a.kind == vkArr or b.kind == vkArr:
    err(line, "arithmetic operation on an array")
  if a.isConst and b.isConst:
    let x = a.constVal
    let y = b.constVal
    case op
    of "+": return vInt(x + y)
    of "-": return vInt(x - y)
    of "*": return vInt(x * y)
    of "div":
      if y == 0: err(line, "division by zero")
      return vInt(floorDivI(x, y))
    of "mod":
      if y == 0: err(line, "modulo by zero")
      return vInt(floorModI(x, y))
    else: discard
  case op
  of "+":
    result = vLin(linAdd(c.toLin(a, line), c.toLin(b, line)))
  of "-":
    result = vLin(linAdd(c.toLin(a, line), c.toLin(b, line), -1))
  of "*":
    if a.isConst:
      result = vLin(linScale(c.toLin(b, line), a.constVal))
    elif b.isConst:
      result = vLin(linScale(c.toLin(a, line), b.constVal))
    else:
      let x = c.toVar(a, line)
      let y = c.toVar(b, line)
      let p1 = c.s.lbs[x] * c.s.lbs[y]
      let p2 = c.s.lbs[x] * c.s.ubs[y]
      let p3 = c.s.ubs[x] * c.s.lbs[y]
      let p4 = c.s.ubs[x] * c.s.ubs[y]
      let z = c.s.newIntVar(min(min(p1, p2), min(p3, p4)),
                            max(max(p1, p2), max(p3, p4)))
      c.s.addTimes(x, y, z)
      result = vLin(linVar(z))
  of "div", "mod":
    if not b.isConst:
      err(line, "the divisor of div/mod must be a constant")
    let d = b.constVal
    if d == 0:
      err(line, "division by zero")
    let e = c.toLin(a, line)
    let (lo, hi) = c.linBounds(e)
    var q, r: int
    if d > 0:
      q = c.s.newIntVar(floorDivI(lo, d), floorDivI(hi, d))
      r = c.s.newIntVar(0, d - 1)
    else:
      q = c.s.newIntVar(floorDivI(hi, d), floorDivI(lo, d))
      r = c.s.newIntVar(d + 1, 0)
    # e = d*q + r
    var t = linAdd(e, linVar(q, d), -1)
    t = linAdd(t, linVar(r), -1)
    c.postCmp("==", t, litTrue)
    result = (if op == "div": vLin(linVar(q)) else: vLin(linVar(r)))
  else:
    err(line, "unknown operator: " & op)

proc cmpValues(c: Compiler, op: string, a, b: Value, line: int): Value =
  if a.kind == vkArr or b.kind == vkArr:
    err(line, "array comparison not supported")
  if a.isConst and b.isConst:
    let x = a.constVal
    let y = b.constVal
    var r = false
    case op
    of "==": r = x == y
    of "!=": r = x != y
    of "<": r = x < y
    of "<=": r = x <= y
    of ">": r = x > y
    else: r = x >= y
    return vBool(r)
  if (op == "==" or op == "!=") and a.isBoolish and b.isBoolish:
    let l = c.mkXor(c.toLit(a, line), c.toLit(b, line))
    return vLit(if op == "==": neg(l) else: l)
  let e = linAdd(c.toLin(a, line), c.toLin(b, line), -1)
  result = vLit(c.reifyCmp(op, e))

proc logicValues(c: Compiler, op: string, a, b: Value, line: int): Value =
  let x = c.toLit(a, line)
  let y = c.toLit(b, line)
  case op
  of "and": result = vLit(c.mkAndN(@[x, y]))
  of "or": result = vLit(c.mkOrN(@[x, y]))
  of "xor": result = vLit(c.mkXor(x, y))
  of "->": result = vLit(c.mkOrN(@[neg(x), y]))
  of "<->": result = vLit(neg(c.mkXor(x, y)))
  else: err(line, "unknown logical operator: " & op)

proc minMax(c: Compiler, isMax: bool, vals: seq[Value], line: int): Value =
  if vals.len == 0:
    err(line, "min/max of an empty list")
  var allConst = true
  for v in vals:
    if not v.isConst:
      allConst = false
  if allConst:
    var r = vals[0].constVal
    for v in vals:
      r = (if isMax: max(r, v.constVal) else: min(r, v.constVal))
    return vInt(r)
  var es: seq[LinExpr] = @[]
  var lo, hi: int
  for i, v in vals:
    let e = c.toLin(v, line)
    es.add e
    let (l, u) = c.linBounds(e)
    if i == 0:
      lo = l
      hi = u
    elif isMax:
      lo = max(lo, l)
      hi = max(hi, u)
    else:
      lo = min(lo, l)
      hi = min(hi, u)
  let z = c.s.newIntVar(lo, hi)
  var sels: seq[int] = @[]
  for e in es:
    let d = linAdd(e, linVar(z), -1)       # e - z
    c.postCmp((if isMax: "<=" else: ">="), d, litTrue)
    let sl = c.s.newLitVar()
    c.postCmp("==", d, sl)                  # sl -> z == e
    sels.add sl
  c.s.addClause(sels)
  result = vLin(linVar(z))

proc buildList(vals: seq[Value], line: int): Value =
  if vals.len > 0 and vals[0].kind == vkArr:
    let d = vals[0].dims
    var elems: seq[Value] = @[]
    for v in vals:
      if v.kind != vkArr or v.dims != d:
        err(line, "irregular nested list")
      elems.add v.elems
    return vArr(elems, @[vals.len] & d)
  for v in vals:
    if v.kind == vkArr:
      err(line, "irregular nested list")
  result = vArr(vals, @[vals.len])

proc elementValue(c: Compiler, elems: seq[Value], iv: int, line: int): Value =
  # elems[iv] with a variable iv (decomposed element constraint)
  let n = elems.len
  if n == 0:
    err(line, "indexing an empty array")
  c.s.addClause([c.s.geLit(iv, 0)])
  c.s.addClause([c.s.leLit(iv, n - 1)])
  let lo = max(0, c.s.lbs[iv])
  let hi = min(n - 1, c.s.ubs[iv])
  if lo > hi:
    c.s.ok = false
    return vInt(0)
  var allBool = true
  var allConst = true
  for i in lo .. hi:
    if not elems[i].isBoolish: allBool = false
    if not elems[i].isConst: allConst = false
    if elems[i].kind == vkArr:
      err(line, "non-scalar array element")
  var z: int
  if allConst:
    var vmin = high(int)
    var vmax = low(int)
    for i in lo .. hi:
      vmin = min(vmin, elems[i].constVal)
      vmax = max(vmax, elems[i].constVal)
    z = c.s.newIntVar(vmin, vmax)
    for i in lo .. hi:
      c.s.addClause([neg(c.s.eqLit(iv, i)), c.s.eqLit(z, elems[i].constVal)])
    for w in vmin .. vmax:
      var cl = @[neg(c.s.eqLit(z, w))]
      for i in lo .. hi:
        if elems[i].constVal == w:
          cl.add c.s.eqLit(iv, i)
      c.s.addClause(cl)
  else:
    var es: seq[LinExpr] = @[]
    var vmin = high(int)
    var vmax = low(int)
    for i in lo .. hi:
      let e = c.toLin(elems[i], line)
      es.add e
      let (l, u) = c.linBounds(e)
      vmin = min(vmin, l)
      vmax = max(vmax, u)
    z = c.s.newIntVar(vmin, vmax)
    for i in lo .. hi:
      c.postCmp("==", linAdd(es[i - lo], linVar(z), -1), c.s.eqLit(iv, i))
  if allBool:
    result = vLit(c.s.geLit(z, 1))
  else:
    result = vLin(linVar(z))

proc indexValue(c: Compiler, base: Value, idxs: seq[Value], line: int): Value =
  if base.kind != vkArr:
    err(line, "indexing a value that is not an array")
  if idxs.len > base.dims.len:
    err(line, "too many indices (" & $idxs.len & ") for an array of dimension " &
        $base.dims.len)
  var strides = newSeq[int](base.dims.len)
  var st = 1
  for k in countdown(base.dims.high, 0):
    strides[k] = st
    st *= base.dims[k]
  var allConst = true
  for v in idxs:
    if not v.isConst:
      allConst = false
  if allConst:
    var off = 0
    for k in 0 ..< idxs.len:
      let i = idxs[k].constVal
      if i < 0 or i >= base.dims[k]:
        err(line, "index " & $i & " out of bounds (0.." & $(base.dims[k] - 1) & ")")
      off += i * strides[k]
    if idxs.len == base.dims.len:
      return base.elems[off]
    let size = strides[idxs.len - 1]
    return vArr(base.elems[off ..< off + size], base.dims[idxs.len .. ^1])
  if idxs.len != base.dims.len:
    err(line, "partial indexing with a variable index is not supported")
  var flat = linConst(0)
  for k in 0 ..< idxs.len:
    let e = c.toLin(idxs[k], line)
    if not idxs[k].isConst:
      c.postCmp(">=", e, litTrue)
      c.postCmp("<=", linAdd(e, linConst(base.dims[k] - 1), -1), litTrue)
    flat = linAdd(flat, linScale(e, strides[k]))
  let iv = c.toVar(vLin(flat), line)
  result = c.elementValue(base.elems, iv, line)

proc argList(c: Compiler, args: seq[Node], line: int): seq[Value] =
  # f(array) or f(a, b, c)
  if args.len == 1:
    let v = c.eval(args[0])
    if v.kind == vkArr:
      return v.elems
    return @[v]
  for a in args:
    result.add c.eval(a)

proc checkArgs(n: Node, k: int) =
  if n.args.len != k:
    err(n.line, "'" & n.fname & "' expects " & $k & " argument(s)")

proc iteValue(c: Compiler, cond, a, b: Value, line: int): Value =
  if cond.isConst:
    return (if cond.constVal != 0: a else: b)
  let r = c.toLit(cond, line)
  if a.isBoolish and b.isBoolish:
    let x = c.toLit(a, line)
    let y = c.toLit(b, line)
    let z = c.s.newLitVar()
    c.s.addClause([neg(r), neg(x), z])
    c.s.addClause([neg(r), x, neg(z)])
    c.s.addClause([r, neg(y), z])
    c.s.addClause([r, y, neg(z)])
    return vLit(z)
  let ea = c.toLin(a, line)
  let eb = c.toLin(b, line)
  let (la, ua) = c.linBounds(ea)
  let (lb, ub) = c.linBounds(eb)
  let z = c.s.newIntVar(min(la, lb), max(ua, ub))
  c.postCmp("==", linAdd(ea, linVar(z), -1), r)
  c.postCmp("==", linAdd(eb, linVar(z), -1), neg(r))
  result = vLin(linVar(z))

proc aggregate(c: Compiler, name: string, vals: seq[Value], line: int): Value =
  case name
  of "sum":
    result = c.sumValues(vals, line)
  of "min":
    result = c.minMax(false, vals, line)
  of "max":
    result = c.minMax(true, vals, line)
  of "forall", "exists":
    var ls: seq[int] = @[]
    for v in vals:
      ls.add c.toLit(v, line)
    if name == "forall":
      result = vLit(c.mkAndN(ls))
    else:
      result = vLit(c.mkOrN(ls))
  else:
    err(line, "unknown aggregate: " & name)

proc evalCall(c: Compiler, n: Node): Value =
  let line = n.line
  case n.fname
  of "abs":
    checkArgs(n, 1)
    let v = c.eval(n.args[0])
    if v.isConst:
      result = vInt(abs(v.constVal))
    else:
      let m = vLin(linScale(c.toLin(v, line), -1))
      result = c.minMax(true, @[v, m], line)
  of "min", "max":
    result = c.minMax(n.fname == "max", c.argList(n.args, line), line)
  of "sum":
    result = c.sumValues(c.argList(n.args, line), line)
  of "count":
    checkArgs(n, 2)
    let lst = c.eval(n.args[0])
    if lst.kind != vkArr:
      err(line, "count: the first argument must be an array")
    let target = c.eval(n.args[1])
    var bs: seq[Value] = @[]
    for v in lst.elems:
      bs.add c.cmpValues("==", v, target, line)
    result = c.sumValues(bs, line)
  of "bool2int":
    checkArgs(n, 1)
    result = vLin(c.toLin(c.eval(n.args[0]), line))
  of "ite":
    checkArgs(n, 3)
    result = c.iteValue(c.eval(n.args[0]), c.eval(n.args[1]),
                        c.eval(n.args[2]), line)
  of "length":
    checkArgs(n, 1)
    let v = c.eval(n.args[0])
    if v.kind != vkArr:
      err(line, "length: array expected")
    result = vInt(v.dims[0])
  of "alldifferent", "table", "circuit", "increasing", "cumulative",
     "disjunctive", "reservoir", "windows":
    err(line, "'" & n.fname & "' is a global constraint: use it " &
        "directly in 'constraint' (possibly combined with 'and')")
  else:
    err(line, "unknown function: " & n.fname)

proc eval(c: Compiler, n: Node): Value =
  case n.kind
  of nkInt:
    result = vInt(n.ival)
  of nkBool:
    result = vBool(n.bval)
  of nkStr:
    err(n.line, "character strings are only allowed in 'output'")
  of nkIdent:
    result = c.lookup(n.name, n.line)
  of nkUn:
    let v = c.eval(n.arg)
    if n.uop == "neg":
      if v.isConst:
        result = vInt(-v.constVal)
      else:
        result = vLin(linScale(c.toLin(v, n.line), -1))
    else:
      result = vLit(neg(c.toLit(v, n.line)))
  of nkBin:
    case n.op
    of "+", "-", "*", "div", "mod":
      result = c.arith(n.op, c.eval(n.lhs), c.eval(n.rhs), n.line)
    of "==", "!=", "<", "<=", ">", ">=":
      result = c.cmpValues(n.op, c.eval(n.lhs), c.eval(n.rhs), n.line)
    of "and", "or", "xor", "->", "<->":
      result = c.logicValues(n.op, c.eval(n.lhs), c.eval(n.rhs), n.line)
    else:
      err(n.line, "unknown operator: " & n.op)
  of nkCall:
    result = c.evalCall(n)
  of nkIndex:
    let base = c.eval(n.base)
    var idxs: seq[Value] = @[]
    for e in n.idx:
      idxs.add c.eval(e)
    result = c.indexValue(base, idxs, n.line)
  of nkList:
    var vals: seq[Value] = @[]
    for e in n.items:
      vals.add c.eval(e)
    result = buildList(vals, n.line)
  of nkCompr:
    var vals: seq[Value] = @[]
    c.iterGens(n.gens, 0, n.cond, proc () = vals.add c.eval(n.body))
    result = buildList(vals, n.line)
  of nkAggr:
    var vals: seq[Value] = @[]
    c.iterGens(n.agens, 0, n.acond, proc () = vals.add c.eval(n.abody))
    result = c.aggregate(n.aname, vals, n.line)

#
# Global constraints
#

proc postAllDiffVars(c: Compiler, xs: seq[int]) =
  if xs.len <= 1:
    return
  var lo = high(int)
  var hi = low(int)
  for x in xs:
    lo = min(lo, c.s.lbs[x])
    hi = max(hi, c.s.ubs[x])
  for w in lo .. hi:
    var ls: seq[int] = @[]
    for x in xs:
      let e = c.s.eqLit(x, w)
      if e != litFalse:
        ls.add e
    c.atMostOne(ls)

proc postAllDiff(c: Compiler, vals: seq[Value], line: int) =
  var xs: seq[int] = @[]
  for v in vals:
    xs.add c.toVar(v, line)
  c.postAllDiffVars(xs)

proc postIncreasing(c: Compiler, vals: seq[Value], line: int) =
  for i in 0 ..< vals.len - 1:
    c.postCmp("<=", linAdd(c.toLin(vals[i], line), c.toLin(vals[i + 1], line), -1),
              litTrue)

proc postCircuit(c: Compiler, vals: seq[Value], line: int) =
  # succ[i] = successor of i; a single Hamiltonian cycle over 0..n-1
  let n = vals.len
  if n == 0:
    return
  var xs: seq[int] = @[]
  for v in vals:
    let x = c.toVar(v, line)
    c.s.addClause([c.s.geLit(x, 0)])
    c.s.addClause([c.s.leLit(x, n - 1)])
    xs.add x
  if n == 1:
    return
  for i in 0 ..< n:
    c.s.addClause([neg(c.s.eqLit(xs[i], i))])
  c.postAllDiffVars(xs)
  # visit rank (subtour elimination, MTZ style)
  var o: seq[int] = @[]
  for i in 0 ..< n:
    o.add c.s.newIntVar(0, n - 1)
  c.s.addClause([c.s.leLit(o[0], 0)])
  for i in 0 ..< n:
    for j in 1 ..< n:
      if j == i:
        continue
      let e = c.s.eqLit(xs[i], j)
      if e == litFalse:
        continue
      var d = linAdd(linVar(o[j]), linVar(o[i]), -1)
      d.k -= 1
      c.postCmp("==", d, e)             # succ[i] = j -> o[j] = o[i] + 1

proc postTable(c: Compiler, vals: seq[Value], tup: Value, line: int) =
  var xs: seq[int] = @[]
  for v in vals:
    xs.add c.toVar(v, line)
  let n = xs.len
  if tup.kind != vkArr or tup.dims.len != 2 or tup.dims[1] != n:
    err(line, "table: the tuples must form a 2D array of width " & $n)
  for e in tup.elems:
    if not e.isConst:
      err(line, "table: the tuples must be constants")
  let k = tup.dims[0]
  var ts: seq[int] = @[]
  for r in 0 ..< k:
    let t = c.s.newLitVar()
    ts.add t
    for j in 0 ..< n:
      c.s.addClause([neg(t), c.s.eqLit(xs[j], tup.elems[r * n + j].constVal)])
  c.s.addClause(ts)
  for j in 0 ..< n:
    for w in c.s.lbs[xs[j]] .. c.s.ubs[xs[j]]:
      var cl = @[neg(c.s.eqLit(xs[j], w))]
      for r in 0 ..< k:
        if tup.elems[r * n + j].constVal == w:
          cl.add ts[r]
      c.s.addClause(cl)

proc listArg(c: Compiler, n: Node, k: int, what: string): seq[Value] =
  let v = c.eval(n.args[k])
  if v.kind != vkArr:
    err(n.line, what & ": argument " & $(k + 1) & " must be an array")
  result = v.elems

proc overlapLit(c: Compiler, si, di, sj: LinExpr): int =
  # literal b <-> (s_i <= s_j < s_i + d_i)
  let l1 = c.reifyCmp("<=", linAdd(si, sj, -1))
  let l2 = c.reifyCmp(">", linAdd(linAdd(si, di), sj, -1))
  result = c.mkAndN(@[l1, l2])

proc scaledLit(c: Compiler, b: int, q: Value, line: int): LinExpr =
  # q * b (b boolean), q constant or expression
  if q.isConst:
    result = linScale(c.litToLin(b), q.constVal)
  else:
    result = c.toLin(c.iteValue(vLit(b), q, vInt(0), line), line)

proc postCumulative(c: Compiler, ss, ds, qs: seq[Value], cap: Value, line: int) =
  # Cumulative resource: at any time, the sum of the demands of the running
  # tasks is <= cap. "Task-based" decomposition: checking the load at the
  # start of each task is enough.
  let n = ss.len
  if ds.len != n or qs.len != n:
    err(line, "cumulative: the three arrays must have the same size")
  var S, D: seq[LinExpr]
  for i in 0 ..< n:
    S.add c.toLin(ss[i], line)
    D.add c.toLin(ds[i], line)
  let capL = c.toLin(cap, line)
  for j in 0 ..< n:
    if qs[j].isConst and qs[j].constVal == 0: continue
    if D[j].terms.len == 0 and D[j].k == 0: continue
    var load = c.toLin(qs[j], line)
    for i in 0 ..< n:
      if i == j: continue
      if qs[i].isConst and qs[i].constVal == 0: continue
      let b = c.overlapLit(S[i], D[i], S[j])
      if b == litFalse: continue
      load = linAdd(load, c.scaledLit(b, qs[i], line))
    c.postCmp("<=", linAdd(load, capL, -1), litTrue)

proc postDisjunctive(c: Compiler, ss, ds: seq[Value], line: int) =
  # Unary resource: the tasks do not overlap.
  let n = ss.len
  if ds.len != n:
    err(line, "disjunctive: the two arrays must have the same size")
  var S, D: seq[LinExpr]
  for i in 0 ..< n:
    S.add c.toLin(ss[i], line)
    D.add c.toLin(ds[i], line)
  for i in 0 ..< n:
    for j in i + 1 ..< n:
      if (D[i].terms.len == 0 and D[i].k == 0) or (D[j].terms.len == 0 and D[j].k == 0):
        continue
      let l1 = c.s.newLitVar()
      let l2 = c.s.newLitVar()
      c.postCmp("<=", linAdd(linAdd(S[i], D[i]), S[j], -1), l1)   # i before j
      c.postCmp("<=", linAdd(linAdd(S[j], D[j]), S[i], -1), l2)   # j before i
      c.s.addClause([l1, l2])

proc postReservoir(c: Compiler, ts, dqs: seq[Value], init, lo, hi: Value, line: int) =
  # Stock: level = init + sum of the changes dq_j of the events t_j <= t.
  # The level stays within [lo, hi] right after each event.
  let n = ts.len
  if dqs.len != n:
    err(line, "reservoir: the two arrays must have the same size")
  let initL = c.toLin(init, line)
  let loL = c.toLin(lo, line)
  let hiL = c.toLin(hi, line)
  c.postCmp(">=", linAdd(initL, loL, -1), litTrue)
  c.postCmp("<=", linAdd(initL, hiL, -1), litTrue)
  var T: seq[LinExpr]
  for t in ts: T.add c.toLin(t, line)
  for i in 0 ..< n:
    var level = linAdd(initL, c.toLin(dqs[i], line))
    for j in 0 ..< n:
      if j == i: continue
      if dqs[j].isConst and dqs[j].constVal == 0: continue
      let b = c.reifyCmp("<=", linAdd(T[j], T[i], -1))     # t_j <= t_i
      if b == litFalse: continue
      level = linAdd(level, c.scaledLit(b, dqs[j], line))
    c.postCmp(">=", linAdd(level, loL, -1), litTrue)
    c.postCmp("<=", linAdd(level, hiL, -1), litTrue)

proc postWindows(c: Compiler, ss, ds, as0, bs: seq[Value], line: int) =
  # Every task i fits entirely in one of the windows [a_w, b_w].
  let n = ss.len
  if ds.len != n or as0.len != bs.len:
    err(line, "windows: inconsistent array sizes")
  for i in 0 ..< n:
    let s = c.toLin(ss[i], line)
    let e = linAdd(s, c.toLin(ds[i], line))
    var lits: seq[int] = @[]
    for w in 0 ..< as0.len:
      let l = c.s.newLitVar()
      c.postCmp(">=", linAdd(s, c.toLin(as0[w], line), -1), l)
      c.postCmp("<=", linAdd(e, c.toLin(bs[w], line), -1), l)
      lits.add l
    c.s.addClause(lits)

#
# Posting high-level constraints
#

proc arithCmp(a, b: Value): bool =
  # true if the comparison a op b must be handled linearly
  result = not (a.isConst and b.isConst) and not (a.isBoolish and b.isBoolish)

proc halfReif(c: Compiler, n: Node): int =
  # literal l such that l -> n (enough for a disjunction)
  if n.kind == nkBin and n.op in cmpOps:
    let a = c.eval(n.lhs)
    let b = c.eval(n.rhs)
    if arithCmp(a, b):
      let l = c.s.newLitVar()
      c.postCmp(n.op, linAdd(c.toLin(a, n.line), c.toLin(b, n.line), -1), l)
      return l
    return c.toLit(c.cmpValues(n.op, a, b, n.line), n.line)
  result = c.toLit(c.eval(n), n.line)

proc postImplied(c: Compiler, r: int, n: Node) =
  # r -> n
  if n.kind == nkBin and n.op == "and":
    c.postImplied(r, n.lhs)
    c.postImplied(r, n.rhs)
    return
  if n.kind == nkBin and n.op in cmpOps:
    let a = c.eval(n.lhs)
    let b = c.eval(n.rhs)
    if arithCmp(a, b):
      c.postCmp(n.op, linAdd(c.toLin(a, n.line), c.toLin(b, n.line), -1), r)
    else:
      c.s.addClause([neg(r), c.toLit(c.cmpValues(n.op, a, b, n.line), n.line)])
    return
  c.s.addClause([neg(r), c.toLit(c.eval(n), n.line)])

proc collectOr(n: Node, acc: var seq[Node]) =
  if n.kind == nkBin and n.op == "or":
    collectOr(n.lhs, acc)
    collectOr(n.rhs, acc)
  else:
    acc.add n

proc postConstraint(c: Compiler, n: Node) =
  if n.kind == nkBin:
    if n.op == "and":
      c.postConstraint(n.lhs)
      c.postConstraint(n.rhs)
      return
    if n.op in cmpOps:
      let a = c.eval(n.lhs)
      let b = c.eval(n.rhs)
      if arithCmp(a, b):
        c.postCmp(n.op, linAdd(c.toLin(a, n.line), c.toLin(b, n.line), -1), litTrue)
      else:
        c.assertLit(c.toLit(c.cmpValues(n.op, a, b, n.line), n.line))
      return
    if n.op == "->":
      let r = c.toLit(c.eval(n.lhs), n.line)
      if r != litFalse:
        c.postImplied(r, n.rhs)
      return
    if n.op == "or":
      var parts: seq[Node] = @[]
      collectOr(n, parts)
      var lits: seq[int] = @[]
      for p in parts:
        lits.add c.halfReif(p)
      c.s.addClause(lits)
      return
  elif n.kind == nkCall:
    case n.fname
    of "alldifferent":
      c.postAllDiff(c.argList(n.args, n.line), n.line)
      return
    of "increasing":
      c.postIncreasing(c.argList(n.args, n.line), n.line)
      return
    of "circuit":
      c.postCircuit(c.argList(n.args, n.line), n.line)
      return
    of "cumulative":
      checkArgs(n, 4)
      c.postCumulative(c.listArg(n, 0, "cumulative"), c.listArg(n, 1, "cumulative"),
                       c.listArg(n, 2, "cumulative"), c.eval(n.args[3]), n.line)
      return
    of "disjunctive":
      checkArgs(n, 2)
      c.postDisjunctive(c.listArg(n, 0, "disjunctive"), c.listArg(n, 1, "disjunctive"), n.line)
      return
    of "reservoir":
      checkArgs(n, 5)
      c.postReservoir(c.listArg(n, 0, "reservoir"), c.listArg(n, 1, "reservoir"),
                      c.eval(n.args[2]), c.eval(n.args[3]), c.eval(n.args[4]), n.line)
      return
    of "windows":
      checkArgs(n, 4)
      c.postWindows(c.listArg(n, 0, "windows"), c.listArg(n, 1, "windows"),
                    c.listArg(n, 2, "windows"), c.listArg(n, 3, "windows"), n.line)
      return
    of "table":
      checkArgs(n, 2)
      let lst = c.eval(n.args[0])
      if lst.kind != vkArr:
        err(n.line, "table: the first argument must be an array")
      c.postTable(lst.elems, c.eval(n.args[1]), n.line)
      return
    else:
      discard
  elif n.kind == nkAggr and n.aname == "forall":
    c.iterGens(n.agens, 0, n.acond, proc () = c.postConstraint(n.abody))
    return
  c.assertLit(c.toLit(c.eval(n), n.line))

#
# Statement execution
#

proc execStmt(c: Compiler, st: Stmt)

proc execBlock(c: Compiler, stmts: seq[Stmt]) =
  c.scopes.add initTable[string, Value]()
  for st in stmts:
    c.execStmt(st)
  discard c.scopes.pop()

proc newDeclVar(c: Compiler, st: Stmt, lo, hi: int, allowed: seq[int]): Value =
  if st.visBool:
    let x = c.s.newIntVar(0, 1)
    c.decisionVars.add x
    return vLit(c.s.geLit(x, 1))
  let x = c.s.newIntVar(lo, hi)
  if allowed.len > 0:
    for w in lo .. hi:
      if w notin allowed:
        c.s.addClause([neg(c.s.eqLit(x, w))])
  c.decisionVars.add x
  result = vLin(linVar(x))

proc parseVarSel(name: string, line: int): VarSel =
  case name
  of "input_order": result = vsInputOrder
  of "first_fail": result = vsFirstFail
  of "smallest": result = vsSmallest
  of "largest": result = vsLargest
  else: err(line, "unknown variable selection: " & name &
            " (input_order, first_fail, smallest, largest)")

proc parseValSel(name: string, line: int): ValSel =
  case name
  of "min": result = vlMin
  of "max": result = vlMax
  of "split": result = vlSplit
  else: err(line, "unknown value selection: " & name & " (min, max, split)")

proc execStmt(c: Compiler, st: Stmt) =
  case st.kind
  of skConst:
    let v = c.eval(st.cval)
    if not isConstValue(v):
      err(st.sline, "'const' requires a constant value (use 'let' for an alias)")
    c.declare(st.cname, v, st.sline)
  of skLet:
    c.declare(st.cname, c.eval(st.cval), st.sline)
  of skVar:
    var dims: seq[int] = @[]
    var total = 1
    for d in st.vdims:
      let k = c.evalInt(d)
      if k < 0:
        err(st.sline, "negative dimension")
      dims.add k
      total *= k
    var lo, hi: int
    var allowed: seq[int] = @[]
    if not st.visBool:
      if st.vset.len > 0:
        for e in st.vset:
          allowed.add c.evalInt(e)
        lo = min(allowed)
        hi = max(allowed)
      else:
        lo = c.evalInt(st.vlo)
        hi = c.evalInt(st.vhi)
        if lo > hi:
          err(st.sline, "empty domain " & $lo & ".." & $hi)
    var elems: seq[Value] = @[]
    for k in 0 ..< total:
      elems.add c.newDeclVar(st, lo, hi, allowed)
    let v = (if dims.len == 0: elems[0] else: vArr(elems, dims))
    c.declare(st.vname, v, st.sline)
    if c.scopes.len == 1:
      c.userVars.add((st.vname, v))
  of skConstraint:
    c.postConstraint(st.cexpr)
  of skForall:
    c.iterGens(st.fgens, 0, st.fcond, proc () = c.execBlock(st.fbody))
  of skIf:
    if c.evalBool(st.ifCond):
      c.execBlock(st.thenB)
    else:
      c.execBlock(st.elseB)
  of skSolve:
    if c.solveKind != "":
      err(st.sline, "only one 'solve' statement is allowed")
    c.solveKind = st.skind
    if st.sobj != nil:
      c.objective = c.toLin(c.eval(st.sobj), st.sline)
  of skOutput:
    c.hasOutput = true
    for it in st.oitems:
      if it.kind == nkStr:
        c.outputs.add OutItem(isText: true, text: it.sval)
      else:
        c.outputs.add OutItem(isText: false, val: c.eval(it))
  of skSearch:
    let v = c.eval(st.svars)
    let vals = (if v.kind == vkArr: v.elems else: @[v])
    var g = SearchGroup(varSel: parseVarSel(st.svarSel, st.sline),
                        valSel: parseValSel(st.svalSel, st.sline))
    for e in vals:
      g.vars.add c.toVar(e, st.sline)
    c.s.searchGroups.add g
  of skOption:
    case st.oname
    of "timeout": c.timeout = float(c.evalInt(st.oval))
    of "solutions": c.maxSolutions = c.evalInt(st.oval)
    of "stats": c.showStats = c.evalInt(st.oval) != 0
    else: err(st.sline, "unknown option: " & st.oname &
              " (timeout, solutions, stats)")

#
# Output and solving control
#

proc formatValue(c: Compiler, v: Value): string

proc formatArr(c: Compiler, elems: seq[Value], dims: seq[int]): string =
  var parts: seq[string] = @[]
  if dims.len <= 1:
    for e in elems:
      parts.add c.formatValue(e)
  else:
    var size = 1
    for d in dims[1 .. ^1]:
      size *= d
    for r in 0 ..< dims[0]:
      parts.add c.formatArr(elems[r * size ..< (r + 1) * size], dims[1 .. ^1])
  result = "[" & parts.join(", ") & "]"

proc formatValue(c: Compiler, v: Value): string =
  case v.kind
  of vkInt:
    result = $v.i
  of vkBool:
    result = (if v.b: "true" else: "false")
  of vkLin:
    var t = v.lin.k
    for tm in v.lin.terms:
      t += tm.a * c.s.solVals[tm.x]
    result = $t
  of vkLit:
    result = (if c.s.solLit(v.lit): "true" else: "false")
  of vkArr:
    result = c.formatArr(v.elems, v.dims)

proc objValue(c: Compiler): int =
  result = c.objective.k
  for t in c.objective.terms:
    result += t.a * c.s.solVals[t.x]

proc printSolution(c: Compiler, optimizing: bool) =
  if c.hasOutput:
    var txt = ""
    for it in c.outputs:
      if it.isText:
        txt.add it.text
      else:
        txt.add c.formatValue(it.val)
    stdout.write txt
    if not txt.endsWith("\n"):
      stdout.write "\n"
  else:
    for (name, v) in c.userVars:
      echo name, " = ", c.formatValue(v)
    if optimizing:
      echo "objective = ", c.objValue()
  echo "----------"
  flushFile(stdout)

#
# API for applications (wdreka): callback-driven solving
#

type
  SolutionProc* = proc (c: Compiler, index: int, objective: int,
                        hasObjective: bool) {.nimcall, gcsafe.}
  RunSummary* = object
    kind*: string          # satisfy / all / minimize / maximize
    solutions*: int
    complete*: bool        # search finished (optimum proven / all found / infeasible)
    lastObjective*: int

proc solveKindOf*(c: Compiler): string =
  result = (if c.solveKind == "": "satisfy" else: c.solveKind)

proc objectiveBounds*(c: Compiler): (int, int) =
  # current bounds of the objective (at level 0: after root propagation)
  result = c.linBounds(c.objective)

proc currentObjective*(c: Compiler): int = c.objValue()

proc hasName*(c: Compiler, name: string): bool =
  result = c.scopes.len > 0 and c.scopes[0].hasKey(name)

proc valueOf*(c: Compiler, name: string): string =
  # value (in the last solution) of a name declared at top level
  if not c.hasName(name):
    return ""
  result = c.formatValue(c.scopes[0][name])

proc intValueOf*(c: Compiler, name: string, default = 0): int =
  if not c.hasName(name):
    return default
  let v = c.scopes[0][name]
  case v.kind
  of vkInt, vkBool: result = v.constVal
  of vkLin, vkLit: result = parseInt(c.formatValue(v).replace("true", "1").replace("false", "0"))
  of vkArr: result = default

proc intListOf*(c: Compiler, name: string): seq[int] =
  if not c.hasName(name):
    return @[]
  let v = c.scopes[0][name]
  if v.kind != vkArr:
    return @[]
  for e in v.elems:
    let s = c.formatValue(e)
    result.add(if s == "true": 1 elif s == "false": 0 else: parseInt(s))

proc topLevelNames*(c: Compiler): seq[string] =
  # top-level names depending on decision variables
  for name, v in c.scopes[0].pairs:
    if not isConstValue(v):
      result.add name

proc errorLine*(msg: string): int =
  # extracts N from a message "line N: ..." (0 if absent)
  result = 0
  if msg.startsWith("line "):
    var i = 5
    while i < msg.len and msg[i] in Digits:
      result = result * 10 + (ord(msg[i]) - ord('0'))
      inc i

proc runInteractive*(c: Compiler, onSolution: SolutionProc, timeout = 0.0,
                     maxSolutions = 0): RunSummary =
  # Solves the compiled model; calls onSolution at each solution
  # (each improvement when optimizing). Progress monitoring and stopping
  # are set through c.s.progress.
  let s = c.s
  s.startTime = epochTime()
  if timeout > 0.0:
    s.deadline = s.startTime + timeout
  let kind = c.solveKindOf()
  result.kind = kind
  case kind
  of "satisfy":
    let r = s.solve()
    if r == srSat:
      inc result.solutions
      onSolution(c, 1, 0, false)
    result.complete = r != srUnknown
  of "all":
    while true:
      let r = s.solve()
      if r == srSat:
        inc result.solutions
        onSolution(c, result.solutions, 0, false)
        if maxSolutions > 0 and result.solutions >= maxSolutions:
          break
        var cl: seq[int] = @[]
        for x in c.decisionVars:
          let v = s.solVals[x]
          cl.add s.leLit(x, v - 1)
          cl.add s.geLit(x, v + 1)
        s.addClause(cl)
        if not s.ok:
          result.complete = true
          break
      elif r == srUnsat:
        result.complete = true
        break
      else:
        break
  else:
    let obj = c.objective
    while true:
      let r = s.solve()
      if r == srSat:
        inc result.solutions
        let val = c.objValue()
        result.lastObjective = val
        onSolution(c, result.solutions, val, true)
        if obj.terms.len == 0:
          result.complete = true
          break
        if kind == "minimize":
          c.postLE(obj.terms, val - 1 - obj.k, litTrue)
        else:
          c.postLE(negTerms(obj.terms), obj.k - val - 1, litTrue)
        if not s.ok:
          result.complete = true
          break
      elif r == srUnsat:
        result.complete = true
        break
      else:
        break

proc runModel*(c: Compiler, allOverride = false, timeoutOverride = 0.0,
               statsOverride = false) =
  let s = c.s
  let t0 = epochTime()
  var timeout = c.timeout
  if timeoutOverride > 0.0:
    timeout = timeoutOverride
  if timeout > 0.0:
    s.deadline = t0 + timeout
  var kind = (if c.solveKind == "": "satisfy" else: c.solveKind)
  if allOverride and kind == "satisfy":
    kind = "all"
  var nsol = 0
  var complete = false
  case kind
  of "satisfy":
    let r = s.solve()
    if r == srSat:
      inc nsol
      c.printSolution(false)
    elif r == srUnsat:
      complete = true
  of "all":
    while true:
      let r = s.solve()
      if r == srSat:
        inc nsol
        c.printSolution(false)
        if c.maxSolutions > 0 and nsol >= c.maxSolutions:
          break
        var cl: seq[int] = @[]           # blocking clause
        for x in c.decisionVars:
          let v = s.solVals[x]
          cl.add s.leLit(x, v - 1)
          cl.add s.geLit(x, v + 1)
        s.addClause(cl)
        if not s.ok:
          complete = true
          break
      elif r == srUnsat:
        complete = true
        break
      else:
        break
  else:                                  # minimize / maximize
    let obj = c.objective
    while true:
      let r = s.solve()
      if r == srSat:
        inc nsol
        c.printSolution(true)
        let val = c.objValue()
        if obj.terms.len == 0:
          complete = true
          break
        if kind == "minimize":
          c.postLE(obj.terms, val - 1 - obj.k, litTrue)
        else:
          c.postLE(negTerms(obj.terms), obj.k - val - 1, litTrue)
        if not s.ok:
          complete = true
          break
      elif r == srUnsat:
        complete = true
        break
      else:
        break
  if nsol == 0:
    echo(if complete: "=====UNSATISFIABLE=====" else: "=====UNKNOWN=====")
  elif complete and kind != "satisfy":
    echo "=========="
  if c.showStats or statsOverride:
    stderr.writeLine s.statsString()
    stderr.writeLine "% solutions: " & $nsol & ", time: " &
      formatFloat(epochTime() - t0, ffDecimal, 3) & " s"

proc compileModel*(src: string): Compiler =
  # Parses the text of a model and posts all its constraints.
  let toks = lex(src)
  var p = Parser(toks: toks, pos: 0)
  var prog: seq[Stmt] = @[]
  while p.peek().kind != tkEof:
    prog.add p.parseStmt()
  let c = Compiler(s: newSolver())
  c.scopes = @[initTable[string, Value]()]
  c.litIntCache = initTable[int, int]()
  for st in prog:
    c.execStmt(st)
  result = c
