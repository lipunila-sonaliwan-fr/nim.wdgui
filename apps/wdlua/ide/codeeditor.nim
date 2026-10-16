# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
# Portage pour wdlua de l'éditeur de wdnim (CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026).
#
# Un seul contrôle wdgui :
# * une barre d'onglets (un par document, point de modification, case de fermeture) ;
# * une colonne de numéros de ligne, avec points d'arrêt et ligne d'exécution du débogueur ;
# * un diagramme de structure (CSD) des blocs Lua dans la marge ;
# * le code coloré (lualang via luatok), ligne courante, sélection, diagnostics ;
# * une minicarte.
#
# Adaptations à Lua : coloration, CSD (function / if / for / while / repeat / do),
# commentaires « -- », indentation automatique, complétion à partir des paquets
# enregistrés (langdocs), points d'arrêt et ligne d'exécution.
# Les procédures `editor...` en fin de fichier sont sûres entre threads
# (withControl / readControl de wdgui) et identifient les documents par un uid.
#
# Signaux émis (evSelection, ev.text) : "pos:L:C", "doc:UID", "bp:UID",
# "cmd:<nom>[:arg]" ; evChange (ev.text = "edit") quand le texte change.
import std/[strutils, unicode, tables, os, math, sequtils, streams, sets, algorithm]
import sdl3
import wdgui
import luatok, langdocs, lualint
import compat except KHome, KEnd
from lualang import Keywords
from lsptypes import CompletionItem, kindBadge

type
  Snapshot = object
    lines: seq[string]
    line, col: int

  CsdKind* = enum
    cbRoutine, cbIf, cbWhen, cbCase, cbLoop, cbTry, cbBlock, cbSection

  CsdBlock* = object
    kind*: CsdKind
    first*, last*: int           # header line, last line of the body.
    level*: int
    branches*: seq[int]          # elif / else / of / except / finally lines.

  Document* = ref object
    uid*: int                    # identifiant stable (API).
    bps*: HashSet[int]           # points d'arrêt (lignes 0-based).
    execLine*: int               # ligne d'exécution du débogueur, -1 sinon.
    version*: int                # incrémenté à chaque modification.
    savedVersion*: int
    lastLen: int                 # nombre de lignes avant la dernière modification.
    path*: string
    title*: string
    lines*: seq[string]
    line*, col*: int             # cursor (col = byte offset).
    ancLine*, ancCol*: int       # selection anchor.
    scroll*: float               # first visible line.
    scrollX*: float
    modified*: bool
    undoStack, redoStack: seq[Snapshot]
    lastWasTyping: bool
    wantCol: int
    tokens: seq[seq[Token]]
    csd: seq[CsdBlock]
    maxLevel: int
    analyzed: bool
    diags*: seq[Diagnostic]      # diagnostics de lualint (colonnes en octets).

  EditorColors = object
    bg, gutter, gutterText, gutterMajor, currentLine, selection, caret, tabBar, tabActive,
      tabText, tabTextActive, minimapBg, minimapView, separator: Color
    tok: array[TokKind, Color]
    csd: array[CsdKind, Color]

  CompletionState = object
    active: bool
    items: seq[CompletionItem]
    shown: seq[int]
    selected, scroll: int
    line, startCol: int

  CodeEditor* = ref object of Control
    docs*: seq[Document]
    current*: int
    showMinimap*, showCsd*: bool
    fontSize*: float
    pending: seq[string]         # commands that must run on the UI thread (clipboard...).
    charW, lineH: float
    fontReady: bool
    when defined(sdlttf):
      font: TTF_Font
      cache: Table[string, tuple[tex: SDL_Texture, w, h: float]]
    dragging, draggingMini: bool
    hoverTab, hoverClose: int
    untitledCount: int
    comp: CompletionState        # completion popup.
    compRect: Rect
    infoText: string             # hover / signature bubble.
    suppressSpace: bool
    projectNames*: seq[string]   # symboles du projet pour la complétion.
    clipText: string             # texte à copier (commande "setClipboard").


const ImageExts = [
  ".png", ".jpg", ".jpeg",
  ".gif", ".bmp", ".webp",
  ".tif", ".tiff", ".ico",
  ".avif"
]

const
  tabBarH = 34.0
  levelW = 10.0
  minimapW = 118.0
  monoFonts = ["/System/Library/Fonts/SFNSMono.ttf", "/System/Library/Fonts/Menlo.ttc",
               "/System/Library/Fonts/Monaco.ttf",
               "C:/Windows/Fonts/CascadiaMono.ttf", "C:/Windows/Fonts/consola.ttf", "C:/Windows/Fonts/cour.ttf",
               "/usr/share/fonts/truetype/jetbrains-mono/JetBrainsMono-Regular.ttf",
               "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf", "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
               "/usr/share/fonts/dejavu-sans-mono-fonts/DejaVuSansMono.ttf",
               "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
               "/usr/share/fonts/noto/NotoSansMono-Regular.ttf",
               "/usr/share/fonts/truetype/noto/NotoSansMono-Regular.ttf"]

when defined(macosx):
  const wordMod = KMOD_ALT
else:
  const wordMod = KMOD_CTRL

const
  SDLK_D = 0x64'u32
  SDLK_Y = 0x79'u32
  SDLK_Z = 0x7A'u32
  SDLK_SLASH = 0x2F'u32

# colors

proc colorsFor(t: Theme): EditorColors =
  if t.dark:
    result = EditorColors(bg: hex"#1E1F22", gutter: hex"#1E1F22", gutterText: hex"#4B4F57",
      gutterMajor: hex"#8C9099", currentLine: hex"#26282E", selection: hex"#214283",
      caret: hex"#FFC200", tabBar: hex"#2B2D30", tabActive: hex"#1E1F22", tabText: hex"#8C9099",
      tabTextActive: hex"#E6E8EC", minimapBg: hex"#1B1C1F", minimapView: hex"#FFFFFF1C",
      separator: hex"#393B40")
    result.tok = [hex"#D4D7DD", hex"#C678DD", hex"#E5C07B", hex"#56B6C2", hex"#61AFEF",
                  hex"#98C379", hex"#D19A66", hex"#6C7280", hex"#7FA37F", hex"#56B6C2",
                  hex"#ABB2BF", hex"#9DA5B4"]
    result.csd = [hex"#61AFEF", hex"#E5C07B", hex"#E5C07B", hex"#D19A66", hex"#98C379",
                  hex"#E06C75", hex"#ABB2BF", hex"#C678DD"]
  else:
    result = EditorColors(bg: hex"#FFFFFF", gutter: hex"#FAFAFA", gutterText: hex"#B0B4BA",
      gutterMajor: hex"#5F6368", currentLine: hex"#F5F8FE", selection: hex"#ADD6FF",
      caret: hex"#1B1B1B", tabBar: hex"#EEF0F3", tabActive: hex"#FFFFFF", tabText: hex"#6B6F76",
      tabTextActive: hex"#1B1B1B", minimapBg: hex"#F7F7F8", minimapView: hex"#0000001A",
      separator: hex"#E1E3E6")
    result.tok = [hex"#24292E", hex"#A626A4", hex"#C18401", hex"#0184BC", hex"#4078F2",
                  hex"#50A14F", hex"#986801", hex"#A0A1A7", hex"#6F8F6F", hex"#0184BC",
                  hex"#383A42", hex"#696C77"]
    result.csd = [hex"#4078F2", hex"#C18401", hex"#C18401", hex"#986801", hex"#50A14F",
                  hex"#E45649", hex"#696C77", hex"#A626A4"]

# analysis (tokens + CSD)

proc leadingSpaces(s: string): int =
  while result < s.len and s[result] == ' ': inc result

proc firstWord(s: string, from0: int): string =
  var i = from0
  while i < s.len and (s[i].isAlphaNumeric or s[i] == '_'): inc i
  s[from0 ..< i]

proc computeCsd(lines: seq[string], toks: seq[seq[Token]], maxLevel: var int): seq[CsdBlock] =
  ## Blocs Lua : function, if/elseif/else, for, while, repeat/until, do.
  ## Les formes courtes « if (c) instr » et « while (c) instr » n'ouvrent pas de bloc.
  var stack: seq[int]
  maxLevel = 0
  for i, line in lines:
    let ts = toks[i]
    var kws: seq[string]
    for t in ts:
      if t.kind == tkKeyword: kws.add line[t.start ..< t.start + t.len]
    for k, w in kws:
      case w
      of "function", "repeat":
        result.add CsdBlock(kind: (if w == "function": cbRoutine else: cbLoop), first: i, last: i, level: stack.len)
        maxLevel = max(maxLevel, stack.len)
        stack.add result.high
      of "if":
        if "then" in kws[k .. ^1]:
          result.add CsdBlock(kind: cbIf, first: i, last: i, level: stack.len)
          maxLevel = max(maxLevel, stack.len)
          stack.add result.high
      of "for", "while":
        if w == "for" or "do" in kws[k .. ^1]:
          result.add CsdBlock(kind: cbLoop, first: i, last: i, level: stack.len)
          maxLevel = max(maxLevel, stack.len)
          stack.add result.high
      of "do":
        # « do » d'une boucle déjà ouverte sur la ligne : rien ; sinon bloc do ... end
        if not ("for" in kws[0 ..< k] or "while" in kws[0 ..< k]) and
           not (stack.len > 0 and result[stack[^1]].kind == cbLoop and result[stack[^1]].first < i and
                result[stack[^1]].last == result[stack[^1]].first and
                (lines[result[stack[^1]].first].contains("for") or lines[result[stack[^1]].first].contains("while"))):
          result.add CsdBlock(kind: cbBlock, first: i, last: i, level: stack.len)
          maxLevel = max(maxLevel, stack.len)
          stack.add result.high
      of "elseif", "else":
        if stack.len > 0 and result[stack[^1]].kind == cbIf: result[stack[^1]].branches.add i
      of "end", "until":
        if stack.len > 0:
          let top = stack.pop()
          result[top].last = i
      else: discard
  while stack.len > 0:
    let top = stack.pop()
    result[top].last = max(result[top].first, lines.high)

proc analyze(doc: Document) =
  if doc.analyzed: return
  var state = lsNormal
  var depth = 0
  doc.tokens.setLen(doc.lines.len)
  for i, l in doc.lines: doc.tokens[i] = lexLine(l, state, depth)
  doc.csd = computeCsd(doc.lines, doc.tokens, doc.maxLevel)
  doc.analyzed = true

# document editing primitives

var docUidCounter: int

proc newDocument*(title: string, text = "", path = ""): Document =
  inc docUidCounter
  result = Document(title: title, path: path, uid: docUidCounter, execLine: -1, bps: initHashSet[int]())
  result.lines = text.replace("\r\n", "\n").replace("\t", "  ").split('\n')
  if result.lines.len == 0: result.lines = @[""]
  result.lastLen = result.lines.len

proc text*(doc: Document): string = doc.lines.join("\n")

proc clampCursor(doc: Document) =
  doc.line = clamp(doc.line, 0, doc.lines.high)
  doc.col = clamp(doc.col, 0, doc.lines[doc.line].len)
  doc.ancLine = clamp(doc.ancLine, 0, doc.lines.high)
  doc.ancCol = clamp(doc.ancCol, 0, doc.lines[doc.ancLine].len)

proc hasSelection*(doc: Document): bool = doc.line != doc.ancLine or doc.col != doc.ancCol

proc selectionRange(doc: Document): tuple[l1, c1, l2, c2: int] =
  if doc.ancLine < doc.line or (doc.ancLine == doc.line and doc.ancCol <= doc.col):
    (doc.ancLine, doc.ancCol, doc.line, doc.col)
  else:
    (doc.line, doc.col, doc.ancLine, doc.ancCol)

proc selectedText*(doc: Document): string =
  let r = doc.selectionRange
  if r.l1 == r.l2: return doc.lines[r.l1][r.c1 ..< r.c2]
  result = doc.lines[r.l1][r.c1 .. ^1]
  for l in r.l1 + 1 ..< r.l2: result.add "\n" & doc.lines[l]
  result.add "\n" & doc.lines[r.l2][0 ..< r.c2]

proc collapse(doc: Document) =
  doc.ancLine = doc.line
  doc.ancCol = doc.col

proc shiftBreakpoints(doc: Document) =
  ## Décale les points d'arrêt quand des lignes ont été insérées ou supprimées
  ## (la modification a eu lieu autour de la ligne du curseur).
  let delta = doc.lines.len - doc.lastLen
  doc.lastLen = doc.lines.len
  if delta == 0 or doc.bps.len == 0: return
  var nb = initHashSet[int]()
  let pivot = if delta > 0: doc.line - delta else: doc.line
  for l in doc.bps:
    if l <= pivot: nb.incl l
    elif delta < 0 and l <= pivot - delta: discard
    else: nb.incl l + delta
  doc.bps = nb

proc changed(doc: Document) =
  doc.modified = true
  doc.analyzed = false
  doc.redoStack.setLen(0)
  inc doc.version
  doc.shiftBreakpoints()

proc pushUndo(doc: Document, typing = false) =
  if typing and doc.lastWasTyping and doc.undoStack.len > 0: return
  doc.undoStack.add Snapshot(lines: doc.lines, line: doc.line, col: doc.col)
  if doc.undoStack.len > 300: doc.undoStack.delete(0)
  doc.lastWasTyping = typing

proc deleteSelection(doc: Document) =
  if not doc.hasSelection: return
  let r = doc.selectionRange
  let head = doc.lines[r.l1][0 ..< r.c1]
  let tail = doc.lines[r.l2][r.c2 .. ^1]
  doc.lines[r.l1] = head & tail
  if r.l2 > r.l1: doc.lines.delete(r.l1 + 1 .. r.l2)
  doc.line = r.l1
  doc.col = r.c1
  doc.collapse()
  doc.changed()

proc insertText(doc: Document, s: string) =
  doc.deleteSelection()
  let parts = s.replace("\r\n", "\n").replace("\t", "  ").split('\n')
  let cur = doc.lines[doc.line]
  let head = cur[0 ..< doc.col]
  let tail = cur[doc.col .. ^1]
  if parts.len == 1:
    doc.lines[doc.line] = head & parts[0] & tail
    doc.col += parts[0].len
  else:
    doc.lines[doc.line] = head & parts[0]
    for k in 1 ..< parts.high:
      doc.lines.insert(parts[k], doc.line + k)
    doc.lines.insert(parts[^1] & tail, doc.line + parts.high)
    doc.line += parts.high
    doc.col = parts[^1].len
  doc.collapse()
  doc.changed()

proc undo(doc: Document) =
  if doc.undoStack.len == 0: return
  doc.redoStack.add Snapshot(lines: doc.lines, line: doc.line, col: doc.col)
  let s = doc.undoStack.pop()
  doc.lines = s.lines
  doc.line = s.line
  doc.col = s.col
  doc.clampCursor()
  doc.collapse()
  doc.modified = true
  doc.analyzed = false
  doc.lastWasTyping = false
  inc doc.version
  doc.lastLen = doc.lines.len

proc redo(doc: Document) =
  if doc.redoStack.len == 0: return
  doc.undoStack.add Snapshot(lines: doc.lines, line: doc.line, col: doc.col)
  let s = doc.redoStack.pop()
  doc.lines = s.lines
  doc.line = s.line
  doc.col = s.col
  doc.clampCursor()
  doc.collapse()
  doc.modified = true
  doc.analyzed = false
  doc.lastWasTyping = false
  inc doc.version
  doc.lastLen = doc.lines.len

proc prevRuneStart(s: string, i: int): int =
  result = max(0, i - 1)
  while result > 0 and (uint8(s[result]) and 0xC0'u8) == 0x80'u8: dec result

proc nextRuneStart(s: string, i: int): int =
  result = min(s.len, i + 1)
  while result < s.len and (uint8(s[result]) and 0xC0'u8) == 0x80'u8: inc result

proc runeCol(s: string, byteCol: int): int = s[0 ..< min(byteCol, s.len)].runeLen

proc byteCol(s: string, runeCol: int): int =
  var n = 0
  while result < s.len and n < runeCol:
    result = nextRuneStart(s, result)
    inc n

proc isWordChar(c: char): bool = c.isAlphaNumeric or c == '_' or ord(c) >= 128

proc wordLeft(doc: Document) =
  if doc.col == 0:
    if doc.line > 0:
      dec doc.line
      doc.col = doc.lines[doc.line].len
    return
  let s = doc.lines[doc.line]
  var i = doc.col
  while i > 0 and not s[i - 1].isWordChar: dec i
  while i > 0 and s[i - 1].isWordChar: dec i
  doc.col = i

proc wordRight(doc: Document) =
  let s = doc.lines[doc.line]
  if doc.col >= s.len:
    if doc.line < doc.lines.high:
      inc doc.line
      doc.col = 0
    return
  var i = doc.col
  while i < s.len and not s[i].isWordChar: inc i
  while i < s.len and s[i].isWordChar: inc i
  doc.col = i

proc selectedLines(doc: Document): tuple[a, b: int] =
  let r = doc.selectionRange
  var b = r.l2
  if r.l2 > r.l1 and r.c2 == 0: dec b
  (r.l1, b)

proc indentLines(doc: Document, dedent: bool) =
  doc.pushUndo()
  let (a, b) = doc.selectedLines
  for l in a .. b:
    if dedent:
      let n = min(2, leadingSpaces(doc.lines[l]))
      doc.lines[l] = doc.lines[l][n .. ^1]
      if l == doc.line: doc.col = max(0, doc.col - n)
      if l == doc.ancLine: doc.ancCol = max(0, doc.ancCol - n)
    elif doc.lines[l].len > 0:
      doc.lines[l] = "  " & doc.lines[l]
      if l == doc.line: doc.col += 2
      if l == doc.ancLine: doc.ancCol += 2
  doc.changed()

proc toggleComment(doc: Document) =
  doc.pushUndo()
  let (a, b) = doc.selectedLines
  var allCommented = true
  var minInd = high(int)
  for l in a .. b:
    let s = doc.lines[l]
    let ind = leadingSpaces(s)
    if ind >= s.len: continue
    minInd = min(minInd, ind)
    if not s[ind .. ^1].startsWith("--"): allCommented = false
  if minInd == high(int): return
  for l in a .. b:
    let s = doc.lines[l]
    let ind = leadingSpaces(s)
    if ind >= s.len: continue
    if allCommented:
      let n = if ind + 2 < s.len and s[ind + 2] == ' ': 3 else: 2
      doc.lines[l] = s[0 ..< ind] & s[ind + n .. ^1]
    else:
      doc.lines[l] = s[0 ..< minInd] & "-- " & s[minInd .. ^1]
  doc.clampCursor()
  doc.changed()

proc duplicateLine(doc: Document) =
  doc.pushUndo()
  let (a, b) = doc.selectedLines
  let block0 = doc.lines[a .. b]
  for k, l in block0: doc.lines.insert(l, b + 1 + k)
  doc.line += block0.len
  doc.ancLine += block0.len
  doc.changed()

proc newline(doc: Document) =
  doc.pushUndo()
  let cur = doc.lines[doc.line]
  var ind = leadingSpaces(cur)
  if doc.col < ind: ind = doc.col
  let before = cur[0 ..< doc.col].strip(leading = false)
  let bs = before.strip
  var opens = bs.endsWith(" then") or bs == "then" or bs.endsWith(" do") or bs == "do" or
              bs == "else" or bs == "repeat" or bs.endsWith("{") or bs.endsWith("(") or
              (bs.contains("function") and bs.endsWith(")"))
  if bs.startsWith("--"): opens = false
  if opens: ind += 2
  doc.insertText("\n" & spaces(ind))

proc backspace(doc: Document) =
  doc.pushUndo()
  if doc.hasSelection:
    doc.deleteSelection()
    return
  if doc.col == 0:
    if doc.line == 0: return
    let prev = doc.lines[doc.line - 1]
    doc.lines[doc.line - 1] = prev & doc.lines[doc.line]
    doc.lines.delete(doc.line)
    dec doc.line
    doc.col = prev.len
  else:
    let s = doc.lines[doc.line]
    var start = prevRuneStart(s, doc.col)
    if s[0 ..< doc.col].strip.len == 0:                           # inside the indentation: back to a tab stop.
      start = max(0, (doc.col - 1) div 2 * 2)
    doc.lines[doc.line] = s[0 ..< start] & s[doc.col .. ^1]
    doc.col = start
  doc.collapse()
  doc.changed()

proc deleteForward(doc: Document) =
  doc.pushUndo()
  if doc.hasSelection:
    doc.deleteSelection()
    return
  let s = doc.lines[doc.line]
  if doc.col >= s.len:
    if doc.line < doc.lines.high:
      doc.lines[doc.line] = s & doc.lines[doc.line + 1]
      doc.lines.delete(doc.line + 1)
  else:
    doc.lines[doc.line] = s[0 ..< doc.col] & s[nextRuneStart(s, doc.col) .. ^1]
  doc.changed()

# find / replace in a document.

proc sameText(a, b: string, matchCase: bool): bool =
  if matchCase: a == b else: cmpIgnoreCase(a, b) == 0

proc findNext*(doc: Document, req: FindRequest): bool =
  # Selects the next (or previous) match, wrapping around the document.
  let n = doc.lines.len
  let r = doc.selectionRange
  if not req.backwards:
    for k in 0 .. n:
      let l = (r.l2 + k) mod n
      let start = if k == 0: r.c2 else: 0
      let p = findInText(doc.lines[l], req, start, wrap = false)
      if p >= 0 and not (k == n and p >= r.c2):
        doc.ancLine = l
        doc.ancCol = p
        doc.line = l
        doc.col = p + req.findText.len
        return true
  else:
    for k in 0 .. n:
      let l = ((r.l1 - k) mod n + n) mod n
      let s = doc.lines[l]
      let start = if k == 0: r.c1 else: s.len + 1
      let p = findInText(s, req, start, wrap = false)
      if p >= 0:
        doc.ancLine = l
        doc.ancCol = p
        doc.line = l
        doc.col = p + req.findText.len
        return true
  false

proc replaceSelection*(doc: Document, req: FindRequest): bool =
  if doc.hasSelection and sameText(doc.selectedText, req.findText, req.matchCase):
    doc.pushUndo()
    doc.insertText(req.replaceText)
    return true
  false

proc replaceAll*(doc: Document, req: FindRequest): int =
  doc.pushUndo()
  for l in 0 ..< doc.lines.len:
    var pos = 0
    while true:
      let p = findInText(doc.lines[l], req, pos, wrap = false)
      if p < 0: break
      doc.lines[l] = doc.lines[l][0 ..< p] & req.replaceText & doc.lines[l][p + req.findText.len .. ^1]
      pos = p + req.replaceText.len
      inc result
  if result > 0:
    doc.clampCursor()
    doc.collapse()
    doc.changed()

# control: geometry.

proc newCodeEditor*(): CodeEditor =
  result = CodeEditor(showMinimap: true, showCsd: true, fontSize: 14, charW: 9, lineH: 19,
                      hoverTab: -1, hoverClose: -1, current: -1)
  initControl(result)
  result.focusable = true

proc doc*(ed: CodeEditor): Document =
  if ed.current >= 0 and ed.current < ed.docs.len: ed.docs[ed.current] else: nil

proc bodyRect(ed: CodeEditor): Rect =
  rect(ed.rect.x, ed.rect.y + tabBarH, ed.rect.w, max(0.0, ed.rect.h - tabBarH))

proc numbersW(ed: CodeEditor): float = 5 * ed.charW + 30

proc csdW(ed: CodeEditor): float =
  let d = ed.doc
  if not ed.showCsd or d == nil: 0.0 else: 16 + float(min(10, d.maxLevel + 1)) * levelW

proc miniW(ed: CodeEditor): float = (if ed.showMinimap: minimapW else: 0.0)

proc codeRect(ed: CodeEditor): Rect =
  let b = ed.bodyRect
  let x = b.x + ed.numbersW + ed.csdW
  rect(x, b.y, max(0.0, b.x + b.w - ed.miniW - x), b.h)

proc minimapRect(ed: CodeEditor): Rect =
  let b = ed.bodyRect
  rect(b.x + b.w - ed.miniW, b.y, ed.miniW, b.h)

proc visibleLines(ed: CodeEditor): int = max(1, int(ed.codeRect.h / ed.lineH))

proc lineY(ed: CodeEditor, l: int): float =
  ed.codeRect.y + 4 + (float(l) - ed.doc.scroll) * ed.lineH

proc clampScroll(ed: CodeEditor) =
  let d = ed.doc
  if d == nil: return
  d.scroll = clamp(d.scroll, 0.0, max(0.0, float(d.lines.len) - 1))
  d.scrollX = max(0.0, d.scrollX)

proc ensureCursorVisible(ed: CodeEditor) =
  let d = ed.doc
  if d == nil: return
  let n = float(ed.visibleLines)
  if float(d.line) < d.scroll: d.scroll = float(d.line)
  if float(d.line) > d.scroll + n - 2: d.scroll = float(d.line) - n + 2
  let cx = float(runeCol(d.lines[d.line], d.col)) * ed.charW
  let cw = ed.codeRect.w - 20
  if cx < d.scrollX: d.scrollX = max(0.0, cx - 40)
  if cx > d.scrollX + cw: d.scrollX = cx - cw + 40
  ed.clampScroll()

proc notifyCursor(ed: CodeEditor) =
  let d = ed.doc
  if d == nil: return
  let c = runeCol(d.lines[d.line], d.col) + 1
  emit(ed, evSelection, index = d.line + 1, column = c, text = "pos:" & $(d.line + 1) & ":" & $c)

proc signal(ed: CodeEditor, text: string) =
  emit(ed, evSelection, text = text)

proc openCompletion(ed: CodeEditor)

proc notifyChange(ed: CodeEditor, trigger = "") =
  # evChange ("edit") ; `trigger` = "complete" ouvre la complétion.
  let d = ed.doc
  if d == nil: return
  if trigger == "complete": ed.openCompletion()
  emit(ed, evChange, index = d.line + 1, column = runeCol(d.lines[d.line], d.col) + 1, text = "edit")

proc tabRects(ed: CodeEditor, d: Drawing): seq[Rect] =
  var x = ed.rect.x + 6
  for doc in ed.docs:
    let w = min(240.0, d.textWidth(doc.title) + 52)
    result.add rect(x, ed.rect.y + 5, w, tabBarH - 5)
    x += w + 2

proc posFromPoint(ed: CodeEditor, x, y: float): tuple[line, col: int] =
  let d = ed.doc
  let c = ed.codeRect
  let l = clamp(int(floor((y - c.y - 4) / ed.lineH + d.scroll)), 0, d.lines.high)
  let rc = int(round((x - c.x - 6 + d.scrollX) / ed.charW))
  (l, byteCol(d.lines[l], max(0, rc)))

# control: text rendering

proc ensureFont(ed: CodeEditor, d: Drawing) =
  if ed.fontReady: return
  ed.fontReady = true
  when defined(sdlttf):
    for p in monoFonts:
      if fileExists(p):
        ed.font = TTF_OpenFont(p.cstring, ed.fontSize.cfloat)
        if ed.font != nil: break
    if ed.font != nil:
      var w, h: cint
      if TTF_GetStringSize(ed.font, "M", 1, addr w, addr h):
        ed.charW = float(w)
        ed.lineH = float(h) + 5
      return
  ed.charW = 8 * d.scale
  ed.lineH = 8 * d.scale + 7

proc monoText(ed: CodeEditor, d: Drawing, x, y: float, s: string, c: Color) =
  if s.len == 0: return
  when defined(sdlttf):
    if ed.font != nil:
      var e = ed.cache.getOrDefault(s)
      if e.tex == nil:
        if ed.cache.len > 6000:
          for v in ed.cache.values: SDL_DestroyTexture(v.tex)
          ed.cache.clear()
        let surf = TTF_RenderText_Blended(ed.font, s.cstring, csize_t(s.len), SDL_Color(r: 255, g: 255, b: 255, a: 255))
        if surf == nil: return
        let tex = SDL_CreateTextureFromSurface(d.ren, surf)
        SDL_DestroySurface(surf)
        if tex == nil: return
        var w, h: cfloat
        discard SDL_GetTextureSize(tex, addr w, addr h)
        e = (tex, float(w), float(h))
        ed.cache[s] = e
      discard SDL_SetTextureColorMod(e.tex, c.r, c.g, c.b)
      discard SDL_SetTextureAlphaMod(e.tex, c.a)
      d.drawTexture(e.tex, rect(round(x), round(y + (ed.lineH - e.h) / 2), e.w, e.h))
      return
  d.text(x, y + (ed.lineH - d.textHeight) / 2, s, c)

proc lineNumberText*(n: int): string =
  # 5 characters: multiples of 10 show line/1000, left-aligned ("0.010", "1.230");
  # the other lines show line mod 1000, right-aligned ("  231").
  if n mod 10 == 0: strutils.alignLeft($(n div 1000), 5)
  else: strutils.align($(n mod 1000), 5)

# control: drawing

proc drawCsd(ed: CodeEditor, d: Drawing, doc: Document, colors: EditorColors, x0, first, last: int) =
  # jGRASP-like Control Structure Diagram in the gutter.
  let lh = ed.lineH
  for b in doc.csd:
    if b.last < first or b.first > last: continue
    let col = colors.csd[b.kind]
    let x = float(x0) + 8 + float(min(b.level, 9)) * levelW
    let yTop = ed.lineY(b.first) + lh / 2
    let yBot = ed.lineY(b.last) + lh - 3
    # body bar (double for loops, as in jGRASP).
    if b.last > b.first:
      d.fillRect(rect(x - 1, yTop, 2, yBot - yTop), col)
      if b.kind == cbLoop: d.fillRect(rect(x + 2, yTop, 1, yBot - yTop), col.withAlpha(150))
      d.fillRect(rect(x - 1, yBot - 1, 6, 2), col)                # end tick.
    # entry connector towards the code.
    let xr = float(x0) + ed.csdW - 4
    d.fillRect(rect(x + 4, yTop - 0.5, max(0.0, xr - x - 4), 1), col.withAlpha(90))
    # glyph telling the kind of processing.
    case b.kind
    of cbRoutine:
      d.fillRoundRect(rect(x - 4, yTop - 4, 8, 8), 2, col)
      d.fillRect(rect(x - 2, yTop - 1, 4, 2), colors.bg)
    of cbIf, cbWhen, cbCase:
      let s = 4.5
      d.fillPolygon([(x, yTop - s), (x + s, yTop), (x, yTop + s), (x - s, yTop)], col)
      if b.kind == cbWhen: d.fillCircle(x, yTop, 1.5, colors.bg)
      for br in b.branches:
        if br < first or br > last: continue
        let yb = ed.lineY(br) + lh / 2
        d.fillPolygon([(x, yb - 3.5), (x + 3.5, yb), (x, yb + 3.5), (x - 3.5, yb)], col)
        d.fillRect(rect(x + 4, yb - 0.5, max(0.0, xr - x - 4), 1), col.withAlpha(70))
    of cbLoop:
      d.strokeCircle(x, yTop, 4.5, col, 1.5)
      d.fillPolygon([(x + 3, yTop - 6), (x + 7, yTop - 4), (x + 3, yTop - 1.5)], col)
    of cbTry:
      d.fillPolygon([(x - 4.5, yTop + 4), (x + 4.5, yTop + 4), (x, yTop - 4.5)], col)
      for br in b.branches:
        if br < first or br > last: continue
        let yb = ed.lineY(br) + lh / 2
        d.fillPolygon([(x - 3.5, yb - 3), (x + 3.5, yb - 3), (x, yb + 3.5)], col)
    of cbBlock, cbSection:
      d.fillRect(rect(x - 1, yTop - 4, 6, 2), col)
      d.fillRect(rect(x - 1, yTop - 4, 2, 6), col)

proc drawMinimap(ed: CodeEditor, d: Drawing, doc: Document, colors: EditorColors) =
  let m = ed.minimapRect
  d.fillRect(m, colors.minimapBg)
  d.fillRect(rect(m.x, m.y, 1, m.h), colors.separator)
  let mh = 2.0
  let capacity = int(m.h / mh)
  let n = doc.lines.len
  let vis = ed.visibleLines
  let maxScroll = max(1.0, float(n - 1))
  let start = if n <= capacity: 0 else: int(doc.scroll / maxScroll * float(n - capacity))
  d.pushClip(m)
  for l in start ..< min(n, start + capacity):
    let y = m.y + 4 + float(l - start) * mh
    for t in doc.tokens[l]:
      if t.kind in {tkPunct}: continue
      let x = m.x + 8 + float(t.start) * 1.1
      if x > m.x + m.w - 4: break
      d.fillRect(rect(x, y, max(1.0, float(t.len) * 1.1), mh - 0.6), colors.tok[t.kind].withAlpha(170))
  let vy = m.y + 4 + (doc.scroll - float(start)) * mh
  d.fillRect(rect(m.x + 1, vy, m.w - 1, float(vis) * mh), colors.minimapView)
  d.popClip()

proc drawWelcome(ed: CodeEditor, d: Drawing, t: Theme, colors: EditorColors) =
  let b = ed.bodyRect
  d.fillRect(b, colors.bg)
  let lines = ["wdLua [S]tudio", "Un atelier logiciel écrit par Jean-Marc Quéré.", "LPCS, Lab'Oratoire (metalab at sonaliwan.fr)", "",
               "Ctrl+N  nouveau fichier      Ctrl+O  ouvrir",
               "Ctrl+S  enregistrer          Ctrl+F  rechercher",
               "Ctrl+R  exécuter   F5  déboguer   F9  point d'arrêt   F10 / F11  pas à pas"]
  var y = b.y + b.h / 3
  for i, s in lines:
    let c = if i == 0: t.accent elif i == 2: colors.tabText else: colors.gutterMajor
    d.textIn(rect(b.x, y, b.w, t.lineHeight), s, c, alCenter)
    y += t.lineHeight

proc dgSeverity(dg: Diagnostic): int =
  case dg.sev
  of sevError: 1
  of sevWarning: 2
  of sevInfo: 3

proc severityColor(sev: int): Color =
  case sev
  of 1: hex"#F14C4C"
  of 2: hex"#E5A33B"
  of 3: hex"#3E9BFF"
  else: hex"#8C8F96"

let badgeColors = [hex"#61AFEF", hex"#D19A66", hex"#56B6C2", hex"#E5C07B", hex"#9DA5B4", hex"#C678DD"]

proc drawCompletion(ed: CodeEditor, d: Drawing, t: Theme, colors: EditorColors) =
  let doc = ed.doc
  let c = ed.comp
  ed.compRect = rect(0, 0, 0, 0)
  if doc == nil or not c.active or c.shown.len == 0 or c.line > doc.lines.high: return
  let rowH = t.lineHeight
  let rows = min(10, c.shown.len)
  let w = 520.0
  let footer = rowH + 4
  let h = float(rows) * rowH + 8 + footer
  var x = ed.codeRect.x + 6 + float(runeCol(doc.lines[c.line], c.startCol)) * ed.charW - doc.scrollX - 30
  var y = ed.lineY(doc.line) + ed.lineH + 2
  if y + h > ed.rect.y + ed.rect.h: y = ed.lineY(doc.line) - h - 2
  x = clamp(x, ed.rect.x + 4, max(ed.rect.x + 4, ed.rect.x + ed.rect.w - w - 4))
  let r = rect(x, y, w, h)
  ed.compRect = r
  d.shadow(r, 8, t.shadow)
  d.fillRoundRect(r, 8, colors.separator)
  d.fillRoundRect(r.shrink(1), 7, t.surface)
  for k in 0 ..< rows:
    let idx = c.scroll + k
    if idx >= c.shown.len: break
    let it = c.items[c.shown[idx]]
    let ry = y + 4 + float(k) * rowH
    let rr = rect(x + 4, ry, w - 8, rowH)
    if idx == c.selected: d.fillRoundRect(rr, 5, t.selection)
    let (letter, hue) = kindBadge(it.kind)
    let bc = badgeColors[hue mod badgeColors.len]
    let br = rect(rr.x + 6, ry + (rowH - 18) / 2, 18, 18)
    d.fillRoundRect(br, 4, bc.withAlpha(60))
    d.textIn(br, letter, bc, alCenter)
    let labelW = min(rr.w * 0.55, d.textWidth(it.label) + 8)
    d.textIn(rect(rr.x + 32, ry, labelW, rowH), it.label,
             (if idx == c.selected: t.textSelection else: t.text))
    d.textIn(rect(rr.x + 40 + labelW, ry, rr.w - labelW - 48, rowH), it.detail, t.textSecondary, alRight)
  # details of the selected item.
  let sel = c.items[c.shown[c.selected]]
  var info = if sel.documentation.len > 0: sel.documentation.splitLines()[0] else: sel.detail
  let fy = y + h - footer
  d.fillRect(rect(x + 1, fy, w - 2, 1), colors.separator)
  d.textIn(rect(x + 10, fy + 2, w - 20, footer - 2), info, t.textSecondary)

proc drawInfo(ed: CodeEditor, d: Drawing, t: Theme, colors: EditorColors) =
  let doc = ed.doc
  if doc == nil or ed.infoText.len == 0: return
  var lines = ed.infoText.splitLines()
  if lines.len > 8: lines.setLen(8)
  var w = 0.0
  for l in lines: w = max(w, d.textWidth(l))
  w = min(ed.codeRect.w - 20, w + 24)
  let h = float(lines.len) * t.lineHeight + 12
  var x = ed.codeRect.x + 6 + float(runeCol(doc.lines[doc.line], doc.col)) * ed.charW - doc.scrollX - 20
  x = clamp(x, ed.rect.x + 4, max(ed.rect.x + 4, ed.rect.x + ed.rect.w - w - 4))
  var y = ed.lineY(doc.line) - h - 4
  if y < ed.bodyRect.y: y = ed.lineY(doc.line) + ed.lineH + 4
  let r = rect(x, y, w, h)
  d.shadow(r, 6, t.shadow)
  d.fillRoundRect(r, 6, t.accent.withAlpha(140))
  d.fillRoundRect(r.shrink(1), 5, t.surface)
  for i, l in lines:
    d.textIn(rect(x + 12, y + 6 + float(i) * t.lineHeight, w - 24, t.lineHeight), l,
             (if i == 0: t.text else: t.textSecondary))

method preferredSize*(ed: CodeEditor, d: Drawing, t: Theme): tuple[w, h: float] = (600.0, 400.0)

method typeName*(ed: CodeEditor): string = "CodeEditor"

method acceptsText*(ed: CodeEditor): bool = ed.doc != nil

method acceptsTab*(ed: CodeEditor): bool = ed.doc != nil

method mouseCursor*(ed: CodeEditor, x, y: float): int =
  if ed.doc != nil and ed.codeRect.containsPoint(x, y): SDL_SYSTEM_CURSOR_TEXT
  else: SDL_SYSTEM_CURSOR_DEFAULT

proc runPending(ed: CodeEditor)

method draw*(ed: CodeEditor, d: Drawing, t: Theme) =
  ed.ensureFont(d)
  ed.runPending()
  let colors = colorsFor(t)
  let r = ed.rect
  # tab strip.
  d.fillRect(rect(r.x, r.y, r.w, tabBarH), colors.tabBar)
  d.fillRect(rect(r.x, r.y + tabBarH - 1, r.w, 1), colors.separator)
  if not ed.hovered:
    ed.hoverTab = -1
    ed.hoverClose = -1
  let tabs = ed.tabRects(d)
  d.pushClip(rect(r.x, r.y, r.w, tabBarH))
  for i, tr in tabs:
    let doc = ed.docs[i]
    let active = i == ed.current
    if active:
      d.fillRoundRect(rect(tr.x, tr.y, tr.w, tr.h + 6), 6, colors.tabActive)
      d.fillRect(rect(tr.x + 8, tr.y, tr.w - 16, 2), t.accent)
    elif i == ed.hoverTab:
      d.fillRoundRect(rect(tr.x, tr.y, tr.w, tr.h + 6), 6, colors.tabActive.withAlpha(110))
    d.textIn(rect(tr.x + 12, tr.y, tr.w - 36, tr.h), doc.title,
             (if active: colors.tabTextActive else: colors.tabText))
    let cx = tr.x + tr.w - 16
    let cy = tr.y + tr.h / 2
    if i == ed.hoverClose:
      d.fillCircle(cx, cy, 8, colors.separator)
    if doc.modified and i != ed.hoverTab and i != ed.hoverClose:
      d.fillCircle(cx, cy, 4, t.accent)
    elif active or i == ed.hoverTab:
      d.line(cx - 3.5, cy - 3.5, cx + 3.5, cy + 3.5, colors.tabText, 1.5)
      d.line(cx + 3.5, cy - 3.5, cx - 3.5, cy + 3.5, colors.tabText, 1.5)
  d.popClip()
  let doc = ed.doc
  if doc == nil:
    ed.drawWelcome(d, t, colors)
    return
  doc.analyze()
  ed.clampScroll()
  let b = ed.bodyRect
  let c = ed.codeRect
  let lh = ed.lineH
  d.fillRect(b, colors.bg)
  let first = max(0, int(doc.scroll))
  let last = min(doc.lines.high, first + ed.visibleLines + 1)
  let sel = doc.selectionRange
  # gutter: line numbers.
  let gx = b.x
  d.fillRect(rect(gx, b.y, ed.numbersW + ed.csdW, b.h), colors.gutter)
  d.pushClip(rect(gx, b.y, ed.numbersW + ed.csdW, b.h))
  for l in first .. last:
    let y = ed.lineY(l)
    let n = l + 1
    let major = n mod 10 == 0
    let col = if l == doc.line: colors.tabTextActive elif major: colors.gutterMajor else: colors.gutterText
    if l == doc.execLine:
      d.fillRect(rect(gx, y, ed.numbersW, lh), hex"#5A4A10")
    if l in doc.bps:
      d.fillCircle(gx + 9, y + lh / 2, 5, hex"#E5484D")
    if l == doc.execLine:
      d.fillPolygon([(gx + 3, y + lh / 2 - 5), (gx + 13, y + lh / 2), (gx + 3, y + lh / 2 + 5)], hex"#FFC200")
    ed.monoText(d, gx + 20, y, lineNumberText(n), col)
  # gutter: control structure diagram.
  if ed.showCsd:
    let x0 = gx + ed.numbersW
    d.fillRect(rect(x0, b.y, 1, b.h), colors.separator)
    ed.drawCsd(d, doc, colors, int(x0), first, last)
  d.popClip()
  # code.
  d.pushClip(c)
  for l in first .. last:
    let y = ed.lineY(l)
    let s = doc.lines[l]
    if l == doc.execLine:
      d.fillRect(rect(c.x, y, c.w, lh), hex"#4A3B10")
    elif l == doc.line and not doc.hasSelection:
      d.fillRect(rect(c.x, y, c.w, lh), colors.currentLine)
    if doc.hasSelection and l >= sel.l1 and l <= sel.l2:
      let a = if l == sel.l1: runeCol(s, sel.c1) else: 0
      let e = if l == sel.l2: runeCol(s, sel.c2) else: s.runeLen + 1
      let x1 = c.x + 6 + float(a) * ed.charW - doc.scrollX
      d.fillRect(rect(x1, y, float(e - a) * ed.charW, lh), colors.selection)
    for tk in doc.tokens[l]:
      let x = c.x + 6 + float(runeCol(s, tk.start)) * ed.charW - doc.scrollX
      if x > c.x + c.w: break
      let piece = s[tk.start ..< tk.start + tk.len]
      if x + float(piece.runeLen) * ed.charW < c.x: continue
      ed.monoText(d, x, y, piece, colors.tok[tk.kind])
  # diagnostics : soulignement ondulé.
  for dg in doc.diags:
    if dg.line < first or dg.line > last or dg.line > doc.lines.high: continue
    let col = severityColor(dgSeverity(dg))
    let s = doc.lines[dg.line]
    let a = runeCol(s, dg.col)
    let z = max(a + 1, runeCol(s, min(s.len, dg.col + dg.len)))
    let x1 = c.x + 6 + float(a) * ed.charW - doc.scrollX
    let x2 = c.x + 6 + float(z) * ed.charW - doc.scrollX
    let yb = ed.lineY(dg.line) + lh - 3
    var x = x1
    var up = true
    while x < x2:
      let nx = min(x2, x + 2.5)
      d.line(x, (if up: yb else: yb - 2), nx, (if up: yb - 2 else: yb), col, 1.2)
      x = nx
      up = not up
  if ed.focus and ed.win != nil and ed.win.caretVisible:
    let cx = c.x + 6 + float(runeCol(doc.lines[doc.line], doc.col)) * ed.charW - doc.scrollX
    d.fillRect(rect(cx - 1, ed.lineY(doc.line) + 1, 2, lh - 2), colors.caret)
  d.popClip()
  # diagnostic markers in the gutter.
  d.pushClip(rect(gx, b.y, ed.numbersW, b.h))
  for dg in doc.diags:
    if dg.line < first or dg.line > last: continue
    d.fillRoundRect(rect(gx + 1, ed.lineY(dg.line) + 3, 3, lh - 6), 1.5, severityColor(dgSeverity(dg)))
  d.popClip()
  # minimap and scroll indicator.
  if ed.showMinimap:
    ed.drawMinimap(d, doc, colors)
    let m = ed.minimapRect
    let n = max(1, doc.lines.len)
    for dg in doc.diags:
      if dgSeverity(dg) > 2: continue
      let y = m.y + 4 + float(dg.line) / float(n) * (m.h - 8)
      d.fillRect(rect(m.x + m.w - 5, y, 4, 3), severityColor(dgSeverity(dg)))
  drawScrollIndicator(d, t, rect(c.x + c.w - 10, c.y, 8, c.h),
                      float(doc.lines.len + ed.visibleLines - 1), float(ed.visibleLines), doc.scroll)
  # completion popup and information bubble (over everything).
  d.pushClip(ed.rect)
  ed.drawCompletion(d, t, colors)
  ed.drawInfo(d, t, colors)
  d.popClip()

# control: input

proc runCommand(ed: CodeEditor, cmd: string) =
  # Commands shared by the keyboard and the menus (run on the UI thread).
  if cmd == "setClipboard":                 # copie demandée par l'IDE (console...)
    discard SDL_SetClipboardText(ed.clipText.cstring)
    ed.clipText = ""
    return
  let d = ed.doc
  if d == nil: return
  case cmd
  of "undo": d.undo()
  of "redo": d.redo()
  of "copy":
    if d.hasSelection: discard SDL_SetClipboardText(d.selectedText.cstring)
  of "cut":
    if d.hasSelection:
      discard SDL_SetClipboardText(d.selectedText.cstring)
      d.pushUndo()
      d.deleteSelection()
  of "paste":
    let p = SDL_GetClipboardText()
    if p != nil:
      d.pushUndo()
      d.insertText($p)
      SDL_free(cast[pointer](p))
  of "selectAll":
    d.ancLine = 0
    d.ancCol = 0
    d.line = d.lines.high
    d.col = d.lines[^1].len
  of "toggleComment": d.toggleComment()
  of "duplicate": d.duplicateLine()
  of "indent": d.indentLines(false)
  of "dedent": d.indentLines(true)
  else: discard
  if cmd != "selectAll": ed.ensureCursorVisible()
  if cmd notin ["copy", "selectAll"]: ed.notifyChange()
  ed.notifyCursor()

proc runPending(ed: CodeEditor) =
  if ed.pending.len == 0: return
  let cmds = ed.pending
  ed.pending.setLen(0)
  for c in cmds: ed.runCommand(c)

proc switchTo(ed: CodeEditor, i: int) =
  if i >= 0 and i < ed.docs.len and i != ed.current:
    ed.current = i
    ed.signal("doc:" & $ed.docs[i].uid)
    ed.notifyCursor()

proc wordStart(doc: Document): int =
  result = doc.col
  let s = doc.lines[doc.line]
  while result > 0 and s[result - 1].isWordChar: dec result

proc refilter(ed: CodeEditor) =
  let doc = ed.doc
  if doc == nil or doc.line != ed.comp.line or doc.col < ed.comp.startCol:
    ed.comp.active = false
    return
  let prefix = doc.lines[doc.line][ed.comp.startCol ..< doc.col].toLowerAscii
  var starts, inside: seq[int]
  for i, it in ed.comp.items:
    let l = it.label.toLowerAscii
    if prefix.len == 0 or l.startsWith(prefix): starts.add i
    elif l.contains(prefix): inside.add i
  ed.comp.shown = starts & inside
  ed.comp.selected = 0
  ed.comp.scroll = 0
  ed.comp.active = ed.comp.shown.len > 0 and
    not (ed.comp.shown.len == 1 and ed.comp.items[ed.comp.shown[0]].label.toLowerAscii == prefix)

proc moveSelection(ed: CodeEditor, delta: int) =
  let n = ed.comp.shown.len
  if n == 0: return
  ed.comp.selected = clamp(ed.comp.selected + delta, 0, n - 1)
  if ed.comp.selected < ed.comp.scroll: ed.comp.scroll = ed.comp.selected
  if ed.comp.selected >= ed.comp.scroll + 10: ed.comp.scroll = ed.comp.selected - 9

proc acceptCompletion(ed: CodeEditor) =
  let doc = ed.doc
  if doc == nil or not ed.comp.active or ed.comp.shown.len == 0: return
  let it = ed.comp.items[ed.comp.shown[ed.comp.selected]]
  let text = if it.insertText.len > 0: it.insertText else: it.label
  doc.pushUndo()
  doc.ancLine = doc.line
  doc.ancCol = min(ed.comp.startCol, doc.col)
  doc.insertText(text)
  ed.comp.active = false
  doc.wantCol = runeCol(doc.lines[doc.line], doc.col)
  ed.ensureCursorVisible()
  ed.notifyChange()
  ed.notifyCursor()

proc diagnosticAt(doc: Document, line, rcol: int): int =
  for i, dg in doc.diags:
    if dg.line != line or line > doc.lines.high: continue
    let s = doc.lines[line]
    let a = runeCol(s, dg.col)
    let z = max(a + 1, runeCol(s, min(s.len, dg.col + dg.len)))
    if rcol >= a - 1 and rcol <= z + 1: return i
  -1

method onMouse*(ed: CodeEditor, e: MouseEvent) =
  if ed.win == nil: return
  let d = ed.win.drawing
  if d == nil: return
  let r = ed.rect
  # tab strip.
  if e.y < r.y + tabBarH and not ed.dragging and not ed.draggingMini:
    ed.hoverTab = -1
    ed.hoverClose = -1
    for i, tr in ed.tabRects(d):
      if tr.containsPoint(e.x, e.y):
        ed.hoverTab = i
        let onClose = abs(e.x - (tr.x + tr.w - 16)) <= 8
        if onClose: ed.hoverClose = i
        if e.action == maPress and e.button == mbLeft:
          if onClose: ed.signal("cmd:close:" & $ed.docs[i].uid)
          else: ed.switchTo(i)
        elif e.action == maPress and e.button == mbMiddle:
          ed.signal("cmd:close:" & $ed.docs[i].uid)
    return
  let doc = ed.doc
  if doc == nil: return
  let m = ed.minimapRect
  case e.action
  of maPress:
    if ed.comp.active and ed.compRect.containsPoint(e.x, e.y):
      let k = int((e.y - ed.compRect.y - 4) / ed.win.theme.lineHeight)
      if k >= 0 and ed.comp.scroll + k < ed.comp.shown.len:
        ed.comp.selected = ed.comp.scroll + k
        ed.acceptCompletion()
      return
    ed.comp.active = false
    ed.infoText = ""
    if ed.showMinimap and m.containsPoint(e.x, e.y):
      ed.draggingMini = true
    elif e.button == mbLeft:
      let p = ed.posFromPoint(e.x, e.y)
      doc.lastWasTyping = false
      if e.x < ed.bodyRect.x + ed.numbersW:                         # numéros : point d'arrêt.
        if p.line in doc.bps: doc.bps.excl p.line else: doc.bps.incl p.line
        ed.signal("bp:" & $doc.uid)
        return
      elif e.x < ed.codeRect.x:                                     # diagramme : sélection de la ligne.
        doc.ancLine = p.line
        doc.ancCol = 0
        doc.line = min(p.line + 1, doc.lines.high)
        doc.col = if p.line + 1 <= doc.lines.high: 0 else: doc.lines[p.line].len
      elif e.clicks >= 2:                                         # double click: word.
        let s = doc.lines[p.line]
        var a = p.col
        var z = p.col
        while a > 0 and s[a - 1].isWordChar: dec a
        while z < s.len and s[z].isWordChar: inc z
        doc.line = p.line
        doc.ancLine = p.line
        doc.ancCol = a
        doc.col = z
      else:
        doc.line = p.line
        doc.col = p.col
        if (e.mods and KMOD_SHIFT) == 0: doc.collapse()
        ed.dragging = (e.mods and KMOD_CMD) == 0
      doc.wantCol = runeCol(doc.lines[doc.line], doc.col)
      ed.notifyCursor()
      if (e.mods and KMOD_CMD) != 0 and e.x >= ed.codeRect.x:     # Cmd/Ctrl+clic : définition.
        let s = doc.lines[doc.line]
        var a = doc.col
        var z = doc.col
        while a > 0 and s[a - 1].isWordChar: dec a
        while z < s.len and s[z].isWordChar: inc z
        if z > a: ed.signal("cmd:definition:" & s[a ..< z])
  of maMove:
    if ed.draggingMini:
      let n = doc.lines.len
      let capacity = int(m.h / 2.0)
      let target = if n <= capacity: (e.y - m.y) / 2.0
                   else: (e.y - m.y) / m.h * float(n)
      doc.scroll = target - float(ed.visibleLines) / 2
      ed.clampScroll()
    elif ed.dragging:
      let p = ed.posFromPoint(e.x, e.y)
      doc.line = p.line
      doc.col = p.col
      ed.ensureCursorVisible()
      ed.notifyCursor()
    elif ed.codeRect.containsPoint(e.x, e.y) and doc.diags.len > 0:   # diagnostic tooltip
      let p = ed.posFromPoint(e.x, e.y)
      let i = diagnosticAt(doc, p.line, runeCol(doc.lines[p.line], p.col))
      ed.tooltip = if i >= 0: $doc.diags[i].sev & " : " & doc.diags[i].msg else: ""
    else:
      ed.tooltip = ""
  of maRelease:
    if ed.draggingMini:
      let n = doc.lines.len
      let capacity = int(m.h / 2.0)
      let target = if n <= capacity: (e.y - m.y) / 2.0 else: (e.y - m.y) / m.h * float(n)
      doc.scroll = target - float(ed.visibleLines) / 2
      ed.clampScroll()
    ed.dragging = false
    ed.draggingMini = false

method onWheel*(ed: CodeEditor, dx, dy: float): bool =
  let doc = ed.doc
  if doc == nil: return false
  var h = dx
  var v = dy
  if h == 0 and (SDL_GetModState() and KMOD_SHIFT) != 0:
    h = v
    v = 0
  doc.scroll -= v * 3
  doc.scrollX -= h * ed.charW * 4
  ed.clampScroll()
  true

method onText*(ed: CodeEditor, s: string) =
  let doc = ed.doc
  if doc == nil or s.len == 0: return
  if ed.suppressSpace and s == " ":          # Ctrl+Space already handled as "complete".
    ed.suppressSpace = false
    return
  ed.suppressSpace = false
  doc.pushUndo(typing = true)
  doc.insertText(s)
  doc.wantCol = runeCol(doc.lines[doc.line], doc.col)
  ed.ensureCursorVisible()
  let last = s[^1]
  ed.infoText = ""
  var trigger = ""
  if ed.comp.active:
    if last.isWordChar: ed.refilter()
    else: ed.comp.active = false
  if last == '.': trigger = "complete"
  elif last == '(' or last == ',': trigger = "signature"
  elif last.isWordChar and not ed.comp.active and doc.col - doc.wordStart >= 3: trigger = "complete"
  ed.notifyChange(trigger)
  ed.notifyCursor()

method onKey*(ed: CodeEditor, e: KeyEvent): bool =
  let doc = ed.doc
  if doc == nil: return false
  let shift = (e.mods and KMOD_SHIFT) != 0
  let cmd = (e.mods and KMOD_CMD) != 0
  let word = (e.mods and wordMod) != 0
  if e.key >= 0x400000E0'u32 and e.key <= 0x400000E7'u32: return false   # modifier keys alone.
  # raccourcis de l'IDE : transmis à la fenêtre sous forme de commandes
  let kc = int(e.key)
  let ctrlOnly = (e.mods and (KMOD_CTRL or KMOD_CMD)) != 0
  var shortcut = ""
  case kc
  of KF5: shortcut = (if shift: "cmd:stop" else: "cmd:debug")
  of KF10: shortcut = "cmd:stepover"
  of KF11: shortcut = (if shift: "cmd:stepout" else: "cmd:stepinto")
  of KF3: shortcut = (if shift: "cmd:findprev" else: "cmd:findnext")
  of KF2: shortcut = "cmd:goto"
  of KF12:
    let s = doc.lines[doc.line]
    var a = doc.col
    var z = doc.col
    while a > 0 and s[a - 1].isWordChar: dec a
    while z < s.len and s[z].isWordChar: inc z
    if z > a: shortcut = "cmd:definition:" & s[a ..< z]
  of KF9:
    if doc.line in doc.bps: doc.bps.excl doc.line else: doc.bps.incl doc.line
    shortcut = "bp:" & $doc.uid
  else:
    if ctrlOnly:
      case kc
      of ord('s'): shortcut = (if shift: "cmd:saveas" else: "cmd:save")
      of ord('f'): shortcut = "cmd:find"
      of ord('h'), ord('g'): shortcut = "cmd:findnext"
      of ord('l'): shortcut = "cmd:goto"
      of ord('r'): shortcut = "cmd:run"
      of ord('n'): shortcut = "cmd:new"
      of ord('o'): shortcut = "cmd:open"
      of ord('k'): shortcut = "cmd:replace"
      of ord('b'):
        ed.runCommand("toggleComment")
        return true
      of KTab:
        if ed.docs.len > 1:
          ed.switchTo((ed.current + (if shift: ed.docs.len - 1 else: 1)) mod ed.docs.len)
        return true
      else: discard
  if shortcut.len > 0:
    ed.signal(shortcut)
    return true
  if ed.comp.active:
    case e.key
    of SDLK_UP:
      ed.moveSelection(-1)
      return true
    of SDLK_DOWN:
      ed.moveSelection(1)
      return true
    of SDLK_PAGEUP:
      ed.moveSelection(-9)
      return true
    of SDLK_PAGEDOWN:
      ed.moveSelection(9)
      return true
    of SDLK_RETURN, SDLK_KP_ENTER, SDLK_TAB:
      ed.acceptCompletion()
      return true
    of SDLK_ESCAPE:
      ed.comp.active = false
      return true
    of SDLK_BACKSPACE: discard                                    # refiltered below.
    else: ed.comp.active = false
  if e.key == SDLK_ESCAPE and ed.infoText.len > 0:
    ed.infoText = ""
    return true
  if e.key == SDLK_SPACE and (e.mods and KMOD_CTRL) != 0:         # Ctrl+Space: suggestions.
    ed.suppressSpace = true
    ed.notifyChange("complete")
    return true
  if e.key notin [SDLK_LEFT, SDLK_RIGHT] or not shift: ed.infoText = ""
  var moved = true
  var edited = false
  case e.key
  of SDLK_LEFT:
    if doc.hasSelection and not shift:
      let r = doc.selectionRange
      doc.line = r.l1
      doc.col = r.c1
    elif cmd: doc.col = 0
    elif word: doc.wordLeft()
    elif doc.col > 0: doc.col = prevRuneStart(doc.lines[doc.line], doc.col)
    elif doc.line > 0:
      dec doc.line
      doc.col = doc.lines[doc.line].len
    doc.wantCol = runeCol(doc.lines[doc.line], doc.col)
  of SDLK_RIGHT:
    if doc.hasSelection and not shift:
      let r = doc.selectionRange
      doc.line = r.l2
      doc.col = r.c2
    elif cmd: doc.col = doc.lines[doc.line].len
    elif word: doc.wordRight()
    elif doc.col < doc.lines[doc.line].len: doc.col = nextRuneStart(doc.lines[doc.line], doc.col)
    elif doc.line < doc.lines.high:
      inc doc.line
      doc.col = 0
    doc.wantCol = runeCol(doc.lines[doc.line], doc.col)
  of SDLK_UP, SDLK_DOWN, SDLK_PAGEUP, SDLK_PAGEDOWN:
    let step = case e.key
               of SDLK_UP: -1
               of SDLK_DOWN: 1
               of SDLK_PAGEUP: -ed.visibleLines
               else: ed.visibleLines
    if cmd and e.key in [SDLK_UP, SDLK_DOWN]:
      doc.line = (if step < 0: 0 else: doc.lines.high)
    else:
      doc.line = clamp(doc.line + step, 0, doc.lines.high)
    doc.col = byteCol(doc.lines[doc.line], doc.wantCol)
    if e.key in [SDLK_PAGEUP, SDLK_PAGEDOWN]: doc.scroll += float(step)
  of SDLK_HOME:
    if cmd:
      doc.line = 0
      doc.col = 0
    else:
      let ind = leadingSpaces(doc.lines[doc.line])
      doc.col = if doc.col == ind: 0 else: ind                    # smart home.
    doc.wantCol = runeCol(doc.lines[doc.line], doc.col)
  of SDLK_END:
    if cmd: doc.line = doc.lines.high
    doc.col = doc.lines[doc.line].len
    doc.wantCol = runeCol(doc.lines[doc.line], doc.col)
  of SDLK_BACKSPACE:
    doc.backspace()
    if ed.comp.active: ed.refilter()
    edited = true
  of SDLK_DELETE:
    doc.deleteForward()
    edited = true
  of SDLK_RETURN, SDLK_KP_ENTER:
    doc.newline()
    edited = true
  of SDLK_TAB:
    if doc.hasSelection and doc.line != doc.ancLine: doc.indentLines(shift)
    elif shift: doc.indentLines(true)
    else:
      doc.pushUndo()
      doc.insertText(spaces(2 - runeCol(doc.lines[doc.line], doc.col) mod 2))
    edited = true
  of SDLK_A, SDLK_C, SDLK_X, SDLK_V, SDLK_Z, SDLK_Y, SDLK_D, SDLK_SLASH:
    if not cmd: return false
    let c = case e.key
            of SDLK_A: "selectAll"
            of SDLK_C: "copy"
            of SDLK_X: "cut"
            of SDLK_V: "paste"
            of SDLK_Z: (if shift: "redo" else: "undo")
            of SDLK_Y: "redo"
            of SDLK_D: "duplicate"
            else: "toggleComment"
    ed.runCommand(c)
    return true
  else:
    return false
  if edited:
    doc.lastWasTyping = false
    doc.wantCol = runeCol(doc.lines[doc.line], doc.col)
    ed.ensureCursorVisible()
    ed.notifyChange()
    ed.notifyCursor()
    return true
  if moved:
    if not shift: doc.collapse()
    doc.lastWasTyping = false
    ed.ensureCursorVisible()
    ed.notifyCursor()
  true

# complétion et API sûre entre threads

proc newLuaEditor*(): CodeEditor =
  result = newCodeEditor()

proc identsOf(doc: Document): seq[string] =
  doc.analyze()
  var seen = initHashSet[string]()
  for l in 0 ..< min(doc.lines.len, doc.tokens.len):
    for t in doc.tokens[l]:
      if t.kind == tkText:
        let w = doc.lines[l][t.start ..< t.start + t.len]
        if w.len > 1 and w notin seen:
          seen.incl w
          result.add w

proc openCompletion(ed: CodeEditor) =
  ## Complétion locale : mots-clés, bibliothèques et paquets enregistrés,
  ## membres après « . », méthodes après « : », symboles du projet et du fichier.
  let d = ed.doc
  if d == nil: return
  let line = d.lines[d.line]
  var a = min(d.col, line.len)
  while a > 0 and line[a - 1].isWordChar: dec a
  let sep = if a > 0: line[a - 1] else: ' '
  var items: seq[CompletionItem]
  var seen = initHashSet[string]()
  template addItem(lbl, det: string, k: int) =
    if lbl.len > 0 and lbl notin seen:
      seen.incl lbl
      items.add CompletionItem(label: lbl, detail: det, kind: k)
  if sep == ':':
    for e in methodEntries(): addItem(e.name, e.signature, 2)
  elif sep == '.' and a >= 2:
    var b = a - 1
    while b > 0 and line[b - 1].isWordChar: dec b
    let owner = line[b ..< a - 1]
    for e in membersOf(owner): addItem(e.name, e.signature, 3)
    if owner notin packageNames():
      for h in UiHandlers: addItem(h, "gestionnaire ui : function(ev) ... end", 23)
      for p in UiProps: addItem(p, "propriété ui", 10)
  else:
    for k in Keywords: addItem(k, "mot-clé", 14)
    for e in apiEntries():
      if e.owner.len == 0 and not e.isMethod: addItem(e.name, e.signature, 3)
    for p in packageNames(): addItem(p, "paquet : require \"" & p & "\"", 9)
    for n in ed.projectNames: addItem(n, "projet", 6)
    for n in d.identsOf(): addItem(n, "fichier", 6)
  if items.len == 0: return
  ed.comp = CompletionState(active: true, items: items, line: d.line, startCol: a)
  ed.refilter()

proc docIndex(ed: CodeEditor, uid: int): int =
  for i, d in ed.docs:
    if d.uid == uid: return i
  -1

proc samePath(a, b: string): bool =
  a.len > 0 and b.len > 0 and normalizedPath(absolutePath(a)) == normalizedPath(absolutePath(b))

proc editorOpen*(id: ControlId, path, text: string): int =
  ## Ouvre (ou active) un document ; renvoie son uid.
  let full = if path.len > 0: normalizedPath(absolutePath(path)) else: ""
  withControl(id, CodeEditor, ed):
    for i, d in ed.docs:
      if full.len > 0 and d.path == full:
        ed.switchTo(i)
        return d.uid
    let d = newDocument(extractFilename(full), text, full)
    ed.docs.add d
    ed.current = ed.docs.high
    ed.signal("doc:" & $d.uid)
    ed.notifyCursor()
    result = d.uid

proc editorNew*(id: ControlId, title: string): int =
  withControl(id, CodeEditor, ed):
    let d = newDocument(title)
    ed.docs.add d
    ed.current = ed.docs.high
    ed.signal("doc:" & $d.uid)
    result = d.uid

proc editorIsOpen*(id: ControlId, path: string): bool =
  readControl(id, CodeEditor, ed):
    for d in ed.docs:
      if samePath(d.path, path): return true

proc editorActiveUid*(id: ControlId): int =
  result = -1
  readControl(id, CodeEditor, ed):
    let d = ed.doc
    if d != nil: result = d.uid

proc editorActivate*(id: ControlId, uid: int) =
  withControl(id, CodeEditor, ed): ed.switchTo(ed.docIndex(uid))

proc editorDocs*(id: ControlId): seq[tuple[uid: int, path, title: string, dirty: bool]] =
  readControl(id, CodeEditor, ed):
    for d in ed.docs: result.add (uid: d.uid, path: d.path, title: d.title, dirty: d.modified)

proc editorInfo*(id: ControlId, uid: int): tuple[path, title: string, dirty: bool, version: int] =
  readControl(id, CodeEditor, ed):
    let i = ed.docIndex(uid)
    if i >= 0:
      let d = ed.docs[i]
      result = (path: d.path, title: d.title, dirty: d.modified, version: d.version)

proc editorText*(id: ControlId, uid: int): string =
  readControl(id, CodeEditor, ed):
    let i = ed.docIndex(uid)
    if i >= 0: result = ed.docs[i].lines.join("\n")

proc editorSnapshot*(id: ControlId, uid: int): tuple[version: int, lines: seq[string]] =
  readControl(id, CodeEditor, ed):
    let i = ed.docIndex(uid)
    if i >= 0: result = (version: ed.docs[i].version, lines: ed.docs[i].lines)

proc editorMarkSaved*(id: ControlId, uid: int, version: int, path = "") =
  withControl(id, CodeEditor, ed):
    let i = ed.docIndex(uid)
    if i >= 0:
      let d = ed.docs[i]
      if d.version == version: d.modified = false
      if path.len > 0:
        d.path = normalizedPath(absolutePath(path))
        d.title = extractFilename(d.path)

proc editorClose*(id: ControlId, uid: int) =
  withControl(id, CodeEditor, ed):
    let i = ed.docIndex(uid)
    if i >= 0:
      ed.docs.delete(i)
      if ed.current >= ed.docs.len: ed.current = ed.docs.high
      elif i < ed.current: dec ed.current
      ed.comp.active = false
      if ed.doc != nil: ed.signal("doc:" & $ed.doc.uid)
      ed.notifyCursor()

proc editorSetDiagnostics*(id: ControlId, uid, version: int, diags: seq[Diagnostic]) =
  withControl(id, CodeEditor, ed):
    let i = ed.docIndex(uid)
    if i >= 0 and ed.docs[i].version == version: ed.docs[i].diags = diags

proc editorGoto*(id: ControlId, uid: int, line: int, col = 0) =
  ## line et col à partir de 0 (col en caractères).
  withControl(id, CodeEditor, ed):
    let i = ed.docIndex(uid)
    if i >= 0:
      ed.switchTo(i)
      let d = ed.docs[i]
      d.line = clamp(line, 0, d.lines.high)
      d.col = byteCol(d.lines[d.line], max(0, col))
      d.collapse()
      d.wantCol = runeCol(d.lines[d.line], d.col)
      d.scroll = max(0.0, float(d.line) - float(ed.visibleLines) / 3)
      ed.ensureCursorVisible()
      ed.notifyCursor()

proc editorCursor*(id: ControlId): tuple[line, col: int] =
  readControl(id, CodeEditor, ed):
    let d = ed.doc
    if d != nil: result = (line: d.line, col: runeCol(d.lines[d.line], d.col))

proc editorInsert*(id: ControlId, text: string) =
  withControl(id, CodeEditor, ed):
    let d = ed.doc
    if d != nil:
      d.pushUndo()
      d.insertText(text)
      ed.ensureCursorVisible()
      ed.notifyChange()
      ed.notifyCursor()

proc editorCommand*(id: ControlId, cmd: string) =
  ## undo, redo, cut, copy, paste, selectall, dup, comment, indent, outdent :
  ## exécutées au prochain rendu, sur le thread UI (presse-papiers).
  let c = case cmd
    of "selectall": "selectAll"
    of "dup": "duplicate"
    of "comment": "toggleComment"
    of "outdent": "dedent"
    else: cmd
  withControl(id, CodeEditor, ed): ed.pending.add c

proc editorWordAtCursor*(id: ControlId): string =
  readControl(id, CodeEditor, ed):
    let d = ed.doc
    if d != nil:
      let s = d.lines[d.line]
      var a = min(d.col, s.len)
      var z = a
      while a > 0 and s[a - 1].isWordChar: dec a
      while z < s.len and s[z].isWordChar: inc z
      result = s[a ..< z]

proc editorSelection*(id: ControlId): string =
  readControl(id, CodeEditor, ed):
    let d = ed.doc
    if d != nil and d.hasSelection: result = d.selectedText

proc editorCallContext*(id: ControlId): tuple[name: string, isMethod: bool, arg: int, firstArg: string] =
  ## Fonction dont on écrit les arguments (aide à la signature).
  var lines: seq[string]
  var line, col: int
  readControl(id, CodeEditor, ed):
    let d = ed.doc
    if d != nil:
      line = d.line
      col = d.col
      lines = d.lines[max(0, d.line - 20) .. d.line]
  if lines.len == 0: return
  var text = lines[0 ..< lines.high].join("\n")
  if lines.len > 1: text.add "\n"
  text.add lines[^1][0 ..< min(col, lines[^1].len)]
  var depth = 0
  var commas = 0
  var i = text.high
  while i >= 0:
    let c = text[i]
    case c
    of ')', ']', '}': inc depth
    of '[', '{':
      if depth == 0: return
      dec depth
    of '"', '\'':
      dec i
      while i >= 0 and text[i] != c: dec i
    of ',':
      if depth == 0: inc commas
    of '(':
      if depth == 0:
        var e = i - 1
        while e >= 0 and text[e] == ' ': dec e
        var b = e
        while b >= 0 and text[b].isWordChar: dec b
        if e > b:
          result.name = text[b + 1 .. e]
          result.isMethod = b >= 0 and text[b] == ':'
          result.arg = commas
          result.firstArg = text[i + 1 .. ^1].split(',')[0].strip()
        return
      dec depth
    else: discard
    dec i

proc editorFind*(id: ControlId, req: FindRequest): bool =
  withControl(id, CodeEditor, ed):
    let d = ed.doc
    if d != nil:
      result = d.findNext(req)
      ed.ensureCursorVisible()
      ed.notifyCursor()

proc editorReplace*(id: ControlId, req: FindRequest): bool =
  withControl(id, CodeEditor, ed):
    let d = ed.doc
    if d != nil:
      result = d.replaceSelection(req)
      discard d.findNext(req)
      ed.ensureCursorVisible()
      ed.notifyChange()
      ed.notifyCursor()

proc editorReplaceAll*(id: ControlId, req: FindRequest): int =
  withControl(id, CodeEditor, ed):
    let d = ed.doc
    if d != nil:
      result = d.replaceAll(req)
      if result > 0: ed.notifyChange()
      ed.notifyCursor()

proc editorSetOptions*(id: ControlId, minimap, dark: bool) =
  ## Les couleurs suivent le thème de la fenêtre ; `dark` est ignoré ici.
  withControl(id, CodeEditor, ed): ed.showMinimap = minimap

proc editorSetProjectNames*(id: ControlId, names: seq[string]) =
  withControl(id, CodeEditor, ed): ed.projectNames = names

proc editorFlush*(id: ControlId) =
  ## Compatibilité : les signaux sont émis directement.
  discard

proc editorBreakpoints*(id: ControlId, uid: int): seq[int] =
  readControl(id, CodeEditor, ed):
    let i = ed.docIndex(uid)
    if i >= 0:
      for l in ed.docs[i].bps: result.add l
  result.sort()

proc editorToggleBreakpoint*(id: ControlId) =
  withControl(id, CodeEditor, ed):
    let d = ed.doc
    if d != nil:
      if d.line in d.bps: d.bps.excl d.line else: d.bps.incl d.line
      ed.signal("bp:" & $d.uid)

proc editorClearBreakpoints*(id: ControlId) =
  withControl(id, CodeEditor, ed):
    for d in ed.docs:
      d.bps.clear()
      ed.signal("bp:" & $d.uid)

proc editorSetExecLine*(id: ControlId, uid, line: int) =
  ## Ligne d'exécution (0-based) ; uid = -1 l'efface partout.
  withControl(id, CodeEditor, ed):
    for d in ed.docs: d.execLine = (if d.uid == uid: line else: -1)
    let i = ed.docIndex(uid)
    if i >= 0:
      ed.switchTo(i)
      let d = ed.docs[i]
      d.line = clamp(line, 0, d.lines.high)
      d.col = leadingSpaces(d.lines[d.line])
      d.collapse()
      let n = float(ed.visibleLines)
      if float(d.line) < d.scroll or float(d.line) > d.scroll + n - 2:
        d.scroll = max(0.0, float(d.line) - n / 3)

proc editorUidOf*(id: ControlId, path: string): int =
  ## uid du document ouvert sur `path` (ou dont le titre vaut `path`), -1 sinon.
  result = -1
  readControl(id, CodeEditor, ed):
    for d in ed.docs:
      if samePath(d.path, path) or (d.path.len == 0 and d.title == path):
        return d.uid

proc editorSourceName*(id: ControlId, uid: int): string =
  ## Nom de source pour l'interpréteur : chemin, ou titre si non enregistré.
  readControl(id, CodeEditor, ed):
    let i = ed.docIndex(uid)
    if i >= 0: result = (if ed.docs[i].path.len > 0: ed.docs[i].path else: ed.docs[i].title)


proc editorCopyToClipboard*(id: ControlId, text: string) =
  ## Copie `text` dans le presse-papiers. SDL exige le thread UI : la copie est
  ## faite par l'éditeur à son prochain rendu.
  withControl(id, CodeEditor, ed):
    ed.clipText = text
    ed.pending.add "setClipboard"
