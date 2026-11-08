# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
#   wdgui - Enhanced Markdown: block and segment-based parsing (layout, HTML).
#
# Blocks: headings (# … and underlined, with optional {#anchor}), paragraphs, lists (bulleted,
# numbered, checkboxes [ ] / [x], nested), blockquotes, callout boxes (> [!NOTE] / TIP / WARNING /
# IMPORTANT / CAUTION, or their equivalents), code blocks ``` (with language specification),
# tables | (with alignment :--: ), figures (an image standing alone in a paragraph, optionally
# followed by {width=60%}), horizontal rules, and composition markers:
# [[toc]] (table of contents), [[index]], [[saut]] (page break).
# Inline elements: **bold**, *italics*, `code`, [link](address), ![image](…) (alt text),
# [[i:term]] (invisible index entry), [[ref:anchor]] (cross-reference),
# ~~strikethrough~~, \ (escape character), <br>, and two spaces at the end of a line (line break).

import std/[strutils, unicode]

type
  BKind* = enum
    bkPara, bkHead, bkList, bkQuote, bkCallout, bkCode, bkTable, bkRule, bkFigure, bkToc, bkIndex, bkBreak

  MdItem* = object
    level*: int
    ordered*: bool
    marker*: string
    text*: string
    task*: int              # -1 : aucune case ; 0 : à faire ; 1 : faite

  MdBlk* = ref object
    kind*: BKind
    level*: int             # titre : 1..6
    text*: string           # source en ligne (paragraphe, titre)
    id*: string             # ancre du titre
    lang*: string           # langage du code ; genre de l'encadré
    lines*: seq[string]     # code
    items*: seq[MdItem]     # liste
    children*: seq[MdBlk]   # citation, encadré
    rows*: seq[seq[string]] # tableau (ligne 0 : en-tête)
    aligns*: seq[char]      # l, c, r
    src*, alt*, title*, width*: string   # figure

  SegKind* = enum
    skText, skBreak, skIndex, skRef

  Seg* = object
    kind*: SegKind
    text*: string
    bold*, italic*, code*, strike*: bool
    link*: string

proc slugify*(s: string): string =
  # Title anchor: lowercase letters without accents, hyphens.
  const Acc = {"à": "a", "â": "a", "ä": "a", "á": "a", "ã": "a", "ç": "c", "é": "e", "è": "e", "ê": "e",
               "ë": "e", "î": "i", "ï": "i", "í": "i", "ô": "o", "ö": "o", "ó": "o", "õ": "o", "ù": "u",
               "û": "u", "ü": "u", "ú": "u", "ÿ": "y", "ñ": "n", "œ": "oe", "æ": "ae"}
  var t = s.toLower
  for (a, b) in Acc: t = t.replace(a, b)
  var dash = false
  for ch in t:
    if ch in {'a' .. 'z', '0' .. '9'}:
      result.add ch
      dash = false
    elif not dash and result.len > 0:
      result.add '-'
      dash = true
  result = result.strip(chars = {'-'})
  if result.len == 0: result = "section"

proc sortKey*(s: string): string =
  # Alphabetical sorting key (ignoring accents and case).
  slugify(s).replace("-", " ")

proc indentOf(s: string): int =
  for ch in s:
    if ch == ' ': inc result
    elif ch == '\t': result += 4
    else: break

proc isRule(t: string): bool =
  let s = t.strip
  if s.len < 3: return false
  let c = s[0]
  if c notin {'-', '*', '_'}: return false
  var n = 0
  for ch in s:
    if ch == c: inc n
    elif ch != ' ': return false
  n >= 3

proc isTableSep(t: string): bool =
  let s = t.strip
  if s.len < 3 or '-' notin s: return false
  for ch in s:
    if ch notin {'|', '-', ':', ' '}: return false
  true

proc splitRow(t: string): seq[string] =
  var s = t.strip
  if s.startsWith("|"): s = s[1 .. ^1]
  if s.endsWith("|") and not s.endsWith("\\|"): s = s[0 ..< ^1]
  var cur = ""
  var i = 0
  var inCode = false
  while i < s.len:
    let ch = s[i]
    if ch == '\\' and i + 1 < s.len and s[i + 1] == '|':
      cur.add '|'
      i += 2
      continue
    if ch == '`': inCode = not inCode
    if ch == '|' and not inCode:
      result.add cur.strip
      cur = ""
    else: cur.add ch
    inc i
  result.add cur.strip

proc listItem(line: string): tuple[ok, ordered: bool, marker, rest: string, indent: int] =
  let ind = indentOf(line)
  let t = line.strip(trailing = false)
  if t.len >= 2 and t[0] in {'-', '*', '+'} and t[1] == ' ':
    return (true, false, $t[0], t[2 .. ^1].strip, ind)
  var k = 0
  while k < t.len and t[k].isDigit: inc k
  if k > 0 and k <= 9 and k + 1 < t.len and t[k] in {'.', ')'} and t[k + 1] == ' ':
    return (true, true, t[0 .. k], t[k + 2 .. ^1].strip, ind)
  (false, false, "", "", 0)

proc parseFigure(t: string, b: var MdBlk): bool =
  # Paragraph reduced to an image: ![alt](src "title"){width=60%}.
  let s = t.strip
  if not s.startsWith("![") : return false
  let e = s.find("](")
  if e < 0: return false
  var depth = 0
  var close = -1
  for i in e + 2 ..< s.len:
    if s[i] == '(': inc depth
    elif s[i] == ')':
      if depth == 0:
        close = i
        break
      dec depth
  if close < 0: return false
  var rest = s[close + 1 .. ^1].strip
  var width = ""
  if rest.startsWith("{") and rest.endsWith("}"):
    for kv in rest[1 ..< ^1].split({',', ' ', ';'}):
      let p = kv.split('=')
      if p.len == 2 and p[0].strip.toLowerAscii in ["largeur", "width", "l"]: width = p[1].strip
    rest = ""
  if rest.len > 0: return false
  var inner = s[e + 2 ..< close].strip
  var title = ""
  let q = inner.find(" \"")
  if q > 0 and inner.endsWith("\""):
    title = inner[q + 2 ..< ^1]
    inner = inner[0 ..< q].strip
  b = MdBlk(kind: bkFigure, alt: s[2 ..< e], src: inner, title: title, width: width)
  true

proc headingId(text: var string): string =
  # "Title {#anchor}": removes and returns the explicit anchor.
  let t = text.strip
  if t.endsWith("}"):
    let k = t.rfind("{#")
    if k >= 0:
      result = t[k + 2 ..< ^1].strip
      text = t[0 ..< k].strip
      return
  text = t

proc parseMd*(src: string): seq[MdBlk]

proc calloutKind(first: string): string =
  # « [!NOTE] » → note, tip, attention, important, caution.
  let t = first.strip.toUpperAscii
  if not (t.startsWith("[!") and "]" in t): return ""
  let k = t[2 ..< t.find(']')]
  case k
  of "NOTE", "REMARQUE", "INFO": "note"
  of "TIP", "ASTUCE", "CONSEIL": "astuce"
  of "WARNING", "ATTENTION", "AVERTISSEMENT": "attention"
  of "IMPORTANT": "important"
  of "CAUTION", "DANGER", "PRUDENCE": "danger"
  else: "note"

proc parseMd*(src: string): seq[MdBlk] =
  let lines = src.replace("\r\n", "\n").replace("\r", "\n").split('\n')
  var para: seq[string]
  var i = 0
  proc flush(res: var seq[MdBlk], para: var seq[string]) =
    if para.len == 0: return
    var text = ""
    for k, l in para:
      var x = l
      var hard = false
      if x.endsWith("  "): hard = true
      elif x.endsWith("\\") and not x.endsWith("\\\\"):
        hard = true
        x = x[0 ..< ^1]
      if text.len > 0 and not text.endsWith("\n"): text.add ' '
      text.add x.strip
      if hard and k < para.high: text.add "\n"
    var fig: MdBlk
    if para.len == 1 and parseFigure(text, fig): res.add fig
    else: res.add MdBlk(kind: bkPara, text: text)
    para.setLen(0)
  while i < lines.len:
    let line = lines[i]
    let t = line.strip
    # HTML comment
    if t.startsWith("<!--"):
      flush(result, para)
      while i < lines.len and "-->" notin lines[i]: inc i
      inc i
      continue
    if t.len == 0:
      flush(result, para)
      inc i
      continue
    # code block
    if t.startsWith("```") or t.startsWith("~~~"):
      flush(result, para)
      let fence = t[0 .. 2]
      let b = MdBlk(kind: bkCode, lang: t[3 .. ^1].strip)
      let ind = indentOf(line)
      inc i
      while i < lines.len and not lines[i].strip.startsWith(fence):
        var l = lines[i]
        if ind > 0 and indentOf(l) >= ind: l = l[ind .. ^1]
        b.lines.add l.replace("\t", "    ")
        inc i
      inc i
      result.add b
      continue
    # composition markers
    case t.toLowerAscii
    of "[[toc]]", "[[sommaire]]":
      flush(result, para); result.add MdBlk(kind: bkToc); inc i; continue
    of "[[index]]":
      flush(result, para); result.add MdBlk(kind: bkIndex); inc i; continue
    of "[[saut]]", "[[page]]", "\\pagebreak", "\\newpage":
      flush(result, para); result.add MdBlk(kind: bkBreak); inc i; continue
    else: discard
    # titres soulignés
    if para.len == 1 and t.len >= 2 and (t.allCharsInSet({'='}) or t.allCharsInSet({'-'})):
      var text = para[0].strip
      para.setLen(0)
      let id = headingId(text)
      result.add MdBlk(kind: bkHead, level: (if t[0] == '=': 1 else: 2), text: text, id: id)
      inc i
      continue
    # titles
    if t.startsWith("#"):
      var n = 0
      while n < t.len and t[n] == '#': inc n
      if n <= 6 and (n == t.len or t[n] == ' '):
        flush(result, para)
        var text = t[n .. ^1].strip.strip(leading = false, chars = {'#'}).strip
        let id = headingId(text)
        result.add MdBlk(kind: bkHead, level: n, text: text, id: id)
        inc i
        continue
    if isRule(t) and para.len == 0:
      result.add MdBlk(kind: bkRule)
      inc i
      continue
    # quotations and boxed text
    if t.startsWith(">"):
      flush(result, para)
      var inner: seq[string]
      while i < lines.len and lines[i].strip.startsWith(">"):
        var l = lines[i].strip[1 .. ^1]
        if l.startsWith(" "): l = l[1 .. ^1]
        inner.add l
        inc i
      let ck = if inner.len > 0: calloutKind(inner[0]) else: ""
      if ck.len > 0:
        let first = inner[0].strip
        let title = first[first.find(']') + 1 .. ^1].strip
        let b = MdBlk(kind: bkCallout, lang: ck, title: title)
        b.children = parseMd(inner[1 .. ^1].join("\n"))
        result.add b
      else:
        result.add MdBlk(kind: bkQuote, children: parseMd(inner.join("\n")))
      continue
    # arrays
    if '|' in t and i + 1 < lines.len and isTableSep(lines[i + 1]) and para.len == 0:
      let b = MdBlk(kind: bkTable)
      b.rows.add splitRow(t)
      for c in splitRow(lines[i + 1]):
        let cs = c.strip
        b.aligns.add(if cs.startsWith(":") and cs.endsWith(":"): 'c' elif cs.endsWith(":"): 'r' else: 'l')
      i += 2
      while i < lines.len and '|' in lines[i] and lines[i].strip.len > 0:
        b.rows.add splitRow(lines[i])
        inc i
      let n = b.rows[0].len
      for r in b.rows.mitems:
        while r.len < n: r.add ""
        if r.len > n: r.setLen(n)
      while b.aligns.len < n: b.aligns.add 'l'
      result.add b
      continue
    # lists
    let li = listItem(line)
    if li.ok and (para.len == 0 or li.indent == 0):
      flush(result, para)
      let b = MdBlk(kind: bkList)
      var indents: seq[int]
      while i < lines.len:
        let l = lines[i]
        let it = listItem(l)
        if it.ok:
          while indents.len > 0 and it.indent < indents[^1] - 1: indents.setLen(indents.len - 1)
          if indents.len == 0 or it.indent > indents[^1] + 1: indents.add it.indent
          var item = MdItem(level: indents.high, ordered: it.ordered, marker: it.marker, text: it.rest, task: -1)
          let r = item.text
          if r.startsWith("[ ] ") or r == "[ ]": item.task = 0; item.text = r[3 .. ^1].strip
          elif r.toLowerAscii.startsWith("[x] ") or r.toLowerAscii == "[x]": item.task = 1; item.text = r[3 .. ^1].strip
          b.items.add item
          inc i
        elif l.strip.len > 0 and indentOf(l) >= 2 and b.items.len > 0:
          b.items[^1].text.add " " & l.strip
          inc i
        elif l.strip.len == 0 and i + 1 < lines.len and listItem(lines[i + 1]).ok:
          inc i
        else: break
      result.add b
      continue
    para.add line
    inc i
  flush(result, para)

#
# line
#

proc parseInline*(s: string): seq[Seg] =
  var bold, italic, strike = false
  var cur = ""
  var link = ""
  var i = 0
  template push() =
    if cur.len > 0:
      result.add Seg(kind: skText, text: cur, bold: bold, italic: italic, strike: strike, link: link)
      cur = ""
  while i < s.len:
    let ch = s[i]
    if ch == '\\' and i + 1 < s.len and s[i + 1] in {'!' .. '/', ':' .. '@', '[' .. '`', '{' .. '~'}:
      cur.add s[i + 1]
      i += 2
      continue
    if ch == '\n':
      push()
      result.add Seg(kind: skBreak)
      inc i
      continue
    if s.continuesWith("<br>", i) or s.continuesWith("<br/>", i) or s.continuesWith("<br />", i):
      push()
      result.add Seg(kind: skBreak)
      i = s.find('>', i) + 1
      continue
    if ch == '`':
      var n = 0
      while i + n < s.len and s[i + n] == '`': inc n
      let close = s.find(repeat('`', n), i + n)
      if close > 0:
        push()
        result.add Seg(kind: skText, text: s[i + n ..< close].strip, code: true, bold: bold, italic: italic, link: link)
        i = close + n
        continue
    if s.continuesWith("[[", i):
      let close = s.find("]]", i + 2)
      if close > 0:
        let inner = s[i + 2 ..< close]
        let low = inner.toLowerAscii
        if low.startsWith("i:") or low.startsWith("index:"):
          push()
          result.add Seg(kind: skIndex, text: inner[inner.find(':') + 1 .. ^1].strip)
          i = close + 2
          continue
        if low.startsWith("ref:"):
          push()
          result.add Seg(kind: skRef, text: inner[4 .. ^1].strip, link: "#" & inner[4 .. ^1].strip)
          i = close + 2
          continue
    if ch == '!' and i + 1 < s.len and s[i + 1] == '[':
      let e = s.find("](", i + 2)
      let close = if e > 0: s.find(')', e) else: -1
      if e > 0 and close > 0:
        cur.add s[i + 2 ..< e]
        i = close + 1
        continue
    if ch == '[' and link.len == 0:
      # [text](address) : text being analyzed, address enclosed in balanced parentheses
      var depth = 0
      var e = -1
      for k in i + 1 ..< s.len:
        if s[k] == '[': inc depth
        elif s[k] == ']':
          if depth == 0:
            e = k
            break
          dec depth
      if e > 0 and e + 1 < s.len and s[e + 1] == '(':
        let close = s.find(')', e + 2)
        if close > 0:
          push()
          var url = s[e + 2 ..< close].strip
          let q = url.find(" \"")
          if q > 0: url = url[0 ..< q]
          let inner = parseInline(s[i + 1 ..< e])
          for sg in inner:
            var x = sg
            x.bold = x.bold or bold
            x.italic = x.italic or italic
            if x.kind == skText: x.link = url
            result.add x
          i = close + 1
          continue
    if (ch == '*' or ch == '_') and i + 1 < s.len and s[i + 1] == ch:
      push()
      bold = not bold
      i += 2
      continue
    if ch == '~' and i + 1 < s.len and s[i + 1] == '~':
      push()
      strike = not strike
      i += 2
      continue
    if ch == '*' or (ch == '_' and (i == 0 or not s[i - 1].isAlphaNumeric or italic) and
                     (italic or (i + 1 < s.len and s[i + 1] notin {' ', '\t'}))):
      # "_" in the middle of a word (variable_name) remains literal
      if ch == '_' and italic and i + 1 < s.len and s[i + 1].isAlphaNumeric:
        cur.add ch
        inc i
        continue
      if not italic and (i + 1 >= s.len or s[i + 1] == ' '):
        cur.add ch
        inc i
        continue
      push()
      italic = not italic
      inc i
      continue
    cur.add ch
    inc i
  push()

proc plainText*(s: string): string =
  ## Texte brut d'une source en ligne (titres du sommaire, signets, recherche).
  for sg in parseInline(s):
    case sg.kind
    of skText: result.add sg.text
    of skBreak: result.add ' '
    else: discard
