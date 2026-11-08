# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
#   wdgui - mise en page : Markdown enrichi -> pages (scènes vectorielles vscene).
#
# The generated pages are used for the preview (canvas), SVG export, and PDF (vpdf): a single
# engine, ensuring the preview is an accurate representation of the published document.
#
# * Typography: body text (Lora by default), headings (Poppins), code (DejaVu Sans Mono); baselines
#   aligned according to font metrics; optional justification;
#   widows and orphans (at least two lines on either side of a page break); a heading
#   is never left alone at the bottom of a page.
# * Blocks: numbered or unnumbered headings, paragraphs, nested lists and checkboxes,
#   quotations, callout boxes (note, tip, caution, important, danger), code (background, language),
#   tables (repeated headers, adjusted columns, multi-line cells, striped rows), figures
#   (PNG, JPEG, BMP, SVG; numbered captions), horizontal rules, table of contents [[toc]], index [[index]],
#   page breaks [[saut]], cross-references [[ref:anchor]] (e.g., "p. 12"), and index entries [[i:term]].
# * Template: format, margins, colors, header and footer (“left|center|right” with
#   {title}, {chapter}, {page}, {pages}), cover, chapters starting on an odd-numbered or new page.
# * Two passes: the first locates the pages for titles, anchors, and terms; the second
#   writes the table of contents, the index, and the cross-references with the correct page numbers.
# * The forms carry their role within `data` (role=H1, P, LI, TD, Figure, Code, etc.), along with
#   links (link=#anchor or address) and replacement text—resulting in tagged PDF and active links.

import std/[strutils, tables, math, os, algorithm, unicode]
import vscene, mdparse

type
  LStyle* = object
    pageW*, pageH*: float
    mTop*, mBottom*, mLeft*, mRight*: float
    bodyFont*, headFont*, monoFont*: string
    bodySize*, lineH*, paraGap*: float
    hSize*: array[1 .. 4, float]
    textCol*, headCol*, accent*, muted*, codeBg*, ruleCol*, tableHead*, zebra*: string
    justify*, numbering*, h1NewPage*, mirror*, cover*, tocNumbers*: bool
    header*, footer*: string
    title*, subtitle*, author*, date*: string
    tocTitle*, indexTitle*, figureLabel*, tableLabel*: string
    base*: string

  LHeading* = object
    level*: int
    text*, id*, number*: string
    page*: int
    y*: float

  LResult* = object
    pages*: seq[VScene]
    headings*: seq[LHeading]
    anchors*: Table[string, tuple[page: int, y: float]]
    index*: seq[tuple[term: string, pages: seq[int]]]
    style*: LStyle

  Word = object
    text: string
    bold, italic, code, strike: bool
    link: string
    w: float
    space: bool           # une espace suit
    kind: SegKind
    marks: seq[string]    # entrées d'index posées sur ce mot

  Line = object
    words: seq[Word]
    width: float
    last: bool            # dernière ligne du paragraphe (pas de justification)

  Ctx = object
    st: LStyle
    pages: seq[VScene]
    chapters: seq[string]
    y, x0, x1, bottom: float
    keepNext: float                    # hauteur du bloc qui doit suivre un titre (figure)
    headings: seq[LHeading]
    anchors: Table[string, tuple[page: int, y: float]]
    terms: Table[string, seq[int]]
    termLabel: Table[string, string]
    prev: LResult         # résultats de la passe précédente
    figNo, tabNo: int
    counters: array[1 .. 6, int]
    chapter: string
    allHeads: seq[MdBlk]
    blockNo: int          # bloc logique courant (balisage du PDF)

proc defaultStyle*(): LStyle =
  LStyle(pageW: 595.28, pageH: 841.89, mTop: 72, mBottom: 68, mLeft: 66, mRight: 66,
         bodyFont: "Lora", headFont: "Poppins", monoFont: "Mono", bodySize: 10.5, lineH: 1.5, paraGap: 7,
         hSize: [24.0, 16.5, 13.0, 11.0],
         textCol: "#1f2937", headCol: "#0f172a", accent: "#4f46e5", muted: "#64748b", codeBg: "#f4f6fa",
         ruleCol: "#e2e8f0", tableHead: "#eef2ff", zebra: "#f8fafc",
         justify: true, numbering: false, h1NewPage: false, tocNumbers: true,
         header: "{titre}||{chapitre}", footer: "||{page} / {pages}",
         tocTitle: "Sommaire", indexTitle: "Index", figureLabel: "Figure", tableLabel: "Tableau")

#
# forms
#

proc page(c: var Ctx): VScene = c.pages[^1]

proc add(c: var Ctx, s: VShape) =
  s.layer = "Calque 1"
  c.page.shapes.add s

proc textShape(font: string, size: float, bold, italic: bool, col, text: string, x, baseline: float): VShape =
  result = newShape(vkText)
  result.text = text
  result.font = font
  result.fontSize = size
  result.bold = bold
  result.italic = italic
  result.fill = col
  result.lineHeight = 1.0
  let fm = fontMetrics(font, size, bold, italic)
  result.x = x
  result.y = baseline - (size - fm.height) / 2 - fm.ascent
  result.w = -measureText(font, size, bold, italic, text)
  result.h = size

proc rectShape(x, y, w, h: float, fill: string, rx = 0.0, stroke = "none", sw = 0.0): VShape =
  result = newShape(vkRect)
  result.x = x; result.y = y; result.w = w; result.h = h
  result.fill = fill
  result.rx = rx
  result.stroke = stroke
  result.strokeWidth = sw

proc lineShape(x1, y1, x2, y2: float, col: string, width: float, dash = ""): VShape =
  result = newShape(vkLine)
  result.subs = @[VSub(pts: @[VPt(x: x1, y: y1), VPt(x: x2, y: y2)])]
  result.fill = "none"
  result.stroke = col
  result.strokeWidth = width
  result.dash = dash
  result.syncPathBox

proc contentW(c: Ctx): float = c.x1 - c.x0

proc newPage(c: var Ctx) =
  let sc = newScene(c.st.pageW, c.st.pageH)
  sc.background = "#ffffff"
  sc.base = c.st.base
  c.pages.add sc
  c.chapters.add c.chapter
  c.y = c.st.mTop
  let even = c.pages.len mod 2 == 0
  if c.st.mirror and even:
    c.x0 = c.st.mRight
    c.x1 = c.st.pageW - c.st.mLeft
  else:
    c.x0 = c.st.mLeft
    c.x1 = c.st.pageW - c.st.mRight
  c.bottom = c.st.pageH - c.st.mBottom

proc atTop(c: Ctx): bool = c.y <= c.st.mTop + 0.5

proc ensure(c: var Ctx, h: float) =
  if c.y + h > c.bottom and not c.atTop: c.newPage

proc pageNo(c: Ctx): int = c.pages.len    # numéro (1..)

#
# text
#

proc fontOf(c: Ctx, w: Word, baseFont: string, size: float): tuple[font: string, size: float] =
  if w.code: (c.st.monoFont, size * 0.86) else: (baseFont, size)

proc wordsOf(c: var Ctx, src: string, baseFont: string, size: float, bold0 = false, italic0 = false): seq[Word] =
  # Segments -> words (a word may combine several styles, joined together: “**bold**,”).
  for sg in parseInline(src):
    case sg.kind
    of skBreak:
      result.add Word(kind: skBreak)
    of skIndex:
      if result.len > 0 and result[^1].kind == skText: result[^1].marks.add sg.text
      else: result.add Word(kind: skIndex, text: sg.text)
    of skRef:
      let target = sg.text
      var label = "p. ?"
      if c.prev.anchors.hasKey(target): label = "p. " & $(c.prev.anchors[target].page)
      result.add Word(kind: skRef, text: label, link: "#" & target, w: measureText(baseFont, size, bold0, italic0, label))
    of skText:
      var t = sg.text
      var i = 0
      var cur = ""
      template flushWord(sp: bool) =
        if cur.len > 0:
          var w = Word(kind: skText, text: cur, bold: sg.bold or bold0, italic: sg.italic or italic0, code: sg.code,
                       strike: sg.strike, link: sg.link, space: sp)
          let f = c.fontOf(w, baseFont, size)
          w.w = measureText(f.font, f.size, w.bold, w.italic, cur)
          result.add w
          cur = ""
        elif sp and result.len > 0:
          result[^1].space = true
      if t.len > 0 and t[0] == ' ' and result.len > 0: result[^1].space = true
      while i < t.len:
        if t[i] == ' ':
          flushWord(true)
        else: cur.add t[i]
        inc i
      flushWord(false)

proc spaceW(font: string, size: float): float = measureText(font, size, false, false, "a a") - measureText(font, size, false, false, "aa")

proc breakLines(words: seq[Word], width, sp: float): seq[Line] =
  # Greedy break at spaces (words joined together form an unbreakable block).
  var boxes: seq[seq[Word]]
  var cur: seq[Word]
  for w in words:
    if w.kind == skBreak:
      if cur.len > 0: boxes.add cur
      boxes.add @[w]
      cur = @[]
      continue
    cur.add w
    if w.space:
      boxes.add cur
      cur = @[]
  if cur.len > 0: boxes.add cur
  var line = Line()
  var lw = 0.0
  for b in boxes:
    if b.len == 1 and b[0].kind == skBreak:
      line.last = true
      result.add line
      line = Line()
      lw = 0
      continue
    var bw = 0.0
    for w in b: bw += w.w
    let gap = if line.words.len > 0: sp else: 0.0
    if line.words.len > 0 and lw + gap + bw > width:
      line.width = lw
      result.add line
      line = Line()
      lw = 0
    lw += (if line.words.len > 0: sp else: 0.0) + bw
    for w in b: line.words.add w
  if line.words.len > 0 or result.len == 0:
    line.width = lw
    line.last = true
    result.add line

proc indexTerm(c: var Ctx, term: string) =
  let key = sortKey(term)
  if not c.terms.hasKey(key):
    c.terms[key] = @[]
    c.termLabel[key] = term
  if c.pageNo notin c.terms[key]: c.terms[key].add c.pageNo

proc emitLine(c: var Ctx, ln: Line, x, width, baseline: float, font: string, size: float, col: string,
              role: string, justify: bool, align = 'l') =
  let sp = spaceW(font, size)
  var gaps = 0
  for i, w in ln.words:
    if w.space and i < ln.words.high: inc gaps
  var extra = 0.0
  if justify and not ln.last and gaps > 0:
    extra = (width - ln.width) / gaps.float
    if extra > sp * 2.2: extra = 0
  var cx = x
  if align == 'c': cx = x + (width - ln.width) / 2
  elif align == 'r': cx = x + width - ln.width
  var i = 0
  while i < ln.words.len:
    let w = ln.words[i]
    if w.kind == skIndex:
      c.indexTerm(w.text)
      inc i
      continue
    # groups words of the same style (without justification) into a single form
    for mk in w.marks: c.indexTerm(mk)
    var text = w.text
    var ww = w.w
    var j = i
    while not (extra > 0) and j + 1 < ln.words.len:
      let n = ln.words[j + 1]
      if n.kind notin {skText, skRef} or n.bold != w.bold or n.italic != w.italic or n.code != w.code or
         n.link != w.link or n.strike != w.strike: break
      if ln.words[j].space:
        text.add ' '
        ww += sp
      text.add n.text
      ww += n.w
      for mk in n.marks: c.indexTerm(mk)
      inc j
    let f = c.fontOf(w, font, size)
    var colr = if w.link.len > 0: c.st.accent elif w.code: "#be185d" else: col
    if w.code:
      let fm = fontMetrics(f.font, f.size, false, false)
      let bg = rectShape(cx - 2, baseline - fm.ascent - 1, ww + 4, fm.height + 2, c.st.codeBg, 3)
      bg.data = "role=Artifact"
      c.add bg
    let s = textShape(f.font, f.size, w.bold, w.italic, colr, text, cx, baseline)
    var data = "role=" & role & ";b=" & $c.blockNo
    if w.link.len > 0: data.add ";lien=" & w.link
    s.data = data
    c.add s
    if w.link.len > 0 and not w.link.startsWith("#"):
      let u = lineShape(cx, baseline + size * 0.14, cx + ww, baseline + size * 0.14, c.st.accent, max(0.4, size * 0.05))
      u.opacity = 0.55
      u.data = "role=Artifact"
      c.add u
    if w.strike:
      let u = lineShape(cx, baseline - size * 0.3, cx + ww, baseline - size * 0.3, colr, max(0.4, size * 0.06))
      u.data = "role=Artifact"
      c.add u
    cx += ww
    if ln.words[j].space: cx += sp + extra
    i = j + 1

proc lineMetrics(c: Ctx, font: string, size, lh: float): tuple[step, base: float] =
  let fm = fontMetrics(font, size, false, false)
  let step = size * lh
  (step, (step - fm.height) / 2 + fm.ascent)

proc flowText(c: var Ctx, src: string, x, width: float, font: string, size, lh: float, col, role: string,
              bold = false, italic = false, justify = false, align = 'l',
              before: proc (c: var Ctx, y, h: float) = nil) =
  # Paragraph: line breaking, followed by placement with handling of widows and orphans.
  # `before` is called for each placed line (e.g., for the background of a box or a rule for a quotation).
  inc c.blockNo
  let words = c.wordsOf(src, font, size, bold, italic)
  let lines = breakLines(words, width, spaceW(font, size))
  let m = c.lineMetrics(font, size, lh)
  var k = 0
  while k < lines.len:
    let room = int(floor((c.bottom - c.y) / m.step + 1e-6))
    let left = lines.len - k
    var n = left
    if left > room:
      if room < 2 or (left <= 3 and k == 0) :
        if not c.atTop:
          c.newPage
          continue
        n = max(1, room)
      else:
        n = min(room, left - 2)
        if n < 2: n = room
    for q in 0 ..< n:
      if before != nil: before(c, c.y, m.step)
      c.emitLine(lines[k + q], x, width, c.y + m.base, font, size, col, role, justify, align)
      c.y += m.step
    k += n
    if k < lines.len: c.newPage

#
# blocks
#

proc headingText(c: var Ctx, b: MdBlk): string =
  result = plainText(b.text)
  if c.st.numbering and b.level <= 3:
    inc c.counters[b.level]
    for l in b.level + 1 .. 6: c.counters[l] = 0
    var num = ""
    for l in 1 .. b.level: num.add $c.counters[l] & "."
    if b.level > 1: num = num[0 ..< ^1]
    result = num & "  " & result

proc layoutBlocks(c: var Ctx, blocks: seq[MdBlk], x, width: float, depth = 0)

proc doHeading(c: var Ctx, b: MdBlk) =
  let lvl = min(b.level, 4)
  let size = c.st.hSize[lvl]
  let txt = c.headingText(b)
  if b.level == 1:
    c.chapter = plainText(b.text)
    if c.st.h1NewPage and not c.atTop: c.newPage
    if c.atTop and c.pages.len > 0: c.chapters[^1] = c.chapter
  let before = if c.atTop: 0.0 else: size * (if lvl <= 2: 1.15 else: 0.9)
  let m = c.lineMetrics(c.st.headFont, size, 1.22)
  let bodyStep = c.st.bodySize * c.st.lineH
  let words = c.wordsOf(txt, c.st.headFont, size, true)
  let lines = breakLines(words, c.contentW, spaceW(c.st.headFont, size))
  c.ensure(before + lines.len.float * m.step + max(2 * bodyStep, c.keepNext) + size * 0.5)
  c.keepNext = 0
  if not c.atTop: c.y += before
  if c.atTop and c.pages.len > 0: c.chapters[^1] = c.chapter
  inc c.blockNo
  let id = if b.id.len > 0: b.id else: slugify(plainText(b.text))
  c.headings.add LHeading(level: b.level, text: txt, id: id, page: c.pageNo, y: c.y)
  if not c.anchors.hasKey(id): c.anchors[id] = (c.pageNo, c.y)
  let col = if lvl >= 3 and lvl == 4: c.st.muted else: c.st.headCol
  for ln in lines:
    c.emitLine(ln, c.x0, c.contentW, c.y + m.base, c.st.headFont, size, col, "H" & $min(b.level, 6), false)
    c.y += m.step
  if b.level == 1:
    let bar = rectShape(c.x0, c.y + 3, 36, 3, c.st.accent, 1.5)
    bar.data = "role=Artifact"
    c.add bar
    c.y += 10
  c.y += size * 0.42

proc doPara(c: var Ctx, b: MdBlk, x, width: float, role = "P", italic = false, col = "", before: proc (c: var Ctx, y, h: float) = nil) =
  c.flowText(b.text, x, width, c.st.bodyFont, c.st.bodySize, c.st.lineH, (if col.len > 0: col else: c.st.textCol),
             role, false, italic, c.st.justify, 'l', before)
  c.y += c.st.paraGap

proc doList(c: var Ctx, b: MdBlk, x, width: float) =
  var counters: array[0 .. 9, int]
  var kinds: array[0 .. 9, int]
  let size = c.st.bodySize
  for it in b.items:
    let lvl = min(it.level, 9)
    for l in lvl + 1 .. 9:
      counters[l] = 0
      kinds[l] = 0
    let k = if it.ordered: 2 else: 1
    if kinds[lvl] != k:
      counters[lvl] = 0
      kinds[lvl] = k
      if it.ordered:
        try: counters[lvl] = parseInt(it.marker[0 ..< ^1]) - 1
        except ValueError: discard
    inc counters[lvl]
    let ind = x + lvl.float * 16
    let markW = if it.ordered: 18.0 else: 13.0
    let m = c.lineMetrics(c.st.bodyFont, size, c.st.lineH)
    c.ensure(m.step * 2)
    let y0 = c.y
    let startPage = c.pages.len
    c.flowText(it.text, ind + markW, width - (ind - x) - markW, c.st.bodyFont, size, c.st.lineH, c.st.textCol,
               "LI", false, false, false)
    # mark on the first line
    let pg = c.pages[startPage - 1]
    let base = y0 + m.base
    var mk: VShape
    if it.task >= 0:
      let bx = rectShape(ind, base - size * 0.72, size * 0.78, size * 0.78, (if it.task == 1: c.st.accent else: "none"),
                         2, c.st.accent, 0.9)
      bx.layer = "Calque 1"
      bx.data = "role=Artifact"
      pg.shapes.add bx
      if it.task == 1:
        let ck = newShape(vkPath)
        let s0 = size * 0.78
        let ox = ind
        let oy = base - size * 0.72
        ck.subs = @[VSub(pts: @[VPt(x: ox + s0 * 0.22, y: oy + s0 * 0.52), VPt(x: ox + s0 * 0.42, y: oy + s0 * 0.72),
                               VPt(x: ox + s0 * 0.8, y: oy + s0 * 0.28)])]
        ck.fill = "none"
        ck.stroke = "#ffffff"
        ck.strokeWidth = 1.3
        ck.syncPathBox
        ck.layer = "Calque 1"
        ck.data = "role=Artifact"
        pg.shapes.add ck
      continue
    if it.ordered:
      let lbl = $counters[lvl] & "."
      mk = textShape(c.st.headFont, size * 0.9, true, false, c.st.accent, lbl, ind, base)
    else:
      let d = size * (if lvl == 0: 0.36 else: 0.32)
      let dot = newShape(if lvl mod 3 == 2: vkRect else: vkEllipse)
      dot.x = ind + 1.5; dot.y = base - size * 0.29 - d / 2; dot.w = d; dot.h = d
      if lvl mod 3 == 1:
        dot.fill = "none"
        dot.stroke = c.st.accent
        dot.strokeWidth = 0.8
      else:
        dot.fill = (if lvl == 0: c.st.accent else: c.st.muted)
      mk = dot
    mk.layer = "Calque 1"
    mk.data = "role=Lbl"
    pg.shapes.add mk
    c.y += 1.5
  c.y += c.st.paraGap

proc doQuote(c: var Ctx, b: MdBlk, x, width: float) =
  let accent = c.st.accent
  let bar = proc (cc: var Ctx, y, h: float) =
    let r = rectShape(x, y, 2.6, h, accent)
    r.opacity = 0.45
    r.data = "role=Artifact"
    cc.add r
  for ch in b.children:
    if ch.kind == bkPara:
      c.flowText(ch.text, x + 14, width - 14, c.st.bodyFont, c.st.bodySize * 1.03, c.st.lineH, c.st.muted,
                 "BlockQuote", false, true, false, 'l', bar)
      c.y += c.st.paraGap
    else:
      c.layoutBlocks(@[ch], x + 14, width - 14, 1)

proc calloutColors(kind: string): tuple[bar, bg, title: string, label: string] =
  case kind
  of "tip": ("#10b981", "#ecfdf5", "#047857", "Astuce")
  of "warning": ("#f59e0b", "#fffbeb", "#b45309", "Attention")
  of "important": ("#8b5cf6", "#f5f3ff", "#6d28d9", "Important")
  of "danger": ("#ef4444", "#fef2f2", "#b91c1c", "Danger")
  else: ("#3b82f6", "#eff6ff", "#1d4ed8", "Remarque")

proc doCallout(c: var Ctx, b: MdBlk, x, width: float) =
  let cc = calloutColors(b.lang)
  let fillBox = proc (k: var Ctx, y, h: float) =
    let r = rectShape(x, y - 0.4, width, h + 0.8, cc.bg)
    r.data = "role=Artifact"
    k.add r
    let br = rectShape(x, y - 0.4, 3, h + 0.8, cc.bar)
    br.data = "role=Artifact"
    k.add br
  let pad = 9.0
  c.ensure(c.st.bodySize * c.st.lineH * 3)
  fillBox(c, c.y, pad)
  c.y += pad
  let title = if b.title.len > 0: b.title else: cc.label
  c.flowText("**" & title & "**", x + 16, width - 28, c.st.headFont, c.st.bodySize * 0.92, 1.5, cc.title, "Caption",
             false, false, false, 'l', fillBox)
  for ch in b.children:
    case ch.kind
    of bkPara:
      c.flowText(ch.text, x + 16, width - 28, c.st.bodyFont, c.st.bodySize, c.st.lineH, c.st.textCol, "P",
                 false, false, false, 'l', fillBox)
    of bkList:
      for it in ch.items:
        c.flowText("–  " & it.text, x + 16 + it.level.float * 14, width - 28 - it.level.float * 14, c.st.bodyFont,
                   c.st.bodySize, c.st.lineH, c.st.textCol, "LI", false, false, false, 'l', fillBox)
    else:
      c.flowText(plainText(ch.text), x + 16, width - 28, c.st.bodyFont, c.st.bodySize, c.st.lineH, c.st.textCol, "P",
                 false, false, false, 'l', fillBox)
  fillBox(c, c.y, pad)
  c.y += pad + c.st.paraGap + 2

proc doCode(c: var Ctx, b: MdBlk, x, width: float) =
  let size = c.st.bodySize * 0.84
  let lh = size * 1.48
  let fm = fontMetrics(c.st.monoFont, size, false, false)
  let pad = 9.0
  let cw = measureText(c.st.monoFont, size, false, false, "0000000000") / 10
  let maxChars = max(10, int((width - 2 * pad) / max(cw, 0.1)))
  var lines: seq[string]
  for l in b.lines:
    var r = l
    if r.runeLen <= maxChars: lines.add r
    else:
      while r.runeLen > maxChars:
        lines.add r.runeSubStr(0, maxChars)
        r = "  " & r.runeSubStr(maxChars)
      lines.add r
  if lines.len == 0: lines.add ""
  var k = 0
  while k < lines.len:
    let room = int(floor((c.bottom - c.y - 2 * pad) / lh))
    var n = min(room, lines.len - k)
    if n < min(3, lines.len - k) and not c.atTop:
      c.newPage
      continue
    n = max(1, n)
    let h = n.float * lh + 2 * pad
    let bg = rectShape(x, c.y, width, h, c.st.codeBg, 6, "#e5e7eb", 0.6)
    bg.data = "role=Artifact"
    c.add bg
    if k == 0 and b.lang.len > 0:
      let lab = textShape(c.st.headFont, size * 0.78, true, false, c.st.muted, b.lang.toUpperAscii, 0, c.y + pad + size * 0.6)
      lab.x = x + width - pad - abs(lab.w)
      lab.data = "role=Artifact"
      c.add lab
    var y = c.y + pad
    for q in 0 ..< n:
      let t = lines[k + q]
      if t.len > 0:
        var col = "#1e293b"
        let ts = t.strip
        if ts.startsWith("#") or ts.startsWith("//") or ts.startsWith("--") or ts.startsWith(";"): col = "#64748b"
        let s = textShape(c.st.monoFont, size, false, false, col, t, x + pad, y + (lh - fm.height) / 2 + fm.ascent)
        s.data = "role=Code"
        c.add s
      y += lh
    c.y += h
    k += n
    if k < lines.len: c.newPage
  c.y += c.st.paraGap + 2

proc imageSize(c: Ctx, path: string): tuple[w, h: float] =
  if path.toLowerAscii.endsWith(".svg"):
    let sc = loadSvgScene(path)
    if sc != nil: return (sc.width, sc.height)
    return (0.0, 0.0)
  let img = loadRgba(path)
  (img.w.float * 0.75, img.h.float * 0.75)

proc resolve(c: Ctx, src: string): string =
  if src.startsWith("data:") or src.isAbsolute or src.contains("://"): src
  elif c.st.base.len > 0: c.st.base / src
  else: src

proc figureSize(c: Ctx, b: MdBlk, width: float): tuple[w, h, capH: float] =
  # Dimensions of a figure (adjusted image, height of the caption).
  let path = c.resolve(b.src)
  var (iw, ih) = c.imageSize(path)
  if iw <= 0 or ih <= 0:
    iw = width
    ih = width * 0.4
  var maxW = width
  if b.width.endsWith("%"):
    try: maxW = width * clamp(parseFloat(b.width[0 ..< ^1]) / 100, 0.05, 1)
    except ValueError: discard
  elif b.width.len > 0:
    try: maxW = min(width, parseFloat(b.width))
    except ValueError: discard
  let maxH = (c.st.pageH - c.st.mTop - c.st.mBottom) * 0.62
  var w = min(maxW, iw)
  if b.width.len > 0: w = maxW
  var h = w * ih / iw
  if h > maxH:
    h = maxH
    w = h * iw / ih
  let caption = if b.title.len > 0: b.title else: b.alt
  result = (w, h, (if caption.len > 0: c.st.bodySize * 2.4 else: 0.0))

proc doFigure(c: var Ctx, b: MdBlk, x, width: float) =
  let path = c.resolve(b.src)
  let (w, h, capH) = c.figureSize(b, width)
  let caption = if b.title.len > 0: b.title else: b.alt
  c.ensure(h + capH + 8)
  c.y += 4
  let img = newShape(vkImage)
  img.href = path
  img.x = x + (width - w) / 2
  img.y = c.y
  img.w = w
  img.h = h
  img.fill = "none"
  img.data = "role=Figure;alt=" & b.alt.replace(";", ",")
  c.add img
  c.y += h + 6
  if caption.len > 0:
    inc c.figNo
    let txt = "*" & c.st.figureLabel & " " & $c.figNo & "* — " & caption
    c.flowText(txt, x + width * 0.1, width * 0.8, c.st.bodyFont, c.st.bodySize * 0.86, 1.4, c.st.muted, "Caption",
               false, false, false, 'c')
  c.y += c.st.paraGap + 2

proc doTable(c: var Ctx, b: MdBlk, x, width: float) =
  let size = c.st.bodySize * 0.9
  let lh = 1.38
  let padX = 7.0
  let padY = 5.0
  let n = b.rows[0].len
  if n == 0: return
  # largeurs : naturelle (une ligne) et minimale (le mot le plus long)
  var nat = newSeq[float](n)
  var mini = newSeq[float](n)
  for r, row in b.rows:
    for j, cell in row:
      let bold = r == 0
      let font = if r == 0: c.st.headFont else: c.st.bodyFont
      let sz = if r == 0: size * 0.92 else: size
      let t = plainText(cell)
      nat[j] = max(nat[j], measureText(font, sz, bold, false, t) + 2 * padX)
      for wd in t.split(' '):
        mini[j] = max(mini[j], measureText(font, sz, bold, false, wd) + 2 * padX)
  var widths = nat
  var total = 0.0
  for v in nat: total += v
  if total > width:
    var minTot = 0.0
    for v in mini: minTot += v
    if minTot >= width:
      for j in 0 ..< n: widths[j] = width * mini[j] / minTot
    else:
      let extra = width - minTot
      let flex = total - minTot
      for j in 0 ..< n: widths[j] = mini[j] + (if flex > 0: extra * (nat[j] - mini[j]) / flex else: 0)
  else:
    # table stretched to the width of the text (proportional columns)
    for j in 0 ..< n: widths[j] = nat[j] * width / total
  var tw = 0.0
  for v in widths: tw += v
  let tx = x + (width - tw) / 2
  proc rowHeight(c: var Ctx, row: seq[string], header: bool): float =
    var h = 0.0
    for j, cell in row:
      let font = if header: c.st.headFont else: c.st.bodyFont
      let sz = if header: size * 0.92 else: size
      let words = c.wordsOf(cell, font, sz, header)
      let lines = breakLines(words, widths[j] - 2 * padX, spaceW(font, sz))
      h = max(h, lines.len.float * sz * lh)
    h + 2 * padY
  proc drawRow(c: var Ctx, row: seq[string], header: bool, zebra: bool, h: float) =
    if header:
      let bg = rectShape(tx, c.y, tw, h, c.st.tableHead)
      bg.data = "role=Artifact"
      c.add bg
    elif zebra:
      let bg = rectShape(tx, c.y, tw, h, c.st.zebra)
      bg.data = "role=Artifact"
      c.add bg
    var cx = tx
    for j, cell in row:
      let font = if header: c.st.headFont else: c.st.bodyFont
      let sz = if header: size * 0.92 else: size
      let words = c.wordsOf(cell, font, sz, header)
      let lines = breakLines(words, widths[j] - 2 * padX, spaceW(font, sz))
      let m = c.lineMetrics(font, sz, lh)
      inc c.blockNo
      var y = c.y + padY
      for ln in lines:
        c.emitLine(ln, cx + padX, widths[j] - 2 * padX, y + m.base, font, sz,
                   (if header: c.st.headCol else: c.st.textCol), (if header: "TH" else: "TD"), false, b.aligns[j])
        y += m.step
      cx += widths[j]
    let rl = lineShape(tx, c.y + h, tx + tw, c.y + h, (if header: c.st.accent else: c.st.ruleCol), (if header: 1.0 else: 0.6))
    rl.data = "role=Artifact"
    c.add rl
    c.y += h
  let headH = c.rowHeight(b.rows[0], true)
  var first = true
  c.ensure(headH + c.rowHeight(if b.rows.len > 1: b.rows[1] else: b.rows[0], false) + 4)
  let top = lineShape(tx, c.y, tx + tw, c.y, c.st.accent, 1.0)
  top.data = "role=Artifact"
  c.add top
  c.drawRow(b.rows[0], true, false, headH)
  for r in 1 ..< b.rows.len:
    let h = c.rowHeight(b.rows[r], false)
    if c.y + h > c.bottom:
      c.newPage
      c.drawRow(b.rows[0], true, false, headH)
    c.drawRow(b.rows[r], false, r mod 2 == 0, h)
    first = false
  c.y += c.st.paraGap + 6

proc doRule(c: var Ctx, x, width: float) =
  c.ensure(18)
  c.y += 8
  let l = lineShape(x + width * 0.3, c.y, x + width * 0.7, c.y, c.st.ruleCol, 1)
  l.data = "role=Artifact"
  c.add l
  c.y += 10

proc doToc(c: var Ctx) =
  if not c.atTop: c.newPage
  let size = c.st.hSize[1]
  let m = c.lineMetrics(c.st.headFont, size, 1.2)
  let t = textShape(c.st.headFont, size, true, false, c.st.headCol, c.st.tocTitle, c.x0, c.y + m.base)
  t.data = "role=H1"
  c.add t
  c.y += m.step
  let bar = rectShape(c.x0, c.y + 3, 36, 3, c.st.accent, 1.5)
  bar.data = "role=Artifact"
  c.add bar
  c.y += 22
  var counters: array[1 .. 6, int]
  for h in c.allHeads:
    if h.level > 3: continue
    var label = plainText(h.text)
    if c.st.numbering:
      inc counters[h.level]
      for l in h.level + 1 .. 6: counters[l] = 0
      var num = ""
      for l in 1 .. h.level: num.add $counters[l] & "."
      if h.level > 1: num = num[0 ..< ^1]
      label = num & "  " & label
    let id = if h.id.len > 0: h.id else: slugify(plainText(h.text))
    var pg = "?"
    if c.prev.anchors.hasKey(id): pg = $c.prev.anchors[id].page
    let lvl = h.level
    let size = if lvl == 1: c.st.bodySize * 1.08 else: c.st.bodySize * 0.98
    let font = if lvl == 1: c.st.headFont else: c.st.bodyFont
    let bold = lvl == 1
    let step = size * (if lvl == 1: 2.1 else: 1.75)
    c.ensure(step)
    let ind = c.x0 + (lvl - 1).float * 16
    let fm = fontMetrics(font, size, bold, false)
    let base = c.y + (step - fm.height) / 2 + fm.ascent
    let ts = textShape(font, size, bold, false, (if lvl == 1: c.st.headCol else: c.st.textCol), label, ind, base)
    inc c.blockNo
    ts.data = "role=TOCI;b=" & $c.blockNo & ";lien=#" & id
    c.add ts
    let ps = textShape(font, size, bold, false, (if lvl == 1: c.st.accent else: c.st.muted), pg, 0, base)
    ps.x = c.x1 - abs(ps.w)
    ps.data = "role=TOCI;b=" & $c.blockNo & ";lien=#" & id
    c.add ps
    let lx0 = ind + abs(ts.w) + 6
    let lx1 = ps.x - 6
    if lx1 > lx0 + 10:
      let dots = lineShape(lx0, base - 1, lx1, base - 1, c.st.ruleCol, 1.1, "1 3")
      dots.data = "role=Artifact"
      c.add dots
    c.y += step
  c.newPage

proc doIndex(c: var Ctx) =
  if not c.atTop: c.newPage
  let size = c.st.hSize[1]
  let m = c.lineMetrics(c.st.headFont, size, 1.2)
  let t = textShape(c.st.headFont, size, true, false, c.st.headCol, c.st.indexTitle, c.x0, c.y + m.base)
  t.data = "role=H1"
  c.add t
  c.y += m.step
  let bar = rectShape(c.x0, c.y + 3, 36, 3, c.st.accent, 1.5)
  bar.data = "role=Artifact"
  c.add bar
  c.y += 22
  let gap = 24.0
  let colW = (c.contentW - gap) / 2
  let top = c.y
  var col = 0
  var letter = ""
  let fs = c.st.bodySize * 0.95
  let step = fs * 1.6
  for e in c.prev.index:
    let L0 = sortKey(e.term)
    let l = if L0.len > 0: L0[0 .. 0].toUpperAscii else: "#"
    var need = step
    if l != letter: need += step * 1.4
    if c.y + need > c.bottom:
      if col == 0:
        col = 1
        c.y = top
      else:
        c.newPage
        col = 0
    let x = c.x0 + col.float * (colW + gap)
    if l != letter:
      letter = l
      let fm = fontMetrics(c.st.headFont, fs * 1.2, true, false)
      let ls = textShape(c.st.headFont, fs * 1.2, true, false, c.st.accent, l, x, c.y + step * 0.4 + fm.ascent)
      ls.data = "role=H2"
      c.add ls
      c.y += step * 1.4
    let fm = fontMetrics(c.st.bodyFont, fs, false, false)
    let base = c.y + (step - fm.height) / 2 + fm.ascent
    let ts = textShape(c.st.bodyFont, fs, false, false, c.st.textCol, e.term, x, base)
    ts.data = "role=P"
    c.add ts
    var px = x + abs(ts.w) + 8
    for k, p in e.pages:
      let lbl = $p & (if k < e.pages.high: "," else: "")
      let ps = textShape(c.st.bodyFont, fs, false, false, c.st.accent, lbl, px, base)
      ps.data = "role=Link;lien=#page-" & $p
      c.add ps
      px += abs(ps.w) + 4
    c.y += step

proc doCover(c: var Ctx) =
  let st = c.st
  let band = rectShape(0, 0, st.pageW, st.pageH * 0.58, "linear(135," & st.accent & ",#0ea5e9)")
  band.data = "role=Artifact"
  c.add band
  # motif discret
  for k in 0 .. 5:
    let e = newShape(vkEllipse)
    let r = 60.0 + k.float * 48
    e.x = st.pageW * 0.78 - r; e.y = st.pageH * 0.12 - r; e.w = 2 * r; e.h = 2 * r
    e.fill = "none"
    e.stroke = "#ffffff"
    e.strokeWidth = 1
    e.opacity = 0.16 - k.float * 0.02
    e.data = "role=Artifact"
    c.add e
  let x = st.mLeft
  let w = st.pageW - st.mLeft - st.mRight
  c.y = st.pageH * 0.30
  c.flowText("**" & st.title & "**", x, w, st.headFont, 30, 1.18, "#ffffff", "Title")
  if st.subtitle.len > 0:
    c.y += 6
    c.flowText(st.subtitle, x, w, st.headFont, 14, 1.4, "#e0e7ff", "P")
  var info: seq[string]
  if st.author.len > 0: info.add st.author
  if st.date.len > 0: info.add st.date
  if info.len > 0:
    c.y = st.pageH * 0.64
    c.flowText(info.join("  ·  "), x, w, st.headFont, 11, 1.5, st.muted, "P")
  c.chapter = ""
  c.newPage

proc layoutBlocks(c: var Ctx, blocks: seq[MdBlk], x, width: float, depth = 0) =
  for i, b in blocks:
    case b.kind
    of bkHead:
      # A title followed by a figure remains with that figure (no title appearing alone at the bottom of a page)
      if i + 1 < blocks.len and blocks[i + 1].kind == bkFigure:
        let f = c.figureSize(blocks[i + 1], width)
        c.keepNext = min(f.h + f.capH + 12, (c.st.pageH - c.st.mTop - c.st.mBottom) * 0.7)
      c.doHeading(b)
    of bkPara: c.doPara(b, x, width)
    of bkList: c.doList(b, x, width)
    of bkQuote: c.doQuote(b, x, width)
    of bkCallout: c.doCallout(b, x, width)
    of bkCode: c.doCode(b, x, width)
    of bkTable: c.doTable(b, x, width)
    of bkFigure: c.doFigure(b, x, width)
    of bkRule: c.doRule(x, width)
    of bkToc: c.doToc()
    of bkIndex: c.doIndex()
    of bkBreak:
      if not c.atTop: c.newPage

proc expandTemplate(s: string, title, chapter: string, page, pages: int): string =
  s.multiReplace(("{titre}", title), ("{title}", title), ("{chapitre}", chapter), ("{page}", $page),
                 ("{pages}", $pages))

proc decorate(c: var Ctx) =
  # Headers and footers (excluding cover), page anchors.
  let n = c.pages.len
  let fs = 7.6
  for i, pg in c.pages:
    let p = i + 1
    if c.st.cover and i == 0: continue
    let even = p mod 2 == 0
    let x0 = if c.st.mirror and even: c.st.mRight else: c.st.mLeft
    let x1 = c.st.pageW - (if c.st.mirror and even: c.st.mLeft else: c.st.mRight)
    let chapter = if i < c.chapters.len: c.chapters[i] else: ""
    proc band(c: var Ctx, tpl: string, base: float, rule: float) =
      if tpl.strip.len == 0: return
      var parts = tpl.split('|')
      while parts.len < 3: parts.add ""
      if c.st.mirror and even: swap(parts[0], parts[2])
      for k in 0 .. 2:
        let t = expandTemplate(parts[k], c.st.title, chapter, p, n)
        if t.strip.len == 0: continue
        let s = textShape(c.st.headFont, fs, k == 2 and "{page}" in parts[k], false, c.st.muted, t, x0, base)
        if k == 1: s.x = (x0 + x1) / 2 - abs(s.w) / 2
        elif k == 2: s.x = x1 - abs(s.w)
        s.data = "role=Artifact"
        s.layer = "Calque 1"
        pg.shapes.add s
      if rule > 0:
        let l = lineShape(x0, rule, x1, rule, c.st.ruleCol, 0.6)
        l.layer = "Calque 1"
        l.data = "role=Artifact"
        pg.shapes.add l
    c.band(c.st.header, c.st.mTop * 0.5, c.st.mTop * 0.5 + 6)
    c.band(c.st.footer, c.st.pageH - c.st.mBottom * 0.45, 0)

proc layoutPass(blocks: seq[MdBlk], st: LStyle, prev: LResult): LResult =
  var c = Ctx(st: st, prev: prev)
  for b in blocks:
    if b.kind == bkHead: c.allHeads.add b
  c.newPage
  if st.cover and st.title.len > 0: c.doCover()
  c.layoutBlocks(blocks, c.x0, c.contentW)
  # dernière page vide (saut final) retirée
  if c.pages.len > 1 and c.page.shapes.len == 0:
    c.pages.setLen(c.pages.len - 1)
    c.chapters.setLen(c.pages.len)
  c.decorate()
  result.pages = c.pages
  result.headings = c.headings
  result.anchors = c.anchors
  for i in 1 .. c.pages.len: result.anchors["page-" & $i] = (i, 0.0)
  var keys: seq[string]
  for k in c.terms.keys: keys.add k
  keys.sort()
  for k in keys: result.index.add (c.termLabel[k], c.terms[k])
  result.style = st

proc layoutMarkdown*(md: string, st: LStyle): LResult =
  # Formats an enhanced Markdown document (already drafted).
  let blocks = parseMd(md)
  var needs2 = false
  for b in blocks:
    if b.kind in {bkToc, bkIndex}: needs2 = true
  if not needs2 and ("[[ref:" in md): needs2 = true
  let first = layoutPass(blocks, st, LResult())
  if not needs2: return first
  layoutPass(blocks, st, first)
