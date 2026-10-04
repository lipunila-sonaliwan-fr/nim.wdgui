# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
#   _._
# o|- -|o  wdnotes - styles, formats, labels and templates
#  ( l )
#    =
#
# A *template* (modèle) gathers formats, labels and custom tags.
# A *format* defines the page (paper, margins, header, footer) and the
# typography of every Markdown tag (h1..h6, p, quote, code, table...).
# Properties are plain key/value pairs, the same ones that can be written
# in a "{ ... }" suffix in a note:
#
#   font size bold italic underline strike upper color bg align
#   before after indent line border frame prefix break
#
# French aliases are accepted (police, taille, gras, italique, couleur,
# fond, alignement, avant, apres, retrait, interligne, bordure, cadre...).

import std/[tables, strutils, json, os, algorithm]
import mdmodel

type
  Props* = OrderedTable[string, string]

  Style* = object
    font*: string
    size*: float
    bold*, italic*, underline*, strike*, upper*: bool
    color*, bg*: string
    align*: string                                                # left, center, right, justify.
    before*, after*, indent*: float                               # points.
    lineHeight*: float                                            # multiplier.
    border*: string                                               # border color.
    frame*: string                                                # "", left, box, bottom, top.
    prefix*: string
    pageBreak*: bool

  PageSetup* = object
    paper*: string
    landscape*: bool
    width*, height*: float                                        # mm
    marginTop*, marginBottom*, marginLeft*, marginRight*: float   # mm
    header*, footer*: string                                      # placeholders {project} {title} {page} {pages} {date}
    background*: string
    headerStyle*, footerStyle*: Style

  Format* = object
    name*: string
    page*: Props
    tags*: OrderedTable[string, Props]

  LabelDef* = object
    name*, color*, format*: string

  CustomTag* = object
    name*: string
    inline*: bool
    props*: Props

  Template* = object
    name*: string
    builtin*: bool
    defaultFormat*: string
    formats*: seq[Format]
    labels*: seq[LabelDef]
    customTags*: seq[CustomTag]

const
  StdTags* = ["body", "title", "h1", "h2", "h3", "h4", "h5", "h6", "p", "quote",
              "li", "task", "codeblock", "code", "strong", "em", "strike", "link",
              "wikilink", "table", "th", "td", "hr", "image", "header", "footer"]
  StyleKeys* = ["font", "size", "bold", "italic", "underline", "strike", "upper",
                "color", "bg", "align", "before", "after", "indent", "line",
                "border", "frame", "prefix", "break"]
  PageKeys* = ["paper", "orientation", "margin-top", "margin-bottom", "margin-left",
               "margin-right", "header", "footer", "background"]
  Papers* = ["A4", "A5", "A3", "Letter", "Legal"]

# keys

proc normKey*(k: string): string =
  let k = k.strip.toLowerAscii
  case k
  of "police", "font-family", "famille": "font"
  of "taille", "font-size", "corps": "size"
  of "gras": "bold"
  of "italique": "italic"
  of "souligne", "souligné": "underline"
  of "barre", "barré": "strike"
  of "majuscules", "uppercase", "caps": "upper"
  of "couleur", "colour": "color"
  of "fond", "background", "background-color": "bg"
  of "alignement", "text-align": "align"
  of "avant", "space-before", "margin-top": "before"
  of "apres", "après", "space-after", "margin-bottom": "after"
  of "retrait", "margin-left": "indent"
  of "interligne", "line-height": "line"
  of "bordure", "border-color": "border"
  of "cadre", "border-mode": "frame"
  of "prefixe", "préfixe": "prefix"
  of "saut", "page-break", "page-break-before": "break"
  else: k

proc normAlign(v: string): string =
  case v.strip.toLowerAscii
  of "gauche", "left", "l": "left"
  of "centre", "center", "centré", "c": "center"
  of "droite", "right", "r": "right"
  of "justifie", "justifié", "justify", "j": "justify"
  else: "left"

proc truthy(v: string): bool =
  v.strip.toLowerAscii in ["true", "1", "oui", "yes", "on", "vrai", "x"]

const NamedColors = {"rouge": "#d13438", "red": "#d13438", "bleu": "#1f5fbf", "blue": "#1f5fbf",
  "vert": "#2e7d32", "green": "#2e7d32", "noir": "#000000", "black": "#000000",
  "blanc": "#ffffff", "white": "#ffffff", "gris": "#777777", "gray": "#777777", "grey": "#777777",
  "orange": "#e3740f", "jaune": "#f2c200", "yellow": "#f2c200", "violet": "#7b3fa0",
  "purple": "#7b3fa0", "rose": "#d63384", "pink": "#d63384", "marine": "#1f3a5f",
  "navy": "#1f3a5f", "or": "#c9a227", "gold": "#c9a227", "brun": "#7a4b2a", "brown": "#7a4b2a",
  "aucun": "", "none": "", "transparent": ""}.toTable

proc normColor*(v: string): string =
  let x = v.strip.toLowerAscii
  if x in NamedColors: return NamedColors[x]
  if x.startsWith('#'):
    if x.len == 4:               # #abc -> #aabbcc
      return "#" & x[1] & x[1] & x[2] & x[2] & x[3] & x[3]
    return x
  if x.len == 6 and x.allCharsInSet(HexDigits): return "#" & x
  x

proc toFloatOr(v: string, default: float): float =
  try: parseFloat(v.strip.replace(',', '.').strip(chars = {'p', 't', 'm', ' '}))
  except ValueError: default

# styles

proc defaultStyle*(): Style =
  Style(font: "Serif", size: 11, color: "#222222", align: "left", lineHeight: 1.4)

proc applyProp*(s: var Style, key, value: string) =
  case normKey(key)
  of "font": s.font = value.strip
  of "size":
    let v = value.strip
    if v.endsWith('%'): s.size = s.size * toFloatOr(v[0 .. ^2], 100) / 100
    elif v.startsWith('+') or v.startsWith('-') and v.len > 1:
      s.size = max(4.0, s.size + toFloatOr(v, 0))
    else: s.size = max(4.0, toFloatOr(v, s.size))
  of "bold": s.bold = truthy(value)
  of "italic": s.italic = truthy(value)
  of "underline": s.underline = truthy(value)
  of "strike": s.strike = truthy(value)
  of "upper": s.upper = truthy(value)
  of "color": s.color = normColor(value)
  of "bg": s.bg = normColor(value)
  of "align": s.align = normAlign(value)
  of "before": s.before = toFloatOr(value, s.before)
  of "after": s.after = toFloatOr(value, s.after)
  of "indent": s.indent = toFloatOr(value, s.indent)
  of "line": s.lineHeight = toFloatOr(value, s.lineHeight)
  of "border":
    let c = normColor(value)
    s.border = c
    if s.frame.len == 0 and c.len > 0: s.frame = "left"
  of "frame":
    let f = value.strip.toLowerAscii
    s.frame = case f
      of "gauche", "left": "left"
      of "boite", "boîte", "box", "cadre", "all": "box"
      of "dessous", "bottom", "souligne": "bottom"
      of "dessus", "top": "top"
      else: ""
  of "prefix": s.prefix = value
  of "break": s.pageBreak = truthy(value)
  else: discard

proc applyProps*(s: var Style, p: Props) =
  for k, v in p: s.applyProp(k, v)

proc applyProps*(s: var Style, p: seq[(string, string)]) =
  for (k, v) in p: s.applyProp(k, v)

proc props*(pairs: openArray[(string, string)]): Props =
  result = initOrderedTable[string, string]()
  for (k, v) in pairs: result[normKey(k)] = v

# templates

proc findFormat*(t: Template, name: string): int =
  for i, f in t.formats:
    if cmpIgnoreCase(f.name, name) == 0: return i
  -1

proc findLabel*(t: Template, name: string): int =
  for i, l in t.labels:
    if cmpIgnoreCase(l.name, name) == 0: return i
  -1

proc findTag*(t: Template, name: string): int =
  for i, c in t.customTags:
    if cmpIgnoreCase(c.name, name) == 0: return i
  -1

proc formatNames*(t: Template): seq[string] =
  for f in t.formats: result.add f.name

proc allTags*(t: Template): seq[string] =
  for s in StdTags: result.add s
  for c in t.customTags: result.add c.name

proc tagProps(f: Format, tag: string): Props =
  if tag in f.tags: f.tags[tag] else: initOrderedTable[string, string]()

proc resolveStyle*(t: Template, formatName, tag: string, attrs: Attrs,
                   base: Style, inlineTag = false): Style =
  # base -> default format(body, tag) -> format(body, tag) -> custom tags -> props
  result = base
  let di = t.findFormat(t.defaultFormat)
  let fi = t.findFormat(formatName)
  if not inlineTag:
    if di >= 0: result.applyProps(t.formats[di].tagProps("body"))
    if fi >= 0 and fi != di: result.applyProps(t.formats[fi].tagProps("body"))
  if tag.len > 0 and tag != "body":
    if di >= 0: result.applyProps(t.formats[di].tagProps(tag))
    if fi >= 0 and fi != di: result.applyProps(t.formats[fi].tagProps(tag))
  for c in attrs.classes:
    let ci = t.findTag(c)
    if ci >= 0: result.applyProps(t.customTags[ci].props)
    if di >= 0: result.applyProps(t.formats[di].tagProps(c))
    if fi >= 0 and fi != di: result.applyProps(t.formats[fi].tagProps(c))
  result.applyProps(attrs.props)

proc paperSize*(paper: string): (float, float) =
  case paper.toLowerAscii
  of "a5": (148.0, 210.0)
  of "a3": (297.0, 420.0)
  of "letter": (215.9, 279.4)
  of "legal": (215.9, 355.6)
  else: (210.0, 297.0)

proc resolvePage*(t: Template, formatName: string): PageSetup =
  var p = initOrderedTable[string, string]()
  let di = t.findFormat(t.defaultFormat)
  let fi = t.findFormat(formatName)
  if di >= 0:
    for k, v in t.formats[di].page: p[k] = v
  if fi >= 0 and fi != di:
    for k, v in t.formats[fi].page: p[k] = v
  template num(k: string, d: float): float =
    (if k in p: toFloatOr(p[k], d) else: d)
  result.paper = p.getOrDefault("paper", "A4")
  result.landscape = p.getOrDefault("orientation", "portrait").toLowerAscii in ["landscape", "paysage"]
  var (w, h) = paperSize(result.paper)
  if result.landscape: swap(w, h)
  result.width = w
  result.height = h
  result.marginTop = num("margin-top", 25)
  result.marginBottom = num("margin-bottom", 22)
  result.marginLeft = num("margin-left", 25)
  result.marginRight = num("margin-right", 22)
  result.header = p.getOrDefault("header", "")
  result.footer = p.getOrDefault("footer", "")
  result.background = normColor(p.getOrDefault("background", ""))
  let body = t.resolveStyle(formatName, "body", Attrs(), defaultStyle())
  result.headerStyle = t.resolveStyle(formatName, "header", Attrs(), body)
  result.footerStyle = t.resolveStyle(formatName, "footer", Attrs(), body)

proc fillPlaceholders*(s, project, title: string, page, pages: int, date: string): string =
  s.multiReplace(("{project}", project), ("{projet}", project), ("{title}", title),
                 ("{titre}", title), ("{page}", $page), ("{pages}", $pages),
                 ("{date}", date))

# built-in template

proc mkFormat(name: string, page: openArray[(string, string)],
         tags: openArray[(string, seq[(string, string)])]): Format =
  result.name = name
  result.page = initOrderedTable[string, string]()
  for (k, v) in page: result.page[k] = v
  result.tags = initOrderedTable[string, Props]()
  for (t, ps) in tags: result.tags[t] = props(ps)

proc builtinTemplate*(): Template =
  # "Classique": an elegant serif document, navy and gold accents.
  result = Template(name: "Classique", builtin: true, defaultFormat: "Standard")
  result.formats.add mkFormat("Standard",
    {"paper": "A4", "orientation": "portrait", "margin-top": "25", "margin-bottom": "22",
     "margin-left": "25", "margin-right": "22", "header": "{project} — {title}",
     "footer": "{page} / {pages}", "background": ""},
    {"body": @{"font": "Serif", "size": "11", "color": "#2b2b2b", "line": "1.45",
               "align": "justify", "after": "6"},
     "title": @{"font": "Serif", "size": "26", "color": "#1f3a5f", "after": "14",
                "before": "6", "frame": "bottom", "border": "#c9a227", "align": "left"},
     "h1": @{"font": "Sans", "size": "19", "bold": "true", "color": "#1f3a5f",
             "before": "16", "after": "8", "align": "left"},
     "h2": @{"font": "Sans", "size": "15.5", "bold": "true", "color": "#2d5b88",
             "before": "14", "after": "6", "align": "left"},
     "h3": @{"font": "Sans", "size": "13", "bold": "true", "italic": "true",
             "color": "#3b6ea5", "before": "10", "after": "4", "align": "left"},
     "h4": @{"font": "Sans", "size": "12", "bold": "true", "color": "#444444", "align": "left"},
     "h5": @{"font": "Sans", "size": "11", "bold": "true", "upper": "true", "color": "#555555"},
     "h6": @{"font": "Sans", "size": "10", "italic": "true", "color": "#666666"},
     "quote": @{"italic": "true", "color": "#4a4a4a", "bg": "#f7f4ec", "border": "#c9a227",
                "frame": "left", "indent": "14", "before": "4", "after": "8"},
     "li": @{"indent": "16", "after": "2", "align": "left"},
     "task": @{"indent": "16", "after": "2", "align": "left"},
     "codeblock": @{"font": "Mono", "size": "9.5", "color": "#2b2b2b", "bg": "#f4f5f7",
                    "frame": "box", "border": "#dde1e6", "align": "left", "line": "1.3",
                    "before": "4", "after": "8"},
     "code": @{"font": "Mono", "size": "-1", "color": "#a33a3a", "bg": "#f4f5f7"},
     "strong": @{"bold": "true"},
     "em": @{"italic": "true"},
     "strike": @{"strike": "true", "color": "#888888"},
     "link": @{"color": "#2d6cdf", "underline": "true"},
     "wikilink": @{"color": "#0f7b6c", "underline": "true"},
     "table": @{"border": "#c8ccd2", "size": "10", "after": "10", "align": "left"},
     "th": @{"bold": "true", "bg": "#1f3a5f", "color": "#ffffff"},
     "hr": @{"border": "#c9a227", "before": "8", "after": "8"},
     "image": @{"italic": "true", "color": "#777777"},
     "header": @{"font": "Sans", "size": "8.5", "color": "#8a8f98", "align": "right"},
     "footer": @{"font": "Sans", "size": "8.5", "color": "#8a8f98", "align": "center"}})
  result.formats.add mkFormat("Chapitre", {"header": "{title}"},
    {"title": @{"size": "30", "break": "true", "before": "40", "after": "24",
                "color": "#7a2e2e", "border": "#7a2e2e"},
     "h1": @{"color": "#7a2e2e"}, "h2": @{"color": "#a0443c"}})
  result.formats.add mkFormat("Annexe", {"header": "Annexe — {title}", "margin-left": "20",
                                    "margin-right": "20"},
    {"body": @{"font": "Sans", "size": "10", "color": "#444444", "align": "left"},
     "title": @{"font": "Sans", "size": "20", "color": "#6b7a8f", "border": "#6b7a8f"},
     "h1": @{"size": "15", "color": "#6b7a8f"}, "h2": @{"size": "13", "color": "#6b7a8f"}})
  result.formats.add mkFormat("Mémo", {"background": "#fffbea", "header": "Mémo — {title}",
                                  "margin-top": "18", "margin-bottom": "18"},
    {"body": @{"font": "Sans", "size": "10.5", "align": "left", "line": "1.35"},
     "title": @{"font": "Sans", "size": "18", "color": "#8a5a00", "border": "#e3a21a"},
     "h1": @{"color": "#8a5a00"}, "h2": @{"color": "#8a5a00"}})
  result.labels = @[
    LabelDef(name: "important", color: "#d13438", format: ""),
    LabelDef(name: "brouillon", color: "#e3a21a", format: "Mémo"),
    LabelDef(name: "annexe", color: "#6b7a8f", format: "Annexe"),
    LabelDef(name: "chapitre", color: "#7a2e2e", format: "Chapitre"),
    LabelDef(name: "référence", color: "#0f7b6c", format: "")]
  result.customTags = @[
    CustomTag(name: "alerte", props: props({"bg": "#fdecea", "border": "#d13438",
      "frame": "left", "color": "#7a1c1c", "prefix": "Attention — ", "indent": "10"})),
    CustomTag(name: "astuce", props: props({"bg": "#e9f5ea", "border": "#2e7d32",
      "frame": "left", "color": "#1f4d22", "prefix": "Astuce — ", "indent": "10"})),
    CustomTag(name: "encadre", props: props({"bg": "#f3f6fa", "border": "#1f3a5f",
      "frame": "box", "indent": "8"})),
    CustomTag(name: "centre", props: props({"align": "center"})),
    CustomTag(name: "signature", props: props({"align": "right", "italic": "true"})),
    CustomTag(name: "surligne", inline: true, props: props({"bg": "#fff3a3"})),
    CustomTag(name: "petit", inline: true, props: props({"size": "85%"})),
    CustomTag(name: "rouge", inline: true, props: props({"color": "#d13438"}))]

proc cloneTemplate*(t: Template, newName: string): Template =
  result = t
  result.name = newName
  result.builtin = false

# JSON

proc toJ(p: Props): JsonNode =
  result = newJObject()
  for k, v in p: result[k] = %v

proc fromJ(n: JsonNode): Props =
  result = initOrderedTable[string, string]()
  if n != nil and n.kind == JObject:
    for k, v in n.pairs:
      result[normKey(k)] = (if v.kind == JString: v.getStr else: $v)

proc toJson*(t: Template): JsonNode =
  result = %*{"name": t.name, "defaultFormat": t.defaultFormat}
  var fs = newJArray()
  for f in t.formats:
    var tags = newJObject()
    for k, v in f.tags: tags[k] = toJ(v)
    fs.add %*{"name": f.name, "page": toJ(f.page), "tags": tags}
  result["formats"] = fs
  var ls = newJArray()
  for l in t.labels: ls.add %*{"name": l.name, "color": l.color, "format": l.format}
  result["labels"] = ls
  var cs = newJArray()
  for c in t.customTags: cs.add %*{"name": c.name, "inline": c.inline, "props": toJ(c.props)}
  result["customTags"] = cs

proc templateFromJson*(n: JsonNode): Template =
  result.name = n{"name"}.getStr("Modèle")
  result.defaultFormat = n{"defaultFormat"}.getStr("Standard")
  for f in n{"formats"}.getElems:
    var fo = Format(name: f{"name"}.getStr, page: fromJ(f{"page"}),
                    tags: initOrderedTable[string, Props]())
    if f{"tags"} != nil:
      for k, v in f{"tags"}.pairs: fo.tags[k.toLowerAscii] = fromJ(v)
    result.formats.add fo
  for l in n{"labels"}.getElems:
    result.labels.add LabelDef(name: l{"name"}.getStr, color: l{"color"}.getStr,
                               format: l{"format"}.getStr)
  for c in n{"customTags"}.getElems:
    result.customTags.add CustomTag(name: c{"name"}.getStr.toLowerAscii,
                                    inline: c{"inline"}.getBool, props: fromJ(c{"props"}))
  if result.findFormat(result.defaultFormat) < 0 and result.formats.len > 0:
    result.defaultFormat = result.formats[0].name

proc safeFileName*(s: string): string =
  for ch in s:
    if ch.isAlphaNumeric or ch in {'-', '_'} or ord(ch) >= 128: result.add ch
    elif ch == ' ': result.add '_'
  if result.len == 0: result = "modele"

proc saveTemplate*(t: Template, dir: string) =
  createDir(dir)
  writeFile(dir / safeFileName(t.name) & ".json", t.toJson.pretty)

proc loadTemplates*(dir: string): seq[Template] =
  if not dirExists(dir): return
  var files: seq[string]
  for f in walkFiles(dir / "*.json"): files.add f
  files.sort()
  for f in files:
    try: result.add templateFromJson(parseFile(f))
    except CatchableError: discard

# CSS helpers

proc cssFamily*(font: string): string =
  # generic family names used by the templates -> CSS font stacks.
  case font.toLowerAscii
  of "serif", "": "\"Iowan Old Style\", \"Palatino Linotype\", Palatino, Georgia, \"Times New Roman\", serif"
  of "sans", "sans-serif": "\"Inter\", \"Segoe UI\", \"Helvetica Neue\", Arial, sans-serif"
  of "mono", "monospace": "\"JetBrains Mono\", \"Fira Code\", Consolas, \"Courier New\", monospace"
  else: "\"" & font & "\", serif"

proc isMonoFont*(font: string): bool =
  let f = font.toLowerAscii
  "mono" in f or "courier" in f or "consol" in f or "code" in f

proc isSansFont*(font: string): bool =
  let f = font.toLowerAscii
  "sans" in f or f in ["arial", "helvetica", "inter", "segoe ui", "verdana", "dejavu sans",
                       "liberation sans", "noto sans", "roboto", "open sans", "calibri"]

proc officeFamily*(font: string): string =
  # family names for RTF/LibreOffice/...
  case font.toLowerAscii
  of "serif", "": "Liberation Serif"
  of "sans", "sans-serif": "Liberation Sans"
  of "mono", "monospace": "Liberation Mono"
  else: font
