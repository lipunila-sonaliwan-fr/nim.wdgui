# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
# Types shared by the LSP client and the editor.

type
  Diagnostic* = object
    line*, col*, endLine*, endCol*: int   ## 0-based; columns in characters (runes)
    severity*: int                        ## 1 error, 2 warning, 3 information, 4 hint
    message*, source*: string

  CompletionItem* = object
    label*, detail*, insertText*, documentation*: string
    kind*: int                            ## LSP CompletionItemKind

proc severityName*(s: int): string =
  case s
  of 1: "Error"
  of 2: "Warning"
  of 3: "Info"
  else: "Hint"

proc kindBadge*(kind: int): tuple[letter: string, hue: int] =
  ## One-letter badge and color index for a completion kind.
  case kind
  of 2, 3, 4: ("p", 0)          # method / function / constructor
  of 5, 10: ("f", 1)            # field / property
  of 6: ("v", 2)                # variable
  of 7, 8, 13, 22, 25: ("t", 3) # class, interface, enum, struct, type parameter
  of 9: ("m", 4)                # module
  of 14: ("k", 5)               # keyword
  of 12, 20, 21: ("c", 1)       # value, enum member, constant
  of 15: ("s", 4)               # snippet
  of 24: ("o", 4)               # operator
  else: ("·", 4)
