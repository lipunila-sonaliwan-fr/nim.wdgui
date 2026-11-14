# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
#
# codegen.nim - "Compile the visual" (graph -> NCP) and the reverse
#
#
# The generated NCP text is at the same time:
#  * a model directly executable by the solver (and by `cpsat`);
#  * the document's save format: the graph is described in it by
#    annotation comments, which the solver ignores.
#
#   //@wdreka 1
#   //@doc titre="Workshop" horizon="48" unite="h" timeout="30" solutions="0"
#   //@node n3 tache x="120" y="80" titre="Cutting" duree="3"
#   //@link n3.task -> n7.avant
#   //@begin n3 tache
#   ... NCP code generated from the component template ...
#   //@end n3
#
# Templates (`code` field of components):
#   {{id}}                node identifier (n3)
#   {{titre}}             node title (escaped for an NCP string)
#   {{p:name}}            value of parameter `name`
#   {{in:port}}           prefix of the output linked to input `port`
#                         (n2_task); error if not linked
#   {{in:port?default}}   same, `default` if not linked
#   {{list:port:suffix}}  list "a_suffix, b_suffix, ..." of the outputs
#                         linked to the multiple input `port`
#   {{count:port}}        number of links entering `port`
#   {{expr:param}}        parameter value in which every input name
#                         (e.g. a, b) is replaced by the linked output
#   {{if:port}} … {{fi}}      text kept only if `port` is linked
#   {{ifnot:port}} … {{fi}}   text kept only if `port` is not linked
# A `task` output of node n3 is named n3_task; the template defines the
# names derived from it (n3_task_s, n3_task_d, n3_task_e...).

import std/[tables, strutils, algorithm, sets]
import model

type
  CodegenError* = object of CatchableError

  BlockSpan* = object
    node*: string
    first*, last*: int            # lines (1-based) of the block in the text

proc cgErr(msg: string) {.noreturn.} =
  raise newException(CodegenError, msg)

#
# Escaping of annotation values
#

proc quoteVal*(s: string): string =
  result = "\""
  for ch in s:
    case ch
    of '"': result.add "\\\""
    of '\\': result.add "\\\\"
    of '\n': result.add "\\n"
    of '\r': discard
    of '\t': result.add "\\t"
    else: result.add ch
  result.add "\""

proc ncpString(s: string): string =
  # text that is safe inside an NCP string
  for ch in s:
    case ch
    of '"': result.add "\\\""
    of '\\': result.add "\\\\"
    of '\n': result.add "\\n"
    else: result.add ch

proc parseAttrs*(s: string): OrderedTable[string, string] =
  # key="value" key2="..." (quoted, escaped values)
  result = initOrderedTable[string, string]()
  var i = 0
  while i < s.len:
    while i < s.len and s[i] in Whitespace: inc i
    if i >= s.len: break
    var key = ""
    while i < s.len and s[i] notin {'=', ' ', '\t'}:
      key.add s[i]
      inc i
    if i >= s.len or s[i] != '=':
      result[key] = ""
      continue
    inc i
    var val = ""
    if i < s.len and s[i] == '"':
      inc i
      while i < s.len and s[i] != '"':
        if s[i] == '\\' and i + 1 < s.len:
          inc i
          case s[i]
          of 'n': val.add '\n'
          of 't': val.add '\t'
          else: val.add s[i]
        else:
          val.add s[i]
        inc i
      inc i
    else:
      while i < s.len and s[i] notin Whitespace:
        val.add s[i]
        inc i
    result[key] = val

#
# Template expansion
#

proc sourcesOf(d: Document, n: Node, port: string): seq[Link] =
  result = d.linksInto(n.id, port)
  # stable order: top to bottom on the canvas
  proc ypos(l: Link): float =
    let s = d.findNode(l.src)
    result = (if s == nil: 0.0 else: s.y)
  result.sort(proc (a, b: Link): int = cmp(ypos(a), ypos(b)))

proc resolveConditionals(d: Document, n: Node, tpl0: string): string =
  var tpl = tpl0
  while true:
    let a = tpl.find("{{if")
    if a < 0: break
    let close = tpl.find("}}", a)
    if close < 0:
      cgErr(n.id & ": '{{if' without '}}' in the template")
    let head = tpl[a + 2 ..< close].strip()          # if:port / ifnot:port
    let fi = tpl.find("{{fi}}", close)
    if fi < 0:
      cgErr(n.id & ": {{" & head & "}} without {{fi}}")
    var keep = false
    if head.startsWith("ifnot:"):
      keep = sourcesOf(d, n, head[6 .. ^1].strip()).len == 0
    elif head.startsWith("if:"):
      keep = sourcesOf(d, n, head[3 .. ^1].strip()).len > 0
    else:
      cgErr(n.id & ": unknown conditional tag {{" & head & "}}")
    let inner = tpl[close + 2 ..< fi]
    tpl = tpl[0 ..< a] & (if keep: inner else: "") & tpl[fi + 6 .. ^1]
  result = tpl

proc substituteInputs(d: Document, lib: Library, n: Node, expr: string): string =
  # replaces identifiers equal to an input name by the linked output
  var inputs: seq[string] = @[]
  if lib.comps.hasKey(n.comp):
    for p in lib.comps[n.comp].inputs: inputs.add p.name
  var i = 0
  while i < expr.len:
    if expr[i] in IdentStartChars:
      var j = i
      while j < expr.len and expr[j] in IdentChars: inc j
      let word = expr[i ..< j]
      if word in inputs:
        let src = sourcesOf(d, n, word)
        if src.len == 0:
          cgErr(n.id & " (" & n.nodeLabel(lib) & "): input \"" & word &
                "\" is used in the expression but is not linked")
        result.add src[0].src & "_" & src[0].srcPort
      else:
        result.add word
      i = j
    elif expr[i] == '"':
      var j = i + 1
      while j < expr.len and expr[j] != '"':
        if expr[j] == '\\': inc j
        inc j
      result.add expr[i .. min(j, expr.len - 1)]
      i = j + 1
    else:
      result.add expr[i]
      inc i

proc expandTemplate*(d: Document, lib: Library, n: Node, tpl0: string): string =
  let comp = (if lib.comps.hasKey(n.comp): lib.comps[n.comp] else: nil)
  let tpl = resolveConditionals(d, n, tpl0)
  var i = 0
  while i < tpl.len:
    if i + 1 < tpl.len and tpl[i] == '{' and tpl[i + 1] == '{':
      let j = tpl.find("}}", i + 2)
      if j < 0:
        cgErr(n.id & ": '{{' without '}}' in the template")
      let key = tpl[i + 2 ..< j].strip()
      i = j + 2
      if key == "id":
        result.add n.id
      elif key == "titre":
        result.add ncpString(n.nodeLabel(lib))
      elif key.startsWith("p:"):
        let name = key[2 .. ^1]
        if not n.params.hasKey(name):
          cgErr(n.id & ": unknown parameter '" & name & "'")
        var v = n.params[name]
        if comp != nil:
          for p in comp.params:
            if p.name == name and p.kind == "text":
              v = ncpString(v)
        if v.strip().len == 0 and comp != nil:
          for p in comp.params:
            if p.name == name and p.kind in ["int", "expr"]:
              cgErr(n.id & " (" & n.nodeLabel(lib) & "): parameter '" &
                    p.label & "' is empty")
        result.add v
      elif key.startsWith("in:"):
        var port = key[3 .. ^1]
        var default = ""
        var hasDefault = false
        let q = port.find('?')
        if q >= 0:
          default = port[q + 1 .. ^1]
          port = port[0 ..< q]
          hasDefault = true
        let src = sourcesOf(d, n, port)
        if src.len == 0:
          if hasDefault:
            result.add default
          else:
            cgErr(n.id & " (" & n.nodeLabel(lib) & "): input \"" & port &
                  "\" must be linked")
        else:
          result.add src[0].src & "_" & src[0].srcPort
      elif key.startsWith("list:"):
        let parts = key[5 .. ^1].split(':')
        let port = parts[0]
        let suffix = (if parts.len > 1: parts[1] else: "")
        var items: seq[string] = @[]
        for l in sourcesOf(d, n, port):
          items.add l.src & "_" & l.srcPort & suffix
        result.add items.join(", ")
      elif key.startsWith("expr:"):
        let name = key[5 .. ^1]
        if not n.params.hasKey(name):
          cgErr(n.id & ": unknown parameter '" & name & "'")
        result.add substituteInputs(d, lib, n, n.params[name])
      elif key.startsWith("count:"):
        result.add $sourcesOf(d, n, key[6 .. ^1]).len
      else:
        cgErr(n.id & ": unknown template tag {{" & key & "}}")
    else:
      result.add tpl[i]
      inc i

proc nodeCode*(d: Document, lib: Library, n: Node): string =
  if n.customCode.len > 0:
    return n.customCode
  if not lib.comps.hasKey(n.comp):
    cgErr(n.id & ": unknown component \"" & n.comp & "\" (missing library?)")
  result = expandTemplate(d, lib, n, lib.comps[n.comp].code).strip(leading = false)

#
# Graph -> NCP text
#

proc topoOrder(d: Document): seq[Node] =
  var indeg = initTable[string, int]()
  for n in d.nodes: indeg[n.id] = 0
  for l in d.links:
    if indeg.hasKey(l.dst): indeg[l.dst] = indeg[l.dst] + 1
  var ready: seq[Node] = @[]
  for n in d.nodes:
    if indeg[n.id] == 0: ready.add n
  var done = initHashSet[string]()
  while ready.len > 0:
    # reading order: top to bottom, left to right
    ready.sort(proc (a, b: Node): int =
      result = cmp(a.y, b.y)
      if result == 0: result = cmp(a.x, b.x))
    let n = ready[0]
    ready.delete(0)
    result.add n
    done.incl n.id
    for l in d.links:
      if l.src == n.id and indeg.hasKey(l.dst):
        indeg[l.dst] = indeg[l.dst] - 1
        if indeg[l.dst] == 0:
          let m = d.findNode(l.dst)
          if m != nil and m.id notin done: ready.add m
  if result.len != d.nodes.len:
    var cyc: seq[string] = @[]
    for n in d.nodes:
      if n.id notin done: cyc.add n.id
    cgErr("cycle in the graph (nodes " & cyc.join(", ") &
          "): links must go from definitions to their uses")

proc annotationLines*(d: Document): seq[string] =
  # Graph description only (no code): enough to rebuild it.
  var lines: seq[string] = @[]
  lines.add "//@wdreka 1"
  lines.add "//@doc titre=" & quoteVal(d.title) & " horizon=" & quoteVal($d.horizon) &
            " unite=" & quoteVal(d.unit) & " timeout=" & quoteVal($d.timeout) &
            " solutions=" & quoteVal($d.maxSolutions)
  for n in d.nodes:
    var s = "//@node " & n.id & " " & n.comp & " x=" & quoteVal($int(n.x)) &
            " y=" & quoteVal($int(n.y))
    if n.title.len > 0: s.add " titre=" & quoteVal(n.title)
    for k, v in n.params.pairs: s.add " " & k & "=" & quoteVal(v)
    lines.add s
  for l in d.links:
    lines.add "//@link " & l.src & "." & l.srcPort & " -> " & l.dst & "." & l.dstPort
  result = lines

proc compileGraph*(d: Document, lib: Library): (string, seq[BlockSpan]) =
  # Produces the annotated NCP text and the position of each node block.
  var lines = annotationLines(d)
  var spans: seq[BlockSpan] = @[]
  lines.add ""
  lines.add "// ---- Model generated by wdreka: « " & d.title & " » ----"
  lines.add "//@begin __doc"
  lines.add "const HORIZON = " & $d.horizon & ";"
  lines.add "//@end __doc"
  for n in topoOrder(d):
    let code = nodeCode(d, lib, n)
    lines.add ""
    lines.add "//@begin " & n.id & " " & n.comp &
              (if n.customCode.len > 0: " custom" else: "")
    let first = lines.len + 1
    for cl in code.splitLines():
      lines.add cl
    spans.add BlockSpan(node: n.id, first: first, last: lines.len)
    lines.add "//@end " & n.id
  result = (lines.join("\n") & "\n", spans)

proc blockSpans*(text: string): seq[BlockSpan] =
  # Finds the //@begin ... //@end blocks of a text (to locate an error).
  var cur = ""
  var first = 0
  var i = 0
  for line in text.splitLines():
    inc i
    let t = line.strip()
    if t.startsWith("//@begin "):
      let p = t[9 .. ^1].splitWhitespace()
      if p.len > 0:
        cur = p[0]
        first = i + 1
    elif t.startsWith("//@end") and cur.len > 0:
      result.add BlockSpan(node: cur, first: first, last: i - 1)
      cur = ""

proc nodeAtLine*(text: string, line: int): string =
  for b in blockSpans(text):
    if line >= b.first and line <= b.last:
      return b.node
  result = ""

#
# NCP text -> graph
#

proc importText*(text: string, lib: Library): (Document, seq[string]) =
  # Rebuilds a document from an NCP text.
  # * //@ annotations -> nodes, links, settings;
  # * node block edited by hand -> custom code of the node;
  # * free code (outside blocks) -> "NCP block" node.
  let d = newDocument()
  var notes: seq[string] = @[]
  var blocks = initTable[string, string]()
  var free: seq[string] = @[]
  var cur = ""
  var buf: seq[string] = @[]
  var maxId = 0
  var annotated = false
  for raw in text.splitLines():
    let t = raw.strip()
    if cur.len > 0:
      if t.startsWith("//@end"):
        blocks[cur] = buf.join("\n")
        cur = ""
        buf = @[]
      else:
        buf.add raw
      continue
    if t.startsWith("//@begin "):
      let p = t[9 .. ^1].splitWhitespace()
      cur = (if p.len > 0: p[0] else: "?")
      buf = @[]
    elif t.startsWith("//@wdreka"):
      annotated = true
    elif t.startsWith("//@doc "):
      let a = parseAttrs(t[7 .. ^1])
      d.title = a.getOrDefault("titre", d.title)
      try:
        d.horizon = parseInt(a.getOrDefault("horizon", $d.horizon))
        d.timeout = parseInt(a.getOrDefault("timeout", $d.timeout))
        d.maxSolutions = parseInt(a.getOrDefault("solutions", "0"))
      except ValueError:
        notes.add "unreadable document settings: default values used"
      d.unit = a.getOrDefault("unite", d.unit)
    elif t.startsWith("//@node "):
      let rest = t[8 .. ^1].strip()
      let p1 = rest.find(' ')
      if p1 < 0: continue
      let id = rest[0 ..< p1]
      let rest2 = rest[p1 + 1 .. ^1].strip()
      let p2 = rest2.find(' ')
      let comp = (if p2 < 0: rest2 else: rest2[0 ..< p2])
      let attrs = parseAttrs(if p2 < 0: "" else: rest2[p2 + 1 .. ^1])
      let n = Node(id: id, comp: comp, params: initOrderedTable[string, string]())
      if lib.comps.hasKey(comp):
        for p in lib.comps[comp].params:
          n.params[p.name] = p.default
      else:
        notes.add "unknown component \"" & comp & "\" for " & id
      for k, v in attrs.pairs:
        case k
        of "x":
          try:
            n.x = parseFloat(v)
          except ValueError:
            discard
        of "y":
          try:
            n.y = parseFloat(v)
          except ValueError:
            discard
        of "titre": n.title = v
        else: n.params[k] = v
      d.nodes.add n
      if id.startsWith("n"):
        try:
          maxId = max(maxId, parseInt(id[1 .. ^1]))
        except ValueError:
          discard
    elif t.startsWith("//@link "):
      let parts = t[8 .. ^1].split("->")
      if parts.len == 2:
        let a = parts[0].strip().split('.')
        let b = parts[1].strip().split('.')
        if a.len == 2 and b.len == 2:
          d.links.add Link(src: a[0], srcPort: a[1], dst: b[0], dstPort: b[1])
    elif t.startsWith("// ---- Model generated by wdreka") or t.startsWith("// ---- Modèle généré par wdreka"):
      discard
    else:
      if t.len > 0 or free.len > 0:
        free.add raw
  if cur.len > 0:
    notes.add "unterminated //@begin " & cur & " block"
  d.nextId = maxId + 1
  # blocks edited by hand -> custom code
  for n in d.nodes:
    if blocks.hasKey(n.id):
      let written = blocks[n.id].strip()
      var generated = ""
      try:
        n.customCode = ""
        generated = nodeCode(d, lib, n).strip()
      except CodegenError:
        generated = ""
      if written != generated:
        n.customCode = written
        notes.add n.id & ": code edited by hand, kept as custom code"
  # free code -> NCP block node
  while free.len > 0 and free[^1].strip().len == 0:
    discard free.pop()
  if free.len > 0:
    var y = 40.0
    for n in d.nodes: y = max(y, n.y + 180)
    let n = d.addNode(lib, "ncp", 40, (if d.nodes.len == 0: 40.0 else: y))
    n.params["code"] = free.join("\n")
    if not annotated:
      n.title = "Imported model"
      notes.add "text without wdreka annotations: imported as a single NCP block"
    else:
      notes.add "code outside blocks gathered in node " & n.id
  d.graphDirty = false
  d.textDirty = false
  result = (d, notes)
