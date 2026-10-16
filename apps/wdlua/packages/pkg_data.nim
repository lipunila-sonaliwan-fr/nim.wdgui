# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
#   wdlua - paquets de données
#
#   file   fichiers et dossiers (texte et binaire) ; reprend aussi les noms
#          du manuel §10.8 : ls, cp, mv, rm, mkdir, pwd, cd, fstat
#   bin    données binaires : pack / unpack / size (format proche de string.pack)
#   csv    lecture / écriture CSV (RFC 4180)
#   json   encodage / décodage JSON

import std/[os, strutils, json, times, parsecsv, streams, tables, math, algorithm]
import ../lua/api

#
# file
#

proc readText(path: string): seq[Value] =
  try: @[strV(readFile(path))]
  except IOError, OSError: fail(path & " : lecture impossible")

proc writeText(path, data: string, append: bool): seq[Value] =
  try:
    if append:
      var f: File
      if not open(f, path, fmAppend): return fail(path & " : écriture impossible")
      f.write(data)
      f.close()
    else:
      writeFile(path, data)
    @[boolV(true)]
  except IOError, OSError:
    fail(path & " : écriture impossible")

proc listDir(dir: string, recursive: bool): Value =
  let t = newLTable()
  var names: seq[string]
  if recursive:
    for f in walkDirRec(dir, relative = true): names.add f.replace('\\', '/')
  else:
    for k, p in walkDir(dir, relative = true):
      names.add(if k in {pcDir, pcLinkToDir}: p & "/" else: p)
  names.sort()
  for n in names: t.arr.add strV(n)
  tableV(t)

proc statTable(path: string): Value =
  if not (fileExists(path) or dirExists(path)): return nilV
  let info = getFileInfo(path)
  let t = newLTable()
  t.set "size", intV(info.size)
  t.set "kind", strV(if info.kind in {pcDir, pcLinkToDir}: "folder" else: "file")
  t.set "modified", intV(info.lastWriteTime.toUnix)
  t.set "created", intV(info.creationTime.toUnix)
  tableV(t)

proc openFile(L: Interp): Value =
  let m = newLib()
  m.fn "read", proc (L: Interp, a: seq[Value]): seq[Value] = readText(L.checkStr(a, 1, "read"))
  m.fn "readbytes", proc (L: Interp, a: seq[Value]): seq[Value] = readText(L.checkStr(a, 1, "readbytes"))
  m.fn "write", proc (L: Interp, a: seq[Value]): seq[Value] =
    writeText(L.checkStr(a, 1, "write"), L.checkStr(a, 2, "write"), false)
  m.fn "writebytes", proc (L: Interp, a: seq[Value]): seq[Value] =
    writeText(L.checkStr(a, 1, "writebytes"), L.checkStr(a, 2, "writebytes"), false)
  m.fn "append", proc (L: Interp, a: seq[Value]): seq[Value] =
    writeText(L.checkStr(a, 1, "append"), L.checkStr(a, 2, "append"), true)
  m.fn "lines", proc (L: Interp, a: seq[Value]): seq[Value] =
    let path = L.checkStr(a, 1, "lines")
    try:
      let t = newLTable()
      for l in lines(path): t.arr.add strV(l)
      @[tableV(t)]
    except IOError, OSError: fail(path & " : lecture impossible")
  m.fn "writelines", proc (L: Interp, a: seq[Value]): seq[Value] =
    let t = L.checkTable(a, 2, "writelines")
    var parts: seq[string]
    for i in 1 .. t.rawLen: parts.add L.tostr(t.rawGet(intV(i)))
    writeText(L.checkStr(a, 1, "writelines"), parts.join("\n") & "\n", false)
  m.fn "exists", proc (L: Interp, a: seq[Value]): seq[Value] =
    let p = L.checkStr(a, 1, "exists")
    @[boolV(fileExists(p) or dirExists(p))]
  m.fn "isfile", proc (L: Interp, a: seq[Value]): seq[Value] = @[boolV(fileExists(L.checkStr(a, 1, "isfile")))]
  m.fn "isdir", proc (L: Interp, a: seq[Value]): seq[Value] = @[boolV(dirExists(L.checkStr(a, 1, "isdir")))]
  m.fn "size", proc (L: Interp, a: seq[Value]): seq[Value] =
    let p = L.checkStr(a, 1, "size")
    if not fileExists(p): return fail(p & " : fichier introuvable")
    @[intV(getFileSize(p))]
  let lsFn = proc (L: Interp, a: seq[Value]): seq[Value] =
    let d = L.optStr(a, 1, "list", ".")
    if not dirExists(d): return fail(d & " : dossier introuvable")
    @[listDir(d, optBool(a, 2, false))]
  m.fn "list", lsFn
  m.fn "ls", lsFn
  let mkdirFn = proc (L: Interp, a: seq[Value]): seq[Value] =
    let d = L.checkStr(a, 1, "mkdir")
    try:
      createDir(d)
      @[boolV(true)]
    except OSError: fail(d & " : création impossible")
  m.fn "mkdir", mkdirFn
  let rmFn = proc (L: Interp, a: seq[Value]): seq[Value] =
    let p = L.checkStr(a, 1, "remove")
    try:
      if dirExists(p): removeDir(p)
      elif fileExists(p): removeFile(p)
      else: return fail(p & " : introuvable")
      @[boolV(true)]
    except OSError: fail(p & " : suppression impossible")
  m.fn "remove", rmFn
  m.fn "rm", rmFn
  let cpFn = proc (L: Interp, a: seq[Value]): seq[Value] =
    let src = L.checkStr(a, 1, "copy")
    let dst = L.checkStr(a, 2, "copy")
    try:
      if dirExists(src): copyDir(src, dst) else: copyFile(src, dst)
      @[boolV(true)]
    except OSError, IOError: fail(src & " : copie impossible")
  m.fn "copy", cpFn
  m.fn "cp", cpFn
  let mvFn = proc (L: Interp, a: seq[Value]): seq[Value] =
    let src = L.checkStr(a, 1, "move")
    let dst = L.checkStr(a, 2, "move")
    try:
      if dirExists(src): moveDir(src, dst) else: moveFile(src, dst)
      @[boolV(true)]
    except OSError, IOError: fail(src & " : déplacement impossible")
  m.fn "move", mvFn
  m.fn "mv", mvFn
  let statFn = proc (L: Interp, a: seq[Value]): seq[Value] = @[statTable(L.checkStr(a, 1, "stat"))]
  m.fn "stat", statFn
  m.fn "fstat", statFn
  let pwdFn = proc (L: Interp, a: seq[Value]): seq[Value] = @[strV(getCurrentDir())]
  m.fn "cwd", pwdFn
  m.fn "pwd", pwdFn
  m.fn "cd", proc (L: Interp, a: seq[Value]): seq[Value] =
    let d = L.checkStr(a, 1, "cd")
    try:
      setCurrentDir(d)
      @[boolV(true)]
    except OSError: fail(d & " : dossier introuvable")
  m.fn "join", proc (L: Interp, a: seq[Value]): seq[Value] =
    var p = ""
    for i in 1 .. a.len: p = if p.len == 0: L.checkStr(a, i, "join") else: p / L.checkStr(a, i, "join")
    @[strV(p)]
  m.fn "basename", proc (L: Interp, a: seq[Value]): seq[Value] = @[strV(extractFilename(L.checkStr(a, 1, "basename")))]
  m.fn "dirname", proc (L: Interp, a: seq[Value]): seq[Value] = @[strV(parentDir(L.checkStr(a, 1, "dirname")))]
  m.fn "ext", proc (L: Interp, a: seq[Value]): seq[Value] = @[strV(splitFile(L.checkStr(a, 1, "ext")).ext)]
  m.fn "abs", proc (L: Interp, a: seq[Value]): seq[Value] = @[strV(absolutePath(L.checkStr(a, 1, "abs")))]
  m.fn "tmpdir", proc (L: Interp, a: seq[Value]): seq[Value] = @[strV(getTempDir())]
  m.fn "home", proc (L: Interp, a: seq[Value]): seq[Value] = @[strV(getHomeDir())]
  tableV(m)

registerPackage PackageDef(name: "file", open: openFile,
  description: "Fichiers et dossiers (texte et binaire)",
  docs: docs("file", [
    "file.read(path)", "Contenu complet d'un fichier (texte ou binaire) ; nil et message en cas d'échec.",
    "file.readbytes(path)", "Contenu binaire (les chaînes Lua sont des suites d'octets).",
    "file.write(path, data)", "Remplace le contenu d'un fichier.",
    "file.writebytes(path, data)", "Écrit des octets.",
    "file.append(path, data)", "Ajoute à la fin d'un fichier.",
    "file.lines(path)", "Table des lignes d'un fichier.",
    "file.writelines(path, lines)", "Écrit une table de lignes.",
    "file.exists(path)", "Vrai si le fichier ou dossier existe.",
    "file.isfile(path)", "Vrai pour un fichier.", "file.isdir(path)", "Vrai pour un dossier.",
    "file.size(path)", "Taille en octets.",
    "file.list([dir], [recursive])", "Noms contenus dans un dossier (les dossiers finissent par /).",
    "file.ls([dir])", "Alias de list (manuel §10.8).",
    "file.mkdir(path)", "Crée un dossier (et ses parents).",
    "file.remove(path)", "Supprime un fichier ou un dossier (récursif).", "file.rm(path)", "Alias de remove (§10.8).",
    "file.copy(src, dest)", "Copie (dossiers récursivement).", "file.cp(src, dest)", "Alias de copy (§10.8).",
    "file.move(src, dest)", "Déplace ou renomme.", "file.mv(src, dest)", "Alias de move (§10.8).",
    "file.stat(path)", "Table {size, kind, modified, created} ou nil.", "file.fstat(path)", "Alias de stat (§10.8).",
    "file.cwd()", "Dossier courant.", "file.pwd()", "Alias de cwd (§10.8).", "file.cd(path)", "Change de dossier (§10.8).",
    "file.join(a, b, ...)", "Assemble des chemins.", "file.basename(path)", "Nom du fichier.",
    "file.dirname(path)", "Dossier parent.", "file.ext(path)", "Extension.", "file.abs(path)", "Chemin absolu.",
    "file.tmpdir()", "Dossier temporaire.", "file.home()", "Dossier personnel."]))

#
# bin : pack / unpack
#

proc putInt(buf: var string, v: uint64, size: int, little: bool) =
  for i in 0 ..< size:
    let shift = if little: 8 * i else: 8 * (size - 1 - i)
    buf.add chr(int((v shr shift) and 0xFF))

proc getInt(s: string, pos, size: int, little: bool): uint64 =
  for i in 0 ..< size:
    let b = uint64(ord(s[pos + i]))
    let shift = if little: 8 * i else: 8 * (size - 1 - i)
    result = result or (b shl shift)

proc fmtSize(c: char, num: int): int =
  case c
  of 'b', 'B': 1
  of 'h', 'H': 2
  of 'i', 'I', 'f': 4
  of 'l', 'L', 'j', 'J', 'd', 'n': 8
  of 'c': num
  else: 0

proc readNum(fmt: string, i: var int): int =
  result = -1
  while i < fmt.len and fmt[i] in Digits:
    result = max(result, 0) * 10 + (ord(fmt[i]) - ord('0'))
    inc i

proc openBin(L: Interp): Value =
  let m = newLib()
  m.fn "pack", proc (L: Interp, a: seq[Value]): seq[Value] =
    let fmt = L.checkStr(a, 1, "pack")
    var little = true
    var outp = ""
    var argi = 2
    var i = 0
    while i < fmt.len:
      let c = fmt[i]
      inc i
      var num = readNum(fmt, i)
      case c
      of '<', '=': little = true
      of '>', '!': little = false
      of ' ': discard
      of 'b', 'B', 'h', 'H', 'i', 'I', 'l', 'L', 'j', 'J':
        let size = if c in {'i', 'I'} and num > 0: num else: fmtSize(c, num)
        putInt(outp, cast[uint64](L.checkInt(a, argi, "pack")), size, little)
        inc argi
      of 'f':
        let f = float32(L.checkNum(a, argi, "pack"))
        putInt(outp, uint64(cast[uint32](f)), 4, little)
        inc argi
      of 'd', 'n':
        putInt(outp, cast[uint64](L.checkNum(a, argi, "pack")), 8, little)
        inc argi
      of 'z':
        outp.add L.checkStr(a, argi, "pack") & "\0"
        inc argi
      of 's':
        let s = L.checkStr(a, argi, "pack")
        putInt(outp, uint64(s.len), (if num > 0: num else: 8), little)
        outp.add s
        inc argi
      of 'c':
        if num < 0: rtError("taille manquante pour 'c' dans le format")
        var s = L.checkStr(a, argi, "pack")
        if s.len > num: argError(argi, "pack", "chaîne plus longue que la taille donnée")
        while s.len < num: s.add '\0'
        outp.add s
        inc argi
      of 'x': outp.add '\0'
      else: rtError("option de format invalide '" & $c & "'")
    @[strV(outp)]
  m.fn "unpack", proc (L: Interp, a: seq[Value]): seq[Value] =
    let fmt = L.checkStr(a, 1, "unpack")
    let s = L.checkStr(a, 2, "unpack")
    var pos = int(L.optInt(a, 3, "unpack", 1)) - 1
    var little = true
    var i = 0
    template need(n: int) =
      if pos + n > s.len: rtError("données trop courtes pour 'unpack'")
    while i < fmt.len:
      let c = fmt[i]
      inc i
      let num = readNum(fmt, i)
      case c
      of '<', '=': little = true
      of '>', '!': little = false
      of ' ': discard
      of 'b', 'h', 'i', 'l', 'j':
        let size = if c == 'i' and num > 0: num else: fmtSize(c, num)
        need(size)
        var v = getInt(s, pos, size, little)
        if size < 8 and (v and (1'u64 shl (8 * size - 1))) != 0:
          v = v or (not 0'u64 shl (8 * size))          # extension de signe
        result.add intV(cast[int64](v))
        pos += size
      of 'B', 'H', 'I', 'L', 'J':
        let size = if c == 'I' and num > 0: num else: fmtSize(c, num)
        need(size)
        result.add intV(cast[int64](getInt(s, pos, size, little)))
        pos += size
      of 'f':
        need(4)
        result.add numV(float64(cast[float32](uint32(getInt(s, pos, 4, little)))))
        pos += 4
      of 'd', 'n':
        need(8)
        result.add numV(cast[float64](getInt(s, pos, 8, little)))
        pos += 8
      of 'z':
        let e = s.find('\0', pos)
        if e < 0: rtError("chaîne non terminée pour 'z'")
        result.add strV(s[pos ..< e])
        pos = e + 1
      of 's':
        let size = if num > 0: num else: 8
        need(size)
        let n = int(getInt(s, pos, size, little))
        pos += size
        need(n)
        result.add strV(s[pos ..< pos + n])
        pos += n
      of 'c':
        need(num)
        result.add strV(s[pos ..< pos + num])
        pos += num
      of 'x': pos += 1
      else: rtError("option de format invalide '" & $c & "'")
    result.add intV(pos + 1)
  m.fn "size", proc (L: Interp, a: seq[Value]): seq[Value] =
    let fmt = L.checkStr(a, 1, "size")
    var total = 0
    var i = 0
    while i < fmt.len:
      let c = fmt[i]
      inc i
      let num = readNum(fmt, i)
      if c in {'s', 'z'}: rtError("taille variable pour '" & $c & "'")
      total += (if c in {'i', 'I'} and num > 0: num elif c == 'x': 1 else: fmtSize(c, num))
    @[intV(total)]
  m.fn "tohex", proc (L: Interp, a: seq[Value]): seq[Value] =
    let s = L.checkStr(a, 1, "tohex")
    var r = ""
    for ch in s: r.add toHex(ord(ch), 2).toLowerAscii
    @[strV(r)]
  m.fn "fromhex", proc (L: Interp, a: seq[Value]): seq[Value] =
    let s = L.checkStr(a, 1, "fromhex")
    if s.len mod 2 != 0: return fail("longueur hexadécimale impaire")
    var r = ""
    try:
      for i in countup(0, s.len - 2, 2): r.add chr(parseHexInt(s[i .. i + 1]))
    except ValueError: return fail("chaîne hexadécimale invalide")
    @[strV(r)]
  # compatibilité Lua 5.4 : string.pack / string.unpack / string.packsize
  let strLib = L.stringMeta.rawGet("__index")
  if strLib.kind == vkTable:
    strLib.t.set "pack", m.get("pack")
    strLib.t.set "unpack", m.get("unpack")
    strLib.t.set "packsize", m.get("size")
  tableV(m)

registerPackage PackageDef(name: "bin", open: openBin,
  description: "Données binaires",
  docs: docs("bin", [
    "bin.pack(fmt, ...)", "Code des valeurs en binaire. Format : < petit-boutiste, > gros-boutiste, b/B 8 bits, h/H 16, i/I 32 (iN : N octets), l/L/j/J 64, f flottant 32, d flottant 64, z chaîne terminée par zéro, s chaîne préfixée par sa longueur, cN chaîne de N octets, x octet nul.",
    "bin.unpack(fmt, data, [pos])", "Décode ; renvoie les valeurs puis la position suivante.",
    "bin.size(fmt)", "Taille d'un format fixe.",
    "bin.tohex(data)", "Représentation hexadécimale.",
    "bin.fromhex(hex)", "Octets à partir de l'hexadécimal."]))

#
# json
#

type JsonNull* = ref object of LUser

proc jsonNull(L: Interp): Value =
  let existing = L.registry.rawGet("json.null")
  if existing.kind != vkNil: return existing
  result = userV(JsonNull(tname: "json.null"))
  result.u.meta = newLTable()
  result.u.meta.set "__tostring", fnV("tostring", proc (L: Interp, a: seq[Value]): seq[Value] = @[strV("null")])
  L.registry.rawSet("json.null", result)

proc toJsonNode*(L: Interp, v: Value, depth = 0): JsonNode =
  # Conversion Lua -> JSON. Une table à index 1..n devient un tableau.
  if depth > 100: rtError("structure trop profonde ou cyclique pour JSON")
  case v.kind
  of vkNil: result = newJNull()
  of vkBool: result = newJBool(v.b)
  of vkInt: result = newJInt(v.i)
  of vkNum:
    if v.n != v.n or v.n == Inf or v.n == NegInf: rtError("nombre non représentable en JSON")
    result = newJFloat(v.n)
  of vkStr: result = newJString(v.s)
  of vkTable:
    let n = v.t.rawLen
    var total = 0
    for k, _ in v.t.pairs: inc total
    if n > 0 and total == n:
      result = newJArray()
      for i in 1 .. n: result.add L.toJsonNode(v.t.rawGet(intV(i)), depth + 1)
    else:
      result = newJObject()
      for k, x in v.t.pairs:
        if k.kind notin {vkStr, vkInt, vkNum}: rtError("clé de table non représentable en JSON")
        result[rawToString(k)] = L.toJsonNode(x, depth + 1)
  of vkUser:
    if v.u of JsonNull: result = newJNull()
    else: rtError("valeur userdata non représentable en JSON")
  of vkFunc: rtError("fonction non représentable en JSON")

proc fromJsonNode*(L: Interp, j: JsonNode, nullAsNil = false): Value =
  case j.kind
  of JNull: (if nullAsNil: nilV else: L.jsonNull())
  of JBool: boolV(j.getBool)
  of JInt: intV(j.getBiggestInt)
  of JFloat: numV(j.getFloat)
  of JString: strV(j.getStr)
  of JArray:
    let t = newLTable(j.len)
    var i = 1
    for x in j.elems:
      t.rawSet(intV(i), L.fromJsonNode(x, nullAsNil))
      inc i
    tableV(t)
  of JObject:
    let t = newLTable()
    for k, x in j.fields:
      let v = L.fromJsonNode(x, nullAsNil)
      if v.kind != vkNil: t.rawSet(strV(k), v)
    tableV(t)

proc openJson(L: Interp): Value =
  let m = newLib()
  m.set "null", L.jsonNull()
  m.fn "encode", proc (L: Interp, a: seq[Value]): seq[Value] =
    let j = L.toJsonNode(arg(a, 1))
    @[strV(if optBool(a, 2, false): j.pretty else: $j)]
  m.fn "decode", proc (L: Interp, a: seq[Value]): seq[Value] =
    try: @[L.fromJsonNode(parseJson(L.checkStr(a, 1, "decode")))]
    except JsonParsingError, ValueError: fail("JSON invalide : " & getCurrentExceptionMsg())
  m.fn "read", proc (L: Interp, a: seq[Value]): seq[Value] =
    let path = L.checkStr(a, 1, "read")
    try: @[L.fromJsonNode(parseFile(path))]
    except IOError, OSError: fail(path & " : lecture impossible")
    except JsonParsingError, ValueError: fail("JSON invalide : " & getCurrentExceptionMsg())
  m.fn "write", proc (L: Interp, a: seq[Value]): seq[Value] =
    let path = L.checkStr(a, 1, "write")
    let j = L.toJsonNode(arg(a, 2))
    try:
      writeFile(path, if optBool(a, 3, true): j.pretty else: $j)
      @[boolV(true)]
    except IOError, OSError: fail(path & " : écriture impossible")
  tableV(m)

registerPackage PackageDef(name: "json", open: openJson,
  description: "JSON",
  docs: docs("json", [
    "json.encode(value, [pretty])", "Texte JSON ; une table à index 1..n devient un tableau, sinon un objet.",
    "json.decode(text)", "Valeur Lua ; null devient json.null.",
    "json.read(path)", "Lit et décode un fichier JSON.",
    "json.write(path, value, [pretty])", "Encode et écrit un fichier JSON (indenté par défaut).",
    "json.null", "Valeur représentant null."]))

#
# csv
#

proc csvParse(L: Interp, text: string, opts: LTable): Value =
  let sep = optField(opts, "sep", ",")
  let header = optField(opts, "header", false)
  let convert = optField(opts, "convert", true)
  var p: CsvParser
  var s = newStringStream(text)
  p.open(s, "csv", separator = (if sep.len > 0: sep[0] else: ','))
  let rows = newLTable()
  var names: seq[string]
  try:
    if header:
      p.readHeaderRow()
      names = p.headers
    while p.readRow():
      let r = newLTable()
      for i, cell in p.row:
        var v = strV(cell)
        if convert and cell.len > 0:
          let (ok, n) = str2number(cell)
          if ok: v = n
        if header and i < names.len: r.rawSet(strV(names[i]), v)
        else: r.rawSet(intV(i + 1), v)
      rows.arr.add tableV(r)
  except CsvError as e:
    rtError("CSV invalide : " & e.msg)
  finally:
    p.close()
  if header:
    let h = newLTable()
    for n in names: h.arr.add strV(n)
    rows.set "header", tableV(h)
  tableV(rows)

proc csvQuote(s, sep: string): string =
  if s.contains(sep) or s.contains('"') or s.contains('\n') or s.contains('\r'):
    "\"" & s.replace("\"", "\"\"") & "\""
  else: s

proc csvEncode(L: Interp, rows: LTable, opts: LTable): string =
  let sep = optField(opts, "sep", ",")
  var cols: seq[string]
  let hv = if opts.isNil: nilV else: opts.rawGet("header")
  if hv.kind == vkTable:
    for i in 1 .. hv.t.rawLen: cols.add rawToString(hv.t.rawGet(intV(i)))
  elif hv.kind == vkBool and hv.b and rows.rawLen > 0 and rows.rawGet(intV(1)).kind == vkTable:
    # en-tête déduit des clés de la première ligne (ordre alphabétique).
    for k, _ in rows.rawGet(intV(1)).t.pairs:
      if k.kind == vkStr: cols.add k.s
    cols.sort()
  var lines: seq[string]
  if cols.len > 0:
    var hs: seq[string]
    for c in cols: hs.add csvQuote(c, sep)
    lines.add hs.join(sep)
  for i in 1 .. rows.rawLen:
    let r = rows.rawGet(intV(i))
    if r.kind != vkTable: rtError("ligne " & $i & " : table attendue")
    var cells: seq[string]
    if cols.len > 0:
      for c in cols:
        let v = r.t.rawGet(c)
        cells.add csvQuote(if v.kind == vkNil: "" else: L.tostr(v), sep)
    else:
      for k in 1 .. r.t.rawLen:
        let v = r.t.rawGet(intV(k))
        cells.add csvQuote(if v.kind == vkNil: "" else: L.tostr(v), sep)
    lines.add cells.join(sep)
  lines.join("\r\n") & "\r\n"

proc openCsv(L: Interp): Value =
  let m = newLib()
  m.fn "parse", proc (L: Interp, a: seq[Value]): seq[Value] =
    let opts = if arg(a, 2).kind == vkTable: a[1].t else: nil
    @[L.csvParse(L.checkStr(a, 1, "parse"), opts)]
  m.fn "read", proc (L: Interp, a: seq[Value]): seq[Value] =
    let path = L.checkStr(a, 1, "read")
    let opts = if arg(a, 2).kind == vkTable: a[1].t else: nil
    var text: string
    try: text = readFile(path)
    except IOError, OSError: return fail(path & " : lecture impossible")
    @[L.csvParse(text, opts)]
  m.fn "encode", proc (L: Interp, a: seq[Value]): seq[Value] =
    let opts = if arg(a, 2).kind == vkTable: a[1].t else: nil
    @[strV(L.csvEncode(L.checkTable(a, 1, "encode"), opts))]
  m.fn "write", proc (L: Interp, a: seq[Value]): seq[Value] =
    let path = L.checkStr(a, 1, "write")
    let opts = if arg(a, 3).kind == vkTable: a[2].t else: nil
    let text = L.csvEncode(L.checkTable(a, 2, "write"), opts)
    try:
      writeFile(path, text)
      @[boolV(true)]
    except IOError, OSError: fail(path & " : écriture impossible")
  tableV(m)

registerPackage PackageDef(name: "csv", open: openCsv,
  description: "Fichiers CSV",
  docs: docs("csv", [
    "csv.parse(text, [opts])", "Lignes d'un texte CSV. opts : sep (\",\"), header (false : lignes = tableaux ; true : lignes = tables par nom de colonne, et rows.header), convert (true : nombres convertis).",
    "csv.read(path, [opts])", "Lit un fichier CSV (mêmes options).",
    "csv.encode(rows, [opts])", "Texte CSV. opts : sep, header (table des colonnes, ou true pour les déduire).",
    "csv.write(path, rows, [opts])", "Écrit un fichier CSV."]))
