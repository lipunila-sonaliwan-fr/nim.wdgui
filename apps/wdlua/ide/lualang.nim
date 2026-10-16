# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
#   wdlua - IDE : coloration syntaxique
#
# Analyse lexicale ligne par ligne, avec un état de reprise (commentaire ou
# chaîne longue en cours), pour ne recalculer que les lignes modifiées.
# L'interpréteur a son propre analyseur (lua/lexer.nim) ; celui-ci est fait
# pour la coloration : il ne lève jamais d'erreur et marque les jetons fautifs.
#
# Extensions du manuel (§9.2) mises en évidence :
#   += -= *= /= //= \= %= ^= ..= &= |= <<= >>=   \   !=   ?expr   0b...

import std/strutils
import langdocs

type
  TokKind* = enum
    tkSpace       # blancs.
    tkIdent       # identifiant ordinaire.
    tkKeyword     # mot-clé Lua.
    tkBuiltin     # fonction ou paquet connu (bibliothèques et paquets enregistrés).
    tkCallback    # (réservé).
    tkNumber
    tkString
    tkEscape      # séquence d'échappement dans une chaîne.
    tkComment
    tkPod         # (réservé).
    tkOperator    # opérateur Lua standard.
    tkPicoOp      # extension du manuel (+=, !=, \, ?...)
    tkPunct       # ( ) [ ] { } , ;
    tkError       # caractère invalide, chaîne non terminée, nombre mal formé.

  Token* = object
    kind*: TokKind
    start*, len*: int     # position en octets dans la ligne.

  LexMode* = enum lmNormal, lmLongComment, lmLongString

  LexState* = object
    mode*: LexMode
    level*: int           # nombre de '=' du crochet long ouvert.

const
  Keywords* = ["and", "break", "do", "else", "elseif", "end", "false", "for",
               "function", "goto", "if", "in", "local", "nil", "not", "or",
               "repeat", "return", "then", "true", "until", "while"]

  # du plus long au plus court : le premier qui correspond gagne.
  Ops3 = ["...", "..=", "//=", "<<=", ">>="]
  Ops2 = ["==", "~=", "<=", ">=", "//", "..", "::", "<<", ">>",
          "!=", "+=", "-=", "*=", "/=", "%=", "^=", "&=", "|=", "\\="]
  PicoOps* = ["..=", "//=", "<<=", ">>=", "!=", "+=", "-=", "*=", "/=", "%=",
              "^=", "&=", "|=", "\\=", "\\", "?"]
  Op1 = {'+', '-', '*', '/', '%', '^', '#', '&', '~', '|', '<', '>', '=', ':', '.', '\\', '?'}
  Punct1 = {'(', ')', '[', ']', '{', '}', ',', ';'}
  IdentStart = {'a'..'z', 'A'..'Z', '_'}
  LuaIdentChars* = {'a'..'z', 'A'..'Z', '0'..'9', '_'}

proc same*(a, b: LexState): bool {.inline.} =
  a.mode == b.mode and (a.mode == lmNormal or a.level == b.level)

proc isKeyword*(s: string): bool = s in Keywords

proc tokText*(line: string, t: Token): string {.inline.} =
  line[t.start ..< min(line.len, t.start + t.len)]

proc longBracketLevel*(s: string, i: int): int =
  # s[i] == '[' : renvoie le niveau du crochet long « [==[ » ou -1.
  if i >= s.len or s[i] != '[': return -1
  var j = i + 1
  var lvl = 0
  while j < s.len and s[j] == '=':
    inc lvl
    inc j
  if j < s.len and s[j] == '[': lvl else: -1

proc findLongClose*(s: string, start, level: int): int =
  # Indice juste après le crochet fermant de niveau `level`, ou -1.
  var i = start
  while i < s.len:
    if s[i] == ']':
      var j = i + 1
      var lvl = 0
      while j < s.len and s[j] == '=':
        inc lvl
        inc j
      if lvl == level and j < s.len and s[j] == ']': return j + 1
    inc i
  -1

proc scanNumber(s: string, i: int): (int, bool) =
  # Renvoie (fin, ok). Accepte décimal, hexadécimal (avec fraction et
  # exposant p) et binaire 0b.
  var j = i
  var ok = true
  if s[j] == '0' and j + 1 < s.len and s[j + 1] in {'x', 'X'}:
    j += 2
    let d0 = j
    while j < s.len and s[j] in HexDigits + {'.'}: inc j
    if j == d0: ok = false
    if j < s.len and s[j] in {'p', 'P'}:
      inc j
      if j < s.len and s[j] in {'+', '-'}: inc j
      let e0 = j
      while j < s.len and s[j] in Digits: inc j
      if j == e0: ok = false
  elif s[j] == '0' and j + 1 < s.len and s[j + 1] in {'b', 'B'}:
    j += 2
    let d0 = j
    while j < s.len and s[j] in {'0', '1', '.'}: inc j
    if j == d0: ok = false
  else:
    var dots = 0
    while j < s.len and s[j] in Digits + {'.'}:
      if s[j] == '.':
        # « 1..2 » : concaténation, pas un nombre décimal.
        if j + 1 < s.len and s[j + 1] == '.': break
        inc dots
      inc j
    if dots > 1: ok = false
    if j < s.len and s[j] in {'e', 'E'}:
      inc j
      if j < s.len and s[j] in {'+', '-'}: inc j
      let e0 = j
      while j < s.len and s[j] in Digits: inc j
      if j == e0: ok = false
  # un nombre collé à une lettre (« 3d ») est mal formé.
  if j < s.len and s[j] in LuaIdentChars:
    ok = false
    while j < s.len and s[j] in LuaIdentChars: inc j
  (j, ok)

proc escapeLen(s: string, i: int): int =
  # s[i] == '\\' dans une chaîne courte.
  if i + 1 >= s.len: return 1
  let c = s[i + 1]
  case c
  of 'x':
    var j = i + 2
    while j < s.len and j < i + 4 and s[j] in HexDigits: inc j
    j - i
  of 'u':
    if i + 2 < s.len and s[i + 2] == '{':
      let close = s.find('}', i + 3)
      if close >= 0: return close + 1 - i
    2
  of '0'..'9':
    var j = i + 1
    while j < s.len and j < i + 4 and s[j] in Digits: inc j
    j - i
  else: 2   # \n \t \" \\ et codes P8SCII (\* \# \- \| \+ \^ \a \b ...)

proc lexLine*(s: string, st: var LexState): seq[Token] =
  # Découpe une ligne en jetons. `st` est l'état à l'entrée de la ligne ;
  # il contient l'état de sortie au retour.
  var i = 0
  template push(k: TokKind, a, b: int) =
    if b > a: result.add Token(kind: k, start: a, len: b - a)

  # suite d'un commentaire / d'une chaîne longue.
  if st.mode != lmNormal:
    let k = if st.mode == lmLongComment: tkComment else: tkString
    let close = findLongClose(s, 0, st.level)
    if close < 0:
      push(k, 0, s.len)
      return
    push(k, 0, close)
    i = close
    st = LexState(mode: lmNormal)

  while i < s.len:
    let c = s[i]
    if c in {' ', '\t', '\r'}:
      var j = i
      while j < s.len and s[j] in {' ', '\t', '\r'}: inc j
      push(tkSpace, i, j)
      i = j
    elif c == '-' and i + 1 < s.len and s[i + 1] == '-':
      let lvl = longBracketLevel(s, i + 2)
      if lvl >= 0:
        let close = findLongClose(s, i + 4 + lvl, lvl)
        if close < 0:
          push(tkComment, i, s.len)
          st = LexState(mode: lmLongComment, level: lvl)
          return
        push(tkComment, i, close)
        i = close
      else:
        push(tkComment, i, s.len)
        i = s.len
    elif c == '[' and longBracketLevel(s, i) >= 0:
      let lvl = longBracketLevel(s, i)
      let close = findLongClose(s, i + 2 + lvl, lvl)
      if close < 0:
        push(tkString, i, s.len)
        st = LexState(mode: lmLongString, level: lvl)
        return
      push(tkString, i, close)
      i = close
    elif c in {'"', '\''}:
      var j = i + 1
      var segStart = i
      var closed = false
      while j < s.len:
        if s[j] == '\\':
          push(tkString, segStart, j)
          let n = escapeLen(s, j)
          push(tkEscape, j, min(s.len, j + n))
          j += n
          segStart = j
        elif s[j] == c:
          inc j
          closed = true
          break
        else:
          inc j
      j = min(j, s.len)
      push(if closed: tkString else: tkError, segStart, j)
      i = j
    elif c in Digits or (c == '.' and i + 1 < s.len and s[i + 1] in Digits):
      let (j, ok) = scanNumber(s, i)
      push(if ok: tkNumber else: tkError, i, j)
      i = j
    elif c in IdentStart:
      var j = i
      while j < s.len and s[j] in LuaIdentChars: inc j
      let w = s[i ..< j]
      let k =
        if isKeyword(w): tkKeyword
        elif isBuiltin(w): tkBuiltin
        else: tkIdent
      push(k, i, j)
      i = j
    elif c in Punct1:
      push(tkPunct, i, i + 1)
      inc i
    else:
      var matched = ""
      for op in Ops3:
        if s.continuesWith(op, i):
          matched = op
          break
      if matched.len == 0:
        for op in Ops2:
          if s.continuesWith(op, i):
            matched = op
            break
      if matched.len == 0 and c in Op1: matched = $c
      if matched.len > 0:
        push(if matched in PicoOps: tkPicoOp else: tkOperator, i, i + matched.len)
        i += matched.len
      else:
        # caractère inconnu (UTF-8 hors chaîne, '!', '@', '$', '`'...)
        var j = i + 1
        while j < s.len and (ord(s[j]) and 0xC0) == 0x80: inc j
        push(tkError, i, j)
        i = j

proc lexAll*(lines: openArray[string]): (seq[seq[Token]], seq[LexState]) =
  # Jetons de toutes les lignes et état d'entrée de chaque ligne.
  #(le tableau d'états a une case de plus : l'état en fin de texte).
  var st = LexState()
  var toks = newSeq[seq[Token]](lines.len)
  var states = newSeq[LexState](lines.len + 1)
  for i, l in lines:
    states[i] = st
    toks[i] = lexLine(l, st)
  states[lines.len] = st
  (toks, states)

when isMainModule:
  initLangDocs()
  var st = LexState()
  for l in ["if (x > 0) x -= 2 y = 1", "?\"hi\" a != b c \\= 2", "n = 0b1010 + 0x1.8p3 + 3d"]:
    var parts: seq[string]
    for t in lexLine(l, st):
      if t.kind != tkSpace: parts.add $t.kind & ":" & tokText(l, t)
    echo parts.join("  ")
