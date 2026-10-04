# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
#   _._
# o|- -|o  wdnotes - wdgui adaptation layer
#  ( l )
#    =
#
# The tutorial documents the event API, the id API and the custom-control
# methods precisely, but only names most drawing primitives. Every call
# whose exact signature is not documented goes through this module, with
# `when compiles(...)` alternatives. If a primitive is renamed in a future
# wdgui version, this is the only file to touch.

import std/[times, math, strutils, browsers]
import std/unicode except strip, split, splitWhitespace, align, alignLeft, cmpIgnoreCase, reversed
export math
import ../../src/wdgui
export wdgui

# Type used by `method onKey`. Change here if wdgui names it differently.
type WdKeyEvent* = KeyEvent

# true -> `newSplitter(vertical = true)` puts the two panes side by side.
const SplitSideBySide* = true

# colors (or *colours* for our English friends) 👋).

proc col*(s: string): Color =
  ## "#rrggbb" or "#rrggbbaa" at run time
  when compiles(hex(s)): hex(s)
  elif compiles(parseColor(s)): parseColor(s)
  else: {.error: "wdcompat: no runtime hex -> Color conversion".}

proc colA*(s: string, alpha: int): Color =
  ## colour with alpha (0..255)
  const digits = "0123456789abcdef"
  let a = clamp(alpha, 0, 255)
  col(s & digits[a shr 4] & digits[a and 15])

# shapes

proc gfxFill*(d: Drawing, x, y, w, h: float, c: Color) =
  if w <= 0 or h <= 0: return
  when compiles(d.fillRect(rect(x, y, w, h), c)): d.fillRect(rect(x, y, w, h), c)
  elif compiles(d.fillRect(x, y, w, h, c)): d.fillRect(x, y, w, h, c)
  else: {.error: "wdcompat: adapt gfxFill".}

proc gfxRound*(d: Drawing, x, y, w, h, r: float, c: Color) =
  if w <= 0 or h <= 0: return
  when compiles(d.fillRoundRect(rect(x, y, w, h), r, c)): d.fillRoundRect(rect(x, y, w, h), r, c)
  elif compiles(d.fillRoundRect(x, y, w, h, r, c)): d.fillRoundRect(x, y, w, h, r, c)
  else: d.gfxFill(x, y, w, h, c)

proc gfxStroke*(d: Drawing, x, y, w, h: float, c: Color) =
  when compiles(d.strokeRect(rect(x, y, w, h), c)): d.strokeRect(rect(x, y, w, h), c)
  elif compiles(d.strokeRect(x, y, w, h, c)): d.strokeRect(x, y, w, h, c)
  else:
    d.gfxFill(x, y, w, 1, c); d.gfxFill(x, y + h - 1, w, 1, c)
    d.gfxFill(x, y, 1, h, c); d.gfxFill(x + w - 1, y, 1, h, c)

proc gfxStrokeRound*(d: Drawing, x, y, w, h, r: float, c: Color) =
  when compiles(d.strokeRoundRect(rect(x, y, w, h), r, c)): d.strokeRoundRect(rect(x, y, w, h), r, c)
  elif compiles(d.strokeRoundRect(x, y, w, h, r, c)): d.strokeRoundRect(x, y, w, h, r, c)
  else: d.gfxStroke(x, y, w, h, c)

proc gfxLine*(d: Drawing, x1, y1, x2, y2: float, c: Color) =
  when compiles(d.line(x1, y1, x2, y2, c)): d.line(x1, y1, x2, y2, c)
  elif compiles(d.drawLine(x1, y1, x2, y2, c)): d.drawLine(x1, y1, x2, y2, c)
  else:
    # fallback: dotted with small squares,
    let n = max(1, int(max(abs(x2 - x1), abs(y2 - y1))))
    for i in 0 .. n:
      let t = float(i) / float(n)
      d.gfxFill(x1 + (x2 - x1) * t, y1 + (y2 - y1) * t, 1, 1, c)

proc gfxDashed*(d: Drawing, x1, y1, x2, y2: float, c: Color, dash = 5.0) =
  let len = sqrt((x2 - x1) * (x2 - x1) + (y2 - y1) * (y2 - y1))
  if len < 1: return
  var t = 0.0
  while t < len:
    let a = t / len
    let b = min(t + dash, len) / len
    d.gfxLine(x1 + (x2 - x1) * a, y1 + (y2 - y1) * a, x1 + (x2 - x1) * b, y1 + (y2 - y1) * b, c)
    t += dash * 2

proc gfxCircle*(d: Drawing, x, y, r: float, c: Color) =
  d.fillCircle(x, y, r, c)

proc gfxRing*(d: Drawing, x, y, r: float, c: Color) =
  when compiles(d.strokeCircle(x, y, r, c)): d.strokeCircle(x, y, r, c)
  else:
    d.fillCircle(x, y, r, c)

proc gfxShadow*(d: Drawing, x, y, w, h, r: float) =
  when compiles(d.shadow(rect(x, y, w, h), r)): d.shadow(rect(x, y, w, h), r)
  else:
    for i in 1 .. 4:
      d.gfxRound(x - float(i) + 1, y - float(i) + 3, w + float(i * 2) - 2, h + float(i * 2) - 2,
                 r + float(i), colA("#000000", 10))

proc gfxClip*(d: Drawing, x, y, w, h: float) =
  when compiles(d.pushClip(rect(x, y, w, h))): d.pushClip(rect(x, y, w, h))
  elif compiles(d.pushClip(x, y, w, h)): d.pushClip(x, y, w, h)
  else: discard

proc gfxUnclip*(d: Drawing) =
  when compiles(d.popClip()): d.popClip()
  else: discard

# text

const FontControl* = compiles((var d: Drawing; d.setFont("Serif", 12.0, true, false))) or
                     compiles((var d: Drawing; d.setFontSize(12.0))) or
                     compiles((var d: Drawing; d.fontSize = 12.0))
  # false: wdgui draws every text with the theme font; sizes are then emulated (bold is simulated, headings are colored).

var fakeBold {.threadvar.}: bool

proc gfxFont*(d: Drawing, family: string, size: float, bold, italic: bool) =
  fakeBold = bold
  when compiles(d.setFont(family, size, bold, italic)):
    d.setFont(family, size, bold, italic); fakeBold = false
  elif compiles(d.setFontSize(size)):
    d.setFontSize(size)
  elif compiles(d.fontSize = size):
    d.fontSize = size
  else: discard

proc gfxFontReset*(d: Drawing, t: Theme) =
  fakeBold = false
  when compiles(d.resetFont()): d.resetFont()
  elif compiles(d.setFontSize(t.fontSize)): d.setFontSize(t.fontSize)
  elif compiles(d.fontSize = t.fontSize): d.fontSize = t.fontSize
  else: discard

proc gfxTextW*(d: Drawing, s: string): float =
  if s.len == 0: return 0
  float(d.textWidth(s))

proc gfxTextH*(d: Drawing, t: Theme): float =
  when compiles(d.textHeight()): float(d.textHeight())
  else: float(t.fontSize) * 1.25

proc gfxText*(d: Drawing, x, y, h: float, s: string, c: Color) =
  # draws `s` with its left edge at x, vertically centred in [y, y+h].
  if s.len == 0: return
  let w = d.gfxTextW(s) + 6
  d.textIn(rect(x, y, w, h), s, c)  # documented
  if fakeBold: d.textIn(rect(x + 0.6, y, w, h), s, c)

proc truncate*(d: Drawing, s: string, maxW: float): string =
  if d.gfxTextW(s) <= maxW: return s
  var rs = s.toRunes
  while rs.len > 1 and d.gfxTextW($rs & "…") > maxW: rs.setLen(rs.len - 1)
  $rs & "…"

# events

template mouseX*(e: untyped): float = float(e.x)
template mouseY*(e: untyped): float = float(e.y)

template keyCode*(e: untyped): int64 =
  when compiles(int64(e.key)): int64(e.key)
  elif compiles(int64(ord(e.key))): int64(ord(e.key))
  elif compiles(int64(e.keycode)): int64(e.keycode)
  elif compiles(int64(e.sym)): int64(e.sym)
  else: 0'i64

template keyMods*(e: untyped): int =
  when compiles(int(e.modifiers)): int(e.modifiers)
  elif compiles(int(ord(e.modifiers))): int(ord(e.modifiers))
  elif compiles(int(e.mods)): int(e.mods)
  elif compiles(int(e.keymod)): int(e.keymod)
  else: 0

const
  KReturn* = 0x0D'i64
  KEscape* = 0x1B'i64
  KBackspace* = 0x08'i64
  KTab* = 0x09'i64
  KDelete* = 0x7F'i64
  KRight* = 0x4000004F'i64
  KLeft* = 0x40000050'i64
  KDown* = 0x40000051'i64
  KUp* = 0x40000052'i64
  KHome* = 0x4000004A'i64
  KPageUp* = 0x4000004B'i64
  KEnd* = 0x4000004D'i64
  KPageDown* = 0x4000004E'i64
  KKpEnter* = 0x40000058'i64
  ModShift* = 0x0003
  ModCtrl* = 0x00C0
  ModAlt* = 0x0300
  ModGui* = 0x0C00

proc currentMods*(): int =
  # keyboard modifiers at this instant (for shift-click).
  when compiles(SDL_GetModState()): int(SDL_GetModState())
  else: 0

proc nowSec*(): float = epochTime()

# clipboard

var localClipboard {.threadvar.}: string

proc clipboardSet*(s: string) =
  localClipboard = s
  when compiles(SDL_SetClipboardText(cstring(s))): discard SDL_SetClipboardText(cstring(s))

proc clipboardGet*(): string =
  when compiles(SDL_GetClipboardText()):
    let p = SDL_GetClipboardText()
    if p != nil:
      result = $p
      when compiles(SDL_free(p)): SDL_free(p)
      return
  localClipboard

# controls

proc newFlatButton*(caption: string, tip = ""): Control =
  when compiles(newButton(caption, isFlat = true)): result = newButton(caption, isFlat = true)
  elif compiles(newButton(caption, flat = true)): result = newButton(caption, flat = true)
  else: result = newButton(caption)
  result.stretch = false
  if tip.len > 0:
    when compiles(result.tooltip = tip): result.tooltip = tip

proc makeFocusable*(c: Control) =
  when compiles(c.focusable = true): c.focusable = true
  elif compiles(c.canFocus = true): c.canFocus = true
  elif compiles(c.tabStop = true): c.tabStop = true
  else: discard

proc setTip*(id: ControlId, tip: string) =
  id.tooltip = tip

proc selectTab*(tab: ControlId, page: int) =
  ## 1-based page
  when compiles(tab.valueNum = float(page)): tab.valueNum = float(page)
  else: tab.value = $page

proc listSelectedIndex*(id: ControlId): int =
  try:
    result = parseInt(id.value.strip)
  except ValueError:
    result = -1

proc openUrl*(url: string) =
  when compiles(openDefaultBrowser(url)): openDefaultBrowser(url)
  else: discard

proc treeSelectPath*(tree: ControlId, path: string) =
  # selects a node by its TAB-separated path.
  when compiles(treeSelect(tree, path)): treeSelect(tree, path)
  else: tree.value = path

proc pageDialog*(paper: var string, landscape: var bool, mt, mb, ml, mr: var float): bool =
  # native "Page setup" dialog of wdgui, mapped to the format fields.
  when compiles(block: (var ps = defaultPageSettings(); discard pageSetupDialog(ps))):
    var ps = defaultPageSettings()
    when compiles(ps.marginTop = mt):
      ps.marginTop = mt; ps.marginBottom = mb; ps.marginLeft = ml; ps.marginRight = mr
    if pageSetupDialog(ps) == drOk:
      when compiles(float(ps.marginTop)):
        mt = float(ps.marginTop); mb = float(ps.marginBottom)
        ml = float(ps.marginLeft); mr = float(ps.marginRight)
      when compiles($ps.paper):
        let s = ($ps.paper).toLowerAscii
        for name in ["A3", "A4", "A5", "Letter", "Legal"]:
          if name.toLowerAscii in s: paper = name
      when compiles($ps.orientation):
        landscape = "land" in ($ps.orientation).toLowerAscii
      return true
  false
