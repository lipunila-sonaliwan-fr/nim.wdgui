# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
# Basic controls: Label, Button, Check Box, Radio Button, Edit, Spin, Progress Bar,
# Slider, Range Slider, Scrollbar, Rating, Shape, Image, Bar Code,
# and containers: Cell, Tab, Splitter, Toolbar.
import std/[math, strutils, unicode]
import ../sdl3, core

# shared drawing helpers

proc drawPanel*(d: Drawing, t: Theme, c: Control, r: Rect, accent = false) =
  # "Button" background according to the look & feel (reusable by custom controls).
  let rad = if t.buttonStyle == bsPill: r.h / 2 else: radiusOf(c, t)
  let enabled = c.isActive
  let acc = c.style.accent.get(t.accent)
  var background = if accent: acc else: t.surface
  if enabled:
    if c.pressed and c.hovered: background = if accent: mix(acc, Black, 0.15) else: t.surfacePressed
    elif c.hovered: background = if accent: t.accentHover else: t.surfaceHover
  else:
    background = mix(background, t.windowBg, 0.5)
  background = c.style.background.get(background)
  let borderCol = c.style.border.get(if accent: mix(acc, Black, 0.1) else: t.border)
  let ep = c.style.borderWidth.get(t.borderWidth)
  case t.buttonStyle
  of bsRaised:
    d.fillRoundRect(rect(r.x, r.y + 1, r.w, r.h), rad, t.shadow)
    d.fillRoundRect(r, rad, borderCol)
    d.fillRoundRect(r.shrink(ep), max(0.0, rad - ep), background)
  of bsPill:
    d.fillRoundRect(r, rad, borderCol)
    d.fillRoundRect(r.shrink(ep), max(0.0, rad - ep), background)
  of bsFlat:
    d.fillRoundRect(r, rad, background)

proc drawFieldFrame*(d: Drawing, t: Theme, c: Control, r: Rect) =
  # Frame of an edit / list control with the native focus indicator.
  let rad = c.style.radius.get(t.fieldRadius)
  let ep = c.style.borderWidth.get(t.borderWidth)
  var borderCol = c.style.border.get(t.border)
  if c.focus and t.focusStyle == fsRing: borderCol = t.accent
  d.fillRoundRect(r, rad, borderCol)
  d.fillRoundRect(r.shrink(ep), max(0.0, rad - ep),
                     c.style.background.get(if c.isGrayed: t.windowBg else: t.fieldBg))
  if c.focus:
    case t.focusStyle
    of fsUnderline: d.fillRect(rect(r.x + 1, r.y + r.h - 2, r.w - 2, 2), c.style.accent.get(t.accent))
    of fsHalo: d.drawFocus(t, r, rad)
    of fsRing: d.strokeRoundRect(r, rad, t.accent, 2)

proc drawThumb*(d: Drawing, t: Theme, cx, cy: float, hover: bool) =
  # Slider thumb according to the platform.
  case t.look
  of lfWindows:
    d.fillCircle(cx, cy, 10, t.border)
    d.fillCircle(cx, cy, 9, t.fieldBg)
    d.fillCircle(cx, cy, (if hover: 6.5 else: 5.0), t.accent)
  of lfMacOS:
    d.fillCircle(cx, cy + 1, 10, t.shadow)
    d.fillCircle(cx, cy, 10, t.border)
    d.fillCircle(cx, cy, 9, (if t.dark: hex"#CFCFCF" else: White))
  else:
    d.fillCircle(cx, cy, 10, t.border)
    d.fillCircle(cx, cy, 9, (if hover: mix(White, t.accent, 0.1) else: White))

# Label.
type
  Label* = ref object of Control
    alignment*: Alignment
    isLink*: bool          # "link" rendering (underlined, accent color, hand cursor).

proc newLabel*(text: string, alignment = alLeft, isLink = false): Label =
  result = Label(alignment: alignment, isLink: isLink)
  initControl(result, text)

method typeName*(c: Label): string = "Label"

method preferredSize*(c: Label, d: Drawing, t: Theme): tuple[w, h: float] =
  let rows = c.caption.split('\n')
  var w = 0.0
  for l in rows: w = max(w, d.textWidth(l))
  (w + 4, max(t.controlHeight, float(rows.len) * t.lineHeight))

method mouseCursor*(c: Label, x, y: float): int =
  if c.isLink: SDL_SYSTEM_CURSOR_POINTER else: SDL_SYSTEM_CURSOR_DEFAULT

method draw*(c: Label, d: Drawing, t: Theme) =
  if c.style.background.isSome: d.fillRoundRect(c.rect, radiusOf(c, t), c.style.background.get)
  let col = if c.isLink and not c.isGrayed:
              (if c.hovered: t.accentHover else: c.style.accent.get(t.accent))
            else: textColor(c, t)
  let rows = c.caption.split('\n')
  let lh = t.lineHeight
  var y = c.rect.y + (c.rect.h - float(rows.len) * lh) / 2
  for l in rows:
    let zr = rect(c.rect.x, y, c.rect.w, lh)
    d.textIn(zr, l, col, c.alignment, 2)
    if c.isLink:
      let w = min(d.textWidth(l), c.rect.w - 4)
      let x = case c.alignment
              of alLeft: zr.x + 2
              of alCenter: zr.x + (zr.w - w) / 2
              of alRight: zr.x + zr.w - w - 2
      d.fillRect(rect(x, y + (lh + d.textHeight) / 2 + 1, w, 1), col)
    y += lh

# Button

type
  Button* = ref object of Control
    isDefault*: bool    # default button (Enter) - accent-colored rendering.
    isCancel*: bool     # cancel button (Escape).
    flat*: bool         # flat rendering (toolbars).

proc newButton*(caption: string, isDefault = false, isCancel = false): Button =
  result = Button(isDefault: isDefault, isCancel: isCancel)
  initControl(result, caption)
  result.focusable = true
  result.stretch = false

method typeName*(c: Button): string = "Button"

method isDefaultButton*(c: Button): bool = c.isDefault

method isCancelButton*(c: Button): bool = c.isCancel

method preferredSize*(c: Button, d: Drawing, t: Theme): tuple[w, h: float] =
  let w = d.textWidth(c.caption) + 2 * t.margin + 8
  let lw = if c.flat: w else: max(w, 88.0)
  (lw, t.controlHeight)

method draw*(c: Button, d: Drawing, t: Theme) =
  let r = c.rect
  if not c.flat or c.hovered or c.pressed or c.focus:
    drawPanel(d, t, c, r, c.isDefault)
  let col = if c.isDefault and not c.isGrayed: c.style.text.get(t.textOnAccent) else: textColor(c, t)
  d.textIn(r, c.caption, col, alCenter, 6)
  if c.focus: d.drawFocus(t, r, radiusOf(c, t))

method onKey*(c: Button, e: KeyEvent): bool =
  if e.key == SDLK_SPACE or e.key == SDLK_RETURN or e.key == SDLK_KP_ENTER:
    emit(c, evClick, button = mbLeft)
    return true
  false

# Check Box

type
  CheckBox* = ref object of Control
    options*: seq[string]
    checked*: seq[bool]
    switchStyle*: bool     # "switch" rendering (toggle switch).
    currentOption*: int

proc newCheckBox*(caption: string, checked = false, switchStyle = false): CheckBox =
  result = CheckBox(options: @[caption], checked: @[checked], switchStyle: switchStyle)
  initControl(result, caption)
  result.focusable = true

proc newCheckBox*(options: openArray[string], switchStyle = false): CheckBox =
  # Check box with several options (value = bit mask).
  result = CheckBox(options: @options, switchStyle: switchStyle)
  result.checked.setLen(options.len)
  initControl(result, if options.len > 0: options[0] else: "")
  result.focusable = true

proc optionRowHeight(c: CheckBox, t: Theme): float =
  if c.options.len <= 1: c.rect.h else: t.lineHeight

proc optionRect(c: CheckBox, t: Theme, i: int): Rect =
  let hl = c.optionRowHeight(t)
  rect(c.rect.x, c.rect.y + float(i) * hl, c.rect.w, hl)

proc boxRect(c: CheckBox, t: Theme, i: int): Rect =
  let ro = c.optionRect(t, i)
  let s = t.checkSize
  let w = if c.switchStyle: s * 2 else: s
  rect(ro.x + 3, ro.y + (ro.h - s) / 2, w, s)

method typeName*(c: CheckBox): string = "Check Box"

method preferredSize*(c: CheckBox, d: Drawing, t: Theme): tuple[w, h: float] =
  var w = 0.0
  for o in c.options: w = max(w, d.textWidth(o))
  let bw = if c.switchStyle: t.checkSize * 2 else: t.checkSize
  let h = if c.options.len <= 1: t.controlHeight else: float(c.options.len) * t.lineHeight
  (w + bw + 16, h)

method draw*(c: CheckBox, d: Drawing, t: Theme) =
  let acc = c.style.accent.get(t.accent)
  let grayed = c.isGrayed
  for i, o in c.options:
    let b = c.boxRect(t, i)
    let on = i < c.checked.len and c.checked[i]
    if c.switchStyle:
      if on:
        d.fillRoundRect(b, b.h / 2, if grayed: t.textDisabled else: acc)
        d.fillCircle(b.x + b.w - b.h / 2, b.y + b.h / 2, b.h / 2 - 3, t.textOnAccent)
      else:
        d.fillRoundRect(b, b.h / 2, if grayed: t.textDisabled else: t.textSecondary)
        d.fillRoundRect(b.shrink(1), b.h / 2 - 1, t.fieldBg)
        d.fillCircle(b.x + b.h / 2, b.y + b.h / 2, b.h / 2 - 4,
                      if grayed: t.textDisabled else: t.textSecondary)
    else:
      if on:
        d.fillRoundRect(b, t.checkRadius, if grayed: t.textDisabled else: acc)
        d.drawCheckMark(b.shrink(b.w * 0.12), t.textOnAccent, 2)
      else:
        d.fillRoundRect(b, t.checkRadius,
                           if grayed: t.textDisabled elif t.look == lfWindows: t.textSecondary else: t.border)
        d.fillRoundRect(b.shrink(1), max(0.0, t.checkRadius - 1),
                           if c.hovered and not grayed: t.surfaceHover else: t.fieldBg)
    let ro = c.optionRect(t, i)
    d.textIn(rect(b.x + b.w + 8, ro.y, max(0.0, ro.x + ro.w - b.x - b.w - 8), ro.h), o, textColor(c, t))
    if c.focus and i == c.currentOption:
      d.drawFocus(t, b, if c.switchStyle: b.h / 2 else: t.checkRadius)

method onMouse*(c: CheckBox, e: MouseEvent) =
  if e.action != maRelease or e.button != mbLeft or not c.rect.containsPoint(e.x, e.y): return
  let t = c.win.theme
  let i = clamp(int((e.y - c.rect.y) / c.optionRowHeight(t)), 0, c.options.high)
  c.currentOption = i
  c.checked[i] = not c.checked[i]
  emit(c, evChange, index = i + 1, text = c.options[i])

method onKey*(c: CheckBox, e: KeyEvent): bool =
  case e.key
  of SDLK_SPACE:
    c.checked[c.currentOption] = not c.checked[c.currentOption]
    emit(c, evChange, index = c.currentOption + 1, text = c.options[c.currentOption])
  of SDLK_UP: c.currentOption = max(0, c.currentOption - 1)
  of SDLK_DOWN: c.currentOption = min(c.options.high, c.currentOption + 1)
  else: return false
  true

method valueText*(c: CheckBox): string =
  if c.options.len == 1: return (if c.checked[0]: "1" else: "0")
  var m = 0
  for i, b in c.checked:
    if b: m = m or (1 shl i)
  $m

method setValueText*(c: CheckBox, v: string) =
  var m = 0
  try: m = parseInt(v.strip)
  except ValueError: m = (if v.strip.toLowerAscii in ["on", "true", "yes"]: 1 else: 0)
  for i in 0 ..< c.checked.len: c.checked[i] = (m and (1 shl i)) != 0

# Radio Button

type
  RadioButton* = ref object of Control
    options*: seq[string]
    selection*: int    # 0-based, -1 = none.
    horizontal*: bool

proc newRadioButton*(options: openArray[string], selection = 0, horizontal = false): RadioButton =
  result = RadioButton(options: @options, selection: selection, horizontal: horizontal)
  initControl(result, if options.len > 0: options[0] else: "")
  result.focusable = true

proc radioRect(c: RadioButton, d: Drawing, t: Theme, i: int): Rect =
  if c.horizontal:
    var x = c.rect.x
    for j in 0 ..< i: x += d.textWidth(c.options[j]) + t.checkSize + 24
    rect(x, c.rect.y, d.textWidth(c.options[i]) + t.checkSize + 24, c.rect.h)
  else:
    let hl = if c.options.len <= 1: c.rect.h else: t.lineHeight
    rect(c.rect.x, c.rect.y + float(i) * hl, c.rect.w, hl)

method typeName*(c: RadioButton): string = "Radio Button"

method preferredSize*(c: RadioButton, d: Drawing, t: Theme): tuple[w, h: float] =
  if c.horizontal:
    var w = 0.0
    for o in c.options: w += d.textWidth(o) + t.checkSize + 24
    return (w, t.controlHeight)
  var w = 0.0
  for o in c.options: w = max(w, d.textWidth(o))
  (w + t.checkSize + 16, max(t.controlHeight, float(c.options.len) * t.lineHeight))

method draw*(c: RadioButton, d: Drawing, t: Theme) =
  let acc = c.style.accent.get(t.accent)
  let grayed = c.isGrayed
  let s = t.checkSize
  for i, o in c.options:
    let ro = c.radioRect(d, t, i)
    let cx = ro.x + 3 + s / 2
    let cy = ro.y + ro.h / 2
    if i == c.selection:
      d.fillCircle(cx, cy, s / 2, if grayed: t.textDisabled else: acc)
      d.fillCircle(cx, cy, s * 0.22, t.textOnAccent)
    else:
      d.fillCircle(cx, cy, s / 2, if t.look == lfWindows: t.textSecondary else: t.border)
      d.fillCircle(cx, cy, s / 2 - 1, t.fieldBg)
    d.textIn(rect(ro.x + s + 11, ro.y, max(0.0, ro.w - s - 11), ro.h), o, textColor(c, t))
    if c.focus and i == max(0, c.selection):
      d.drawFocus(t, rect(cx - s/2, cy - s/2, s, s), s / 2)

method onMouse*(c: RadioButton, e: MouseEvent) =
  if e.action != maRelease or e.button != mbLeft: return
  for i in 0 ..< c.options.len:
    if c.radioRect(c.win.drawing, c.win.theme, i).containsPoint(e.x, e.y):
      if i != c.selection:
        c.selection = i
        emit(c, evChange, index = i + 1, text = c.options[i])
      return

method onKey*(c: RadioButton, e: KeyEvent): bool =
  var n = c.selection
  case e.key
  of SDLK_UP, SDLK_LEFT: n = max(0, n - 1)
  of SDLK_DOWN, SDLK_RIGHT: n = min(c.options.high, n + 1)
  else: return false
  if n != c.selection:
    c.selection = n
    emit(c, evChange, index = n + 1, text = c.options[n])
  true

method valueText*(c: RadioButton): string = $(c.selection + 1)

method setValueText*(c: RadioButton, v: string) =
  try: c.selection = clamp(parseInt(v.strip) - 1, -1, c.options.high)
  except ValueError: discard

# Edit

type
  InputKind* = enum
    ikText = "Text", ikInteger = "Integer", ikReal = "Real", ikPassword = "Password"
  Edit* = ref object of Control
    text*: string
    inputKind*: InputKind
    multiline*: bool
    placeholder*: string    # placeholder text shown when the control is empty.
    maxLength*: int         # 0 = unlimited.
    cursor*, anchor*: int   # positions (UTF-8 bytes); selection lies between anchor and cursor.
    scrollX*, scrollY*: float
    rightMargin*: float
    followCursor: bool

proc newEdit*(text = "", inputKind = ikText, multiline = false, placeholder = ""): Edit =
  result = Edit(text: text, inputKind: inputKind, multiline: multiline, placeholder: placeholder)
  initControl(result)
  result.focusable = true
  result.cursor = text.len
  result.anchor = text.len

proc prevRune*(s: string, i: int): int =
  result = max(0, i - 1)
  while result > 0 and (uint8(s[result]) and 0xC0'u8) == 0x80'u8: dec result

proc nextRune*(s: string, i: int): int =
  result = min(s.len, i + 1)
  while result < s.len and (uint8(s[result]) and 0xC0'u8) == 0x80'u8: inc result

proc displayed(c: Edit, s: string): string =
  if c.inputKind == ikPassword: "*".repeat(s.runeLen) else: s

proc lineRanges(c: Edit): seq[tuple[a, b: int]] =
  var a = 0
  if c.multiline:
    for i in 0 ..< c.text.len:
      if c.text[i] == '\n':
        result.add((a, i))
        a = i + 1
  result.add((a, c.text.len))

proc lineOf(ls: seq[tuple[a, b: int]], pos: int): int =
  for i, l in ls:
    if pos >= l.a and pos <= l.b: return i
  ls.high

proc textArea(c: Edit): Rect =
  let r = c.rect
  if c.multiline: rect(r.x + 8, r.y + 5, max(0.0, r.w - 16 - c.rightMargin), max(0.0, r.h - 10))
  else: rect(r.x + 8, r.y + 2, max(0.0, r.w - 16 - c.rightMargin), max(0.0, r.h - 4))

proc lineY(c: Edit, t: Theme, z: Rect, i: int): float =
  if c.multiline: z.y + float(i) * t.lineHeight - c.scrollY
  else: z.y + (z.h - t.lineHeight) / 2

proc posFromXY(c: Edit, d: Drawing, t: Theme, x, y: float): int =
  let z = c.textArea
  let ls = c.lineRanges
  var li = 0
  if c.multiline: li = clamp(int(floor((y - z.y + c.scrollY) / t.lineHeight)), 0, ls.high)
  let (a, b) = ls[li]
  let rx = x - z.x + c.scrollX
  var i = a
  var wPrev = 0.0
  while i < b:
    let j = nextRune(c.text, i)
    let w = d.textWidth(c.displayed(c.text[a ..< j]))
    if rx < (wPrev + w) / 2: return i
    wPrev = w
    i = j
  b

proc hasSelection(c: Edit): bool = c.cursor != c.anchor

proc selectionBounds(c: Edit): (int, int) = (min(c.cursor, c.anchor), max(c.cursor, c.anchor))

proc deleteSelection(c: Edit) =
  let (a, b) = c.selectionBounds
  if b > a: c.text.delete(a .. b - 1)
  c.cursor = a
  c.anchor = a

proc filterInput(c: Edit, s: string): string =
  case c.inputKind
  of ikInteger:
    for ch in s:
      if ch in {'0' .. '9', '-'}: result.add ch
  of ikReal:
    for ch in s:
      if ch in {'0' .. '9', '-', '.'}: result.add ch
      elif ch == ',': result.add '.'
  else:
    result = s.replace("\r", "")
    if not c.multiline: result = result.replace("\n", " ")

proc insertText(c: Edit, s: string) =
  var s2 = c.filterInput(s)
  c.deleteSelection()
  if c.maxLength > 0:
    let available = c.maxLength - c.text.runeLen
    if available <= 0: return
    if s2.runeLen > available: s2 = s2.runeSubStr(0, available)
  c.text.insert(s2, c.cursor)
  c.cursor += s2.len
  c.anchor = c.cursor
  c.followCursor = true

method typeName*(c: Edit): string = "Input"

method acceptsText*(c: Edit): bool = c.state == csActive

method mouseCursor*(c: Edit, x, y: float): int = SDL_SYSTEM_CURSOR_TEXT

method valueText*(c: Edit): string = c.text

method setValueText*(c: Edit, v: string) =
  c.text = if c.multiline: v else: v.replace("\n", " ")
  c.cursor = c.text.len
  c.anchor = c.cursor
  c.followCursor = true

method preferredSize*(c: Edit, d: Drawing, t: Theme): tuple[w, h: float] =
  if c.multiline: (220.0, t.lineHeight * 4 + 10) else: (180.0, t.controlHeight)

method draw*(c: Edit, d: Drawing, t: Theme) =
  drawFieldFrame(d, t, c, c.rect)
  let z = c.textArea
  let lh = t.lineHeight
  let th = d.textHeight
  let ls = c.lineRanges
  let li = lineOf(ls, c.cursor)
  let cx = d.textWidth(c.displayed(c.text[ls[li].a ..< c.cursor]))
  if c.followCursor:
    if cx - c.scrollX > z.w - 2: c.scrollX = cx - z.w + 2
    if cx - c.scrollX < 0: c.scrollX = cx
    if c.multiline:
      let cy = float(li) * lh
      if cy + lh - c.scrollY > z.h: c.scrollY = cy + lh - z.h
      if cy < c.scrollY: c.scrollY = cy
    c.followCursor = false
  d.pushClip(z)
  let col = textColor(c, t)
  if c.text.len == 0 and c.placeholder.len > 0:
    d.text(z.x, c.lineY(t, z, 0) + (lh - th) / 2, c.placeholder, t.textSecondary)
  let (sa, sb) = c.selectionBounds
  for i, l in ls:
    let y = c.lineY(t, z, i)
    if y + lh < z.y or y > z.y + z.h: continue
    if sb > sa and sb >= l.a and sa <= l.b:
      let a = max(sa, l.a)
      let b = min(sb, l.b)
      let x1 = d.textWidth(c.displayed(c.text[l.a ..< a]))
      var x2 = d.textWidth(c.displayed(c.text[l.a ..< b]))
      if sb > l.b and c.multiline: x2 += 6
      d.fillRect(rect(z.x - c.scrollX + x1, y + 2, x2 - x1, lh - 4),
                  withAlpha(c.style.accent.get(t.accent), if c.focus: 90 else: 45))
    d.text(z.x - c.scrollX, y + (lh - th) / 2, c.displayed(c.text[l.a ..< l.b]), col)
  if c.focus and c.win != nil and c.win.caretVisible and c.state == csActive:
    let y = c.lineY(t, z, li)
    d.fillRect(rect(z.x - c.scrollX + cx, y + (lh - th) / 2 - 1, 1.5, th + 2), c.style.text.get(t.text))
  d.popClip()

method onText*(c: Edit, s: string) =
  if c.state != csActive: return
  let before = c.text
  c.insertText(s)
  if c.text != before: emit(c, evChange, text = c.text)

method onKey*(c: Edit, e: KeyEvent): bool =
  let shift = (e.mods and KMOD_SHIFT) != 0
  let cmd = (e.mods and KMOD_CMD) != 0
  let editable = c.state == csActive
  let before = c.text
  let ls = c.lineRanges
  let li = lineOf(ls, c.cursor)
  var isMove = true
  case e.key
  of SDLK_LEFT:
    if c.hasSelection and not shift: c.cursor = c.selectionBounds[0]
    elif cmd: c.cursor = ls[li].a
    else: c.cursor = prevRune(c.text, c.cursor)
  of SDLK_RIGHT:
    if c.hasSelection and not shift: c.cursor = c.selectionBounds[1]
    elif cmd: c.cursor = ls[li].b
    else: c.cursor = nextRune(c.text, c.cursor)
  of SDLK_HOME: c.cursor = (if cmd: 0 else: ls[li].a)
  of SDLK_END: c.cursor = (if cmd: c.text.len else: ls[li].b)
  of SDLK_UP, SDLK_DOWN:
    if not c.multiline: return false
    let d = c.win.drawing
    let t = c.win.theme
    let nl = if e.key == SDLK_UP: li - 1 else: li + 1
    if nl < 0: c.cursor = 0
    elif nl > ls.high: c.cursor = c.text.len
    else:
      let x = d.textWidth(c.displayed(c.text[ls[li].a ..< c.cursor]))
      let z = c.textArea
      c.cursor = c.posFromXY(d, t, z.x + x - c.scrollX, c.lineY(t, z, nl) + t.lineHeight / 2)
  of SDLK_BACKSPACE:
    isMove = false
    if editable:
      if c.hasSelection: c.deleteSelection()
      elif c.cursor > 0:
        let p = prevRune(c.text, c.cursor)
        c.text.delete(p .. c.cursor - 1)
        c.cursor = p
        c.anchor = p
  of SDLK_DELETE:
    isMove = false
    if editable:
      if c.hasSelection: c.deleteSelection()
      elif c.cursor < c.text.len:
        let p = nextRune(c.text, c.cursor)
        c.text.delete(c.cursor .. p - 1)
  of SDLK_RETURN, SDLK_KP_ENTER:
    if c.multiline and editable:
      c.insertText("\n")
      isMove = false
    else: return false
  of SDLK_A:
    if not cmd: return false
    c.anchor = 0
    c.cursor = c.text.len
    isMove = false
  of SDLK_C, SDLK_X:
    if not cmd: return false
    let (a, b) = c.selectionBounds
    if b > a and c.inputKind != ikPassword:
      discard SDL_SetClipboardText(c.text[a ..< b].cstring)
      if e.key == SDLK_X and editable: c.deleteSelection()
    isMove = false
  of SDLK_V:
    if not cmd: return false
    if editable:
      let p = SDL_GetClipboardText()
      if p != nil:
        c.insertText($p)
        SDL_free(cast[pointer](p))
    isMove = false
  else: return false
  if isMove and not shift: c.anchor = c.cursor
  c.followCursor = true
  if c.text != before: emit(c, evChange, text = c.text)
  true

method onMouse*(c: Edit, e: MouseEvent) =
  if c.win == nil or c.win.drawing == nil or e.button notin {mbLeft, mbNone}: return
  let t = c.win.theme
  case e.action
  of maPress:
    let p = c.posFromXY(c.win.drawing, t, e.x, e.y)
    if e.clicks >= 2:
      var a = p
      var b = p
      while a > 0 and c.text[a - 1] notin Whitespace: dec a
      while b < c.text.len and c.text[b] notin Whitespace: inc b
      c.anchor = a
      c.cursor = b
    else:
      c.cursor = p
      if (e.mods and KMOD_SHIFT) == 0: c.anchor = p
  of maMove:
    if c.pressed:
      c.cursor = c.posFromXY(c.win.drawing, t, e.x, e.y)
      c.followCursor = true
  of maRelease: discard

method onWheel*(c: Edit, dx, dy: float): bool =
  if not c.multiline: return false
  let t = c.win.theme
  let total = float(c.lineRanges.len) * t.lineHeight
  c.scrollY = clamp(c.scrollY - dy * t.lineHeight * 3, 0.0, max(0.0, total - c.textArea.h))
  true

# Spin

type
  Spin* = ref object of Edit
    minValue*, maxValue*, step*: float

proc newSpin*(value = 0.0, minValue = 0.0, maxValue = 100.0, step = 1.0): Spin =
  result = Spin(minValue: minValue, maxValue: maxValue, step: step, inputKind: ikReal, rightMargin: 22)
  initControl(result)
  result.focusable = true
  result.text = formatNumber(clamp(value, minValue, maxValue))
  result.cursor = result.text.len
  result.anchor = result.cursor

proc readValue(c: Spin): float =
  try: result = parseFloat(c.text.strip)
  except ValueError: result = c.minValue

proc increment(c: Spin, direction: float) =
  let s = formatNumber(clamp(c.readValue + direction * c.step, c.minValue, c.maxValue))
  if s != c.text:
    c.text = s
    c.cursor = s.len
    c.anchor = s.len
    emit(c, evChange, text = s)

proc arrowArea(c: Spin): Rect = rect(c.rect.x + c.rect.w - 23, c.rect.y + 2, 21, c.rect.h - 4)

method typeName*(c: Spin): string = "Spin"

method preferredSize*(c: Spin, d: Drawing, t: Theme): tuple[w, h: float] = (120.0, t.controlHeight)

method valueNum*(c: Spin): float = c.readValue

method setValueNum*(c: Spin, v: float) = c.setValueText(formatNumber(clamp(v, c.minValue, c.maxValue)))

method draw*(c: Spin, d: Drawing, t: Theme) =
  procCall draw(Edit(c), d, t)
  let z = c.arrowArea
  let col = if c.isGrayed: t.textDisabled else: t.textSecondary
  d.fillRect(rect(z.x, z.y + 2, 1, z.h - 4), t.border)
  d.triangle(z.x + z.w / 2 + 1, z.y + z.h * 0.28, 8, '^', col)
  d.triangle(z.x + z.w / 2 + 1, z.y + z.h * 0.72, 8, 'v', col)

method onMouse*(c: Spin, e: MouseEvent) =
  let z = c.arrowArea
  if e.action == maPress and z.containsPoint(e.x, e.y):
    c.increment(if e.y < z.y + z.h / 2: 1.0 else: -1.0)
  elif not z.containsPoint(e.x, e.y) or e.action == maMove:
    procCall onMouse(Edit(c), e)

method mouseCursor*(c: Spin, x, y: float): int =
  if c.arrowArea.containsPoint(x, y): SDL_SYSTEM_CURSOR_DEFAULT else: SDL_SYSTEM_CURSOR_TEXT

method onKey*(c: Spin, e: KeyEvent): bool =
  case e.key
  of SDLK_UP: c.increment(1)
  of SDLK_DOWN: c.increment(-1)
  of SDLK_PAGEUP: c.increment(10)
  of SDLK_PAGEDOWN: c.increment(-10)
  else: return procCall onKey(Edit(c), e)
  true

method onWheel*(c: Spin, dx, dy: float): bool =
  c.increment(if dy > 0: 1.0 else: -1.0)
  true

# Progress Bar

type
  ProgressBar* = ref object of Control
    minValue*, maxValue*, value*: float
    showText*: bool

proc newProgressBar*(value = 0.0, minValue = 0.0, maxValue = 100.0, showText = true): ProgressBar =
  result = ProgressBar(minValue: minValue, maxValue: maxValue, value: value, showText: showText)
  initControl(result)

proc fraction*(v, minValue, maxValue: float): float =
  if maxValue > minValue: clamp((v - minValue) / (maxValue - minValue), 0.0, 1.0) else: 0.0

method typeName*(c: ProgressBar): string = "Progress Bar"

method valueNum*(c: ProgressBar): float = c.value

method setValueNum*(c: ProgressBar, v: float) = c.value = clamp(v, c.minValue, c.maxValue)

method valueText*(c: ProgressBar): string = formatNumber(c.value)

method setValueText*(c: ProgressBar, v: string) =
  try: c.setValueNum(parseFloat(v.strip))
  except ValueError: discard

method preferredSize*(c: ProgressBar, d: Drawing, t: Theme): tuple[w, h: float] = (200.0, t.lineHeight)

method draw*(c: ProgressBar, d: Drawing, t: Theme) =
  let r = c.rect
  let wt = if c.showText: 56.0 else: 0.0
  let hp = if t.look == lfWindows: 4.0 else: 6.0
  let p = rect(r.x, r.y + (r.h - hp) / 2, max(0.0, r.w - wt), hp)
  d.fillRoundRect(p, hp / 2, c.style.background.get(mix(t.border, t.windowBg, 0.2)))
  let f = fraction(c.value, c.minValue, c.maxValue)
  let acc = if c.isGrayed: t.textDisabled else: c.style.accent.get(t.accent)
  if f > 0: d.fillRoundRect(rect(p.x, p.y, max(hp, p.w * f), p.h), hp / 2, acc)
  if c.showText:
    d.textIn(rect(r.x + r.w - wt, r.y, wt, r.h), $int(round(f * 100)) & " %", textColor(c, t), alRight)

# Slider

type
  Slider* = ref object of Control
    minValue*, maxValue*, value*, step*: float
    vertical*: bool

proc newSlider*(value = 0.0, minValue = 0.0, maxValue = 100.0, step = 1.0, vertical = false): Slider =
  result = Slider(minValue: minValue, maxValue: maxValue, value: value, step: step, vertical: vertical)
  initControl(result)
  result.focusable = true

proc trackOf*(r: Rect, vertical: bool): Rect =
  const m = 11.0
  if vertical: rect(r.x + r.w / 2 - 2, r.y + m, 4, max(0.0, r.h - 2*m))
  else: rect(r.x + m, r.y + r.h / 2 - 2, max(0.0, r.w - 2*m), 4)

proc pointFor*(p: Rect, vertical: bool, f: float): (float, float) =
  if vertical: (p.x + 2, p.y + p.h * (1 - f)) else: (p.x + p.w * f, p.y + 2)

proc valueFrom*(p: Rect, vertical: bool, minValue, maxValue, step, x, y: float): float =
  let f = if vertical: 1 - (y - p.y) / max(1.0, p.h) else: (x - p.x) / max(1.0, p.w)
  result = minValue + clamp(f, 0.0, 1.0) * (maxValue - minValue)
  if step > 0: result = minValue + round((result - minValue) / step) * step
  result = clamp(result, min(minValue, maxValue), max(minValue, maxValue))

proc applyValue(c: Slider, v: float) =
  let v2 = clamp(v, c.minValue, c.maxValue)
  if v2 != c.value:
    c.value = v2
    emit(c, evChange, text = formatNumber(v2))

method typeName*(c: Slider): string = "Slider"

method valueNum*(c: Slider): float = c.value

method setValueNum*(c: Slider, v: float) = c.value = clamp(v, c.minValue, c.maxValue)

method valueText*(c: Slider): string = formatNumber(c.value)

method setValueText*(c: Slider, v: string) =
  try: c.setValueNum(parseFloat(v.strip))
  except ValueError: discard

method preferredSize*(c: Slider, d: Drawing, t: Theme): tuple[w, h: float] =
  if c.vertical: (28.0, 160.0) else: (200.0, 28.0)

method draw*(c: Slider, d: Drawing, t: Theme) =
  let p = trackOf(c.rect, c.vertical)
  let acc = if c.isGrayed: t.textDisabled else: c.style.accent.get(t.accent)
  d.fillRoundRect(p, 2, c.style.background.get(mix(t.border, t.textSecondary, 0.35)))
  let (px, py) = pointFor(p, c.vertical, fraction(c.value, c.minValue, c.maxValue))
  if c.vertical: d.fillRoundRect(rect(p.x, py, p.w, p.y + p.h - py), 2, acc)
  else: d.fillRoundRect(rect(p.x, p.y, px - p.x, p.h), 2, acc)
  drawThumb(d, t, px, py, c.hovered or c.pressed)
  if c.focus: d.drawFocus(t, rect(px - 10, py - 10, 20, 20), 10)

method onMouse*(c: Slider, e: MouseEvent) =
  if e.action == maPress or (e.action == maMove and c.pressed):
    c.applyValue(valueFrom(trackOf(c.rect, c.vertical), c.vertical, c.minValue, c.maxValue, c.step, e.x, e.y))

method onKey*(c: Slider, e: KeyEvent): bool =
  let p = if c.step > 0: c.step else: (c.maxValue - c.minValue) / 100
  case e.key
  of SDLK_LEFT, SDLK_DOWN: c.applyValue(c.value - p)
  of SDLK_RIGHT, SDLK_UP: c.applyValue(c.value + p)
  of SDLK_PAGEDOWN: c.applyValue(c.value - p * 10)
  of SDLK_PAGEUP: c.applyValue(c.value + p * 10)
  of SDLK_HOME: c.applyValue(c.minValue)
  of SDLK_END: c.applyValue(c.maxValue)
  else: return false
  true

method onWheel*(c: Slider, dx, dy: float): bool =
  let p = if c.step > 0: c.step else: (c.maxValue - c.minValue) / 100
  c.applyValue(c.value + (if dy > 0: p else: -p))
  true

# Range Slider

type
  RangeSlider* = ref object of Control
    minValue*, maxValue*, step*: float
    lowValue*, highValue*: float
    activeThumb: int

proc newRangeSlider*(lower = 20.0, upper = 80.0, minValue = 0.0, maxValue = 100.0, step = 1.0): RangeSlider =
  result = RangeSlider(minValue: minValue, maxValue: maxValue, step: step, lowValue: lower, highValue: upper)
  initControl(result)
  result.focusable = true

method typeName*(c: RangeSlider): string = "Range Slider"

method valueText*(c: RangeSlider): string = formatNumber(c.lowValue) & ";" & formatNumber(c.highValue)

method setValueText*(c: RangeSlider, v: string) =
  let p = v.split(';')
  try:
    if p.len >= 2:
      c.lowValue = clamp(parseFloat(p[0].strip), c.minValue, c.maxValue)
      c.highValue = clamp(parseFloat(p[1].strip), c.lowValue, c.maxValue)
  except ValueError: discard

method preferredSize*(c: RangeSlider, d: Drawing, t: Theme): tuple[w, h: float] = (200.0, 28.0)

method draw*(c: RangeSlider, d: Drawing, t: Theme) =
  let p = trackOf(c.rect, false)
  let acc = if c.isGrayed: t.textDisabled else: c.style.accent.get(t.accent)
  d.fillRoundRect(p, 2, mix(t.border, t.textSecondary, 0.35))
  let (x1, y1) = pointFor(p, false, fraction(c.lowValue, c.minValue, c.maxValue))
  let (x2, _) = pointFor(p, false, fraction(c.highValue, c.minValue, c.maxValue))
  d.fillRect(rect(x1, p.y, x2 - x1, p.h), acc)
  drawThumb(d, t, x1, y1, c.pressed and c.activeThumb == 0)
  drawThumb(d, t, x2, y1, c.pressed and c.activeThumb == 1)
  if c.focus:
    let x = if c.activeThumb == 0: x1 else: x2
    d.drawFocus(t, rect(x - 10, y1 - 10, 20, 20), 10)

method onMouse*(c: RangeSlider, e: MouseEvent) =
  let p = trackOf(c.rect, false)
  let v = valueFrom(p, false, c.minValue, c.maxValue, c.step, e.x, e.y)
  if e.action == maPress:
    c.activeThumb = if abs(v - c.lowValue) <= abs(v - c.highValue) and v <= c.highValue: 0 else: 1
  if e.action == maPress or (e.action == maMove and c.pressed):
    let before = c.valueText
    if c.activeThumb == 0: c.lowValue = min(v, c.highValue) else: c.highValue = max(v, c.lowValue)
    if c.valueText != before: emit(c, evChange, index = c.activeThumb + 1, text = c.valueText)

method onKey*(c: RangeSlider, e: KeyEvent): bool =
  let p = if c.step > 0: c.step else: 1.0
  case e.key
  of SDLK_TAB: return false
  of SDLK_SPACE: c.activeThumb = 1 - c.activeThumb
  of SDLK_LEFT, SDLK_RIGHT:
    let s = if e.key == SDLK_LEFT: -p else: p
    if c.activeThumb == 0: c.lowValue = clamp(c.lowValue + s, c.minValue, c.highValue)
    else: c.highValue = clamp(c.highValue + s, c.lowValue, c.maxValue)
    emit(c, evChange, index = c.activeThumb + 1, text = c.valueText)
  else: return false
  true

# Scrollbar

type
  Scrollbar* = ref object of Control
    minValue*, maxValue*, value*, pageSize*: float
    vertical*: bool
    dragging: bool
    dragOffset: float

proc newScrollbar*(vertical = true, minValue = 0.0, maxValue = 100.0, pageSize = 10.0): Scrollbar =
  result = Scrollbar(vertical: vertical, minValue: minValue, maxValue: maxValue, pageSize: pageSize)
  initControl(result)
  result.stretch = false

proc geometry(c: Scrollbar): tuple[arrow1, arrow2, track, thumb: Rect] =
  let r = c.rect
  let e = if c.vertical: r.w else: r.h
  let extent = max(0.0, c.maxValue - c.minValue)
  if c.vertical:
    result.arrow1 = rect(r.x, r.y, r.w, e)
    result.arrow2 = rect(r.x, r.y + r.h - e, r.w, e)
    result.track = rect(r.x, r.y + e, r.w, max(0.0, r.h - 2*e))
    let lp = if extent <= 0: result.track.h else: max(20.0, result.track.h * c.pageSize / (extent + c.pageSize))
    let pos = if extent <= 0: 0.0 else: (c.value - c.minValue) / extent * (result.track.h - lp)
    result.thumb = rect(r.x + 3, result.track.y + pos, r.w - 6, lp)
  else:
    result.arrow1 = rect(r.x, r.y, e, r.h)
    result.arrow2 = rect(r.x + r.w - e, r.y, e, r.h)
    result.track = rect(r.x + e, r.y, max(0.0, r.w - 2*e), r.h)
    let lp = if extent <= 0: result.track.w else: max(20.0, result.track.w * c.pageSize / (extent + c.pageSize))
    let pos = if extent <= 0: 0.0 else: (c.value - c.minValue) / extent * (result.track.w - lp)
    result.thumb = rect(result.track.x + pos, r.y + 3, lp, r.h - 6)

proc applyValue(c: Scrollbar, v: float) =
  let v2 = clamp(v, c.minValue, c.maxValue)
  if v2 != c.value:
    c.value = v2
    emit(c, evChange, text = formatNumber(v2))

method typeName*(c: Scrollbar): string = "Scrollbar"

method valueNum*(c: Scrollbar): float = c.value

method setValueNum*(c: Scrollbar, v: float) = c.value = clamp(v, c.minValue, c.maxValue)

method valueText*(c: Scrollbar): string = formatNumber(c.value)

method setValueText*(c: Scrollbar, v: string) =
  try: c.setValueNum(parseFloat(v.strip))
  except ValueError: discard

method preferredSize*(c: Scrollbar, d: Drawing, t: Theme): tuple[w, h: float] =
  if c.vertical: (16.0, 160.0) else: (160.0, 16.0)

method draw*(c: Scrollbar, d: Drawing, t: Theme) =
  let g = c.geometry
  d.fillRoundRect(c.rect, 4, c.style.background.get(mix(t.windowBg, t.surfacePressed, 0.5)))
  let col = if c.isGrayed: t.textDisabled else: t.textSecondary
  if c.vertical:
    d.triangle(g.arrow1.x + g.arrow1.w / 2, g.arrow1.y + g.arrow1.h / 2, 7, '^', col)
    d.triangle(g.arrow2.x + g.arrow2.w / 2, g.arrow2.y + g.arrow2.h / 2, 7, 'v', col)
  else:
    d.triangle(g.arrow1.x + g.arrow1.w / 2, g.arrow1.y + g.arrow1.h / 2, 7, '<', col)
    d.triangle(g.arrow2.x + g.arrow2.w / 2, g.arrow2.y + g.arrow2.h / 2, 7, '>', col)
  d.fillRoundRect(g.thumb, min(g.thumb.w, g.thumb.h) / 2,
                     if c.dragging or c.hovered: withAlpha(t.textSecondary, 220) else: withAlpha(t.textSecondary, 150))

method onMouse*(c: Scrollbar, e: MouseEvent) =
  let g = c.geometry
  let lineStep = max(1.0, c.pageSize / 10)
  case e.action
  of maPress:
    if g.arrow1.containsPoint(e.x, e.y): c.applyValue(c.value - lineStep)
    elif g.arrow2.containsPoint(e.x, e.y): c.applyValue(c.value + lineStep)
    elif g.thumb.containsPoint(e.x, e.y):
      c.dragging = true
      c.dragOffset = if c.vertical: e.y - g.thumb.y else: e.x - g.thumb.x
    elif g.track.containsPoint(e.x, e.y):
      let before = if c.vertical: e.y < g.thumb.y else: e.x < g.thumb.x
      c.applyValue(c.value + (if before: -c.pageSize else: c.pageSize))
  of maMove:
    if c.dragging:
      let freeSpace = if c.vertical: g.track.h - g.thumb.h else: g.track.w - g.thumb.w
      let pos = if c.vertical: e.y - c.dragOffset - g.track.y else: e.x - c.dragOffset - g.track.x
      if freeSpace > 0: c.applyValue(c.minValue + clamp(pos / freeSpace, 0.0, 1.0) * (c.maxValue - c.minValue))
  of maRelease: c.dragging = false

method onWheel*(c: Scrollbar, dx, dy: float): bool =
  c.applyValue(c.value - dy * max(1.0, c.pageSize / 10) * 3)
  true

# Rating (stars; Do we really need it?)

type
  Rating* = ref object of Control
    maxValue*: int
    value*: float
    hoverIndex: int

proc newRating*(value = 0.0, maxValue = 5): Rating =
  result = Rating(maxValue: maxValue, value: value)
  initControl(result)
  result.focusable = true
  result.stretch = false

proc starPoints(cx, cy, r: float): seq[Point] =
  for i in 0 ..< 10:
    let a = -PI / 2 + float(i) * PI / 5
    let rr = if i mod 2 == 0: r else: r * 0.45
    result.add((cx + rr * cos(a), cy + rr * sin(a)))

proc starSize(c: Rating): float = min(c.rect.h, 28.0)

method typeName*(c: Rating): string = "Rating"

method valueNum*(c: Rating): float = c.value

method setValueNum*(c: Rating, v: float) = c.value = clamp(v, 0.0, float(c.maxValue))

method valueText*(c: Rating): string = formatNumber(c.value)

method setValueText*(c: Rating, v: string) =
  try: c.setValueNum(parseFloat(v.strip))
  except ValueError: discard

method preferredSize*(c: Rating, d: Drawing, t: Theme): tuple[w, h: float] =
  (float(c.maxValue) * 30.0, t.controlHeight)

method draw*(c: Rating, d: Drawing, t: Theme) =
  let s = c.starSize
  let v = if c.hovered and c.hoverIndex > 0 and c.isActive: float(c.hoverIndex) else: c.value
  let filled = if c.isGrayed: t.textDisabled else: c.style.accent.get(hex"#F5B301")
  for i in 0 ..< c.maxValue:
    let cx = c.rect.x + float(i) * (s + 2) + s / 2 + 1
    let cy = c.rect.y + c.rect.h / 2
    d.fillPolygon(starPoints(cx, cy, s / 2), if float(i) + 0.5 <= v: filled else: t.border)
  if c.focus: d.drawFocus(t, rect(c.rect.x, c.rect.y + (c.rect.h - s) / 2, float(c.maxValue) * (s + 2), s), 4)

method onMouse*(c: Rating, e: MouseEvent) =
  let s = c.starSize
  let i = clamp(int((e.x - c.rect.x) / (s + 2)) + 1, 1, c.maxValue)
  case e.action
  of maMove: c.hoverIndex = i
  of maRelease:
    if e.button == mbLeft and c.rect.containsPoint(e.x, e.y):
      c.value = if float(i) == c.value: 0.0 else: float(i)
      emit(c, evChange, index = int(c.value), text = formatNumber(c.value))
  else: discard

method onKey*(c: Rating, e: KeyEvent): bool =
  case e.key
  of SDLK_LEFT: c.value = max(0.0, c.value - 1)
  of SDLK_RIGHT: c.value = min(float(c.maxValue), c.value + 1)
  else: return false
  emit(c, evChange, index = int(c.value), text = formatNumber(c.value))
  true

# Shape

type
  ShapeKind* = enum
    skRectangle = "Rectangle", skRoundRect = "RoundRect", skEllipse = "Ellipse",
    skHLine = "HorizontalLine", skVLine = "VerticalLine", skDiagonal = "Diagonal"

  Shape* = ref object of Control
    shapeKind*: ShapeKind
    thickness*: float

proc newShape*(shapeKind = skRoundRect, thickness = 1.0): Shape =
  result = Shape(shapeKind: shapeKind, thickness: thickness)
  initControl(result)

method typeName*(c: Shape): string = "Shape"

method preferredSize*(c: Shape, d: Drawing, t: Theme): tuple[w, h: float] =
  case c.shapeKind
  of skHLine: (100.0, max(2.0, c.thickness + 4))
  of skVLine: (max(2.0, c.thickness + 4), 60.0)
  else: (80.0, 60.0)

method draw*(c: Shape, d: Drawing, t: Theme) =
  let r = c.rect
  let background = c.style.background.get(t.surface)
  let borderCol = c.style.border.get(t.border)
  let ep = c.thickness
  case c.shapeKind
  of skRectangle:
    d.fillRect(r, borderCol)
    d.fillRect(r.shrink(ep), background)
  of skRoundRect:
    let rad = c.style.radius.get(12)
    d.fillRoundRect(r, rad, borderCol)
    d.fillRoundRect(r.shrink(ep), max(0.0, rad - ep), background)
  of skEllipse:
    d.fillEllipse(r, borderCol)
    d.fillEllipse(r.shrink(ep), background)
  of skHLine: d.fillRect(rect(r.x, r.y + (r.h - ep) / 2, r.w, ep), borderCol)
  of skVLine: d.fillRect(rect(r.x + (r.w - ep) / 2, r.y, ep, r.h), borderCol)
  of skDiagonal: d.line(r.x, r.y, r.x + r.w, r.y + r.h, borderCol, ep)
  if c.caption.len > 0 and c.shapeKind in {skRectangle, skRoundRect, skEllipse}:
    d.textIn(r, c.caption, textColor(c, t), alCenter)

# Image

type
  ImageMode* = enum
    imCenter = "Centered", imStretch = "Stretched", imFit = "Fit (keep ratio)"

  Image* = ref object of Control
    path*: string
    mode*: ImageMode
    tex: SDL_Texture
    texPath: string
    texW, texH: float

proc newImage*(path = "", mode = imFit): Image =
  result = Image(path: path, mode: mode)
  initControl(result)

method typeName*(c: Image): string = "Image"

method valueText*(c: Image): string = c.path

method setValueText*(c: Image, v: string) = c.path = v

method preferredSize*(c: Image, d: Drawing, t: Theme): tuple[w, h: float] =
  if c.tex != nil: (c.texW, c.texH) else: (120.0, 90.0)

method draw*(c: Image, d: Drawing, t: Theme) =
  if c.path != c.texPath:
    if c.tex != nil: SDL_DestroyTexture(c.tex)
    c.tex = nil
    c.texPath = c.path
    if c.path.len > 0:
      when defined(sdlimage):
        let s = IMG_Load(c.path.cstring)
      else:
        let s = SDL_LoadBMP(c.path.cstring)
      if s != nil:
        c.tex = SDL_CreateTextureFromSurface(d.ren, s)
        SDL_DestroySurface(s)
        if c.tex != nil:
          var w, h: cfloat
          discard SDL_GetTextureSize(c.tex, addr w, addr h)
          c.texW = float(w)
          c.texH = float(h)
  let r = c.rect
  if c.style.background.isSome: d.fillRect(r, c.style.background.get)
  if c.tex == nil:
    d.strokeRect(r, t.border)
    d.line(r.x, r.y, r.x + r.w, r.y + r.h, t.border)
    d.line(r.x + r.w, r.y, r.x, r.y + r.h, t.border)
    return
  var dst = r
  case c.mode
  of imStretch: discard
  of imCenter:
    dst = rect(r.x + (r.w - c.texW) / 2, r.y + (r.h - c.texH) / 2, c.texW, c.texH)
  of imFit:
    let k = min(r.w / max(1.0, c.texW), r.h / max(1.0, c.texH))
    dst = rect(r.x + (r.w - c.texW * k) / 2, r.y + (r.h - c.texH * k) / 2, c.texW * k, c.texH * k)
  d.pushClip(r)
  d.drawTexture(c.tex, dst)
  d.popClip()

# Bar Code (Code 39)

const code39 = [
  ('0', "NNNWWNWNN"), ('1', "WNNWNNNNW"), ('2', "NNWWNNNNW"), ('3', "WNWWNNNNN"),
  ('4', "NNNWWNNNW"), ('5', "WNNWWNNNN"), ('6', "NNWWWNNNN"), ('7', "NNNWNNWNW"),
  ('8', "WNNWNNWNN"), ('9', "NNWWNNWNN"), ('A', "WNNNNWNNW"), ('B', "NNWNNWNNW"),
  ('C', "WNWNNWNNN"), ('D', "NNNNWWNNW"), ('E', "WNNNWWNNN"), ('F', "NNWNWWNNN"),
  ('G', "NNNNNWWNW"), ('H', "WNNNNWWNN"), ('I', "NNWNNWWNN"), ('J', "NNNNWWWNN"),
  ('K', "WNNNNNNWW"), ('L', "NNWNNNNWW"), ('M', "WNWNNNNWN"), ('N', "NNNNWNNWW"),
  ('O', "WNNNWNNWN"), ('P', "NNWNWNNWN"), ('Q', "NNNNNNWWW"), ('R', "WNNNNNWWN"),
  ('S', "NNWNNNWWN"), ('T', "NNNNWNWWN"), ('U', "WWNNNNNNW"), ('V', "NWWNNNNNW"),
  ('W', "WWWNNNNNN"), ('X', "NWNNWNNNW"), ('Y', "WWNNWNNNN"), ('Z', "NWWNWNNNN"),
  ('-', "NWNNNNWNW"), ('.', "WWNNNNWNN"), (' ', "NWWNNNWNN"), ('*', "NWNNWNWNN"),
  ('$', "NWNWNWNNN"), ('/', "NWNWNNNWN"), ('+', "NWNNNWNWN"), ('%', "NNNWNWNWN")]

proc code39Pattern(ch: char): string =
  for (k, v) in code39:
    if k == ch: return v
  ""

type
  BarCode* = ref object of Control
    text*: string
    showText*: bool

proc newBarCode*(text = "", showText = true): BarCode =
  result = BarCode(text: text.toUpperAscii, showText: showText)
  initControl(result)

method typeName*(c: BarCode): string = "Bar Code"

method valueText*(c: BarCode): string = c.text

method setValueText*(c: BarCode, v: string) = c.text = v.toUpperAscii

method preferredSize*(c: BarCode, d: Drawing, t: Theme): tuple[w, h: float] =
  (float(c.text.len + 2) * 16 * 1.6 + 20, 90.0)

method draw*(c: BarCode, d: Drawing, t: Theme) =
  let r = c.rect
  d.fillRect(r, c.style.background.get(White))
  var patterns: seq[string]
  patterns.add code39Pattern('*')
  for ch in c.text:
    let m = code39Pattern(ch)
    if m.len > 0: patterns.add m
  patterns.add code39Pattern('*')
  let units = float(patterns.len) * 16 - 1   # 6 narrow + 3 wide (×3) + gap
  let hTexte = if c.showText: d.textHeight + 4 else: 0.0
  let u = max(0.5, (r.w - 20) / units)
  var x = r.x + (r.w - units * u) / 2
  let col = c.style.text.get(Black)
  for m in patterns:
    for i, e in m:
      let w = (if e == 'W': 3.0 else: 1.0) * u
      if i mod 2 == 0: d.fillRect(rect(x, r.y + 6, w, max(0.0, r.h - 12 - hTexte)), col)
      x += w
    x += u
  if c.showText:
    d.textIn(rect(r.x, r.y + r.h - hTexte - 4, r.w, hTexte), "*" & c.text & "*", col, alCenter)

# Cell (decorated container)

type
  Cell* = ref object of Container

proc newCell*(layout = lkVertical, title = "", columns = 2): Cell =
  result = Cell(layout: layout, margin: -1, spacing: -1, columns: columns, framed: true)
  initControl(result, title)

method typeName*(c: Cell): string = "Cell"

method contentArea*(c: Cell, t: Theme): Rect =
  result = c.rect.shrink(c.marginOf(t))
  if c.caption.len > 0:
    result.y += t.lineHeight
    result.h = max(0.0, result.h - t.lineHeight)

method preferredSize*(c: Cell, d: Drawing, t: Theme): tuple[w, h: float] =
  result = procCall preferredSize(Container(c), d, t)
  if c.caption.len > 0: result.h += t.lineHeight

method draw*(c: Cell, d: Drawing, t: Theme) =
  let rad = radiusOf(c, t) + 2
  if c.framed: d.fillRoundRect(c.rect, rad, c.style.border.get(t.border))
  d.fillRoundRect(c.rect.shrink(if c.framed: 1.0 else: 0.0), rad - 1,
                     c.style.background.get(mix(t.windowBg, t.surface, 0.6)))
  if c.caption.len > 0:
    let m = c.marginOf(t)
    d.textIn(rect(c.rect.x + m, c.rect.y + m / 2, c.rect.w - 2*m, t.lineHeight),
                c.caption, t.textSecondary)

# Tab

type
  Tab* = ref object of Container
    hoverIndex: int

proc newTab*(): Tab =
  result = Tab(layout: lkStack, margin: -1, spacing: -1)
  initControl(result)
  result.focusable = true

proc addPage*(o: Tab, title: string, layout = lkVertical, columns = 2): Container =
  ## Adds a pane (page): a container whose caption is the tab title.
  result = newContainer(layout, 0, -1, columns)
  result.caption = title
  discard o.addChild(result)

proc tabHeaderHeight(t: Theme): float = t.controlHeight + 8

proc tabRects(o: Tab, d: Drawing, t: Theme): seq[Rect] =
  var ws: seq[float]
  var total = 0.0
  for e in o.children:
    let w = d.textWidth(e.caption) + 28
    ws.add w
    total += w
  let h = t.controlHeight
  var x = if t.look == lfMacOS: o.rect.x + max(0.0, (o.rect.w - total) / 2) else: o.rect.x + 4
  let y = o.rect.y + 4
  for w in ws:
    result.add rect(x, y, w, h)
    x += w + (if t.look == lfMacOS: 0.0 else: 2.0)

method typeName*(o: Tab): string = "Tab"

method contentArea*(o: Tab, t: Theme): Rect =
  let r = o.rect
  let h = tabHeaderHeight(t)
  rect(r.x, r.y + h, r.w, max(0.0, r.h - h)).shrink(o.marginOf(t))
method childShown*(o: Tab, i: int): bool = i == o.activePage

method preferredSize*(o: Tab, d: Drawing, t: Theme): tuple[w, h: float] =
  result = procCall preferredSize(Container(o), d, t)
  result.h += tabHeaderHeight(t)
method valueText*(o: Tab): string = $(o.activePage + 1)

method setValueText*(o: Tab, v: string) =
  try: o.activePage = clamp(parseInt(v.strip) - 1, 0, max(0, o.children.high))
  except ValueError: discard

method draw*(o: Tab, d: Drawing, t: Theme) =
  let r = o.rect
  let he = tabHeaderHeight(t)
  let panel = rect(r.x, r.y + he, r.w, max(0.0, r.h - he))
  let acc = o.style.accent.get(t.accent)
  if t.look == lfMacOS:
    let p2 = rect(panel.x, panel.y - he / 2 + 2, panel.w, panel.h + he / 2 - 2)
    d.fillRoundRect(p2, t.radius, t.border)
    d.fillRoundRect(p2.shrink(1), t.radius - 1, o.style.background.get(mix(t.windowBg, t.surfacePressed, 0.35)))
  else:
    d.fillRect(panel, t.border)
    d.fillRect(rect(panel.x, panel.y + 1, panel.w, max(0.0, panel.h - 1)), o.style.background.get(t.surface))
  let rs = o.tabRects(d, t)
  if not o.hovered: o.hoverIndex = -1
  if t.look == lfMacOS and rs.len > 0:
    let seg = rect(rs[0].x, rs[0].y, rs[^1].x + rs[^1].w - rs[0].x, rs[0].h)
    d.fillRoundRect(seg, t.radius, t.border)
    d.fillRoundRect(seg.shrink(1), t.radius - 1, t.surfacePressed)
  for i, rr in rs:
    let isActiveTab = i == o.activePage
    var col = if isActiveTab: t.text else: t.textSecondary
    if o.isGrayed: col = t.textDisabled
    case t.look
    of lfMacOS:
      if isActiveTab:
        d.fillRoundRect(rect(rr.x + 2, rr.y + 3, rr.w - 4, rr.h - 4), t.radius - 1, t.shadow)
        d.fillRoundRect(rect(rr.x + 2, rr.y + 2, rr.w - 4, rr.h - 4), t.radius - 1,
                           if t.dark: t.surface else: White)
      elif i == o.hoverIndex:
        d.fillRoundRect(rr.shrink(2), t.radius - 1, withAlpha(t.surfaceHover, 160))
    else:
      if isActiveTab:
        d.fillRoundRect(rect(rr.x, rr.y, rr.w, rr.h + 6), t.radius, t.border)
        d.fillRoundRect(rect(rr.x + 1, rr.y + 1, rr.w - 2, rr.h + 6), t.radius, o.style.background.get(t.surface))
        if t.look == lfWindows:
          d.fillRoundRect(rect(rr.x + rr.w / 2 - 8, rr.y + rr.h - 4, 16, 3), 1.5, acc)
        else:
          d.fillRect(rect(rr.x + 6, rr.y + rr.h - 3, rr.w - 12, 3), acc)
      elif i == o.hoverIndex:
        d.fillRoundRect(rr.shrink(2), t.radius, t.surfaceHover)
    d.textIn(rr, o.children[i].caption, col, alCenter)
    if o.focus and isActiveTab: d.drawFocus(t, rr.shrink(2), t.radius)

method onMouse*(o: Tab, e: MouseEvent) =
  let rs = o.tabRects(o.win.drawing, o.win.theme)
  for i, rr in rs:
    if rr.containsPoint(e.x, e.y):
      if e.action == maMove: o.hoverIndex = i
      elif e.action == maPress and e.button == mbLeft and i != o.activePage:
        o.activePage = i
        emit(o, evChange, index = i + 1, text = o.children[i].caption)
      return
  o.hoverIndex = -1

method onKey*(o: Tab, e: KeyEvent): bool =
  var n = o.activePage
  case e.key
  of SDLK_LEFT: n = max(0, n - 1)
  of SDLK_RIGHT: n = min(o.children.high, n + 1)
  else: return false
  if n != o.activePage and n >= 0:
    o.activePage = n
    emit(o, evChange, index = n + 1, text = o.children[n].caption)
  true

# Splitter

type
  Splitter* = ref object of Container
    vertical*: bool    # true: vertical bar (two panes side by side).
    position*: float   # 0..1.
    thickness*: float
    dragging: bool

proc newSplitter*(vertical = true, position = 0.5): Splitter =
  result = Splitter(vertical: vertical, position: position, thickness: 6,
                      layout: lkHorizontal, margin: 0, spacing: 0)
  initControl(result)

proc bar(s: Splitter): Rect =
  let r = s.rect
  if s.vertical: rect(r.x + (r.w - s.thickness) * s.position, r.y, s.thickness, r.h)
  else: rect(r.x, r.y + (r.h - s.thickness) * s.position, r.w, s.thickness)

method typeName*(s: Splitter): string = "Splitter"

method valueNum*(s: Splitter): float = s.position

method setValueNum*(s: Splitter, v: float) = s.position = clamp(v, 0.0, 1.0)

method valueText*(s: Splitter): string = formatNumber(s.position)

method setValueText*(s: Splitter, v: string) =
  try: s.setValueNum(parseFloat(v.strip))
  except ValueError: discard

method layoutChildren*(s: Splitter, d: Drawing, t: Theme) =
  let r = s.rect
  let b = s.bar
  var vis: seq[Control]
  for e in s.children:
    if e.visible: vis.add e
  if vis.len >= 1:
    layoutControl(vis[0], (if s.vertical: rect(r.x, r.y, b.x - r.x, r.h) else: rect(r.x, r.y, r.w, b.y - r.y)), d, t)
  if vis.len >= 2:
    layoutControl(vis[1], (if s.vertical: rect(b.x + b.w, r.y, r.x + r.w - b.x - b.w, r.h)
                      else: rect(r.x, b.y + b.h, r.w, r.y + r.h - b.y - b.h)), d, t)

method mouseCursor*(s: Splitter, x, y: float): int =
  if s.bar.containsPoint(x, y) or s.dragging:
    (if s.vertical: SDL_SYSTEM_CURSOR_EW_RESIZE else: SDL_SYSTEM_CURSOR_NS_RESIZE)
  else: SDL_SYSTEM_CURSOR_DEFAULT

method draw*(s: Splitter, d: Drawing, t: Theme) =
  let b = s.bar
  d.fillRect(b, if s.dragging or s.hovered: t.surfacePressed else: t.windowBg)
  let col = t.textSecondary
  for i in -1 .. 1:
    if s.vertical: d.fillCircle(b.x + b.w / 2, b.y + b.h / 2 + float(i) * 6, 1.5, col)
    else: d.fillCircle(b.x + b.w / 2 + float(i) * 6, b.y + b.h / 2, 1.5, col)

method onMouse*(s: Splitter, e: MouseEvent) =
  case e.action
  of maPress: s.dragging = s.bar.containsPoint(e.x, e.y)
  of maMove:
    if s.dragging:
      let r = s.rect
      let p = if s.vertical: (e.x - r.x) / max(1.0, r.w - s.thickness)
              else: (e.y - r.y) / max(1.0, r.h - s.thickness)
      s.position = clamp(p, 0.05, 0.95)
  of maRelease:
    if s.dragging:
      s.dragging = false
      emit(s, evChange, text = formatNumber(s.position))

# Toolbar

type
  Toolbar* = ref object of Container

proc newToolbar*(): Toolbar =
  result = Toolbar(layout: lkHorizontal, margin: 4, spacing: 4)
  initControl(result)

proc addTool*(b: Toolbar, caption: string, tooltip = ""): Button =
  result = newButton(caption)
  result.flat = true
  result.tooltip = tooltip
  discard b.addChild(result)

method typeName*(b: Toolbar): string = "Toolbar"

method draw*(b: Toolbar, d: Drawing, t: Theme) =
  d.fillRect(b.rect, b.style.background.get(t.header))
  d.fillRect(rect(b.rect.x, b.rect.y + b.rect.h - 1, b.rect.w, 1), t.border)
