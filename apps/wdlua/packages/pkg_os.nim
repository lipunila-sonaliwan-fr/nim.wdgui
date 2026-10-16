# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
#   wdlua - paquet os (Lua 5.4, plus quelques ajouts)
#
#   os.time([t]) os.clock() os.date([fmt], [t]) os.difftime(a, b)
#   os.getenv(name) os.setenv(name, value) os.execute(cmd) os.capture(cmd)
#   os.remove(path) os.rename(a, b) os.tmpname() os.exit([code])
#   os.sleep(seconds) os.platform() os.args

import std/[os, osproc, times, strutils, monotimes]
import ../lua/api

type LuaExit* = object of LuaStop
  code*: int

let progStart = getMonoTime()

proc tmField(t: LTable, name: string, def: int, required = true): int =
  let v = t.rawGet(name)
  if v.kind == vkNil:
    if required: rtError("champ « " & name & " » manquant dans la table de date")
    return def
  var ok: bool
  result = int(toInteger(v, ok))
  if not ok: rtError("champ « " & name & " » invalide dans la table de date")

const
  DayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
  MonthNames = ["January", "February", "March", "April", "May", "June", "July",
                "August", "September", "October", "November", "December"]

proc strftime(fmt: string, dt: DateTime): string =
  var i = 0
  let wd = (ord(dt.weekday) + 1) mod 7          # 0 = dimanche.
  while i < fmt.len:
    if fmt[i] != '%' or i + 1 >= fmt.len:
      result.add fmt[i]
      inc i
      continue
    let c = fmt[i + 1]
    i += 2
    case c
    of 'Y': result.add $dt.year
    of 'y': result.add align($(dt.year mod 100), 2, '0')
    of 'm': result.add align($ord(dt.month), 2, '0')
    of 'd': result.add align($dt.monthday, 2, '0')
    of 'H': result.add align($dt.hour, 2, '0')
    of 'I': result.add align($(if dt.hour mod 12 == 0: 12 else: dt.hour mod 12), 2, '0')
    of 'M': result.add align($dt.minute, 2, '0')
    of 'S': result.add align($dt.second, 2, '0')
    of 'p': result.add(if dt.hour < 12: "AM" else: "PM")
    of 'A': result.add DayNames[wd]
    of 'a': result.add DayNames[wd][0 .. 2]
    of 'B': result.add MonthNames[ord(dt.month) - 1]
    of 'b': result.add MonthNames[ord(dt.month) - 1][0 .. 2]
    of 'j': result.add align($(dt.yearday + 1), 3, '0')
    of 'w': result.add $wd
    of 'c': result.add dt.format("ddd MMM d HH:mm:ss yyyy")
    of 'x': result.add dt.format("MM/dd/yy")
    of 'X': result.add dt.format("HH:mm:ss")
    of 'F': result.add dt.format("yyyy-MM-dd")
    of 'T': result.add dt.format("HH:mm:ss")
    of 'Z': result.add dt.timezone.name
    of '%': result.add '%'
    else: rtError("conversion invalide '%" & $c & "' pour os.date")

proc openOs(L: Interp): Value =
  let m = newLib()
  m.fn "time", proc (L: Interp, a: seq[Value]): seq[Value] =
    if arg(a, 1).kind != vkTable: return @[intV(getTime().toUnix)]
    let t = a[0].t
    let dt = dateTime(tmField(t, "year", 0), Month(tmField(t, "month", 1)),
                      MonthdayRange(tmField(t, "day", 1)),
                      HourRange(tmField(t, "hour", 12, false)),
                      MinuteRange(tmField(t, "min", 0, false)),
                      SecondRange(tmField(t, "sec", 0, false)), zone = local())
    @[intV(dt.toTime.toUnix)]
  m.fn "clock", proc (L: Interp, a: seq[Value]): seq[Value] =
    @[numV(float64(inNanoseconds(getMonoTime() - progStart)) / 1e9)]
  m.fn "date", proc (L: Interp, a: seq[Value]): seq[Value] =
    var fmt = L.optStr(a, 1, "date", "%c")
    let tm = if arg(a, 2).kind == vkNil: getTime() else: fromUnix(L.checkInt(a, 2, "date"))
    var utc = false
    if fmt.startsWith("!"):
      utc = true
      fmt = fmt[1 .. ^1]
    let dt = if utc: tm.utc else: tm.local
    if fmt.startsWith("*t"):
      let t = newLTable()
      t.set "year", intV(dt.year)
      t.set "month", intV(ord(dt.month))
      t.set "day", intV(dt.monthday)
      t.set "hour", intV(dt.hour)
      t.set "min", intV(dt.minute)
      t.set "sec", intV(dt.second)
      t.set "wday", intV((ord(dt.weekday) + 1) mod 7 + 1)
      t.set "yday", intV(dt.yearday + 1)
      t.set "isdst", boolV(dt.isDst)
      return @[tableV(t)]
    @[strV(strftime(fmt, dt))]
  m.fn "difftime", proc (L: Interp, a: seq[Value]): seq[Value] =
    @[numV(L.checkNum(a, 1, "difftime") - L.optNum(a, 2, "difftime", 0))]
  m.fn "getenv", proc (L: Interp, a: seq[Value]): seq[Value] =
    let n = L.checkStr(a, 1, "getenv")
    if existsEnv(n): @[strV(getEnv(n))] else: @[nilV]
  m.fn "setenv", proc (L: Interp, a: seq[Value]): seq[Value] =
    putEnv(L.checkStr(a, 1, "setenv"), L.checkStr(a, 2, "setenv"))
  m.fn "execute", proc (L: Interp, a: seq[Value]): seq[Value] =
    if arg(a, 1).kind == vkNil: return @[boolV(true)]
    let cmd = L.checkStr(a, 1, "execute")
    var code: int
    L.blocking:
      code = execShellCmd(cmd)
    @[(if code == 0: boolV(true) else: nilV), strV("exit"), intV(code)]
  m.fn "capture", proc (L: Interp, a: seq[Value]): seq[Value] =
    let cmd = L.checkStr(a, 1, "capture")
    var res: tuple[output: string, exitCode: int]
    L.blocking:
      res = execCmdEx(cmd)
    @[strV(res.output), intV(res.exitCode)]
  m.fn "remove", proc (L: Interp, a: seq[Value]): seq[Value] =
    let p = L.checkStr(a, 1, "remove")
    try:
      if dirExists(p): removeDir(p)
      elif fileExists(p): removeFile(p)
      else: return fail(p & " : fichier introuvable")
      @[boolV(true)]
    except OSError: fail(p & " : suppression impossible")
  m.fn "rename", proc (L: Interp, a: seq[Value]): seq[Value] =
    let x = L.checkStr(a, 1, "rename")
    try:
      moveFile(x, L.checkStr(a, 2, "rename"))
      @[boolV(true)]
    except OSError, IOError: fail(x & " : renommage impossible")
  m.fn "tmpname", proc (L: Interp, a: seq[Value]): seq[Value] =
    @[strV(getTempDir() / "wdlua_" & $getCurrentProcessId() & "_" & $int(epochTime() * 1000))]
  m.fn "exit", proc (L: Interp, a: seq[Value]): seq[Value] =
    var e = newException(LuaExit, "os.exit")
    let v = arg(a, 1)
    e.code = if v.kind == vkBool: (if v.b: 0 else: 1) else: int(L.optInt(a, 1, "exit", 0))
    raise e
  m.fn "sleep", proc (L: Interp, a: seq[Value]): seq[Value] =
    let s = L.checkNum(a, 1, "sleep")
    var left = int(s * 1000)
    L.blocking:
      while left > 0 and not L.stopRequested():
        sleep(min(left, 50))
        left -= 50
    L.checkStop()
  m.fn "platform", proc (L: Interp, a: seq[Value]): seq[Value] = @[strV(hostOS)]
  let argsT = newLTable()
  for i, s in L.args: argsT.rawSet(intV(i + 1), strV(s))
  argsT.rawSet(intV(0), strV(L.scriptPath))
  m.set "args", tableV(argsT)
  L.globals.rawSet("arg", tableV(argsT))
  tableV(m)

registerPackage PackageDef(name: "os", global: true, open: openOs,
  description: "Système d'exploitation",
  docs: docs("os", [
    "os.time([t])", "Heure actuelle (secondes Unix), ou date d'une table {year, month, day, hour, min, sec}.",
    "os.clock()", "Temps écoulé en secondes (horloge monotone).",
    "os.date([fmt], [t])", "Date formatée (%Y %m %d %H %M %S %A %B...) ; \"*t\" renvoie une table ; \"!\" en tête pour UTC.",
    "os.difftime(t2, t1)", "Différence en secondes.",
    "os.getenv(name)", "Variable d'environnement.", "os.setenv(name, value)", "Définit une variable d'environnement.",
    "os.execute(cmd)", "Exécute une commande système ; true ou nil, \"exit\", code.",
    "os.capture(cmd)", "Exécute une commande et renvoie sa sortie et son code.",
    "os.remove(path)", "Supprime un fichier.", "os.rename(old, new)", "Renomme un fichier.",
    "os.tmpname()", "Nom de fichier temporaire.",
    "os.exit([code])", "Termine le programme.",
    "os.sleep(seconds)", "Pause (les fenêtres restent réactives).",
    "os.platform()", "\"linux\", \"macosx\", \"windows\"...",
    "os.args", "Arguments du programme (aussi dans la globale arg)."]))
