# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
#   wdlua - IDE : jetons de coloration au format de l'éditeur de wdnim
#
# L'éditeur (codeeditor.nim) est un portage de celui de wdnim, qui attend
# l'interface de son nimlexer : TokKind (12 catégories), Token, LexState,
# lexLine(line, state, depth) et codeTail. Ce module la fournit pour Lua en
# s'appuyant sur lualang.nim.

from lualang as ll import nil

type
  TokKind* = enum
    tkText, tkKeyword, tkType, tkBuiltin, tkProcName, tkString, tkNumber,
    tkComment, tkDocComment, tkPragma, tkOperator, tkPunct
  Token* = object
    kind*: TokKind
    start*, len*: int            # octets dans la ligne.
  LexState* = enum
    lsNormal, lsBlockComment, lsLongString

proc lexLine*(line: string, state: var LexState, depth: var int): seq[Token] =
  # Jetons d'une ligne ; `state` / `depth` (niveau du crochet long) pour la suivante.
  var st = ll.LexState()
  case state
  of lsNormal: st.mode = ll.lmNormal
  of lsBlockComment: st.mode = ll.lmLongComment
  of lsLongString: st.mode = ll.lmLongString
  st.level = depth
  let toks = ll.lexLine(line, st)
  case st.mode
  of ll.lmNormal: state = lsNormal
  of ll.lmLongComment: state = lsBlockComment
  of ll.lmLongString: state = lsLongString
  depth = st.level
  var afterFunction = false
  for t in toks:
    let txt = ll.tokText(line, t)
    var k: TokKind
    case t.kind
    of ll.tkSpace:
      continue
    of ll.tkKeyword:
      k = tkKeyword
      afterFunction = txt == "function"
    of ll.tkIdent, ll.tkCallback:
      if afterFunction: k = tkProcName
      elif txt == "self": k = tkType
      elif txt.len > 0 and txt[0] in {'A'..'Z'}: k = tkType
      else: k = tkText
    of ll.tkBuiltin:
      k = if afterFunction: tkProcName else: tkBuiltin
    of ll.tkNumber: k = tkNumber
    of ll.tkString, ll.tkEscape: k = tkString
    of ll.tkComment, ll.tkPod:
      k = if txt.len >= 3 and txt[0 .. 2] == "---": tkDocComment else: tkComment
    of ll.tkPicoOp: k = tkPragma                 # extensions du manuel : +=, !=, \, ?
    of ll.tkOperator:
      k = tkOperator
      if txt notin [".", ":"]: afterFunction = false
    of ll.tkPunct:
      k = tkPunct
      afterFunction = false
    of ll.tkError: k = tkPragma
    result.add Token(kind: k, start: t.start, len: t.len)

proc codeTail*(line: string, toks: seq[Token]): char =
  # Dernier caractère significatif de la ligne, hors commentaires (' ' si aucun).
  for i in countdown(toks.high, 0):
    let t = toks[i]
    if t.kind notin {tkComment, tkDocComment}:
      return line[t.start + t.len - 1]
  ' '
