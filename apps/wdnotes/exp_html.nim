# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
#   _._
# o|- -|o  wdnotes - HTML / CSS / JS export
#  ( l )   Produces a folder: index.html, style.css, script.js.
#    =     Every resolved style becomes a CSS class (deduplicated), each
#          note is a "page" card with its own header and footer; a side
#          table of contents, a search box, a dark mode and print CSS
#          (@page margins from the format) are included.

import std/[strutils, tables, os]
import styles, render

type CssBook = object
  classes: OrderedTable[string, string]                           # css body -> class name

proc esc*(s: string): string =
  result = newStringOfCap(s.len)
  for c in s:
    case c
    of '&': result.add "&amp;"
    of '<': result.add "&lt;"
    of '>': result.add "&gt;"
    of '"': result.add "&quot;"
    else: result.add c

proc pt(v: float): string = formatFloat(v, ffDecimal, 1) & "pt"

proc styleCss(s: Style, blockLevel: bool): string =
  var parts: seq[string]
  parts.add "font-family:" & cssFamily(s.font)
  parts.add "font-size:" & pt(s.size)
  if s.bold: parts.add "font-weight:700"
  if s.italic: parts.add "font-style:italic"
  var deco: seq[string]
  if s.underline: deco.add "underline"
  if s.strike: deco.add "line-through"
  if deco.len > 0: parts.add "text-decoration:" & deco.join(" ")
  if s.color.len > 0: parts.add "color:" & s.color
  if s.bg.len > 0: parts.add "background:" & s.bg
  if blockLevel:
    parts.add "text-align:" & s.align
    parts.add "margin:" & pt(s.before) & " 0 " & pt(s.after) & " " & pt(s.indent)
    parts.add "line-height:" & formatFloat(s.lineHeight, ffDecimal, 2)
    if s.bg.len > 0 or s.frame.len > 0: parts.add "padding:4pt 8pt"
    if s.pageBreak: parts.add "break-before:page"
    let bc = if s.border.len > 0: s.border else: "#cccccc"
    case s.frame
    of "left": parts.add "border-left:3pt solid " & bc
    of "box": parts.add "border:1pt solid " & bc & ";border-radius:4pt"
    of "bottom": parts.add "border-bottom:1.5pt solid " & bc & ";padding-bottom:4pt"
    of "top": parts.add "border-top:1.5pt solid " & bc & ";padding-top:4pt"
    else: discard
  else:
    if s.bg.len > 0: parts.add "padding:0 2pt;border-radius:2pt"
  parts.join(";")

proc cls(book: var CssBook, s: Style, blockLevel: bool): string =
  let css = styleCss(s, blockLevel)
  if css notin book.classes:
    book.classes[css] = (if blockLevel: "b" else: "r") & $book.classes.len
  book.classes[css]

proc runsHtml(book: var CssBook, runs: seq[Run], parentStyle: Style): string =
  for r in runs:
    var t = esc(r.text).replace("\n", "<br>")
    if r.style != parentStyle:
      t = "<span class=\"" & book.cls(r.style, false) & "\">" & t & "</span>"
    if r.link.startsWith("note:"):
      t = "<a class=\"wl\" href=\"#" & r.link[5 .. ^1] & "\">" & t & "</a>"
    elif r.link.startsWith("missing:"):
      t = "<a class=\"wl missing\" title=\"note absente\">" & t & "</a>"
    elif r.link.len > 0:
      t = "<a href=\"" & esc(r.link) & "\" target=\"_blank\" rel=\"noopener\">" & t & "</a>"
    result.add t

proc blockHtml(book: var CssBook, b: RBlock): string =
  let c = book.cls(b.style, true)
  case b.kind
  of "title":
    let h = "h" & $min(b.level + 1, 6)
    "<" & h & " class=\"note-title " & c & "\">" & book.runsHtml(b.runs, b.style) & "</" & h & ">\n"
  of "heading":
    let h = "h" & $min(b.level + 1, 6)
    "<" & h & " class=\"" & c & "\">" & book.runsHtml(b.runs, b.style) & "</" & h & ">\n"
  of "para", "meta":
    "<p class=\"" & c & "\">" & book.runsHtml(b.runs, b.style) & "</p>\n"
  of "quote":
    "<blockquote class=\"" & c & "\">" & book.runsHtml(b.runs, b.style) & "</blockquote>\n"
  of "li":
    "<div class=\"li " & c & "\"><span class=\"mk\">" & esc(b.marker) & "</span><span>" &
      book.runsHtml(b.runs, b.style) & "</span></div>\n"
  of "code":
    "<pre class=\"" & c & "\"><code>" & esc(plain(b.runs)) & "</code></pre>\n"
  of "hr":
    "<hr style=\"border:0;border-top:1pt solid " &
      (if b.style.border.len > 0: b.style.border else: "#ccc") & ";margin:" &
      pt(b.style.before) & " 0 " & pt(b.style.after) & "\">\n"
  of "pagebreak":
    "<div class=\"pb\"></div>\n"
  of "table":
    var s = "<div class=\"tw\"><table class=\"" & c & "\" style=\"border-color:" &
      (if b.style.border.len > 0: b.style.border else: "#ccc") & "\">\n"
    for r, row in b.rows:
      s.add "<tr>"
      for k, cell in row:
        let tag = if r == 0: "th" else: "td"
        let st = if r == 0: b.thStyle else: b.tdStyle
        let al = if k < b.aligns.len: b.aligns[k] else: "left"
        s.add "<" & tag & " class=\"" & book.cls(st, false) & "\" style=\"text-align:" & al &
          ";border-color:" & (if b.style.border.len > 0: b.style.border else: "#ccc") & "\">" &
          book.runsHtml(cell, st) & "</" & tag & ">"
      s.add "</tr>\n"
    s & "</table></div>\n"
  else: ""

# TODO: Load BaseCss and Script from external files if exist, so final user can adapt ou choose a style.
const BaseCss = """
:root{--bg:#eef0f3;--paper:#ffffff;--ink:#22252a;--muted:#7a808a;--accent:#1f3a5f;--gold:#c9a227;--side:#f8f9fb;--line:#e1e4e8}
[data-theme=dark]{--bg:#16181c;--paper:#1f2228;--ink:#e6e6e6;--muted:#9aa0aa;--accent:#8fb3e0;--gold:#d8b64a;--side:#1a1d22;--line:#2c3038}
[data-theme=dark] .page{filter:invert(.92) hue-rotate(180deg)}
*{box-sizing:border-box}
html,body{margin:0;background:var(--bg);color:var(--ink);font-family:"Inter","Segoe UI",system-ui,sans-serif}
#side{position:fixed;top:0;left:0;bottom:0;width:290px;background:var(--side);border-right:1px solid var(--line);display:flex;flex-direction:column}
#side header{padding:22px 20px 12px}
#side h1{font:600 18px/1.25 "Iowan Old Style",Georgia,serif;margin:0 0 4px;color:var(--accent)}
#side .sub{font-size:12px;color:var(--muted)}
#q{margin:10px 20px;padding:8px 12px;border-radius:8px;border:1px solid var(--line);background:var(--paper);color:var(--ink);font-size:13px}
#toc{overflow:auto;padding:4px 10px 20px;flex:1}
#toc a{display:block;padding:5px 10px;border-radius:6px;color:var(--ink);text-decoration:none;font-size:13px;line-height:1.3;border-left:3px solid transparent}
#toc a:hover{background:rgba(127,127,127,.12)}
#toc a.on{background:rgba(31,58,95,.10);border-left-color:var(--gold);font-weight:600}
#side footer{padding:10px 20px;border-top:1px solid var(--line);display:flex;gap:8px}
#side button{flex:1;padding:7px;border-radius:7px;border:1px solid var(--line);background:var(--paper);color:var(--ink);cursor:pointer;font-size:12px}
main{margin-left:290px;padding:36px 24px 80px}
.page{position:relative;margin:0 auto 36px;background:var(--paper);box-shadow:0 1px 2px rgba(0,0,0,.06),0 8px 28px rgba(0,0,0,.08);border-radius:3px}
.page .hd,.page .ft{position:absolute;left:0;right:0}
.page .lab{display:inline-block;font:600 10px/1 "Inter",sans-serif;padding:4px 8px;border-radius:20px;color:#fff;margin:0 6px 10px 0;letter-spacing:.03em}
.li{display:flex;gap:.5em}.li .mk{min-width:1.2em;text-align:right;opacity:.85}
pre{white-space:pre-wrap;overflow:auto}
.tw{overflow-x:auto}table{border-collapse:collapse;width:100%}th,td{border:1px solid;padding:4pt 7pt;vertical-align:top}
a{color:inherit}a.wl{cursor:pointer}a.missing{cursor:not-allowed;opacity:.7}
.pb{height:0;break-after:page}
.hidden{display:none}
mark{background:#fff3a3;color:inherit}
@media (max-width:900px){#side{position:static;width:auto;height:auto}main{margin:0}}
@media print{#side{display:none}main{margin:0;padding:0}html,body{background:#fff}.page{box-shadow:none;margin:0;break-after:page;width:auto!important;min-height:0!important;padding:0!important}.page .hd,.page .ft{display:none}}
"""

const Script = """
(function(){
  const toc=document.querySelectorAll('#toc a'),pages=[...document.querySelectorAll('.page')];
  const obs=new IntersectionObserver(es=>{es.forEach(e=>{if(e.isIntersecting){toc.forEach(a=>a.classList.toggle('on',a.getAttribute('href')==='#'+e.target.id))}})},{rootMargin:'-30% 0px -60% 0px'});
  pages.forEach(p=>obs.observe(p));
  document.querySelectorAll('a[href^="#"]').forEach(a=>a.addEventListener('click',ev=>{const t=document.getElementById(a.getAttribute('href').slice(1));if(t){ev.preventDefault();t.scrollIntoView({behavior:'smooth'});history.replaceState(null,'','#'+t.id)}}));
  const q=document.getElementById('q');
  q.addEventListener('input',()=>{const v=q.value.trim().toLowerCase();
    pages.forEach(p=>{const hit=!v||p.textContent.toLowerCase().includes(v);p.classList.toggle('hidden',!hit);
      const link=document.querySelector('#toc a[href="#'+p.id+'"]');if(link)link.classList.toggle('hidden',!hit)})});
  const root=document.documentElement,key='wdnotes-theme';
  try{if(localStorage.getItem(key)==='dark')root.dataset.theme='dark'}catch(e){}
  document.getElementById('theme').onclick=()=>{root.dataset.theme=root.dataset.theme==='dark'?'':'dark';try{localStorage.setItem(key,root.dataset.theme)}catch(e){}};
  document.getElementById('print').onclick=()=>window.print();
})();
"""

proc exportHtml*(doc: RenderDoc, dir: string) =
  createDir(dir)
  var book = CssBook(classes: initOrderedTable[string, string]())
  var body = ""
  var toc = ""
  var pages = 0
  var atRule = ""
  for s in doc.sections:
    inc pages
    let pg = s.page
    if atRule.len == 0:
      atRule = "@page{size:" & formatFloat(pg.width, ffDecimal, 1) & "mm " &
        formatFloat(pg.height, ffDecimal, 1) & "mm;margin:" &
        formatFloat(pg.marginTop, ffDecimal, 1) & "mm " &
        formatFloat(pg.marginRight, ffDecimal, 1) & "mm " &
        formatFloat(pg.marginBottom, ffDecimal, 1) & "mm " &
        formatFloat(pg.marginLeft, ffDecimal, 1) & "mm}\n"
    let indent = s.depth * 14
    toc.add "<a href=\"#" & s.noteId & "\" style=\"padding-left:" & $(10 + indent) & "px\">" &
      esc(s.title) & "</a>\n"
    let hd = fillPlaceholders(pg.header, doc.project, s.title, pages, doc.sections.len, doc.date)
    let ft = fillPlaceholders(pg.footer, doc.project, s.title, pages, doc.sections.len, doc.date)
    body.add "<section class=\"page\" id=\"" & s.noteId & "\" style=\"width:min(100%," &
      formatFloat(pg.width, ffDecimal, 1) & "mm);min-height:" &
      formatFloat(pg.height * 0.6, ffDecimal, 0) & "mm;padding:" &
      formatFloat(pg.marginTop, ffDecimal, 1) & "mm " & formatFloat(pg.marginRight, ffDecimal, 1) &
      "mm " & formatFloat(pg.marginBottom, ffDecimal, 1) & "mm " &
      formatFloat(pg.marginLeft, ffDecimal, 1) & "mm" &
      (if pg.background.len > 0: ";background:" & pg.background else: "") & "\">\n"
    if hd.len > 0:
      body.add "<div class=\"hd " & book.cls(pg.headerStyle, true) & "\" style=\"top:" &
        formatFloat(pg.marginTop * 0.4, ffDecimal, 1) & "mm;padding:0 " &
        formatFloat(pg.marginRight, ffDecimal, 1) & "mm 0 " &
        formatFloat(pg.marginLeft, ffDecimal, 1) & "mm;margin:0\">" & esc(hd) & "</div>\n"
    if s.labels.len > 0:
      body.add "<div>"
      for l in s.labels:
        body.add "<span class=\"lab\" style=\"background:" &
          (if s.labelColor.len > 0: s.labelColor else: "#6b7a8f") & "\">" & esc(l) & "</span>"
      body.add "</div>\n"
    for b in s.blocks: body.add book.blockHtml(b)
    if ft.len > 0:
      body.add "<div class=\"ft " & book.cls(pg.footerStyle, true) & "\" style=\"bottom:" &
        formatFloat(pg.marginBottom * 0.35, ffDecimal, 1) & "mm;padding:0 " &
        formatFloat(pg.marginRight, ffDecimal, 1) & "mm 0 " &
        formatFloat(pg.marginLeft, ffDecimal, 1) & "mm;margin:0\">" & esc(ft) & "</div>\n"
    body.add "</section>\n"
  var css = BaseCss & atRule
  for rule, name in book.classes: css.add "." & name & "{" & rule & "}\n"
  writeFile(dir / "style.css", css)
  writeFile(dir / "script.js", Script)
  let html = "<!doctype html>\n<html lang=\"fr\">\n<head>\n<meta charset=\"utf-8\">\n" &
    "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">\n" &
    "<meta name=\"generator\" content=\"wdnotes\">\n<title>" & esc(doc.title) & "</title>\n" &
    "<link rel=\"stylesheet\" href=\"style.css\">\n</head>\n<body>\n" &
    "<nav id=\"side\"><header><h1>" & esc(doc.title) & "</h1><div class=\"sub\">" &
    esc(doc.project) & " · " & esc(doc.date) & " · " & $doc.sections.len & " notes</div></header>\n" &
    "<input id=\"q\" type=\"search\" placeholder=\"Rechercher…\">\n<div id=\"toc\">\n" & toc &
    "</div>\n<footer><button id=\"theme\">◐ Thème</button><button id=\"print\">⎙ Imprimer</button></footer></nav>\n" &
    "<main>\n" & body & "</main>\n<script src=\"script.js\"></script>\n</body>\n</html>\n"
  writeFile(dir / "index.html", html)
