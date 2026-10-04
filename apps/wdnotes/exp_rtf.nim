# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
#   _._
# o|- -|o  wdnotes - RTF export
#  ( l )   Rich Text Format 1.9: font and colour tables, page size and
#    =     margins, header / footer with the PAGE / NUMPAGES fields, styled
#          paragraphs (spacing, indentation, alignment, shading, borders),
#          character formatting, hyperlinks and tables.
#          Opens in Word, LibreOffice Writer, WordPad, TextEdit...

import std/[strutils, tables, math]
import std/unicode except strip, split, splitWhitespace, align, alignLeft, cmpIgnoreCase, reversed
import styles, render

type RtfBook = object
  fonts: OrderedTable[string, int]
  colors: OrderedTable[string, int]

proc fontIdx(b: var RtfBook, f: string): int =
  let name = officeFamily(f)
  if name notin b.fonts: b.fonts[name] = b.fonts.len
  b.fonts[name]

proc colorIdx(b: var RtfBook, c: string): int =
  if c.len == 0: return 0
  if c notin b.colors: b.colors[c] = b.colors.len + 1
  b.colors[c]

proc rtfText(s: string): string =
  for r in s.runes:
    let c = int(r)
    case c
    of ord('\\'): result.add "\\\\"
    of ord('{'): result.add "\\{"
    of ord('}'): result.add "\\}"
    of 0x0A: result.add "\\line "
    of 0x09: result.add "\\tab "
    else:
      if c < 0x80: result.add char(c)
      elif c <= 0xFFFF:
        let v = if c > 32767: c - 65536 else: c
        result.add "\\u" & $v & "?"
      else:
        # surrogate pair
        let x = c - 0x10000
        let hi = 0xD800 + (x shr 10)
        let lo = 0xDC00 + (x and 0x3FF)
        result.add "\\u" & $(hi - 65536) & "?\\u" & $(lo - 65536) & "?"

proc tw(pt: float): int = int(round(pt * 20))
proc twMm(mm: float): int = int(round(mm * 56.6929))

proc charFmt(b: var RtfBook, s: Style): string =
  result = "\\f" & $b.fontIdx(s.font) & "\\fs" & $int(round(s.size * 2))
  if s.bold: result.add "\\b"
  if s.italic: result.add "\\i"
  if s.underline: result.add "\\ul"
  if s.strike: result.add "\\strike"
  if s.color.len > 0: result.add "\\cf" & $b.colorIdx(s.color)
  if s.bg.len > 0: result.add "\\chcbpat" & $b.colorIdx(s.bg) & "\\chshdng10000"
  result.add " "

proc paraFmt(b: var RtfBook, s: Style, firstIndent = 0.0): string =
  result = "\\pard\\plain"
  let q = case s.align
    of "center": "\\qc"
    of "right": "\\qr"
    of "justify": "\\qj"
    else: "\\ql"
  result.add q
  result.add "\\sb" & $tw(s.before) & "\\sa" & $tw(s.after) & "\\li" & $tw(s.indent)
  if firstIndent != 0: result.add "\\fi" & $tw(firstIndent)
  result.add "\\sl" & $tw(s.size * s.lineHeight * 1.0) & "\\slmult0"
  if s.pageBreak: result.add "\\pagebb"
  if s.bg.len > 0: result.add "\\cbpat" & $b.colorIdx(s.bg) & "\\shading10000"
  let bc = b.colorIdx(if s.border.len > 0: s.border else: "#cccccc")
  case s.frame
  of "left": result.add "\\brdrl\\brdrs\\brdrw40\\brsp80\\brdrcf" & $bc
  of "box": result.add "\\box\\brdrs\\brdrw10\\brsp60\\brdrcf" & $bc
  of "bottom": result.add "\\brdrb\\brdrs\\brdrw20\\brsp40\\brdrcf" & $bc
  of "top": result.add "\\brdrt\\brdrs\\brdrw20\\brsp40\\brdrcf" & $bc
  else: discard
  result.add " "

proc runsRtf(b: var RtfBook, runs: seq[Run]): string =
  for r in runs:
    let body = "{" & b.charFmt(r.style) & rtfText(r.text) & "}"
    if r.link.len > 0 and not r.link.startsWith("missing:"):
      let target = if r.link.startsWith("note:"): "\\\\l \"" & r.link[5 .. ^1] & "\""
                   else: "\"" & r.link & "\""
      result.add "{\\field{\\*\\fldinst{HYPERLINK " & target & "}}{\\fldrslt " & body & "}}"
    else:
      result.add body

proc tableRtf(b: var RtfBook, bl: RBlock, textWidth: float): string =
  var cols = 0
  for r in bl.rows: cols = max(cols, r.len)
  if cols == 0: return
  let bc = b.colorIdx(if bl.style.border.len > 0: bl.style.border else: "#c8ccd2")
  let cw = textWidth / float(cols)
  for r, row in bl.rows:
    let cs = if r == 0: bl.thStyle else: bl.tdStyle
    result.add "\\trowd\\trgaph108\\trleft" & $tw(bl.style.indent)
    if r == 0: result.add "\\trhdr"
    for k in 0 ..< cols:
      result.add "\\clbrdrt\\brdrs\\brdrw10\\brdrcf" & $bc & "\\clbrdrl\\brdrs\\brdrw10\\brdrcf" &
        $bc & "\\clbrdrb\\brdrs\\brdrw10\\brdrcf" & $bc & "\\clbrdrr\\brdrs\\brdrw10\\brdrcf" & $bc
      if cs.bg.len > 0: result.add "\\clcbpat" & $b.colorIdx(cs.bg)
      result.add "\\cellx" & $tw(bl.style.indent + cw * float(k + 1))
    result.add "\n"
    for k in 0 ..< cols:
      let al = if k < bl.aligns.len: bl.aligns[k] else: "left"
      let q = case al
        of "center": "\\qc"
        of "right": "\\qr"
        else: "\\ql"
      result.add "\\pard\\intbl" & q & " "
      if k < row.len: result.add b.runsRtf(row[k])
      result.add "\\cell\n"
    result.add "\\row\n"
  result.add "\\pard\\sa" & $tw(bl.style.after) & "\\par\n"

proc renderRtf*(doc: RenderDoc): string =
  var b = RtfBook(fonts: initOrderedTable[string, int](), colors: initOrderedTable[string, int]())
  discard b.fontIdx("Serif")
  var body = ""
  let pg = if doc.sections.len > 0: doc.sections[0].page
           else: PageSetup(width: 210, height: 297, marginTop: 25, marginBottom: 22,
                           marginLeft: 25, marginRight: 22)
  let textWidth = (pg.width - pg.marginLeft - pg.marginRight) * 72 / 25.4
  for si, s in doc.sections:
    body.add "{\\*\\bkmkstart " & s.noteId & "}{\\*\\bkmkend " & s.noteId & "}"
    for bl in s.blocks:
      case bl.kind
      of "pagebreak": body.add "\\page\n"
      of "hr":
        let bc = b.colorIdx(if bl.style.border.len > 0: bl.style.border else: "#bbbbbb")
        body.add "\\pard\\sb" & $tw(bl.style.before) & "\\sa" & $tw(bl.style.after) &
          "\\brdrb\\brdrs\\brdrw10\\brdrcf" & $bc & "\\fs4 \\par\n"
      of "table": body.add b.tableRtf(bl, textWidth)
      of "code":
        var st = bl.style
        if st.bg.len == 0 and st.frame.len == 0: st.bg = "#f4f5f7"
        let lines = plain(bl.runs).split('\n')
        for k, l in lines:
          var ps = st
          if k > 0: ps.before = 0
          if k < lines.high: ps.after = 0
          ps.align = "left"
          body.add b.paraFmt(ps) & "{" & b.charFmt(st) & rtfText(l) & "}\\par\n"
      of "li":
        body.add b.paraFmt(bl.style, -14) & "{" & b.charFmt(bl.style) &
          rtfText(if bl.marker.len > 0: bl.marker else: " ") & "}\\tab " &
          b.runsRtf(bl.runs) & "\\par\n"
      else:
        body.add b.paraFmt(bl.style) & b.runsRtf(bl.runs) & "\\par\n"
    discard si
  # header / footer
  proc hf(b: var RtfBook, txt: string, st: Style, doc: RenderDoc): string =
    let pageField = "{\\field{\\*\\fldinst PAGE}{\\fldrslt 1}}"
    let pagesField = "{\\field{\\*\\fldinst NUMPAGES}{\\fldrslt 1}}"
    var raw = rtfText(txt.multiReplace(("{project}", doc.project), ("{projet}", doc.project),
                                       ("{title}", doc.title), ("{titre}", doc.title),
                                       ("{date}", doc.date)))
    raw = raw.replace("\\{page\\}", pageField).replace("\\{pages\\}", pagesField)
    b.paraFmt(st) & "{" & b.charFmt(st) & raw & "}\\par"
  var head = ""
  if pg.header.len > 0: head.add "{\\header " & b.hf(pg.header, pg.headerStyle, doc) & "}\n"
  if pg.footer.len > 0: head.add "{\\footer " & b.hf(pg.footer, pg.footerStyle, doc) & "}\n"
  # tables
  var ft = "{\\fonttbl"
  for name, idx in b.fonts:
    let fam = if isMonoFont(name): "\\fmodern" elif isSansFont(name): "\\fswiss" else: "\\froman"
    ft.add "{\\f" & $idx & fam & "\\fcharset0 " & name & ";}"
  ft.add "}\n"
  var ct = "{\\colortbl;"
  for c, _ in b.colors:
    var h = c.strip(chars = {'#'})
    if h.len != 6: h = "000000"
    try:
      ct.add "\\red" & $parseHexInt(h[0..1]) & "\\green" & $parseHexInt(h[2..3]) & "\\blue" &
        $parseHexInt(h[4..5]) & ";"
    except ValueError: ct.add "\\red0\\green0\\blue0;"
  ct.add "}\n"
  result = "{\\rtf1\\ansi\\ansicpg1252\\deff0\\uc1\n" & ft & ct &
    "{\\info{\\title " & rtfText(doc.title) & "}{\\subject " & rtfText(doc.project) &
    "}{\\doccomm wdnotes}}\n" &
    "\\paperw" & $twMm(pg.width) & "\\paperh" & $twMm(pg.height) &
    "\\margl" & $twMm(pg.marginLeft) & "\\margr" & $twMm(pg.marginRight) &
    "\\margt" & $twMm(pg.marginTop) & "\\margb" & $twMm(pg.marginBottom) &
    "\\headery" & $twMm(pg.marginTop * 0.45) & "\\footery" & $twMm(pg.marginBottom * 0.4) &
    (if pg.width > pg.height: "\\landscape" else: "") & "\n" &
    head & body & "}\n"

proc exportRtf*(doc: RenderDoc, path: string) =
  writeFile(path, renderRtf(doc))
