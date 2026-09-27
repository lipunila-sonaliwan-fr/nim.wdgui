# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
# Line-by-line Nim lexer used for syntax highlighting.
# The state carried from one line to the next handles multi-line comments `#[ ]#`,
# documentation comments `##[ ]##` and triple-quoted strings.
import std/strutils

type
  TokKind* = enum
    tkText, tkKeyword, tkType, tkBuiltin, tkProcName, tkString, tkNumber,
    tkComment, tkDocComment, tkPragma, tkOperator, tkPunct
  Token* = object
    kind*: TokKind
    start*, len*: int            # byte offsets inside the line
  LexState* = enum
    lsNormal, lsBlockComment, lsDocComment, lsTripleString

const
  keywords* = ["addr", "and", "as", "asm", "bind", "block", "break", "case", "cast", "concept",
    "const", "continue", "converter", "defer", "discard", "distinct", "div", "do", "elif", "else",
    "end", "enum", "except", "export", "finally", "for", "from", "func", "if", "import", "in",
    "include", "interface", "is", "isnot", "iterator", "let", "macro", "method", "mixin", "mod",
    "nil", "not", "notin", "object", "of", "or", "out", "proc", "ptr", "raise", "ref", "return",
    "shl", "shr", "static", "template", "try", "tuple", "type", "using", "var", "when", "while",
    "xor", "yield"]
  builtinTypes = ["int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16", "uint32",
    "uint64", "float", "float32", "float64", "bool", "char", "string", "cstring", "pointer",
    "seq", "array", "openArray", "set", "range", "varargs", "untyped", "typed", "auto", "void",
    "byte", "Natural", "Positive", "cint", "cfloat", "csize_t", "typedesc", "sink", "lent"]
  builtins = ["true", "false", "result", "echo", "len", "high", "low", "add", "inc", "dec",
    "assert", "doAssert", "new", "newSeq", "sizeof", "ord", "chr", "quit", "items", "pairs",
    "min", "max", "abs", "succ", "pred", "defined", "declared", "compiles", "isNil", "setLen",
    "newString", "toSeq", "debugEcho", "stdout", "stderr", "stdin", "self"]
  routineWords = ["proc", "func", "method", "iterator", "template", "macro", "converter"]

proc isIdentStart(c: char): bool = c.isAlphaAscii or c == '_' or ord(c) >= 128

proc isIdentChar(c: char): bool = c.isAlphaNumeric or c == '_' or ord(c) >= 128

proc classify(word: string, afterRoutine: bool): TokKind =
  if afterRoutine: tkProcName
  elif word in keywords: tkKeyword
  elif word in builtinTypes: tkType
  elif word in builtins: tkBuiltin
  elif word.len > 0 and word[0].isUpperAscii: tkType
  else: tkText

proc lexLine*(line: string, state: var LexState, depth: var int): seq[Token] =
  # Tokens of one line; `state` / `depth` are updated for the next line.
  let n = line.len
  var i = 0
  var afterRoutine = false
  template emitTok(k: TokKind, a, b: int) =
    if b > a: result.add Token(kind: k, start: a, len: b - a)

  # continuation of a multi-line construct.
  case state
  of lsBlockComment, lsDocComment:
    let k = if state == lsDocComment: tkDocComment else: tkComment
    var j = 0
    while j < n:
      if j + 1 < n and line[j] == '#' and line[j + 1] == '[':
        inc depth
        j += 2
      elif j + 1 < n and line[j] == ']' and line[j + 1] == '#':
        dec depth
        j += 2
        if depth <= 0:
          if state == lsDocComment and j < n and line[j] == '#': inc j
          state = lsNormal
          depth = 0
          break
      else: inc j
    emitTok(k, 0, j)
    i = j
  of lsTripleString:
    let p = line.find("\"\"\"")
    if p < 0:
      emitTok(tkString, 0, n)
      return
    emitTok(tkString, 0, p + 3)
    i = p + 3
    state = lsNormal
  of lsNormal: discard

  while i < n:
    let c = line[i]
    if c == ' ' or c == '\t':
      inc i
      continue
    let s = i
    if c == '#':
      if i + 1 < n and line[i + 1] == '[':
        state = lsBlockComment
        depth = 1
        var j = i + 2
        while j < n:
          if j + 1 < n and line[j] == '#' and line[j + 1] == '[':
            inc depth
            j += 2
          elif j + 1 < n and line[j] == ']' and line[j + 1] == '#':
            dec depth
            j += 2
            if depth <= 0:
              state = lsNormal
              break
          else: inc j
        emitTok(tkComment, s, j)
        i = j
      elif i + 2 < n and line[i + 1] == '#' and line[i + 2] == '[':
        state = lsDocComment
        depth = 1
        let p = line.find("]##", i + 3)
        if p >= 0:
          state = lsNormal
          emitTok(tkDocComment, s, p + 3)
          i = p + 3
        else:
          emitTok(tkDocComment, s, n)
          i = n
      else:
        emitTok((if i + 1 < n and line[i + 1] == '#': tkDocComment else: tkComment), s, n)
        i = n
    elif c == '"':
      if i + 2 < n and line[i + 1] == '"' and line[i + 2] == '"':
        let p = line.find("\"\"\"", i + 3)
        if p < 0:
          emitTok(tkString, s, n)
          state = lsTripleString
          i = n
        else:
          emitTok(tkString, s, p + 3)
          i = p + 3
      else:
        var j = i + 1
        while j < n and line[j] != '"':
          if line[j] == '\\': inc j
          inc j
        emitTok(tkString, s, min(n, j + 1))
        i = min(n, j + 1)
    elif c == '\'':
      var j = i + 1
      if j < n and line[j] == '\\': j += 2
      else: inc j
      if j < n and line[j] == '\'':
        emitTok(tkString, s, j + 1)
        i = j + 1
      else:
        emitTok(tkPunct, s, i + 1)
        inc i
    elif c.isDigit:
      var j = i + 1
      while j < n and (line[j].isAlphaNumeric or line[j] in {'_', '.', '\''}):
        if line[j] == '.' and (j + 1 >= n or not line[j + 1].isDigit): break
        inc j
      emitTok(tkNumber, s, j)
      i = j
    elif c.isIdentStart:
      var j = i + 1
      while j < n and line[j].isIdentChar: inc j
      let word = line[s ..< j]
      if j < n and line[j] == '"':                       # raw / generalized string: r"...", fmt"..."
        var k = j + 1
        while k < n and line[k] != '"': inc k
        emitTok(tkString, s, min(n, k + 1))
        i = min(n, k + 1)
        continue
      emitTok(classify(word, afterRoutine), s, j)
      afterRoutine = word in routineWords
      i = j
      continue
    elif c == '{' and i + 1 < n and line[i + 1] == '.':
      let p = line.find(".}", i + 2)
      let e = if p < 0: n else: p + 2
      emitTok(tkPragma, s, e)
      i = e
    elif c == '`':
      let p = line.find('`', i + 1)
      let e = if p < 0: n else: p + 1
      emitTok((if afterRoutine: tkProcName else: tkText), s, e)
      i = e
      afterRoutine = false
      continue
    elif c in "=+-*/<>@$~&%|!?^.:\\":
      var j = i + 1
      while j < n and line[j] in "=+-*/<>@$~&%|!?^.:\\": inc j
      emitTok(tkOperator, s, j)
      i = j
      if afterRoutine and line[s ..< j] == "*": continue          # exported routine: keep the name.
    else:
      emitTok(tkPunct, s, i + 1)
      inc i
    afterRoutine = false

proc codeTail*(line: string, toks: seq[Token]): char =
  # Last significant character of the line, ignoring comments (' ' if none).
  for i in countdown(toks.high, 0):
    let t = toks[i]
    if t.kind notin {tkComment, tkDocComment}:
      return line[t.start + t.len - 1]
  ' '
