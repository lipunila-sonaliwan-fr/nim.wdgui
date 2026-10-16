# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
#   wdlua - runtime autonome
#
#   wdluart programme.lua [arguments...]
#   wdluart --check programme.lua        vérifie la syntaxe sans exécuter
#   wdluart --packages                   liste les paquets disponibles
#   wdluart -e "code"                    exécute du code
#
# Même interpréteur et mêmes paquets que l'IDE. Si le programme a ouvert des
# fenêtres (paquet ui) sans appeler ui.run(), la boucle de wdgui est lancée
# à la fin du programme, jusqu'à la fermeture des fenêtres.

import std/[os, strutils]
import wdgui
import lua/api
import packages/all
from lua/lexer import SyntaxError
from lua/parser import parseChunk

proc usage() =
  echo "wdLua[RT] 1.3a écrit par Jean-Marc Quéré."
  echo "LPCS, Lab'Oratoire (metalab at sonaliwan.fr)"
  echo "  wdluart programme.lua [arguments...]"
  echo "  wdluart --check programme.lua"
  echo "  wdluart -e \"code\""
  echo "  wdluart --packages"

proc main(): int =
  if paramCount() < 1:
    usage()
    return 1
  let first = paramStr(1)
  case first
  of "-h", "--help":
    usage()
    return 0
  of "--packages":
    for p in packages():
      echo alignLeft(p.name, 12), (if p.global: "global   " else: "require  "), p.description
    return 0
  of "--check":
    if paramCount() < 2:
      usage()
      return 1
    let path = paramStr(2)
    try:
      discard parseChunk(readFile(path), path)
      echo path, " : syntaxe correcte"
      return 0
    except SyntaxError as e:
      stderr.writeLine e.msg
      return 2
    except IOError, OSError:
      stderr.writeLine "lecture impossible : ", path
      return 1
  else: discard

  let L = newFullInterp()
  var src, name: string
  var argStart = 2
  if first == "-e":
    if paramCount() < 2:
      usage()
      return 1
    src = paramStr(2)
    name = "(ligne de commande)"
    argStart = 3
  else:
    name = absolutePath(first)
    L.scriptPath = name
    L.searchDirs.add name.parentDir
  for i in argStart .. paramCount(): L.args.add paramStr(i)
  # os.args / arg ont été installés à l'ouverture : on les complète
  let argT = newLTable()
  argT.rawSet(intV(0), strV(L.scriptPath))
  for i, a in L.args: argT.rawSet(intV(i + 1), strV(a))
  L.globals.rawSet("arg", tableV(argT))

  var code = 0
  L.enter()
  curCtx = Ctx()
  try:
    var vargs: seq[Value]
    for a in L.args: vargs.add strV(a)
    if src.len > 0: discard L.call(L.load(src, name), vargs)
    else: discard L.runFile(name, vargs)
    if L.loopNeeded():
      L.uiState.loopRunning = true
      L.blocking: runApplication()
  except SyntaxError as e:
    stderr.writeLine e.msg
    code = 2
  except LuaExit as e:
    code = e.code
  except LuaStop:
    discard
  except LuaError as e:
    stderr.writeLine e.msg
    stderr.writeLine e.traceback
    code = 1
  except IOError, OSError:
    stderr.writeLine "lecture impossible : ", name
    code = 1
  except CatchableError as e:
    stderr.writeLine "erreur : ", e.msg
    code = 1
  L.shutdown()
  L.leave()
  code

when isMainModule:
  quit main()
