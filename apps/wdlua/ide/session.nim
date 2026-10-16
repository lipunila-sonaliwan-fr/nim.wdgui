# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
#   wdlua - IDE : session d'exécution et de débogage
#
# Une session exécute un programme dans un interpréteur neuf, avec tous les
# paquets. Elle tourne sur le thread du gestionnaire qui l'a lancée (étape 6
# du tutoriel wdgui : un gestionnaire peut durer longtemps) ; les commandes
# Continuer / Pas à pas / Pause / Arrêter arrivent par d'autres gestionnaires.
#
# Les fenêtres créées par le programme (paquet ui) vivent dans l'application
# de l'IDE ; la session reste active tant qu'elles sont ouvertes.

import std/[locks, strutils, tables, sets, os, algorithm, atomics]
import ../lua/[api, stdlib]
import ../packages/all
from ../lua/lexer import SyntaxError

type
  VarInfo* = object
    name*, value*, kind*, scope*: string

  FrameInfo* = object
    name*, source*: string
    line*: int                   # 1-based.
    vars*: seq[VarInfo]

  PauseInfo* = object
    source*: string
    line*: int                   # 1-based.
    frames*: seq[FrameInfo]      # [0] = cadre courant.
    globals*: seq[VarInfo]

  SessionHooks* = object
    output*: proc (s: string) {.closure, gcsafe.}
    input*: proc (prompt: string): (bool, string) {.closure, gcsafe.}
    paused*: proc (info: PauseInfo) {.closure, gcsafe.}
    finished*: proc (ok: bool, msg, source: string, line: int) {.closure, gcsafe.}
    sourceProvider*: proc (path: string): (bool, string) {.closure, gcsafe.}
    breakpoints*: proc (): seq[(string, seq[int])] {.closure, gcsafe.}

var sLock: Lock
var current: Interp
initLock(sLock)

proc active*(): bool =
  {.cast(gcsafe).}:
    withLock sLock: result = not current.isNil

proc withCurrent(body: proc (L: Interp) {.closure.}) =
  {.cast(gcsafe).}:
    var L: Interp
    withLock sLock: L = current
    if not L.isNil: body(L)

#
# Instantané des variables
#

proc short(L: Interp, v: Value, depth = 0): string =
  case v.kind
  of vkStr:
    var s = v.s
    if s.len > 80: s = s[0 ..< 80] & "…"
    "\"" & s.replace("\n", "\\n") & "\""
  of vkTable:
    if depth > 0: return "{…}"
    var parts: seq[string]
    var n = 0
    for k, x in v.t.pairs:
      inc n
      if parts.len < 8:
        let ks = if k.kind == vkStr: k.s else: "[" & rawToString(k) & "]"
        parts.add ks & "=" & L.short(x, depth + 1)
    "{" & parts.join(", ") & (if n > 8: ", … (" & $n & ")" else: "") & "}"
  of vkFunc:
    if v.f.native: "fonction native " & v.f.name else: "function " & v.f.name
  of vkUser: rawToString(v)
  else: rawToString(v)

proc kindOf(v: Value): string =
  case v.kind
  of vkInt: "integer"
  of vkNum: "float"
  else: typeName(v)

proc frameVars(L: Interp, f: Frame): seq[VarInfo] =
  if f.proto.isNil: return
  for i, c in f.slots:
    if not c.isNil and i < f.proto.slotNames.len:
      result.add VarInfo(name: f.proto.slotNames[i], value: L.short(c.v), kind: kindOf(c.v), scope: "locale")
  for i, u in f.proto.ups:
    if i < f.upvals.len and not f.upvals[i].isNil:
      result.add VarInfo(name: u.name, value: L.short(f.upvals[i].v), kind: kindOf(f.upvals[i].v), scope: "upvalue")
  for i, v in f.varargs:
    result.add VarInfo(name: "...[" & $(i + 1) & "]", value: L.short(v), kind: kindOf(v), scope: "vararg")

proc snapshot(L: Interp, c: Ctx, builtin: HashSet[string]): PauseInfo =
  for i in countdown(c.frames.high, 0):
    let f = c.frames[i]
    if f.proto.isNil: continue
    result.frames.add FrameInfo(name: (if f.fnName.len > 0: f.fnName else: f.proto.name),
                                source: f.proto.source, line: f.line, vars: L.frameVars(f))
  if result.frames.len > 0:
    result.source = result.frames[0].source
    result.line = result.frames[0].line
  for k, v in L.globals.pairs:
    if k.kind == vkStr and k.s notin builtin:
      result.globals.add VarInfo(name: k.s, value: L.short(v), kind: kindOf(v), scope: "globale")
  result.globals.sort(proc (a, b: VarInfo): int = cmp(a.name, b.name))

#
# Commandes
#

proc debugCommand*(mode: StepMode) =
  withCurrent(proc (L: Interp) =
    if not L.dbg.isNil: L.dbg.command(mode))

proc pauseProgram*() =
  withCurrent(proc (L: Interp) =
    if not L.dbg.isNil:
      L.dbg.active = true
      L.dbg.requestPause())

proc stopProgram*() =
  withCurrent(proc (L: Interp) =
    L.requestStop()
    if not L.dbg.isNil: L.dbg.command(smRun)
    L.closeAllWindows())

proc updateBreakpoints*(source: string, lines: seq[int]) =
  ## lines : 1-based.
  withCurrent(proc (L: Interp) =
    if not L.dbg.isNil: L.dbg.setBreakpoints(source, lines))

#
# Exécution
#

proc locate(msg: string): (string, int) =
  ## « source:ligne: message » -> (source, ligne)
  var i = msg.find(".lua:")
  if i < 0:
    # source sans extension (document non enregistré) : chercher " :N: ".
    var j = 0
    while j < msg.len:
      let c = msg.find(':', j)
      if c < 0: break
      var k = c + 1
      var n = 0
      while k < msg.len and msg[k] in Digits:
        n = n * 10 + (ord(msg[k]) - ord('0'))
        inc k
      if k > c + 1 and k < msg.len and msg[k] == ':': return (msg[0 ..< c], n)
      j = c + 1
    return ("", 0)
  var k = i + 5
  var n = 0
  while k < msg.len and msg[k] in Digits:
    n = n * 10 + (ord(msg[k]) - ord('0'))
    inc k
  (msg[0 ..< i + 4], n)

proc runProgram*(path: string, args: seq[string], debug: bool, stepFirst: bool,
                 hooks: SessionHooks) =
  # Exécute `path` (bloquant). debug = débogueur actif ; stepFirst = pause
  # sur la première instruction.
  {.cast(gcsafe).}:
    var builtin = initHashSet[string]()
    let L = newFullInterp()
    for k, _ in L.globals.pairs:
      if k.kind == vkStr: builtin.incl k.s
    L.hosted = true
    L.scriptPath = path
    L.args = args
    L.searchDirs = @[path.parentDir]
    L.output = hooks.output
    L.errput = hooks.output
    L.input = hooks.input
    L.sourceProvider = hooks.sourceProvider
    L.onError = proc (msg: string) = hooks.output("\n[erreur] " & msg & "\n")
    if debug:
      let d = newDebugger()
      d.active = true
      d.mode = if stepFirst: smInto else: smRun
      for (src, lines) in hooks.breakpoints(): d.setBreakpoints(src, lines)
      d.onPause = proc (L: Interp, c: Ctx) = hooks.paused(snapshot(L, c, builtin))
      L.dbg = d
    withLock sLock: current = L
    var ok = true
    var msg = ""
    var src = ""
    var line = 0
    L.enter()
    curCtx = Ctx()
    try:
      var vargs: seq[Value]
      for a in args: vargs.add strV(a)
      discard L.runFile(path, vargs)
      if L.openWindows() > 0:
        hooks.output("[le programme attend la fermeture de ses fenêtres]\n")
        L.blocking:
          while L.openWindows() > 0 and not L.stopRequested(): sleep(30)
      msg = if L.stopRequested(): "arrêté" else: "terminé"
    except SyntaxError as e:
      ok = false
      msg = e.msg
      src = e.source
      line = e.line
    except LuaExit as e:
      msg = "os.exit(" & $e.code & ")"
    except LuaStop:
      msg = "arrêté"
    except LuaError as e:
      ok = false
      msg = e.msg & "\n" & e.traceback
      (src, line) = locate(e.msg)
    except IOError, OSError:
      ok = false
      msg = "lecture impossible : " & path
    except CatchableError as e:
      ok = false
      msg = e.msg
    L.closeAllWindows()
    L.shutdown()
    L.leave()
    withLock sLock: current = nil
    hooks.finished(ok, msg, src, line)
