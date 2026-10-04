# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
#   _._
# o|- -|o  wdnotes - render model
#  ( l )   Turns notes + template into a fully styled document (RenderDoc).
#    =     The consultation view and every exporter (PDF, HTML, RTF, ODT)
#          consume the same RenderDoc, so they all honour formats, labels,
#          custom tags and "{ ... }" instructions identically.

import std/[strutils, times, tables]
import std/unicode except strip, split, splitWhitespace, align, alignLeft, cmpIgnoreCase, reversed
import mdmodel, styles, project

type
  Run* = object
    text*: string
    style*: Style
    link*: string                # "note:<id>", "missing:<title>" or an URL.

  RBlock* = object
    kind*: string                # title heading para quote li code hr table pagebreak meta.
    level*: int                  # heading level / list depth / title depth.
    marker*: string              # list bullet or number, task box.
    style*: Style
    runs*: seq[Run]
    rows*: seq[seq[seq[Run]]]
    aligns*: seq[string]
    thStyle*, tdStyle*: Style
    line*: int                   # 1-based source line (0 = generated).

  RSection* = object
    noteId*, title*, format*: string
    depth*: int
    labels*: seq[string]
    labelColor*: string
    page*: PageSetup
    blocks*: seq[RBlock]

  RenderDoc* = object
    project*, title*, date*: string
    sections*: seq[RSection]

  Builder = object
    p: Project
    t: Template
    fmt: string
    noteId: string
    blocks: seq[RBlock]

proc addRun(runs: var seq[Run], text: string, st: Style, link = "") =
  if text.len == 0: return
  let t = if st.upper: unicode.toUpper(text) else: text
  if runs.len > 0 and runs[^1].style == st and runs[^1].link == link:
    runs[^1].text.add t
  else:
    runs.add Run(text: t, style: st, link: link)

proc inlineRuns(b: Builder, inls: seq[Inline], base: Style, runs: var seq[Run], link = "") =
  for n in inls:
    case n.kind
    of ikText: runs.addRun(n.text, base, link)
    of ikBreak: runs.addRun("\n", base, link)
    of ikCode:
      runs.addRun(n.text, b.t.resolveStyle(b.fmt, "code", n.attrs, base, inlineTag = true), link)
    of ikStrong:
      b.inlineRuns(n.children, b.t.resolveStyle(b.fmt, "strong", n.attrs, base, true), runs, link)
    of ikEm:
      b.inlineRuns(n.children, b.t.resolveStyle(b.fmt, "em", n.attrs, base, true), runs, link)
    of ikStrike:
      b.inlineRuns(n.children, b.t.resolveStyle(b.fmt, "strike", n.attrs, base, true), runs, link)
    of ikSpan:
      b.inlineRuns(n.children, b.t.resolveStyle(b.fmt, "", n.attrs, base, true), runs, link)
    of ikLink:
      b.inlineRuns(n.children, b.t.resolveStyle(b.fmt, "link", n.attrs, base, true), runs, n.text)
    of ikWiki:
      let target = b.p.findByTitle(n.text)
      var st = b.t.resolveStyle(b.fmt, "wikilink", n.attrs, base, true)
      if target.len == 0:
        st.strike = false
        st.color = "#b0483c"
        st.underline = true
      b.inlineRuns(n.children, st,
                   runs, if target.len > 0: "note:" & target else: "missing:" & n.text)
    of ikImage:
      let st = b.t.resolveStyle(b.fmt, "image", n.attrs, base, true)
      let alt = plainText(n.children)
      runs.addRun("[image : " & (if alt.len > 0: alt else: n.text) & "]", st, n.text)

proc withPrefix(b: Builder, st: Style, runs: var seq[Run]) =
  if st.prefix.len > 0:
    var ps = st
    ps.bold = true
    runs.insert(Run(text: st.prefix, style: ps), 0)

proc blockStyle(b: Builder, tag: string, attrs: Attrs, extra: Attrs): Style =
  var a = extra
  a.merge attrs
  b.t.resolveStyle(b.fmt, tag, a, defaultStyle())

proc convert(b: var Builder, blocks: seq[Block], ctx: string, extra: Attrs, depth: int) =
  for bl in blocks:
    case bl.kind
    of bkHeading:
      let st = b.blockStyle("h" & $bl.level, bl.attrs, extra)
      var rb = RBlock(kind: "heading", level: bl.level, style: st, line: bl.line + 1)
      b.inlineRuns(bl.inlines, st, rb.runs)
      b.withPrefix(st, rb.runs)
      b.blocks.add rb
    of bkPara:
      let tag = if ctx.len > 0: ctx else: "p"
      var st = b.blockStyle(tag, bl.attrs, extra)
      var rb = RBlock(kind: (if ctx == "quote": "quote" else: "para"), style: st,
                      line: bl.line + 1)
      b.inlineRuns(bl.inlines, st, rb.runs)
      b.withPrefix(st, rb.runs)
      b.blocks.add rb
    of bkQuote:
      var a = extra
      a.merge bl.attrs
      b.convert(bl.children, "quote", a, depth)
    of bkDiv:
      var a = extra
      a.merge bl.attrs
      b.convert(bl.children, ctx, a, depth)
    of bkList:
      var num = bl.start
      for item in bl.items:
        let tag = if item.task >= 0: "task" else: "li"
        var ia = bl.attrs
        ia.merge item.attrs
        var st = b.blockStyle(tag, ia, extra)
        st.indent += float(depth) * 16
        let marker =
          if item.task == 0: "☐"
          elif item.task == 1: "☑"
          elif bl.ordered: $num & "."
          else: (if depth mod 2 == 0: "•" else: "◦")
        inc num
        var first = true
        for sub in item.blocks:
          if sub.kind == bkPara and first:
            var rb = RBlock(kind: "li", level: depth, marker: marker, style: st,
                            line: sub.line + 1)
            var rs = st
            if item.task == 1:
              rs.strike = true
              rs.color = "#888888"
            b.inlineRuns(sub.inlines, rs, rb.runs)
            b.withPrefix(st, rb.runs)
            b.blocks.add rb
            first = false
          elif sub.kind == bkPara:
            var rb = RBlock(kind: "li", level: depth, marker: "", style: st, line: sub.line + 1)
            b.inlineRuns(sub.inlines, st, rb.runs)
            b.blocks.add rb
          elif sub.kind == bkList:
            if first:
              b.blocks.add RBlock(kind: "li", level: depth, marker: marker, style: st,
                                  line: sub.line + 1)
              first = false
            b.convert(@[sub], ctx, extra, depth + 1)
          else:
            b.convert(@[sub], ctx, extra, depth + 1)
        if first:
          b.blocks.add RBlock(kind: "li", level: depth, marker: marker, style: st,
                              line: bl.line + 1)
    of bkCode:
      let st = b.blockStyle("codeblock", bl.attrs, extra)
      var rb = RBlock(kind: "code", style: st, line: bl.line + 1)
      rb.runs.add Run(text: bl.code, style: st)
      b.blocks.add rb
    of bkHr:
      b.blocks.add RBlock(kind: "hr", style: b.blockStyle("hr", bl.attrs, extra),
                          line: bl.line + 1)
    of bkPageBreak:
      b.blocks.add RBlock(kind: "pagebreak", line: bl.line + 1)
    of bkTable:
      let st = b.blockStyle("table", bl.attrs, extra)
      var rb = RBlock(kind: "table", style: st, aligns: bl.aligns, line: bl.line + 1)
      rb.thStyle = b.t.resolveStyle(b.fmt, "th", Attrs(), st)
      rb.tdStyle = b.t.resolveStyle(b.fmt, "td", Attrs(), st)
      for r, row in bl.rows:
        var cells: seq[seq[Run]]
        for cell in row:
          var runs: seq[Run]
          b.inlineRuns(cell, if r == 0: rb.thStyle else: rb.tdStyle, runs)
          cells.add runs
        rb.rows.add cells
      b.blocks.add rb

proc buildSection(p: Project, id: string, depth: int, withMeta: bool): RSection =
  let n = p.notes[id]
  let t = p.tpl
  let f = p.effectiveFormat(id)
  result = RSection(noteId: id, title: n.title, format: f, depth: depth,
                    labels: n.labels, labelColor: p.labelColor(id),
                    page: t.resolvePage(f))
  var b = Builder(p: p, t: t, fmt: f, noteId: id)
  var ast = parseMarkdown(n.text)
  # automatic title, unless the note starts with a level-1 heading.
  var titleAttrs = Attrs()
  if ast.len > 0 and ast[0].kind == bkHeading and ast[0].level == 1:
    titleAttrs = ast[0].attrs
    let ttext = plainText(ast[0].inlines)
    var st = b.blockStyle("title", titleAttrs, Attrs())
    if depth > 0: st.size = max(st.size * (1.0 - 0.1 * float(min(depth, 3))), 12)
    var rb = RBlock(kind: "title", level: depth, style: st, line: 1)
    b.inlineRuns(ast[0].inlines, st, rb.runs)
    if rb.runs.len == 0: rb.runs.addRun(ttext, st)
    b.blocks.add rb
    ast.delete(0)
  else:
    var st = b.blockStyle("title", Attrs(), Attrs())
    if depth > 0: st.size = max(st.size * (1.0 - 0.1 * float(min(depth, 3))), 12)
    var rb = RBlock(kind: "title", level: depth, style: st)
    rb.runs.addRun(n.title, st)
    b.blocks.add rb
  b.convert(ast, "", Attrs(), 0)
  if withMeta:
    let bl = p.backlinks(id)
    if bl.len > 0:
      var st = b.blockStyle("p", Attrs(), Attrs())
      st.size = max(st.size - 2, 7)
      st.italic = true
      st.color = "#8a8f98"
      st.before = 10
      st.align = "left"
      var rb = RBlock(kind: "meta", style: st)
      rb.runs.addRun("Référencée par : ", st)
      for k, other in bl:
        if k > 0: rb.runs.addRun(", ", st)
        var ls = st
        ls.color = "#0f7b6c"
        ls.underline = true
        rb.runs.addRun(p.notes[other].title, ls, "note:" & other)
      b.blocks.add rb
  result.blocks = b.blocks

proc buildDoc*(p: Project, rootId: string, withChildren = true, withMeta = false): RenderDoc =
  # rootId = "" -> every root note in order (whole project).
  result = RenderDoc(project: p.title, date: now().format("dd/MM/yyyy"))
  var ids: seq[(string, int)]
  if rootId.len == 0:
    for id in p.preorder: ids.add (id, p.depth(id))
    result.title = p.title
  else:
    ids.add (rootId, 0)
    if withChildren:
      let d0 = p.depth(rootId)
      for d in p.descendants(rootId): ids.add (d, p.depth(d) - d0)
    result.title = p.notes[rootId].title
  for (id, depth) in ids:
    if id == p.lexiconNote and rootId != id: continue
    result.sections.add buildSection(p, id, depth, withMeta)

proc plain*(runs: seq[Run]): string =
  for r in runs: result.add r.text

proc buildProjectDoc*(p: Project, withMeta = false): RenderDoc =
  # The whole project as one document: the main note and its branch first,
  # then every other note in tree order (the lexicon note is left out).
  if p.mainNote.len == 0 or p.mainNote notin p.notes: return buildDoc(p, "", true, withMeta)
  result = RenderDoc(project: p.title, date: now().format("dd/MM/yyyy"),
                     title: p.notes[p.mainNote].title)
  var ids = @[(p.mainNote, 0)]
  let d0 = p.depth(p.mainNote)
  for d in p.descendants(p.mainNote): ids.add (d, p.depth(d) - d0)
  for id in p.preorder:
    if id == p.mainNote or p.isAncestor(p.mainNote, id) or id == p.lexiconNote: continue
    ids.add (id, p.depth(id))
  for (id, depth) in ids:
    result.sections.add buildSection(p, id, depth, withMeta)
