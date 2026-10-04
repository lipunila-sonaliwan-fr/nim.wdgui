# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
#   _._
# o|- -|o  wdnotes - Markdown notes in a tree, with links, formats,
#  ( l )   consultation, graph, lexicon and exports. A wdgui demo app.
#    =
#
#   nimble wdnotes
#   nim c -r --threads:on --mm:atomicArc -d:sdlttf -o:apps/wdnotes/wdnotes apps/wdnotes/wdnotes.nim [project]
#
# ┌ menu ───────────────────────────────────────────────────────────────┐
# │ H1 H2 H3 │ G I S </> │ ❝ • 1. ☐ │ Lien [[Note]] Image Table ``` ... │  quick Markdown bar
# ├──────────┬───────────────────────────────────────────┬─────────────┤
# │ notes    │ Conception │ Consultation │ Graphe │ Formats │ Termes      │
# │ tree     │                                           │ Familles    │
# │          │   editor / document / graph / formats     │ occurrences │
# ├──────────┴───────────────────────────────────────────┴─────────────┤
# │ status                                   format · labels · caret   │
# └─────────────────────────────────────────────────────────────────────┘

import std/[os, strutils, locks, atomics, sets, sequtils, options]
import std/tables except newTable
import wdcompat, ctl_editor, ctl_docview, ctl_graph
import mdmodel, styles, project, lexicon, render, graphlayout, exporters

# state

type
  App = ref object
    p: Project
    cur: string
    dirty, lexDirty, dark: bool
    lex: Lexicon
    pathToId: Table[string, string]
    idToPath: Table[string, string]
    treeMenu: bool
    treeFilter: string
    mode: int                    # 1 design, 2 consultation, 3 graph, 4 formats.
    scope: int                   # 1 project, 2 note, 3 note + children.
    graphSel: string
    termWords: seq[string]
    termLevel: int
    termNote: string
    termMap: Table[string, string]
    famWords: seq[string]
    famName: string
    famLevel: int
    famNote: string
    famMap: Table[string, string]
    fmtName: string
    fmtTarget: string
    loading: bool

var app: App

# reentrant lock: handlers run on their own threads (wdgui step 6?).
var gLock: Lock
var gOwner: Atomic[int]
var gDepth: int
var tidCounter: Atomic[int]
var myTid {.threadvar.}: int

proc tid(): int =
  if myTid == 0: myTid = tidCounter.fetchAdd(1) + 1
  myTid

proc enterApp() =
  if gOwner.load == tid():
    inc gDepth
  else:
    acquire(gLock)
    gOwner.store(tid())
    gDepth = 1

proc leaveApp() =
  dec gDepth
  if gDepth == 0:
    gOwner.store(0)
    release(gLock)

template unlocked(body: untyped) =
  # releases the application lock during a blocking dialog.
  let savedDepth = gDepth
  gDepth = 0
  gOwner.store(0)
  release(gLock)
  try:
    body
  finally:
    acquire(gLock)
    gOwner.store(tid())
    gDepth = savedDepth

# controls

var
  mainWinId: typeof(newWindow("", 1, 1).id)
  menuBar, tree, edSearch, lblProject: ControlId
  btnNew, btnChild, btnUp, btnDown, btnIn, btnOut, btnDel: ControlId
  quick: seq[(ControlId, string)]
  btnTheme, btnPdf, btnSave: ControlId
  tabCenter: ControlId
  lblNoteTitle, lblNoteMeta, ed: ControlId
  cbScope, btnZoomOut, btnZoomIn, btnEditHere, btnRefresh, dv: ControlId
  chkTree, btnFit, btnGIn, btnGOut, btnRelayout, gv: ControlId
  lblGTitle, lblGInfo, lblGExcerpt, btnGEdit, btnGConsult: ControlId
  cbTemplate, btnTplClone, btnTplRename, btnTplDelete: ControlId
  cbFormat, btnFmtNew, btnFmtDup, btnFmtDel, btnFmtDefault: ControlId
  cbPaper, cbOrient, edMT, edMB, edML, edMR, edHeader, edFooter, edPageBg: ControlId
  btnPageApply, btnPageSetup: ControlId
  gridTags, btnColor, btnBg, btnFont, btnTagNew, btnTagDel: ControlId
  gridLabels, btnLabelNew, btnLabelDel: ControlId
  lblTarget, cbPolicy, cbPolicyLabel, btnApply, btnClearFmt, btnTargetNote, btnTargetProject: ControlId
  lblFmtHint: ControlId
  tabRight, edTermFilter, tblTerms, lblTermDetail, btnTermBack, tblTermDetail: ControlId
  tblFams, lblFamDetail, btnFamBack, tblFamDetail: ControlId
  lblStatus, lblInfo, lblCaret: ControlId

const
  TagColumns = ["tag", "font", "size", "bold", "italic", "underline", "color", "bg", "align",
                "before", "after", "indent", "frame", "border", "prefix", "extra"]
  ExtraKeys = ["line", "upper", "strike", "break"]
  PolicyNames = ["Note seule (les enfants héritent)", "Forcer sur tous les descendants",
                 "Descendants sans format", "Descendants portant l'étiquette…",
                 "Descendants sans format portant l'étiquette…"]
  TreeMenuItems = ["Nouvelle note", "Nouvelle sous-note", "Renommer…", "Monter", "Descendre",
                   "Indenter (devient enfant)", "Désindenter (remonte d'un niveau)",
                   "Déplacer vers…", "Définir comme note principale ★",
                   "Définir comme note lexique ◈", "Étiquettes…", "Format…", "Consulter",
                   "Supprimer…"]

# dialogs

proc infoBox(msg: string) =
  unlocked:
    alert(iconInformation, msg, title = "wdnotes")

proc warnBox(msg: string) =
  unlocked:
    alert(iconExclamation, msg, title = "wdnotes")

proc ask(msg: string): bool =
  var r = drCancel
  unlocked:
    r = confirm(iconQuestion, msg, title = "wdnotes")
  r == drOk

proc askText(msg, def: string): string =
  unlocked:
    result = prompt(iconQuestion, msg, def, title = "wdnotes")

# list picker (a small window; prompt-like but with a filterable list).

var
  pkLock: Lock
  pkItems: seq[string]
  pkShown: seq[int]
  pkResult: int
  pkDone: Atomic[bool]
  pkList, pkFilter, pkOk, pkCancel: ControlId

proc pkRefill() =
  let f = pkFilter.value.toLowerAscii.strip
  pkShown.setLen(0)
  listDeleteAll(pkList)
  for i, it in pkItems:
    if f.len == 0 or f in it.toLowerAscii:
      pkShown.add i
      discard listAdd(pkList, it)
  if pkShown.len > 0: pkList.value = "1"

proc pickerHandler(ev: var Event) {.nimcall, gcsafe.} =
  {.cast(gcsafe).}:
    withLock pkLock:
      if ev.kind == evWindowClose:
        if not pkDone.load:
          pkResult = -1
          pkDone.store(true)
        return
      if ev.current != ev.id: return
      if ev.kind == evChange and ev.id == pkFilter:
        pkRefill()
      elif (ev.kind == evClick and ev.id == pkOk) or (ev.kind == evDoubleClick and ev.id == pkList):
        let k = listSelectedIndex(pkList)
        pkResult = if k >= 1 and k <= pkShown.len: pkShown[k - 1] else: -1
        pkDone.store(true)
        closeWindow(ev.window)
      elif ev.kind == evClick and ev.id == pkCancel:
        pkResult = -1
        pkDone.store(true)
        closeWindow(ev.window)

proc pickFrom(title, hint: string, items: seq[string]): int =
  # blocks the calling handler until the user picks an item (-1 = cancel).
  result = -1
  if items.len == 0: return
  unlocked:
    withLock pkLock:
      pkItems = items
      pkDone.store(false)
      pkResult = -1
      let w = newWindow(title, 460, 520, pickerHandler, layout = lkBorder)
      let top = w.addChild(newContainer(lkVertical))
      top.dock = dkTop
      discard top.addChild(newLabel(hint))
      pkFilter = top.addChild(newEdit(placeholder = "Filtrer…")).id
      let l = w.addChild(newListBox())
      l.dock = dkCenter
      pkList = l.id
      let b = w.addChild(newSupercontrol(lkHorizontal))
      b.dock = dkBottom
      let sp = b.addChild(newLabel(""))
      sp.weight = 1
      pkCancel = b.addChild(newButton("Annuler", isCancel = true)).id
      pkOk = b.addChild(newButton("Choisir", isDefault = true)).id
      pkRefill()
    while not pkDone.load: sleep(25)
    withLock pkLock:
      result = pkResult

# helpers

proc setStatus(s: string) = lblStatus.caption = s

proc noteTitles(excludeBranch = ""): (seq[string], seq[string]) =
  # (indented titles, ids) in tree order.
  for id in app.p.preorder:
    if excludeBranch.len > 0 and (id == excludeBranch or app.p.isAncestor(excludeBranch, id)):
      continue
    result[0].add repeat("   ", app.p.depth(id)) & app.p.notes[id].title
    result[1].add id

proc wordCount(text: string): int =
  for w in text.splitWhitespace:
    if w.len > 0 and w[0] notin {'#', '-', '*', '>', '|', '{', '`'}: inc result

# tree

proc treeLabel(id: string): string =
  let n = app.p.notes[id]
  result = n.title.replace("\t", " ")
  if id == app.p.mainNote: result.add "  ★"
  if id == app.p.lexiconNote: result.add "  ◈"
  if n.labels.len > 0: result.add "  #" & n.labels.join(" #")

proc refreshTree() =
  let p = app.p
  treeDeleteAll(tree)
  app.pathToId.clear()
  app.idToPath.clear()
  var visible = initHashSet[string]()
  let f = app.treeFilter.toLowerAscii
  if f.len > 0:
    for id in p.preorder:
      let n = p.notes[id]
      if f in n.title.toLowerAscii or f in n.text.toLowerAscii or
         n.labels.anyIt(f in it.toLowerAscii):
        for a in p.chain(id): visible.incl a
  for id in p.preorder:
    if f.len > 0 and id notin visible: continue
    let parent = p.notes[id].parent
    let base = if parent.len > 0 and parent in app.idToPath: app.idToPath[parent] & TreeSep else: ""
    var label = treeLabel(id)
    var path = base & label
    var k = 2
    while path in app.pathToId:
      path = base & label & " (" & $k & ")"
      inc k
    treeAdd(tree, path)
    app.pathToId[path] = id
    app.idToPath[id] = path
  for id, path in app.idToPath:
    if p.notes[id].children.len > 0: treeExpand(tree, path)
  if app.cur in app.idToPath: treeSelectPath(tree, app.idToPath[app.cur])
  lblProject.caption = p.title & "  ·  " & $p.notes.len & " notes"

# note header / status

proc updateHeader() =
  let p = app.p
  if app.cur.len == 0 or app.cur notin p.notes:
    lblNoteTitle.caption = "Aucune note"
    lblNoteMeta.caption = ""
    return
  let n = p.notes[app.cur]
  lblNoteTitle.caption = n.title
  var crumbs: seq[string]
  for a in p.chain(app.cur): crumbs.add p.notes[a].title
  let fmt = p.effectiveFormat(app.cur)
  lblNoteMeta.caption = crumbs.join("  ›  ") & "     ·     format « " & fmt & " » (" &
    p.formatOrigin(app.cur) & ")" &
    (if n.labels.len > 0: "     ·     #" & n.labels.join(" #") else: "")
  let lc = p.labelColor(app.cur)
  lblNoteTitle.color = col(if lc.len > 0: lc elif app.dark: "#8fb3e0" else: "#1f3a5f")
  lblInfo.caption = $wordCount(n.text) & " mots  ·  " & $p.outlinks(app.cur).len &
    " liens sortants  ·  " & $p.backlinks(app.cur).len & " entrants"

# editor sync

proc storeEditor() =
  let p = app.p
  if app.cur.len == 0 or app.cur notin p.notes or not app.dirty: return
  let n = p.notes[app.cur]
  n.text = ed.value
  p.saveNote(app.cur)
  app.dirty = false
  app.lexDirty = true
  # the first level-1 heading is the note title.
  for line in n.text.splitLines:
    if line.startsWith("# "):
      let t = splitTrailingAttrs(line[2 .. ^1]).body.strip
      if t.len > 0 and t != n.title:
        p.renameNote(app.cur, t, updateLinks = true)
        p.saveProject(withNotes = true)
        refreshTree()
      break
    elif line.strip.len > 0: break
  updateHeader()

proc saveAll() =
  storeEditor()
  app.p.saveProject()
  setStatus("Projet enregistré : " & app.p.dir)

# lexicon panel

proc refreshTerms() =
  tableDeleteAll(tblTerms)
  var n = 0
  for (w, c) in app.lex.sortedWords(edTermFilter.value):
    discard tableAddLine(tblTerms, w, $c)
    inc n
    if n >= 600: break

proc refreshFamilies() =
  tableDeleteAll(tblFams)
  for (f, nw, occ) in app.lex.familyStats:
    discard tableAddLine(tblFams, f, $nw, $occ)

proc clearTermDetail() =
  tableDeleteAll(tblTermDetail)
  app.termLevel = 0
  lblTermDetail.caption = "Cliquez un terme pour voir les notes qui l'utilisent."

proc clearFamDetail() =
  tableDeleteAll(tblFamDetail)
  app.famLevel = 0
  lblFamDetail.caption = "Cliquez une famille pour voir les notes qui l'utilisent."

proc refreshLexicon(force = false) =
  if not (app.lexDirty or force): return
  app.lex = buildLexicon(app.p)
  app.lexDirty = false
  refreshTerms()
  refreshFamilies()
  clearTermDetail()
  clearFamDetail()

proc fillNotes(tbl, lbl: ControlId, words: seq[string], map: var Table[string, string],
               caption: string) =
  tableDeleteAll(tbl)
  map.clear()
  let rows = app.lex.notesFor(words)
  for (id, c) in rows:
    var t = app.p.notes[id].title
    var k = 2
    while t in map:
      t = app.p.notes[id].title & " (" & $k & ")"
      inc k
    map[t] = id
    discard tableAddLine(tbl, t, $c, excerpt(app.p.notes[id].text, 60))
  lbl.caption = caption & "  —  " & $rows.len & " note(s). Cliquez une note pour ses lignes."

proc fillLines(tbl, lbl: ControlId, id: string, words: seq[string], caption: string) =
  tableDeleteAll(tbl)
  let rows = linesFor(app.p, id, words)
  for (line, c, text) in rows:
    discard tableAddLine(tbl, "L" & $line, $c, text)
  lbl.caption = caption & " dans « " & app.p.notes[id].title & " » — " & $rows.len &
    " ligne(s). Double-clic : ouvrir."

# views

proc refreshConsult() =
  storeEditor()
  let p = app.p
  if p.notes.len == 0: return
  let doc = case app.scope
    of 2: buildDoc(p, app.cur, false, true)
    of 3: buildDoc(p, app.cur, true, true)
    else: buildProjectDoc(p, true)
  dv.value = docPayload(doc)
  if app.scope == 1 and app.cur.len > 0: dv.value = "scroll" & Sep & app.cur
  setStatus("Consultation : " & doc.title & " (" & $doc.sections.len & " notes)")

proc refreshGraph() =
  storeEditor()
  let g = buildGraph(app.p, withTree = chkTree.value == "1")
  gv.value = "load" & Sep & encode(g)
  gv.value = "tree" & Sep & chkTree.value
  if app.cur.len > 0: gv.value = "select" & Sep & app.cur

proc showGraphCard(id: string) =
  let p = app.p
  if id notin p.notes: return
  app.graphSel = id
  let n = p.notes[id]
  lblGTitle.caption = n.title
  lblGInfo.caption = "format « " & p.effectiveFormat(id) & " »  ·  " &
    $p.outlinks(id).len & " → / " & $p.backlinks(id).len & " ←" &
    (if n.labels.len > 0: "  ·  #" & n.labels.join(" #") else: "")
  lblGExcerpt.caption = excerpt(n.text, 420)

proc loadFormats()

proc openNote(id: string, line = 0) =
  let p = app.p
  if id notin p.notes: return
  if id != app.cur:
    storeEditor()
    app.cur = id
    app.loading = true
    ed.value = "set" & Sep & p.notes[id].text
    app.loading = false
    app.dirty = false
    if id in app.idToPath: treeSelectPath(tree, app.idToPath[id])
  if line > 0: ed.value = "goto" & Sep & $line
  updateHeader()
  case app.mode
  of 2: refreshConsult()
  of 3: gv.value = "select" & Sep & id
  of 4:
    app.fmtTarget = id
    loadFormats()
  else: discard

proc setMode(m: int) =
  if m == app.mode: return
  storeEditor()
  app.mode = m
  case m
  of 1: setFocus(ed)
  of 2: refreshConsult()
  of 3:
    refreshGraph()
    if app.cur.len > 0: showGraphCard(app.cur)
  of 4:
    if app.fmtTarget.len == 0: app.fmtTarget = app.cur
    loadFormats()
  else: discard
  refreshLexicon()

proc gotoMode(m: int) =
  selectTab(tabCenter, m)
  setMode(m)

# project

proc loadProjectUI(p: Project) =
  app.p = p
  app.cur = ""
  app.dirty = false
  app.lexDirty = true
  app.treeFilter = ""
  app.fmtTarget = ""
  refreshTree()
  let first = if p.mainNote.len > 0 and p.mainNote in p.notes: p.mainNote
              elif p.roots.len > 0: p.roots[0] else: ""
  if first.len > 0: openNote(first)
  else: ed.value = "set" & Sep & ""
  refreshLexicon(true)
  mainWinId.caption = "wdnotes — " & p.title
  setStatus("Projet ouvert : " & p.dir)

proc newProjectAt(dir, title: string): Project =
  result = newProject(dir, title)
  let home = result.addNote(title, "", text = "# " & title & "\n\n" &
    "Bienvenue ! Cette note est la **note principale** du projet.\n\n" &
    "- Créez des notes avec le bouton **＋** ou *Ctrl+N*.\n" &
    "- Reliez-les avec [[Lexique]] ou le bouton **[[Note]]**.\n")
  result.mainNote = home
  let lexId = result.addNote("Lexique", "", text = "# Lexique\n\n## Exemple\nmot, autre\n")
  result.lexiconNote = lexId
  result.saveProject()

proc exportAs(kind: ExportKind) =
  storeEditor()
  let p = app.p
  var path = ""
  unlocked:
    path = saveFileDialog(defaultName = safeFileName(p.title),
                          filter = ExportFilters[kind] & "\nTous les fichiers|*")
  if path.len == 0: return
  setStatus("Export " & $kind & " en cours…")
  let doc = buildProjectDoc(p)
  try:
    let outPath = exportDoc(doc, kind, path)
    setStatus("Exporté : " & outPath)
    if kind == exHtml and ask("Export terminé :\n" & outPath & "\n\nOuvrir dans le navigateur ?"):
      openUrl("file://" & outPath)
    elif kind != exHtml:
      infoBox("Export terminé :\n" & outPath)
  except CatchableError as e:
    warnBox("Échec de l'export : " & e.msg)

# note commands

proc cmdNewNote(child: bool) =
  let p = app.p
  let title = askText(if child: "Titre de la nouvelle sous-note :" else: "Titre de la nouvelle note :",
                      "Nouvelle note").strip
  if title.len == 0: return
  storeEditor()
  var id: string
  if app.cur.len == 0: id = p.addNote(title, "")
  elif child: id = p.addNote(title, app.cur)
  else: id = p.addNote(title, p.notes[app.cur].parent, after = app.cur)
  p.saveNote(id)
  p.saveProject(withNotes = false)
  refreshTree()
  openNote(id)
  app.lexDirty = true
  gotoMode(1)

proc cmdRename() =
  let p = app.p
  if app.cur.len == 0: return
  let n = p.notes[app.cur]
  let t = askText("Nouveau titre (les liens [[...]] seront mis à jour) :", n.title).strip
  if t.len == 0 or t == n.title: return
  storeEditor()
  p.renameNote(app.cur, t)
  # keep the first heading in sync.
  var lines = n.text.splitLines
  for i, l in lines:
    if l.startsWith("# "):
      let (_, at, found) = splitTrailingAttrs(l)
      lines[i] = "# " & t & (if found: " {" & at & "}" else: "")
      break
    elif l.strip.len > 0: break
  n.text = lines.join("\n")
  ed.value = "set" & Sep & n.text
  p.saveProject()
  refreshTree()
  updateHeader()

proc cmdDelete() =
  let p = app.p
  if app.cur.len == 0: return
  let n = p.notes[app.cur]
  let k = p.descendants(app.cur).len
  if not ask("Supprimer « " & n.title & " »" &
             (if k > 0: " et ses " & $k & " sous-note(s)" else: "") & " ?"): return
  let parent = n.parent
  p.deleteNote(app.cur)
  app.cur = ""
  app.dirty = false
  p.saveProject(withNotes = false)
  refreshTree()
  let next = if parent.len > 0: parent elif p.roots.len > 0: p.roots[0] else: ""
  if next.len > 0: openNote(next) else: ed.value = "set" & Sep & ""
  app.lexDirty = true
  refreshLexicon()

proc cmdMove(op: string) =
  let p = app.p
  if app.cur.len == 0: return
  storeEditor()
  var ok = false
  case op
  of "up": ok = p.moveUp(app.cur)
  of "down": ok = p.moveDown(app.cur)
  of "in": ok = p.indent(app.cur)
  of "out": ok = p.outdent(app.cur)
  of "to":
    let (titles, idsList) = noteTitles(app.cur)
    let k = pickFrom("Déplacer la note", "Nouveau parent de « " & p.notes[app.cur].title & " » :",
                     @["(racine du projet)"] & titles)
    if k == 0: ok = p.moveTo(app.cur, "")
    elif k > 0: ok = p.moveTo(app.cur, idsList[k - 1])
  else: discard
  if ok:
    p.saveProject(withNotes = false)
    refreshTree()
    updateHeader()
    setStatus("Note déplacée.")

proc cmdLabels() =
  let p = app.p
  if app.cur.len == 0: return
  let n = p.notes[app.cur]
  var avail: seq[string]
  for l in p.tpl.labels: avail.add l.name
  let s = askText("Étiquettes de « " & n.title & " », séparées par des virgules.\n" &
                  "Disponibles : " & avail.join(", "), n.labels.join(", "))
  var labels: seq[string]
  for part in s.split(','):
    let x = part.strip.strip(chars = {'#'})
    if x.len > 0 and x notin labels: labels.add x
  if labels == n.labels: return
  n.labels = labels
  p.saveProject(withNotes = false)
  refreshTree()
  updateHeader()

proc cmdLink() =
  let p = app.p
  let (titles, idsList) = noteTitles()
  let k = pickFrom("Lien vers une note", "Choisissez la note à relier :", titles)
  if k < 0: return
  ed.value = "link" & Sep & p.notes[idsList[k]].title
  app.dirty = true
  setFocus(ed)

proc cmdFind() =
  let q = askText("Rechercher dans toutes les notes :", "").strip
  if q.len == 0: return
  storeEditor()
  let hits = app.p.searchNotes(q)
  if hits.len == 0:
    infoBox("Aucun résultat pour « " & q & " ».")
    return
  var items: seq[string]
  for (id, line, text) in hits:
    items.add app.p.notes[id].title & "  ·  L" & $line & "  ·  " & text
  let k = pickFrom("Résultats", $hits.len & " résultat(s) pour « " & q & " »", items)
  if k >= 0:
    openNote(hits[k][0], hits[k][1])
    gotoMode(1)

proc cmdTreeMenu(item: string) =
  let p = app.p
  if app.cur.len == 0 and item notin ["Nouvelle note", "Nouvelle sous-note"]: return
  case item
  of "Nouvelle note": cmdNewNote(false)
  of "Nouvelle sous-note": cmdNewNote(true)
  of "Renommer…": cmdRename()
  of "Monter": cmdMove("up")
  of "Descendre": cmdMove("down")
  of "Indenter (devient enfant)": cmdMove("in")
  of "Désindenter (remonte d'un niveau)": cmdMove("out")
  of "Déplacer vers…": cmdMove("to")
  of "Définir comme note principale ★":
    p.mainNote = app.cur
    p.saveProject(withNotes = false)
    refreshTree()
    setStatus("Note principale : " & p.notes[app.cur].title)
  of "Définir comme note lexique ◈":
    p.lexiconNote = app.cur
    p.saveProject(withNotes = false)
    refreshTree()
    app.lexDirty = true
    refreshLexicon()
    setStatus("Note lexique : " & p.notes[app.cur].title)
  of "Étiquettes…": cmdLabels()
  of "Format…":
    app.fmtTarget = app.cur
    gotoMode(4)
    loadFormats()
  of "Consulter":
    app.scope = 2
    cbScope.value = "2"
    gotoMode(2)
    refreshConsult()
  of "Supprimer…": cmdDelete()
  else: discard

# quick bar

proc quickAction(action: string) =
  let p = app.p
  var cmd = ""
  case action
  of "h1": cmd = "prefix" & Sep & "# "
  of "h2": cmd = "prefix" & Sep & "## "
  of "h3": cmd = "prefix" & Sep & "### "
  of "bold": cmd = "wrap" & Sep & "**" & Sep & "**" & Sep & "texte"
  of "italic": cmd = "wrap" & Sep & "*" & Sep & "*" & Sep & "texte"
  of "strike": cmd = "wrap" & Sep & "~~" & Sep & "~~" & Sep & "texte"
  of "code": cmd = "wrap" & Sep & "`" & Sep & "`" & Sep & "code"
  of "quote": cmd = "prefix" & Sep & "> "
  of "ul": cmd = "prefix" & Sep & "- "
  of "ol": cmd = "prefix" & Sep & "1. "
  of "task": cmd = "prefix" & Sep & "- [ ] "
  of "url": cmd = "wrap" & Sep & "[" & Sep & "](https://)" & Sep & "texte du lien"
  of "image": cmd = "wrap" & Sep & "![" & Sep & "](image.png)" & Sep & "légende"
  of "table":
    cmd = "insert" & Sep & "\n| Colonne 1 | Colonne 2 | Colonne 3 |\n|---|:---:|---:|\n" &
      "| a | b | c |\n| d | e | f |\n"
  of "fence": cmd = "block" & Sep & "```" & Sep & "```"
  of "hr": cmd = "insert" & Sep & "\n---\n"
  of "break": cmd = "insert" & Sep & "\n\\pagebreak\n"
  of "note": cmdLink(); return
  of "div", "span", "attrs":
    let t = p.tpl
    var names: seq[string]
    for c in t.customTags:
      if action == "div" and c.inline: continue
      if action == "span" and not c.inline: continue
      names.add c.name
    if action == "attrs": names.add "✎ Instructions libres…"
    let k = pickFrom("Balise", "Choisissez la balise du modèle « " & t.name & " » :", names)
    if k < 0: return
    case action
    of "div": cmd = "block" & Sep & "::: " & names[k] & Sep & ":::"
    of "span": cmd = "wrap" & Sep & "[" & Sep & "]{." & names[k] & "}" & Sep & "texte"
    else:
      if names[k].startsWith("✎"):
        let s = askText("Instructions à ajouter à la ligne (ex. color: #a33; size: 14; align: center) :",
                        "color: #a33a3a")
        if s.strip.len == 0: return
        cmd = "suffix" & Sep & "{" & s.strip & "}"
      else:
        cmd = "suffix" & Sep & "{." & names[k] & "}"
  else: discard
  if cmd.len > 0:
    if app.mode != 1: gotoMode(1)
    ed.value = cmd
    app.dirty = true
    setFocus(ed)

# formats tab

proc curTemplate(): Template = app.p.tpl

proc ensureEditable(): bool =
  ## the built-in template is read-only: offer to clone it
  if not curTemplate().builtin: return true
  let name = askText("Le modèle « " & curTemplate().name & " » est le modèle par défaut, " &
                     "non modifiable.\nNom du clone à créer et à utiliser :",
                     curTemplate().name & " (perso)").strip
  if name.len == 0 or name == curTemplate().name: return false
  for t in app.p.templates:
    if t.name == name:
      warnBox("Un modèle porte déjà ce nom.")
      return false
  app.p.templates.add cloneTemplate(curTemplate(), name)
  app.p.templateName = name
  app.p.saveProject(withNotes = false)
  true

proc fmtIndex(): int =
  let t = curTemplate()
  result = t.findFormat(app.fmtName)
  if result < 0:
    app.fmtName = t.defaultFormat
    result = t.findFormat(app.fmtName)

proc tagRow(t: Template, f: Format, tag: string): seq[string] =
  let ps = if tag in f.tags: f.tags[tag] else: initOrderedTable[string, string]()
  template g(k: string): string = ps.getOrDefault(k, "")
  template chk(k: string): string =
    (if ps.getOrDefault(k, "").toLowerAscii in ["true", "1", "oui", "yes"]: "1" else: "0")
  var extra: seq[string]
  for k in ExtraKeys:
    if k in ps: extra.add k & ": " & ps[k]
  @[tag, g("font"), g("size"), chk("bold"), chk("italic"), chk("underline"), g("color"),
    g("bg"), g("align"), g("before"), g("after"), g("indent"), g("frame"), g("border"),
    g("prefix"), extra.join("; ")]

proc loadFormats() =
  let p = app.p
  let t = curTemplate()
  app.loading = true
  # templates.
  listDeleteAll(cbTemplate)
  for tt in p.templates:
    discard listAdd(cbTemplate, tt.name & (if tt.builtin: "  (modèle par défaut)" else: ""))
  cbTemplate.value = $(p.tplIndex + 1)
  btnTplRename.state = if t.builtin: csGrayed else: csActive
  btnTplDelete.state = if t.builtin: csGrayed else: csActive
  # target.
  if app.fmtTarget.len > 0 and app.fmtTarget notin p.notes: app.fmtTarget = ""
  if app.fmtName.len == 0 or t.findFormat(app.fmtName) < 0:
    app.fmtName = if app.fmtTarget.len > 0: p.effectiveFormat(app.fmtTarget)
                  elif p.globalFormat.len > 0: p.globalFormat else: t.defaultFormat
  lblTarget.caption =
    if app.fmtTarget.len > 0:
      "Cible : « " & p.notes[app.fmtTarget].title & " » — format actuel « " &
        p.effectiveFormat(app.fmtTarget) & " » (" & p.formatOrigin(app.fmtTarget) & ")"
    else:
      "Cible : projet entier (mise en forme globale) — format global « " &
        (if p.globalFormat.len > 0: p.globalFormat else: t.defaultFormat) & " »"
  # formats.
  listDeleteAll(cbFormat)
  for f in t.formats:
    discard listAdd(cbFormat, f.name & (if f.name == t.defaultFormat: "  (défaut)" else: ""))
  let fi = fmtIndex()
  cbFormat.value = $(fi + 1)
  let f = t.formats[fi]
  # page.
  let pg = t.resolvePage(f.name)
  cbPaper.value = $(max(0, Papers.find(pg.paper)) + 1)
  cbOrient.value = if pg.landscape: "2" else: "1"
  edMT.value = f.page.getOrDefault("margin-top", "")
  edMB.value = f.page.getOrDefault("margin-bottom", "")
  edML.value = f.page.getOrDefault("margin-left", "")
  edMR.value = f.page.getOrDefault("margin-right", "")
  edHeader.value = f.page.getOrDefault("header", "")
  edFooter.value = f.page.getOrDefault("footer", "")
  edPageBg.value = f.page.getOrDefault("background", "")
  # tags.
  gridDeleteAll(gridTags)
  for tag in t.allTags:
    let row = tagRow(t, f, tag)
    discard gridAddLine(gridTags, row)
  gridSetEditable(gridTags, not t.builtin)
  # labels.
  gridDeleteAll(gridLabels)
  for l in t.labels: discard gridAddLine(gridLabels, l.name, l.color, l.format)
  gridSetEditable(gridLabels, not t.builtin)
  gridSetChoices(gridLabels, "format", @[""] & t.formatNames)
  listDeleteAll(cbPolicyLabel)
  for l in t.labels: discard listAdd(cbPolicyLabel, l.name)
  if t.labels.len > 0: cbPolicyLabel.value = "1"
  lblFmtHint.caption =
    if t.builtin: "Modèle par défaut en lecture seule : clonez-le (« Cloner… ») pour le modifier."
    elif f.name == t.defaultFormat: "Format par défaut du modèle : il fournit les valeurs de base."
    else: "Cellules vides = valeur héritée du format par défaut « " & t.defaultFormat & " »."
  app.loading = false

proc withTemplate(body: proc (t: var Template)) =
  var t = curTemplate()
  body(t)
  app.p.setTpl(t)
  app.p.saveProject(withNotes = false)

proc setTagProp(tag, key, value: string) =
  let fname = app.fmtName
  withTemplate(proc (t: var Template) =
    let fi = t.findFormat(fname)
    if fi < 0: return
    if tag notin t.formats[fi].tags:
      t.formats[fi].tags[tag] = initOrderedTable[string, string]()
    if key == "extra":
      for k in ExtraKeys: t.formats[fi].tags[tag].del(k)
      for (k, v) in parseAttrs(value).props:
        t.formats[fi].tags[tag][normKey(k)] = v
    elif value.strip.len == 0 or (value == "0" and key in ["bold", "italic", "underline"] and
                                  fname == t.defaultFormat):
      t.formats[fi].tags[tag].del(key)
    elif key in ["bold", "italic", "underline"]:
      t.formats[fi].tags[tag][key] = (if value == "1": "true" else: "false")
    else:
      t.formats[fi].tags[tag][key] = value.strip)

proc gridRowTag(): (int, string) =
  let row = gridSelect(gridTags)
  if row < 1: return (-1, "")
  (row, gridCell(gridTags, row, "tag"))

proc applyPage() =
  if not ensureEditable():
    loadFormats(); return
  let fname = app.fmtName
  let vals = @[("paper", Papers[max(0, listSelectedIndex(cbPaper) - 1)]),
               ("orientation", (if cbOrient.value == "2": "landscape" else: "portrait")),
               ("margin-top", edMT.value), ("margin-bottom", edMB.value),
               ("margin-left", edML.value), ("margin-right", edMR.value),
               ("header", edHeader.value), ("footer", edFooter.value),
               ("background", edPageBg.value)]
  withTemplate(proc (t: var Template) =
    let fi = t.findFormat(fname)
    if fi < 0: return
    for (k, v) in vals:
      if v.strip.len == 0: t.formats[fi].page.del(k)
      else: t.formats[fi].page[k] = v.strip)
  loadFormats()
  setStatus("Mise en page du format « " & fname & " » enregistrée.")

proc formatsClick(id: ControlId): bool =
  ## buttons of the Formats tab; true if handled
  let p = app.p
  result = true
  if id == btnTplClone:
    let name = askText("Nom du nouveau modèle (clone de « " & curTemplate().name & " ») :",
                       curTemplate().name & " (copie)").strip
    if name.len == 0: return
    if p.templates.anyIt(it.name == name):
      warnBox("Un modèle porte déjà ce nom."); return
    p.templates.add cloneTemplate(curTemplate(), name)
    p.templateName = name
    p.saveProject(withNotes = false)
    loadFormats()
    setStatus("Modèle « " & name & " » créé et utilisé par le projet.")
  elif id == btnTplRename:
    let t = curTemplate()
    if t.builtin: return
    let name = askText("Nouveau nom du modèle :", t.name).strip
    if name.len == 0 or name == t.name or p.templates.anyIt(it.name == name): return
    let old = p.dir / "templates" / safeFileName(t.name) & ".json"
    if fileExists(old): removeFile(old)
    p.templates[p.tplIndex].name = name
    p.templateName = name
    p.saveProject(withNotes = false)
    loadFormats()
  elif id == btnTplDelete:
    let t = curTemplate()
    if t.builtin: return
    if not ask("Supprimer le modèle « " & t.name & " » ? Le projet reviendra au modèle par défaut."):
      return
    let f = p.dir / "templates" / safeFileName(t.name) & ".json"
    if fileExists(f): removeFile(f)
    p.templates.delete(p.tplIndex)
    p.templateName = p.templates[0].name
    p.saveProject(withNotes = false)
    loadFormats()
  elif id == btnFmtNew or id == btnFmtDup:
    if not ensureEditable(): return
    let name = askText("Nom du format :", if id == btnFmtDup: app.fmtName & " 2" else: "Nouveau format").strip
    if name.len == 0 or curTemplate().findFormat(name) >= 0: return
    let src = app.fmtName
    let dup = id == btnFmtDup
    withTemplate(proc (t: var Template) =
      var f = Format(name: name, page: initOrderedTable[string, string](),
                     tags: initOrderedTable[string, Props]())
      if dup:
        let si = t.findFormat(src)
        if si >= 0:
          f = t.formats[si]
          f.name = name
      t.formats.add f)
    app.fmtName = name
    loadFormats()
  elif id == btnFmtDel:
    if not ensureEditable(): return
    let t = curTemplate()
    if app.fmtName == t.defaultFormat:
      warnBox("Le format par défaut ne peut pas être supprimé."); return
    if not ask("Supprimer le format « " & app.fmtName & " » ? Les notes qui l'utilisent hériteront."):
      return
    let name = app.fmtName
    for n in p.notes.values:
      if n.format == name: n.format = ""
    if p.globalFormat == name: p.globalFormat = ""
    withTemplate(proc (t: var Template) =
      let fi = t.findFormat(name)
      if fi >= 0: t.formats.delete(fi)
      for l in t.labels.mitems:
        if l.format == name: l.format = "")
    app.fmtName = ""
    loadFormats()
  elif id == btnFmtDefault:
    if not ensureEditable(): return
    let name = app.fmtName
    withTemplate(proc (t: var Template) = t.defaultFormat = name)
    loadFormats()
  elif id == btnPageApply:
    applyPage()
  elif id == btnPageSetup:
    var paper = Papers[max(0, listSelectedIndex(cbPaper) - 1)]
    var land = cbOrient.value == "2"
    let pg = curTemplate().resolvePage(app.fmtName)
    var mt = pg.marginTop
    var mb = pg.marginBottom
    var ml = pg.marginLeft
    var mr = pg.marginRight
    var ok = false
    unlocked:
      ok = pageDialog(paper, land, mt, mb, ml, mr)
    if ok:
      cbPaper.value = $(max(0, Papers.find(paper)) + 1)
      cbOrient.value = if land: "2" else: "1"
      edMT.value = $mt; edMB.value = $mb; edML.value = $ml; edMR.value = $mr
      applyPage()
  elif id == btnColor or id == btnBg:
    let (row, tag) = gridRowTag()
    if row < 0:
      infoBox("Sélectionnez d'abord une balise dans la grille."); return
    if not ensureEditable(): return
    let key = if id == btnColor: "color" else: "bg"
    let cur = gridCell(gridTags, row, key)
    var c = col(if cur.startsWith("#") and cur.len >= 7: cur else: "#1f3a5f")
    var r = drCancel
    unlocked:
      r = colorDialog(c)
    if r == drOk:
      let hx = hexOf(c)
      setTagProp(tag, key, if hx.len > 7: hx[0 .. 6] else: hx)
      loadFormats()
  elif id == btnFont:
    let (row, tag) = gridRowTag()
    if row < 0:
      infoBox("Sélectionnez d'abord une balise dans la grille."); return
    if not ensureEditable(): return
    var fc = FontChoice(family: "DejaVuSans", size: 12)
    var r = drCancel
    unlocked:
      r = fontDialog(fc)
    if r == drOk:
      setTagProp(tag, "font", fc.family)
      setTagProp(tag, "size", formatFloat(float(fc.size), ffDecimal, 1))
      setTagProp(tag, "bold", if fc.bold: "1" else: "0")
      setTagProp(tag, "italic", if fc.italic: "1" else: "0")
      loadFormats()
  elif id == btnTagNew:
    if not ensureEditable(): return
    let name = askText("Nom de la nouvelle balise (utilisable par {.nom} ou ::: nom) :", "").strip.toLowerAscii
    if name.len == 0 or name in StdTags or curTemplate().findTag(name) >= 0: return
    let inline = ask("La balise « " & name & " » s'applique-t-elle à un passage de texte " &
                     "(OK = en ligne, [texte]{." & name & "}) ?\nAnnuler = balise de bloc (paragraphe).")
    withTemplate(proc (t: var Template) =
      t.customTags.add CustomTag(name: name, inline: inline,
                                 props: initOrderedTable[string, string]()))
    loadFormats()
  elif id == btnTagDel:
    let (row, tag) = gridRowTag()
    if row < 0 or tag in StdTags: return
    if not ensureEditable(): return
    if not ask("Supprimer la balise « " & tag & " » du modèle ?"): return
    withTemplate(proc (t: var Template) =
      let k = t.findTag(tag)
      if k >= 0: t.customTags.delete(k)
      for f in t.formats.mitems: f.tags.del(tag))
    loadFormats()
  elif id == btnLabelNew:
    if not ensureEditable(): return
    let name = askText("Nom de la nouvelle étiquette :", "").strip.strip(chars = {'#'})
    if name.len == 0 or curTemplate().findLabel(name) >= 0: return
    withTemplate(proc (t: var Template) =
      t.labels.add LabelDef(name: name, color: "#6b7a8f", format: ""))
    loadFormats()
  elif id == btnLabelDel:
    let row = gridSelect(gridLabels)
    if row < 1: return
    if not ensureEditable(): return
    let name = gridCell(gridLabels, row, "name")
    withTemplate(proc (t: var Template) =
      let k = t.findLabel(name)
      if k >= 0: t.labels.delete(k))
    loadFormats()
  elif id == btnTargetNote:
    app.fmtTarget = app.cur
    app.fmtName = ""
    loadFormats()
  elif id == btnTargetProject:
    app.fmtTarget = ""
    app.fmtName = ""
    loadFormats()
  elif id == btnApply:
    let policy = ApplyPolicy(clamp(listSelectedIndex(cbPolicy) - 1, 0, ord(high(ApplyPolicy))))
    let k = listSelectedIndex(cbPolicyLabel)
    let label = if k >= 1 and k <= curTemplate().labels.len: curTemplate().labels[k - 1].name else: ""
    if policy in {apLabel, apUnformattedLabel} and label.len == 0:
      warnBox("Choisissez une étiquette."); return
    let n = p.applyFormat(app.fmtTarget, app.fmtName, policy, label)
    p.saveProject(withNotes = false)
    loadFormats()
    updateHeader()
    setStatus("Format « " & app.fmtName & " » appliqué" &
           (if app.fmtTarget.len == 0: " au projet" else: "") & " (" & $n & " note(s) modifiée(s)).")
  elif id == btnClearFmt:
    if app.fmtTarget.len == 0:
      p.globalFormat = ""
    else:
      let rec = p.descendants(app.fmtTarget).len > 0 and
                ask("Retirer aussi le format propre de toutes les sous-notes ?")
      p.clearFormat(app.fmtTarget, rec)
    p.saveProject(withNotes = false)
    app.fmtName = ""
    loadFormats()
    updateHeader()
    setStatus("Format retiré : la note hérite à nouveau.")
  else:
    result = false

# main handler

proc dispatch(ev: var Event) =
  let p = app.p
  let id = ev.id
  case ev.kind
  of evWindowOpen: discard
  of evWindowClose:
    saveAll()
  of evClick:
    if id == ed: setFocus(ed); return
    for (qid, action) in quick:
      if id == qid:
        quickAction(action); return
    if id == btnNew: cmdNewNote(false)
    elif id == btnChild: cmdNewNote(true)
    elif id == btnUp: cmdMove("up")
    elif id == btnDown: cmdMove("down")
    elif id == btnIn: cmdMove("in")
    elif id == btnOut: cmdMove("out")
    elif id == btnDel: cmdDelete()
    elif id == btnSave: saveAll()
    elif id == btnPdf: exportAs(exPdf)
    elif id == btnTheme:
      app.dark = not app.dark
      var th = themeMacOS(dark = app.dark)
      th.accent = col(if app.dark: "#8fb3e0" else: "#2d5b88")
      th.radius = 7
      ev.window.theme = th
      let m = if app.dark: "dark" else: "light"
      ed.value = "theme" & Sep & m
      dv.value = "theme" & Sep & m
      gv.value = "theme" & Sep & m
      updateHeader()
    elif id == btnZoomIn: dv.value = "zoomin"
    elif id == btnZoomOut: dv.value = "zoomout"
    elif id == btnRefresh: refreshConsult()
    elif id == btnEditHere: gotoMode(1)
    elif id == btnFit: gv.value = "fit"
    elif id == btnGIn: gv.value = "zoomin"
    elif id == btnGOut: gv.value = "zoomout"
    elif id == btnRelayout: refreshGraph()
    elif id == btnGEdit:
      if app.graphSel.len > 0:
        openNote(app.graphSel)
        gotoMode(1)
    elif id == btnGConsult:
      if app.graphSel.len > 0:
        openNote(app.graphSel)
        app.scope = 2
        cbScope.value = "2"
        gotoMode(2)
        refreshConsult()
    elif id == btnTermBack:
      if app.termLevel == 2:
        fillNotes(tblTermDetail, lblTermDetail, app.termWords, app.termMap,
                  "« " & app.termWords.join(", ") & " »")
        app.termLevel = 1
      else: clearTermDetail()
    elif id == btnFamBack:
      if app.famLevel == 2:
        fillNotes(tblFamDetail, lblFamDetail, app.famWords, app.famMap, "Famille « " & app.famName & " »")
        app.famLevel = 1
      else: clearFamDetail()
    else:
      discard formatsClick(id)
  of evRightClick:
    if id == tree:
      app.treeMenu = true
      openContextMenu(tree, TreeMenuItems)
  of evChange:
    if id == ed:
      if app.loading: return
      if ev.text.startsWith("cmd:"):
        case ev.text
        of "cmd:save": saveAll()
        of "cmd:link": cmdLink()
        of "cmd:find": cmdFind()
        of "cmd:new": cmdNewNote(false)
        of "cmd:consult":
          app.scope = 2
          cbScope.value = "2"
          gotoMode(2)
          refreshConsult()
        else: discard
      else:
        if not app.dirty: setStatus("Modifié — enregistrement automatique au changement de note (Ctrl+S).")
        app.dirty = true
    elif id == edSearch:
      app.treeFilter = edSearch.value.strip
      refreshTree()
    elif id == edTermFilter:
      refreshTerms()
    elif id == cbScope:
      app.scope = max(1, listSelectedIndex(cbScope))
      refreshConsult()
    elif id == chkTree:
      gv.value = "tree" & Sep & chkTree.value
    elif id == tabCenter:
      setMode(max(1, listSelectedIndex(tabCenter)))
    elif id == cbTemplate and not app.loading:
      let k = listSelectedIndex(cbTemplate)
      if k >= 1 and k <= p.templates.len:
        p.templateName = p.templates[k - 1].name
        p.saveProject(withNotes = false)
        app.fmtName = ""
        loadFormats()
        updateHeader()
    elif id == cbFormat and not app.loading:
      let k = listSelectedIndex(cbFormat)
      let t = curTemplate()
      if k >= 1 and k <= t.formats.len:
        app.fmtName = t.formats[k - 1].name
        loadFormats()
    elif id == gridTags and not app.loading and ev.column > 0:
      if not ensureEditable():
        loadFormats(); return
      let tag = gridCell(gridTags, ev.index, "tag")
      let key = TagColumns[ev.column - 1]
      setTagProp(tag, key, ev.text)
      if curTemplate().builtin == false and app.mode == 4:
        setStatus("Balise « " & tag & " » : " & key & " = " & ev.text)
    elif id == gridLabels and not app.loading and ev.column > 0:
      if not ensureEditable():
        loadFormats(); return
      let row = ev.index
      let name = gridCell(gridLabels, row, "name")
      let colr = gridCell(gridLabels, row, "color")
      let fmt = gridCell(gridLabels, row, "format")
      let rowIdx = row - 1
      withTemplate(proc (t: var Template) =
        if rowIdx < t.labels.len:
          t.labels[rowIdx] = LabelDef(name: name, color: normColor(colr), format: fmt))
      refreshTree()
  of evSelection:
    if id == tree:
      if app.treeMenu and ev.text in TreeMenuItems:
        app.treeMenu = false
        cmdTreeMenu(ev.text)
        return
      app.treeMenu = false
      if ev.text in app.pathToId: openNote(app.pathToId[ev.text])
    elif id == menuBar:
      let parts = ev.text.split(TreeSep)
      let item = parts[^1]
      case item
      of "Nouveau projet…":
        saveAll()
        var path = ""
        unlocked:
          path = saveFileDialog(defaultName = "MonProjet", filter = "Dossier de projet|*")
        if path.len > 0:
          if isProjectDir(path): loadProjectUI(loadProject(path))
          else:
            createDir(path)
            loadProjectUI(newProjectAt(path, path.lastPathPart))
      of "Ouvrir un projet…":
        saveAll()
        var path = ""
        unlocked:
          path = openFileDialog(title = "Ouvrir un projet wdnotes (wdnotes.json)",
                                filter = "Projet wdnotes|wdnotes.json\nTous les fichiers|*")
        if path.len > 0:
          let dir = if dirExists(path): path else: path.parentDir
          if isProjectDir(dir): loadProjectUI(loadProject(dir))
          else: warnBox("Aucun fichier wdnotes.json dans " & dir)
      of "Enregistrer": saveAll()
      of "Exporter en PDF…": exportAs(exPdf)
      of "Exporter en HTML/CSS/JS…": exportAs(exHtml)
      of "Exporter en RTF…": exportAs(exRtf)
      of "Exporter pour LibreOffice (.fodt)…": exportAs(exOdt)
      of "Quitter":
        saveAll()
        quitApplication()
      of "Rechercher…": cmdFind()
      of "Insérer un lien vers une note…": cmdLink()
      of "Conception": gotoMode(1)
      of "Consultation": gotoMode(2)
      of "Graphe des liens": gotoMode(3)
      of "Formats et modèles": gotoMode(4)
      of "Mise en forme globale…":
        app.fmtTarget = ""
        app.fmtName = ""
        gotoMode(4)
        loadFormats()
      of "Syntaxe Markdown étendue":
        infoBox("Markdown + instructions :\n\n" &
          "# Titre {color: #7a2e2e; align: center}\n" &
          "Paragraphe {.alerte}   ← balise du modèle\n" &
          "[texte]{.surligne}  [texte]{color: red; bold}\n" &
          "**gras**{color: navy}  *italique*  ~~barré~~  `code`\n" &
          "[[Titre de note]]  [[Titre|libellé]]  ← liens entre notes\n" &
          "::: encadre … :::   ← bloc stylé\n" &
          "{ size: 14 }   ← ligne seule : style du bloc précédent\n" &
          "\\pagebreak  ← saut de page à l'export\n\n" &
          "Clés : font size bold italic underline strike upper color bg align\n" &
          "before after indent line border frame prefix break\n" &
          "(alias : police taille gras italique couleur fond alignement avant apres…)")
      of "À propos de wdnotes":
        infoBox("wdnotes ß1.2a - notes Markdown arborescentes\nApplication écrite par Jean-Marc Quéré\n◎ https://sonaliwan.fr\nLPCS, Lab'Oratoire, ✉ metalab (à) sonaliwan.fr\n\n" &
             "Projet : " & p.dir)
      else:
        cmdTreeMenu(item)
    elif id == ed:
      lblCaret.caption = "Ln " & ev.text.replace(":", ", Col ")
    elif id == dv:
      let link = ev.text
      if link.startsWith("note:"):
        let target = link[5 .. ^1]
        if app.scope == 1:
          storeEditor()
          app.cur = target
          dv.value = "scroll" & Sep & target
          if target in app.idToPath: treeSelectPath(tree, app.idToPath[target])
          ed.value = "set" & Sep & p.notes[target].text
          app.dirty = false
          updateHeader()
        else:
          openNote(target)
      elif link.startsWith("missing:") and app.cur.len > 0:
        let title = link[8 .. ^1]
        if ask("La note « " & title & " » n'existe pas encore. La créer comme sous-note de « " &
               p.notes[app.cur].title & " » ?"):
          let nid = p.addNote(title, app.cur)
          p.saveNote(nid)
          p.saveProject(withNotes = false)
          refreshTree()
          openNote(nid)
          gotoMode(1)
      elif link.len > 0:
        openUrl(link)
    elif id == gv:
      if ev.text.startsWith("sel:"): showGraphCard(ev.text[4 .. ^1])
      elif ev.text.startsWith("open:"):
        openNote(ev.text[5 .. ^1])
        gotoMode(1)
    elif id == tabCenter:
      setMode(max(1, listSelectedIndex(tabCenter)))
    elif id == cbScope:
      app.scope = max(1, listSelectedIndex(cbScope))
      refreshConsult()
    elif id == tblTerms:
      let w = tableCell(tblTerms, ev.index, 1)
      if w.len == 0: return
      app.termWords = @[w]
      fillNotes(tblTermDetail, lblTermDetail, app.termWords, app.termMap, "« " & w & " »")
      app.termLevel = 1
    elif id == tblTermDetail and app.termLevel == 1:
      let t = tableCell(tblTermDetail, ev.index, 1)
      if t in app.termMap:
        app.termNote = app.termMap[t]
        fillLines(tblTermDetail, lblTermDetail, app.termNote, app.termWords,
                  "« " & app.termWords.join(", ") & " »")
        app.termLevel = 2
    elif id == tblFams:
      let f = tableCell(tblFams, ev.index, 1)
      if f notin app.lex.families: return
      app.famName = f
      app.famWords = app.lex.families[f]
      let preview = app.famWords[0 ..< min(6, app.famWords.len)].join(", ")
      fillNotes(tblFamDetail, lblFamDetail, app.famWords, app.famMap,
                "Famille « " & f & " » (" & preview & (if app.famWords.len > 6: "…" else: "") & ")")
      app.famLevel = 1
    elif id == tblFamDetail and app.famLevel == 1:
      let t = tableCell(tblFamDetail, ev.index, 1)
      if t in app.famMap:
        app.famNote = app.famMap[t]
        fillLines(tblFamDetail, lblFamDetail, app.famNote, app.famWords, "Famille « " & app.famName & " »")
        app.famLevel = 2
  of evDoubleClick:
    if id == tblTermDetail and app.termLevel == 2:
      let l = tableCell(tblTermDetail, ev.index, 1).strip(chars = {'L'})
      try:
        openNote(app.termNote, parseInt(l))
        gotoMode(1)
      except ValueError: discard
    elif id == tblFamDetail and app.famLevel == 2:
      let l = tableCell(tblFamDetail, ev.index, 1).strip(chars = {'L'})
      try:
        openNote(app.famNote, parseInt(l))
        gotoMode(1)
      except ValueError: discard
    elif id == tree and app.cur.len > 0:
      app.scope = 2
      cbScope.value = "2"
      gotoMode(2)
      refreshConsult()
  else: discard

proc handler(ev: var Event) {.nimcall, gcsafe.} =
  {.cast(gcsafe).}:
    let windowEvent = ev.kind in {evWindowOpen, evWindowClose}
    if not windowEvent and ev.current != ev.id: return
    if ev.kind in {evMouseEnter, evMouseLeave, evMouseMove, evKeyUp, evFocusGained,
                   evFocusLost, evButtonDown, evButtonUp, evWheel}: return
    enterApp()
    try:
      dispatch(ev)
    except CatchableError as e:
      lblStatus.caption = "Erreur : " & e.msg
    finally:
      leaveApp()

# user interface

proc flat(parent: Container, caption, tip: string): ControlId =
  parent.addChild(newFlatButton(caption, tip)).id

proc flatSmall(parent: Container, caption, tip: string, w = 40f, h = 22f): ControlId =
  let b = parent.addChild(newFlatButton(caption, tip))
  b.fixedWidth = w
  b.fixedHeight = h
  b.id

proc buildUi(): Window =
  var th = themeMacOS(dark = false)
  th.accent = col("#2d5b88")
  th.radius = 7
  let win = newWindow("wdnotes", 1440, 900, handler, layout = lkBorder, theme = th)

  # top: menu + quick Markdown bar.
  let top = win.addChild(newContainer(lkVertical))
  top.dock = dkTop
  top.margin = 0
  top.spacing = 0
  let mb = top.addChild(newMenuBar())
  menuBar = mb.id
  for item in ["Fichier\tNouveau projet…", "Fichier\tOuvrir un projet…", "Fichier\tEnregistrer",
               "Fichier\tExporter en PDF…", "Fichier\tExporter en HTML/CSS/JS…",
               "Fichier\tExporter en RTF…", "Fichier\tExporter pour LibreOffice (.fodt)…",
               "Fichier\tQuitter",
               "Note\tNouvelle note", "Note\tNouvelle sous-note", "Note\tRenommer…",
               "Note\tMonter", "Note\tDescendre", "Note\tIndenter (devient enfant)",
               "Note\tDésindenter (remonte d'un niveau)", "Note\tDéplacer vers…",
               "Note\tÉtiquettes…", "Note\tFormat…", "Note\tDéfinir comme note principale ★",
               "Note\tDéfinir comme note lexique ◈", "Note\tSupprimer…",
               "Édition\tRechercher…", "Édition\tInsérer un lien vers une note…",
               "Affichage\tConception", "Affichage\tConsultation", "Affichage\tGraphe des liens",
               "Affichage\tFormats et modèles", "Affichage\tMise en forme globale…",
               "Aide\tSyntaxe Markdown étendue", "Aide\tÀ propos de wdnotes"]:
    menuAdd(menuBar, item)
  let bar = top.addChild(newSupercontrol(lkHorizontal))
  bar.margin = 6
  bar.spacing = 2
  for (cap, action, tip) in [("H1", "h1", "Titre 1  (# )"), ("H2", "h2", "Titre 2  (## )"),
      ("H3", "h3", "Titre 3  (### )"), ("|", "", ""),
      ("G", "bold", "Gras **texte**  (Ctrl+B)"), ("I", "italic", "Italique *texte*  (Ctrl+I)"),
      ("S", "strike", "Barré ~~texte~~"), ("</>", "code", "Code `texte`"), ("|", "", ""),
      ("❝", "quote", "Citation (> )"), ("•", "ul", "Liste à puces (- )"),
      ("1.", "ol", "Liste numérotée (1. )"), ("☐", "task", "Tâche (- [ ] )"), ("|", "", ""),
      ("Lien", "url", "Lien web [texte](url)"), ("[[Note]]", "note", "Lien vers une note (Ctrl+K)"),
      ("Image", "image", "Image ![légende](fichier)"), ("Table", "table", "Tableau"),
      ("```", "fence", "Bloc de code"), ("—", "hr", "Filet horizontal"),
      ("Saut", "break", "Saut de page (\\pagebreak)"), ("|", "", ""),
      ("::: Bloc", "div", "Bloc stylé par une balise du modèle"),
      ("[ ]{.}", "span", "Passage stylé par une balise en ligne"),
      ("{ }", "attrs", "Ajouter des instructions { … } à la ligne")]:
    if action.len == 0:
      let s = bar.addChild(newLabel("  "))
      s.stretch = false
      continue
    if cap.len < 4:
      quick.add((bar.flatSmall(cap, tip), action))
    else:
      quick.add((bar.flatSmall(cap, tip, 60f), action))
  let spacer = bar.addChild(newLabel(""))
  spacer.weight = 1
  btnSave = bar.flatSmall("Enregistrer", "Enregistrer le projet (Ctrl+S)", 80f)
  btnPdf = bar.flatSmall("⇩ PDF", "Exporter le projet en PDF", 80f)
  btnTheme = bar.flatSmall("◐", "Thème clair / sombre", 80f)

  # bottom: status bar.
  let sb = win.addChild(newSupercontrol(lkHorizontal))
  sb.dock = dkBottom
  sb.margin = 6
  let ls = sb.addChild(newLabel("Prêt."))
  ls.weight = 1
  lblStatus = ls.id
  lblInfo = sb.addChild(newLabel("")).id
  let lc = sb.addChild(newLabel("Ln 1, Col 1"))
  lc.fixedWidth = 130
  lblCaret = lc.id

  # centre: tree | (tabs | lexicon).
  let split1 = win.addChild(newSplitter(vertical = SplitSideBySide, position = 0.18))
  split1.dock = dkCenter

  # left: notes tree.
  let left = split1.addChild(newContainer(lkBorder))
  let lh = left.addChild(newContainer(lkVertical))
  lh.dock = dkTop
  let lp = lh.addChild(newLabel("Projet"))
  lp.style.text = some(col("#1f3a5f"))
  lblProject = lp.id
  edSearch = lh.addChild(newEdit(placeholder = "Filtrer les notes…")).id
  let tv = left.addChild(newTreeView())
  tv.dock = dkCenter
  tree = tv.id
  let lb = left.addChild(newSupercontrol(lkHorizontal, 2f))
  lb.dock = dkBottom
  btnNew = lb.flatSmall("＋", "Nouvelle note (même niveau)  Ctrl+N", 30f)
  btnChild = lb.flatSmall("↳", "Nouvelle sous-note", 30f)
  btnUp = lb.flatSmall("↑", "Monter", 30f)
  btnDown = lb.flatSmall("↓", "Descendre", 30f)
  btnIn = lb.flatSmall("→", "Indenter : devient enfant de la note précédente", 30f)
  btnOut = lb.flatSmall("←", "Désindenter : remonte d'un niveau", 30f)
  btnDel = lb.flatSmall("✕", "Supprimer la note", 30f)

  let split2 = split1.addChild(newSplitter(vertical = SplitSideBySide, position = 0.76))

  # centre tabs.
  let tab = split2.addChild(newTab())
  tabCenter = tab.id

  # 1 - design.
  let pDesign = tab.addPage("✎ Conception", lkBorder)
  let hd = pDesign.addChild(newContainer(lkVertical))
  hd.dock = dkTop
  let lt = hd.addChild(newLabel("Note"))
  lt.style.text = some(col("#1f3a5f"))
  lblNoteTitle = lt.id
  let lm = hd.addChild(newLabel(""))
  lm.style.text = some(col("#8a8f98"))
  lblNoteMeta = lm.id
  let editor = pDesign.addChild(newMdEditor())
  editor.dock = dkCenter
  ed = editor.id

  # 2 - consultation.
  let pView = tab.addPage("◉ Consultation", lkBorder)
  let vb = pView.addChild(newSupercontrol(lkHorizontal))
  vb.dock = dkTop
  vb.margin = 6
  let lsc = vb.addChild(newLabel("Afficher :"))
  lsc.stretch = false
  let cs = vb.addChild(newComboBox(["Document du projet (depuis la note principale)",
                                    "Note courante (aperçu rapide)",
                                    "Note courante et ses sous-notes"]))
  cs.fixedWidth = 360
  cbScope = cs.id
  let vsp = vb.addChild(newLabel(""))
  vsp.weight = 1
  btnZoomOut = vb.flat("－", "Réduire")
  btnZoomIn = vb.flat("＋", "Agrandir")
  btnRefresh = vb.flat("⟳ Actualiser", "Recalculer la mise en page")
  btnEditHere = vb.flat("✎ Éditer", "Revenir à la conception")
  let dview = pView.addChild(newDocView())
  dview.dock = dkCenter
  dv = dview.id

  # 3 - graph.
  let pGraph = tab.addPage("⬡ Graphe", lkBorder)
  let gb = pGraph.addChild(newSupercontrol(lkHorizontal))
  gb.dock = dkTop
  gb.margin = 6
  let ck = gb.addChild(newCheckBox(["Afficher la hiérarchie (pointillés)"]))
  chkTree = ck.id
  let gsp = gb.addChild(newLabel(""))
  gsp.weight = 1
  btnGOut = gb.flat("－", "Dézoomer")
  btnGIn = gb.flat("＋", "Zoomer")
  btnFit = gb.flat("⤢ Ajuster", "Tout afficher")
  btnRelayout = gb.flat("⟳ Recalculer", "Recalculer la disposition")
  let card = pGraph.addChild(newCell(lkVertical, "Note sélectionnée"))
  card.dock = dkRight
  card.fixedWidth = 270
  let gt = card.addChild(newLabel("Cliquez un point du graphe."))
  gt.style.text = some(col("#1f3a5f"))
  lblGTitle = gt.id
  let gi = card.addChild(newLabel(""))
  gi.style.text = some(col("#8a8f98"))
  lblGInfo = gi.id
  let ge = card.addChild(newLabel(""))
  ge.weight = 1
  lblGExcerpt = ge.id
  btnGEdit = card.addChild(newButton("✎ Éditer la note")).id
  btnGConsult = card.addChild(newButton("◉ Consulter la note")).id
  let graph = pGraph.addChild(newGraphView())
  graph.dock = dkCenter
  gv = graph.id

  # 4 - formats.
  let pFmt = tab.addPage("¶ Formats", lkBorder)
  let fp = pFmt.addChild(newPanel(lkVertical, scrollbars = smAutomatic))
  fp.dock = dkCenter
  let rowT = fp.addChild(newSupercontrol(lkHorizontal))
  let lmt = rowT.addChild(newLabel("Modèle"))
  lmt.fixedWidth = 70
  let ct = rowT.addChild(newComboBox(["Classique"]))
  ct.fixedWidth = 260
  cbTemplate = ct.id
  btnTplClone = rowT.flat("Cloner…", "Copier le modèle sous un nouveau nom (pour le modifier)")
  btnTplRename = rowT.flat("Renommer…", "")
  btnTplDelete = rowT.flat("Supprimer", "")
  let rowF = fp.addChild(newSupercontrol(lkHorizontal))
  let lfm = rowF.addChild(newLabel("Format"))
  lfm.fixedWidth = 70
  let cf = rowF.addChild(newComboBox(["Standard"]))
  cf.fixedWidth = 260
  cbFormat = cf.id
  btnFmtNew = rowF.flat("Nouveau…", "Nouveau format vide (hérite du format par défaut)")
  btnFmtDup = rowF.flat("Dupliquer…", "")
  btnFmtDel = rowF.flat("Supprimer", "")
  btnFmtDefault = rowF.flat("Par défaut", "Faire de ce format le format par défaut du modèle")
  let hint = fp.addChild(newLabel(""))
  hint.style.text = some(col("#b8901a"))
  lblFmtHint = hint.id

  let cellApply = fp.addChild(newCell(lkVertical, "Application du format"))
  let lta = cellApply.addChild(newLabel("Cible : —"))
  lta.style.text = some(col("#1f3a5f"))
  lblTarget = lta.id
  let rowA = cellApply.addChild(newSupercontrol(lkHorizontal))
  btnTargetNote = rowA.flat("Cible = note courante", "")
  btnTargetProject = rowA.flat("Cible = projet (global)", "")
  let rowB = cellApply.addChild(newSupercontrol(lkHorizontal))
  let cp = rowB.addChild(newComboBox(PolicyNames))
  cp.fixedWidth = 330
  cbPolicy = cp.id
  let cpl = rowB.addChild(newComboBox(["important"]))
  cpl.fixedWidth = 160
  cbPolicyLabel = cpl.id
  btnApply = rowB.addChild(newButton("Appliquer le format", isDefault = false)).id
  btnClearFmt = rowB.flat("Retirer (hériter)", "La note reprend le format de son parent")

  let cellPage = fp.addChild(newCell(lkGrid, "Page, en-tête et pied de page"))
  when compiles(cellPage.columns = 4): cellPage.columns = 4
  discard cellPage.addChild(newLabel("Papier"))
  cbPaper = cellPage.addChild(newComboBox(Papers)).id
  discard cellPage.addChild(newLabel("Orientation"))
  cbOrient = cellPage.addChild(newComboBox(["Portrait", "Paysage"])).id
  discard cellPage.addChild(newLabel("Marge haut (mm)"))
  edMT = cellPage.addChild(newEdit(placeholder = "hérité")).id
  discard cellPage.addChild(newLabel("Marge bas (mm)"))
  edMB = cellPage.addChild(newEdit(placeholder = "hérité")).id
  discard cellPage.addChild(newLabel("Marge gauche (mm)"))
  edML = cellPage.addChild(newEdit(placeholder = "hérité")).id
  discard cellPage.addChild(newLabel("Marge droite (mm)"))
  edMR = cellPage.addChild(newEdit(placeholder = "hérité")).id
  discard cellPage.addChild(newLabel("En-tête"))
  edHeader = cellPage.addChild(newEdit(placeholder = "{project} — {title}")).id
  discard cellPage.addChild(newLabel("Pied de page"))
  edFooter = cellPage.addChild(newEdit(placeholder = "{page} / {pages}")).id
  discard cellPage.addChild(newLabel("Fond de page"))
  edPageBg = cellPage.addChild(newEdit(placeholder = "#fffbea")).id
  btnPageSetup = cellPage.addChild(newButton("Mise en page…")).id
  btnPageApply = cellPage.addChild(newButton("Appliquer la page")).id

  let cellTags = fp.addChild(newCell(lkVertical, "Mise en forme des balises (Markdown et balises du modèle)"))
  let rowG = cellTags.addChild(newSupercontrol(lkHorizontal))
  btnFont = rowG.flat("Police…", "Choisir police, taille, gras, italique de la balise sélectionnée")
  btnColor = rowG.flat("Couleur…", "Couleur du texte de la balise sélectionnée")
  btnBg = rowG.flat("Fond…", "Couleur de fond de la balise sélectionnée")
  btnTagNew = rowG.flat("Nouvelle balise…", "Balise personnalisée utilisable par {.nom} ou ::: nom")
  btnTagDel = rowG.flat("Supprimer la balise", "")
  let g = cellTags.addChild(newGrid())
  g.fixedHeight = 430
  gridTags = g.id
  discard gridAddColumn(gridTags, "tag", "Balise", gcText, 92)
  discard gridAddColumn(gridTags, "font", "Police", gcCombo, 86, choices = ["", "Serif", "Sans", "Mono"])
  discard gridAddColumn(gridTags, "size", "Taille", gcText, 52)
  discard gridAddColumn(gridTags, "bold", "G", gcCheck, 30)
  discard gridAddColumn(gridTags, "italic", "I", gcCheck, 30)
  discard gridAddColumn(gridTags, "underline", "S", gcCheck, 30)
  discard gridAddColumn(gridTags, "color", "Couleur", gcText, 76)
  discard gridAddColumn(gridTags, "bg", "Fond", gcText, 76)
  discard gridAddColumn(gridTags, "align", "Align.", gcCombo, 76,
                        choices = ["", "left", "center", "right", "justify"])
  discard gridAddColumn(gridTags, "before", "Avant", gcText, 48)
  discard gridAddColumn(gridTags, "after", "Après", gcText, 48)
  discard gridAddColumn(gridTags, "indent", "Retrait", gcText, 52)
  discard gridAddColumn(gridTags, "frame", "Cadre", gcCombo, 70,
                        choices = ["", "left", "box", "bottom", "top"])
  discard gridAddColumn(gridTags, "border", "Bordure", gcText, 76)
  discard gridAddColumn(gridTags, "prefix", "Préfixe", gcText, 90)
  discard gridAddColumn(gridTags, "extra", "Autres { }", gcText, 170)
  gridSetColumnEdit(gridTags, "tag", emReadOnly)

  let cellLabels = fp.addChild(newCell(lkVertical, "Étiquettes (une étiquette peut imposer un format)"))
  let rowL = cellLabels.addChild(newSupercontrol(lkHorizontal))
  btnLabelNew = rowL.flat("Nouvelle étiquette…", "")
  btnLabelDel = rowL.flat("Supprimer l'étiquette", "")
  let gl = cellLabels.addChild(newGrid())
  gl.fixedHeight = 190
  gridLabels = gl.id
  discard gridAddColumn(gridLabels, "name", "Étiquette", gcText, 160)
  discard gridAddColumn(gridLabels, "color", "Couleur", gcText, 100)
  discard gridAddColumn(gridLabels, "format", "Format associé", gcCombo, 180, choices = [""])

  # right: lexicon.
  let rt = split2.addChild(newTab())
  tabRight = rt.id
  let pTerms = rt.addPage("Termes", lkBorder)
  let tt = pTerms.addChild(newContainer(lkVertical))
  tt.dock = dkTop
  edTermFilter = tt.addChild(newEdit(placeholder = "Filtrer les termes…")).id
  let tsplit = pTerms.addChild(newSplitter(vertical = not SplitSideBySide, position = 0.55))
  tsplit.dock = dkCenter
  let tbl = tsplit.addChild(newTable())
  tblTerms = tbl.id
  tableAddColumn(tblTerms, "Terme", 150)
  tableAddColumn(tblTerms, "Occ.", 60, alRight)
  let tdet = tsplit.addChild(newContainer(lkBorder))
  let tdh = tdet.addChild(newContainer(lkVertical))
  tdh.dock = dkTop
  let ltd = tdh.addChild(newLabel(""))
  lblTermDetail = ltd.id
  btnTermBack = tdh.addChild(newFlatButton("◂ Retour", "Revenir au niveau précédent")).id
  let td = tdet.addChild(newTable())
  td.dock = dkCenter
  tblTermDetail = td.id
  tableAddColumn(tblTermDetail, "Note / ligne", 140)
  tableAddColumn(tblTermDetail, "Occ.", 44, alRight)
  tableAddColumn(tblTermDetail, "Extrait", 260)

  let pFam = rt.addPage("Familles", lkBorder)
  let fsplit = pFam.addChild(newSplitter(vertical = not SplitSideBySide, position = 0.45))
  fsplit.dock = dkCenter
  let tf = fsplit.addChild(newTable())
  tblFams = tf.id
  tableAddColumn(tblFams, "Famille", 130)
  tableAddColumn(tblFams, "Mots", 50, alRight)
  tableAddColumn(tblFams, "Occ.", 56, alRight)
  let fdet = fsplit.addChild(newContainer(lkBorder))
  let fdh = fdet.addChild(newContainer(lkVertical))
  fdh.dock = dkTop
  lblFamDetail = fdh.addChild(newLabel("")).id
  btnFamBack = fdh.addChild(newFlatButton("◂ Retour", "Revenir au niveau précédent")).id
  let fd = fdet.addChild(newTable())
  fd.dock = dkCenter
  tblFamDetail = fd.id
  tableAddColumn(tblFamDetail, "Note / ligne", 140)
  tableAddColumn(tblFamDetail, "Occ.", 44, alRight)
  tableAddColumn(tblFamDetail, "Extrait", 260)
  win

# start

proc findStartProject(): string =
  let args = commandLineParams()
  if args.len > 0 and isProjectDir(args[0]): return args[0]
  for cand in [getAppDir() / "demo", currentSourcePath().parentDir / "demo", getCurrentDir() / "demo"]:
    if isProjectDir(cand): return cand
  ""

when isMainModule:
  initLock(gLock)
  initLock(pkLock)
  app = App(mode: 1, scope: 1)
  let win = buildUi()
  mainWinId = win.id
  chkTree.value = "1"
  cbScope.value = "1"
  cbPolicy.value = "1"
  var start = findStartProject()
  {.cast(gcsafe).}:
    enterApp()
    try:
      if start.len > 0:
        loadProjectUI(loadProject(start))
      else:
        let dir = getHomeDir() / "wdnotes-demo"
        createDir(dir)
        loadProjectUI(if isProjectDir(dir): loadProject(dir) else: newProjectAt(dir, "Mes notes"))
    finally:
      leaveApp()
  runApplication()
