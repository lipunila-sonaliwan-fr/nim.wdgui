# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
#   _._
# o|- -|o  wdnotes - Markdown model
#  ( l )   Markdown parser extended with "{ instructions }" suffixes.
#    =
#
# Supported syntax (CommonMark subset + extensions):
#   # .. ######        headings              ``` / ~~~   fenced code
#   > quote             - * + 1. 1)  lists    - [ ] / - [x] tasks
#   | a | b |  tables   --- *** ___  rule     \pagebreak or <<<  page break
#   ::: tag  ... :::    styled division (custom tag)
#   **strong** *em* ~~strike~~ `code` [txt](url) ![alt](img) <http://..>
#   [[Note title]] [[Note title|label]]      wiki links between notes
#   [text]{.tag color: red}                   styled span
#   any block or inline element may be followed by { .tag key: value; ... }
#   a line containing only { ... } styles the previous block.

import std/[strutils]
import std/unicode except strip, split, splitWhitespace, align, alignLeft, cmpIgnoreCase, reversed

type
  Attrs* = object
    classes*: seq[string]
    props*: seq[(string, string)]

  InlineKind* = enum
    ikText, ikStrong, ikEm, ikStrike, ikCode, ikLink, ikWiki, ikImage, ikSpan, ikBreak

  Inline* = ref object
    kind*: InlineKind
    text*: string                # text, code, url, wiki target or image source.
    children*: seq[Inline]       # content (label of links, spans...).
    attrs*: Attrs

  BlockKind* = enum
    bkHeading, bkPara, bkQuote, bkList, bkCode, bkHr, bkTable, bkDiv, bkPageBreak

  ListItem* = object
    task*: int                   # -1 no task, 0 open, 1 done.
    blocks*: seq[Block]
    attrs*: Attrs

  Block* = ref object
    kind*: BlockKind
    level*: int                  # heading level.
    ordered*: bool
    start*: int
    items*: seq[ListItem]
    inlines*: seq[Inline]
    children*: seq[Block]        # quote / division content.
    lang*, code*: string
    rows*: seq[seq[seq[Inline]]]
    aligns*: seq[string]
    attrs*: Attrs
    line*: int                   # 0-based source line.

# attributes

proc unquote(s: string): string =
  result = s.strip
  if result.len >= 2 and result[0] in {'"', '\''} and result[^1] == result[0]:
    result = result[1 .. ^2]

proc isEmpty*(a: Attrs): bool = a.classes.len == 0 and a.props.len == 0

proc merge*(a: var Attrs, b: Attrs) =
  for c in b.classes:
    if c notin a.classes: a.classes.add c
  for p in b.props: a.props.add p

proc parseAttrs*(s: string): Attrs =
  # Parses the content of a "{ ... }" block: `.tag1 .tag2 color: #c00; size = 14; bold`.
  for part in s.split(';'):
    let p = part.strip
    if p.len == 0: continue
    let sep = p.find({':', '='})
    if sep < 0:
      for tok in p.splitWhitespace:
        if tok.startsWith('.') and tok.len > 1: result.classes.add tok[1 .. ^1].toLowerAscii
        elif tok.startsWith('#'): result.props.add(("id", tok[1 .. ^1]))
        else: result.props.add((tok.toLowerAscii, "true"))
    else:
      var toks = p[0 ..< sep].splitWhitespace
      while toks.len > 1 and toks[0].startsWith('.'):
        result.classes.add toks[0][1 .. ^1].toLowerAscii
        toks.delete(0)
      let key = toks.join(" ").toLowerAscii
      if key.len > 0: result.props.add((key, unquote(p[sep + 1 .. ^1])))

proc `$`*(a: Attrs): string =
  var parts: seq[string]
  for c in a.classes: parts.add "." & c
  for (k, v) in a.props: parts.add k & ": " & v
  "{" & parts.join("; ") & "}"

proc splitTrailingAttrs*(line: string): tuple[body, attrs: string, found: bool] =
  # "## Title {color: red}" -> ("## Title", "color: red", true).
  let s = line.strip(leading = false)
  result = (line, "", false)
  if s.len < 2 or s[^1] != '}': return
  var depth = 0
  var i = s.high
  while i >= 0:
    if s[i] == '}': inc depth
    elif s[i] == '{':
      dec depth
      if depth == 0: break
    dec i
  if i < 0: return
  if i > 0 and s[i - 1] == '\\': return
  if i == 0 or s[i - 1] in {' ', '\t'}:
    result = (s[0 ..< i].strip(leading = false), s[i + 1 .. ^2], true)

# inlines

proc isPunct(c: char): bool = c in {'!'..'/', ':'..'@', '['..'`', '{'..'~'}

proc findClose(s, delim: string, start: int): int =
  # position of the closing delimiter (not preceded by a space), -1 if none.
  var j = start
  while j < s.len:
    if s[j] == '\\': j += 2; continue
    if s[j] == '`':
      let e = s.find('`', j + 1)
      if e > 0: j = e + 1; continue
    if s.continuesWith(delim, j):
      if delim.len == 1 and j + 1 < s.len and s[j + 1] == delim[0]:
        j += 2; continue
      if j > start and s[j - 1] notin {' ', '\t', '\n'}:
        return j
    inc j
  -1

proc tryAttrs(s: string, i: var int, node: Inline) =
  if i < s.len and s[i] == '{':
    let e = s.find('}', i + 1)
    if e > i:
      node.attrs.merge parseAttrs(s[i + 1 ..< e])
      i = e + 1

proc matchBracket(s: string, start: int): int =
  # start points to '[' ; returns index of the matching ']'.
  var depth = 0
  var j = start
  while j < s.len:
    case s[j]
    of '\\': inc j
    of '[': inc depth
    of ']':
      dec depth
      if depth == 0: return j
    else: discard
    inc j
  -1

proc parseInlines*(s: string): seq[Inline] =
  var buf = ""
  var i = 0
  template flush() =
    if buf.len > 0:
      result.add Inline(kind: ikText, text: buf)
      buf = ""
  while i < s.len:
    let c = s[i]
    case c
    of '\\':
      if i + 1 < s.len and s[i + 1] == '\n':
        flush(); result.add Inline(kind: ikBreak); i += 2
      elif i + 1 < s.len and isPunct(s[i + 1]):
        buf.add s[i + 1]; i += 2
      else:
        buf.add c; inc i
    of '\n':
      if buf.endsWith("  "):
        buf.setLen(buf.len - 2)
        flush(); result.add Inline(kind: ikBreak)
      else:
        buf.add ' '
      inc i
    of '`':
      var k = 0
      while i + k < s.len and s[i + k] == '`': inc k
      let fence = repeat('`', k)
      let e = s.find(fence, i + k)
      if e < 0:
        buf.add fence; i += k
      else:
        flush()
        let node = Inline(kind: ikCode, text: s[i + k ..< e].strip)
        i = e + k
        tryAttrs(s, i, node)
        result.add node
    of '!':
      if i + 1 < s.len and s[i + 1] == '[':
        let rb = matchBracket(s, i + 1)
        if rb > 0 and rb + 1 < s.len and s[rb + 1] == '(':
          let rp = s.find(')', rb + 2)
          if rp > 0:
            flush()
            let node = Inline(kind: ikImage, text: s[rb + 2 ..< rp].strip,
                              children: @[Inline(kind: ikText, text: s[i + 2 ..< rb])])
            i = rp + 1
            tryAttrs(s, i, node)
            result.add node
            continue
      buf.add c; inc i
    of '[':
      if i + 1 < s.len and s[i + 1] == '[':
        let e = s.find("]]", i + 2)
        if e > 0:
          flush()
          let inner = s[i + 2 ..< e]
          let bar = inner.find('|')
          let target = (if bar >= 0: inner[0 ..< bar] else: inner).strip
          let label = (if bar >= 0: inner[bar + 1 .. ^1] else: inner).strip
          let node = Inline(kind: ikWiki, text: target,
                            children: @[Inline(kind: ikText, text: label)])
          i = e + 2
          tryAttrs(s, i, node)
          result.add node
          continue
      let rb = matchBracket(s, i)
      if rb > 0 and rb + 1 < s.len and s[rb + 1] == '(':
        let rp = s.find(')', rb + 2)
        if rp > 0:
          flush()
          let node = Inline(kind: ikLink, text: s[rb + 2 ..< rp].strip,
                            children: parseInlines(s[i + 1 ..< rb]))
          i = rp + 1
          tryAttrs(s, i, node)
          result.add node
          continue
      if rb > 0 and rb + 1 < s.len and s[rb + 1] == '{':
        flush()
        let node = Inline(kind: ikSpan, children: parseInlines(s[i + 1 ..< rb]))
        i = rb + 1
        tryAttrs(s, i, node)
        result.add node
        continue
      buf.add c; inc i
    of '<':
      let e = s.find('>', i + 1)
      if e > 0 and (s.continuesWith("http://", i + 1) or s.continuesWith("https://", i + 1) or
                    s.continuesWith("mailto:", i + 1)):
        flush()
        let url = s[i + 1 ..< e]
        result.add Inline(kind: ikLink, text: url, children: @[Inline(kind: ikText, text: url)])
        i = e + 1
      else:
        buf.add c; inc i
    of '*', '_', '~':
      var delim = ""
      if i + 1 < s.len and s[i + 1] == c: delim = c & c
      elif c != '~': delim = $c
      if delim.len == 0 or (c == '_' and i > 0 and s[i - 1].isAlphaNumeric):
        buf.add c; inc i; continue
      if i + delim.len >= s.len or s[i + delim.len] in {' ', '\t', '\n'}:
        buf.add delim; i += delim.len; continue
      let e = findClose(s, delim, i + delim.len)
      if e < 0:
        buf.add delim; i += delim.len; continue
      flush()
      let kind = if c == '~': ikStrike elif delim.len == 2: ikStrong else: ikEm
      let node = Inline(kind: kind, children: parseInlines(s[i + delim.len ..< e]))
      i = e + delim.len
      tryAttrs(s, i, node)
      result.add node
    of 'h':
      if (s.continuesWith("http://", i) or s.continuesWith("https://", i)) and
         (i == 0 or s[i - 1] in {' ', '\t', '\n', '('}):
        var e = i
        while e < s.len and s[e] notin {' ', '\t', '\n', ')', '<'}: inc e
        while e > i and s[e - 1] in {'.', ',', ';', ':', '!', '?'}: dec e
        flush()
        let url = s[i ..< e]
        result.add Inline(kind: ikLink, text: url, children: @[Inline(kind: ikText, text: url)])
        i = e
      else:
        buf.add c; inc i
    else:
      buf.add c; inc i
  flush()

proc plainText*(inls: seq[Inline]): string =
  for n in inls:
    case n.kind
    of ikText: result.add n.text
    of ikCode: result.add n.text
    of ikBreak: result.add ' '
    of ikWiki, ikImage, ikLink, ikStrong, ikEm, ikStrike, ikSpan:
      result.add plainText(n.children)

# blocks

proc expandTabs(s: string): string = s.replace("\t", "    ")

proc indentOf(s: string): int =
  while result < s.len and s[result] == ' ': inc result

proc isBlank(s: string): bool = s.strip.len == 0

proc headingLevel(s: string): int =
  let t = s.strip(trailing = false)
  if indentOf(s) > 3: return 0
  var n = 0
  while n < t.len and t[n] == '#': inc n
  if n in 1..6 and (n == t.len or t[n] == ' '): n else: 0

proc isHr(s: string): bool =
  let t = s.strip
  if t.len < 3 or t[0] notin {'-', '*', '_'}: return false
  var cnt = 0
  for ch in t:
    if ch == t[0]: inc cnt
    elif ch != ' ': return false
  cnt >= 3

proc isFence(s: string): tuple[ok: bool, ch: char, len: int, info: string] =
  let t = s.strip(trailing = false)
  if indentOf(s) > 3 or t.len < 3 or t[0] notin {'`', '~'}: return
  var n = 0
  while n < t.len and t[n] == t[0]: inc n
  if n >= 3: result = (true, t[0], n, t[n .. ^1].strip)

proc isPageBreak(s: string): bool =
  let t = s.strip
  t in ["\\pagebreak", "\\newpage", "<<<", "\\saut"]

proc isDivOpen(s: string): bool =
  let t = s.strip
  t.startsWith(":::") and t.strip(chars = {':', ' '}).len > 0

proc isDivClose(s: string): bool = s.strip == ":::"

proc isQuote(s: string): bool = indentOf(s) <= 3 and s.strip(trailing = false).startsWith(">")

type Marker = tuple[ok, ordered: bool, num, indent, width: int]

proc listMarker(s: string): Marker =
  let ind = indentOf(s)
  if ind >= s.len: return
  let t = s[ind .. ^1]
  if t.len >= 2 and t[0] in {'-', '*', '+'} and t[1] == ' ':
    return (true, false, 0, ind, ind + 2)
  if t == "-" or t == "*" or t == "+":
    return (true, false, 0, ind, ind + 1)
  var n = 0
  while n < t.len and n < 9 and t[n].isDigit: inc n
  if n > 0 and n + 1 < t.len and t[n] in {'.', ')'} and t[n + 1] == ' ':
    return (true, true, parseInt(t[0 ..< n]), ind, ind + n + 2)

proc splitRow(s: string): seq[string] =
  var t = s.strip
  if t.startsWith('|'): t = t[1 .. ^1]
  if t.endsWith('|') and not t.endsWith("\\|"): t = t[0 .. ^2]
  var cur = ""
  var i = 0
  while i < t.len:
    if t[i] == '\\' and i + 1 < t.len and t[i + 1] == '|':
      cur.add '|'; i += 2; continue
    if t[i] == '|':
      result.add cur.strip; cur = ""
    else: cur.add t[i]
    inc i
  result.add cur.strip

proc isTableSep(s: string): bool =
  if '-' notin s: return false
  let cells = splitRow(s)
  if cells.len == 0: return false
  for c in cells:
    let x = c.strip(chars = {':', ' '})
    if x.len == 0: return false
    for ch in x:
      if ch != '-': return false
  true

proc startsBlock(lines: seq[string], i: int): bool =
  let s = lines[i]
  headingLevel(s) > 0 or isHr(s) or isFence(s).ok or isQuote(s) or
    listMarker(s).ok or isPageBreak(s) or isDivOpen(s) or isDivClose(s) or
    ('|' in s and i + 1 < lines.len and isTableSep(lines[i + 1]))

proc standaloneAttrs(s: string): (bool, string) =
  let t = s.strip
  if t.len >= 2 and t[0] == '{' and t[^1] == '}' and t.find('}') == t.high:
    return (true, t[1 .. ^2])
  (false, "")

proc parseBlocks*(src: seq[string], baseLine = 0): seq[Block] =
  var lines = newSeq[string](src.len)
  for k, l in src: lines[k] = expandTabs(l)
  var i = 0
  let n = lines.len
  while i < n:
    let s = lines[i]
    if isBlank(s): inc i; continue
    let (isAttr, attrTxt) = standaloneAttrs(s)
    if isAttr:
      if result.len > 0: result[^1].attrs.merge parseAttrs(attrTxt)
      inc i; continue
    if isPageBreak(s):
      result.add Block(kind: bkPageBreak, line: baseLine + i)
      inc i; continue
    let fence = isFence(s)
    if fence.ok:
      var b = Block(kind: bkCode, line: baseLine + i)
      let (info, at, found) = splitTrailingAttrs(fence.info)
      b.lang = info.strip
      if found: b.attrs = parseAttrs(at)
      var code: seq[string]
      inc i
      while i < n:
        let f = isFence(lines[i])
        if f.ok and f.ch == fence.ch and f.len >= fence.len and f.info.len == 0:
          inc i; break
        code.add lines[i]
        inc i
      b.code = code.join("\n")
      result.add b
      continue
    let lvl = headingLevel(s)
    if lvl > 0:
      let (body, at, found) = splitTrailingAttrs(s.strip)
      var t = body.strip(chars = {'#', ' '}, leading = true, trailing = false)
      t = t.strip(chars = {' '})
      while t.endsWith('#') and (t.len == 1 or t[^2] == ' '): t = t.strip(chars = {'#', ' '}, leading = false)
      var b = Block(kind: bkHeading, level: lvl, inlines: parseInlines(t), line: baseLine + i)
      if found: b.attrs = parseAttrs(at)
      result.add b
      inc i; continue
    if isHr(splitTrailingAttrs(s).body) and not listMarker(s).ok or isHr(s):
      let (_, at, found) = splitTrailingAttrs(s)
      var b = Block(kind: bkHr, line: baseLine + i)
      if found: b.attrs = parseAttrs(at)
      result.add b
      inc i; continue
    if isDivOpen(s):
      let (body, at, found) = splitTrailingAttrs(s.strip)
      let name = body.strip(chars = {':', ' '})
      var b = Block(kind: bkDiv, line: baseLine + i)
      for tok in name.splitWhitespace:
        b.attrs.classes.add tok.strip(chars = {'.'}).toLowerAscii
      if found: b.attrs.merge parseAttrs(at)
      var inner: seq[string]
      var depth = 1
      let start = i + 1
      inc i
      while i < n:
        if isDivOpen(lines[i]): inc depth
        elif isDivClose(lines[i]):
          dec depth
          if depth == 0: inc i; break
        inner.add lines[i]
        inc i
      b.children = parseBlocks(inner, baseLine + start)
      result.add b
      continue
    if isQuote(s):
      var inner: seq[string]
      let start = i
      while i < n and not isBlank(lines[i]):
        var t = lines[i].strip(trailing = false)
        if t.startsWith(">"):
          t = t[1 .. ^1]
          if t.startsWith(" "): t = t[1 .. ^1]
        elif startsBlock(lines, i): break
        inner.add t
        inc i
      result.add Block(kind: bkQuote, children: parseBlocks(inner, baseLine + start),
                       line: baseLine + start)
      continue
    let mk = listMarker(s)
    if mk.ok:
      var b = Block(kind: bkList, ordered: mk.ordered, start: max(mk.num, 1), line: baseLine + i)
      while i < n:
        let m = listMarker(lines[i])
        if not m.ok or m.ordered != mk.ordered or m.indent > mk.indent + 1 or
           m.indent + 1 < mk.indent: break
        var item = ListItem(task: -1)
        var first = if m.width <= lines[i].len: lines[i][m.width .. ^1] else: ""
        if first.startsWith("[ ] ") or first == "[ ]":
          item.task = 0
          first = first.substr(4)
        elif first.toLowerAscii.startsWith("[x] ") or first.toLowerAscii == "[x]":
          item.task = 1
          first = first.substr(4)
        let (fb, fat, ffound) = splitTrailingAttrs(first)
        if ffound:
          item.attrs = parseAttrs(fat)
          first = fb
        var content = @[first]
        let itemLine = i
        inc i
        while i < n:
          let l = lines[i]
          if isBlank(l):
            if i + 1 < n and not isBlank(lines[i + 1]) and indentOf(lines[i + 1]) > m.indent and
               indentOf(lines[i + 1]) >= min(m.width, m.indent + 2):
              content.add ""
              inc i; continue
            break
          let ind = indentOf(l)
          if ind > m.indent:
            content.add l[min(ind, m.width) .. ^1]
            inc i; continue
          if not startsBlock(lines, i) and not isBlank(content[^1]):
            content.add l.strip  # lazy continuation.
            inc i; continue
          break
        item.blocks = parseBlocks(content, baseLine + itemLine)
        b.items.add item
        while i < n and isBlank(lines[i]) and i + 1 < n and listMarker(lines[i + 1]).ok and
              listMarker(lines[i + 1]).indent == mk.indent:
          inc i
      result.add b
      continue
    if '|' in s and i + 1 < n and isTableSep(lines[i + 1]):
      var b = Block(kind: bkTable, line: baseLine + i)
      let (hb, hat, hfound) = splitTrailingAttrs(s)
      if hfound: b.attrs = parseAttrs(hat)
      var header: seq[seq[Inline]]
      for c in splitRow(hb): header.add parseInlines(c)
      b.rows.add header
      for c in splitRow(lines[i + 1]):
        let x = c.strip
        b.aligns.add(if x.startsWith(':') and x.endsWith(':'): "center"
                     elif x.endsWith(':'): "right" else: "left")
      i += 2
      while i < n and not isBlank(lines[i]) and '|' in lines[i]:
        var row: seq[seq[Inline]]
        for c in splitRow(lines[i]): row.add parseInlines(c)
        while row.len < header.len: row.add @[]
        b.rows.add row
        inc i
      result.add b
      continue
    # paragraph
    var para: seq[string]
    let start = i
    while i < n and not isBlank(lines[i]):
      if para.len > 0 and (startsBlock(lines, i) or standaloneAttrs(lines[i])[0]): break
      para.add lines[i].strip(trailing = false)
      inc i
    var b = Block(kind: bkPara, line: baseLine + start)
    let (lb, lat, lfound) = splitTrailingAttrs(para[^1])
    if lfound:
      b.attrs = parseAttrs(lat)
      para[^1] = lb
    b.inlines = parseInlines(para.join("\n"))
    result.add b

proc parseMarkdown*(text: string): seq[Block] =
  parseBlocks(text.replace("\r\n", "\n").split('\n'))

# helpers

proc wikiTargets*(text: string): seq[string] =
  # every [[target]] or [[target|label]] outside fenced code.
  var inCode = false
  for line in text.splitLines:
    if isFence(line).ok: inCode = not inCode; continue
    if inCode: continue
    var p = 0
    while true:
      let a = line.find("[[", p)
      if a < 0: break
      let b = line.find("]]", a + 2)
      if b < 0: break
      var t = line[a + 2 ..< b]
      let bar = t.find('|')
      if bar >= 0: t = t[0 ..< bar]
      t = t.strip
      if t.len > 0: result.add t
      p = b + 2

proc excerpt*(text: string, maxRunes = 280): string =
  # first meaningful lines of a note, without markup.
  var parts: seq[string]
  var inCode = false
  for line in text.splitLines:
    if isFence(line).ok: inCode = not inCode; continue
    if inCode or isBlank(line): continue
    var l = splitTrailingAttrs(line).body.strip
    if standaloneAttrs(l)[0] or isHr(l) or isDivOpen(l) or isDivClose(l) or isPageBreak(l): continue
    l = l.strip(chars = {'#', '>', ' '})
    let mk = listMarker(l)
    if mk.ok: l = "• " & l[min(mk.width, l.len) .. ^1]
    l = plainText(parseInlines(l))
    if l.len > 0: parts.add l
    if parts.join(" ").runeLen >= maxRunes: break
  result = parts.join(" ")
  if result.runeLen > maxRunes:
    result = $result.toRunes[0 ..< maxRunes] & "…"
