# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
#   _._
# o|- -|o  wdnotes - DocView, the consultation view (custom control)
#  ( l )   Lays out a RenderDoc as paper cards (one per note) with the
#    =     format's margins, header, footer, background, fonts, sizes,
#          colours, frames, lists, tables and clickable links.
#
# Commands (`dvId.value = cmd & Sep & arg`):
#   doc <json RenderDoc>   zoom <factor>   zoomin   zoomout
#   scroll <noteId>        top             theme dark|light
# Events: evSelection with ev.text = the link ("note:<id>", "missing:<t>",
# an URL) when a link is clicked.

import std/[strutils, tables, json, jsonutils]
import wdcompat, styles, render

const Sep = "\x1F"

type
  DItem = object
    kind: uint8                  # 0 text, 1 fill, 2 stroke, 3 hline, 4 label chip, 5 card
    x, y, w, h: float
    text, color, font: string
    size: float
    bold, italic: bool
    link: string

  DocView* = ref object of Control
    doc: RenderDoc
    hasDoc, dark, dirty: bool
    zoom: float
    scrollY: float
    items: seq[DItem]
    totalH, layoutW: float
    starts: Table[string, float]
    pendingScroll: string
    colors: Table[string, Color]

proc newDocView*(): DocView =
  result = DocView(zoom: 1.0, dirty: true)
  initControl(result, "")
  result.starts = initTable[string, float]()
  result.colors = initTable[string, Color]()

proc c2(v: DocView, s: string): Color =
  let k = if s.len == 0: "#000000" else: s
  if k notin v.colors: v.colors[k] = col(k)
  v.colors[k]

# layout

type
  WTok = object
    text: string
    w: float
    st: styles.Style
    link: string
    space, nl: bool

  WLine = object
    toks: seq[WTok]
    width, height, maxSize: float
    last: bool

proc measure(d: Drawing, s: string, st: styles.Style, k: float): float =
  d.gfxFont(st.font, st.size * k, st.bold, st.italic)
  d.gfxTextW(s)

proc toks(d: Drawing, runs: seq[Run], k: float): seq[WTok] =
  for r in runs:
    var word = ""
    template flush() =
      if word.len > 0:
        result.add WTok(text: word, w: measure(d, word, r.style, k), st: r.style, link: r.link)
        word = ""
    for c in r.text:
      if c == '\n':
        flush()
        result.add WTok(nl: true, st: r.style)
      elif c == ' ':
        flush()
        result.add WTok(text: " ", w: measure(d, " ", r.style, k), st: r.style, link: r.link,
                        space: true)
      else: word.add c
    flush()

proc wrapW(ts: seq[WTok], maxW: float, base: styles.Style, k: float): seq[WLine] =
  var line = WLine()
  var x = 0.0
  template finish(isLast: bool) =
    while line.toks.len > 0 and line.toks[^1].space: line.toks.setLen(line.toks.len - 1)
    line.width = 0
    line.maxSize = 0
    for t in line.toks:
      line.width += t.w
      line.maxSize = max(line.maxSize, t.st.size * k)
    if line.maxSize == 0: line.maxSize = base.size * k
    line.height = line.maxSize * max(base.lineHeight, 1.05) * 1.08
    line.last = isLast
    result.add line
    line = WLine()
    x = 0
  for t in ts:
    if t.nl:
      finish(true); continue
    if t.space:
      if line.toks.len == 0: continue
      line.toks.add t; x += t.w; continue
    if x + t.w > maxW and line.toks.len > 0: finish(false)
    line.toks.add t
    x += t.w
  if line.toks.len > 0 or result.len == 0: finish(true)

proc relayout(v: DocView, d: Drawing, width: float) =
  v.items.setLen(0)
  v.starts.clear()
  let pxMm = 96.0 / 25.4
  var y = 28.0
  for s in v.doc.sections:
    let pg = s.page
    var z = v.zoom
    let naturalW = pg.width * pxMm
    if naturalW * z > width - 48: z = max(0.3, (width - 48) / naturalW)
    let k = z * 96.0 / 72.0          # pt -> px
    let cardW = naturalW * z
    let cx = max(24.0, (width - cardW) / 2)
    let mL = pg.marginLeft * pxMm * z
    let mR = pg.marginRight * pxMm * z
    let mT = pg.marginTop * pxMm * z
    let mB = pg.marginBottom * pxMm * z
    let cardTop = y
    v.starts[s.noteId] = cardTop
    let cardIdx = v.items.len
    v.items.add DItem(kind: 5, x: cx, y: cardTop, w: cardW, h: 0,
                      color: (if pg.background.len > 0: pg.background else: "#ffffff"))
    var cy = cardTop + mT
    # labels
    if s.labels.len > 0:
      var lx = cx + mL
      for l in s.labels:
        var st = defaultStyle()
        st.font = "Sans"; st.size = 7.5; st.bold = true
        let w = measure(d, l, st, k) + 14 * z
        v.items.add DItem(kind: 4, x: lx, y: cy - 22 * z, w: w, h: 16 * z, text: l,
                          color: (if s.labelColor.len > 0: s.labelColor else: "#6b7a8f"),
                          font: "Sans", size: 7.5 * k, bold: true)
        lx += w + 6
    let x0 = cx + mL
    let x1 = cx + cardW - mR
    for b in s.blocks:
      let st = b.style
      case b.kind
      of "pagebreak":
        v.items.add DItem(kind: 3, x: x0, y: cy + 6, w: x1 - x0, color: "#d0d4da")
        v.items.add DItem(kind: 0, x: (x0 + x1) / 2 - 30, y: cy + 8, h: 14, text: "saut de page",
                          color: "#a0a6ae", font: "Sans", size: 8 * k, italic: true)
        cy += 24
        continue
      of "hr":
        cy += st.before * k
        v.items.add DItem(kind: 3, x: x0 + st.indent * k, y: cy, w: x1 - x0 - st.indent * k,
                          color: (if st.border.len > 0: st.border else: "#bbbbbb"))
        cy += st.after * k + 2
        continue
      else: discard
      cy += st.before * k
      let bx0 = x0 + st.indent * k
      let framed = st.bg.len > 0 or st.frame.len > 0
      let pad = if framed: 6.0 * z else: 0.0
      let tx = bx0 + pad + (if st.frame == "left": 5 * z else: 0)
      let availW = x1 - pad - tx
      let blockTop = cy
      let frameIdx = v.items.len
      cy += pad
      if b.kind == "table":
        var cols = 0
        for r in b.rows: cols = max(cols, r.len)
        if cols > 0:
          let W = x1 - bx0
          var nat = newSeq[float](cols)
          for r in b.rows:
            for c, cell in r:
              var w = 0.0
              for t in toks(d, cell, k): w += t.w
              nat[c] = max(nat[c], min(w, W * 0.6) + 12 * z)
          var tot = 0.0
          for c in 0 ..< cols:
            nat[c] = max(nat[c], 40 * z); tot += nat[c]
          let bc = if st.border.len > 0: st.border else: "#c8ccd2"
          for r, row in b.rows:
            let cs = if r == 0: b.thStyle else: b.tdStyle
            var lines: seq[seq[WLine]]
            var rh = 0.0
            for c in 0 ..< cols:
              let w = nat[c] * W / tot
              let cell = if c < row.len: row[c] else: newSeq[Run]()
              let ls = wrapW(toks(d, cell, k), w - 12 * z, cs, k)
              var h = 0.0
              for l in ls: h += l.height
              rh = max(rh, h)
              lines.add ls
            rh += 10 * z
            var cxp = bx0
            for c in 0 ..< cols:
              let w = nat[c] * W / tot
              if cs.bg.len > 0:
                v.items.add DItem(kind: 1, x: cxp, y: cy, w: w, h: rh, color: cs.bg)
              v.items.add DItem(kind: 2, x: cxp, y: cy, w: w, h: rh, color: bc)
              var ly = cy + 5 * z
              let al = if c < b.aligns.len: b.aligns[c] else: "left"
              for l in lines[c]:
                var lx = cxp + 6 * z
                if al == "center": lx = cxp + (w - l.width) / 2
                elif al == "right": lx = cxp + w - 6 * z - l.width
                for t in l.toks:
                  if not t.space:
                    v.items.add DItem(kind: 0, x: lx, y: ly, w: t.w, h: l.height, text: t.text,
                                      color: t.st.color, font: t.st.font, size: t.st.size * k,
                                      bold: t.st.bold, italic: t.st.italic, link: t.link)
                  lx += t.w
                ly += l.height
              cxp += w
            cy += rh
      elif b.kind == "code":
        var ls: seq[WLine]
        for raw in plain(b.runs).split('\n'):
          ls.add WLine(toks: @[WTok(text: raw, w: measure(d, raw, st, k), st: st)],
                       height: st.size * k * st.lineHeight * 1.1, maxSize: st.size * k, last: true)
        for l in ls:
          if l.toks[0].text.len > 0:
            v.items.add DItem(kind: 0, x: tx, y: cy, h: l.height, text: l.toks[0].text,
                              color: st.color, font: st.font, size: st.size * k)
          cy += l.height
      else:
        let lines = wrapW(toks(d, b.runs, k), availW, st, k)
        for i, l in lines:
          if i == 0 and b.marker.len > 0:
            let mw = measure(d, b.marker, st, k)
            v.items.add DItem(kind: 0, x: tx - mw - 6 * z, y: cy, h: l.height, text: b.marker,
                              color: (if st.color.len > 0: st.color else: "#000000"),
                              font: st.font, size: st.size * k, bold: st.bold)
          var lx = tx
          var extra = 0.0
          case st.align
          of "center": lx = tx + (availW - l.width) / 2
          of "right": lx = tx + availW - l.width
          of "justify":
            if not l.last:
              var n = 0
              for t in l.toks:
                if t.space: inc n
              if n > 0 and l.width > availW * 0.6: extra = (availW - l.width) / float(n)
          else: discard
          for t in l.toks:
            let w = t.w + (if t.space: extra else: 0)
            if not t.space:
              if t.st.bg.len > 0 and t.st.bg != st.bg:
                v.items.add DItem(kind: 1, x: lx - 1, y: cy + (l.height - t.st.size * k * 1.3) / 2,
                                  w: t.w + 2, h: t.st.size * k * 1.3, color: t.st.bg)
              v.items.add DItem(kind: 0, x: lx, y: cy, w: t.w, h: l.height, text: t.text,
                                color: t.st.color, font: t.st.font, size: t.st.size * k,
                                bold: t.st.bold, italic: t.st.italic, link: t.link)
            if t.st.underline:
              v.items.add DItem(kind: 3, x: lx, y: cy + l.height / 2 + t.st.size * k * 0.55,
                                w: w, color: t.st.color)
            if t.st.strike:
              v.items.add DItem(kind: 3, x: lx, y: cy + l.height / 2, w: w, color: t.st.color)
            lx += w
          cy += l.height
      cy += pad
      if framed:
        var fr: seq[DItem]
        let bc = if st.border.len > 0: st.border else: "#cccccc"
        if st.bg.len > 0:
          fr.add DItem(kind: 1, x: bx0, y: blockTop, w: x1 - bx0, h: cy - blockTop, color: st.bg)
        case st.frame
        of "left": fr.add DItem(kind: 1, x: bx0, y: blockTop, w: 3 * z, h: cy - blockTop, color: bc)
        of "box": fr.add DItem(kind: 2, x: bx0, y: blockTop, w: x1 - bx0, h: cy - blockTop, color: bc)
        of "bottom": fr.add DItem(kind: 3, x: bx0, y: cy, w: x1 - bx0, color: bc)
        of "top": fr.add DItem(kind: 3, x: bx0, y: blockTop, w: x1 - bx0, color: bc)
        else: discard
        for k2, it in fr: v.items.insert(it, frameIdx + k2)
      cy += st.after * k
    let cardH = max(cy - cardTop + mB, pg.height * pxMm * z * 0.35)
    v.items[cardIdx].h = cardH
    # header and footer
    for (txt, st, yy) in [(pg.header, pg.headerStyle, cardTop + mT * 0.42),
                          (pg.footer, pg.footerStyle, cardTop + cardH - mB * 0.62)]:
      if txt.len == 0: continue
      let t = fillPlaceholders(txt, v.doc.project, s.title, v.starts.len, v.doc.sections.len,
                               v.doc.date)
      let tw = measure(d, t, st, k)
      let hx = case st.align
        of "center": (x0 + x1 - tw) / 2
        of "right": x1 - tw
        else: x0
      v.items.add DItem(kind: 0, x: hx, y: yy - st.size * k * 0.7, h: st.size * k * 1.4,
                        text: t, color: st.color, font: st.font, size: st.size * k,
                        bold: st.bold, italic: st.italic)
    y = cardTop + cardH + 28
  v.totalH = y
  v.layoutW = width
  v.dirty = false

# drawing

method typeName*(v: DocView): string = "DocView"

method preferredSize*(v: DocView, d: Drawing, t: Theme): tuple[w, h: float] = (420.0, 320.0)

method draw*(v: DocView, d: Drawing, t: Theme) =
  let r = v.rect
  d.gfxFill(r.x, r.y, r.w, r.h, if v.dark: col("#15171a") else: col("#e9ebee"))
  if not v.hasDoc:
    d.gfxFontReset(t)
    d.gfxText(r.x + 24, r.y + 24, 24, "Aucun document à afficher.", col("#8a8f98"))
    return
  if v.dirty or abs(v.layoutW - r.w) > 0.5:
    v.relayout(d, r.w)
  if v.pendingScroll.len > 0 and v.pendingScroll in v.starts:
    v.scrollY = v.starts[v.pendingScroll] - 16
    v.pendingScroll = ""
  v.scrollY = clamp(v.scrollY, 0.0, max(0.0, v.totalH - r.h))
  d.gfxClip(r.x, r.y, r.w, r.h)
  let top = v.scrollY - 40
  let bottom = v.scrollY + r.h + 40
  for it in v.items:
    let iy = it.y
    if it.kind == 5:
      # paper card (drawn even if partially visible).
      if iy + it.h < top or iy > bottom: continue
      d.gfxShadow(r.x + it.x, r.y + iy - v.scrollY, it.w, it.h, 3)
      d.gfxRound(r.x + it.x, r.y + iy - v.scrollY, it.w, it.h, 3, v.c2(it.color))
      continue
    if iy + max(it.h, 2) < top or iy > bottom: continue
    let x = r.x + it.x
    let y = r.y + iy - v.scrollY
    case it.kind
    of 0:
      d.gfxFont(it.font, it.size, it.bold, it.italic)
      d.gfxText(x, y, it.h, it.text, v.c2(it.color))
    of 1: d.gfxFill(x, y, it.w, it.h, v.c2(it.color))
    of 2: d.gfxStroke(x, y, it.w, it.h, v.c2(it.color))
    of 3: d.gfxFill(x, y, it.w, 1, v.c2(it.color))
    of 4:
      d.gfxRound(x, y, it.w, it.h, it.h / 2, v.c2(it.color))
      d.gfxFont(it.font, it.size, true, false)
      d.gfxText(x + 7, y, it.h, it.text, col("#ffffff"))
    else: discard
  d.gfxFontReset(t)
  if v.totalH > r.h:
    let th = max(30.0, r.h * r.h / v.totalH)
    let ty = r.y + (r.h - th) * v.scrollY / (v.totalH - r.h)
    d.gfxRound(r.x + r.w - 8, ty + 2, 5, th - 4, 2.5, colA("#000000", 70))
  d.gfxUnclip()

method onWheel*(v: DocView, dx, dy: float): bool =
  v.scrollY = max(0.0, v.scrollY - float(dy) * 60)
  true

method onMouse*(v: DocView, e: MouseEvent) =
  if e.action != maRelease or e.button != mbLeft: return
  let r = v.rect
  let x = mouseX(e) - r.x
  let y = mouseY(e) - r.y + v.scrollY
  for it in v.items:
    if it.kind == 0 and it.link.len > 0 and x >= it.x - 2 and x <= it.x + it.w + 2 and
       y >= it.y and y <= it.y + it.h:
      emit(v, evSelection, text = it.link)
      return

method valueText*(v: DocView): string = $v.zoom

method setValueText*(v: DocView, s: string) =
  let k = s.find(Sep)
  let cmd = if k >= 0: s[0 ..< k] else: s
  let arg = if k >= 0: s[k + 1 .. ^1] else: ""
  case cmd
  of "doc":
    try:
      v.doc = jsonTo(parseJson(arg), RenderDoc)
      v.hasDoc = true
    except CatchableError:
      v.hasDoc = false
    v.dirty = true
    v.scrollY = 0
  of "zoom":
    try: v.zoom = clamp(parseFloat(arg), 0.4, 3.0)
    except ValueError: discard
    v.dirty = true
  of "zoomin":
    v.zoom = min(3.0, v.zoom * 1.15); v.dirty = true
  of "zoomout":
    v.zoom = max(0.4, v.zoom / 1.15); v.dirty = true
  of "scroll": v.pendingScroll = arg
  of "top": v.scrollY = 0
  of "theme": v.dark = arg == "dark"
  else: discard

proc docPayload*(doc: RenderDoc): string =
  "doc" & Sep & $toJson(doc)
