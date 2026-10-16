# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
#   wdlua - paquet io : entrées/sorties standard et fichiers (API de Lua 5.4)
#
#   io.write(...)            écrit sur la sortie (console de l'IDE ou terminal)
#   io.read([fmt])           lit l'entrée : "l" ligne, "n" nombre, "L" ligne + \n
#   io.lines([path])         itérateur sur les lignes (fichier ou entrée)
#   io.open(path, [mode])    ouvre un fichier : "r", "w", "a", "rb", "wb", "r+"...
#   f:read(...) f:write(...) f:lines() f:seek([whence], [off]) f:flush() f:close()
#   io.stdout:write(...)  io.stderr:write(...)

import std/strutils
import ../lua/api

type
  LFile* = ref object of LUser
    f*: File
    closed*: bool
    isStd*: int          # 0 fichier, 1 stdout, 2 stderr, 3 stdin.

var fileMethods {.threadvar.}: LTable

proc checkFile(L: Interp, a: seq[Value], fname: string): LFile =
  result = checkUser[LFile](L, a, 1, fname, "fichier")
  if result.closed: rtError("tentative d'utiliser un fichier fermé")

proc readFmt(L: Interp, f: File, fmt: Value, eof: var bool): Value =
  if fmt.kind in {vkInt, vkNum}:
    var ok: bool
    let n = int(toInteger(fmt, ok))
    if n == 0: return (if f.endOfFile: nilV else: strV(""))
    var buf = newString(n)
    let got = f.readChars(toOpenArray(buf, 0, n - 1))
    if got == 0:
      eof = true
      return nilV
    buf.setLen(got)
    return strV(buf)
  var s = if fmt.kind == vkStr: fmt.s else: "l"
  if s.startsWith("*"): s = s[1 .. ^1]
  case (if s.len > 0: s[0] else: 'l')
  of 'a':
    strV(f.readAll())
  of 'l', 'L':
    var line: string
    if f.readLine(line): strV(if s[0] == 'L': line & "\n" else: line)
    else:
      eof = true
      nilV
  of 'n':
    var line: string
    if not f.readLine(line):
      eof = true
      return nilV
    let (ok, v) = str2number(line)
    if ok: v else: nilV
  else:
    rtError("format de lecture invalide « " & s & " »")

proc consoleRead(L: Interp, fmt: Value): Value =
  var s = if fmt.kind == vkStr: fmt.s else: "l"
  if s.startsWith("*"): s = s[1 .. ^1]
  var got: (bool, string)
  L.blocking:
    got = L.input("")
  if not got[0]: return nilV
  case (if s.len > 0: s[0] else: 'l')
  of 'n':
    let (ok, v) = str2number(got[1])
    if ok: v else: nilV
  of 'L': strV(got[1] & "\n")
  else: strV(got[1])

proc writeTo(L: Interp, h: LFile, a: seq[Value], start: int) =
  for i in start .. a.len:
    let v = a[i - 1]
    if v.kind notin {vkStr, vkInt, vkNum}: argError(i, "write", "chaîne ou nombre attendu")
    let s = rawToString(v)
    case h.isStd
    of 1: L.output(s)
    of 2: L.errput(s)
    else: h.f.write(s)

proc newFile(L: Interp, f: File, std = 0): Value =
  L.wrap(LFile(f: f, isStd: std), "FILE*", fileMethods)

proc openIo(L: Interp): Value =
  fileMethods = newLib()
  let fm = fileMethods
  fm.fn "write", proc (L: Interp, a: seq[Value]): seq[Value] =
    let h = L.checkFile(a, "write")
    L.writeTo(h, a, 2)
    @[a[0]]
  fm.fn "read", proc (L: Interp, a: seq[Value]): seq[Value] =
    let h = L.checkFile(a, "read")
    if h.isStd == 3: return @[L.consoleRead(arg(a, 2))]
    var eof = false
    if a.len < 2: return @[L.readFmt(h.f, strV("l"), eof)]
    for i in 2 .. a.len:
      let v = L.readFmt(h.f, a[i - 1], eof)
      result.add v
      if v.kind == vkNil: break
  fm.fn "lines", proc (L: Interp, a: seq[Value]): seq[Value] =
    let h = L.checkFile(a, "lines")
    let fmt = if a.len >= 2: a[1] else: strV("l")
    @[fnV("lines_iter", proc (L: Interp, x: seq[Value]): seq[Value] =
      if h.closed: return @[nilV]
      var eof = false
      @[L.readFmt(h.f, fmt, eof)])]
  fm.fn "seek", proc (L: Interp, a: seq[Value]): seq[Value] =
    let h = L.checkFile(a, "seek")
    let whence = L.optStr(a, 2, "seek", "cur")
    let off = L.optInt(a, 3, "seek", 0)
    case whence
    of "set": h.f.setFilePos(off, fspSet)
    of "end": h.f.setFilePos(off, fspEnd)
    else: h.f.setFilePos(off, fspCur)
    @[intV(h.f.getFilePos())]
  fm.fn "flush", proc (L: Interp, a: seq[Value]): seq[Value] =
    let h = L.checkFile(a, "flush")
    if h.isStd == 0: h.f.flushFile()
    @[a[0]]
  fm.fn "close", proc (L: Interp, a: seq[Value]): seq[Value] =
    let h = L.checkFile(a, "close")
    if h.isStd == 0:
      h.f.close()
      h.closed = true
    @[boolV(true)]

  let m = newLib()
  let stdoutV = L.newFile(nil, 1)
  let stderrV = L.newFile(nil, 2)
  let stdinV = L.newFile(nil, 3)
  m.set "stdout", stdoutV
  m.set "stderr", stderrV
  m.set "stdin", stdinV
  m.fn "write", proc (L: Interp, a: seq[Value]): seq[Value] =
    L.writeTo(LFile(stdoutV.u), a, 1)
    @[stdoutV]
  m.fn "read", proc (L: Interp, a: seq[Value]): seq[Value] =
    @[L.consoleRead(arg(a, 1))]
  m.fn "open", proc (L: Interp, a: seq[Value]): seq[Value] =
    let path = L.checkStr(a, 1, "open")
    let mode = L.optStr(a, 2, "open", "r").replace("b", "")
    let fm = case mode
      of "r": fmRead
      of "w": fmWrite
      of "a": fmAppend
      of "r+": fmReadWriteExisting
      of "w+": fmReadWrite
      of "a+": fmAppend
      else: argError(2, "open", "mode invalide « " & mode & " »")
    var f: File
    if not open(f, path, fm): return fail(path & " : impossible d'ouvrir le fichier")
    @[L.newFile(f)]
  m.fn "lines", proc (L: Interp, a: seq[Value]): seq[Value] =
    if arg(a, 1).kind == vkNil:
      return @[fnV("lines_iter", proc (L: Interp, x: seq[Value]): seq[Value] =
        @[L.consoleRead(strV("l"))])]
    let path = L.checkStr(a, 1, "lines")
    var f: File
    if not open(f, path, fmRead): rtError(path & " : impossible d'ouvrir le fichier")
    let h = LFile(f: f)
    L.closers.add proc () =
      if not h.closed: h.f.close()
    @[fnV("lines_iter", proc (L: Interp, x: seq[Value]): seq[Value] =
      if h.closed: return @[nilV]
      var line: string
      if h.f.readLine(line): return @[strV(line)]
      h.f.close()
      h.closed = true
      @[nilV])]
  m.fn "type", proc (L: Interp, a: seq[Value]): seq[Value] =
    let v = arg(a, 1)
    if v.kind == vkUser and v.u of LFile:
      @[strV(if LFile(v.u).closed: "closed file" else: "file")]
    else: @[nilV]
  tableV(m)

registerPackage PackageDef(name: "io", global: true, open: openIo,
  description: "Entrées/sorties standard et fichiers (Lua 5.4)",
  docs: docs("io", [
    "io.write(...)", "Écrit les valeurs sur la sortie standard (console de l'IDE).",
    "io.read([fmt])", "Lit l'entrée standard : \"l\" ligne (défaut), \"n\" nombre, \"L\" ligne avec fin de ligne.",
    "io.lines([path])", "Itérateur sur les lignes d'un fichier, ou de l'entrée standard.",
    "io.open(path, [mode])", "Ouvre un fichier (\"r\", \"w\", \"a\", \"r+\", \"w+\", avec \"b\" possible) ; nil et message en cas d'échec.",
    "io.type(v)", "\"file\", \"closed file\" ou nil.",
    "io.stdout", "Sortie standard.", "io.stderr", "Sortie d'erreur.", "io.stdin", "Entrée standard.",
    "f:read(...)", "Lit selon les formats : \"l\", \"L\", \"n\", \"a\" ou un nombre d'octets.",
    "f:write(...)", "Écrit chaînes et nombres.",
    "f:lines([fmt])", "Itérateur de lecture.",
    "f:seek([whence], [offset])", "Position : \"set\", \"cur\", \"end\" ; renvoie la position.",
    "f:flush()", "Vide les tampons.",
    "f:close()", "Ferme le fichier."]))
