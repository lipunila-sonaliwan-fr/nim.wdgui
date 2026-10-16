# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
#   wdlua - paquet ui : wdgui depuis Lua
#
#   local ui = require "ui"
#   local win = ui.window{title = "Bonjour", width = 420, height = 220}
#   local lbl = win:add(ui.label("Cliquez le bouton", "center"))
#   local btn = win:add(ui.button("OK", {default = true}))
#   btn.onclick = function(ev) lbl.caption = "Cliqué en " .. ev.x .. ", " .. ev.y end
#   ui.run()
#
# Chaque contrôle est un objet Lua :
#   - propriétés lues et écrites comme dans wdgui (value, num, caption, visible,
#     state, tooltip, name, x, y, width, height, color, background, dock,
#     weight, fixedwidth, fixedheight, stretch, margin, spacing, min, max...) ;
#   - gestionnaires on<événement> : onclick, onchange, onselection, ondoubleclick,
#     onrightclick, onkeydown, ontextinput, onfocusgained, onwindowclose... et
#     onevent pour tous ; ev:stop() arrête la propagation (étape 7 du tutoriel) ;
#   - méthodes selon la famille : list:add, table:addline, tree:add,
#     grid:addcolumn, chart:adddata, tab:addpage...
#
# Les gestionnaires s'exécutent sur les threads de wdgui ; l'interpréteur les
# sérialise avec son verrou global. ui.run() attend la fermeture des fenêtres
# (dans l'IDE) ou lance la boucle de wdgui (runtime autonome).

import std/[strutils, tables, os, locks, options]
import wdgui
import ../lua/api
import ../ide/compat

type
  UiCtl* = ref object of LUser
    rawId: ControlId     # identifiant fixe (colonnes de grille), sinon lu sur ctl / win.
    ctl*: Control
    win*: Window
    family*: string
    handlers*: LTable
    closed*: bool

  UiState* = ref object of RootObj
    ctls*: seq[UiCtl]
    windows*: seq[UiCtl]
    loopRunning*: bool
    trace*: bool          # ui.trace(true) : affiche chaque événement reçu.

proc id*(c: UiCtl): ControlId =
  # Identifiant courant. wdgui n'attribue l'identifiant d'un contrôle qu'au
  # moment où il est rattaché à l'arbre d'une fenêtre (comme dans wdnim, qui
  # lit `.id` après `addChild`) : on le relit donc à chaque fois.
  if not c.ctl.isNil: result = c.ctl.id
  elif not c.win.isNil: result = c.win.id
  else: result = c.rawId

var uiLock: Lock
var uiInterps: seq[Interp]     # interpréteurs ayant ouvert le paquet ui (un par programme).
initLock(uiLock)

var ctlMeta: LTable

proc uiState*(L: Interp): UiState =
  let r = L.ext.getOrDefault("ui")
  if r.isNil:
    result = UiState()
    L.ext["ui"] = result
  else:
    result = UiState(r)

proc findCtl(st: UiState, cid: ControlId): UiCtl =
  # Objet Lua d'un identifiant wdgui. On compare d'abord les objets Control
  # (control(id) de wdgui), puis les identifiants relus.
  var target: Control = nil
  when compiles(control(cid)):
    try: target = control(cid)
    except CatchableError: target = nil
  if not target.isNil:
    for c in st.ctls:
      if not c.ctl.isNil and c.ctl == target: return c
  for c in st.ctls:
    if c.id == cid: return c
  nil

proc idText(cid: ControlId): string =
  when compiles($cid): result = $cid
  elif compiles(int(cid)): result = $int(cid)
  else: result = "?"

proc openWindows*(L: Interp): int =
  # Nombre de fenêtres du programme encore ouvertes.
  let r = L.ext.getOrDefault("ui")
  if r.isNil: return 0
  for w in UiState(r).windows:
    if not w.closed: inc result

proc closeAllWindows*(L: Interp) =
  let r = L.ext.getOrDefault("ui")
  if r.isNil: return
  for w in UiState(r).windows:
    if not w.closed:
      w.closed = true
      closeWindow(w.id)

proc loopNeeded*(L: Interp): bool =
  # Runtime autonome : faut-il lancer la boucle wdgui après le programme ?
  let r = L.ext.getOrDefault("ui")
  not r.isNil and not UiState(r).loopRunning and L.openWindows() > 0

#
# Conversions de noms
#

proc layoutOf(s: string): typeof(lkVertical) =
  case s.toLowerAscii
  of "horizontal", "h", "row": lkHorizontal
  of "grid": lkGrid
  of "flow": lkFlow
  of "border": lkBorder
  of "stack": lkStack
  of "absolute": lkAbsolute
  else: lkVertical

proc dockOf(s: string): typeof(dkTop) =
  case s.toLowerAscii
  of "top": dkTop
  of "bottom": dkBottom
  of "left": dkLeft
  of "right": dkRight
  else: dkCenter

proc alignOf(s: string): typeof(alCenter) =
  case s.toLowerAscii
  of "center", "centre": result = alCenter
  of "right", "droite": result = alRight
  else:
    when declared(alLeft): result = alLeft
    else: result = alCenter

proc iconOf(s: string): typeof(iconStop) =
  case s.toLowerAscii
  of "stop", "error", "erreur": iconStop
  of "exclamation", "warning", "attention": iconExclamation
  of "question": iconQuestion
  of "none", "aucune": iconNone
  else: iconInformation

proc themeOf(name: string, dark: bool): Theme =
  case name.toLowerAscii
  of "windows", "windows11", "native": result = themeNative(dark = dark)
  of "macos", "mac": result = themeMacOS(dark = dark)
  of "linux", "gnome", "adwaita": result = themeLinux(dark = dark)
  else: result = themeFor(dark)

proc chartKindOf(s: string): typeof(ckColumn) =
  case s.toLowerAscii
  of "line": ckLine
  of "area": ckArea
  of "pie": ckPie
  else: ckColumn

proc gridKindOf(s: string): typeof(gcText) =
  case s.toLowerAscii
  of "number": gcNumber
  of "date": gcDate
  of "image": gcImage
  of "button": gcButton
  of "combo": gcCombo
  of "check", "checkbox": gcCheck
  else: gcText

proc footerOf(s: string): typeof(fkSum) =
  case s.toLowerAscii
  of "average", "avg": fkAverage
  of "min": fkMin
  of "max": fkMax
  of "count": fkCount
  else: fkSum

proc editModeOf(s: string): typeof(emInherit) =
  case s.toLowerAscii
  of "readonly": emReadOnly
  of "editable": emEditable
  else: emInherit

proc fillModeOf(s: string): typeof(fmProgrammed) =
  case s.toLowerAscii
  of "manual": fmManual
  of "automatic": fmAutomatic
  else: fmProgrammed

proc compareOf(s: string): typeof(coEquals) =
  case s
  of "==", "=", "equals": coEquals
  of "~=", "!=", "notequals": coNotEquals
  of "<": coLess
  of "<=": coLessOrEqual
  of ">": coGreater
  of ">=": coGreaterOrEqual
  of "contains": coContains
  of "empty": coEmpty
  else: coNotEmpty

proc stateName(id: ControlId): string =
  when compiles(id.state):
    let s = id.state
    if s == csGrayed: result = "grayed"
    elif s == csReadOnly: result = "readonly"
    else: result = "active"
  else: result = ""

proc stateOf(s: string): typeof(csActive) =
  case s.toLowerAscii
  of "grayed", "disabled": csGrayed
  of "readonly": csReadOnly
  else: csActive

# ---------------------------------------------------------------------------
# Accès aux propriétés (getters/setters de l'API par identifiant)
# ---------------------------------------------------------------------------

template defGetter(pname, field, conv: untyped) =
  proc pname(id: ControlId): Value =
    when compiles(id.field): result = conv(id.field)
    else: result = nilV

defGetter(gValue, value, strV)
defGetter(gNum, valueNum, numV)
defGetter(gCaption, caption, strV)
defGetter(gVisible, visible, boolV)
defGetter(gTooltip, tooltip, strV)
defGetter(gX, x, numV)
defGetter(gY, y, numV)
defGetter(gWidth, width, numV)
defGetter(gHeight, height, numV)
defGetter(gMin, minBound, numV)
defGetter(gMax, maxBound, numV)

proc gName(id: ControlId): Value =
  when compiles(name(id)): result = strV(name(id))
  else: result = nilV

proc colorOf(v: Value): Color =
  if v.kind != vkStr: rtError("couleur attendue sous la forme \"#RRGGBB\"")
  hex(v.s)

proc numOf(v: Value, what: string): float =
  var ok: bool
  result = toFloat(v, ok)
  if not ok: rtError(what & " : nombre attendu")

proc wrapCtl(L: Interp, c: UiCtl): Value

proc unsupported(what: string) {.noreturn.} =
  rtError("propriété « " & what & " » non prise en charge par cette version de wdgui")

template setNum(lhs: untyped, v: float, what = "") =
  # Affecte un nombre quel que soit le type numérique attendu (float ou int) ;
  # erreur Lua si la propriété n'existe pas dans wdgui.
  when compiles(lhs = v): lhs = v
  elif compiles(lhs = typeof(lhs)(v)): lhs = typeof(lhs)(v)
  else: unsupported(what)

template setAny(lhs: untyped, v: untyped, what: string) =
  # Affectation protégée : erreur Lua si la propriété n'existe pas dans wdgui.
  when compiles(lhs = v): lhs = v
  else: unsupported(what)

template setVia(c: UiCtl, idExpr, objField: untyped, v: untyped, what: string) =
  # Affectation par identifiant (API de wdgui) ; à défaut, sur l'objet Control sous le verrou de wdgui, comme le fait wdnim.
  when compiles(idExpr = v):
    idExpr = v
  else:
    if c.ctl.isNil: unsupported(what)
    withControl(c.id, Control, obj):
      when compiles(obj.objField = v): obj.objField = v
      else: unsupported(what)
    requestRedraw(c.id)

template doCall(call: untyped) =
  # Appel d'une procédure qui renvoie une valeur ou rien.
  when typeof(call) is void: call
  else: discard call

proc anyV(x: bool): Value = boolV(x)
proc anyV(x: int): Value = intV(x)
proc anyV(x: float): Value = numV(x)
proc anyV(x: string): Value = strV(x)

proc typeNameOf(id: ControlId, family: string): Value =
  when compiles(controlType(id)): result = strV(controlType(id))
  else: result = strV(family)

proc ctlOf(v: Value, what = "contrôle"): UiCtl =
  if v.kind != vkUser or not (v.u of UiCtl): rtError(what & " attendu")
  UiCtl(v.u)

proc setProp(L: Interp, c: UiCtl, key: string, v: Value) =
  let id = c.id
  case key
  of "value", "text":
    let txt = L.tostr(v)
    if c.family in ["label", "button", "window", "page", "cell"] and key == "text":
      setVia(c, id.caption, caption, txt, key)
    else:
      when compiles(id.value = txt): id.value = txt
      else:
        if c.ctl.isNil: unsupported(key)
        withControl(c.id, Control, obj): obj.setValueText(txt)
        requestRedraw(c.id)
  of "num": setNum(id.valueNum, numOf(v, "num"), key)
  of "caption", "title":
    let txt = L.tostr(v)
    setVia(c, id.caption, caption, txt, key)
  of "visible":
    let b = truthy(v)
    setVia(c, id.visible, visible, b, key)
  of "state":
    let st = stateOf(L.tostr(v))
    setVia(c, id.state, state, st, key)
  of "enabled":
    let st = if truthy(v): csActive else: csGrayed
    setVia(c, id.state, state, st, key)
  of "tooltip":
    let txt = L.tostr(v)
    setVia(c, id.tooltip, tooltip, txt, key)
  of "name":
    let txt = L.tostr(v)
    setAny(id.name, txt, key)
  of "x": setNum(id.x, numOf(v, "x"), key)
  of "y": setNum(id.y, numOf(v, "y"), key)
  of "width": setNum(id.width, numOf(v, "width"), key)
  of "height": setNum(id.height, numOf(v, "height"), key)
  of "color", "textcolor":
    let col = colorOf(v)
    when compiles(id.color = col): id.color = col
    else:
      if c.ctl.isNil: unsupported(key)
      c.ctl.style.text = some(col)
      requestRedraw(id)
  of "background":
    let col = colorOf(v)
    when compiles(id.backgroundColor = col): id.backgroundColor = col
    else:
      if c.ctl.isNil: unsupported(key)
      c.ctl.style.background = some(col)
      requestRedraw(id)
  of "bordercolor":
    let col = colorOf(v)
    setAny(id.borderColor, col, key)
  of "accent":
    let col = colorOf(v)
    setAny(id.accentColor, col, key)
  of "radius": setNum(id.radius, numOf(v, "radius"), key)
  of "checked":
    let txt = if truthy(v): "1" else: "0"
    setAny(id.value, txt, key)
  of "min": setNum(id.minBound, numOf(v, "min"), key)
  of "max": setNum(id.maxBound, numOf(v, "max"), key)
  of "theme":
    if c.family == "window":
      let th = themeOf(L.tostr(v), false)
      setAny(id.theme, th, key)
  of "dock", "weight", "fixedwidth", "fixedheight", "stretch", "margin", "spacing", "columns":
    let o = c.ctl
    if o.isNil: rtError("propriété « " & key & " » indisponible pour une fenêtre")
    case key
    of "dock":
      let dk = dockOf(L.tostr(v))
      setAny(o.dock, dk, key)
    of "weight": setNum(o.weight, numOf(v, "weight"), key)
    of "fixedwidth": setNum(o.fixedWidth, numOf(v, "fixedwidth"), key)
    of "fixedheight": setNum(o.fixedHeight, numOf(v, "fixedheight"), key)
    of "stretch":
      let b = truthy(v)
      setAny(o.stretch, b, key)
    of "margin": setNum(Container(o).margin, numOf(v, "margin"), key)
    of "spacing": setNum(Container(o).spacing, numOf(v, "spacing"), key)
    else: setNum(Container(o).columns, numOf(v, "columns"), key)
    requestRedraw(id)
  else:
    if key.startsWith("on"):
      if v.kind notin {vkFunc, vkNil}: rtError("le gestionnaire « " & key & " » doit être une fonction")
      c.handlers.rawSet(key, v)
    else:
      rtError("propriété inconnue « " & key & " » (" & c.family & ")")

proc getProp(L: Interp, c: UiCtl, key: string): Value =
  let id = c.id
  case key
  of "value", "text":
    if key == "text" and c.family in ["label", "button", "window", "page", "cell"]: gCaption(id)
    else: gValue(id)
  of "num": gNum(id)
  of "caption", "title": gCaption(id)
  of "visible": gVisible(id)
  of "state": strV(stateName(id))
  of "enabled": boolV(stateName(id) == "active")
  of "tooltip": gTooltip(id)
  of "name": gName(id)
  of "x": gX(id)
  of "y": gY(id)
  of "width": gWidth(id)
  of "height": gHeight(id)
  of "checked": boolV(id.value == "1")
  of "min": gMin(id)
  of "max": gMax(id)
  of "family", "kind": strV(c.family)
  of "type": typeNameOf(id, c.family)
  else:
    if key.startsWith("on"): c.handlers.rawGet(key) else: nilV

#
# Événements
#

proc buttonName(b: typeof(mbLeft)): string =
  if b == mbRight: "right" elif b == mbMiddle: "middle" else: "left"

template evNum(t: LTable, ev: Event, field: untyped, key: string) =
  when compiles(float(ev.field)): t.set key, numV(float(ev.field))

template evInt(t: LTable, ev: Event, field: untyped, key: string) =
  when compiles(int(ev.field)): t.set key, intV(int(ev.field))

proc buildEvent(L: Interp, st: UiState, ev: Event, kindName: string): LTable =
  let t = newLTable()
  t.set "kind", strV(kindName)
  let target = st.findCtl(ev.id)
  let current = st.findCtl(ev.current)
  if not target.isNil: t.set "id", L.wrapCtl(target)
  if not current.isNil: t.set "current", L.wrapCtl(current)
  evNum(t, ev, x, "x")
  evNum(t, ev, y, "y")
  evNum(t, ev, dx, "dx")
  evNum(t, ev, dy, "dy")
  evInt(t, ev, key, "key")
  evInt(t, ev, modifiers, "modifiers")
  evInt(t, ev, index, "index")
  evInt(t, ev, column, "column")
  when compiles(ev.button == mbLeft): t.set "button", strV(buttonName(ev.button))
  when compiles(ev.isRepeat): t.set "repeat", boolV(ev.isRepeat)
  t.set "text", strV(ev.text)
  if ev.text.contains(TreeSep):
    let path = newLTable()
    for p in ev.text.split(TreeSep): path.arr.add strV(p)
    t.set "path", tableV(path)
  t.set "stop", fnV("stop", proc (L: Interp, a: seq[Value]): seq[Value] =
    if arg(a, 1).kind == vkTable: a[0].t.set("stopped", boolV(true)))
  t

proc eventName(ev: Event): string =
  # Nom Lua d'un événement : « click », « mouseenter », « windowclose »...
  # Selon les versions de wdgui, $ev.kind vaut « evClick » ou « Click ».
  var k = $ev.kind
  if k.len > 2 and k.startsWith("ev") and k[2] in {'A'..'Z'}: k = k[2 .. ^1]
  k.toLowerAscii

proc scriptHandler(ev: var Event) {.nimcall, gcsafe.} =
  # Gestionnaire de toutes les fenêtres du programme Lua. wdgui l'appelle pour
  # la cible puis pour chacun de ses parents (ev.current) ; on exécute à chaque
  # niveau le gestionnaire on<événement> de l'objet Lua correspondant.
  {.cast(gcsafe).}:
    # interpréteur propriétaire de la fenêtre de l'événement.
    var L: Interp = nil
    withLock uiLock:
      for cand in uiInterps:
        let r = cand.ext.getOrDefault("ui")
        if r.isNil: continue
        for w in UiState(r).windows:
          if w.id == ev.window:
            L = cand
            break
        if not L.isNil: break
    if L.isNil or L.stopRequested(): return
    let kindName = eventName(ev)
    L.enter()
    try:
      curCtx = Ctx()
      let st = L.uiState
      let cur = st.findCtl(ev.current)
      if st.trace and kindName notin ["mousemove", "mouseenter", "mouseleave"]:
        L.output("[ui] " & kindName & " id=" & idText(ev.id) & " current=" & idText(ev.current) &
                 " objet=" & (if cur.isNil: "aucun" else: cur.family) &
                 (if cur.isNil: "" else: " gestionnaire=" &
                    (if cur.handlers.rawGet("on" & kindName).kind == vkNil: "non" else: "oui")) & "\n")
      if not cur.isNil:
        if ev.kind == evWindowClose and cur.family == "window": cur.closed = true
        let h = cur.handlers.rawGet("on" & kindName)
        let g = cur.handlers.rawGet("onevent")
        if h.kind != vkNil or g.kind != vkNil:
          let evT = L.buildEvent(st, ev, kindName)
          if h.kind != vkNil: discard L.call(h, @[tableV(evT)])
          if g.kind != vkNil: discard L.call(g, @[tableV(evT)])
          if truthy(evT.rawGet("stopped")): ev.stopPropagation()
    except LuaStop:
      discard
    except LuaError as e:
      L.onError(e.msg & "\n" & e.traceback)
    except Exception as e:
      # y compris les Defect de Nim, qui sinon tueraient le thread en silence :-/
      L.onError("erreur interne dans le gestionnaire ui (" & kindName & ") : " & e.msg)
    finally:
      L.leave()

#
# Objets contrôles
#

var familyMethods: Table[string, LTable]

proc register(L: Interp, c: UiCtl): Value =
  c.handlers = newLTable()
  c.tname = "ui." & c.family
  c.meta = ctlMeta
  L.uiState.ctls.add c
  if c.family == "window": L.uiState.windows.add c
  userV(c)

proc wrapCtl(L: Interp, c: UiCtl): Value = userV(c)

proc newCtl(L: Interp, ctl: Control, family: string): Value =
  L.register(UiCtl(rawId: ctl.id, ctl: ctl, family: family))

proc mfn(family, name: string, p: NativeProc) =
  if not familyMethods.hasKey(family): familyMethods[family] = newLTable()
  familyMethods[family].fn name, p

proc self(L: Interp, a: seq[Value], fname: string): UiCtl =
  let v = arg(a, 1)
  if v.kind != vkUser or not (v.u of UiCtl): rtError("'" & fname & "' : appelez-la avec « : » (obj:" & fname & "(...))")
  UiCtl(v.u)

proc strs(L: Interp, a: seq[Value], start: int, fname: string): seq[string] =
  # Arguments chaînes à partir de `start`, ou une table de chaînes.
  if arg(a, start).kind == vkTable:
    let t = a[start - 1].t
    for i in 1 .. t.rawLen: result.add L.tostr(t.rawGet(intV(i)))
  else:
    for i in start .. a.len: result.add L.tostr(a[i - 1])

proc pathOf(L: Interp, a: seq[Value], start: int, fname: string): string =
  # Chemin d'arbre / de menu : "A", "B" ou {"A", "B"} ou "A/B".
  var parts = L.strs(a, start, fname)
  if parts.len == 1 and TreeSep notin parts[0] and '/' in parts[0]:
    parts = parts[0].split('/')
  parts.join($TreeSep)

template colArg(v: Value, body: untyped) =
  # Colonne de grille par nom ou par index.
  if v.kind == vkStr:
    let col {.inject.} = v.s
    body
  else:
    var okc: bool
    let col {.inject.} = int(toInteger(v, okc))
    if not okc: rtError("colonne attendue (nom ou index)")
    body

proc ctlIndex(L: Interp, a: seq[Value]): seq[Value] =
  let c = UiCtl(a[0].u)
  let key = arg(a, 2)
  if key.kind != vkStr: return @[nilV]
  if familyMethods.hasKey(c.family):
    let m = familyMethods[c.family].rawGet(key.s)
    if m.kind != vkNil: return @[m]
  let common = familyMethods.getOrDefault("*")
  if not common.isNil:
    let m = common.rawGet(key.s)
    if m.kind != vkNil: return @[m]
  @[L.getProp(c, key.s)]

proc ctlNewIndex(L: Interp, a: seq[Value]): seq[Value] =
  let c = UiCtl(a[0].u)
  let key = arg(a, 2)
  if key.kind != vkStr: rtError("nom de propriété attendu")
  L.setProp(c, key.s, arg(a, 3))

proc addChildTo(L: Interp, parent: UiCtl, child: UiCtl) =
  if child.ctl.isNil: rtError("une fenêtre ne peut pas être ajoutée à un conteneur")
  if parent.family == "window":
    discard parent.win.addChild(child.ctl)
  elif parent.ctl of Container:
    discard Container(parent.ctl).addChild(child.ctl)
  else:
    rtError("« " & parent.family & " » n'est pas un conteneur")

proc defineMethods() =
  # communs
  mfn "*", "add", proc (L: Interp, a: seq[Value]): seq[Value] =
    let p = L.self(a, "add")
    for i in 2 .. a.len:
      L.addChildTo(p, ctlOf(a[i - 1], "contrôle à ajouter"))
    @[arg(a, 2)]
  mfn "*", "focus", proc (L: Interp, a: seq[Value]): seq[Value] =
    setFocus(L.self(a, "focus").id)
  mfn "*", "contextmenu", proc (L: Interp, a: seq[Value]): seq[Value] =
    let c = L.self(a, "contextmenu")
    openContextMenu(c.id, L.strs(a, 2, "contextmenu"))
  mfn "*", "redraw", proc (L: Interp, a: seq[Value]): seq[Value] =
    requestRedraw(L.self(a, "redraw").id)

  # fenêtre
  mfn "window", "close", proc (L: Interp, a: seq[Value]): seq[Value] =
    let w = L.self(a, "close")
    if not w.closed:
      w.closed = true
      closeWindow(w.id)
  mfn "window", "settheme", proc (L: Interp, a: seq[Value]): seq[Value] =
    let w = L.self(a, "settheme")
    let th = themeOf(L.optStr(a, 2, "settheme", "native"), optBool(a, 3, false))
    setAny(w.id.theme, th, "theme")

  # onglets
  mfn "tab", "addpage", proc (L: Interp, a: seq[Value]): seq[Value] =
    let t = L.self(a, "addpage")
    let page = typeof(newTab())(t.ctl).addPage(L.checkStr(a, 2, "addpage"), layoutOf(L.optStr(a, 3, "addpage", "vertical")))
    @[L.newCtl(page, "page")]

  # listes et combos
  for fam in ["list", "combo"]:
    mfn fam, "add", proc (L: Interp, a: seq[Value]): seq[Value] =
      let c = L.self(a, "add")
      var last = 0
      for s in L.strs(a, 2, "add"): last = listAdd(c.id, s)
      @[intV(last)]
    mfn fam, "insert", proc (L: Interp, a: seq[Value]): seq[Value] =
      let c = L.self(a, "insert")
      let idx = int(L.checkInt(a, 2, "insert"))
      let item = L.checkStr(a, 3, "insert")
      listInsert(c.id, item, idx)
    mfn fam, "delete", proc (L: Interp, a: seq[Value]): seq[Value] =
      listDelete(L.self(a, "delete").id, int(L.checkInt(a, 2, "delete")))
    mfn fam, "clear", proc (L: Interp, a: seq[Value]): seq[Value] =
      listDeleteAll(L.self(a, "clear").id)
    mfn fam, "select", proc (L: Interp, a: seq[Value]): seq[Value] =
      listSelectPlus(L.self(a, "select").id, int(L.checkInt(a, 2, "select")))
    mfn fam, "unselect", proc (L: Interp, a: seq[Value]): seq[Value] =
      listSelectMinus(L.self(a, "unselect").id, int(L.checkInt(a, 2, "unselect")))
    mfn fam, "selected", proc (L: Interp, a: seq[Value]): seq[Value] =
      let v = L.self(a, "selected").id.value
      try: @[intV(parseInt(v))] except ValueError: @[intV(0)]
    mfn fam, "count", proc (L: Interp, a: seq[Value]): seq[Value] =
      @[intV(listCount(L.self(a, "count").id))]
    mfn fam, "item", proc (L: Interp, a: seq[Value]): seq[Value] =
      @[strV(listItem(L.self(a, "item").id, int(L.checkInt(a, 2, "item"))))]
    mfn fam, "modify", proc (L: Interp, a: seq[Value]): seq[Value] =
      listModify(L.self(a, "modify").id, L.checkStr(a, 3, "modify"), int(L.checkInt(a, 2, "modify")))
    mfn fam, "seek", proc (L: Interp, a: seq[Value]): seq[Value] =
      @[intV(listSeek(L.self(a, "seek").id, L.checkStr(a, 2, "seek")))]

  # able simple
  mfn "table", "addcolumn", proc (L: Interp, a: seq[Value]): seq[Value] =
    let c = L.self(a, "addcolumn")
    let title = L.checkStr(a, 2, "addcolumn")
    let w = L.optNum(a, 3, "addcolumn", 120)
    let al = alignOf(L.optStr(a, 4, "addcolumn", "left"))
    tableAddColumn(c.id, title, w, al)
  mfn "table", "addline", proc (L: Interp, a: seq[Value]): seq[Value] =
    @[anyV(tableAddLine(L.self(a, "addline").id, L.strs(a, 2, "addline")))]
  mfn "table", "insertline", proc (L: Interp, a: seq[Value]): seq[Value] =
    tableInsertLine(L.self(a, "insertline").id, int(L.checkInt(a, 2, "insertline")), L.strs(a, 3, "insertline"))
  mfn "table", "delete", proc (L: Interp, a: seq[Value]): seq[Value] =
    tableDelete(L.self(a, "delete").id, int(L.checkInt(a, 2, "delete")))
  mfn "table", "clear", proc (L: Interp, a: seq[Value]): seq[Value] =
    tableDeleteAll(L.self(a, "clear").id)
  mfn "table", "selected", proc (L: Interp, a: seq[Value]): seq[Value] =
    @[intV(tableSelect(L.self(a, "selected").id))]
  mfn "table", "select", proc (L: Interp, a: seq[Value]): seq[Value] =
    tableSelectPlus(L.self(a, "select").id, int(L.checkInt(a, 2, "select")))
  mfn "table", "count", proc (L: Interp, a: seq[Value]): seq[Value] =
    @[intV(tableCount(L.self(a, "count").id))]
  mfn "table", "cell", proc (L: Interp, a: seq[Value]): seq[Value] =
    @[strV(tableCell(L.self(a, "cell").id, int(L.checkInt(a, 2, "cell")), int(L.checkInt(a, 3, "cell"))))]
  mfn "table", "setcell", proc (L: Interp, a: seq[Value]): seq[Value] =
    tableSetCell(L.self(a, "setcell").id, int(L.checkInt(a, 2, "setcell")), int(L.checkInt(a, 3, "setcell")),
                 L.checkStr(a, 4, "setcell"))
  mfn "table", "line", proc (L: Interp, a: seq[Value]): seq[Value] =
    @[toV(tableLine(L.self(a, "line").id, int(L.checkInt(a, 2, "line"))))]
  mfn "table", "sort", proc (L: Interp, a: seq[Value]): seq[Value] =
    tableSort(L.self(a, "sort").id, int(L.checkInt(a, 2, "sort")), ascending = optBool(a, 3, true))

  # arbre
  mfn "tree", "add", proc (L: Interp, a: seq[Value]): seq[Value] =
    treeAdd(L.self(a, "add").id, L.pathOf(a, 2, "add"))
  mfn "tree", "delete", proc (L: Interp, a: seq[Value]): seq[Value] =
    treeDelete(L.self(a, "delete").id, L.pathOf(a, 2, "delete"))
  mfn "tree", "clear", proc (L: Interp, a: seq[Value]): seq[Value] =
    treeDeleteAll(L.self(a, "clear").id)
  mfn "tree", "expand", proc (L: Interp, a: seq[Value]): seq[Value] =
    treeExpand(L.self(a, "expand").id, L.pathOf(a, 2, "expand"))
  mfn "tree", "collapse", proc (L: Interp, a: seq[Value]): seq[Value] =
    treeCollapse(L.self(a, "collapse").id, L.pathOf(a, 2, "collapse"))
  mfn "tree", "isexpanded", proc (L: Interp, a: seq[Value]): seq[Value] =
    @[boolV(treeIsExpanded(L.self(a, "isexpanded").id, L.pathOf(a, 2, "isexpanded")))]
  mfn "tree", "select", proc (L: Interp, a: seq[Value]): seq[Value] =
    let c = L.self(a, "select")
    when compiles(treeSelectPlus(c.id, "")): treeSelectPlus(c.id, L.pathOf(a, 2, "select"))
  mfn "tree", "count", proc (L: Interp, a: seq[Value]): seq[Value] =
    let c = L.self(a, "count")
    when compiles(treeCount(c.id)): result = @[intV(treeCount(c.id))]

  # menu
  mfn "menubar", "add", proc (L: Interp, a: seq[Value]): seq[Value] =
    menuAdd(L.self(a, "add").id, L.pathOf(a, 2, "add"))

  # cases à cocher, boutons radio
  mfn "check", "checked", proc (L: Interp, a: seq[Value]): seq[Value] =
    let v = checkBoxValue(L.self(a, "checked").id, int(L.optInt(a, 2, "checked", 1)))
    when v is bool: result = @[boolV(v)]
    elif v is string: result = @[boolV(v == "1")]
    else: result = @[boolV(v != 0)]
  mfn "check", "setchecked", proc (L: Interp, a: seq[Value]): seq[Value] =
    checkBoxSet(L.self(a, "setchecked").id, int(L.checkInt(a, 2, "setchecked")), optBool(a, 3, true))
  mfn "check", "addoption", proc (L: Interp, a: seq[Value]): seq[Value] =
    let c = L.self(a, "addoption")
    doCall(checkBoxAdd(c.id, L.checkStr(a, 2, "addoption")))
  mfn "radio", "addoption", proc (L: Interp, a: seq[Value]): seq[Value] =
    let c = L.self(a, "addoption")
    doCall(radioAdd(c.id, L.checkStr(a, 2, "addoption")))

  # graphe, calendrier, planning
  mfn "chart", "adddata", proc (L: Interp, a: seq[Value]): seq[Value] =
    grAddData(L.self(a, "adddata").id, int(L.checkInt(a, 2, "adddata")), int(L.checkInt(a, 3, "adddata")),
              L.checkNum(a, 4, "adddata"))
  mfn "chart", "categorylabel", proc (L: Interp, a: seq[Value]): seq[Value] =
    grCategoryLabel(L.self(a, "categorylabel").id, int(L.checkInt(a, 2, "categorylabel")), L.checkStr(a, 3, "categorylabel"))
  mfn "chart", "serieslabel", proc (L: Interp, a: seq[Value]): seq[Value] =
    grSeriesLabel(L.self(a, "serieslabel").id, int(L.checkInt(a, 2, "serieslabel")), L.checkStr(a, 3, "serieslabel"))
  mfn "chart", "settype", proc (L: Interp, a: seq[Value]): seq[Value] =
    grType(L.self(a, "settype").id, chartKindOf(L.checkStr(a, 2, "settype")))
  mfn "calendar", "show", proc (L: Interp, a: seq[Value]): seq[Value] =
    calendarShow(L.self(a, "show").id, int(L.checkInt(a, 2, "show")), int(L.checkInt(a, 3, "show")))
  mfn "kanban", "addlist", proc (L: Interp, a: seq[Value]): seq[Value] =
    @[anyV(kanbanAddList(L.self(a, "addlist").id, L.checkStr(a, 2, "addlist")))]
  mfn "kanban", "add", proc (L: Interp, a: seq[Value]): seq[Value] =
    @[anyV(kanbanAdd(L.self(a, "add").id, int(L.checkInt(a, 2, "add")), L.checkStr(a, 3, "add")))]
  mfn "treemap", "add", proc (L: Interp, a: seq[Value]): seq[Value] =
    let c = L.self(a, "add")
    let lbl = L.checkStr(a, 2, "add")
    let v = L.checkNum(a, 3, "add")
    treeMapAdd(c.id, lbl, v)
  mfn "gantt", "addtask", proc (L: Interp, a: seq[Value]): seq[Value] =
    @[anyV(ganttAddTask(L.self(a, "addtask").id, L.checkStr(a, 2, "addtask"),
                        start = L.checkNum(a, 3, "addtask"), duration = L.checkNum(a, 4, "addtask"),
                        progress = L.optNum(a, 5, "addtask", 0)))]
  mfn "gantt", "setprogress", proc (L: Interp, a: seq[Value]): seq[Value] =
    ganttSetProgress(L.self(a, "setprogress").id, int(L.checkInt(a, 2, "setprogress")), L.checkNum(a, 3, "setprogress"))

  # panneau défilant.
  mfn "panel", "scrollto", proc (L: Interp, a: seq[Value]): seq[Value] =
    let c = L.self(a, "scrollto")
    let x = L.checkNum(a, 2, "scrollto")
    let y = L.checkNum(a, 3, "scrollto")
    panelScrollTo(c.id, x, y)
  mfn "panel", "scrollby", proc (L: Interp, a: seq[Value]): seq[Value] =
    let c = L.self(a, "scrollby")
    let x = L.checkNum(a, 2, "scrollby")
    let y = L.checkNum(a, 3, "scrollby")
    panelScrollBy(c.id, x, y)
  mfn "panel", "ensurevisible", proc (L: Interp, a: seq[Value]): seq[Value] =
    panelEnsureVisible(L.self(a, "ensurevisible").id, ctlOf(arg(a, 2)).id)

  # grille.
  mfn "grid", "addcolumn", proc (L: Interp, a: seq[Value]): seq[Value] =
    let g = L.self(a, "addcolumn")
    var name, title, kind: string
    var width = 120.0
    var choices: seq[string]
    var decimals = -1
    if arg(a, 2).kind == vkTable:
      let o = a[1].t
      name = optField(o, "name", "")
      title = optField(o, "title", name)
      kind = optField(o, "kind", "text")
      width = optField(o, "width", 120.0)
      decimals = optField(o, "decimals", -1)
      let ch = o.rawGet("choices")
      if ch.kind == vkTable:
        for i in 1 .. ch.t.rawLen: choices.add L.tostr(ch.t.rawGet(intV(i)))
    else:
      name = L.checkStr(a, 2, "addcolumn")
      title = L.optStr(a, 3, "addcolumn", name)
      kind = L.optStr(a, 4, "addcolumn", "text")
      width = L.optNum(a, 5, "addcolumn", 120)
    var colId: ControlId
    let gk = gridKindOf(kind)
    when compiles(gridAddColumn(g.id, name, title, gk, width, choices = choices, decimals = decimals)):
      colId = gridAddColumn(g.id, name, title, gk, width, choices = choices, decimals = decimals)
    else:
      colId = gridAddColumn(g.id, name, title, gk, width)
      if choices.len > 0: gridSetChoices(g.id, name, choices)
      if decimals >= 0: gridSetDecimals(g.id, name, decimals)
    @[L.register(UiCtl(rawId: colId, family: "gridcolumn"))]
  mfn "grid", "addline", proc (L: Interp, a: seq[Value]): seq[Value] =
    @[anyV(gridAddLine(L.self(a, "addline").id, L.strs(a, 2, "addline")))]
  mfn "grid", "insertline", proc (L: Interp, a: seq[Value]): seq[Value] =
    gridInsertLine(L.self(a, "insertline").id, int(L.checkInt(a, 2, "insertline")), L.strs(a, 3, "insertline"))
  mfn "grid", "modifyline", proc (L: Interp, a: seq[Value]): seq[Value] =
    gridModifyLine(L.self(a, "modifyline").id, int(L.checkInt(a, 2, "modifyline")), L.strs(a, 3, "modifyline"))
  mfn "grid", "deleteline", proc (L: Interp, a: seq[Value]): seq[Value] =
    gridDeleteLine(L.self(a, "deleteline").id, int(L.checkInt(a, 2, "deleteline")))
  mfn "grid", "clear", proc (L: Interp, a: seq[Value]): seq[Value] =
    gridDeleteAll(L.self(a, "clear").id)
  mfn "grid", "cell", proc (L: Interp, a: seq[Value]): seq[Value] =
    let g = L.self(a, "cell")
    let row = int(L.checkInt(a, 2, "cell"))
    colArg(arg(a, 3)):
      result = @[strV(gridCell(g.id, row, col))]
  mfn "grid", "setcell", proc (L: Interp, a: seq[Value]): seq[Value] =
    let g = L.self(a, "setcell")
    let row = int(L.checkInt(a, 2, "setcell"))
    let v = L.tostr(arg(a, 4))
    colArg(arg(a, 3)):
      gridSetCell(g.id, row, col, v)
  mfn "grid", "line", proc (L: Interp, a: seq[Value]): seq[Value] =
    @[toV(gridLine(L.self(a, "line").id, int(L.checkInt(a, 2, "line"))))]
  mfn "grid", "count", proc (L: Interp, a: seq[Value]): seq[Value] =
    @[intV(gridCount(L.self(a, "count").id))]
  mfn "grid", "columncount", proc (L: Interp, a: seq[Value]): seq[Value] =
    @[intV(gridColumnCount(L.self(a, "columncount").id))]
  mfn "grid", "column", proc (L: Interp, a: seq[Value]): seq[Value] =
    let g = L.self(a, "column")
    var cid: ControlId
    colArg(arg(a, 2)):
      cid = gridColumn(g.id, col)
    let existing = L.uiState.findCtl(cid)
    if not existing.isNil: return @[userV(existing)]
    @[L.register(UiCtl(rawId: cid, family: "gridcolumn"))]
  mfn "grid", "selected", proc (L: Interp, a: seq[Value]): seq[Value] =
    @[intV(gridSelect(L.self(a, "selected").id, int(L.optInt(a, 2, "selected", 1))))]
  mfn "grid", "selectcount", proc (L: Interp, a: seq[Value]): seq[Value] =
    @[intV(gridSelectCount(L.self(a, "selectcount").id))]
  mfn "grid", "select", proc (L: Interp, a: seq[Value]): seq[Value] =
    gridSelectPlus(L.self(a, "select").id, int(L.checkInt(a, 2, "select")))
  mfn "grid", "unselect", proc (L: Interp, a: seq[Value]): seq[Value] =
    gridSelectMinus(L.self(a, "unselect").id, int(L.checkInt(a, 2, "unselect")))
  mfn "grid", "selectall", proc (L: Interp, a: seq[Value]): seq[Value] =
    gridSelectAll(L.self(a, "selectall").id)
  mfn "grid", "sort", proc (L: Interp, a: seq[Value]): seq[Value] =
    let g = L.self(a, "sort")
    let asc = optBool(a, 3, true)
    colArg(arg(a, 2)):
      gridSort(g.id, col, ascending = asc)
  mfn "grid", "seek", proc (L: Interp, a: seq[Value]): seq[Value] =
    let g = L.self(a, "seek")
    let value = L.checkStr(a, 3, "seek")
    let exact = optBool(a, 4, true)
    let start = int(L.optInt(a, 5, "seek", 1))
    colArg(arg(a, 2)):
      result = @[intV(gridSeek(g.id, col, value, exact = exact, start = start))]
  mfn "grid", "find", proc (L: Interp, a: seq[Value]): seq[Value] =
    let f = gridFind(L.self(a, "find").id, L.checkStr(a, 2, "find"))
    @[intV(f.row), intV(f.column)]
  mfn "grid", "setfooter", proc (L: Interp, a: seq[Value]): seq[Value] =
    let g = L.self(a, "setfooter")
    let k = footerOf(L.optStr(a, 3, "setfooter", "sum"))
    colArg(arg(a, 2)):
      gridSetFooter(g.id, col, k)
  mfn "grid", "footervalue", proc (L: Interp, a: seq[Value]): seq[Value] =
    let g = L.self(a, "footervalue")
    let kv = arg(a, 3)
    colArg(arg(a, 2)):
      if kv.kind == vkNil: result = @[strV($gridFooterValue(g.id, col))]
      else: result = @[strV($gridFooterValue(g.id, col, footerOf(L.tostr(kv))))]
  mfn "grid", "addformat", proc (L: Interp, a: seq[Value]): seq[Value] =
    let g = L.self(a, "addformat")
    let op = compareOf(L.checkStr(a, 3, "addformat"))
    let value = L.optStr(a, 4, "addformat", "")
    let o = if arg(a, 5).kind == vkTable: a[4].t else: nil
    let bg = optField(o, "background", "")
    let fg = optField(o, "text", "")
    let whole = optField(o, "wholerow", false)
    let bgc = if bg.len > 0: hex(bg) else: Transparent
    let fgc = if fg.len > 0: hex(fg) else: Transparent
    colArg(arg(a, 2)):
      when compiles(gridAddFormat(g.id, col, op, value, background = bgc, text = fgc, wholeRow = whole)):
        gridAddFormat(g.id, col, op, value, background = bgc, text = fgc, wholeRow = whole)
      elif compiles(gridAddFormat(g.id, col, op, value, bgc, fgc, whole)):
        gridAddFormat(g.id, col, op, value, bgc, fgc, whole)
      else:
        rtError("grid:addformat : signature de gridAddFormat non reconnue")
  mfn "grid", "clearformats", proc (L: Interp, a: seq[Value]): seq[Value] =
    gridClearFormats(L.self(a, "clearformats").id)
  mfn "grid", "setbreak", proc (L: Interp, a: seq[Value]): seq[Value] =
    let g = L.self(a, "setbreak")
    if arg(a, 2).kind == vkNil: gridSetBreak(g.id, "")
    else:
      colArg(arg(a, 2)):
        gridSetBreak(g.id, col)
  mfn "grid", "seteditable", proc (L: Interp, a: seq[Value]): seq[Value] =
    gridSetEditable(L.self(a, "seteditable").id, optBool(a, 2, true))
  mfn "grid", "setcolumnedit", proc (L: Interp, a: seq[Value]): seq[Value] =
    let g = L.self(a, "setcolumnedit")
    let m = editModeOf(L.checkStr(a, 3, "setcolumnedit"))
    colArg(arg(a, 2)):
      gridSetColumnEdit(g.id, col, m)
  mfn "grid", "setlineedit", proc (L: Interp, a: seq[Value]): seq[Value] =
    gridSetLineEdit(L.self(a, "setlineedit").id, int(L.checkInt(a, 2, "setlineedit")),
                    editModeOf(L.checkStr(a, 3, "setlineedit")))
  mfn "grid", "setfillmode", proc (L: Interp, a: seq[Value]): seq[Value] =
    gridSetFillMode(L.self(a, "setfillmode").id, fillModeOf(L.checkStr(a, 2, "setfillmode")))
  mfn "grid", "setbuttoncaption", proc (L: Interp, a: seq[Value]): seq[Value] =
    let g = L.self(a, "setbuttoncaption")
    let cap = L.checkStr(a, 3, "setbuttoncaption")
    colArg(arg(a, 2)):
      gridSetButtonCaption(g.id, col, cap)
  mfn "grid", "startedit", proc (L: Interp, a: seq[Value]): seq[Value] =
    let g = L.self(a, "startedit")
    let row = int(L.checkInt(a, 2, "startedit"))
    colArg(arg(a, 3)):
      gridStartEdit(g.id, row, col)
  mfn "grid", "tocsv", proc (L: Interp, a: seq[Value]): seq[Value] =
    let sep = L.optStr(a, 2, "tocsv", ",")
    @[strV(gridToCsv(L.self(a, "tocsv").id, sep = sep[0], header = optBool(a, 3, true)))]
  mfn "grid", "fromcsv", proc (L: Interp, a: seq[Value]): seq[Value] =
    @[anyV(gridFromCsv(L.self(a, "fromcsv").id, L.checkStr(a, 2, "fromcsv"), append = optBool(a, 3, false)))]
  mfn "grid", "loadcsv", proc (L: Interp, a: seq[Value]): seq[Value] =
    let sep = L.optStr(a, 3, "loadcsv", ",")
    @[anyV(gridLoadCsv(L.self(a, "loadcsv").id, L.checkStr(a, 2, "loadcsv"), sep = sep[0]))]
  mfn "grid", "savecsv", proc (L: Interp, a: seq[Value]): seq[Value] =
    let sep = L.optStr(a, 3, "savecsv", ",")
    @[anyV(gridSaveCsv(L.self(a, "savecsv").id, L.checkStr(a, 2, "savecsv"), sep = sep[0]))]
  mfn "grid", "tojson", proc (L: Interp, a: seq[Value]): seq[Value] =
    @[strV(gridToJson(L.self(a, "tojson").id, pretty = optBool(a, 2, true)))]
  mfn "grid", "loadjson", proc (L: Interp, a: seq[Value]): seq[Value] =
    @[anyV(gridLoadJson(L.self(a, "loadjson").id, L.checkStr(a, 2, "loadjson")))]
  mfn "grid", "savejson", proc (L: Interp, a: seq[Value]): seq[Value] =
    @[anyV(gridSaveJson(L.self(a, "savejson").id, L.checkStr(a, 2, "savejson")))]

  # visionneuse PDF.
  mfn "pdf", "open", proc (L: Interp, a: seq[Value]): seq[Value] =
    @[anyV(pdfOpen(L.self(a, "open").id, L.checkStr(a, 2, "open"), L.optStr(a, 3, "open", "")))]
  mfn "pdf", "new", proc (L: Interp, a: seq[Value]): seq[Value] =
    let c = L.self(a, "new")
    let w = L.optNum(a, 2, "new", 595)
    let h = L.optNum(a, 3, "new", 842)
    @[boolV(pdfNew(c.id, w, h))]
  mfn "pdf", "save", proc (L: Interp, a: seq[Value]): seq[Value] =
    @[anyV(pdfSave(L.self(a, "save").id, L.optStr(a, 2, "save", "")))]
  mfn "pdf", "close", proc (L: Interp, a: seq[Value]): seq[Value] =
    doCall(pdfClose(L.self(a, "close").id))
  mfn "pdf", "pagecount", proc (L: Interp, a: seq[Value]): seq[Value] =
    @[anyV(pdfPageCount(L.self(a, "pagecount").id))]
  mfn "pdf", "page", proc (L: Interp, a: seq[Value]): seq[Value] =
    @[anyV(pdfCurrentPage(L.self(a, "page").id))]
  mfn "pdf", "goto", proc (L: Interp, a: seq[Value]): seq[Value] =
    doCall(pdfGoto(L.self(a, "goto").id, int(L.checkInt(a, 2, "goto"))))
  mfn "pdf", "zoom", proc (L: Interp, a: seq[Value]): seq[Value] =
    doCall(pdfSetZoom(L.self(a, "zoom").id, L.checkNum(a, 2, "zoom")))
  mfn "pdf", "addtext", proc (L: Interp, a: seq[Value]): seq[Value] =
    let c = L.self(a, "addtext")
    let pg = int(L.checkInt(a, 2, "addtext"))
    let x = L.checkNum(a, 3, "addtext")
    let y = L.checkNum(a, 4, "addtext")
    let txt = L.checkStr(a, 5, "addtext")
    let size = L.optNum(a, 6, "addtext", 14)
    pdfAddText(c.id, pg, x, y, txt, size)
  mfn "pdf", "importpages", proc (L: Interp, a: seq[Value]): seq[Value] =
    let err = pdfImportPages(L.self(a, "importpages").id, L.checkStr(a, 2, "importpages"),
                             L.optStr(a, 3, "importpages", ""), int(L.optInt(a, 4, "importpages", 1)))
    if err.len > 0: fail(err) else: @[boolV(true)]

proc openUi(L: Interp): Value =
  if familyMethods.len == 0: defineMethods()
  ctlMeta = newLTable()
  ctlMeta.set "__index", fnV("ui.index", ctlIndex)
  ctlMeta.set "__newindex", fnV("ui.newindex", ctlNewIndex)
  ctlMeta.set "__name", strV("ui.control")
  ctlMeta.set "__eq", fnV("ui.eq", proc (L: Interp, a: seq[Value]): seq[Value] =
    @[boolV(UiCtl(a[0].u).id == UiCtl(a[1].u).id)])
  withLock uiLock: uiInterps.add L
  L.closers.add proc () =
    {.cast(gcsafe).}:
      withLock uiLock:
        let i = uiInterps.find(L)
        if i >= 0: uiInterps.delete(i)

  let m = newLib()
  m.set "SEP", strV($TreeSep)

  template ctor(name, family: string, body: untyped) {.dirty.} =
    m.fn name, proc (L: Interp, a: seq[Value]): seq[Value] =
      let made: Control = body
      @[L.newCtl(made, family)]

  m.fn "window", proc (L: Interp, a: seq[Value]): seq[Value] =
    let o = if arg(a, 1).kind == vkTable: a[0].t else: nil
    let title = if arg(a, 1).kind == vkStr: a[0].s else: optField(o, "title", "wdlua")
    let w = newWindow(title, optField(o, "width", 640), optField(o, "height", 480), scriptHandler,
                      layout = layoutOf(optField(o, "layout", "vertical")),
                      theme = themeOf(optField(o, "theme", "native"), optField(o, "dark", false)))
    let c = UiCtl(rawId: w.id, win: w, family: "window")
    @[L.register(c)]
  ctor("label", "label"):
    newLabel(L.optStr(a, 1, "label", ""), alignOf(L.optStr(a, 2, "label", "left")))
  m.fn "button", proc (L: Interp, a: seq[Value]): seq[Value] =
    let o = if arg(a, 2).kind == vkTable: a[1].t else: nil
    let b = newButton(L.optStr(a, 1, "button", "OK"), isDefault = optField(o, "default", false),
                      isCancel = optField(o, "cancel", false))
    @[L.newCtl(b, "button")]
  m.fn "edit", proc (L: Interp, a: seq[Value]): seq[Value] =
    let o = if arg(a, 1).kind == vkTable: a[0].t else: nil
    let txt = if arg(a, 1).kind == vkStr: a[0].s else: optField(o, "text", "")
    var e: Control
    if optField(o, "multiline", false): e = newMultilineEdit(txt)
    elif optField(o, "placeholder", "").len > 0: e = newEdit(placeholder = optField(o, "placeholder", ""))
    else: e = newEdit(txt)
    @[L.newCtl(e, "edit")]
  ctor("checkbox", "check"):
    newCheckBox(L.strs(a, 1, "checkbox"))
  ctor("radio", "radio"):
    newRadioButtonCompat(L.strs(a, 1, "radio"))
  ctor("list", "list"):
    newListBox(multiSelection = optBool(a, 1, false))
  ctor("combo", "combo"):
    newComboBox(L.strs(a, 1, "combo"))
  ctor("table", "table"):
    newTable(multiSelection = false)
  ctor("tree", "tree"):
    newTreeView()
  m.fn "grid", proc (L: Interp, a: seq[Value]): seq[Value] =
    let o = if arg(a, 1).kind == vkTable: a[0].t else: nil
    let g = newGrid(multiSelection = optField(o, "multi", false),
                    fillMode = fillModeOf(optField(o, "fill", "programmed")))
    @[L.newCtl(g, "grid")]
  ctor("progress", "progress"):
    newProgressBar()
  ctor("slider", "slider"):
    newControlCompat("slider")
  ctor("rangeslider", "range"):
    newControlCompat("rangeslider")
  ctor("scrollbar", "scroll"):
    newControlCompat("scrollbar")
  ctor("spin", "spin"):
    newControlCompat("spin")
  ctor("rating", "rating"):
    newControlCompat("rating")
  ctor("image", "image"):
    newImageCompat(L.optStr(a, 1, "image", ""))
  ctor("barcode", "barcode"):
    newBarCodeCompat(L.optStr(a, 1, "barcode", ""))
  ctor("chart", "chart"):
    newChart(chartKindOf(L.optStr(a, 1, "chart", "column")), L.optStr(a, 2, "chart", ""))
  ctor("calendar", "calendar"):
    newCalendar(L.optStr(a, 1, "calendar", ""))
  ctor("kanban", "kanban"):
    newControlCompat("kanban")
  ctor("treemap", "treemap"):
    newControlCompat("treemap")
  ctor("gantt", "gantt"):
    newControlCompat("gantt")
  ctor("menubar", "menubar"):
    newMenuBar()
  ctor("tab", "tab"):
    newTab()
  m.fn "splitter", proc (L: Interp, a: seq[Value]): seq[Value] =
    let o = if arg(a, 1).kind == vkTable: a[0].t else: nil
    let sp = newSplitter(vertical = optField(o, "vertical", true), position = optField(o, "position", 0.5))
    @[L.newCtl(sp, "splitter")]
  ctor("container", "container"):
    newContainer(layoutOf(L.optStr(a, 1, "container", "vertical")), columns = int(L.optInt(a, 2, "container", 2)))
  ctor("vbox", "container"):
    newContainer(lkVertical)
  ctor("hbox", "container"):
    newContainer(lkHorizontal)
  ctor("supercontrol", "container"):
    newSupercontrol(layoutOf(L.optStr(a, 1, "supercontrol", "vertical")))
  ctor("cell", "cell"):
    newCell(layoutOf(L.optStr(a, 2, "cell", "vertical")), L.optStr(a, 1, "cell", ""))
  m.fn "panel", proc (L: Interp, a: seq[Value]): seq[Value] =
    let o = if arg(a, 1).kind == vkTable: a[0].t else: nil
    var sb = smAlways
    case optField(o, "scrollbars", "always")
    of "automatic": sb = smAutomatic
    of "hidden": sb = smHidden
    else: discard
    let lk = layoutOf(optField(o, "layout", "vertical"))
    var pn: Control
    when compiles(newPanel(lk, scrollbars = sb, columns = 2)):
      pn = newPanel(lk, scrollbars = sb, columns = optField(o, "columns", 2))
    else:
      pn = newPanel(lk, scrollbars = sb)
    @[L.newCtl(pn, "panel")]
  ctor("pdf", "pdf"):
    newPdfViewer()

  # boucle et dialogues.
  m.fn "run", proc (L: Interp, a: seq[Value]): seq[Value] =
    let st = L.uiState
    if L.hosted:
      L.blocking:
        while L.openWindows() > 0 and not L.stopRequested(): sleep(30)
    elif not st.loopRunning:
      st.loopRunning = true
      L.blocking: runApplication()
    L.checkStop()
  m.fn "quit", proc (L: Interp, a: seq[Value]): seq[Value] =
    if L.hosted: L.closeAllWindows() else: quitApplication()
  m.fn "windows", proc (L: Interp, a: seq[Value]): seq[Value] = @[intV(L.openWindows())]
  m.fn "trace", proc (L: Interp, a: seq[Value]): seq[Value] =
    L.uiState.trace = optBool(a, 1, true)
  m.fn "alert", proc (L: Interp, a: seq[Value]): seq[Value] =
    let msg = L.tostr(arg(a, 1))
    let icon = iconOf(L.optStr(a, 2, "alert", "information"))
    let title = L.optStr(a, 3, "alert", "")
    L.blocking:
      if title.len > 0: alert(icon, msg, title = title) else: alert(icon, msg)
  m.fn "confirm", proc (L: Interp, a: seq[Value]): seq[Value] =
    let msg = L.tostr(arg(a, 1))
    let icon = iconOf(L.optStr(a, 2, "confirm", "question"))
    var ok = false
    L.blocking: ok = confirm(icon, msg) == drOk
    @[boolV(ok)]
  m.fn "prompt", proc (L: Interp, a: seq[Value]): seq[Value] =
    let msg = L.tostr(arg(a, 1))
    let def = L.optStr(a, 2, "prompt", "")
    var r = ""
    L.blocking: r = prompt(iconQuestion, msg, def)
    @[strV(r)]
  m.fn "openfile", proc (L: Interp, a: seq[Value]): seq[Value] =
    let o = if arg(a, 1).kind == vkTable: a[0].t else: nil
    var p = ""
    L.blocking:
      p = openFileDialog(title = optField(o, "title", "Ouvrir"), folder = optField(o, "folder", ""),
                         filter = optField(o, "filter", "Tous les fichiers|*"))
    @[(if p.len > 0: strV(p) else: nilV)]
  m.fn "savefile", proc (L: Interp, a: seq[Value]): seq[Value] =
    let o = if arg(a, 1).kind == vkTable: a[0].t else: nil
    var p = ""
    L.blocking:
      p = saveFileDialog(defaultName = optField(o, "name", ""),
                         filter = optField(o, "filter", "Tous les fichiers|*"))
    @[(if p.len > 0: strV(p) else: nilV)]
  m.fn "color", proc (L: Interp, a: seq[Value]): seq[Value] =
    var c = hex(L.optStr(a, 1, "color", "#005FB8"))
    var ok = false
    L.blocking: ok = colorDialog(c) == drOk
    @[(if ok: strV(hexOf(c)) else: nilV)]
  m.fn "font", proc (L: Interp, a: seq[Value]): seq[Value] =
    var f = FontChoice(family: L.optStr(a, 1, "font", "DejaVuSans"))
    setNum(f.size, L.optNum(a, 2, "font", 14))
    var ok = false
    L.blocking: ok = fontDialog(f) == drOk
    if not ok: return @[nilV]
    let t = newLTable()
    t.set "family", strV(f.family)
    t.set "size", numV(float(f.size))
    when compiles(f.bold): t.set "bold", boolV(f.bold)
    when compiles(f.italic): t.set "italic", boolV(f.italic)
    when compiles(f.path): t.set "path", strV(f.path)
    @[tableV(t)]
  tableV(m)

const uiDocs = [
  "ui.window{title=, width=, height=, layout=, theme=, dark=}", "Crée une fenêtre. layout : vertical, horizontal, grid, flow, border, stack, absolute ; theme : windows, macos, linux, native.",
  "ui.run()", "Attend la fermeture des fenêtres (IDE) ou lance la boucle de wdgui (runtime).",
  "ui.quit()", "Ferme toutes les fenêtres du programme.",
  "ui.windows()", "Nombre de fenêtres ouvertes.",
  "ui.trace([on])", "Affiche dans la console chaque événement reçu (diagnostic).",
  "ui.label(text, [align])", "Libellé (align : left, center, right).",
  "ui.button(caption, [{default=, cancel=}])", "Bouton.",
  "ui.edit(text | {text=, placeholder=, multiline=})", "Champ de saisie.",
  "ui.checkbox(option, ...)", "Cases à cocher ; value = masque de bits.",
  "ui.radio(option, ...)", "Boutons radio ; value = index choisi.",
  "ui.list([multi])", "Liste.", "ui.combo(item, ...)", "Combo.",
  "ui.table()", "Table simple.", "ui.tree()", "Arbre.",
  "ui.grid{multi=, fill=\"programmed|manual|automatic\"}", "Grille de saisie (étape 11 du tutoriel wdgui).",
  "ui.progress()", "Jauge.", "ui.slider()", "Potentiomètre.", "ui.rangeslider()", "Potentiomètre de plage.",
  "ui.scrollbar()", "Ascenseur.", "ui.spin()", "Spin.", "ui.rating()", "Notation.",
  "ui.image(path)", "Image.", "ui.barcode(text)", "Code-barres.",
  "ui.chart([kind], [title])", "Graphe : column, line, area, pie.",
  "ui.calendar([\"YYYYMMDD\"])", "Calendrier.", "ui.kanban()", "Kanban.", "ui.treemap()", "TreeMap.", "ui.gantt()", "Gantt.",
  "ui.menubar()", "Barre de menus.", "ui.tab()", "Onglets.",
  "ui.splitter{vertical=, position=}", "Séparateur (deux enfants).",
  "ui.container([layout], [columns])", "Conteneur.", "ui.vbox()", "Conteneur vertical.", "ui.hbox()", "Conteneur horizontal.",
  "ui.supercontrol([layout])", "Conteneur sans marge.", "ui.cell(title, [layout])", "Cadre de groupe.",
  "ui.panel{layout=, scrollbars=, columns=}", "Conteneur défilant.",
  "ui.pdf()", "Visionneuse PDF (PDFium).",
  "ui.alert(message, [icon], [title])", "Message (icon : information, question, exclamation, stop, none).",
  "ui.confirm(message, [icon])", "OK / Annuler ; renvoie un booléen.",
  "ui.prompt(message, [default])", "Saisie d'un texte.",
  "ui.openfile{title=, filter=, folder=}", "Choix d'un fichier à ouvrir ; nil si annulé.",
  "ui.savefile{name=, filter=}", "Choix d'un fichier à enregistrer ; nil si annulé.",
  "ui.color([\"#RRGGBB\"])", "Sélecteur de couleur.",
  "ui.font([family], [size])", "Sélecteur de police.",
  "ui.SEP", "Séparateur des chemins d'arbre et de menu.",
  "ctl:add(child, ...)", "Ajoute des contrôles à un conteneur ou une fenêtre ; renvoie le premier.",
  "ctl:focus()", "Donne le focus.", "ctl:contextmenu(item, ...)", "Menu contextuel ; le choix arrive dans onselection.",
  "win:close()", "Ferme la fenêtre.", "win:settheme(name, [dark])", "Change le thème.",
  "tab:addpage(title, [layout])", "Ajoute une page ; renvoie son conteneur.",
  "list:add(item, ...)", "Ajoute (listes et combos).", "list:insert(i, item)", "Insère.", "list:delete(i)", "Supprime.",
  "list:clear()", "Vide.", "list:select(i)", "Sélectionne.", "list:selected()", "Index sélectionné.",
  "list:count()", "Nombre d'éléments.", "list:item(i)", "Texte d'un élément.", "list:modify(i, text)", "Modifie.",
  "list:seek(text)", "Recherche.",
  "table:addcolumn(title, [width], [align])", "Ajoute une colonne.", "table:addline(cell, ...)", "Ajoute une ligne.",
  "table:cell(row, col)", "Texte d'une cellule.", "table:setcell(row, col, text)", "Modifie une cellule.",
  "table:selected()", "Ligne sélectionnée.", "table:sort(col, [ascending])", "Trie.",
  "tree:add(path...)", "Ajoute un nœud (\"A\", \"B\" ou \"A/B\").", "tree:expand(path...)", "Déplie.",
  "tree:collapse(path...)", "Replie.", "tree:delete(path...)", "Supprime.", "tree:clear()", "Vide.",
  "menubar:add(path...)", "Ajoute un élément de menu (\"Fichier\", \"Ouvrir\") ; le choix arrive dans onselection (ev.path).",
  "check:checked([i])", "État d'une case.", "check:setchecked(i, [b])", "Coche une case.",
  "chart:adddata(series, category, value)", "Ajoute une donnée.", "chart:categorylabel(i, text)", "Libellé de catégorie.",
  "chart:serieslabel(i, text)", "Libellé de série.", "chart:settype(kind)", "Type de graphe.",
  "grid:addcolumn{name=, title=, kind=, width=, choices=, decimals=}", "Ajoute une colonne (kind : text, number, date, image, button, combo, check) ; renvoie la colonne.",
  "grid:addline(cell, ...)", "Ajoute une ligne.", "grid:cell(row, col)", "Valeur d'une cellule (col = nom ou index).",
  "grid:setcell(row, col, value)", "Modifie une cellule.", "grid:count()", "Nombre de lignes.",
  "grid:sort(col, [ascending])", "Trie.", "grid:seek(col, value, [exact], [start])", "Cherche une ligne.",
  "grid:setfooter(col, kind)", "Pied de colonne : sum, average, min, max, count.",
  "grid:addformat(col, op, value, {background=, text=, wholerow=})", "Mise en forme conditionnelle.",
  "grid:seteditable([b])", "Mode saisie.", "grid:tocsv([sep])", "Export CSV.", "grid:loadcsv(path, [sep])", "Import CSV.",
  "grid:tojson()", "Export JSON.", "grid:loadjson(path)", "Import JSON.",
  "panel:scrollto(x, y)", "Fait défiler.", "pdf:open(path)", "Ouvre un PDF.", "pdf:save([path])", "Enregistre."]

registerPackage PackageDef(name: "ui", open: openUi,
  description: "Interface graphique wdgui", docs: docs("ui", uiDocs))
