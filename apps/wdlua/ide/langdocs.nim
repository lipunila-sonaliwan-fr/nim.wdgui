# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
#   wdlua - documentation du langage pour l'IDE
#
# Source unique : les paquets enregistrés (lua/api.nim). La coloration, la
# complétion, l'aide à la signature et le panneau API en dérivent.

import std/[sets, strutils, algorithm]
import ../lua/api

export ApiDoc

const
  UiHandlers* = ["onclick", "ondoubleclick", "onrightclick", "onmiddleclick", "onrightdoubleclick",
    "onbuttondown", "onbuttonup", "onmouseenter", "onmouseleave", "onmousemove", "onwheel",
    "onkeydown", "onkeyup", "ontextinput", "onfocusgained", "onfocuslost", "onchange",
    "onselection", "onexpand", "oncollapse", "onvalidate", "onwindowopen", "onwindowclose",
    "onwindowresize", "onwindowactivate", "onwindowdeactivate", "onevent"]
  UiProps* = ["value", "num", "caption", "text", "title", "visible", "state", "enabled",
    "tooltip", "name", "x", "y", "width", "height", "color", "background", "bordercolor",
    "accent", "radius", "checked", "min", "max", "dock", "weight", "fixedwidth",
    "fixedheight", "stretch", "margin", "spacing", "columns", "family", "type"]

var
  entries: seq[ApiDoc]
  builtins: HashSet[string]
  pkgNames: seq[string]

proc initLangDocs*() =
  # À appeler une fois au démarrage (après l'import des paquets).
  entries = allDocs()
  builtins = initHashSet[string]()
  for d in entries:
    if d.owner.len == 0 and not d.isMethod: builtins.incl d.name
  for p in packages():
    if p.name != "base":
      builtins.incl p.name
      pkgNames.add p.name
  for n in ["_G", "_VERSION", "arg"]: builtins.incl n

proc isBuiltin*(name: string): bool =
  {.cast(gcsafe).}:
    result = name in builtins

proc apiEntries*(): seq[ApiDoc] =
  {.cast(gcsafe).}:
    result = entries

proc packageNames*(): seq[string] =
  {.cast(gcsafe).}:
    result = pkgNames

proc apiLookup*(name: string, wantMethod = false, owner = ""): seq[ApiDoc] =
  for e in apiEntries():
    if e.name == name and e.isMethod == wantMethod and (owner.len == 0 or e.owner == owner):
      result.add e

proc apiSummary*(name: string, wantMethod = false, owner = ""): string =
  var es = apiLookup(name, wantMethod, owner)
  if es.len == 0 and owner.len > 0: es = apiLookup(name, wantMethod)
  if es.len == 0:
    if name in UiHandlers:
      return name & " = function(ev) ... end — gestionnaire d'événement ui (ev.kind, ev.x, ev.y, ev.text, ev.index, ev:stop())"
    return ""
  var sigs: seq[string]
  for e in es:
    if e.signature notin sigs: sigs.add e.signature
  if sigs.len > 3: sigs.setLen(3)
  sigs.join("  |  ") & "  —  " & es[0].doc

proc membersOf*(owner: string): seq[ApiDoc] =
  # Fonctions « owner.f » (paquet ou bibliothèque).
  for e in apiEntries():
    if e.owner == owner and not e.isMethod: result.add e

proc methodEntries*(): seq[ApiDoc] =
  for e in apiEntries():
    if e.isMethod: result.add e

proc sections*(): seq[string] =
  for e in apiEntries():
    if e.section notin result: result.add e.section
