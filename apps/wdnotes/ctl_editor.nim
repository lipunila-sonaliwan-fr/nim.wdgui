# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
#   _._
# o|- -|o  wdnotes - MdEditor, the design-mode editor (custom control)
#  ( l )   soft wrap, Markdown highlighting (headings, lists, quotes, code,
#    =     links, [[wiki links]], { instructions }), selection, clipboard,
#          undo / redo, list continuation, indentation, line numbers.
#
# Commands are sent through the id API: `edId.value = "cmd" & Sep & args`
#   set <text>                     replace the whole text
#   wrap <before> <after> <ph>     surround the selection (or a placeholder)
#   prefix <p>                     toggle a line prefix ("# ", "> ", "- "...)
#   block <before> <after>         surround the selected lines with lines
#   insert <text>                  insert at the caret
#   suffix <text>                  append to the current line ({ ... })
#   link <title>                   [[title]] or [[title|selection]]
#   goto <line>                    select a line (1-based) and show it
#   theme dark|light
# `edId.value` returns the text.
# Events: evChange "edit" after a modification, "cmd:save|link|find|consult|
# new" for shortcuts, evSelection "line:col" when the caret moves.

import std/[strutils, tables]
import std/unicode except strip, split, splitWhitespace, align, alignLeft, cmpIgnoreCase, reversed
import wdcompat

const Sep* = "\x1F"

type
  VRow = object
    line, a, b: int

  Snap = object
    text: string
    cl, cc: int

  Pal = object
    bg, gutter, gutterText, text, current, sel, caret, heading, marker, quote,
      code, codeBg, link, wiki, attr, dim, fence: Color

  MdEditor* = ref object of Control
    lines: seq[seq[Rune]]
    cl, cc, al, ac: int
    scrollY: float
    undoStack, redoStack: seq[Snap]
    lastKind: int
    lastTime: float
    focused, dragging, dark, follow: bool
    lastClick: float
    clicks: int
    rows: seq[VRow]
    rowsW: float
    rowsVer, ver, codeVer: int
    codeState: seq[int8]          ## 0 text, 1 inside code, 2 fence line
    lineH, gutterW, goalX, viewH: float
    widths: Table[int32, float]
    lastCaret: string

proc palette(dark: bool): Pal =
  if dark:
    Pal(bg: col("#1c1e22"), gutter: col("#18191c"), gutterText: col("#4d525b"),
        text: col("#dcdfe4"), current: col("#23262c"), sel: col("#2f4a6e"),
        caret: col("#e5c158"), heading: col("#8fb3e0"), marker: col("#d8b64a"),
        quote: col("#9aa0aa"), code: col("#e38b7f"), codeBg: col("#25282d"),
        link: col("#7aa7ff"), wiki: col("#5fc2b0"), attr: col("#c29bf0"),
        dim: col("#5b606a"), fence: col("#7d838d"))
  else:
    Pal(bg: col("#fbfaf7"), gutter: col("#f2f0ea"), gutterText: col("#b6b0a2"),
        text: col("#2b2b2b"), current: col("#f4f1e7"), sel: col("#cfe0f5"),
        caret: col("#1f3a5f"), heading: col("#1f3a5f"), marker: col("#b8901a"),
        quote: col("#6b6b6b"), code: col("#a33a3a"), codeBg: col("#eff0f2"),
        link: col("#2d6cdf"), wiki: col("#0f7b6c"), attr: col("#8a4fbf"),
        dim: col("#b8b2a4"), fence: col("#8a8f98"))

proc newMdEditor*(): MdEditor =
  result = MdEditor()
  initControl(result, "")
  result.lines = @[newSeq[Rune]()]
  result.lineH = 22
  result.rowsVer = -1
  result.codeVer = -1
  result.widths = initTable[int32, float]()
  makeFocusable(result)

# text model

proc text*(c: MdEditor): string =
  var parts = newSeq[string](c.lines.len)
  for i, l in c.lines: parts[i] = $l
  parts.join("\n")

proc setText(c: MdEditor, s: string) =
  c.lines = @[]
  for l in s.replace("\r\n", "\n").replace("\t", "    ").split('\n'): c.lines.add l.toRunes
  if c.lines.len == 0: c.lines.add newSeq[Rune]()
  c.cl = 0; c.cc = 0; c.al = 0; c.ac = 0
  c.scrollY = 0
  inc c.ver

proc ch(l: seq[Rune], k: int): char =
  if k >= 0 and k < l.len and int(l[k]) < 128: char(int(l[k])) else: '\0'

proc hasSel(c: MdEditor): bool = c.cl != c.al or c.cc != c.ac

proc selRange(c: MdEditor): (int, int, int, int) =
  if c.al < c.cl or (c.al == c.cl and c.ac < c.cc): (c.al, c.ac, c.cl, c.cc)
  else: (c.cl, c.cc, c.al, c.ac)

proc selectedText(c: MdEditor): string =
  if not c.hasSel: return ""
  let (sl, sc, el, ec) = c.selRange
  if sl == el: return $c.lines[sl][sc ..< ec]
  result = $c.lines[sl][sc .. ^1]
  for i in sl + 1 ..< el: result.add "\n" & $c.lines[i]
  result.add "\n" & $c.lines[el][0 ..< ec]

proc collapse(c: MdEditor) =
  c.al = c.cl; c.ac = c.cc

proc deleteSel(c: MdEditor) =
  if not c.hasSel: return
  let (sl, sc, el, ec) = c.selRange
  c.lines[sl] = c.lines[sl][0 ..< sc] & c.lines[el][ec .. ^1]
  for _ in sl + 1 .. el: c.lines.delete(sl + 1)
  c.cl = sl; c.cc = sc
  c.collapse()

proc insertText(c: MdEditor, s: string) =
  c.deleteSel()
  let parts = s.replace("\r\n", "\n").replace("\t", "    ").split('\n')
  let head = c.lines[c.cl][0 ..< c.cc]
  let tail = c.lines[c.cl][c.cc .. ^1]
  if parts.len == 1:
    let p = parts[0].toRunes
    c.lines[c.cl] = head & p & tail
    c.cc += p.len
  else:
    c.lines[c.cl] = head & parts[0].toRunes
    var at = c.cl
    for k in 1 ..< parts.high:
      inc at
      c.lines.insert(parts[k].toRunes, at)
    inc at
    let last = parts[^1].toRunes
    c.lines.insert(last & tail, at)
    c.cl = at
    c.cc = last.len
  c.collapse()

proc pushUndo(c: MdEditor, kind = 0) =
  let t = nowSec()
  if kind == 1 and c.lastKind == 1 and t - c.lastTime < 1.2:
    c.lastTime = t
    return
  c.undoStack.add Snap(text: c.text, cl: c.cl, cc: c.cc)
  if c.undoStack.len > 300: c.undoStack.delete(0)
  c.redoStack.setLen(0)
  c.lastKind = kind
  c.lastTime = t

proc restore(c: MdEditor, s: Snap) =
  let sy = c.scrollY
  c.setText(s.text)
  c.cl = min(s.cl, c.lines.high)
  c.cc = min(s.cc, c.lines[c.cl].len)
  c.collapse()
  c.scrollY = sy
  c.follow = true

proc changed(c: MdEditor) =
  inc c.ver
  c.follow = true
  emit(c, evChange, text = "edit")

proc notifyCaret(c: MdEditor) =
  let s = $(c.cl + 1) & ":" & $(c.cc + 1)
  if s != c.lastCaret:
    c.lastCaret = s
    emit(c, evSelection, text = s)

# layout

proc cw(c: MdEditor, d: Drawing, r: Rune): float =
  let k = int32(r)
  if k in c.widths: return c.widths[k]
  result = d.gfxTextW($r)
  c.widths[k] = result

proc ensureRows(c: MdEditor, d: Drawing, width: float) =
  if c.rowsVer == c.ver and abs(c.rowsW - width) < 0.5: return
  c.rows.setLen(0)
  for i, l in c.lines:
    if l.len == 0:
      c.rows.add VRow(line: i, a: 0, b: 0); continue
    var start = 0
    while start < l.len:
      var x = 0.0
      var k = start
      var lastSpace = -1
      while k < l.len:
        let w = c.cw(d, l[k])
        if x + w > width and k > start: break
        if l[k] == Rune(32): lastSpace = k
        x += w
        inc k
      var stop = k
      if k < l.len and lastSpace > start: stop = lastSpace + 1
      c.rows.add VRow(line: i, a: start, b: stop)
      start = stop
  c.rowsW = width
  c.rowsVer = c.ver

proc ensureCode(c: MdEditor) =
  if c.codeVer == c.ver: return
  c.codeState.setLen(c.lines.len)
  var inCode = false
  var fenceCh = '\0'
  for i, l in c.lines:
    var k = 0
    while k < l.len and l[k] == Rune(32): inc k
    let f = ch(l, k)
    let isFence = (f == '`' or f == '~') and ch(l, k + 1) == f and ch(l, k + 2) == f
    if isFence and (not inCode or f == fenceCh):
      c.codeState[i] = 2
      if not inCode: fenceCh = f
      inCode = not inCode
    else:
      c.codeState[i] = int8(if inCode: 1 else: 0)
  c.codeVer = c.ver

proc rowIndex(c: MdEditor, line, col: int): int =
  for i, r in c.rows:
    if r.line == line and col >= r.a and (col < r.b or (col == r.b and
        (i == c.rows.high or c.rows[i + 1].line != line))):
      return i
  max(0, c.rows.high)

proc xOf(c: MdEditor, d: Drawing, row: VRow, col: int): float =
  let l = c.lines[row.line]
  for k in row.a ..< min(col, row.b): result += c.cw(d, l[k])

# highlighting

proc highlight(c: MdEditor, i: int): seq[uint8] =
  # 0 text 1 heading 2 marker 3 quote 4 code 5 link 6 wiki 7 attr 8 dim 9 fence.
  let l = c.lines[i]
  result = newSeq[uint8](l.len)
  let state = if i < c.codeState.len: c.codeState[i] else: 0'i8
  if state == 2:
    for k in 0 ..< l.len: result[k] = 9
    return
  if state == 1:
    for k in 0 ..< l.len: result[k] = 4
    return
  var k = 0
  while k < l.len and l[k] == Rune(32): inc k
  let first = ch(l, k)
  var base: uint8 = 0
  if first == '#':
    base = 1
  elif first == '>':
    base = 3
  elif first == ':' and ch(l, k + 1) == ':' and ch(l, k + 2) == ':':
    base = 7
  for j in 0 ..< l.len: result[j] = base
  if first in {'-', '*', '+'} and ch(l, k + 1) == ' ':
    result[k] = 2
    if ch(l, k + 2) == '[' and ch(l, k + 4) == ']':
      for j in k + 2 .. k + 4: result[j] = 2
  elif first in {'0'..'9'}:
    var j = k
    while ch(l, j) in {'0'..'9'}: inc j
    if ch(l, j) in {'.', ')'} and ch(l, j + 1) == ' ':
      for m in k .. j: result[m] = 2
  if first == '-' or first == '*' or first == '_':
    var allSame = true
    for j in k ..< l.len:
      if ch(l, j) != first and l[j] != Rune(32): allSame = false
    if allSame and l.len - k >= 3:
      for j in k ..< l.len: result[j] = 2
  if base == 1:
    var j = k
    while ch(l, j) == '#': result[j] = 2; inc j
  # inline elements
  var j = k
  while j < l.len:
    let cj = ch(l, j)
    case cj
    of '`':
      var e = j + 1
      while e < l.len and ch(l, e) != '`': inc e
      if e < l.len:
        for m in j .. e: result[m] = 4
        j = e + 1; continue
    of '[':
      if ch(l, j + 1) == '[':
        var e = j + 2
        while e + 1 < l.len and not (ch(l, e) == ']' and ch(l, e + 1) == ']'): inc e
        if e + 1 < l.len:
          for m in j .. e + 1: result[m] = 6
          result[j] = 8; result[j + 1] = 8; result[e] = 8; result[e + 1] = 8
          j = e + 2; continue
      else:
        var e = j + 1
        while e < l.len and ch(l, e) != ']': inc e
        if e + 1 < l.len and ch(l, e + 1) == '(':
          var f = e + 2
          while f < l.len and ch(l, f) != ')': inc f
          for m in j .. min(f, l.high): result[m] = 8
          for m in j + 1 ..< e: result[m] = 5
          j = f + 1; continue
    of '{':
      var e = j + 1
      while e < l.len and ch(l, e) != '}': inc e
      if e < l.len:
        for m in j .. e: result[m] = 7
        j = e + 1; continue
    of '*', '_', '~':
      if not (cj == '_' and j > 0 and ch(l, j - 1) in {'a'..'z', 'A'..'Z', '0'..'9'}):
        if result[j] != 2: result[j] = 8
    of '|':
      result[j] = 2
    else: discard
    inc j

# drawing

method typeName*(c: MdEditor): string = "MdEditor"

method preferredSize*(c: MdEditor, d: Drawing, t: Theme): tuple[w, h: float] = (420.0, 320.0)

method acceptsText*(c: MdEditor): bool = true

method draw*(c: MdEditor, d: Drawing, t: Theme) =
  let pal = palette(c.dark)
  let r = c.rect
  d.gfxFontReset(t)
  if c.widths.len > 0 and c.lineH != round(d.gfxTextH(t) * 1.6):
    c.widths.clear()
    c.rowsVer = -1
  c.lineH = round(d.gfxTextH(t) * 1.6)
  c.gutterW = 48
  let pad = 10.0
  let x0 = r.x + c.gutterW + 16
  let width = max(60.0, r.w - c.gutterW - 34)
  c.viewH = r.h
  c.ensureRows(d, width)
  c.ensureCode()
  let total = float(c.rows.len) * c.lineH + 2 * pad
  # follow the caret
  let cri = c.rowIndex(c.cl, c.cc)
  if c.follow:
    let cy = float(cri) * c.lineH
    if cy < c.scrollY: c.scrollY = cy
    elif cy + c.lineH > c.scrollY + r.h - 2 * pad: c.scrollY = cy + c.lineH - r.h + 2 * pad
    c.follow = false
  c.scrollY = clamp(c.scrollY, 0.0, max(0.0, total - r.h))
  d.gfxFill(r.x, r.y, r.w, r.h, pal.bg)
  d.gfxFill(r.x, r.y, c.gutterW, r.h, pal.gutter)
  d.gfxClip(r.x, r.y, r.w, r.h)
  let (sl, sc, el, ec) = c.selRange
  let sel = c.hasSel
  let firstRow = max(0, int(c.scrollY / c.lineH) - 1)
  let lastRow = min(c.rows.high, firstRow + int(r.h / c.lineH) + 2)
  for ri in firstRow .. lastRow:
    let row = c.rows[ri]
    let y = r.y + pad + float(ri) * c.lineH - c.scrollY
    let state = c.codeState[row.line]
    if state > 0:
      d.gfxFill(x0 - 8, y, width + 12, c.lineH, pal.codeBg)
    if row.line == c.cl and not sel:
      d.gfxFill(r.x + c.gutterW, y, r.w - c.gutterW, c.lineH, pal.current)
    if row.a == 0:
      let num = $(row.line + 1)
      let nw = d.gfxTextW(num)
      d.gfxText(r.x + c.gutterW - nw - 10, y, c.lineH, num,
                if row.line == c.cl: pal.marker else: pal.gutterText)
    # selection
    if sel and row.line >= sl and row.line <= el:
      let a = if row.line == sl: max(sc, row.a) else: row.a
      let b = if row.line == el: min(ec, row.b) else: row.b
      if b >= a and not (row.line == el and ec < row.a) and not (row.line == sl and sc > row.b):
        let xa = x0 + c.xOf(d, row, a)
        var xb = x0 + c.xOf(d, row, b)
        if row.line < el and b == row.b: xb += 6
        d.gfxFill(xa, y + 1, max(xb - xa, 2), c.lineH - 2, pal.sel)
    # text, by colour segments
    let kinds = c.highlight(row.line)
    let l = c.lines[row.line]
    var k = row.a
    var x = x0
    while k < row.b:
      var e = k
      while e < row.b and kinds[e] == kinds[k]: inc e
      let seg = $l[k ..< e]
      let colr = case kinds[k]
        of 1: pal.heading
        of 2: pal.marker
        of 3: pal.quote
        of 4: pal.code
        of 5: pal.link
        of 6: pal.wiki
        of 7: pal.attr
        of 8: pal.dim
        of 9: pal.fence
        else: pal.text
      if kinds[k] == 1: d.gfxFont("Sans", float(t.fontSize), true, false)
      d.gfxText(x, y, c.lineH, seg, colr)
      if kinds[k] == 1: d.gfxFontReset(t)
      for m in k ..< e: x += c.cw(d, l[m])
      k = e
    # caret
    if ri == cri and c.focused:
      let cx = x0 + c.xOf(d, row, c.cc)
      d.gfxFill(cx - 1, y + 3, 2, c.lineH - 6, pal.caret)
  # empty document hint.
  if c.lines.len == 1 and c.lines[0].len == 0:
    d.gfxText(x0, r.y + pad, c.lineH, "Commencez à écrire en Markdown…", pal.dim)
  # scrollbar.
  if total > r.h:
    let th = max(30.0, r.h * r.h / total)
    let ty = r.y + (r.h - th) * c.scrollY / (total - r.h)
    d.gfxRound(r.x + r.w - 7, ty + 2, 4, th - 4, 2, pal.dim)
  d.gfxUnclip()

# moving

proc moveTo(c: MdEditor, line, col: int, extend: bool) =
  c.cl = clamp(line, 0, c.lines.high)
  c.cc = clamp(col, 0, c.lines[c.cl].len)
  if not extend: c.collapse()
  c.follow = true

proc wordLeft(c: MdEditor): (int, int) =
  var l = c.cl
  var k = c.cc
  if k == 0:
    if l > 0: return (l - 1, c.lines[l - 1].len)
    return (0, 0)
  let s = c.lines[l]
  while k > 0 and not s[k - 1].isAlpha: dec k
  while k > 0 and s[k - 1].isAlpha: dec k
  (l, k)

proc wordRight(c: MdEditor): (int, int) =
  let l = c.cl
  var k = c.cc
  let s = c.lines[l]
  if k >= s.len:
    if l < c.lines.high: return (l + 1, 0)
    return (l, k)
  while k < s.len and not s[k].isAlpha: inc k
  while k < s.len and s[k].isAlpha: inc k
  (l, k)

proc moveRows(c: MdEditor, delta: int, extend: bool) =
  if c.rows.len == 0: return
  let ri = c.rowIndex(c.cl, c.cc)
  let nri = clamp(ri + delta, 0, c.rows.high)
  # goal column measured in characters from the row start (no Drawing here).
  let goal = c.cc - c.rows[ri].a
  let row = c.rows[nri]
  c.moveTo(row.line, min(row.a + goal, (if row.b > row.a and nri < c.rows.high and
    c.rows[nri + 1].line == row.line: row.b - 1 else: row.b)), extend)

# editing helpers

proc lineRange(c: MdEditor): (int, int) =
  if c.hasSel:
    let (sl, _, el, ec) = c.selRange
    (sl, if ec == 0 and el > sl: el - 1 else: el)
  else: (c.cl, c.cl)

proc togglePrefix(c: MdEditor, p: string) =
  let (a, b) = c.lineRange
  let pr = p.toRunes
  var allHave = true
  for i in a .. b:
    if not ($c.lines[i]).startsWith(p): allHave = false
  for i in a .. b:
    var s = $c.lines[i]
    if allHave:
      s = s[p.len .. ^1]
    else:
      if p.startsWith("#"):
        var k = 0
        while k < s.len and s[k] == '#': inc k
        if k > 0: s = s[k .. ^1].strip(trailing = false)
      elif p in ["- ", "* ", "1. ", "- [ ] ", "> "]:
        for old in ["- [ ] ", "- [x] ", "- ", "* ", "> "]:
          if s.startsWith(old): s = s[old.len .. ^1]; break
        var k = 0
        while k < s.len and s[k].isDigit: inc k
        if k > 0 and k + 1 < s.len and s[k] in {'.', ')'} and s[k + 1] == ' ': s = s[k + 2 .. ^1]
      var pre = p
      if p == "1. ": pre = $(i - a + 1) & ". "
      s = pre & s
    c.lines[i] = s.toRunes
  discard pr
  c.al = a; c.ac = 0
  c.cl = b; c.cc = c.lines[b].len

proc indentLines(c: MdEditor, outdent: bool) =
  let (a, b) = c.lineRange
  for i in a .. b:
    var s = $c.lines[i]
    if outdent:
      var k = 0
      while k < 2 and k < s.len and s[k] == ' ': inc k
      s = s[k .. ^1]
    else: s = "  " & s
    c.lines[i] = s.toRunes
  c.cc = clamp(c.cc + (if outdent: -2 else: 2), 0, c.lines[c.cl].len)
  c.ac = clamp(c.ac + (if outdent: -2 else: 2), 0, c.lines[c.al].len)

proc newlineContinue(c: MdEditor) =
  # Enter: continue lists, tasks, quotes and ordered lists.
  let s = $c.lines[c.cl]
  var k = 0
  while k < s.len and s[k] == ' ': inc k
  let ind = s[0 ..< k]
  let rest = s[k .. ^1]
  var prefix = ""
  for p in ["- [ ] ", "- [x] ", "* [ ] ", "- ", "* ", "+ ", "> "]:
    if rest.startsWith(p):
      prefix = (if p.contains("[x]"): "- [ ] " else: p)
      break
  if prefix.len == 0:
    var j = 0
    while j < rest.len and rest[j].isDigit: inc j
    if j > 0 and j + 1 < rest.len and rest[j] in {'.', ')'} and rest[j + 1] == ' ':
      prefix = $(parseInt(rest[0 ..< j]) + 1) & rest[j] & " "
  let onlyPrefix = prefix.len > 0 and rest.strip.len <= prefix.strip.len and
                   c.cc == c.lines[c.cl].len
  if onlyPrefix:
    # empty item: end the list
    c.lines[c.cl] = newSeq[Rune]()
    c.cc = 0
    c.collapse()
    return
  c.insertText("\n" & ind & prefix)

# events

method onFocus*(c: MdEditor, gained: bool) =
  c.focused = gained

method onWheel*(c: MdEditor, dx, dy: float): bool =
  c.scrollY -= float(dy) * c.lineH * 3
  c.scrollY = max(0.0, c.scrollY)
  true

method onMouse*(c: MdEditor, e: MouseEvent) =
  if c.rows.len == 0: return
  let r = c.rect
  let x = mouseX(e) - (r.x + c.gutterW + 16)
  let ri = clamp(int((mouseY(e) - r.y - 10 + c.scrollY) / c.lineH), 0, c.rows.high)
  let row = c.rows[ri]
  if e.action == maPress:
    if e.button != mbLeft: return
    c.focused = true
    let t = nowSec()
    c.clicks = if t - c.lastClick < 0.35: c.clicks + 1 else: 1
    c.lastClick = t
    # only the row geometry measured during draw is needed: approximate column from cached widths.
    var acc = 0.0
    var col = row.b
    let l = c.lines[row.line]
    for k in row.a ..< row.b:
      let w = c.widths.getOrDefault(int32(l[k]), 8.0)
      if acc + w / 2 > x: col = k; break
      acc += w
    if col == row.b and row.b > row.a and row.b < l.len and l[row.b - 1] == Rune(32): col = row.b - 1
    let extend = (currentMods() and ModShift) != 0
    c.moveTo(row.line, col, extend)
    if c.clicks == 2:
      var a = col
      var b = col
      while a > 0 and l[a - 1].isAlpha: dec a
      while b < l.len and l[b].isAlpha: inc b
      c.al = row.line; c.ac = a; c.cc = b
    elif c.clicks >= 3:
      c.al = row.line; c.ac = 0; c.cc = l.len
    c.dragging = true
  elif e.action == maMove:
    if c.dragging:
      var acc = 0.0
      var col = row.b
      let l = c.lines[row.line]
      for k in row.a ..< row.b:
        let w = c.widths.getOrDefault(int32(l[k]), 8.0)
        if acc + w / 2 > x: col = k; break
        acc += w
      c.cl = row.line
      c.cc = col
  elif e.action == maRelease:
    c.dragging = false
    c.notifyCaret()

method onText*(c: MdEditor, s: string) =
  c.pushUndo(if s == " ": 2 else: 1)
  c.insertText(s)
  c.changed()
  c.notifyCaret()

method onKey*(c: MdEditor, e: WdKeyEvent): bool =
  let k = keyCode(e)
  let m = keyMods(e)
  let shift = (m and ModShift) != 0
  let cmd = (m and (ModCtrl or ModGui)) != 0
  result = true
  case k
  of KLeft:
    if c.hasSel and not shift:
      let (sl, sc, _, _) = c.selRange
      c.moveTo(sl, sc, false)
    elif cmd:
      let (l, col) = c.wordLeft
      c.moveTo(l, col, shift)
    elif c.cc > 0: c.moveTo(c.cl, c.cc - 1, shift)
    elif c.cl > 0: c.moveTo(c.cl - 1, c.lines[c.cl - 1].len, shift)
  of KRight:
    if c.hasSel and not shift:
      let (_, _, el, ec) = c.selRange
      c.moveTo(el, ec, false)
    elif cmd:
      let (l, col) = c.wordRight
      c.moveTo(l, col, shift)
    elif c.cc < c.lines[c.cl].len: c.moveTo(c.cl, c.cc + 1, shift)
    elif c.cl < c.lines.high: c.moveTo(c.cl + 1, 0, shift)
  of KUp:
    if cmd: c.moveTo(0, 0, shift) else: c.moveRows(-1, shift)
  of KDown:
    if cmd: c.moveTo(c.lines.high, c.lines[^1].len, shift) else: c.moveRows(1, shift)
  of KPageUp: c.moveRows(-max(1, int(c.viewH / c.lineH) - 2), shift)
  of KPageDown: c.moveRows(max(1, int(c.viewH / c.lineH) - 2), shift)
  of KHome:
    if cmd: c.moveTo(0, 0, shift)
    else:
      let row = c.rows[c.rowIndex(c.cl, c.cc)]
      c.moveTo(c.cl, row.a, shift)
  of KEnd:
    if cmd: c.moveTo(c.lines.high, c.lines[^1].len, shift)
    else:
      let ri = c.rowIndex(c.cl, c.cc)
      let row = c.rows[ri]
      let last = ri == c.rows.high or c.rows[ri + 1].line != row.line
      c.moveTo(c.cl, (if last: row.b else: max(row.a, row.b - 1)), shift)
  of KBackspace:
    c.pushUndo(3)
    if c.hasSel: c.deleteSel()
    elif c.cc > 0:
      c.lines[c.cl].delete(c.cc - 1)
      dec c.cc
      c.collapse()
    elif c.cl > 0:
      let prev = c.lines[c.cl - 1].len
      c.lines[c.cl - 1].add c.lines[c.cl]
      c.lines.delete(c.cl)
      dec c.cl
      c.cc = prev
      c.collapse()
    c.changed()
  of KDelete:
    c.pushUndo(3)
    if c.hasSel: c.deleteSel()
    elif c.cc < c.lines[c.cl].len: c.lines[c.cl].delete(c.cc)
    elif c.cl < c.lines.high:
      c.lines[c.cl].add c.lines[c.cl + 1]
      c.lines.delete(c.cl + 1)
    c.changed()
  of KReturn, KKpEnter:
    c.pushUndo()
    if cmd: emit(c, evChange, text = "cmd:consult")
    else:
      c.deleteSel()
      c.newlineContinue()
      c.changed()
  of KTab:
    c.pushUndo()
    let s = $c.lines[c.cl]
    let st = s.strip(trailing = false)
    let isItem = st.startsWith("- ") or st.startsWith("* ") or st.startsWith("+ ") or
                 (st.len > 1 and st[0].isDigit)
    if shift: c.indentLines(true)
    elif c.hasSel and c.selRange[0] != c.selRange[2]: c.indentLines(false)
    elif isItem: c.indentLines(false)
    else: c.insertText("    ")
    c.changed()
  of KEscape:
    c.collapse()
  else:
    if not cmd: return false
    case char(k and 0x7F)
    of 'a':
      c.al = 0; c.ac = 0
      c.cl = c.lines.high; c.cc = c.lines[^1].len
    of 'c':
      if c.hasSel: clipboardSet(c.selectedText)
    of 'x':
      if c.hasSel:
        clipboardSet(c.selectedText)
        c.pushUndo()
        c.deleteSel()
        c.changed()
    of 'v':
      let s = clipboardGet()
      if s.len > 0:
        c.pushUndo()
        c.insertText(s)
        c.changed()
    of 'z':
      if shift:
        if c.redoStack.len > 0:
          c.undoStack.add Snap(text: c.text, cl: c.cl, cc: c.cc)
          c.restore(c.redoStack.pop())
          inc c.ver
          emit(c, evChange, text = "edit")
      elif c.undoStack.len > 0:
        c.redoStack.add Snap(text: c.text, cl: c.cl, cc: c.cc)
        c.restore(c.undoStack.pop())
        c.lastKind = 0
        inc c.ver
        emit(c, evChange, text = "edit")
    of 'y':
      if c.redoStack.len > 0:
        c.undoStack.add Snap(text: c.text, cl: c.cl, cc: c.cc)
        c.restore(c.redoStack.pop())
        inc c.ver
        emit(c, evChange, text = "edit")
    of 'b', 'i':
      let mark = if char(k and 0x7F) == 'b': "**" else: "*"
      c.pushUndo()
      if c.hasSel:
        let s = c.selectedText
        c.insertText(mark & s & mark)
      else:
        c.insertText(mark & mark)
        c.cc -= mark.len
        c.collapse()
      c.changed()
    of 'd':
      c.pushUndo()
      let dup = c.lines[c.cl]
      c.lines.insert(dup, c.cl + 1)
      inc c.cl
      c.collapse()
      c.changed()
    of 's': emit(c, evChange, text = "cmd:save")
    of 'k': emit(c, evChange, text = "cmd:link")
    of 'f': emit(c, evChange, text = "cmd:find")
    of 'e': emit(c, evChange, text = "cmd:consult")
    of 'n': emit(c, evChange, text = "cmd:new")
    else: return false
  inc c.ver
  c.follow = true
  c.notifyCaret()

# id API

method valueText*(c: MdEditor): string = c.text

method setValueText*(c: MdEditor, s: string) =
  let parts = s.split(Sep)
  let cmd = parts[0]
  template arg(i: int): string = (if parts.len > i: parts[i] else: "")
  case cmd
  of "set":
    c.setText(s[min(s.len, 4) .. ^1])
    c.undoStack.setLen(0)
    c.redoStack.setLen(0)
  of "wrap":
    c.pushUndo()
    let before = arg(1)
    let after = arg(2)
    if c.hasSel:
      let sel = c.selectedText
      c.insertText(before & sel & after)
      # reselect the content.
      c.cc -= after.toRunes.len
      c.al = c.cl
      c.ac = max(0, c.cc - sel.toRunes.len)
      if '\n' in sel: c.collapse()
    else:
      let ph = arg(3)
      c.insertText(before & ph & after)
      c.cc -= after.toRunes.len
      c.al = c.cl
      c.ac = max(0, c.cc - ph.toRunes.len)
    inc c.ver
  of "prefix":
    c.pushUndo()
    c.togglePrefix(arg(1))
    inc c.ver
  of "block":
    c.pushUndo()
    let (a, b) = c.lineRange
    c.lines.insert(arg(2).toRunes, b + 1)
    c.lines.insert(arg(1).toRunes, a)
    c.cl = a + 1; c.cc = 0
    c.al = b + 1; c.ac = c.lines[b + 1].len
    if a == b and c.lines[a + 1].len == 0:
      c.al = c.cl; c.ac = 0
    inc c.ver
  of "insert":
    c.pushUndo()
    c.insertText(s[min(s.len, 7) .. ^1])
    inc c.ver
  of "suffix":
    c.pushUndo()
    c.cc = c.lines[c.cl].len
    c.collapse()
    let sfx = arg(1)
    let pre = if c.cc > 0 and c.lines[c.cl][^1] != Rune(32): " " else: ""
    c.insertText(pre & sfx)
    let inner = sfx.find(':')
    if sfx.endsWith("}") and inner >= 0:
      c.cc -= 1
      c.collapse()
    inc c.ver
  of "link":
    c.pushUndo()
    let title = arg(1)
    if c.hasSel and '\n' notin c.selectedText:
      c.insertText("[[" & title & "|" & c.selectedText & "]]")
    else:
      c.insertText("[[" & title & "]]")
    inc c.ver
  of "goto":
    var n = 1
    try: n = parseInt(arg(1).strip)
    except ValueError: discard
    let l = clamp(n - 1, 0, c.lines.high)
    c.al = l; c.ac = 0
    c.cl = l; c.cc = c.lines[l].len
    c.follow = true
  of "theme":
    c.dark = arg(1) == "dark"
  else:
    c.setText(s)
  c.follow = true
