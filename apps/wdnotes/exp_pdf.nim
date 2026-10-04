# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
#   _._
# o|- -|o  wdnotes - PDF export
#  ( l )   A dependency-free PDF writer with its own layout engine:
#    =     the 14 standard fonts (Helvetica, Times, Courier families),
#          WinAnsi encoding (French accents, œ, «», —, …), word wrapping,
#          justification, pagination, per-format page setup, headers and
#          footers with {page}/{pages}, tables with repeated header rows,
#          coloured frames, internal links between notes, URI links and
#          bookmarks (outline) for every note.

import std/[strutils, tables]
import std/unicode except strip, split, splitWhitespace, align, alignLeft, cmpIgnoreCase, reversed
import styles, render

const
  FontNames = ["Helvetica", "Helvetica-Bold", "Helvetica-Oblique", "Helvetica-BoldOblique",
               "Times-Roman", "Times-Bold", "Times-Italic", "Times-BoldItalic",
               "Courier", "Courier-Bold", "Courier-Oblique", "Courier-BoldOblique"]
  HelvW: array[32..126, int] = [
    278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, 278, 278,
    556, 556, 556, 556, 556, 556, 556, 556, 556, 556,
    278, 278, 584, 584, 584, 556, 1015,
    667, 667, 722, 722, 667, 611, 778, 722, 278, 500, 667, 556, 833, 722, 778, 667, 778,
    722, 667, 611, 722, 667, 944, 667, 667, 611,
    278, 278, 278, 469, 556, 333,
    556, 556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833, 556, 556, 556, 556,
    333, 500, 278, 556, 500, 722, 500, 500, 500,
    334, 260, 334, 584]
  MmToPt = 72.0 / 25.4

type
  OpKind = enum okText, okFill, okStroke, okLine
  POp = object
    kind: OpKind
    x, y, w, h: float            # y is measured from the top of the page (pt).
    text: string                 # WinAnsi bytes.
    font: int
    size, lw: float
    color: string

  PLink = object
    x, y, w, h: float
    target: string

  PPage = object
    setup: PageSetup
    under, over: seq[POp]
    links: seq[PLink]
    title: string

  Tok = object
    text: string
    w: float
    style: Style
    link: string
    space, newline: bool

  PLine = object
    toks: seq[Tok]
    width, height, maxSize: float
    last: bool

  Pdf = object
    doc: RenderDoc
    pages: seq[PPage]
    y: float
    starts: Table[string, (int, float)]
    outline: seq[(string, int, float, int)]

# encoding.

proc toWinAnsi*(s: string): string =
  for r in s.runes:
    let c = int(r)
    if c == 0x0A: result.add '\n'
    elif c < 0x20: discard
    elif c < 0x7F: result.add char(c)
    elif c in 0xA0..0xFF: result.add char(c)
    else:
      case c
      of 0x20AC: result.add '\x80'
      of 0x201A: result.add '\x82'
      of 0x0192: result.add '\x83'
      of 0x201E: result.add '\x84'
      of 0x2026: result.add '\x85'
      of 0x2020: result.add '\x86'
      of 0x2021: result.add '\x87'
      of 0x02C6: result.add '\x88'
      of 0x2030: result.add '\x89'
      of 0x0160: result.add '\x8A'
      of 0x2039: result.add '\x8B'
      of 0x0152: result.add '\x8C'
      of 0x017D: result.add '\x8E'
      of 0x2018: result.add '\x91'
      of 0x2019: result.add '\x92'
      of 0x201C: result.add '\x93'
      of 0x201D: result.add '\x94'
      of 0x2022, 0x25CF: result.add '\x95'
      of 0x2013: result.add '\x96'
      of 0x2014: result.add '\x97'
      of 0x02DC: result.add '\x98'
      of 0x2122: result.add '\x99'
      of 0x0161: result.add '\x9A'
      of 0x203A: result.add '\x9B'
      of 0x0153: result.add '\x9C'
      of 0x017E: result.add '\x9E'
      of 0x0178: result.add '\x9F'
      of 0x202F, 0x2009, 0x2007: result.add '\xA0'
      of 0x2610: result.add "[ ]"
      of 0x2611, 0x2612: result.add "[x]"
      of 0x25E6: result.add '-'
      of 0x2192: result.add "->"
      of 0x2190: result.add "<-"
      else: result.add '?'

proc charW(font: int, c: char): float =
  if font >= 8: return 600
  let o = ord(c)
  var w = 556.0
  if o in 32..126:
    w = float(HelvW[o])
  else:
    case o
    of 0x80, 0x95, 0x96: w = 556.0
    of 0x85, 0x97, 0x89, 0x8C: w = 1000.0
    of 0x91, 0x92, 0x82: w = 222.0
    of 0x93, 0x94, 0x84: w = 333.0
    of 0x9C: w = 944.0
    of 0xA0: w = 278.0
    of 0xB0: w = 400.0
    of 0xC0..0xDE: w = 700.0
    of 0xEC..0xEF: w = 278.0
    of 0xE7: w = 500.0
    else: w = 556.0
  if font in 4..7: w *= (if font in [5, 7]: 0.95 else: 0.9)
  elif font in [1, 3]: w *= 1.06
  w

proc textW(s: string, font: int, size: float): float =
  for c in s: result += charW(font, c)
  result * size / 1000

proc fontOf(s: Style): int =
  result = if isMonoFont(s.font): 8 elif isSansFont(s.font): 0 else: 4
  if s.bold: result += 1
  if s.italic: result += 2

proc rgb(hex: string): string =
  var h = hex.strip(chars = {'#'})
  if h.len != 6: h = "000000"
  try:
    let r = parseHexInt(h[0..1]) / 255
    let g = parseHexInt(h[2..3]) / 255
    let b = parseHexInt(h[4..5]) / 255
    formatFloat(r, ffDecimal, 3) & " " & formatFloat(g, ffDecimal, 3) & " " &
      formatFloat(b, ffDecimal, 3)
  except ValueError: "0 0 0"

proc pdfStr(s: string): string =
  result = "("
  for c in s:
    case c
    of '(', ')', '\\': result.add '\\'; result.add c
    of '\n': discard
    else: result.add c
  result.add ")"

proc utf16Hex(s: string): string =
  result = "<FEFF"
  for r in s.runes:
    var c = int(r)
    if c > 0xFFFF:
      c -= 0x10000
      result.add toHex(0xD800 + (c shr 10), 4) & toHex(0xDC00 + (c and 0x3FF), 4)
    else:
      result.add toHex(c, 4)
  result.add ">"

proc f2(v: float): string = formatFloat(v, ffDecimal, 2)

# pages

proc pw(p: Pdf): float = p.pages[^1].setup.width * MmToPt
proc ph(p: Pdf): float = p.pages[^1].setup.height * MmToPt
proc top(p: Pdf): float = p.pages[^1].setup.marginTop * MmToPt
proc bottom(p: Pdf): float = p.ph - p.pages[^1].setup.marginBottom * MmToPt
proc left(p: Pdf): float = p.pages[^1].setup.marginLeft * MmToPt
proc right(p: Pdf): float = p.pw - p.pages[^1].setup.marginRight * MmToPt

proc newPage(p: var Pdf, setup: PageSetup, title: string) =
  p.pages.add PPage(setup: setup, title: title)
  p.y = p.top

proc atTop(p: Pdf): bool = abs(p.y - p.top) < 0.5

proc sameSetup(a, b: PageSetup): bool =
  a.width == b.width and a.height == b.height and a.marginTop == b.marginTop and
    a.marginBottom == b.marginBottom and a.marginLeft == b.marginLeft and
    a.marginRight == b.marginRight and a.header == b.header and a.footer == b.footer and
    a.background == b.background

proc ensure(p: var Pdf, h: float) =
  if p.y + h > p.bottom and not p.atTop:
    let s = p.pages[^1].setup
    let t = p.pages[^1].title
    p.newPage(s, t)

# text layout

proc tokens(runs: seq[Run]): seq[Tok] =
  for r in runs:
    let f = fontOf(r.style)
    let enc = toWinAnsi(r.text)
    var word = ""
    template flushWord() =
      if word.len > 0:
        result.add Tok(text: word, w: textW(word, f, r.style.size), style: r.style, link: r.link)
        word = ""
    for c in enc:
      if c == '\n':
        flushWord()
        result.add Tok(newline: true, style: r.style)
      elif c == ' ':
        flushWord()
        result.add Tok(text: " ", w: textW(" ", f, r.style.size), style: r.style,
                       link: r.link, space: true)
      else: word.add c
    flushWord()

proc wrap(toks: seq[Tok], maxW: float, base: Style): seq[PLine] =
  var line = PLine()
  var x = 0.0
  proc finish(line: var PLine, x: var float, last: bool, res: var seq[PLine]) =
    while line.toks.len > 0 and line.toks[^1].space: line.toks.setLen(line.toks.len - 1)
    line.width = 0
    line.maxSize = 0
    for t in line.toks:
      line.width += t.w
      line.maxSize = max(line.maxSize, t.style.size)
    if line.maxSize == 0: line.maxSize = base.size
    line.height = line.maxSize * max(base.lineHeight, 1.0)
    line.last = last
    res.add line
    line = PLine()
    x = 0
  for t0 in toks:
    var t = t0
    if t.newline:
      finish(line, x, true, result); continue
    if t.space:
      if line.toks.len == 0: continue
      line.toks.add t; x += t.w; continue
    if x + t.w > maxW and line.toks.len > 0:
      finish(line, x, false, result)
    while t.w > maxW and t.text.len > 1:
      # word longer than the line: hard split.
      let f = fontOf(t.style)
      var cut = t.text.len - 1
      while cut > 1 and textW(t.text[0 ..< cut], f, t.style.size) > maxW - x: dec cut
      var head = t
      head.text = t.text[0 ..< cut]
      head.w = textW(head.text, f, t.style.size)
      line.toks.add head
      finish(line, x, false, result)
      t.text = t.text[cut .. ^1]
      t.w = textW(t.text, f, t.style.size)
    line.toks.add t
    x += t.w
  if line.toks.len > 0 or result.len == 0: finish(line, x, true, result)

proc drawLine(p: var Pdf, line: PLine, x0, availW: float, base: Style) =
  var x = x0
  var extra = 0.0
  case base.align
  of "center": x = x0 + (availW - line.width) / 2
  of "right": x = x0 + availW - line.width
  of "justify":
    if not line.last:
      var spaces = 0
      for t in line.toks:
        if t.space: inc spaces
      if spaces > 0 and line.width > availW * 0.6:
        extra = (availW - line.width) / float(spaces)
  else: discard
  let baseline = p.y + (line.height - line.maxSize) / 2 + line.maxSize * 0.8
  var pg = addr p.pages[^1]
  for t in line.toks:
    let w = t.w + (if t.space: extra else: 0)
    if not t.space:
      if t.style.bg.len > 0 and t.style.bg != base.bg:
        pg.under.add POp(kind: okFill, x: x - 1, y: baseline - t.style.size * 0.82,
                         w: t.w + 2, h: t.style.size * 1.08, color: t.style.bg)
      pg.over.add POp(kind: okText, x: x, y: baseline, text: t.text, font: fontOf(t.style),
                      size: t.style.size,
                      color: (if t.style.color.len > 0: t.style.color else: "#000000"))
    if t.style.underline:
      pg.over.add POp(kind: okLine, x: x, y: baseline + t.style.size * 0.12, w: w, h: 0,
                      lw: max(t.style.size / 18, 0.4), color: t.style.color)
    if t.style.strike:
      pg.over.add POp(kind: okLine, x: x, y: baseline - t.style.size * 0.3, w: w, h: 0,
                      lw: max(t.style.size / 18, 0.4), color: t.style.color)
    if t.link.len > 0:
      pg.links.add PLink(x: x, y: baseline - t.style.size * 0.85, w: w,
                         h: t.style.size * 1.1, target: t.link)
    x += w
  p.y += line.height

proc frameOps(p: var Pdf, st: Style, x0, x1, y0, y1: float, insertAt: int) =
  var ops: seq[POp]
  if st.bg.len > 0:
    ops.add POp(kind: okFill, x: x0, y: y0, w: x1 - x0, h: y1 - y0, color: st.bg)
  let bc = if st.border.len > 0: st.border else: "#cccccc"
  case st.frame
  of "left": ops.add POp(kind: okFill, x: x0, y: y0, w: 2.6, h: y1 - y0, color: bc)
  of "box": ops.add POp(kind: okStroke, x: x0, y: y0, w: x1 - x0, h: y1 - y0, lw: 0.8, color: bc)
  of "bottom": ops.add POp(kind: okLine, x: x0, y: y1, w: x1 - x0, h: 0, lw: 1.2, color: bc)
  of "top": ops.add POp(kind: okLine, x: x0, y: y0, w: x1 - x0, h: 0, lw: 1.2, color: bc)
  else: discard
  var k = min(insertAt, p.pages[^1].under.len)
  for op in ops:
    p.pages[^1].under.insert(op, k)
    inc k

proc flowLines(p: var Pdf, lines: seq[PLine], st: Style, marker: string) =
  ## places wrapped lines, with background / frame split across pages
  let framed = st.bg.len > 0 or st.frame.len > 0
  let pad = if framed: 5.0 else: 0.0
  let x0 = p.left + st.indent
  let x1 = p.right
  let tx = x0 + (if framed: pad + (if st.frame == "left": 4 else: 0) else: 0)
  let availW = x1 - pad - tx
  if lines.len > 0: p.ensure(lines[0].height + 2 * pad)
  var segStart = p.y
  var segIdx = p.pages[^1].under.len
  p.y += pad
  for i, line in lines:
    if p.y + line.height + pad > p.bottom and not (p.atTop):
      if framed: p.frameOps(st, x0, x1, segStart, p.y + pad, segIdx)
      p.newPage(p.pages[^1].setup, p.pages[^1].title)
      segStart = p.y
      segIdx = 0
      p.y += pad
    if i == 0 and marker.len > 0:
      let mk = toWinAnsi(marker)
      let f = fontOf(st)
      let mw = textW(mk, f, st.size)
      let baseline = p.y + (line.height - line.maxSize) / 2 + line.maxSize * 0.8
      p.pages[^1].over.add POp(kind: okText, x: tx - mw - 5, y: baseline, text: mk, font: f,
                               size: st.size, color: (if st.color.len > 0: st.color else: "#000000"))
    p.drawLine(line, tx, availW, st)
  p.y += pad
  if framed: p.frameOps(st, x0, x1, segStart, p.y, segIdx)

proc layoutTable(p: var Pdf, b: RBlock) =
  let st = b.style
  let x0 = p.left + st.indent
  let W = p.right - x0
  var cols = 0
  for r in b.rows: cols = max(cols, r.len)
  if cols == 0: return
  let pad = 4.0
  var nat = newSeq[float](cols)
  for r in b.rows:
    for k, cell in r:
      var w = 0.0
      for t in tokens(cell): w += t.w
      nat[k] = max(nat[k], min(w, W * 0.6) + 2 * pad)
  var total = 0.0
  for k in 0 ..< cols:
    nat[k] = max(nat[k], 36)
    total += nat[k]
  var widths = newSeq[float](cols)
  for k in 0 ..< cols: widths[k] = nat[k] * W / total
  let bc = if st.border.len > 0: st.border else: "#c8ccd2"
  proc rowLines(p: Pdf, row: seq[seq[Run]], isHead: bool): (seq[seq[PLine]], float) =
    var hmax = 0.0
    var res: seq[seq[PLine]]
    for k in 0 ..< cols:
      let cell = if k < row.len: row[k] else: newSeq[Run]()
      let cs = if isHead: b.thStyle else: b.tdStyle
      let ls = wrap(tokens(cell), widths[k] - 2 * pad, cs)
      var h = 0.0
      for l in ls: h += l.height
      hmax = max(hmax, h)
      res.add ls
    (res, hmax + 2 * pad)
  proc drawRow(p: var Pdf, row: seq[seq[Run]], isHead: bool) =
    let (cl, h) = rowLines(p, row, isHead)
    if p.y + h > p.bottom and not p.atTop:
      p.newPage(p.pages[^1].setup, p.pages[^1].title)
      if not isHead and b.rows.len > 0: drawRow(p, b.rows[0], true)
    let cs = if isHead: b.thStyle else: b.tdStyle
    var x = x0
    let y0 = p.y
    for k in 0 ..< cols:
      if cs.bg.len > 0:
        p.pages[^1].under.add POp(kind: okFill, x: x, y: y0, w: widths[k], h: h, color: cs.bg)
      p.pages[^1].over.add POp(kind: okStroke, x: x, y: y0, w: widths[k], h: h, lw: 0.6, color: bc)
      p.y = y0 + pad
      var cst = cs
      cst.align = if k < b.aligns.len: b.aligns[k] else: "left"
      for l in cl[k]: p.drawLine(l, x + pad, widths[k] - 2 * pad, cst)
      x += widths[k]
    p.y = y0 + h
  for r, row in b.rows: p.drawRow(row, r == 0)

proc layoutBlock(p: var Pdf, b: RBlock) =
  let st = b.style
  case b.kind
  of "pagebreak":
    if not p.atTop: p.newPage(p.pages[^1].setup, p.pages[^1].title)
    return
  of "hr":
    p.y += st.before
    p.ensure(4)
    p.pages[^1].over.add POp(kind: okLine, x: p.left + st.indent, y: p.y,
                             w: p.right - p.left - st.indent, h: 0, lw: 0.8,
                             color: (if st.border.len > 0: st.border else: "#bbbbbb"))
    p.y += st.after
    return
  else: discard
  if st.pageBreak and not p.atTop: p.newPage(p.pages[^1].setup, p.pages[^1].title)
  if not p.atTop: p.y += st.before
  case b.kind
  of "table":
    p.layoutTable(b)
  of "code":
    var lines: seq[PLine]
    let f = fontOf(st)
    let framed = true
    let maxW = p.right - p.left - st.indent - (if framed: 10 else: 0)
    for raw in plain(b.runs).split('\n'):
      let enc = toWinAnsi(raw)
      var rest = enc
      while true:
        var cut = rest.len
        while cut > 1 and textW(rest[0 ..< cut], f, st.size) > maxW: dec cut
        let piece = rest[0 ..< cut]
        lines.add PLine(toks: @[Tok(text: (if piece.len > 0: piece else: " "),
                                    w: textW(piece, f, st.size), style: st)],
                        width: textW(piece, f, st.size), height: st.size * st.lineHeight,
                        maxSize: st.size, last: true)
        if cut >= rest.len: break
        rest = rest[cut .. ^1]
    var cst = st
    cst.align = "left"
    if cst.frame.len == 0 and cst.bg.len == 0: cst.bg = "#f4f5f7"
    p.flowLines(lines, cst, "")
  else:
    let x0 = p.left + st.indent
    let framed = st.bg.len > 0 or st.frame.len > 0
    let availW = p.right - x0 - (if framed: 10.0 + (if st.frame == "left": 4 else: 0) else: 0)
    p.flowLines(wrap(tokens(b.runs), availW, st), st, b.marker)
  p.y += st.after

# document

proc layout(doc: RenderDoc): Pdf =
  result.doc = doc
  for s in doc.sections:
    if result.pages.len == 0:
      result.newPage(s.page, s.title)
    elif not sameSetup(result.pages[^1].setup, s.page):
      result.newPage(s.page, s.title)
    elif result.atTop:
      result.pages[^1].title = s.title
    let breakFirst = s.blocks.len > 0 and s.blocks[0].style.pageBreak and not result.atTop
    if breakFirst: result.newPage(s.page, s.title)
    result.starts[s.noteId] = (result.pages.high, result.y)
    result.outline.add (s.title, result.pages.high, result.y, s.depth)
    for b in s.blocks:
      if b.kind == "title" and result.atTop: result.pages[^1].title = s.title
      result.layoutBlock(b)
  if result.pages.len == 0:
    var ps = PageSetup(paper: "A4", width: 210, height: 297, marginTop: 25,
                       marginBottom: 22, marginLeft: 25, marginRight: 22)
    result.newPage(ps, doc.title)

proc headerFooter(p: var Pdf) =
  let total = p.pages.len
  for i in 0 ..< total:
    let s = p.pages[i].setup
    let w = s.width * MmToPt
    let h = s.height * MmToPt
    let x0 = s.marginLeft * MmToPt
    let x1 = w - s.marginRight * MmToPt
    for (txt, st, y) in [(s.header, s.headerStyle, s.marginTop * MmToPt * 0.5),
                         (s.footer, s.footerStyle, h - s.marginBottom * MmToPt * 0.42)]:
      if txt.len == 0: continue
      let t = toWinAnsi(fillPlaceholders(txt, p.doc.project, p.pages[i].title, i + 1, total,
                                         p.doc.date))
      let f = fontOf(st)
      let tw = textW(t, f, st.size)
      let x = case st.align
        of "center": (x0 + x1 - tw) / 2
        of "right": x1 - tw
        else: x0
      p.pages[i].over.add POp(kind: okText, x: x, y: y, text: t, font: f, size: st.size,
                              color: (if st.color.len > 0: st.color else: "#888888"))
      if st == s.headerStyle and y < h / 2:
        p.pages[i].over.add POp(kind: okLine, x: x0, y: y + st.size * 0.6, w: x1 - x0, h: 0,
                                lw: 0.4, color: "#dddddd")

proc contentStream(pg: PPage): string =
  let h = pg.setup.height * MmToPt
  if pg.setup.background.len > 0:
    result.add rgb(pg.setup.background) & " rg 0 0 " & f2(pg.setup.width * MmToPt) & " " &
      f2(h) & " re f\n"
  for list in [pg.under, pg.over]:
    for op in list:
      case op.kind
      of okFill:
        result.add rgb(op.color) & " rg " & f2(op.x) & " " & f2(h - op.y - op.h) & " " &
          f2(op.w) & " " & f2(op.h) & " re f\n"
      of okStroke:
        result.add rgb(op.color) & " RG " & f2(op.lw) & " w " & f2(op.x) & " " &
          f2(h - op.y - op.h) & " " & f2(op.w) & " " & f2(op.h) & " re S\n"
      of okLine:
        result.add rgb(op.color) & " RG " & f2(op.lw) & " w " & f2(op.x) & " " & f2(h - op.y) &
          " m " & f2(op.x + op.w) & " " & f2(h - op.y - op.h) & " l S\n"
      of okText:
        result.add "BT /F" & $(op.font + 1) & " " & f2(op.size) & " Tf " & rgb(op.color) &
          " rg " & f2(op.x) & " " & f2(h - op.y) & " Td " & pdfStr(op.text) & " Tj ET\n"

proc renderPdf*(doc: RenderDoc): string =
  var p = layout(doc)
  p.headerFooter()
  var objs: seq[string]
  proc newObj(objs: var seq[string]): int =
    objs.add ""
    objs.len
  let catalog = objs.newObj()
  let pagesRoot = objs.newObj()
  var fontIds: seq[int]
  for name in FontNames:
    let id = objs.newObj()
    objs[id - 1] = "<< /Type /Font /Subtype /Type1 /BaseFont /" & name &
      (if name.startsWith("Symbol"): "" else: " /Encoding /WinAnsiEncoding") & " >>"
    fontIds.add id
  var pageIds, contentIds: seq[int]
  for _ in p.pages:
    pageIds.add objs.newObj()
    contentIds.add objs.newObj()
  var fontRes = "<< "
  for k, id in fontIds: fontRes.add "/F" & $(k + 1) & " " & $id & " 0 R "
  fontRes.add ">>"
  proc dest(p: Pdf, pageIds: seq[int], page: int, y: float): string =
    let h = p.pages[page].setup.height * MmToPt
    "[" & $pageIds[page] & " 0 R /XYZ 0 " & f2(h - y + 12) & " 0]"
  for i, pg in p.pages:
    let stream = contentStream(pg)
    objs[contentIds[i] - 1] = "<< /Length " & $stream.len & " >>\nstream\n" & stream &
      "endstream"
    var annots: seq[int]
    let h = pg.setup.height * MmToPt
    for l in pg.links:
      var action = ""
      if l.target.startsWith("note:"):
        let id = l.target[5 .. ^1]
        if id in p.starts:
          let (pi, y) = p.starts[id]
          action = "/Dest " & p.dest(pageIds, pi, y)
      elif l.target.startsWith("missing:"): discard
      elif l.target.len > 0:
        action = "/A << /S /URI /URI " & pdfStr(toWinAnsi(l.target)) & " >>"
      if action.len == 0: continue
      let aid = objs.newObj()
      objs[aid - 1] = "<< /Type /Annot /Subtype /Link /Rect [" & f2(l.x) & " " &
        f2(h - l.y - l.h) & " " & f2(l.x + l.w) & " " & f2(h - l.y) & "] /Border [0 0 0] " &
        action & " >>"
      annots.add aid
    var annotStr = ""
    if annots.len > 0:
      annotStr = " /Annots ["
      for a in annots: annotStr.add $a & " 0 R "
      annotStr.add "]"
    objs[pageIds[i] - 1] = "<< /Type /Page /Parent " & $pagesRoot & " 0 R /MediaBox [0 0 " &
      f2(pg.setup.width * MmToPt) & " " & f2(h) & "] /Resources << /Font " & fontRes &
      " >> /Contents " & $contentIds[i] & " 0 R" & annotStr & " >>"
  var kids = ""
  for id in pageIds: kids.add $id & " 0 R "
  objs[pagesRoot - 1] = "<< /Type /Pages /Kids [" & kids & "] /Count " & $pageIds.len & " >>"
  # outline (flat, indented titles keep the hierarchy readable).
  var outlineRef = ""
  if p.outline.len > 0:
    let root = objs.newObj()
    var items: seq[int]
    for _ in p.outline: items.add objs.newObj()
    for k, entry in p.outline:
      let (title, page, y, depth) = entry
      var d = "<< /Title " & utf16Hex(repeat("  ", depth) & title) & " /Parent " & $root &
        " 0 R /Dest " & p.dest(pageIds, page, y)
      if k > 0: d.add " /Prev " & $items[k - 1] & " 0 R"
      if k < items.high: d.add " /Next " & $items[k + 1] & " 0 R"
      objs[items[k] - 1] = d & " >>"
    objs[root - 1] = "<< /Type /Outlines /First " & $items[0] & " 0 R /Last " & $items[^1] &
      " 0 R /Count " & $items.len & " >>"
    outlineRef = " /Outlines " & $root & " 0 R /PageMode /UseOutlines"
  objs[catalog - 1] = "<< /Type /Catalog /Pages " & $pagesRoot & " 0 R" & outlineRef & " >>"
  let info = objs.newObj()
  objs[info - 1] = "<< /Title " & utf16Hex(doc.title) & " /Subject " & utf16Hex(doc.project) &
    " /Producer (wdnotes - wdgui) /Creator (wdnotes) >>"
  # serialisation
  result = "%PDF-1.4\n%\xE2\xE3\xCF\xD3\n"
  var offsets: seq[int]
  for i, o in objs:
    offsets.add result.len
    result.add $(i + 1) & " 0 obj\n" & o & "\nendobj\n"
  let xref = result.len
  result.add "xref\n0 " & $(objs.len + 1) & "\n0000000000 65535 f \n"
  for off in offsets: result.add align($off, 10, '0') & " 00000 n \n"
  result.add "trailer\n<< /Size " & $(objs.len + 1) & " /Root " & $catalog & " 0 R /Info " &
    $info & " 0 R >>\nstartxref\n" & $xref & "\n%%EOF\n"

proc exportPdf*(doc: RenderDoc, path: string) =
  writeFile(path, renderPdf(doc))
