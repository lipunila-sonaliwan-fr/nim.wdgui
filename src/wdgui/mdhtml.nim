# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
#   wdgui – Enhanced Markdown to HTML (for web publication, with an integrated reader).
#
# Follows the same parsing logic as the layout engine (mdparse): headings with anchors, lists, checkboxes,
# blockquotes, callout boxes, code blocks, tables, figures, cross-references [[ref:anchor]] (links),
# index entries (<span data-index> tags), and a table of contents [[toc]] (a list of links).

import std/[strutils, tables]
import mdparse

proc esc*(s: string): string =
  s.multiReplace(("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"), ("\"", "&quot;"))

type HtmlCtx = object
  heads: seq[MdBlk]
  imgPrefix: string
  figNo: int

proc inlineHtml(src: string): string =
  for sg in parseInline(src):
    case sg.kind
    of skBreak: result.add "<br>"
    of skIndex: result.add "<span class=\"ix\" data-index=\"" & esc(sg.text) & "\"></span>"
    of skRef: result.add "<a class=\"ref\" href=\"#" & esc(sg.text) & "\">§</a>"
    of skText:
      var t = esc(sg.text)
      if sg.code: t = "<code>" & t & "</code>"
      if sg.bold: t = "<strong>" & t & "</strong>"
      if sg.italic: t = "<em>" & t & "</em>"
      if sg.strike: t = "<s>" & t & "</s>"
      if sg.link.len > 0:
        let ext = "://" in sg.link
        t = "<a href=\"" & esc(sg.link) & "\"" & (if ext: " target=\"_blank\" rel=\"noopener\"" else: "") & ">" & t & "</a>"
      result.add t

proc blocksHtml(c: var HtmlCtx, blocks: seq[MdBlk]): string

proc listHtml(items: seq[MdItem]): string =
  var stack: seq[string]
  for it in items:
    let tag = if it.ordered: "ol" else: "ul"
    if stack.len == 0 or it.level > stack.high:
      while stack.len <= it.level:
        result.add "<" & tag & ">"
        stack.add tag
    else:
      while stack.high > it.level: result.add "</li></" & stack.pop & ">"
      result.add "</li>"
    if it.task >= 0:
      result.add "<li class=\"task\"><input type=\"checkbox\" disabled" & (if it.task == 1: " checked" else: "") & "> " &
                 inlineHtml(it.text)
    else:
      result.add "<li>" & inlineHtml(it.text)
  while stack.len > 0: result.add "</li></" & stack.pop & ">"

proc alignCss(c: char): string =
  if c == 'c': "center" elif c == 'r': "right" else: "left"

proc blocksHtml(c: var HtmlCtx, blocks: seq[MdBlk]): string =
  for b in blocks:
    case b.kind
    of bkHead:
      let id = if b.id.len > 0: b.id else: slugify(plainText(b.text))
      let n = min(b.level, 6)
      result.add "<h" & $n & " id=\"" & esc(id) & "\">" & inlineHtml(b.text) & "<a class=\"anchor\" href=\"#" & esc(id) &
                 "\" aria-hidden=\"true\">#</a></h" & $n & ">\n"
    of bkPara: result.add "<p>" & inlineHtml(b.text) & "</p>\n"
    of bkList: result.add listHtml(b.items) & "\n"
    of bkQuote: result.add "<blockquote>" & c.blocksHtml(b.children) & "</blockquote>\n"
    of bkCallout:
      let label = case b.lang
                  of "astuce": "Astuce"
                  of "attention": "Attention"
                  of "important": "Important"
                  of "danger": "Danger"
                  else: "Remarque"
      result.add "<aside class=\"callout " & b.lang & "\"><div class=\"callout-title\">" &
                 esc(if b.title.len > 0: b.title else: label) & "</div>" & c.blocksHtml(b.children) & "</aside>\n"
    of bkCode:
      result.add "<pre class=\"code\"" & (if b.lang.len > 0: " data-lang=\"" & esc(b.lang) & "\"" else: "") & "><code>" &
                 esc(b.lines.join("\n")) & "</code></pre>\n"
    of bkTable:
      result.add "<div class=\"table\"><table><thead><tr>"
      for j, cell in b.rows[0]:
        result.add "<th style=\"text-align:" & alignCss(b.aligns[j]) & "\">" &
                   inlineHtml(cell) & "</th>"
      result.add "</tr></thead><tbody>"
      for r in 1 ..< b.rows.len:
        result.add "<tr>"
        for j, cell in b.rows[r]:
          result.add "<td style=\"text-align:" & alignCss(b.aligns[j]) & "\">" &
                     inlineHtml(cell) & "</td>"
        result.add "</tr>"
      result.add "</tbody></table></div>\n"
    of bkFigure:
      var style = ""
      if b.width.len > 0: style = " style=\"max-width:" & esc(b.width) & "\""
      let cap = if b.title.len > 0: b.title else: b.alt
      result.add "<figure><img src=\"" & esc(c.imgPrefix & b.src) & "\" alt=\"" & esc(b.alt) & "\" loading=\"lazy\"" & style & ">"
      if cap.len > 0:
        inc c.figNo
        result.add "<figcaption><em>Figure " & $c.figNo & "</em> — " & esc(cap) & "</figcaption>"
      result.add "</figure>\n"
    of bkRule: result.add "<hr>\n"
    of bkBreak: result.add "<div class=\"page-break\"></div>\n"
    of bkIndex: result.add "<div class=\"index-auto\"></div>\n"
    of bkToc:
      result.add "<nav class=\"toc-inline\"><ul>"
      for h in c.heads:
        if h.level > 3: continue
        let id = if h.id.len > 0: h.id else: slugify(plainText(h.text))
        result.add "<li class=\"l" & $h.level & "\"><a href=\"#" & esc(id) & "\">" & esc(plainText(h.text)) & "</a></li>"
      result.add "</ul></nav>\n"

proc markdownToHtml*(md: string, imgPrefix = ""): string =
  ## Fragment HTML d'un document Markdown enrichi (sans <html> ni styles).
  let blocks = parseMd(md)
  var c = HtmlCtx(imgPrefix: imgPrefix)
  for b in blocks:
    if b.kind == bkHead: c.heads.add b
  c.blocksHtml(blocks)
