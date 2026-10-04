# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
#   _._
# o|- -|o  wdnotes - project model
#  ( l )
#    =
#
# A project is a folder:
#
#   MyProject/
#     wdnotes.json        tree, titles, formats, labels, settings
#     notes/<id>.md       one Markdown file per note
#     templates/*.json    cloned templates (the built-in one lives in code)
#
# Format resolution for a note (first match wins):
#   1. the note's own format
#   2. the format associated with one of its labels
#   3. the resolved format of its parent
#   4. the project's global format, then the template default format

import std/[tables, strutils, json, os, times, sets, sequtils]
import styles, mdmodel

type
  Note* = ref object
    id*, title*, parent*: string
    children*: seq[string]
    format*: string
    labels*: seq[string]
    text*: string
    created*, modified*: string

  ApplyPolicy* = enum
    apNoteOnly                   # the note only; descendants inherit unless they have a format.
    apAll                        # force the format on every descendant.
    apUnformatted                # descendants without their own format.
    apLabel                      # descendants carrying a given label.
    apUnformattedLabel           # descendants without format carrying a given label.

  Project* = ref object
    dir*, title*: string
    mainNote*, lexiconNote*: string
    templateName*: string
    globalFormat*: string
    roots*: seq[string]
    notes*: OrderedTable[string, Note]
    templates*: seq[Template]
    counter: int

const ProjectFile* = "wdnotes.json"

proc nowStamp(): string = now().format("yyyy-MM-dd'T'HH:mm:ss")

# templates

proc tpl*(p: Project): Template =
  for t in p.templates:
    if t.name == p.templateName: return t
  p.templates[0]

proc tplIndex*(p: Project): int =
  for i, t in p.templates:
    if t.name == p.templateName: return i
  0

proc setTpl*(p: Project, t: Template) =
  for i in 0 ..< p.templates.len:
    if p.templates[i].name == t.name:
      p.templates[i] = t
      return
  p.templates.add t

# creation

proc newId(p: Project): string =
  inc p.counter
  let base = toHex(int64(epochTime() * 1000) and 0xFFFFFFFF'i64, 8).toLowerAscii
  result = "n" & base & $p.counter
  while result in p.notes:
    inc p.counter
    result = "n" & base & $p.counter

proc newProject*(dir, title: string): Project =
  result = Project(dir: dir, title: title, templateName: "Classique",
                   notes: initOrderedTable[string, Note]())
  result.templates.add builtinTemplate()

proc siblings*(p: Project, id: string): seq[string] =
  let n = p.notes[id]
  if n.parent.len == 0: p.roots else: p.notes[n.parent].children

proc setSiblings(p: Project, parent: string, s: seq[string]) =
  if parent.len == 0: p.roots = s else: p.notes[parent].children = s

proc addNote*(p: Project, title, parent: string, after = "", text = ""): string =
  let id = p.newId()
  let n = Note(id: id, title: title, parent: parent, created: nowStamp(), modified: nowStamp(),
               text: (if text.len > 0: text else: "# " & title & "\n\n"))
  p.notes[id] = n
  var s = if parent.len == 0: p.roots else: p.notes[parent].children
  let k = s.find(after)
  if k >= 0: s.insert(id, k + 1) else: s.add id
  p.setSiblings(parent, s)
  id

# traversal

proc descendants*(p: Project, id: string): seq[string] =
  for c in p.notes[id].children:
    result.add c
    result.add p.descendants(c)

proc preorder*(p: Project): seq[string] =
  for r in p.roots:
    result.add r
    result.add p.descendants(r)

proc depth*(p: Project, id: string): int =
  var cur = p.notes[id].parent
  while cur.len > 0:
    inc result
    cur = p.notes[cur].parent

proc isAncestor*(p: Project, anc, id: string): bool =
  var cur = p.notes[id].parent
  while cur.len > 0:
    if cur == anc: return true
    cur = p.notes[cur].parent
  false

proc chain*(p: Project, id: string): seq[string] =
  ## ids from the root to the note
  var cur = id
  while cur.len > 0:
    result.insert(cur, 0)
    cur = p.notes[cur].parent

# reorganisation

proc moveUp*(p: Project, id: string): bool =
  var s = p.siblings(id)
  let k = s.find(id)
  if k <= 0: return false
  swap(s[k], s[k - 1])
  p.setSiblings(p.notes[id].parent, s)
  true

proc moveDown*(p: Project, id: string): bool =
  var s = p.siblings(id)
  let k = s.find(id)
  if k < 0 or k >= s.high: return false
  swap(s[k], s[k + 1])
  p.setSiblings(p.notes[id].parent, s)
  true

proc moveTo*(p: Project, id, newParent: string, index = -1): bool =
  # re-parents a note (index -1 = at the end).
  if id == newParent or (newParent.len > 0 and p.isAncestor(id, newParent)): return false
  let n = p.notes[id]
  var s = p.siblings(id)
  s.delete(s.find(id))
  p.setSiblings(n.parent, s)
  n.parent = newParent
  var t = if newParent.len == 0: p.roots else: p.notes[newParent].children
  if index < 0 or index > t.len: t.add id else: t.insert(id, index)
  p.setSiblings(newParent, t)
  true

proc indent*(p: Project, id: string): bool =
  # becomes the last child of its previous sibling.
  let s = p.siblings(id)
  let k = s.find(id)
  if k <= 0: return false
  p.moveTo(id, s[k - 1])

proc outdent*(p: Project, id: string): bool =
  # becomes the next sibling of its parent.
  let parent = p.notes[id].parent
  if parent.len == 0: return false
  let gp = p.notes[parent].parent
  let s = if gp.len == 0: p.roots else: p.notes[gp].children
  p.moveTo(id, gp, s.find(parent) + 1)

proc deleteNote*(p: Project, id: string) =
  let kids = p.notes[id].children
  for c in kids: p.deleteNote(c)
  let n = p.notes[id]
  if n.parent.len == 0 or n.parent in p.notes:
    var s = if n.parent.len == 0: p.roots else: p.notes[n.parent].children
    let k = s.find(id)
    if k >= 0: s.delete(k)
    p.setSiblings(n.parent, s)
  if p.dir.len > 0:
    let f = p.dir / "notes" / id & ".md"
    if fileExists(f): removeFile(f)
  p.notes.del(id)
  if p.mainNote == id: p.mainNote = ""
  if p.lexiconNote == id: p.lexiconNote = ""

# links

proc findByTitle*(p: Project, target: string): string =
  let t = target.strip
  if t in p.notes: return t
  for id, n in p.notes:
    if cmpIgnoreCase(n.title.strip, t) == 0: return id
  ""

proc links*(p: Project): seq[(string, string)] =
  # (from, to) pairs from [[wiki links]], without duplicates.
  var seen = initHashSet[string]()
  for id, n in p.notes:
    for t in wikiTargets(n.text):
      let to = p.findByTitle(t)
      if to.len > 0 and to != id and (id & ">" & to) notin seen:
        seen.incl id & ">" & to
        result.add (id, to)

proc backlinks*(p: Project, id: string): seq[string] =
  for (a, b) in p.links:
    if b == id and a notin result: result.add a

proc outlinks*(p: Project, id: string): seq[string] =
  for t in wikiTargets(p.notes[id].text):
    let to = p.findByTitle(t)
    if to.len > 0 and to notin result: result.add to

proc renameNote*(p: Project, id, newTitle: string, updateLinks = true) =
  let old = p.notes[id].title
  p.notes[id].title = newTitle
  if not updateLinks or old == newTitle: return
  for oid, n in p.notes:
    var changed = false
    var t = n.text
    for pat in ["[[" & old & "]]", "[[" & old & "|"]:
      if pat in t:
        t = t.replace(pat, pat.replace(old, newTitle))
        changed = true
    if changed:
      n.text = t
      n.modified = nowStamp()

# formats.

proc labelFormat(p: Project, n: Note): string =
  let t = p.tpl
  for l in n.labels:
    let k = t.findLabel(l)
    if k >= 0 and t.labels[k].format.len > 0 and t.findFormat(t.labels[k].format) >= 0:
      return t.labels[k].format
  ""

proc effectiveFormat*(p: Project, id: string): string =
  let t = p.tpl
  var cur = id
  while cur.len > 0:
    let n = p.notes[cur]
    if n.format.len > 0 and t.findFormat(n.format) >= 0: return n.format
    let lf = p.labelFormat(n)
    if lf.len > 0: return lf
    cur = n.parent
  if p.globalFormat.len > 0 and t.findFormat(p.globalFormat) >= 0: p.globalFormat
  else: t.defaultFormat

proc formatOrigin*(p: Project, id: string): string =
  # human readable explanation of where the format comes from.
  let n = p.notes[id]
  if n.format.len > 0: return "propre"
  if p.labelFormat(n).len > 0: return "étiquette"
  if n.parent.len > 0: return "hérité de « " & p.notes[n.parent].title & " »"
  "projet"

proc applyFormat*(p: Project, id, format: string, policy: ApplyPolicy, label = ""): int =
  # sets `format` on note `id` ("" = project level) then on descendants
  # according to `policy`; returns the number of notes changed.
  var targets: seq[string]
  if id.len == 0:
    p.globalFormat = format
    targets = p.preorder
  else:
    p.notes[id].format = format
    inc result
    targets = p.descendants(id)
  for d in targets:
    let n = p.notes[d]
    let hasLabel = label.len > 0 and n.labels.anyIt(cmpIgnoreCase(it, label) == 0)
    let doIt = case policy
      of apNoteOnly: false
      of apAll: true
      of apUnformatted: n.format.len == 0
      of apLabel: hasLabel
      of apUnformattedLabel: hasLabel and n.format.len == 0
    if doIt:
      n.format = format
      inc result

proc clearFormat*(p: Project, id: string, recursive: bool) =
  p.notes[id].format = ""
  if recursive:
    for d in p.descendants(id): p.notes[d].format = ""

proc labelColor*(p: Project, id: string): string =
  let t = p.tpl
  for l in p.notes[id].labels:
    let k = t.findLabel(l)
    if k >= 0: return t.labels[k].color
  ""

# persistence

proc noteToJson(n: Note): JsonNode =
  %*{"id": n.id, "title": n.title, "format": n.format, "labels": n.labels,
     "created": n.created, "modified": n.modified,
     "children": n.children}

proc saveNote*(p: Project, id: string) =
  if p.dir.len == 0: return
  createDir(p.dir / "notes")
  writeFile(p.dir / "notes" / id & ".md", p.notes[id].text)

proc saveProject*(p: Project, withNotes = true) =
  createDir(p.dir)
  var notes = newJArray()
  for id in p.preorder: notes.add noteToJson(p.notes[id])
  let j = %*{"wdnotes": 1, "title": p.title, "mainNote": p.mainNote,
             "lexiconNote": p.lexiconNote, "template": p.templateName,
             "globalFormat": p.globalFormat, "roots": p.roots, "notes": notes}
  writeFile(p.dir / ProjectFile, j.pretty)
  if withNotes:
    for id in p.notes.keys: p.saveNote(id)
  for t in p.templates:
    if not t.builtin: saveTemplate(t, p.dir / "templates")

proc loadProject*(dir: string): Project =
  let j = parseFile(dir / ProjectFile)
  result = newProject(dir, j{"title"}.getStr(dir.lastPathPart))
  result.mainNote = j{"mainNote"}.getStr
  result.lexiconNote = j{"lexiconNote"}.getStr
  result.templateName = j{"template"}.getStr("Classique")
  result.globalFormat = j{"globalFormat"}.getStr
  for t in loadTemplates(dir / "templates"):
    var t2 = t
    t2.builtin = false
    if t2.name == "Classique": t2.name = "Classique (copie)"
    result.templates.add t2
  for nj in j{"notes"}.getElems:
    let id = nj{"id"}.getStr
    var n = Note(id: id, title: nj{"title"}.getStr(id), format: nj{"format"}.getStr,
                 created: nj{"created"}.getStr, modified: nj{"modified"}.getStr)
    for l in nj{"labels"}.getElems: n.labels.add l.getStr
    for c in nj{"children"}.getElems: n.children.add c.getStr
    let f = dir / "notes" / id & ".md"
    n.text = if fileExists(f): readFile(f) else: ""
    result.notes[id] = n
  for r in j{"roots"}.getElems:
    if r.getStr in result.notes: result.roots.add r.getStr
  # parents, and recovery of orphan notes/missing files.
  for id, n in result.notes:
    n.children = n.children.filterIt(it in result.notes)
    for c in n.children: result.notes[c].parent = id
  var placed = initHashSet[string]()
  for id in result.preorder: placed.incl id
  for id in toSeq(result.notes.keys):
    if id notin placed and result.notes[id].parent.len == 0:
      result.roots.add id
  if dirExists(dir / "notes"):
    for f in walkFiles(dir / "notes" / "*.md"):
      let id = f.splitFile.name
      if id notin result.notes:
        let text = readFile(f)
        var title = id
        for l in text.splitLines:
          if l.startsWith("# "): title = l[2 .. ^1].strip; break
        result.notes[id] = Note(id: id, title: title, text: text)
        result.roots.add id

proc isProjectDir*(dir: string): bool = fileExists(dir / ProjectFile)

# search

proc searchNotes*(p: Project, query: string): seq[(string, int, string)] =
  # (note id, 1-based line, line text) for every line containing `query`.
  let q = query.toLowerAscii
  if q.len == 0: return
  for id in p.preorder:
    let lines = p.notes[id].text.splitLines
    for i, l in lines:
      if q in l.toLowerAscii: result.add (id, i + 1, l.strip)
