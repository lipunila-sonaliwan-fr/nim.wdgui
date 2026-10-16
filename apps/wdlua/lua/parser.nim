# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
#   wdlua - analyseur syntaxique
#
# Produit l'arbre de `core` en résolvant chaque nom : variable locale
# (case du cadre d'appel), upvalue (cellule capturée) ou globale.
# Formes du manuel prises en charge en plus de Lua 5.4 (§9.2) :
#   if (cond) instr [else instr]       sur une seule ligne, sans then/end
#   while (cond) instr                 sur une seule ligne, sans do/end
#   a += 1, s ..= "x", n //= 2 ...     affectations composées
#   ?expr, ...                         raccourci pour print
# goto et les étiquettes ne font pas partie du langage décrit : refusés.

import std/strutils
import core, lexer

type
  Scope = object
    names: seq[(string, int)]

  FuncState = ref object
    parent: FuncState
    proto: Proto
    scopes: seq[Scope]
    loops: int

  Parser = object
    toks: seq[Tok]
    p: int
    fs: FuncState
    source: string

const
  CompoundOps = ["+=", "-=", "*=", "/=", "//=", "%=", "^=", "..=", "&=", "|=", "<<=", ">>="]

proc cur(ps: Parser): Tok {.inline.} = ps.toks[ps.p]
proc peekTok(ps: Parser, k = 1): Tok {.inline.} = ps.toks[min(ps.p + k, ps.toks.high)]
proc advance(ps: var Parser): Tok {.discardable.} =
  result = ps.toks[ps.p]
  if ps.p < ps.toks.high: inc ps.p

proc err(ps: Parser, msg: string) {.noreturn.} =
  let t = ps.cur
  let near = if t.kind == tkEOF: "fin du fichier" else: "« " & (if t.kind == tkString: "\"" & t.text & "\"" else: t.text) & " »"
  synErr(ps.source, t.line, msg & " près de " & near)

proc isOp(ps: Parser, s: string): bool {.inline.} = ps.cur.kind == tkOp and ps.cur.text == s
proc isKw(ps: Parser, s: string): bool {.inline.} = ps.cur.kind == tkKeyword and ps.cur.text == s

proc expectOp(ps: var Parser, s: string, what = "") =
  if not ps.isOp(s): ps.err("« " & s & " » attendu" & (if what.len > 0: " " & what else: ""))
  ps.advance()

proc expectKw(ps: var Parser, s: string, openLine = 0, opener = "") =
  if not ps.isKw(s):
    if openLine > 0:
      ps.err("« " & s & " » attendu (pour fermer « " & opener & " » ligne " & $openLine & ")")
    ps.err("« " & s & " » attendu")
  ps.advance()

proc expectName(ps: var Parser): string =
  if ps.cur.kind != tkName: ps.err("nom attendu")
  ps.advance().text

# portée

proc openScope(ps: var Parser) = ps.fs.scopes.add Scope()
proc closeScope(ps: var Parser) = discard ps.fs.scopes.pop()

proc declare(ps: var Parser, name: string): int =
  let pr = ps.fs.proto
  result = pr.nslots
  inc pr.nslots
  pr.slotNames.add name
  ps.fs.scopes[^1].names.add (name, result)

proc findLocal(fs: FuncState, name: string): int =
  for si in countdown(fs.scopes.high, 0):
    let sc = fs.scopes[si]
    for ni in countdown(sc.names.high, 0):
      if sc.names[ni][0] == name: return sc.names[ni][1]
  -1

proc findUp(fs: FuncState, name: string): int =
  for i, u in fs.proto.ups:
    if u.name == name: return i
  if fs.parent.isNil: return -1
  let l = findLocal(fs.parent, name)
  if l >= 0:
    fs.proto.ups.add UpDesc(fromLocal: true, index: l, name: name)
    return fs.proto.ups.high
  let u = findUp(fs.parent, name)
  if u >= 0:
    fs.proto.ups.add UpDesc(fromLocal: false, index: u, name: name)
    return fs.proto.ups.high
  -1

proc resolve(ps: var Parser, name: string, line: int): Expr =
  let l = findLocal(ps.fs, name)
  if l >= 0: return Expr(kind: ekLocal, slot: l, vname: name, line: line)
  let u = findUp(ps.fs, name)
  if u >= 0: return Expr(kind: ekUpval, slot: u, vname: name, line: line)
  Expr(kind: ekGlobal, gname: name, line: line)

# expressions

proc expr(ps: var Parser, limit = 0): Expr
proc blockUntil(ps: var Parser): seq[Stmt]
proc funcBody(ps: var Parser, name: string, isMethod: bool, line: int): Proto

proc exprList(ps: var Parser): seq[Expr] =
  result.add ps.expr()
  while ps.isOp(","):
    ps.advance()
    result.add ps.expr()

proc tableCons(ps: var Parser): Expr =
  let line = ps.cur.line
  ps.expectOp("{")
  result = Expr(kind: ekTable, line: line)
  while not ps.isOp("}"):
    if ps.isOp("["):
      ps.advance()
      let k = ps.expr()
      ps.expectOp("]")
      ps.expectOp("=")
      result.items.add TItem(keyed: true, key: k, val: ps.expr())
    elif ps.cur.kind == tkName and ps.peekTok().kind == tkOp and ps.peekTok().text == "=":
      let nameTok = ps.advance()
      ps.advance()
      result.items.add TItem(keyed: true, key: Expr(kind: ekStr, sval: nameTok.text, line: nameTok.line),
                             val: ps.expr())
    else:
      result.items.add TItem(keyed: false, val: ps.expr())
    if ps.isOp(",") or ps.isOp(";"): ps.advance()
    elif not ps.isOp("}"): ps.err("« } » attendu (constructeur de table ouvert ligne " & $line & ")")
  ps.advance()

proc callArgs(ps: var Parser): seq[Expr] =
  let t = ps.cur
  if t.kind == tkString:
    ps.advance()
    return @[Expr(kind: ekStr, sval: t.text, line: t.line)]
  if ps.isOp("{"): return @[ps.tableCons()]
  ps.expectOp("(")
  if not ps.isOp(")"): result = ps.exprList()
  ps.expectOp(")", "pour fermer l'appel")

proc primary(ps: var Parser): Expr =
  let t = ps.cur
  if t.kind == tkName:
    ps.advance()
    return ps.resolve(t.text, t.line)
  if ps.isOp("("):
    ps.advance()
    let e = ps.expr()
    ps.expectOp(")")
    return Expr(kind: ekParen, e: e, line: t.line)
  ps.err("expression inattendue")

proc suffixed(ps: var Parser): Expr =
  result = ps.primary()
  while true:
    let t = ps.cur
    if ps.isOp("."):
      ps.advance()
      let name = ps.expectName()
      result = Expr(kind: ekIndex, obj: result, key: Expr(kind: ekStr, sval: name, line: t.line), line: t.line)
    elif ps.isOp("["):
      ps.advance()
      let k = ps.expr()
      ps.expectOp("]")
      result = Expr(kind: ekIndex, obj: result, key: k, line: t.line)
    elif ps.isOp(":"):
      ps.advance()
      let name = ps.expectName()
      result = Expr(kind: ekMethod, mobj: result, mname: name, margs: ps.callArgs(), line: t.line)
    elif ps.isOp("(") or ps.isOp("{") or t.kind == tkString:
      # un " ( " en début de ligne commence une nouvelle instruction (comme Lua le signale).
      if ps.isOp("(") and t.line != ps.toks[ps.p - 1].line: return
      result = Expr(kind: ekCall, fn: result, args: ps.callArgs(), line: t.line)
    else:
      return

proc simple(ps: var Parser): Expr =
  let t = ps.cur
  case t.kind
  of tkInt:
    ps.advance()
    Expr(kind: ekInt, ival: t.ival, line: t.line)
  of tkNum:
    ps.advance()
    Expr(kind: ekNum, nval: t.nval, line: t.line)
  of tkString:
    ps.advance()
    Expr(kind: ekStr, sval: t.text, line: t.line)
  of tkKeyword:
    case t.text
    of "nil":
      ps.advance()
      Expr(kind: ekNil, line: t.line)
    of "true":
      ps.advance()
      Expr(kind: ekTrue, line: t.line)
    of "false":
      ps.advance()
      Expr(kind: ekFalse, line: t.line)
    of "function":
      ps.advance()
      Expr(kind: ekFunc, fproto: ps.funcBody("fonction anonyme", false, t.line), line: t.line)
    else:
      ps.err("expression attendue")
  of tkOp:
    if t.text == "...":
      if not ps.fs.proto.vararg: ps.err("« ... » hors d'une fonction variadique")
      ps.advance()
      Expr(kind: ekVararg, line: t.line)
    elif t.text == "{":
      ps.tableCons()
    else:
      ps.suffixed()
  else:
    ps.suffixed()

proc binPrio(t: Tok): (int, int, BinOp) =
  # (priorité gauche, priorité droite, opérateur) ; (0, 0, _) si non binaire.
  if t.kind == tkKeyword:
    if t.text == "or": return (1, 1, opEq)
    if t.text == "and": return (2, 2, opEq)
    return (0, 0, opEq)
  if t.kind != tkOp: return (0, 0, opEq)
  case t.text
  of "<": (3, 3, opLt)
  of ">": (3, 3, opGt)
  of "<=": (3, 3, opLe)
  of ">=": (3, 3, opGe)
  of "~=": (3, 3, opNe)
  of "==": (3, 3, opEq)
  of "|": (4, 4, opBOr)
  of "~": (5, 5, opBXor)
  of "&": (6, 6, opBAnd)
  of "<<": (7, 7, opShl)
  of ">>": (7, 7, opShr)
  of "..": (9, 8, opConcat)
  of "+": (10, 10, opAdd)
  of "-": (10, 10, opSub)
  of "*": (11, 11, opMul)
  of "/": (11, 11, opDiv)
  of "//": (11, 11, opIDiv)
  of "%": (11, 11, opMod)
  of "^": (14, 13, opPow)
  else: (0, 0, opEq)

const UnaryPrio = 12

proc expr(ps: var Parser, limit = 0): Expr =
  let t = ps.cur
  if (t.kind == tkKeyword and t.text == "not") or
     (t.kind == tkOp and t.text in ["-", "#", "~"]):
    ps.advance()
    let operand = ps.expr(UnaryPrio)
    let k = if t.text == "not": ekNot elif t.text == "-": ekNeg elif t.text == "#": ekLen else: ekBNot
    # constante négative directe
    if k == ekNeg and operand.kind == ekInt:
      result = Expr(kind: ekInt, ival: cast[int64](0'u64 - cast[uint64](operand.ival)), line: t.line)
    elif k == ekNeg and operand.kind == ekNum:
      result = Expr(kind: ekNum, nval: -operand.nval, line: t.line)
    else:
      case k
      of ekNot: result = Expr(kind: ekNot, e: operand, line: t.line)
      of ekNeg: result = Expr(kind: ekNeg, e: operand, line: t.line)
      of ekLen: result = Expr(kind: ekLen, e: operand, line: t.line)
      else: result = Expr(kind: ekBNot, e: operand, line: t.line)
  else:
    result = ps.simple()
  while true:
    let opTok = ps.cur
    let (lp, rp, op) = binPrio(opTok)
    if lp <= limit: break
    ps.advance()
    let rhs = ps.expr(rp)
    if opTok.kind == tkKeyword:
      if opTok.text == "or": result = Expr(kind: ekOr, a: result, b: rhs, line: opTok.line)
      else: result = Expr(kind: ekAnd, a: result, b: rhs, line: opTok.line)
    else:
      result = Expr(kind: ekBin, op: op, lhs: result, rhs: rhs, line: opTok.line)

proc funcBody(ps: var Parser, name: string, isMethod: bool, line: int): Proto =
  let pr = Proto(name: name, source: ps.source, line: line)
  let fs = FuncState(parent: ps.fs, proto: pr)
  ps.fs = fs
  ps.openScope()
  if isMethod:
    discard ps.declare("self")
    inc pr.nparams
  ps.expectOp("(", "pour les paramètres")
  if not ps.isOp(")"):
    while true:
      if ps.isOp("..."):
        ps.advance()
        pr.vararg = true
        break
      discard ps.declare(ps.expectName())
      inc pr.nparams
      if ps.isOp(","): ps.advance() else: break
  ps.expectOp(")")
  pr.body = ps.blockUntil()
  pr.lastLine = ps.cur.line
  ps.expectKw("end", line, "function")
  ps.closeScope()
  ps.fs = fs.parent
  pr

# instructions

proc statement(ps: var Parser): Stmt

proc isBlockEnd(ps: Parser): bool =
  let t = ps.cur
  t.kind == tkEOF or (t.kind == tkKeyword and t.text in ["end", "else", "elseif", "until"])

proc blockUntil(ps: var Parser): seq[Stmt] =
  while not ps.isBlockEnd():
    if ps.isKw("return"):
      let line = ps.cur.line
      ps.advance()
      var exprs: seq[Expr]
      if not ps.isBlockEnd() and not ps.isOp(";"): exprs = ps.exprList()
      if ps.isOp(";"): ps.advance()
      result.add Stmt(kind: skReturn, rexprs: exprs, line: line)
      if not ps.isBlockEnd(): ps.err("« return » doit être la dernière instruction du bloc")
      break
    let s = ps.statement()
    if not s.isNil: result.add s

proc sameLineHas(ps: Parser, word: string): bool =
  # Le mot-clé `word` apparaît-il sur la ligne du jeton courant ?
  let ln = ps.toks[ps.p - 1].line
  var i = ps.p
  while i < ps.toks.len and ps.toks[i].line == ln and ps.toks[i].kind != tkEOF:
    if ps.toks[i].kind == tkKeyword and ps.toks[i].text == word: return true
    inc i
  false

proc shortBody(ps: var Parser, line: int): seq[Stmt] =
  # Instructions restant sur la ligne `line` (forme courte du manuel).
  while ps.cur.line == line and not ps.isBlockEnd():
    if ps.isKw("return") or ps.isKw("break"):
      let t = ps.advance()
      if t.text == "break":
        if ps.fs.loops == 0: ps.err("« break » hors d'une boucle")
        result.add Stmt(kind: skBreak, line: t.line)
      else:
        var exprs: seq[Expr]
        if ps.cur.line == line and not ps.isBlockEnd(): exprs = ps.exprList()
        result.add Stmt(kind: skReturn, rexprs: exprs, line: t.line)
      continue
    let s = ps.statement()
    if not s.isNil: result.add s

proc ifStat(ps: var Parser): Stmt =
  let t = ps.advance()               # if.
  result = Stmt(kind: skIf, line: t.line)
  if not ps.sameLineHas("then"):
    # forme courte : if (cond) instr [else instr].
    if not ps.isOp("("): ps.err("« then » attendu, ou forme courte « if (condition) instruction »")
    result.conds.add ps.expr()
    result.blocks.add ps.shortBody(t.line)
    if ps.isKw("else") and ps.cur.line == t.line:
      ps.advance()
      result.elseBlock = ps.shortBody(t.line)
    return
  result.conds.add ps.expr()
  ps.expectKw("then")
  ps.openScope()
  result.blocks.add ps.blockUntil()
  ps.closeScope()
  while ps.isKw("elseif"):
    ps.advance()
    result.conds.add ps.expr()
    ps.expectKw("then")
    ps.openScope()
    result.blocks.add ps.blockUntil()
    ps.closeScope()
  if ps.isKw("else"):
    ps.advance()
    ps.openScope()
    result.elseBlock = ps.blockUntil()
    ps.closeScope()
  ps.expectKw("end", t.line, "if")

proc whileStat(ps: var Parser): Stmt =
  let t = ps.advance()
  result = Stmt(kind: skWhile, line: t.line)
  inc ps.fs.loops
  if not ps.sameLineHas("do"):
    if not ps.isOp("("): ps.err("« do » attendu, ou forme courte « while (condition) instruction »")
    result.wcond = ps.expr()
    result.wbody = ps.shortBody(t.line)
  else:
    result.wcond = ps.expr()
    ps.expectKw("do")
    ps.openScope()
    result.wbody = ps.blockUntil()
    ps.closeScope()
    ps.expectKw("end", t.line, "while")
  dec ps.fs.loops

proc forStat(ps: var Parser): Stmt =
  let t = ps.advance()
  let n1 = ps.expectName()
  if ps.isOp("="):
    ps.advance()
    let a = ps.expr()
    ps.expectOp(",")
    let b = ps.expr()
    var c: Expr = nil
    if ps.isOp(","):
      ps.advance()
      c = ps.expr()
    ps.expectKw("do")
    ps.openScope()
    let slot = ps.declare(n1)
    inc ps.fs.loops
    let body = ps.blockUntil()
    dec ps.fs.loops
    ps.closeScope()
    ps.expectKw("end", t.line, "for")
    return Stmt(kind: skNumFor, fslot: slot, fstart: a, fstop: b, fstep: c, fbody: body, line: t.line)
  var names = @[n1]
  while ps.isOp(","):
    ps.advance()
    names.add ps.expectName()
  ps.expectKw("in")
  let exprs = ps.exprList()
  ps.expectKw("do")
  ps.openScope()
  var slots: seq[int]
  for nm in names: slots.add ps.declare(nm)
  inc ps.fs.loops
  let body = ps.blockUntil()
  dec ps.fs.loops
  ps.closeScope()
  ps.expectKw("end", t.line, "for")
  Stmt(kind: skGenFor, gslots: slots, gexprs: exprs, gbody: body, line: t.line)

proc isAssignable(e: Expr): bool = e.kind in {ekLocal, ekUpval, ekGlobal, ekIndex}

proc compoundOp(s: string): BinOp =
  case s
  of "+=": opAdd
  of "-=": opSub
  of "*=": opMul
  of "/=": opDiv
  of "//=": opIDiv
  of "%=": opMod
  of "^=": opPow
  of "..=": opConcat
  of "&=": opBAnd
  of "|=": opBOr
  of "<<=": opShl
  else: opShr

proc statement(ps: var Parser): Stmt =
  let t = ps.cur
  if t.kind == tkOp:
    case t.text
    of ";":
      ps.advance()
      return nil
    of "::":
      ps.err("les étiquettes (goto) ne font pas partie du langage")
    of "?":
      # raccourci du manuel : ?expr  ==  print(expr).
      ps.advance()
      let args = ps.exprList()
      return Stmt(kind: skCall, line: t.line,
                  call: Expr(kind: ekCall, fn: Expr(kind: ekGlobal, gname: "print", line: t.line),
                             args: args, line: t.line))
    else: discard
  if t.kind == tkKeyword:
    case t.text
    of "if": return ps.ifStat()
    of "while": return ps.whileStat()
    of "for": return ps.forStat()
    of "do":
      ps.advance()
      ps.openScope()
      let b = ps.blockUntil()
      ps.closeScope()
      ps.expectKw("end", t.line, "do")
      return Stmt(kind: skDo, body: b, line: t.line)
    of "repeat":
      ps.advance()
      inc ps.fs.loops
      ps.openScope()
      let b = ps.blockUntil()
      ps.expectKw("until", t.line, "repeat")
      let c = ps.expr()                    # voit les locales du bloc.
      ps.closeScope()
      dec ps.fs.loops
      return Stmt(kind: skRepeat, rbody: b, rcond: c, line: t.line)
    of "function":
      ps.advance()
      let nt = ps.cur
      var target = ps.resolve(ps.expectName(), nt.line)
      var fullName = nt.text
      var isMethod = false
      while ps.isOp(".") or ps.isOp(":"):
        let sep = ps.advance().text
        let k = ps.expectName()
        fullName.add sep & k
        target = Expr(kind: ekIndex, obj: target, key: Expr(kind: ekStr, sval: k, line: nt.line), line: nt.line)
        if sep == ":":
          isMethod = true
          break
      let pr = ps.funcBody(fullName, isMethod, t.line)
      return Stmt(kind: skAssign, targets: @[target],
                  values: @[Expr(kind: ekFunc, fproto: pr, line: t.line)], line: t.line)
    of "local":
      ps.advance()
      if ps.isKw("function"):
        ps.advance()
        let name = ps.expectName()
        let slot = ps.declare(name)           # déclarée avant le corps : récursion possible.
        let pr = ps.funcBody(name, false, t.line)
        return Stmt(kind: skLocalFunc, lfslot: slot, lfunc: pr, line: t.line)
      var names: seq[string]
      while true:
        names.add ps.expectName()
        if ps.isOp("<"):
          ps.advance()
          let attr = ps.expectName()
          if attr != "const": ps.err("attribut « " & attr & " » non pris en charge (seul <const> l'est)")
          ps.expectOp(">")
        if ps.isOp(","): ps.advance() else: break
      var exprs: seq[Expr]
      if ps.isOp("="):
        ps.advance()
        exprs = ps.exprList()
      var slots: seq[int]
      for nm in names: slots.add ps.declare(nm)   # après les expressions : local x =...
      return Stmt(kind: skLocal, lslots: slots, lexprs: exprs, line: t.line)
    of "break":
      ps.advance()
      if ps.fs.loops == 0: ps.err("« break » hors d'une boucle")
      return Stmt(kind: skBreak, line: t.line)
    of "goto":
      ps.err("goto ne fait pas partie du langage")
    of "return":
      ps.err("« return » doit être la dernière instruction du bloc")
    else:
      ps.err("instruction inattendue")
  # instruction-expression : appel ou affectation.
  let e = ps.suffixed()
  if ps.isOp("=") or ps.isOp(","):
    var targets = @[e]
    while ps.isOp(","):
      ps.advance()
      targets.add ps.suffixed()
    ps.expectOp("=")
    for tg in targets:
      if not tg.isAssignable: synErr(ps.source, t.line, "impossible d'affecter cette expression")
    return Stmt(kind: skAssign, targets: targets, values: ps.exprList(), line: t.line)
  if ps.cur.kind == tkOp and ps.cur.text in CompoundOps:
    let op = compoundOp(ps.advance().text)
    if not e.isAssignable: synErr(ps.source, t.line, "impossible d'affecter cette expression")
    return Stmt(kind: skCompound, ctarget: e, cop: op, cval: ps.expr(), line: t.line)
  if e.kind notin {ekCall, ekMethod}:
    ps.err("instruction incomplète (affectation ou appel attendu)")
  Stmt(kind: skCall, call: e, line: t.line)

proc parseChunk*(src, source: string): Proto =
  # Compile un fichier ; lève SyntaxError (message " source:ligne: ... ").
  var ps = Parser(toks: tokenize(src, source), source: source)
  let pr = Proto(name: "programme principal", source: source, line: 1, vararg: true)
  ps.fs = FuncState(proto: pr)
  ps.openScope()
  pr.body = ps.blockUntil()
  if ps.cur.kind != tkEOF:
    ps.err("« " & ps.cur.text & " » inattendu (aucun bloc ouvert à fermer)")
  pr.lastLine = ps.cur.line
  pr
