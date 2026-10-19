# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
# MarkdownView : affichage en lecture seule d'un texte Markdown, avec retour à la
# ligne automatique selon la largeur et ascenseur vertical si le texte déborde.
#
# Sous-ensemble reconnu :
#   blocs  : # titres (1 à 6), paragraphes, listes « - » et « 1. » (imbriquées par
#            l'indentation), citations « > », blocs de code ``` (ou ~~~), règles ---
#   ligne  : **gras**, *italique* (ou _italique_), `code`, [lien](url), \échappement,
#            deux espaces ou « \ » en fin de ligne = saut de ligne forcé.
#
# Molette, flèches, Page préc./suiv., Début/Fin et l'ascenseur (glisser ou cliquer
# dans la piste) font défiler ; Cmd/Ctrl+C copie le texte source. Un clic sur un
# lien émet evSelection avec l'URL dans ev.text (le contrôle ne l'ouvre pas).
#
#   let mv = parent.addChild(newMarkdownView("# Titre\n\nTexte **important**."))
#   mv.id.value = "…"   # remplace le contenu (et remonte en haut)
#   mv.appendMarkdown("- nouvelle ligne"); mv.scrollToEnd()   # sous le verrou (guarded)
import std/[strutils, unicode, tables, os, math]
import ../sdl3, colors_themes, drawing, core, controls_basic

type
  MdFont = enum
    mfBody, mfBold, mfItalic, mfBoldItalic, mfMono, mfH1, mfH2, mfH3

  BlockKind = enum
    bkPara, bkHeading, bkBullet, bkNumber, bkQuote, bkCode, bkRule

  MdBlock = object
    kind: BlockKind
    level: int          # titre : 1..6 ; élément de liste : profondeur (0 = premier niveau).
    marker: string      # liste numérotée : « 1. ».
    text: string        # source en ligne (paragraphe, titre, élément, citation).
    lines: seq[string]  # bloc de code.

  Span = object
    text, url: string
    bold, italic, code, link, brk: bool

  Atom = object
    text, url: string
    font: MdFont
    color, bg: Color    # bg.a = 0 : pas de fond (fond = `code`).
    link, brk, space: bool   # space : précédé d'un espace.

  OpKind = enum
    opText, opFill, opRound, opDot, opRing

  Op = object
    kind: OpKind
    x, y, w, h: float   # coordonnées dans le contenu (avant défilement).
    text, url: string   # url : morceau de lien (cliquable).
    font: MdFont
    color: Color

  MarkdownView* = ref object of Control
    source: string
    scrollY*: float
    padding*: float
    ops: seq[Op]
    contentH, viewH: float
    layoutKey, fontKey: string
    heights: array[MdFont, float]
    when defined(sdlttf):
      fonts: array[MdFont, TTF_Font]
      caches: array[MdFont, Table[string, tuple[tex: SDL_Texture, w, h: float]]]
    draggingBar, hoverBar: bool
    dragOffset: float
    pendingEnd: bool      # scrollToEnd demandé avant la mise en page.

const
  BarW = 10.0
  CodePad = 3.0
  StrongFonts = {mfBold, mfBoldItalic, mfH1, mfH2, mfH3}
  EscapableChars = {'!' .. '/', ':' .. '@', '[' .. '`', '{' .. '~'}
  MonoFonts = ["/System/Library/Fonts/SFNSMono.ttf", "/System/Library/Fonts/Menlo.ttc",
               "/System/Library/Fonts/Monaco.ttf",
               "C:/Windows/Fonts/CascadiaMono.ttf", "C:/Windows/Fonts/consola.ttf", "C:/Windows/Fonts/cour.ttf",
               "/usr/share/fonts/truetype/jetbrains-mono/JetBrainsMono-Regular.ttf",
               "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf", "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
               "/usr/share/fonts/dejavu-sans-mono-fonts/DejaVuSansMono.ttf",
               "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
               "/usr/share/fonts/noto/NotoSansMono-Regular.ttf",
               "/usr/share/fonts/truetype/noto/NotoSansMono-Regular.ttf"]

proc newMarkdownView*(markdown = ""): MarkdownView =
  result = MarkdownView(source: markdown, padding: 10)
  initControl(result)
  result.focusable = true

#
# Analyse : blocs
#

proc indentOf(s: string): int =
  for ch in s:
    if ch == ' ': inc result
    elif ch == '\t': result += 4
    else: break

proc isRule(t: string): bool =
  if t.len < 3 or t[0] notin {'-', '*', '_'}: return false
  for ch in t:
    if ch != t[0] and ch != ' ': return false
  t.count(t[0]) >= 3

proc listItem(line: string): tuple[ok, ordered: bool, marker, rest: string] =
  let t = line.strip(trailing = false)
  if t.len >= 2 and t[0] in {'-', '*', '+'} and t[1] == ' ':
    return (true, false, "", t[2 .. ^1])
  var i = 0
  while i < t.len and t[i] in Digits: inc i
  if i > 0 and i < 10 and i + 1 < t.len and t[i] in {'.', ')'} and t[i + 1] == ' ':
    return (true, true, t[0 .. i], t[i + 2 .. ^1])

proc joinLine(acc: var string, line: string) =
  # Ajoute une ligne source au texte d'un bloc (espace, ou saut forcé).
  var l = line.strip()
  var hard = line.endsWith("  ")
  if l.endsWith("\\") and not l.endsWith("\\\\"):
    hard = true
    l.setLen(l.len - 1)
  if l.len == 0: return
  if acc.len > 0 and acc[^1] != '\n': acc.add ' '
  acc.add l
  if hard: acc.add '\n'

proc parseBlocks(src: string): seq[MdBlock] =
  let lines = src.replace("\r\n", "\n").replace('\r', '\n').split('\n')
  var cur: MdBlock
  var isOpen = false
  var listIndents: seq[int]
  template flush() =
    if isOpen:
      cur.text = cur.text.strip()
      result.add cur
      isOpen = false
  var i = 0
  while i < lines.len:
    let line = lines[i]
    let t = line.strip()
    inc i
    if t.startsWith("```") or t.startsWith("~~~"):
      flush()
      listIndents.setLen(0)
      let fence = t[0 .. 2]
      var b = MdBlock(kind: bkCode)
      while i < lines.len and not lines[i].strip().startsWith(fence):
        b.lines.add lines[i].replace("\t", "    ")
        inc i
      inc i                      # clôture.
      result.add b
      continue
    if t.len == 0:
      flush()
      continue
    if t[0] == '#':
      var n = 0
      while n < t.len and t[n] == '#': inc n
      if n <= 6 and (n == t.len or t[n] == ' '):
        flush()
        listIndents.setLen(0)
        result.add MdBlock(kind: bkHeading, level: n, text: t[n .. ^1].strip(chars = {' ', '#'}))
        continue
    if isRule(t):
      flush()
      listIndents.setLen(0)
      result.add MdBlock(kind: bkRule)
      continue
    if t[0] == '>':
      let rest = t[1 .. ^1]
      if isOpen and cur.kind == bkQuote:
        if rest.strip().len == 0:
          if cur.text.len > 0 and cur.text[^1] != '\n': cur.text.add '\n'
        else: joinLine(cur.text, rest)
      else:
        flush()
        listIndents.setLen(0)
        cur = MdBlock(kind: bkQuote)
        joinLine(cur.text, rest)
        isOpen = true
      continue
    let li = listItem(line)
    if li.ok:
      flush()
      let ind = indentOf(line)
      while listIndents.len > 0 and listIndents[^1] > ind: listIndents.setLen(listIndents.len - 1)
      if listIndents.len == 0 or listIndents[^1] < ind: listIndents.add ind
      cur = MdBlock(kind: (if li.ordered: bkNumber else: bkBullet), level: listIndents.len - 1,
                    marker: li.marker)
      joinLine(cur.text, li.rest)
      isOpen = true
      continue
    if isOpen:
      joinLine(cur.text, line)
      continue
    listIndents.setLen(0)
    cur = MdBlock(kind: bkPara)
    joinLine(cur.text, line)
    isOpen = true
  flush()

#
# Analyse : en ligne
#

proc isWordByte(c: char): bool = c in {'a' .. 'z', 'A' .. 'Z', '0' .. '9'} or ord(c) >= 128

proc parseInline(s: string): seq[Span] =
  var buf = ""
  var bold, italic = false
  template push() =
    if buf.len > 0:
      result.add Span(text: buf, bold: bold, italic: italic)
      buf = ""
  var i = 0
  while i < s.len:
    let c = s[i]
    if c == '\\' and i + 1 < s.len and s[i + 1] in EscapableChars:
      buf.add s[i + 1]
      i += 2
      continue
    if c == '\n':
      push()
      result.add Span(brk: true)
      inc i
      continue
    if c == '`':
      var n = 0
      while i + n < s.len and s[i + n] == '`': inc n
      let fence = repeat('`', n)
      let j = s.find(fence, i + n)
      if j >= 0:
        push()
        var code = s[i + n ..< j]
        if code.len >= 2 and code[0] == ' ' and code[^1] == ' ': code = code[1 .. ^2]
        result.add Span(text: code, code: true)
        i = j + n
      else:
        buf.add fence
        i += n
      continue
    if c in {'*', '_'} and i + 1 < s.len and s[i + 1] == c:
      if bold or (i + 2 < s.len and s[i + 2] != ' ' and s.find(repeat(c, 2), i + 2) >= 0):
        push()
        bold = not bold
        i += 2
        continue
    if c in {'*', '_'}:
      let inWord = i > 0 and isWordByte(s[i - 1]) and i + 1 < s.len and isWordByte(s[i + 1])
      if not (c == '_' and inWord):
        if italic:
          push()
          italic = false
          inc i
          continue
        if i + 1 < s.len and s[i + 1] != ' ' and s.find(c, i + 1) >= 0:
          push()
          italic = true
          inc i
          continue
    if c == '[':
      let j = s.find(']', i + 1)
      if j > 0 and j + 1 < s.len and s[j + 1] == '(':
        let k = s.find(')', j + 2)
        if k > 0:
          push()
          result.add Span(text: s[i + 1 ..< j], url: s[j + 2 ..< k].strip(), link: true,
                          bold: bold, italic: italic)
          i = k + 1
          continue
    buf.add c
    inc i
  push()

#
# Polices et texte
#

proc ensureFonts(v: MarkdownView, d: Drawing, t: Theme) =
  let key = t.name & "|" & $t.fontSize & "|" & $t.textScale & "|" & t.fonts.join(";")
  if key == v.fontKey: return
  v.fontKey = key
  v.layoutKey = ""
  for f in MdFont: v.heights[f] = 0
  when defined(sdlttf):
    for f in MdFont:
      for e in v.caches[f].values: SDL_DestroyTexture(e.tex)
      v.caches[f].clear()
      if v.fonts[f] != nil:
        TTF_CloseFont(v.fonts[f])
        v.fonts[f] = nil
    var body, mono = ""
    for p in t.fonts:
      if fileExists(p):
        body = p
        break
    for p in MonoFonts:
      if fileExists(p):
        mono = p
        break
    if mono.len == 0: mono = body
    if body.len > 0:
      for f in MdFont:
        let (path, k, style) = case f
          of mfBody: (body, 1.0, 0'u32)
          of mfBold: (body, 1.0, 1'u32)
          of mfItalic: (body, 1.0, 2'u32)
          of mfBoldItalic: (body, 1.0, 3'u32)
          of mfMono: (mono, 0.93, 0'u32)
          of mfH1: (body, 1.42, 1'u32)
          of mfH2: (body, 1.2, 1'u32)
          of mfH3: (body, 1.06, 1'u32)
        let fo = TTF_OpenFont(path.cstring, cfloat(t.fontSize * k))
        if fo != nil:
          if style != 0: TTF_SetFontStyle(fo, style)
          v.fonts[f] = fo
          v.heights[f] = float(TTF_GetFontHeight(fo))
  for f in MdFont:
    if v.heights[f] <= 0: v.heights[f] = d.textHeight

proc measure(v: MarkdownView, d: Drawing, f: MdFont, s: string): float =
  if s.len == 0: return 0
  when defined(sdlttf):
    if v.fonts[f] != nil:
      var w, h: cint
      if TTF_GetStringSize(v.fonts[f], s.cstring, csize_t(s.len), addr w, addr h): return float(w)
  d.textWidth(s) + (if f in StrongFonts: 1.0 else: 0.0)

proc drawText(v: MarkdownView, d: Drawing, f: MdFont, x, y: float, s: string, c: Color) =
  if s.len == 0 or c.a == 0: return
  when defined(sdlttf):
    if v.fonts[f] != nil:
      var e = v.caches[f].getOrDefault(s)
      if e.tex == nil:
        if v.caches[f].len > 1500:
          for o in v.caches[f].values: SDL_DestroyTexture(o.tex)
          v.caches[f].clear()
        let surf = TTF_RenderText_Blended(v.fonts[f], s.cstring, csize_t(s.len),
                                          SDL_Color(r: 255, g: 255, b: 255, a: 255))
        if surf == nil: return
        let tex = SDL_CreateTextureFromSurface(d.ren, surf)
        SDL_DestroySurface(surf)
        if tex == nil: return
        var w, h: cfloat
        discard SDL_GetTextureSize(tex, addr w, addr h)
        e = (tex, float(w), float(h))
        v.caches[f][s] = e
      discard SDL_SetTextureColorMod(e.tex, c.r, c.g, c.b)
      discard SDL_SetTextureAlphaMod(e.tex, c.a)
      d.drawTexture(e.tex, rect(round(x), round(y), e.w, e.h))
      return
  # Police bitmap de secours : le gras est simulé par un second tracé décalé.
  d.text(x, y + (v.heights[f] - d.textHeight) / 2, s, c)
  if f in StrongFonts: d.text(x + 1, y + (v.heights[f] - d.textHeight) / 2, s, c)

proc splitToFit(v: MarkdownView, d: Drawing, f: MdFont, s: string, avail: float,
                preferBreak = true): tuple[head, rest: string] =
  ## Coupe `s` pour que la tête tienne dans `avail` (au moins un caractère).
  var head = ""
  for r in s.runes:
    let cand = head & $r
    if head.len > 0 and v.measure(d, f, cand) > avail: break
    head = cand
  if preferBreak and head.len < s.len:
    var cut = -1
    # De préférence après une espace, sinon après une ponctuation.
    for breakers in [{' '}, {',', ';', '/', '.', '(', '{', '[', '-', '='}]:
      for k in countdown(head.len - 2, max(1, head.len div 3)):
        if head[k] in breakers:
          cut = k
          break
      if cut > 0: break
    if cut > 0: head = head[0 .. cut]
  (head, s[head.len .. ^1].strip(trailing = false))

#
# Mise en page
#

proc spaceW(v: MarkdownView, d: Drawing, f: MdFont): float =
  # Espace de la police droite : l'italique synthétique élargit l'espace mesurée.
  let base = case f
             of mfMono, mfItalic: mfBody
             of mfBoldItalic: mfBold
             else: f
  v.measure(d, base, " ")

proc atomW(v: MarkdownView, d: Drawing, a: Atom, s: string): float =
  v.measure(d, a.font, s) + (if a.bg.a > 0: 2 * CodePad else: 0.0)

proc atomsOf(spans: seq[Span], base: MdFont, col, codeFg, codeBg, linkCol: Color): seq[Atom] =
  let heading = base in {mfH1, mfH2, mfH3}
  var pendingSpace = false
  for sp in spans:
    if sp.brk:
      result.add Atom(brk: true)
      pendingSpace = false
      continue
    if sp.code:
      result.add Atom(text: sp.text, font: mfMono, color: codeFg, bg: codeBg, space: pendingSpace)
      pendingSpace = false
      continue
    let f = if heading: base
            elif sp.bold and sp.italic: mfBoldItalic
            elif sp.bold: mfBold
            elif sp.italic: mfItalic
            else: base
    let c = if sp.link: linkCol else: col
    var w = ""
    for ch in sp.text:
      if ch in {' ', '\t'}:
        if w.len > 0:
          result.add Atom(text: w, url: sp.url, font: f, color: c, link: sp.link, space: pendingSpace)
          w = ""
        pendingSpace = true
      else: w.add ch             # sans espace avant : collé au morceau précédent (« **gras**, »).
    if w.len > 0:
      result.add Atom(text: w, url: sp.url, font: f, color: c, link: sp.link, space: pendingSpace)
      pendingSpace = false

proc flowInline(v: MarkdownView, d: Drawing, atoms: seq[Atom], x0, maxW: float,
                y: var float, gap: float): float =
  # Place les morceaux de x0 à x0 + maxW à partir de y ; y avance jusqu'au bas de
  # la dernière ligne. Renvoie la hauteur de la première ligne.
  var line: seq[tuple[a: Atom, s: string, x, w: float]]
  var cx = 0.0
  var cy = y
  var firstH = -1.0
  proc emitLine() =
    var h = v.heights[mfBody]
    for p in line: h = max(h, v.heights[p.a.font])
    for k, p in line:
      let fh = v.heights[p.a.font]
      let ty = cy + (h - fh) / 2
      if p.a.bg.a > 0:
        v.ops.add Op(kind: opRound, x: x0 + p.x, y: ty, w: p.w, h: fh, color: p.a.bg)
        v.ops.add Op(kind: opText, x: x0 + p.x + CodePad, y: ty, w: p.w, h: fh, text: p.s,
                     font: p.a.font, color: p.a.color)
      else:
        v.ops.add Op(kind: opText, x: x0 + p.x, y: ty, w: p.w, h: fh, text: p.s,
                     font: p.a.font, color: p.a.color, url: p.a.url)
      if p.a.link:
        # Soulignement continu entre les mots d'un même lien.
        var ux = x0 + p.x
        if k > 0 and line[k - 1].a.link and line[k - 1].a.url == p.a.url:
          ux = x0 + line[k - 1].x + line[k - 1].w
        v.ops.add Op(kind: opFill, x: ux, y: ty + fh - 2, w: x0 + p.x + p.w - ux, h: 1,
                     color: withAlpha(p.a.color, 160))
    if firstH < 0: firstH = h
    cy += h + gap
    line.setLen(0)
    cx = 0
  # Groupes insécables : morceaux collés, et ponctuation française (« x », a : b).
  var groups: seq[seq[Atom]]
  for a in atoms:
    var glue = groups.len > 0 and not a.brk and not groups[^1][^1].brk
    if glue and a.space:
      glue = a.text in [":", ";", "!", "?"] or a.text.startsWith("»") or groups[^1][^1].text == "«"
    if glue: groups[^1].add a
    else: groups.add @[a]
  for g in groups:
    if g[0].brk:
      emitLine()
      continue
    var gw = 0.0
    for k, a in g:
      if k > 0 and a.space: gw += v.spaceW(d, a.font)
      gw += v.atomW(d, a, a.text)
    let lead = if line.len > 0 and g[0].space: v.spaceW(d, g[0].font) else: 0.0
    if line.len > 0 and cx + lead + gw > maxW: emitLine()
    if gw <= maxW:
      if line.len > 0 and g[0].space: cx += v.spaceW(d, g[0].font)
      for k, a in g:
        if k > 0 and a.space: cx += v.spaceW(d, a.font)
        let w = v.atomW(d, a, a.text)
        line.add (a, a.text, cx, w)
        cx += w
      continue
    # Groupe plus large que la zone : coupé morceau par morceau.
    for k, a in g:
      var s = a.text
      var sp = k > 0 and a.space
      let pad = if a.bg.a > 0: 2 * CodePad else: 0.0
      while s.len > 0:
        let l = if line.len > 0 and sp: v.spaceW(d, a.font) else: 0.0
        let w = v.atomW(d, a, s)
        if cx + l + w <= maxW:
          cx += l
          line.add (a, s, cx, w)
          cx += w
          break
        let avail = maxW - cx - l - pad
        if line.len > 0 and avail < 4 * v.spaceW(d, a.font):
          emitLine()
          sp = false
          continue
        let (head, rest) = v.splitToFit(d, a.font, s, avail)
        cx += l
        let hw = v.atomW(d, a, head)
        line.add (a, head, cx, hw)
        cx += hw
        emitLine()
        s = rest
        sp = false
  if line.len > 0: emitLine()
  if firstH < 0: return v.heights[mfBody]
  y = cy - gap
  firstH

proc layout(v: MarkdownView, d: Drawing, t: Theme, width: float) =
  v.ops.setLen(0)
  let body = textColor(v, t)
  let muted = t.textSecondary
  let accent = v.style.accent.get(t.accent)
  let codeFg = mix(body, accent, if t.dark: 0.45 else: 0.62)
  let codeBg = mix(t.fieldBg, body, if t.dark: 0.12 else: 0.07)
  let blockBg = mix(t.fieldBg, body, if t.dark: 0.08 else: 0.045)
  let quoteBg = mix(t.fieldBg, accent, if t.dark: 0.10 else: 0.06)
  let bh = v.heights[mfBody]
  let gap = round(bh * 0.22)
  let para = round(bh * 0.6)
  let left = v.padding
  let maxW = max(40.0, width - 2 * v.padding)
  let blocks = parseBlocks(v.source)
  var y = v.padding
  for bi, b in blocks:
    let nextKind = if bi + 1 < blocks.len: blocks[bi + 1].kind else: bkPara
    case b.kind
    of bkHeading:
      if bi > 0: y += round(bh * (if b.level <= 1: 0.7 else: 0.45))
      let f = if b.level <= 1: mfH1 elif b.level == 2: mfH2 else: mfH3
      let col = if b.level == 2: accent elif b.level >= 4: muted else: body
      discard v.flowInline(d, atomsOf(parseInline(b.text), f, col, codeFg, codeBg, accent), left, maxW, y, gap)
      if b.level <= 2:
        y += round(bh * 0.25)
        v.ops.add Op(kind: opFill, x: left, y: y, w: maxW, h: (if b.level == 1: 2.0 else: 1.0),
                     color: (if b.level == 1: withAlpha(accent, 200) else: t.border))
        y += 2
      y += round(bh * 0.45)
    of bkPara:
      discard v.flowInline(d, atomsOf(parseInline(b.text), mfBody, body, codeFg, codeBg, accent), left, maxW, y, gap)
      y += para
    of bkBullet, bkNumber:
      let x0 = left + 18 + float(b.level) * 18
      let y0 = y
      let fh = v.flowInline(d, atomsOf(parseInline(b.text), mfBody, body, codeFg, codeBg, accent),
                            x0, maxW - (x0 - left), y, gap)
      if b.kind == bkBullet:
        let cx = x0 - 10
        let cy = y0 + fh / 2
        case b.level mod 3
        of 0: v.ops.add Op(kind: opDot, x: cx, y: cy, w: 3.0, h: 6, color: accent)
        of 1: v.ops.add Op(kind: opRing, x: cx, y: cy, w: 3.0, h: 6, color: accent)
        else: v.ops.add Op(kind: opFill, x: cx - 2, y: cy - 2, w: 4, h: 4, color: accent)
      else:
        let mw = v.measure(d, mfBold, b.marker)
        v.ops.add Op(kind: opText, x: x0 - 6 - mw, y: y0 + (fh - v.heights[mfBold]) / 2, w: mw,
                     h: v.heights[mfBold], text: b.marker, font: mfBold, color: accent)
      y += (if nextKind in {bkBullet, bkNumber}: round(bh * 0.28) else: para)
    of bkQuote:
      let idx = v.ops.len
      let top = y
      y += 6
      discard v.flowInline(d, atomsOf(parseInline(b.text), mfBody, muted, codeFg, codeBg, accent),
                           left + 14, maxW - 20, y, gap)
      y += 6
      v.ops.insert(Op(kind: opRound, x: left, y: top, w: maxW, h: y - top, color: quoteBg), idx)
      v.ops.insert(Op(kind: opFill, x: left, y: top, w: 3, h: y - top, color: withAlpha(accent, 190)), idx + 1)
      y += para
    of bkCode:
      let idx = v.ops.len
      let top = y
      let mh = v.heights[mfMono]
      let lg = round(mh * 0.15)
      let innerW = maxW - 22
      y += 8
      for ln in b.lines:
        var s = ln
        if s.strip().len == 0:
          y += mh + lg
          continue
        while s.len > 0:
          var part = s
          if v.measure(d, mfMono, s) > innerW:
            (part, s) = v.splitToFit(d, mfMono, s, innerW)
          else: s = ""
          v.ops.add Op(kind: opText, x: left + 13, y: y, w: v.measure(d, mfMono, part), h: mh,
                       text: part, font: mfMono, color: body)
          y += mh + lg
      y = y - lg + 8
      v.ops.insert(Op(kind: opRound, x: left, y: top, w: maxW, h: y - top, color: blockBg), idx)
      v.ops.insert(Op(kind: opFill, x: left, y: top, w: 3, h: y - top, color: withAlpha(accent, 150)), idx + 1)
      y += para
    of bkRule:
      y += round(para * 0.4)
      v.ops.add Op(kind: opFill, x: left, y: y, w: maxW, h: 1, color: t.border)
      y += 1 + round(para * 0.8)
  if blocks.len > 0 and blocks[^1].kind != bkHeading: y -= para
  v.contentH = y + v.padding

#
# Contrôle
#

proc viewport(v: MarkdownView): Rect = v.rect.shrink(1)

proc maxScroll(v: MarkdownView): float = max(0.0, v.contentH - v.viewH)

proc overflows(v: MarkdownView): bool = v.contentH > v.viewH + 0.5

proc barTrack(v: MarkdownView): Rect =
  let r = v.rect
  rect(r.x + r.w - BarW - 3, r.y + 3, BarW, max(0.0, r.h - 6))

proc barThumb(v: MarkdownView): Rect =
  let tr = v.barTrack
  let lp = clamp(tr.h * v.viewH / max(1.0, v.contentH), min(24.0, tr.h), tr.h)
  let ms = v.maxScroll
  let y = tr.y + (tr.h - lp) * (if ms > 0: clamp(v.scrollY / ms, 0.0, 1.0) else: 0.0)
  rect(tr.x, y, BarW, lp)

proc scrollBy(v: MarkdownView, dy: float) =
  v.scrollY = clamp(v.scrollY + dy, 0.0, v.maxScroll)

proc scrollToThumb(v: MarkdownView, thumbY: float) =
  let tr = v.barTrack
  let th = v.barThumb
  let frac = (thumbY - tr.y) / max(1.0, tr.h - th.h)
  v.scrollY = clamp(frac, 0.0, 1.0) * v.maxScroll

proc lineStep(v: MarkdownView): float = max(12.0, v.heights[mfBody] * 1.25)

proc linkAt(v: MarkdownView, x, y: float): string =
  # URL du lien sous le point (coordonnées fenêtre), "" sinon.
  let z = v.viewport
  if not z.containsPoint(x, y): return ""
  let cx = x - z.x
  let cy = y - z.y + round(v.scrollY)
  for op in v.ops:
    if op.kind == opText and op.url.len > 0 and
       rect(op.x, op.y, op.w, op.h).containsPoint(cx, cy): return op.url

# API objet (à appeler sous le verrou de wdgui : `guarded` ou `withControl`).

proc markdown*(v: MarkdownView): string = v.source

proc appendMarkdown*(v: MarkdownView, s: string) =
  # Ajoute du texte à la fin (sur une nouvelle ligne) sans changer le défilement.
  if v.source.len > 0 and not v.source.endsWith("\n"): v.source.add '\n'
  v.source.add s
  v.layoutKey = ""

proc scrollPosition*(v: MarkdownView): float = v.scrollY

proc scrollTo*(v: MarkdownView, y: float) =
  v.pendingEnd = false
  v.scrollY = max(0.0, y)        # borné au prochain dessin.

proc scrollToEnd*(v: MarkdownView) =
  v.pendingEnd = true

method typeName*(v: MarkdownView): string = "Markdown"

method valueText*(v: MarkdownView): string = v.source

method setValueText*(v: MarkdownView, s: string) =
  v.source = s
  v.scrollY = 0
  v.pendingEnd = false
  v.layoutKey = ""

method preferredSize*(v: MarkdownView, d: Drawing, t: Theme): tuple[w, h: float] =
  (220.0, t.lineHeight * 4 + 10)

method draw*(v: MarkdownView, d: Drawing, t: Theme) =
  drawFieldFrame(d, t, v, v.rect)
  v.ensureFonts(d, t)
  let z = v.viewport
  v.viewH = z.h
  let key = $z.w & "|" & $z.h & "|" & v.fontKey & "|" & t.name & "|" & $t.dark
  if key != v.layoutKey:
    v.layoutKey = key
    v.layout(d, t, z.w)
    if v.overflows: v.layout(d, t, z.w - BarW - 4)                # place réservée à l'ascenseur.
  if v.pendingEnd:
    v.scrollY = v.maxScroll
    v.pendingEnd = false
  v.scrollY = clamp(v.scrollY, 0.0, v.maxScroll)
  let ox = z.x
  let oy = z.y - round(v.scrollY)
  d.pushClip(z)
  for op in v.ops:
    let top = oy + (if op.kind in {opDot, opRing}: op.y - op.h / 2 else: op.y)
    if top > z.y + z.h or top + op.h < z.y: continue
    case op.kind
    of opText: v.drawText(d, op.font, ox + op.x, oy + op.y, op.text, op.color)
    of opFill: d.fillRect(rect(ox + op.x, oy + op.y, op.w, op.h), op.color)
    of opRound: d.fillRoundRect(rect(ox + op.x, oy + op.y, op.w, op.h), min(5.0, op.h / 2), op.color)
    of opDot: d.fillCircle(ox + op.x, oy + op.y, op.w, op.color)
    of opRing: d.strokeCircle(ox + op.x, oy + op.y, op.w + 0.5, op.color, 1.2)
  d.popClip()
  if v.overflows:
    let tr = v.barTrack
    let th = v.barThumb
    let hot = v.draggingBar or (v.hovered and v.hoverBar)
    d.fillRoundRect(tr, BarW / 2, withAlpha(t.textSecondary, if hot: 40 else: 22))
    d.fillRoundRect(th.shrink(1, 0), (BarW - 2) / 2,
                    withAlpha(t.textSecondary, if v.draggingBar: 210 elif hot: 170 else: 120))

method mouseCursor*(v: MarkdownView, x, y: float): int =
  if v.linkAt(x, y).len > 0: SDL_SYSTEM_CURSOR_POINTER else: SDL_SYSTEM_CURSOR_DEFAULT

method onWheel*(v: MarkdownView, dx, dy: float): bool =
  if not v.overflows: return false
  v.scrollBy(-dy * v.lineStep * 3)
  true

method onMouse*(v: MarkdownView, e: MouseEvent) =
  let zone = v.barTrack.shrink(-3, 0)
  case e.action
  of maPress:
    if e.button == mbLeft and v.overflows and zone.containsPoint(e.x, e.y):
      let th = v.barThumb
      if th.containsPoint(e.x, e.y): v.dragOffset = e.y - th.y
      else:
        v.dragOffset = th.h / 2
        v.scrollToThumb(e.y - v.dragOffset)
      v.draggingBar = true
    elif e.button == mbLeft:
      let url = v.linkAt(e.x, e.y)
      if url.len > 0: emit(v, evSelection, text = url)
  of maMove:
    v.hoverBar = v.overflows and zone.containsPoint(e.x, e.y)
    if v.draggingBar: v.scrollToThumb(e.y - v.dragOffset)
  of maRelease:
    v.draggingBar = false

method onKey*(v: MarkdownView, e: KeyEvent): bool =
  let cmd = (e.mods and KMOD_CMD) != 0
  case e.key
  of SDLK_UP: v.scrollBy(-v.lineStep)
  of SDLK_DOWN: v.scrollBy(v.lineStep)
  of SDLK_PAGEUP: v.scrollBy(-v.viewH * 0.9)
  of SDLK_PAGEDOWN: v.scrollBy(v.viewH * 0.9)
  of SDLK_HOME: v.scrollY = 0
  of SDLK_END: v.scrollY = v.maxScroll
  of SDLK_C:
    if not cmd: return false
    if v.source.len > 0: discard SDL_SetClipboardText(v.source.cstring)
  else: return false
  true
