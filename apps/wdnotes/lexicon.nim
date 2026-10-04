# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
#   _._
# o|- -|o  wdnotes - lexicon
#  ( l )   word occurrences, per note, per line, and word families.
#    =
#
# The *lexicon note* of the project groups words by family:
#
#   # Lexique
#   ## Habitat
#   maison, logement, appartement
#   ## Nature
#   - arbre
#   - forêt
#
# Every counted word that belongs to no family is attached to "isolé".

import std/[tables, strutils, sets, algorithm]
import std/unicode except strip, split, splitWhitespace, align, alignLeft, cmpIgnoreCase, reversed
import project

const IsolatedFamily* = "isolé"

# TODO: use an external file containing an editable list (derived from official sources).
const StopWords = [
  # français
  "les", "des", "une", "est", "sont", "pas", "par", "pour", "sur", "dans", "avec", "que",
  "qui", "quoi", "dont", "aux", "ces", "ses", "son", "sa", "leur", "leurs", "nous", "vous",
  "ils", "elles", "elle", "lui", "mais", "donc", "car", "ainsi", "comme", "plus", "moins",
  "très", "tout", "tous", "toute", "toutes", "cette", "cet", "être", "avoir", "fait", "faire",
  "été", "sans", "sous", "entre", "vers", "chez", "aussi", "bien", "encore", "déjà", "ici",
  "où", "quand", "alors", "puis", "même", "autre", "autres", "peu", "peut", "doit", "ont",
  "était", "sera", "ceux", "celle", "celui", "chaque", "selon", "après", "avant", "lors",
  "notre", "votre", "nos", "vos", "mes", "tes", "une", "uns", "non", "oui", "via", "afin",
  "aussi", "dès", "depuis", "pendant", "contre", "parce", "cela", "ceci", "ça", "rien",
  # english
  "the", "and", "for", "are", "but", "not", "you", "all", "any", "can", "her", "was", "one",
  "our", "out", "has", "have", "this", "that", "with", "from", "they", "will", "would",
  "there", "their", "what", "about", "which", "when", "your", "into", "than", "then",
  "them", "these", "those", "been", "were", "its", "also", "only", "such", "some",
  # markdown / attributes
  "http", "https", "www", "true", "false", "color", "size", "bold", "italic", "align",
  "center", "left", "right", "justify", "font", "border", "frame", "before", "after",
  "indent", "line", "prefix", "upper", "underline", "strike", "pagebreak", "newpage"]

type
  WordStats* = object
    total*: int
    perNote*: OrderedTable[string, int]

  Lexicon* = object
    words*: Table[string, WordStats]
    families*: OrderedTable[string, seq[string]]                  # family -> words.
    wordFamilies*: Table[string, seq[string]]                     # word -> families.

var stopSet {.threadvar.}: HashSet[string]

proc isStop(w: string): bool =
  if stopSet.len == 0:
    for s in StopWords: stopSet.incl s
  w in stopSet

proc cleanLine(line: string): string =
  # removes "{ ... }" attributes and link targets.
  result = newStringOfCap(line.len)
  var i = 0
  while i < line.len:
    let c = line[i]
    if c == '{':
      let e = line.find('}', i + 1)
      if e > i: i = e + 1; continue
    if c == ']' and i + 1 < line.len and line[i + 1] == '(':
      let e = line.find(')', i + 2)
      if e > i: result.add ' '; i = e + 1; continue
    if line.continuesWith("http://", i) or line.continuesWith("https://", i):
      while i < line.len and line[i] notin {' ', '\t', ')'}: inc i
      continue
    result.add c
    inc i

iterator wordsOf*(line: string, minLen = 3): string =
  # lower-case words of a line (letters, inner hyphens).
  var cur: seq[Rune]
  let rs = cleanLine(line).toRunes
  var k = 0
  while k <= rs.len:
    let r = if k < rs.len: rs[k] else: Rune(32)
    if r.isAlpha:
      cur.add r.toLower
    elif r == Rune(45) and cur.len > 0 and k + 1 < rs.len and rs[k + 1].isAlpha:
      cur.add r
    else:
      if cur.len >= minLen:
        let w = $cur
        if not isStop(w): yield w
      cur.setLen(0)
    inc k

proc countWords*(text: string): CountTable[string] =
  result = initCountTable[string]()
  var inCode = false
  for line in text.splitLines:
    let t = line.strip
    if t.startsWith("```") or t.startsWith("~~~"): inCode = not inCode; continue
    if inCode: continue
    for w in wordsOf(line): result.inc w

proc parseFamilies*(text: string): OrderedTable[string, seq[string]] =
  result = initOrderedTable[string, seq[string]]()
  var current = ""
  for line in text.splitLines:
    let t = line.strip
    if t.startsWith("## "):
      current = t.strip(chars = {'#', ' '}).split('{')[0].strip
      if current.len > 0 and current notin result: result[current] = @[]
      continue
    if current.len == 0 or t.len == 0 or t.startsWith("#"): continue
    var body = t
    if body.len > 1 and body[0] in {'-', '*', '+'} and body[1] == ' ': body = body[2 .. ^1]
    for part in body.split({',', ';', '|'}):
      let w = unicode.toLower(part.strip(chars = {' ', '.', '*', '_', '`'}))
      if w.len > 0 and w notin result[current]: result[current].add w

proc buildLexicon*(p: Project): Lexicon =
  result.words = initTable[string, WordStats]()
  for id in p.preorder:
    if id == p.lexiconNote: continue
    for w, c in countWords(p.notes[id].text):
      if w notin result.words:
        result.words[w] = WordStats(perNote: initOrderedTable[string, int]())
      result.words[w].total += c
      result.words[w].perNote[id] = c
  result.families = initOrderedTable[string, seq[string]]()
  if p.lexiconNote.len > 0 and p.lexiconNote in p.notes:
    result.families = parseFamilies(p.notes[p.lexiconNote].text)
  for fam, ws in result.families:
    for w in ws:
      result.wordFamilies.mgetOrPut(w, @[]).add fam
  var isolated: seq[string]
  for w in result.words.keys:
    if w notin result.wordFamilies: isolated.add w
  isolated.sort()
  result.families[IsolatedFamily] = isolated

proc sortedWords*(lex: Lexicon, filter = "", byCount = true): seq[(string, int)] =
  let f = unicode.toLower(filter.strip)
  for w, s in lex.words:
    if f.len == 0 or f in w: result.add (w, s.total)
  if byCount:
    result.sort(proc (a, b: (string, int)): int =
      result = cmp(b[1], a[1])
      if result == 0: result = cmp(a[0], b[0]))
  else:
    result.sort(proc (a, b: (string, int)): int = cmp(a[0], b[0]))

proc familyTotal*(lex: Lexicon, fam: string): int =
  for w in lex.families.getOrDefault(fam):
    if w in lex.words: result += lex.words[w].total

proc familyStats*(lex: Lexicon): seq[(string, int, int)] =
  # (family, number of words, occurrences).
  for fam, ws in lex.families:
    result.add (fam, ws.len, lex.familyTotal(fam))

proc notesFor*(lex: Lexicon, ws: seq[string]): seq[(string, int)] =
  # (note id, occurrences) for a set of words, most frequent first.
  var acc = initOrderedTable[string, int]()
  for w in ws:
    if w notin lex.words: continue
    for id, c in lex.words[w].perNote:
      acc.mgetOrPut(id, 0) += c
  for id, c in acc: result.add (id, c)
  result.sort(proc (a, b: (string, int)): int = cmp(b[1], a[1]))

proc linesFor*(p: Project, id: string, ws: seq[string]): seq[(int, int, string)] =
  # (1-based line, occurrences on the line, line text).
  let wanted = toHashSet(ws)
  let allLines = p.notes[id].text.splitLines
  for i, line in allLines:
    var c = 0
    for w in wordsOf(line):
      if w in wanted: inc c
    if c > 0: result.add (i + 1, c, line.strip)
