# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
#   wdlua - motifs Lua (portage de l'algorithme de lstrlib.c)
#
# Classes %a %c %d %g %l %p %s %u %w %x (et majuscules = complément),
# ensembles [...], quantificateurs * + - ?, ancres ^ $, captures ( ),
# captures de position (), %b, %f, références arrière %1..%9.

import std/strutils

const
  MaxCaptures = 32
  CapUnfinished = -1
  CapPosition = -2
  MaxDepth = 200

type
  PatternError* = object of CatchableError

  MatchState* = object
    src*, pat*: string
    level*: int
    capture*: array[MaxCaptures, tuple[init, len: int]]
    depth: int

proc perr(msg: string) {.noreturn.} = raise newException(PatternError, msg)

proc classEnd(ms: MatchState, p: int): int =
  var p = p
  let c = ms.pat[p]
  inc p
  if c == '%':
    if p >= ms.pat.len: perr("motif mal formé (se termine par '%')")
    return p + 1
  if c == '[':
    if p < ms.pat.len and ms.pat[p] == '^': inc p
    while true:                       # chercher le ']' (le premier caractère peut être ']').
      if p >= ms.pat.len: perr("motif mal formé (']' manquant)")
      let cc = ms.pat[p]
      inc p
      if cc == '%' and p < ms.pat.len: inc p
      if p < ms.pat.len and ms.pat[p] == ']': break
    return p + 1
  p

proc singleClass(c: char, cl: char): bool =
  var res: bool
  case cl.toLowerAscii
  of 'a': res = c.isAlphaAscii
  of 'c': res = ord(c) < 32 or ord(c) == 127
  of 'd': res = c in Digits
  of 'g': res = ord(c) > 32 and ord(c) < 127
  of 'l': res = c in {'a'..'z'}
  of 'p': res = ord(c) > 32 and ord(c) < 127 and not c.isAlphaNumeric
  of 's': res = c in {' ', '\t', '\n', '\v', '\f', '\r'}
  of 'u': res = c in {'A'..'Z'}
  of 'w': res = c.isAlphaNumeric
  of 'x': res = c in HexDigits
  else: return cl == c
  if cl.isUpperAscii: not res else: res

proc matchBracketClass(ms: MatchState, c: char, pStart, ec: int): bool =
  # pStart pointe sur '[', ec sur le ']' final.
  var sig = true
  var p = pStart + 1
  if ms.pat[p] == '^':
    sig = false
    inc p
  while p < ec:
    if ms.pat[p] == '%':
      inc p
      if singleClass(c, ms.pat[p]): return sig
      inc p
    elif p + 2 < ec and ms.pat[p + 1] == '-':
      if ms.pat[p] <= c and c <= ms.pat[p + 2]: return sig
      p += 3
    else:
      if ms.pat[p] == c: return sig
      inc p
  not sig

proc singleMatch(ms: MatchState, s, p, ep: int): bool =
  if s >= ms.src.len: return false
  let c = ms.src[s]
  case ms.pat[p]
  of '.': true
  of '%': singleClass(c, ms.pat[p + 1])
  of '[': matchBracketClass(ms, c, p, ep - 1)
  else: ms.pat[p] == c

proc doMatch(ms: var MatchState, s, p: int): int

proc maxExpand(ms: var MatchState, s, p, ep: int): int =
  var i = 0
  while singleMatch(ms, s + i, p, ep): inc i
  while i >= 0:
    let r = doMatch(ms, s + i, ep + 1)
    if r != -1: return r
    dec i
  -1

proc minExpand(ms: var MatchState, s, p, ep: int): int =
  var s = s
  while true:
    let r = doMatch(ms, s, ep + 1)
    if r != -1: return r
    if singleMatch(ms, s, p, ep): inc s
    else: return -1

proc startCapture(ms: var MatchState, s, p, what: int): int =
  if ms.level >= MaxCaptures: perr("trop de captures")
  ms.capture[ms.level] = (s, what)
  inc ms.level
  result = doMatch(ms, s, p)
  if result == -1: dec ms.level

proc captureToClose(ms: MatchState): int =
  for l in countdown(ms.level - 1, 0):
    if ms.capture[l].len == CapUnfinished: return l
  perr("capture de motif invalide")

proc endCapture(ms: var MatchState, s, p: int): int =
  let l = captureToClose(ms)
  ms.capture[l].len = s - ms.capture[l].init
  result = doMatch(ms, s, p)
  if result == -1: ms.capture[l].len = CapUnfinished

proc matchBalance(ms: MatchState, s, p: int): int =
  if p + 1 >= ms.pat.len: perr("arguments manquants pour '%b'")
  if s >= ms.src.len or ms.src[s] != ms.pat[p]: return -1
  let b = ms.pat[p]
  let e = ms.pat[p + 1]
  var cont = 1
  var s = s + 1
  while s < ms.src.len:
    if ms.src[s] == e:
      dec cont
      if cont == 0: return s + 1
    elif ms.src[s] == b: inc cont
    inc s
  -1

proc checkCapture(ms: MatchState, l: char): int =
  let i = ord(l) - ord('1')
  if i < 0 or i >= ms.level or ms.capture[i].len == CapUnfinished:
    perr("index de capture invalide %" & $(i + 1))
  i

proc matchCapture(ms: MatchState, s: int, l: char): int =
  let i = checkCapture(ms, l)
  let ln = ms.capture[i].len
  let init = ms.capture[i].init
  if ms.src.len - s >= ln and ms.src[init ..< init + ln] == ms.src[s ..< s + ln]: s + ln
  else: -1

proc doMatch(ms: var MatchState, s, p: int): int =
  inc ms.depth
  if ms.depth > MaxDepth: perr("motif trop complexe")
  defer: dec ms.depth
  var s = s
  var p = p
  while true:
    if p >= ms.pat.len: return s
    var useDefault = false
    case ms.pat[p]
    of '(':
      if p + 1 < ms.pat.len and ms.pat[p + 1] == ')':
        return startCapture(ms, s, p + 2, CapPosition)
      return startCapture(ms, s, p + 1, CapUnfinished)
    of ')':
      return endCapture(ms, s, p + 1)
    of '$':
      if p + 1 == ms.pat.len:
        return (if s == ms.src.len: s else: -1)
      useDefault = true
    of '%':
      if p + 1 < ms.pat.len and ms.pat[p + 1] == 'b':
        s = matchBalance(ms, s, p + 2)
        if s == -1: return -1
        p += 4
        continue
      elif p + 1 < ms.pat.len and ms.pat[p + 1] == 'f':
        p += 2
        if p >= ms.pat.len or ms.pat[p] != '[': perr("'[' manquant après '%f' dans le motif")
        let ep = classEnd(ms, p)
        let prev = if s == 0: '\0' else: ms.src[s - 1]
        let curc = if s < ms.src.len: ms.src[s] else: '\0'
        if not matchBracketClass(ms, prev, p, ep - 1) and matchBracketClass(ms, curc, p, ep - 1):
          p = ep
          continue
        return -1
      elif p + 1 < ms.pat.len and ms.pat[p + 1] in Digits:
        s = matchCapture(ms, s, ms.pat[p + 1])
        if s == -1: return -1
        p += 2
        continue
      else:
        useDefault = true
    else:
      useDefault = true
    if useDefault:
      let ep = classEnd(ms, p)
      let epc = if ep < ms.pat.len: ms.pat[ep] else: '\0'
      if not singleMatch(ms, s, p, ep):
        if epc in {'*', '?', '-'}:
          p = ep + 1
          continue
        return -1
      case epc
      of '?':
        let r = doMatch(ms, s + 1, ep + 1)
        if r != -1: return r
        p = ep + 1
      of '+': return maxExpand(ms, s + 1, p, ep)
      of '*': return maxExpand(ms, s, p, ep)
      of '-': return minExpand(ms, s, p, ep)
      else:
        inc s
        p = ep

type Capture* = object
  isPos*: bool
  pos*: int          # position (1-based) pour une capture ().
  str*: string

proc getCapture*(ms: MatchState, i, s, e: int): Capture =
  if i >= ms.level:
    if i == 0: return Capture(str: ms.src[s ..< e])
    perr("index de capture invalide")
  let c = ms.capture[i]
  if c.len == CapUnfinished: perr("capture non terminée")
  if c.len == CapPosition: return Capture(isPos: true, pos: c.init + 1)
  Capture(str: ms.src[c.init ..< c.init + c.len])

proc captures*(ms: MatchState, s, e: int, wholeIfNone: bool): seq[Capture] =
  let n = if ms.level == 0 and wholeIfNone: 1 else: ms.level
  for i in 0 ..< n: result.add getCapture(ms, i, s, e)

proc initMatch*(src, pat: string): MatchState =
  MatchState(src: src, pat: pat)

proc matchAt*(ms: var MatchState, s, p: int): int =
  ms.level = 0
  ms.depth = 0
  doMatch(ms, s, p)

proc hasSpecials*(pat: string): bool =
  for c in pat:
    if c in {'^', '$', '*', '+', '?', '.', '(', ')', '[', ']', '%', '-'}: return true
  false
