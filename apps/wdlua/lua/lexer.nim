# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
#   wdlua - analyseur lexical de l'interpréteur
#
# Lua 5.4 et les extensions du manuel (§9.2) : affectations composées
# (+= -= *= /= //= \= %= ^= ..= &= |= <<= >>=), division entière « \ »,
# différence « != », raccourci « ?expr » pour print, littéraux binaires 0b.

import std/strutils
from std/unicode import Rune, `$`
import core

type
  TokKind* = enum tkEOF, tkName, tkKeyword, tkString, tkInt, tkNum, tkOp

  Tok* = object
    kind*: TokKind
    text*: string        # nom, mot-clé, opérateur normalisé, ou contenu décodé de la chaîne.
    ival*: int64
    nval*: float64
    line*, col*: int

  SyntaxError* = object of CatchableError
    line*: int
    source*: string

const
  Keywords* = ["and", "break", "do", "else", "elseif", "end", "false", "for",
               "function", "goto", "if", "in", "local", "nil", "not", "or",
               "repeat", "return", "then", "true", "until", "while"]
  Ops3 = ["...", "..=", "//=", "<<=", ">>="]
  Ops2 = ["==", "~=", "<=", ">=", "//", "..", "::", "<<", ">>", "!=",
          "+=", "-=", "*=", "/=", "%=", "^=", "&=", "|=", "\\="]
  Ops1 = {'+', '-', '*', '/', '%', '^', '#', '&', '~', '|', '<', '>', '=',
          '(', ')', '{', '}', '[', ']', ';', ':', ',', '.', '\\', '?'}

proc synErr*(source: string, line: int, msg: string) {.noreturn.} =
  var e = newException(SyntaxError, source & ":" & $line & ": " & msg)
  e.line = line
  e.source = source
  raise e

proc tokenize*(src, source: string): seq[Tok] =
  var i = 0
  var line = 1
  var lineStart = 0
  let n = src.len
  template err(msg: string) = synErr(source, line, msg)
  template add(t: Tok) = result.add t

  proc longLevel(i: int): int =
    if i >= n or src[i] != '[': return -1
    var j = i + 1
    var lvl = 0
    while j < n and src[j] == '=':
      inc lvl
      inc j
    if j < n and src[j] == '[': lvl else: -1

  proc readLong(i: var int, lvl: int, line: var int, lineStart: var int, what: string): string =
    # i pointe sur le premier « [ » ; renvoie le contenu.
    i += lvl + 2
    if i < n and src[i] == '\r': inc i
    if i < n and src[i] == '\n':
      inc line
      inc i
      lineStart = i
    let start = i
    while i < n:
      if src[i] == ']':
        var j = i + 1
        var l = 0
        while j < n and src[j] == '=':
          inc l
          inc j
        if l == lvl and j < n and src[j] == ']':
          let content = src[start ..< i]
          i = j + 1
          return content
      if src[i] == '\n':
        inc line
        lineStart = i + 1
      inc i
    synErr(source, line, what & " long non fermé")

  if src.startsWith("#!"):
    while i < n and src[i] != '\n': inc i

  while i < n:
    let c = src[i]
    let col = i - lineStart
    case c
    of '\n':
      inc line
      inc i
      lineStart = i
    of ' ', '\t', '\r', '\f', '\v':
      inc i
    of '-':
      if i + 1 < n and src[i + 1] == '-':
        let lvl = longLevel(i + 2)
        if lvl >= 0:
          i += 2
          discard readLong(i, lvl, line, lineStart, "commentaire")
        else:
          while i < n and src[i] != '\n': inc i
      elif i + 1 < n and src[i + 1] == '=':
        add Tok(kind: tkOp, text: "-=", line: line, col: col)   # affectation composée
        i += 2
      else:
        add Tok(kind: tkOp, text: "-", line: line, col: col)
        inc i
    of '"', '\'':
      let q = c
      let startLine = line
      inc i
      var s = ""
      while true:
        if i >= n or src[i] == '\n': synErr(source, startLine, "chaîne non terminée")
        let ch = src[i]
        if ch == q:
          inc i
          break
        if ch == '\\':
          inc i
          if i >= n: err("chaîne non terminée")
          let e = src[i]
          case e
          of 'n':
            s.add '\n'
            inc i
          of 't':
            s.add '\t'
            inc i
          of 'r':
            s.add '\r'
            inc i
          of 'a':
            s.add '\a'
            inc i
          of 'b':
            s.add '\b'
            inc i
          of 'f':
            s.add '\f'
            inc i
          of 'v':
            s.add '\v'
            inc i
          of '\\':
            s.add '\\'
            inc i
          of '"':
            s.add '"'
            inc i
          of '\'':
            s.add '\''
            inc i
          of '\n':
            s.add '\n'
            inc line
            inc i
            lineStart = i
          of 'x':
            if i + 2 < n and src[i + 1] in HexDigits and src[i + 2] in HexDigits:
              s.add chr(parseHexInt(src[i + 1 .. i + 2]))
              i += 3
            else: err("séquence \\x invalide")
          of 'z':
            inc i
            while i < n and src[i] in Whitespace:
              if src[i] == '\n':
                inc line
                lineStart = i + 1
              inc i
          of 'u':
            if i + 1 < n and src[i + 1] == '{':
              let close = src.find('}', i + 2)
              if close < 0: err("séquence \\u invalide")
              let cp = parseHexInt(src[i + 2 ..< close])
              s.add $Rune(cp)
              i = close + 1
            else: err("séquence \\u invalide")
          of '0'..'9':
            var v = 0
            var k = 0
            while k < 3 and i < n and src[i] in Digits:
              v = v * 10 + (ord(src[i]) - ord('0'))
              inc i
              inc k
            if v > 255: err("séquence décimale trop grande")
            s.add chr(v)
          else:
            err("séquence d'échappement invalide « \\" & $e & " »")
        else:
          s.add ch
          inc i
      add Tok(kind: tkString, text: s, line: startLine, col: col)
    of '[':
      let lvl = longLevel(i)
      if lvl >= 0:
        let startLine = line
        let s = readLong(i, lvl, line, lineStart, "chaîne")
        add Tok(kind: tkString, text: s, line: startLine, col: col)
      else:
        add Tok(kind: tkOp, text: "[", line: line, col: col)
        inc i
    of '0'..'9':
      var j = i
      if c == '0' and j + 1 < n and src[j + 1] in {'x', 'X'}:
        j += 2
        while j < n and (src[j] in HexDigits + {'.'} or
                         (src[j] in {'p', 'P'}) or
                         (src[j] in {'+', '-'} and src[j - 1] in {'p', 'P'})): inc j
      elif c == '0' and j + 1 < n and src[j + 1] in {'b', 'B'}:
        j += 2
        while j < n and src[j] in {'0', '1'}: inc j
      else:
        while j < n and (src[j] in Digits or
                         (src[j] == '.' and not (j + 1 < n and src[j + 1] == '.')) or
                         src[j] in {'e', 'E'} or
                         (src[j] in {'+', '-'} and src[j - 1] in {'e', 'E'})): inc j
      if j < n and src[j] in IdentChars: err("nombre mal formé près de « " & src[i .. j] & " »")
      let txt = src[i ..< j]
      let (ok, v) = str2number(txt)
      if not ok: err("nombre mal formé « " & txt & " »")
      if v.kind == vkInt: add Tok(kind: tkInt, ival: v.i, text: txt, line: line, col: col)
      else: add Tok(kind: tkNum, nval: v.n, text: txt, line: line, col: col)
      i = j
    of '.':
      if i + 1 < n and src[i + 1] in Digits:
        var j = i + 1
        while j < n and (src[j] in Digits or src[j] in {'e', 'E'} or
                         (src[j] in {'+', '-'} and src[j - 1] in {'e', 'E'})): inc j
        let (ok, v) = str2number("0" & src[i ..< j])
        if not ok: err("nombre mal formé")
        add Tok(kind: tkNum, nval: (if v.kind == vkNum: v.n else: float64(v.i)), text: src[i ..< j],
                line: line, col: col)
        i = j
      else:
        var op = "."
        if src.continuesWith("...", i): op = "..."
        elif src.continuesWith("..=", i): op = "..="
        elif src.continuesWith("..", i): op = ".."
        add Tok(kind: tkOp, text: op, line: line, col: col)
        i += op.len
    of 'a'..'z', 'A'..'Z', '_':
      var j = i
      while j < n and src[j] in IdentChars: inc j
      let w = src[i ..< j]
      add Tok(kind: (if w in Keywords: tkKeyword else: tkName), text: w, line: line, col: col)
      i = j
    else:
      var op = ""
      for o in Ops3:
        if src.continuesWith(o, i):
          op = o
          break
      if op.len == 0:
        for o in Ops2:
          if src.continuesWith(o, i):
            op = o
            break
      if op.len == 0 and c in Ops1: op = $c
      if op.len == 0: err("caractère inattendu « " & $c & " »")
      i += op.len
      # normalisation des extensions du manuel
      let norm = case op
        of "!=": "~="
        of "\\": "//"
        of "\\=": "//="
        else: op
      add Tok(kind: tkOp, text: norm, line: line, col: col)
  result.add Tok(kind: tkEOF, line: line, col: 0)
