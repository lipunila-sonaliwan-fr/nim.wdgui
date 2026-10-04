# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
#   _._
# o|- -|o  wdnotes - LibreOffice export (.fodt, Flat OpenDocument Text)
#  ( l )   A single XML file opened natively by LibreOffice / OpenOffice
#    =     (and convertible to .odt / .docx / .pdf by them). Automatic
#          paragraph and text styles are generated from the resolved
#          styles, the page layout comes from the format, the header and
#          footer contain live page-number / page-count fields, notes are
#          bookmarked and wiki links become internal hyperlinks.

import std/[strutils, tables]
import styles, render

type OdtBook = object
  para: OrderedTable[string, string]                              # attributes -> P name.
  text: OrderedTable[string, string]                              # attributes -> T name.
  cells: OrderedTable[string, string]                             # attributes -> cell style name.
  fonts: OrderedTable[string, bool]

proc x(s: string): string =
  result = newStringOfCap(s.len)
  for c in s:
    case c
    of '&': result.add "&amp;"
    of '<': result.add "&lt;"
    of '>': result.add "&gt;"
    of '"': result.add "&quot;"
    else: result.add c

proc ptS(v: float): string = formatFloat(v, ffDecimal, 1) & "pt"

proc textProps(b: var OdtBook, s: Style): string =
  let fam = officeFamily(s.font)
  b.fonts[fam] = true
  result = "<style:text-properties style:font-name=\"" & x(fam) & "\" fo:font-size=\"" &
    ptS(s.size) & "\""
  result.add " fo:font-weight=\"" & (if s.bold: "bold" else: "normal") & "\""
  result.add " fo:font-style=\"" & (if s.italic: "italic" else: "normal") & "\""
  if s.underline:
    result.add " style:text-underline-style=\"solid\" style:text-underline-width=\"auto\"" &
      " style:text-underline-color=\"font-color\""
  if s.strike: result.add " style:text-line-through-style=\"solid\""
  if s.color.len > 0: result.add " fo:color=\"" & s.color & "\""
  if s.bg.len > 0: result.add " fo:background-color=\"" & s.bg & "\""
  result.add "/>"

proc paraName(b: var OdtBook, s: Style, marginLeft = -1.0, textIndent = 0.0,
              keepBg = true): string =
  let al = case s.align
    of "center": "center"
    of "right": "end"
    of "justify": "justify"
    else: "start"
  var pp = "<style:paragraph-properties fo:margin-left=\"" &
    ptS(if marginLeft >= 0: marginLeft else: s.indent) & "\" fo:margin-top=\"" & ptS(s.before) &
    "\" fo:margin-bottom=\"" & ptS(s.after) & "\" fo:text-indent=\"" & ptS(textIndent) &
    "\" fo:line-height=\"" & $int(s.lineHeight * 100) & "%\" fo:text-align=\"" & al & "\""
  if s.pageBreak: pp.add " fo:break-before=\"page\""
  if keepBg and s.bg.len > 0: pp.add " fo:background-color=\"" & s.bg & "\""
  let bc = if s.border.len > 0: s.border else: "#cccccc"
  case s.frame
  of "left": pp.add " fo:border-left=\"2.5pt solid " & bc & "\" fo:padding-left=\"6pt\""
  of "box": pp.add " fo:border=\"0.8pt solid " & bc & "\" fo:padding=\"4pt\""
  of "bottom": pp.add " fo:border-bottom=\"1.2pt solid " & bc & "\" fo:padding-bottom=\"3pt\""
  of "top": pp.add " fo:border-top=\"1.2pt solid " & bc & "\" fo:padding-top=\"3pt\""
  else:
    if keepBg and s.bg.len > 0: pp.add " fo:padding=\"3pt\""
  pp.add "><style:tab-stops/></style:paragraph-properties>"
  let key = pp & b.textProps(s)
  if key notin b.para: b.para[key] = "P" & $(b.para.len + 1)
  b.para[key]

proc textName(b: var OdtBook, s: Style): string =
  let key = b.textProps(s)
  if key notin b.text: b.text[key] = "T" & $(b.text.len + 1)
  b.text[key]

proc spans(b: var OdtBook, runs: seq[Run], base: Style): string =
  for r in runs:
    var t = ""
    var first = true
    for part in r.text.split('\n'):
      if not first: t.add "<text:line-break/>"
      first = false
      # preserve runs of spaces.
      var k = 0
      while k < part.len:
        if part[k] == ' ' and k + 1 < part.len and part[k + 1] == ' ':
          var n = 0
          while k < part.len and part[k] == ' ': inc n; inc k
          t.add " <text:s text:c=\"" & $(n - 1) & "\"/>"
        else:
          t.add x($part[k])
          inc k
    if r.style != base:
      t = "<text:span text:style-name=\"" & b.textName(r.style) & "\">" & t & "</text:span>"
    if r.link.startsWith("note:"):
      t = "<text:a xlink:type=\"simple\" xlink:href=\"#" & r.link[5 .. ^1] & "\">" & t & "</text:a>"
    elif r.link.len > 0 and not r.link.startsWith("missing:"):
      t = "<text:a xlink:type=\"simple\" xlink:href=\"" & x(r.link) & "\">" & t & "</text:a>"
    result.add t

proc hfContent(txt: string, doc: RenderDoc): string =
  var s = x(txt.multiReplace(("{project}", doc.project), ("{projet}", doc.project),
                             ("{title}", doc.title), ("{titre}", doc.title), ("{date}", doc.date)))
  s.replace("{page}", "<text:page-number text:select-page=\"current\">1</text:page-number>")
   .replace("{pages}", "<text:page-count>1</text:page-count>")

proc renderFodt*(doc: RenderDoc): string =
  var b = OdtBook(para: initOrderedTable[string, string](), text: initOrderedTable[string, string](),
                  cells: initOrderedTable[string, string](), fonts: initOrderedTable[string, bool]())
  var body = ""
  var tableCount = 0
  let pg = if doc.sections.len > 0: doc.sections[0].page
           else: PageSetup(width: 210, height: 297, marginTop: 25, marginBottom: 22,
                           marginLeft: 25, marginRight: 22)
  let textW = (pg.width - pg.marginLeft - pg.marginRight) * 72 / 25.4
  var tableStyles = ""
  for s in doc.sections:
    var firstBlock = true
    for bl in s.blocks:
      let bookmark = if firstBlock: "<text:bookmark text:name=\"" & s.noteId & "\"/>" else: ""
      firstBlock = false
      case bl.kind
      of "pagebreak":
        var ps = defaultStyle()
        ps.pageBreak = true
        ps.size = 2
        body.add "<text:p text:style-name=\"" & b.paraName(ps) & "\"/>\n"
      of "hr":
        var hs = bl.style
        hs.frame = "bottom"
        hs.size = 3
        hs.lineHeight = 1
        body.add "<text:p text:style-name=\"" & b.paraName(hs) & "\">" & bookmark & "</text:p>\n"
      of "title":
        body.add "<text:h text:outline-level=\"" & $(bl.level + 1) & "\" text:style-name=\"" &
          b.paraName(bl.style) & "\">" & bookmark & b.spans(bl.runs, bl.style) & "</text:h>\n"
      of "heading":
        body.add "<text:h text:outline-level=\"" & $min(bl.level + 1, 10) & "\" text:style-name=\"" &
          b.paraName(bl.style) & "\">" & bookmark & b.spans(bl.runs, bl.style) & "</text:h>\n"
      of "li":
        body.add "<text:p text:style-name=\"" & b.paraName(bl.style, bl.style.indent + 14, -14) &
          "\">" & bookmark & x(if bl.marker.len > 0: bl.marker else: "") &
          "<text:tab/>" & b.spans(bl.runs, bl.style) & "</text:p>\n"
      of "code":
        var st = bl.style
        if st.bg.len == 0 and st.frame.len == 0: st.bg = "#f4f5f7"
        st.align = "left"
        let lines = plain(bl.runs).split('\n')
        for k, l in lines:
          var ps = st
          if k > 0: ps.before = 0
          if k < lines.high: ps.after = 0
          body.add "<text:p text:style-name=\"" & b.paraName(ps) & "\">" &
            (if k == 0: bookmark else: "") &
            b.spans(@[Run(text: l, style: st)], st) & "</text:p>\n"
      of "table":
        inc tableCount
        var cols = 0
        for r in bl.rows: cols = max(cols, r.len)
        if cols == 0: continue
        let tname = "Tbl" & $tableCount
        let bc = if bl.style.border.len > 0: bl.style.border else: "#c8ccd2"
        tableStyles.add "<style:style style:name=\"" & tname & "\" style:family=\"table\">" &
          "<style:table-properties style:width=\"" & ptS(textW - bl.style.indent) &
          "\" fo:margin-left=\"" & ptS(bl.style.indent) & "\" fo:margin-bottom=\"" &
          ptS(bl.style.after) & "\" table:align=\"margins\"/></style:style>\n"
        for (nm, cs) in [("H", bl.thStyle), ("D", bl.tdStyle)]:
          tableStyles.add "<style:style style:name=\"" & tname & nm &
            "\" style:family=\"table-cell\"><style:table-cell-properties fo:padding=\"3pt\" " &
            "fo:border=\"0.6pt solid " & bc & "\"" &
            (if cs.bg.len > 0: " fo:background-color=\"" & cs.bg & "\"" else: "") &
            "/></style:style>\n"
        body.add bookmark.replace("<text:bookmark", "<text:p><text:bookmark").replace("/>", "/></text:p>")
        body.add "<table:table table:name=\"" & tname & "\" table:style-name=\"" & tname &
          "\"><table:table-column table:number-columns-repeated=\"" & $cols & "\"/>\n"
        for r, row in bl.rows:
          if r == 0: body.add "<table:table-header-rows>"
          body.add "<table:table-row>"
          for k in 0 ..< cols:
            var cs = if r == 0: bl.thStyle else: bl.tdStyle
            cs.align = if k < bl.aligns.len: bl.aligns[k] else: "left"
            cs.before = 0
            cs.after = 0
            cs.indent = 0
            cs.frame = ""
            body.add "<table:table-cell table:style-name=\"" & tname & (if r == 0: "H" else: "D") &
              "\" office:value-type=\"string\"><text:p text:style-name=\"" &
              b.paraName(cs, 0, 0, keepBg = false) & "\">" &
              (if k < row.len: b.spans(row[k], cs) else: "") & "</text:p></table:table-cell>"
          body.add "</table:table-row>"
          if r == 0: body.add "</table:table-header-rows>"
          body.add "\n"
        body.add "</table:table>\n"
      else:
        body.add "<text:p text:style-name=\"" & b.paraName(bl.style) & "\">" & bookmark &
          b.spans(bl.runs, bl.style) & "</text:p>\n"
  let hd = b.paraName(pg.headerStyle)
  let ft = b.paraName(pg.footerStyle)
  var auto = ""
  for key, name in b.para:
    auto.add "<style:style style:name=\"" & name & "\" style:family=\"paragraph\" " &
      "style:parent-style-name=\"Standard\">" & key & "</style:style>\n"
  for key, name in b.text:
    auto.add "<style:style style:name=\"" & name & "\" style:family=\"text\">" & key &
      "</style:style>\n"
  auto.add tableStyles
  auto.add "<style:page-layout style:name=\"pm1\"><style:page-layout-properties fo:page-width=\"" &
    formatFloat(pg.width, ffDecimal, 1) & "mm\" fo:page-height=\"" &
    formatFloat(pg.height, ffDecimal, 1) & "mm\" style:print-orientation=\"" &
    (if pg.width > pg.height: "landscape" else: "portrait") & "\" fo:margin-top=\"" &
    formatFloat(pg.marginTop * 0.55, ffDecimal, 1) & "mm\" fo:margin-bottom=\"" &
    formatFloat(pg.marginBottom * 0.55, ffDecimal, 1) & "mm\" fo:margin-left=\"" &
    formatFloat(pg.marginLeft, ffDecimal, 1) & "mm\" fo:margin-right=\"" &
    formatFloat(pg.marginRight, ffDecimal, 1) & "mm\"" &
    (if pg.background.len > 0: " fo:background-color=\"" & pg.background & "\"" else: "") &
    "/><style:header-style><style:header-footer-properties fo:min-height=\"0mm\" fo:margin-bottom=\"" &
    formatFloat(pg.marginTop * 0.45, ffDecimal, 1) & "mm\"/></style:header-style>" &
    "<style:footer-style><style:header-footer-properties fo:min-height=\"0mm\" fo:margin-top=\"" &
    formatFloat(pg.marginBottom * 0.45, ffDecimal, 1) & "mm\"/></style:footer-style>" &
    "</style:page-layout>\n"
  var fonts = ""
  for f in b.fonts.keys:
    let generic = if isMonoFont(f): "modern" elif isSansFont(f): "swiss" else: "roman"
    fonts.add "<style:font-face style:name=\"" & x(f) & "\" svg:font-family=\"'" & x(f) &
      "'\" style:font-family-generic=\"" & generic & "\"/>\n"
  result = """<?xml version="1.0" encoding="UTF-8"?>
<office:document xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
 xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0"
 xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"
 xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0"
 xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0"
 xmlns:svg="urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0"
 xmlns:xlink="http://www.w3.org/1999/xlink"
 xmlns:dc="http://purl.org/dc/elements/1.1/"
 xmlns:meta="urn:oasis:names:tc:opendocument:xmlns:meta:1.0"
 office:version="1.3" office:mimetype="application/vnd.oasis.opendocument.text">
"""
  result.add "<office:meta><dc:title>" & x(doc.title) & "</dc:title><dc:subject>" &
    x(doc.project) & "</dc:subject><meta:generator>wdnotes</meta:generator></office:meta>\n"
  result.add "<office:font-face-decls>\n" & fonts & "</office:font-face-decls>\n"
  result.add "<office:styles><style:style style:name=\"Standard\" style:family=\"paragraph\"/>" &
    "</office:styles>\n"
  result.add "<office:automatic-styles>\n" & auto & "</office:automatic-styles>\n"
  result.add "<office:master-styles><style:master-page style:name=\"Standard\" " &
    "style:page-layout-name=\"pm1\">"
  if pg.header.len > 0:
    result.add "<style:header><text:p text:style-name=\"" & hd & "\">" & hfContent(pg.header, doc) &
      "</text:p></style:header>"
  if pg.footer.len > 0:
    result.add "<style:footer><text:p text:style-name=\"" & ft & "\">" & hfContent(pg.footer, doc) &
      "</text:p></style:footer>"
  result.add "</style:master-page></office:master-styles>\n"
  result.add "<office:body><office:text>\n" & body & "</office:text></office:body>\n</office:document>\n"

proc exportFodt*(doc: RenderDoc, path: string) =
  writeFile(path, renderFodt(doc))
