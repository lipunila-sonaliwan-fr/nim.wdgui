# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
#   wdlua - IDE : diagnostics, structure (outline) et index des symboles
#
# Les erreurs de syntaxe viennent du vrai analyseur de l'interpréteur
# (lua/parser.nim) : ce que l'IDE signale est exactement ce qui empêcherait
# l'exécution. S'y ajoutent des contrôles heuristiques :
#   - appel d'une fonction définie nulle part (projet, bibliothèques, paquets) ;
#   - option : signaler les extensions du manuel (+=, !=, \, ?, formes courtes),
#     utile pour écrire du Lua 5.4 portable.

import std/[strutils, sets, tables, os, algorithm]
import lualang
from ../lua/parser import parseChunk
from ../lua/lexer import SyntaxError

type
  Severity* = enum sevError = "Erreur", sevWarning = "Avertissement", sevInfo = "Info"

  Diagnostic* = object
    line*, col*, len*: int      # 0-based.
    sev*: Severity
    msg*: string

  SymKind* = enum skFunction = "fonction", skLocalFunction = "fonction locale",
                  skGlobal = "globale", skLocal = "locale"

  Symbol* = object
    name*: string
    display*: string
    kind*: SymKind
    line*, col*: int

  LintOptions* = object
    flagExtensions*: bool
    unknownCalls*: bool

  Sig = object
    kind: TokKind
    text: string
    line, col: int

proc significant(lines: openArray[string], toks: openArray[seq[Token]]): seq[Sig] =
  for li in 0 ..< min(lines.len, toks.len):
    for t in toks[li]:
      if t.kind notin {tkSpace, tkComment, tkPod}:
        result.add Sig(kind: t.kind, text: tokText(lines[li], t), line: li, col: t.start)

proc isKw(s: Sig, w: string): bool {.inline.} = s.kind == tkKeyword and s.text == w

proc readFuncName(sigs: seq[Sig], i: int): (string, string, int) =
  var j = i
  var full, last = ""
  while j < sigs.len and sigs[j].kind in {tkIdent, tkBuiltin, tkCallback}:
    full.add sigs[j].text
    last = sigs[j].text
    inc j
    if j < sigs.len and sigs[j].kind == tkOperator and sigs[j].text in [".", ":"]:
      full.add sigs[j].text
      inc j
    else: break
  (full, last, j)

proc readParams(sigs: seq[Sig], i: int): (string, seq[string], int) =
  var j = i + 1
  var names, parts: seq[string]
  while j < sigs.len and not (sigs[j].kind == tkPunct and sigs[j].text == ")"):
    if sigs[j].kind in {tkIdent, tkBuiltin, tkCallback}: names.add sigs[j].text
    if sigs[j].text != ",": parts.add sigs[j].text
    inc j
  (parts.join(", "), names, j + 1)

proc collectSymbols*(lines: openArray[string], toks: openArray[seq[Token]]):
    (seq[Symbol], HashSet[string]) =
  # Définitions affichables et ensemble de tous les noms définis.
  let sigs = significant(lines, toks)
  var syms: seq[Symbol]
  var names = initHashSet[string]()
  var seenGlobals = initHashSet[string]()
  var i = 0
  while i < sigs.len:
    let s = sigs[i]
    if s.isKw("function"):
      let isLocal = i > 0 and sigs[i - 1].isKw("local")
      let (full, last, j) = readFuncName(sigs, i + 1)
      var params = ""
      if j < sigs.len and sigs[j].text == "(":
        let (p, pnames, _) = readParams(sigs, j)
        params = p
        for n in pnames: names.incl n
      if full.len > 0:
        names.incl full.split({'.', ':'})[0]
        names.incl last
        syms.add Symbol(name: last, display: full & "(" & params & ")",
                        kind: (if isLocal: skLocalFunction else: skFunction),
                        line: s.line, col: s.col)
      i = max(j, i + 1)
      continue
    elif s.isKw("local") or s.isKw("for"):
      var j = i + 1
      while j < sigs.len and sigs[j].kind in {tkIdent, tkBuiltin, tkCallback}:
        names.incl sigs[j].text
        inc j
        if j + 2 < sigs.len and sigs[j].text == "<" and sigs[j + 2].text == ">": j += 3
        if j < sigs.len and sigs[j].text == ",": inc j
        else: break
    elif s.kind in {tkIdent, tkCallback, tkBuiltin} and i + 1 < sigs.len and
         sigs[i + 1].text in ["=", ",", "+=", "-=", "..="] and
         (i == 0 or sigs[i - 1].text notin [".", ":"]):
      names.incl s.text
      let isLocal = i > 0 and sigs[i - 1].isKw("local")
      if sigs[i + 1].text == "=" and not isLocal and s.text notin seenGlobals and
         (i == 0 or sigs[i - 1].text != ","):
        seenGlobals.incl s.text
        let isFn = i + 2 < sigs.len and sigs[i + 2].isKw("function")
        var disp = s.text
        if isFn and i + 3 < sigs.len and sigs[i + 3].text == "(":
          let (p, pnames, _) = readParams(sigs, i + 3)
          disp.add "(" & p & ")"
          for n in pnames: names.incl n
        syms.add Symbol(name: s.text, display: disp,
                        kind: (if isFn: skFunction else: skGlobal), line: s.line, col: s.col)
    inc i
  (syms, names)

proc syntaxCheck*(text, source: string): (bool, int, string) =
  # (ok, ligne 0-based, message) avec le vrai analyseur.
  try:
    discard parseChunk(text, source)
    result = (true, 0, "")
  except SyntaxError as e:
    var msg = e.msg
    let prefix = source & ":" & $e.line & ": "
    if msg.startsWith(prefix): msg = msg[prefix.len .. ^1]
    result = (false, max(0, e.line - 1), msg)

proc lint*(lines: openArray[string], toks: openArray[seq[Token]],
           knownNames: HashSet[string], opts: LintOptions, source = "fichier"): seq[Diagnostic] =
  var diags: seq[Diagnostic]
  template report(l, c, n: int, s: Severity, m: string) =
    diags.add Diagnostic(line: l, col: c, len: max(1, n), sev: s, msg: m)

  # 1. syntaxe : selon l'analyseur de l'interpréteur.
  let (ok, eline, emsg) = syntaxCheck(lines.join("\n"), source)
  if not ok:
    var col = 0
    var n = 1
    if eline < lines.len:
      col = lines[eline].len - lines[eline].strip(trailing = false).len
      n = max(1, lines[eline].strip().len)
    report(eline, col, n, sevError, emsg)

  let sigs = significant(lines, toks)
  # 2. extensions du manuel.
  if opts.flagExtensions:
    for s in sigs:
      if s.kind == tkPicoOp:
        report(s.line, s.col, s.text.len, sevInfo,
          "Extension du manuel « " & s.text & " » (non valide en Lua 5.4 standard)")

  # 3. appels inconnus (seulement si la syntaxe est correcte).
  if ok and opts.unknownCalls:
    for i, s in sigs:
      if s.kind == tkIdent and i + 1 < sigs.len and sigs[i + 1].line == s.line and
         (sigs[i + 1].text == "(" or sigs[i + 1].kind == tkString or sigs[i + 1].text == "{") and
         (i == 0 or sigs[i - 1].text notin [".", ":"]) and
         not (i > 0 and sigs[i - 1].isKw("function")) and
         s.text notin knownNames:
        report(s.line, s.col, s.text.len, sevWarning,
          "« " & s.text & " » n'est défini ni dans le projet, ni dans les bibliothèques et paquets")

  diags.sort(proc (a, b: Diagnostic): int =
    result = cmp(a.line, b.line)
    if result == 0: result = cmp(a.col, b.col))
  diags

#
# Index de projet
#

type
  Location* = object
    file*: string
    line*, col*: int

  ProjectIndex* = object
    defs*: Table[string, seq[Location]]
    names*: HashSet[string]

proc initProjectIndex*(): ProjectIndex =
  ProjectIndex(defs: initTable[string, seq[Location]](), names: initHashSet[string]())

proc indexFile*(idx: var ProjectIndex, path: string, text: string) =
  let lines = text.splitLines()
  let (toks, _) = lexAll(lines)
  let (syms, names) = collectSymbols(lines, toks)
  for n in names: idx.names.incl n
  for s in syms:
    idx.defs.mgetOrPut(s.name, @[]).add Location(file: path, line: s.line, col: s.col)

proc indexProject*(root: string): ProjectIndex =
  result = initProjectIndex()
  if root.len == 0 or not dirExists(root): return
  for f in walkDirRec(root):
    if f.endsWith(".lua"):
      try: result.indexFile(f, readFile(f))
      except IOError, OSError: discard

proc knownNamesFor*(idx: ProjectIndex, local: HashSet[string]): HashSet[string] =
  result = local
  for n in idx.names: result.incl n
