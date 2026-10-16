# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
#   wdlua - IDE Lua construit sur wdgui
#   compat : couche d'adaptation
#
# Le TUTORIAL de wdgui documente l'API publique (contrôles, ids, événements,
# méthodes à surcharger) mais pas le détail de toutes les signatures internes
# (primitives de dessin, champs des événements clavier/souris, presse-papiers).
# Toutes ces hypothèses sont regroupées ici et protégées par `when compiles`
# pour qu'une différence de signature se corrige à un seul endroit.

import std/[locks, times]
import wdgui
import sdl3

# Clavier (valeurs SDL3)

const
  ModShift* = 0x0003   # SDL_KMOD_LSHIFT | SDL_KMOD_RSHIFT.
  ModCtrl*  = 0x00C0   # SDL_KMOD_LCTRL | SDL_KMOD_RCTRL.
  ModAlt*   = 0x0300   # SDL_KMOD_LALT | SDL_KMOD_RALT.
  ModGui*   = 0x0C00   # SDL_KMOD_LGUI | SDL_KMOD_RGUI (Cmd sur macOS).

  KReturn*    = 0x0000000D
  KEscape*    = 0x0000001B
  KBackspace* = 0x00000008
  KTab*       = 0x00000009
  KSpace*     = 0x00000020
  KDelete*    = 0x0000007F
  KF2*        = 0x4000003B
  KF3*        = 0x4000003C
  KF5*        = 0x4000003E
  KF9*        = 0x40000042
  KF10*       = 0x40000043
  KF11*       = 0x40000044
  KF12*       = 0x40000045
  KHome*      = 0x4000004A
  KPageUp*    = 0x4000004B
  KEnd*       = 0x4000004D
  KPageDown*  = 0x4000004E
  KRight*     = 0x4000004F
  KLeft*      = 0x40000050
  KDown*      = 0x40000051
  KUp*        = 0x40000052
  KKpEnter*   = 0x40000058

proc currentMods*(): int =
  when compiles(SDL_GetModState()):
    result = int(SDL_GetModState())
  else:
    result = 0

proc keyCode*[E](e: E): int =
  when compiles(e.key): result = int(e.key)
  elif compiles(e.keycode): result = int(e.keycode)
  else: result = 0

proc keyMods*[E](e: E): int =
  when compiles(e.modifiers): result = int(e.modifiers)
  elif compiles(e.mods): result = int(e.mods)
  else: result = currentMods()

proc mouseMods*[E](e: E): int =
  when compiles(e.modifiers): result = int(e.modifiers)
  else: result = currentMods()

proc mouseX*[E](e: E): float = float(e.x)
proc mouseY*[E](e: E): float = float(e.y)

proc isCtrl*(m: int): bool {.inline.} = (m and (ModCtrl or ModGui)) != 0
proc isShift*(m: int): bool {.inline.} = (m and ModShift) != 0
proc isAlt*(m: int): bool {.inline.} = (m and ModAlt) != 0

proc nowSeconds*(): float =
  when compiles(SDL_GetTicks()):
    result = float(SDL_GetTicks()) / 1000.0
  else:
    result = epochTime()

# Dessin

proc fillBox*(d: Drawing, x, y, w, h: float, col: Color) =
  if w <= 0 or h <= 0: return
  when compiles(d.fillRect(rect(x, y, w, h), col)):
    d.fillRect(rect(x, y, w, h), col)
  else:
    d.fillRect(x, y, w, h, col)

proc frameBox*(d: Drawing, x, y, w, h: float, col: Color) =
  d.fillBox(x, y, w, 1, col)
  d.fillBox(x, y + h - 1, w, 1, col)
  d.fillBox(x, y, 1, h, col)
  d.fillBox(x + w - 1, y, 1, h, col)

proc measure*(d: Drawing, s: string): float =
  if s.len == 0: 0.0 else: float(d.textWidth(s))

proc lineHeightOf*(d: Drawing): float =
  # Hauteur d'une ligne de texte (la signature de textHeight n'est pas documentée).
  when compiles(d.textHeight()):
    result = float(d.textHeight())
  elif compiles(d.textHeight):
    result = float(d.textHeight)
  elif compiles(d.lineHeight()):
    result = float(d.lineHeight())
  elif compiles(d.fontSize):
    result = float(d.fontSize) * 1.25
  else:
    result = 18.0

proc drawText*(d: Drawing, x, y, h: float, s: string, col: Color) =
  # Texte aligné à gauche, centré verticalement dans la hauteur h.
  # Le rectangle a exactement la largeur du texte : le rendu est identique
  # que `textIn` aligne à gauche ou centre.
  if s.len == 0: return
  let w = d.measure(s) + 2
  d.textIn(rect(x, y, w, h), s, col)

proc dot*(d: Drawing, cx, cy, r: float, col: Color) =
  d.fillCircle(cx, cy, r, col)

proc clipPush*(d: Drawing, x, y, w, h: float) =
  when compiles(d.pushClip(rect(x, y, w, h))):
    d.pushClip(rect(x, y, w, h))
  else:
    d.pushClip(x, y, w, h)

proc clipPop*(d: Drawing) = d.popClip()

# Contrôle

proc makeFocusable*(c: Control) =
  when compiles(c.focusable = true): c.focusable = true
  elif compiles(c.canFocus = true): c.canFocus = true
  elif compiles(c.tabStop = true): c.tabStop = true
  else: discard

proc requestRedraw*(id: ControlId) =
  # Depuis un gestionnaire (autre thread) : demande un nouveau rendu.
  when compiles(invalidate(id)): invalidate(id)
  elif compiles(refresh(id)): refresh(id)
  else: id.visible = true   # setter documenté : marque le contrôle à redessiner

# Presse-papiers (à n'appeler que depuis le thread UI)

var clipLock: Lock
var internalClip: string
initLock(clipLock)

proc clipboardSet*(s: string) =
  when compiles(SDL_SetClipboardText(s.cstring)):
    when typeof(SDL_SetClipboardText(s.cstring)) is void:
      SDL_SetClipboardText(s.cstring)
    else:
      discard SDL_SetClipboardText(s.cstring)
  else:
    {.cast(gcsafe).}:
      withLock clipLock: internalClip = s

proc clipboardGet*(): string =
  when compiles(SDL_GetClipboardText()):
    let p = SDL_GetClipboardText()
    if p != nil:
      result = $p
      when compiles(SDL_free(cast[pointer](p))): SDL_free(cast[pointer](p))
  else:
    {.cast(gcsafe).}:
      withLock clipLock: result = internalClip

# Recherche

proc replacementOf*(r: FindRequest): string =
  when compiles(r.replaceText): result = r.replaceText
  elif compiles(r.replaceWith): result = r.replaceWith
  elif compiles(r.replacement): result = r.replacement
  else: result = ""

proc isBackwards*(r: FindRequest): bool =
  when compiles(r.backwards): result = r.backwards
  elif compiles(r.searchBackwards): result = r.searchBackwards
  else: result = false

proc forwardCopy*(r: FindRequest): FindRequest =
  result = r
  when compiles(result.backwards = false): result.backwards = false
  elif compiles(result.searchBackwards = false): result.searchBackwards = false

# Construction de contrôles

proc newMultilineEdit*(text = ""): Control =
  # Edit multiligne (le tutoriel cite l'option sans en donner le nom).
  when compiles(newEdit(text, multiline = true)):
    result = newEdit(text, multiline = true)
  elif compiles(newEdit(multiline = true)):
    result = newEdit(multiline = true)
    result.caption = text
  else:
    result = newEdit(text)

proc themeFor*(dark: bool): Theme =
  # Thème de la plateforme (wdgui fournit themeMacOS, themeLinux et themeNative).
  # when defined(macosx): result = themeMacOS(dark = dark)
  # elif defined(linux): result = themeLinux(dark = dark)
  # else: result = themeNative(dark = dark)
  result = themeMacOS(dark = dark)

# Constructeurs dont le tutoriel ne donne que le nom (aide-mémoire WD)

proc unavailable(kind: string) {.noreturn.} =
  raise newException(ValueError, "contrôle « " & kind & " » indisponible dans cette version de wdgui")

proc newRadioButtonCompat*(options: seq[string]): Control =
  when compiles(newRadioButton(options)):
    result = newRadioButton(options)
  elif compiles(newRadioButton()):
    result = newRadioButton()
    when compiles(radioAdd(result.id, "")):
      for o in options:
        when typeof(radioAdd(result.id, o)) is void: radioAdd(result.id, o)
        else: discard radioAdd(result.id, o)
  else:
    unavailable("radio")

proc newControlCompat*(kind: string): Control =
  case kind
  of "slider":
    when compiles(newSlider()): result = newSlider()
  of "rangeslider":
    when compiles(newRangeSlider()): result = newRangeSlider()
  of "scrollbar":
    when compiles(newScrollbar()): result = newScrollbar()
  of "spin":
    when compiles(newSpin()): result = newSpin()
  of "rating":
    when compiles(newRating()): result = newRating()
  of "kanban":
    when compiles(newKanban()): result = newKanban()
  of "treemap":
    when compiles(newTreeMap()): result = newTreeMap()
  of "gantt":
    when compiles(newGantt()): result = newGantt()
  else: discard
  if result.isNil: unavailable(kind)

proc newImageCompat*(path: string): Control =
  when compiles(newImage(path)): result = newImage(path)
  elif compiles(newImage()):
    result = newImage()
    if path.len > 0: result.id.value = path
  else: unavailable("image")

proc newBarCodeCompat*(text: string): Control =
  when compiles(newBarCode(text)): result = newBarCode(text)
  elif compiles(newBarCode()):
    result = newBarCode()
    result.id.value = text
  else: unavailable("barcode")
