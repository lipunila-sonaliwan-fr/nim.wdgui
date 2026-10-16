#[
  __         __  _   __
  \ \__   __/ /_| | / / _   _  __ _
   \ \ \ / / / _` |/ / | | | |/ _` |
    \ \ V / / (_| / /__| |_| | (_| |
     \_\_/_/ \__,_\____/\__,_|\__,_|  [S]tudio 1.3a,
      Un atelier logiciel écrit par Jean-Marc Quéré.
        LPCS, Lab'Oratoire (metalab at sonaliwan.fr)

  wdlua - IDE pour le Lua standard, construit sur wdgui.

  nim c -r wdlua.nim [dossier_de_projet | fichier.lua]

    Éditeur, analyse en continu, interpréteur intégré (exécution directe ou
    pas à pas avec points d'arrêt, variables et pile d'appels), console avec
    saisie, référence de l'API issue des paquets enregistrés.

  Tous droits réservés, Jean-Marc Quéré, sonaliwan.fr 2026.

]#

import std/[os, strutils, sets, tables, atomics, locks, algorithm, deques]
import wdgui
import ide/[compat, settings, lualang, langdocs, lualint, codeeditor, session]
import lua/api
import packages/all

const
  AppName = "wdlua"
  TextExts = [".lua", ".txt", ".md", ".json", ".csv", ".nims", ".nim", ".ini", ".cfg"]
  NewMain = """-- main.lua : point d'entrée du projet
local ui = require "ui"

print("Bonjour depuis wdlua !")

local win = ui.window{title = "Bonjour", width = 420, height = 200}
local lbl = win:add(ui.label("Cliquez sur le bouton", "center"))
local nb = 0
local btn = win:add(ui.button("Compter", {default = true}))

btn.onclick = function(ev)
  nb += 1                              -- affectation composée (manuel §9.2)
  lbl.caption = "Clics : " .. nb
  if (nb == 5) print("cinq clics !")   -- forme courte de if
end

ui.run()
"""
  Shortcuts = """Édition
Ctrl+X/C/V couper, copier, coller        Ctrl+Z/Y annuler, rétablir
Ctrl+F rechercher, Ctrl+H / F3 suivant   Ctrl+L aller à la ligne
Ctrl+W/E début / fin de ligne            Ctrl+D dupliquer la ligne
Tab / Maj+Tab indenter, désindenter      Ctrl+B commenter / décommenter
Maj+Entrée ajouter la fin de bloc        Ctrl+Espace complétion
F12 ou Ctrl+clic aller à la définition   Ctrl+Tab document suivant

Exécution et débogage
Ctrl+R exécuter (sans débogueur)         F5 déboguer / continuer
F9 ou clic dans la marge : point d'arrêt F10 pas principal
F11 pas à pas                            Maj+F11 sortir de la fonction
Maj+F5 arrêter"""

type
  ProblemRow = object
    uid: int
    path: string
    line, col: int

  AppState = object
    settings: Settings
    root: string
    index: ProjectIndex
    diagByUid: Table[int, tuple[title, path: string, diags: seq[Diagnostic]]]
    runtimeRows: seq[tuple[path: string, line: int, msg: string]]
    rows: seq[ProblemRow]
    outline: seq[Symbol]
    outlineKey: string
    findReq: FindRequest
    apiRows: seq[ApiDoc]
    pause: PauseInfo
    paused: bool
    consoleBuf: string

var
  win: Window
  gWin: typeof(Event().window)
  haveWin: Atomic[bool]
  mnu, edId, trProj, lstOutline, trApi, edApiDoc, tabLeft, tabBottom,
    tblProb, edOut, edIn, btnSend, btnCopy, btnClear, tblVars, lstStack, lblStatus, lblPos,
    btnOpen, btnNew, btnSave, btnCheck, btnRun, btnDebug, btnStepIn, btnStepOver,
    btnStepOut, btnCont, btnPause, btnStop: ControlId
  gLock: Lock
  st: AppState
  lintGen: Atomic[int]
  running: Atomic[bool]
  inLock: Lock
  inCond: Cond
  inQueue: Deque[string]
  waitingInput: Atomic[bool]

initLock(gLock)
initLock(inLock)
initCond(inCond)

template withState(body: untyped) =
  {.cast(gcsafe).}:
    withLock gLock:
      body

#
# Aides
#

proc status(msg: string) = lblStatus.caption = msg

proc root(): string =
  withState: result = st.root

proc opts(): Settings =
  withState: result = st.settings

proc setOpts(s: Settings) =
  withState: st.settings = s
  saveSettings(s)

proc relPath(p: string): string =
  let r = root()
  if r.len > 0 and p.startsWith(r): relativePath(p, r) else: p

proc updateTitle() =
  let uid = editorActiveUid(edId)
  var t = AppName & " — Lua"
  if uid >= 0:
    let info = editorInfo(edId, uid)
    t = (if info.dirty: "● " else: "") & info.title & "  —  " & AppName
  let r = root()
  if r.len > 0: t.add "  [" & extractFilename(r) & "]"
  if running.load(): t.add "  (en cours)"
  if haveWin.load(): gWin.caption = t

proc consoleAppend(s: string) =
  # Ajoute à la console en gardant la fin visible (comme la console de wdnim).
  {.cast(gcsafe).}:
    withControl(edOut, Edit, e):
      var t = e.text & s
      if t.len > 400_000: t = t[t.len - 300_000 .. ^1]
      e.setValueText(t)

proc consoleClear() =
  edOut.value = ""

proc consoleCopy() =
  let text = edOut.value
  if text.len == 0:
    status("La console est vide.")
    return
  editorCopyToClipboard(edId, text)
  status("Contenu de la console copié dans le presse-papiers (" & $text.len & " caractères).")

proc setRunButtons(isRunning, isPaused: bool) =
  let idle = not isRunning
  btnRun.state = (if idle: csActive else: csGrayed)
  btnDebug.state = (if idle: csActive else: csGrayed)
  btnCont.state = (if isPaused: csActive else: csGrayed)
  btnStepIn.state = (if idle or isPaused: csActive else: csGrayed)
  btnStepOver.state = (if isPaused: csActive else: csGrayed)
  btnStepOut.state = (if isPaused: csActive else: csGrayed)
  btnPause.state = (if isRunning and not isPaused: csActive else: csGrayed)
  btnStop.state = (if isRunning: csActive else: csGrayed)

#
# Projet
#

proc reindex() =
  let idx = indexProject(root())
  var names: seq[string]
  for n in idx.names: names.add n
  names.sort()
  withState: st.index = idx
  editorSetProjectNames(edId, names)

proc fillProjectTree() =
  let r = root()
  treeDeleteAll(trProj)
  if r.len == 0 or not dirExists(r): return
  var files: seq[string]
  for f in walkDirRec(r, relative = true):
    let u = f.replace('\\', '/')
    if u.startsWith(".") or "/." in u: continue
    files.add u
  files.sort()
  let top = extractFilename(r)
  for f in files: treeAdd(trProj, top & TreeSep & f.replace("/", $TreeSep))
  treeExpand(trProj, top)

proc openProject(dir: string) =
  if not dirExists(dir):
    alert(iconStop, "Dossier introuvable :\n" & dir)
    return
  withState:
    st.root = absolutePath(dir)
    st.settings.lastProject = st.root
  saveSettings(opts())
  fillProjectTree()
  reindex()
  if fileExists(dir / "main.lua") and not editorIsOpen(edId, dir / "main.lua"):
    discard editorOpen(edId, dir / "main.lua", readFile(dir / "main.lua"))
  status("Projet : " & dir)
  updateTitle()

proc openFile(path: string): int =
  result = -1
  let ext = path.splitFile.ext.toLowerAscii
  if ext notin TextExts and ext.len > 0:
    if confirm(iconQuestion, "Ouvrir « " & extractFilename(path) & " » comme texte ?") != drOk: return
  try:
    result = editorOpen(edId, path, readFile(path))
    if root().len == 0: openProject(path.parentDir)
  except IOError, OSError:
    alert(iconStop, "Lecture impossible :\n" & path)

#
# Analyse
#

proc refreshProblems() =
  var rowsText: seq[array[5, string]]
  var rows: seq[ProblemRow]
  withState:
    var uids: seq[int]
    for k in st.diagByUid.keys: uids.add k
    uids.sort()
    for uid in uids:
      let e = st.diagByUid[uid]
      for d in e.diags:
        rows.add ProblemRow(uid: uid, path: e.path, line: d.line, col: d.col)
        rowsText.add [$d.sev, e.title, $(d.line + 1), $(d.col + 1), d.msg]
    for r in st.runtimeRows:
      rows.add ProblemRow(uid: 0, path: r.path, line: r.line, col: 0)
      rowsText.add ["Exécution", extractFilename(r.path), $(r.line + 1), "", r.msg]
    st.rows = rows
  tableDeleteAll(tblProb)
  for t in rowsText:
    discard tableAddLine(tblProb, t[0], t[1], t[2], t[3], t[4])

proc refreshOutline(syms: seq[Symbol], uid: int) =
  var key = $uid & ":"
  for s in syms: key.add s.display & "@" & $s.line & ";"
  var changed = false
  withState:
    if key != st.outlineKey:
      st.outlineKey = key
      st.outline = syms
      changed = true
  if not changed: return
  listDeleteAll(lstOutline)
  for s in syms:
    let icon = case s.kind
      of skFunction, skLocalFunction: "ƒ "
      of skGlobal: "● "
      of skLocal: "· "
    discard listAdd(lstOutline, icon & s.display & "    :" & $(s.line + 1))

proc lintDoc(uid: int) =
  if uid < 0: return
  let snap = editorSnapshot(edId, uid)
  let info = editorInfo(edId, uid)
  if snap.lines.len == 0: return
  let (toks, _) = lexAll(snap.lines)
  let (syms, localNames) = collectSymbols(snap.lines, toks)
  var known: HashSet[string]
  var o: Settings
  withState:
    known = knownNamesFor(st.index, localNames)
    o = st.settings
  let diags = lint(snap.lines, toks, known,
                   LintOptions(flagExtensions: o.flagExtensions, unknownCalls: o.unknownCalls),
                   editorSourceName(edId, uid))
  editorSetDiagnostics(edId, uid, snap.version, diags)
  withState:
    st.diagByUid[uid] = (title: info.title, path: info.path, diags: diags)
  if uid == editorActiveUid(edId): refreshOutline(syms, uid)
  refreshProblems()

proc scheduleLint() =
  let g = lintGen.fetchAdd(1) + 1
  sleep(350)
  if lintGen.load() == g:
    lintDoc(editorActiveUid(edId))
    updateTitle()

proc lintAllOpen() =
  for d in editorDocs(edId): lintDoc(d.uid)

#
# Fichiers
#

proc saveAs(uid: int): bool

proc save(uid: int): bool =
  if uid < 0: return false
  let info = editorInfo(edId, uid)
  if info.path.len == 0: return saveAs(uid)
  try:
    writeFile(info.path, editorText(edId, uid))
    editorMarkSaved(edId, uid, info.version)
    status("Enregistré : " & relPath(info.path))
    reindex()
    lintDoc(uid)
    updateTitle()
    result = true
  except IOError, OSError:
    alert(iconStop, "Écriture impossible :\n" & info.path)

proc saveAs(uid: int): bool =
  if uid < 0: return false
  let info = editorInfo(edId, uid)
  var target = saveFileDialog(defaultName = info.title, filter = "Code Lua|*.lua\nTous les fichiers|*")
  if target.len == 0: return false
  if target.splitFile.ext.len == 0: target.add ".lua"
  try:
    writeFile(target, editorText(edId, uid))
    editorMarkSaved(edId, uid, info.version, target)
    if root().len == 0: openProject(target.parentDir) else: fillProjectTree()
    status("Enregistré : " & relPath(target))
    reindex()
    updateTitle()
    result = true
  except IOError, OSError:
    alert(iconStop, "Écriture impossible :\n" & target)

proc saveAll(): bool =
  result = true
  for d in editorDocs(edId):
    if d.dirty and d.path.len > 0 and not save(d.uid): result = false

proc closeDoc(uid: int) =
  let info = editorInfo(edId, uid)
  if info.dirty:
    if confirm(iconQuestion, "« " & info.title & " » a été modifié.\n" &
               "OK : enregistrer puis fermer.  Annuler : continuer l'édition.") != drOk: return
    if not save(uid): return
  editorClose(edId, uid)
  withState: st.diagByUid.del(uid)
  refreshProblems()
  lintDoc(editorActiveUid(edId))
  updateTitle()

proc newFileInProject() =
  let r = root()
  var name = prompt(iconQuestion, "Nom du nouveau fichier :", "module.lua")
  if name.strip().len == 0: return
  if name.splitFile.ext.len == 0: name.add ".lua"
  if r.len == 0:
    discard editorNew(edId, name)
    return
  let path = r / name
  if fileExists(path):
    discard openFile(path)
    return
  let modName = name.changeFileExt("")
  try:
    createDir(path.parentDir)
    writeFile(path, "-- " & name & "\n-- usage : local " & modName & " = require \"" & modName &
              "\"\nlocal M = {}\n\nreturn M\n")
  except IOError, OSError:
    alert(iconStop, "Création impossible :\n" & path)
    return
  fillProjectTree()
  discard openFile(path)

proc newProject() =
  let dir = prompt(iconQuestion, "Dossier du nouveau projet :", getHomeDir() / "projet_lua")
  if dir.strip().len == 0: return
  try:
    createDir(dir)
    if not fileExists(dir / "main.lua"): writeFile(dir / "main.lua", NewMain)
  except IOError, OSError:
    alert(iconStop, "Création impossible :\n" & dir)
    return
  openProject(dir)

#
# Navigation
#

proc uidForSource(source: string, open = true): int =
  result = editorUidOf(edId, source)
  if result < 0 and open and fileExists(source): result = openFile(source)

proc gotoFile(path: string, line, col: int) =
  var uid = uidForSource(path)
  if uid < 0 and root().len > 0:
    for f in walkDirRec(root()):
      if extractFilename(f) == extractFilename(path):
        uid = uidForSource(f)
        break
  if uid >= 0:
    editorGoto(edId, uid, line, col)
    editorFlush(edId)

proc gotoDefinition(word: string) =
  if word.len == 0: return
  var locs: seq[Location]
  withState: locs = st.index.defs.getOrDefault(word)
  let uid = editorActiveUid(edId)
  if uid >= 0:
    let snap = editorSnapshot(edId, uid)
    let (toks, _) = lexAll(snap.lines)
    let (syms, _) = collectSymbols(snap.lines, toks)
    for s in syms:
      if s.name == word:
        editorGoto(edId, uid, s.line, 0)
        editorFlush(edId)
        return
  if locs.len > 0: gotoFile(locs[0].file, locs[0].line, 0)
  elif apiSummary(word).len > 0: status(apiSummary(word))
  else: status("Aucune définition trouvée pour « " & word & " »")

proc showSignature() =
  let ctx = editorCallContext(edId)
  if ctx.name.len > 0:
    let s = apiSummary(ctx.name, ctx.isMethod)
    if s.len > 0:
      status(s & "   [argument " & $(ctx.arg + 1) & "]")
      return
  let w = editorWordAtCursor(edId)
  if w.len > 0:
    let s = apiSummary(w)
    if s.len > 0: status(s)

#
# Recherche
#

proc doFind(replace: bool) =
  var req: FindRequest
  withState: req = st.findReq
  let sel = editorSelection(edId)
  if sel.len > 0 and '\n' notin sel: req.findText = sel
  if findDialog(req, replace = replace) != drOk: return
  withState: st.findReq = req
  if req.action == faReplaceAll:
    status($editorReplaceAll(edId, req) & " remplacement(s)")
  elif req.action == faReplace:
    discard editorReplace(edId, req)
  elif not editorFind(edId, req):
    status("« " & req.findText & " » introuvable")
  editorFlush(edId)

proc findAgain(backwards: bool) =
  var req: FindRequest
  withState: req = st.findReq
  if req.findText.len == 0:
    doFind(false)
    return
  when compiles(req.backwards):
    req.backwards = backwards
  if not editorFind(edId, req): status("« " & req.findText & " » introuvable")
  editorFlush(edId)

proc gotoLine() =
  let uid = editorActiveUid(edId)
  if uid < 0: return
  let cur = editorCursor(edId)
  let s = prompt(iconQuestion, "Aller à la ligne :", $(cur.line + 1))
  try:
    editorGoto(edId, uid, parseInt(s.strip()) - 1, 0)
    editorFlush(edId)
  except ValueError: discard

#
# Exécution et débogage
#

proc allBreakpoints(): seq[(string, seq[int])] =
  for d in editorDocs(edId):
    var lines: seq[int]
    for l in editorBreakpoints(edId, d.uid): lines.add l + 1
    result.add (editorSourceName(edId, d.uid), lines)

proc showPause(info: PauseInfo, frameIdx: int) =
  tableDeleteAll(tblVars)
  if frameIdx < info.frames.len:
    for v in info.frames[frameIdx].vars:
      discard tableAddLine(tblVars, v.name, v.value, v.kind, v.scope)
  for v in info.globals:
    discard tableAddLine(tblVars, v.name, v.value, v.kind, v.scope)

proc onPaused(info: PauseInfo) =
  withState:
    st.pause = info
    st.paused = true
  setRunButtons(true, true)
  let uid = uidForSource(info.source)
  if uid >= 0:
    editorSetExecLine(edId, uid, info.line - 1)
    editorFlush(edId)
  listDeleteAll(lstStack)
  for f in info.frames:
    discard listAdd(lstStack, f.name & "    " & extractFilename(f.source) & ":" & $f.line)
  showPause(info, 0)
  tabBottom.value = "3"
  status("En pause : " & extractFilename(info.source) & " ligne " & $info.line &
         " — F5 continuer, F10 pas principal, F11 pas à pas, Maj+F11 sortir")

proc resume(mode: StepMode) =
  var wasPaused = false
  withState:
    wasPaused = st.paused
    st.paused = false
  if not wasPaused: return
  editorSetExecLine(edId, -1, 0)
  setRunButtons(true, false)
  status("Exécution…")
  debugCommand(mode)

proc programInput(prompt: string): (bool, string) =
  # io.read : attend une ligne saisie dans la console.
  {.cast(gcsafe).}:
    if prompt.len > 0: consoleAppend(prompt)
    waitingInput.store(true)
    edIn.state = csActive
    setFocus(edIn)
    status("Le programme attend une saisie : tapez dans la console puis Entrée")
    acquire(inLock)
    while inQueue.len == 0 and running.load():
      wait(inCond, inLock)
    var line = ""
    var ok = false
    if inQueue.len > 0:
      line = inQueue.popFirst()
      ok = true
    release(inLock)
    waitingInput.store(false)
    if ok: consoleAppend(line & "\n")
    (ok, line)

proc sendInput() =
  let s = edIn.value
  edIn.value = ""
  {.cast(gcsafe).}:
    withLock inLock:
      inQueue.addLast s
      signal(inCond)

proc runProgramFrom(debug, stepFirst: bool) =
  # réservation atomique : deux déclenchements rapprochés ne lancent qu'une exécution.
  if running.exchange(true):
    status("Un programme est déjà en cours.")
    return
  let o = opts()
  let r = root()
  var path = ""
  if o.mainFile.len > 0 and r.len > 0 and fileExists(r / o.mainFile): path = r / o.mainFile
  elif r.len > 0 and fileExists(r / "main.lua"): path = r / "main.lua"
  else:
    let uid = editorActiveUid(edId)
    if uid < 0:
      running.store(false)
      status("Aucun programme à exécuter.")
      return
    path = editorSourceName(edId, uid)
  discard saveAll()
  withState:
    st.runtimeRows.setLen(0)
    st.paused = false
  refreshProblems()
  consoleClear()
  tableDeleteAll(tblVars)
  listDeleteAll(lstStack)
  tabBottom.value = "2"
  setRunButtons(true, false)
  updateTitle()
  consoleAppend("▶ " & extractFilename(path) & (if debug: " (débogage)" else: "") & "\n")
  status(if debug: "Débogage de " & extractFilename(path) else: "Exécution de " & extractFilename(path))
  var args: seq[string]
  for a in o.programArgs.splitWhitespace(): args.add a
  var hooks: SessionHooks
  hooks.output = proc (s: string) =
    {.cast(gcsafe).}: consoleAppend(s)
  hooks.input = proc (prompt: string): (bool, string) =
    {.cast(gcsafe).}: result = programInput(prompt)
  hooks.paused = proc (info: PauseInfo) =
    {.cast(gcsafe).}: onPaused(info)
  hooks.breakpoints = proc (): seq[(string, seq[int])] =
    {.cast(gcsafe).}: result = allBreakpoints()
  hooks.sourceProvider = proc (p: string): (bool, string) =
    {.cast(gcsafe).}:
      let uid = editorUidOf(edId, p)
      if uid >= 0: result = (true, editorText(edId, uid))
      else: result = (false, "")
  hooks.finished = proc (ok: bool, msg, source: string, line: int) =
    {.cast(gcsafe).}:
      running.store(false)
      withLock inLock: signal(inCond)
      editorSetExecLine(edId, -1, 0)
      setRunButtons(false, false)
      if ok:
        consoleAppend("\n■ " & msg & "\n")
        status("Programme " & msg)
      else:
        consoleAppend("\n✖ " & msg & "\n")
        status("Erreur : " & msg.splitLines()[0])
        if line > 0:
          withState: st.runtimeRows.add (path: source, line: line - 1, msg: msg.splitLines()[0])
          refreshProblems()
          gotoFile(source, line - 1, 0)
      updateTitle()
  runProgram(path, args, debug, stepFirst, hooks)

proc doStop() =
  if not running.load(): return
  stopProgram()
  {.cast(gcsafe).}:
    withLock inLock: signal(inCond)
  resume(smRun)
  status("Arrêt demandé…")

proc doContinueOrDebug() =
  var p = false
  withState: p = st.paused
  if p: resume(smRun)
  elif not running.load(): runProgramFrom(true, false)

proc doStep(mode: StepMode) =
  var p = false
  withState: p = st.paused
  if p: resume(mode)
  elif not running.load() and mode == smInto: runProgramFrom(true, true)

proc syncBreakpoints(uid: int) =
  if not running.load(): return
  var lines: seq[int]
  for l in editorBreakpoints(edId, uid): lines.add l + 1
  updateBreakpoints(editorSourceName(edId, uid), lines)

proc programArguments() =
  var o = opts()
  o.programArgs = prompt(iconQuestion, "Arguments du programme (os.args / arg) :", o.programArgs)
  o.mainFile = prompt(iconQuestion,
    "Fichier à exécuter, relatif au projet (vide = main.lua, sinon le fichier actif) :", o.mainFile).strip()
  setOpts(o)

#
# Panneau API
#

proc fillApiTree() =
  let rows = apiEntries()
  withState: st.apiRows = rows
  treeDeleteAll(trApi)
  for e in rows: treeAdd(trApi, e.section & TreeSep & e.signature)

proc apiEntryForPath(path: string): (bool, ApiDoc) =
  let parts = path.split(TreeSep)
  if parts.len < 2: return
  withState:
    for e in st.apiRows:
      if e.section == parts[0] and e.signature == parts[^1]:
        return (true, e)

proc callTemplate(e: ApiDoc): string =
  var sig = e.signature
  let p = sig.find('(')
  if p < 0: return sig
  var args = sig[p + 1 .. ^2]
  let b = args.find('[')
  if b >= 0: args = args[0 ..< b]
  args = args.strip(chars = {' ', ','})
  let head = sig[0 ..< p]
  if e.isMethod: ":" & e.name & "(" & args & ")" else: head & "(" & args & ")"

#
# Menus
#

proc applyView() =
  let o = opts()
  editorSetOptions(edId, o.minimap, o.dark)
  if haveWin.load(): gWin.theme = themeFor(o.dark)

proc onMenu(path: string) =
  let item = path.split(TreeSep)[^1]
  case item
  of "Nouveau projet…": newProject()
  of "Ouvrir un projet…":
    let f = openFileDialog(title = "Choisissez un fichier du dossier du projet (ex. main.lua)",
                           filter = "Code Lua|*.lua\nTous les fichiers|*")
    if f.len > 0: openProject(f.parentDir)
  of "Ouvrir un dossier par son chemin…":
    let d = prompt(iconQuestion, "Chemin du dossier :", (if root().len > 0: root() else: getHomeDir()))
    if d.strip().len > 0: openProject(d.strip())
  of "Nouveau fichier…": newFileInProject()
  of "Ouvrir un fichier…":
    let f = openFileDialog(title = "Ouvrir", filter = "Code Lua|*.lua\nTous les fichiers|*")
    if f.len > 0: discard openFile(f)
  of "Enregistrer": discard save(editorActiveUid(edId))
  of "Enregistrer sous…": discard saveAs(editorActiveUid(edId))
  of "Enregistrer tout": discard saveAll()
  of "Fermer l'onglet":
    let uid = editorActiveUid(edId)
    if uid >= 0: closeDoc(uid)
  of "Quitter":
    var dirty = false
    for d in editorDocs(edId):
      if d.dirty: dirty = true
    if not dirty or confirm(iconExclamation, "Des fichiers ne sont pas enregistrés. Quitter quand même ?") == drOk:
      doStop()
      saveSettings(opts())
      quitApplication()
  of "Annuler": editorCommand(edId, "undo")
  of "Rétablir": editorCommand(edId, "redo")
  of "Couper": editorCommand(edId, "cut")
  of "Copier": editorCommand(edId, "copy")
  of "Coller": editorCommand(edId, "paste")
  of "Tout sélectionner": editorCommand(edId, "selectall")
  of "Dupliquer la ligne": editorCommand(edId, "dup")
  of "Commenter / décommenter": editorCommand(edId, "comment")
  of "Indenter": editorCommand(edId, "indent")
  of "Désindenter": editorCommand(edId, "outdent")
  of "Rechercher…": doFind(false)
  of "Remplacer…": doFind(true)
  of "Occurrence suivante": findAgain(false)
  of "Aller à la ligne…": gotoLine()
  of "Aller à la définition": gotoDefinition(editorWordAtCursor(edId))
  of "Vérifier les fichiers ouverts":
    reindex()
    lintAllOpen()
    tabBottom.value = "1"
  of "Exécuter (Ctrl+R)": runProgramFrom(false, false)
  of "Déboguer / Continuer (F5)": doContinueOrDebug()
  of "Pas à pas (F11)": doStep(smInto)
  of "Pas principal (F10)": doStep(smOver)
  of "Sortir de la fonction (Maj+F11)": doStep(smOut)
  of "Pause": pauseProgram()
  of "Arrêter (Maj+F5)": doStop()
  of "Basculer le point d'arrêt (F9)": editorToggleBreakpoint(edId)
  of "Supprimer tous les points d'arrêt": editorClearBreakpoints(edId)
  of "Arguments et fichier principal…": programArguments()
  of "Minicarte":
    var o = opts()
    o.minimap = not o.minimap
    setOpts(o)
    applyView()
  of "Thème sombre / clair":
    var o = opts()
    o.dark = not o.dark
    setOpts(o)
    applyView()
  of "Signaler les extensions du manuel":
    var o = opts()
    o.flagExtensions = not o.flagExtensions
    setOpts(o)
    lintAllOpen()
  of "Signaler les fonctions inconnues":
    var o = opts()
    o.unknownCalls = not o.unknownCalls
    setOpts(o)
    lintAllOpen()
  of "Raccourcis clavier": alert(iconInformation, Shortcuts, title = "Raccourcis")
  of "Référence des paquets": tabLeft.value = "3"
  of "Copier la console": consoleCopy()
  of "Effacer la console": consoleClear()
  of "À propos":
    var names: seq[string]
    for p in packages(): names.add p.name
    alert(iconInformation,
      "wdLua [S]tudio 1.3a,\n" &
      "Un atelier logiciel écrit par Jean-Marc Quéré.\n" &
      "LPCS, Lab'Oratoire (metalab at sonaliwan.fr)\n\n" &
      "Paquets : " & names.join(", ") & "\n" & $apiEntries().len & " fonctions documentées.",
      title = "À propos")
  else: discard

proc buildMenu(m: ControlId) =
  let menus = [
    ("Fichier", @["Nouveau projet…", "Ouvrir un projet…", "Ouvrir un dossier par son chemin…",
                  "Nouveau fichier…", "Ouvrir un fichier…", "Enregistrer", "Enregistrer sous…",
                  "Enregistrer tout", "Fermer l'onglet", "Quitter"]),
    ("Édition", @["Annuler", "Rétablir", "Couper", "Copier", "Coller", "Tout sélectionner",
                  "Dupliquer la ligne", "Commenter / décommenter", "Indenter", "Désindenter"]),
    ("Recherche", @["Rechercher…", "Remplacer…", "Occurrence suivante", "Aller à la ligne…",
                    "Aller à la définition"]),
    ("Exécuter", @["Exécuter (Ctrl+R)", "Déboguer / Continuer (F5)", "Pas à pas (F11)",
                   "Pas principal (F10)", "Sortir de la fonction (Maj+F11)", "Pause",
                   "Arrêter (Maj+F5)", "Basculer le point d'arrêt (F9)",
                   "Supprimer tous les points d'arrêt", "Vérifier les fichiers ouverts",
                   "Arguments et fichier principal…"]),
    ("Affichage", @["Copier la console", "Effacer la console", "Minicarte", "Thème sombre / clair", "Signaler les extensions du manuel",
                    "Signaler les fonctions inconnues"]),
    ("Aide", @["Raccourcis clavier", "Référence des paquets", "À propos"])]
  for (top, items) in menus:
    for it in items: menuAdd(m, top & TreeSep & it)

#
# Signaux de l'éditeur
#

proc onEditorSignal(text: string) =
  if text.startsWith("pos:"):
    let p = text.split(':')
    if p.len >= 3: lblPos.caption = "Ln " & p[1] & ", Col " & p[2]
    showSignature()
  elif text.startsWith("doc:"):
    lintDoc(editorActiveUid(edId))
    updateTitle()
  elif text.startsWith("bp:"):
    try: syncBreakpoints(parseInt(text[3 .. ^1])) except ValueError: discard
  elif text.startsWith("cmd:"):
    let parts = text[4 .. ^1].split(':', maxsplit = 1)
    let arg = if parts.len > 1: parts[1] else: ""
    case parts[0]
    of "save": discard save(editorActiveUid(edId))
    of "saveas": discard saveAs(editorActiveUid(edId))
    of "find": doFind(false)
    of "replace": doFind(true)
    of "findnext": findAgain(false)
    of "findprev": findAgain(true)
    of "goto": gotoLine()
    of "run": runProgramFrom(false, false)
    of "debug": doContinueOrDebug()
    of "stop": doStop()
    of "stepinto": doStep(smInto)
    of "stepover": doStep(smOver)
    of "stepout": doStep(smOut)
    of "new": newFileInProject()
    of "open": onMenu("Fichier" & TreeSep & "Ouvrir un fichier…")
    of "close":
      try: closeDoc(parseInt(arg)) except ValueError: discard
    of "definition": gotoDefinition(arg)
    else: discard

#
# Gestionnaire
#

proc handler(ev: var Event) {.nimcall, gcsafe.} =
  {.cast(gcsafe).}:   # l'état partagé est protégé par gLock (withState).
    if not haveWin.load():
      {.cast(gcsafe).}: gWin = ev.window
      haveWin.store(true)
    if ev.current != ev.id: return
    case ev.kind
    of evWindowOpen:
      applyView()
      let uid = editorActiveUid(edId)
      if uid >= 0: lintDoc(uid)
      updateTitle()
    of evSelection:
      if ev.id == mnu: onMenu(ev.text)
      elif ev.id == edId: onEditorSignal(ev.text)
      elif ev.id == trProj:
        let r = root()
        let parts = ev.text.split(TreeSep)
        if r.len > 0 and parts.len > 1:
          let p = r / parts[1 .. ^1].join($DirSep)
          if fileExists(p):
            discard openFile(p)
            lintDoc(editorActiveUid(edId))
            updateTitle()
      elif ev.id == lstOutline:
        var s: Symbol
        var ok = false
        withState:
          if ev.index >= 1 and ev.index <= st.outline.len:
            s = st.outline[ev.index - 1]
            ok = true
        if ok:
          editorGoto(edId, editorActiveUid(edId), s.line, 0)
          editorFlush(edId)
      elif ev.id == lstStack:
        var info: PauseInfo
        withState: info = st.pause
        let i = ev.index - 1
        if i >= 0 and i < info.frames.len:
          showPause(info, i)
          gotoFile(info.frames[i].source, info.frames[i].line - 1, 0)
      elif ev.id == trApi:
        let (ok, e) = apiEntryForPath(ev.text)
        if ok:
          edApiDoc.value = e.signature & "\n\n" & e.doc & "\n\n— paquet « " & e.section & " »" &
            (if e.section in ["base", "string", "table", "math", "coroutine", "utf8", "io", "os"]: ""
             else: "  (local " & e.section & " = require \"" & e.section & "\")") &
            "\n\nDouble-clic : insérer l'appel."
      elif ev.id == tblProb:
        var row: ProblemRow
        var ok = false
        withState:
          if ev.index >= 1 and ev.index <= st.rows.len:
            row = st.rows[ev.index - 1]
            ok = true
        if ok:
          if row.uid > 0:
            editorGoto(edId, row.uid, row.line, row.col)
            editorFlush(edId)
          else: gotoFile(row.path, row.line, 0)
    of evDoubleClick:
      if ev.id == trApi:
        let (ok, e) = apiEntryForPath(trApi.value)
        if ok:
          editorInsert(edId, callTemplate(e))
          editorFlush(edId)
    of evChange:
      if ev.id == edId:
        updateTitle()
        scheduleLint()
    of evKeyDown:
      if ev.id == edIn and int(ev.key) in [KReturn, KKpEnter]: sendInput()
    of evClick:
      if ev.id == btnOpen: onMenu("Fichier" & TreeSep & "Ouvrir un projet…")
      elif ev.id == btnNew: newFileInProject()
      elif ev.id == btnSave: discard save(editorActiveUid(edId))
      elif ev.id == btnCheck: onMenu("Exécuter" & TreeSep & "Vérifier les fichiers ouverts")
      elif ev.id == btnRun: runProgramFrom(false, false)
      elif ev.id == btnDebug: runProgramFrom(true, false)
      elif ev.id == btnCont: resume(smRun)
      elif ev.id == btnStepIn: doStep(smInto)
      elif ev.id == btnStepOver: doStep(smOver)
      elif ev.id == btnStepOut: doStep(smOut)
      elif ev.id == btnPause: pauseProgram()
      elif ev.id == btnStop: doStop()
      elif ev.id == btnSend: sendInput()
      elif ev.id == btnCopy: consoleCopy()
      elif ev.id == btnClear: consoleClear()
    of evWindowClose:
      doStop()
      saveSettings(opts())
    else: discard

#
# Interface
#

proc toolButton[T](bar: T, caption, tip: string): ControlId =
  result = bar.addChild(newButton(caption)).id
  result.tooltip = tip

proc buildUi() =
  initLangDocs()
  let s = loadSettings()
  withState:
    st.settings = s
    st.diagByUid = initTable[int, tuple[title, path: string, diags: seq[Diagnostic]]]()
    st.index = initProjectIndex()
  {.cast(gcsafe).}: inQueue = initDeque[string]()
  var startDir = ""
  var startFile = ""
  if paramCount() >= 1:
    let a = absolutePath(paramStr(1))
    if dirExists(a): startDir = a
    elif fileExists(a):
      startDir = a.parentDir
      startFile = a
  elif s.lastProject.len > 0 and dirExists(s.lastProject):
    startDir = s.lastProject

  win = newWindow(AppName & " — Lua", 1320, 860, handler, layout = lkBorder, theme = themeFor(s.dark))

  let top = win.addChild(newSupercontrol(lkVertical))
  top.dock = dkTop
  mnu = top.addChild(newMenuBar()).id
  buildMenu(mnu)
  let bar = top.addChild(newSupercontrol(lkHorizontal))
  btnOpen = bar.toolButton("Ouvrir", "Ouvrir un projet")
  btnNew = bar.toolButton("Nouveau", "Nouveau fichier")
  btnSave = bar.toolButton("Enregistrer", "Ctrl+S")
  btnCheck = bar.toolButton("Vérifier", "Analyser les fichiers ouverts")
  btnRun = bar.toolButton("▶ Exécuter", "Ctrl+R : exécution directe")
  btnDebug = bar.toolButton("Déboguer", "F5 : exécution jusqu'au prochain point d'arrêt")
  btnCont = bar.toolButton("Continuer", "F5 (en pause)")
  btnStepIn = bar.toolButton("Pas à pas", "F11 : entrer dans les fonctions")
  btnStepOver = bar.toolButton("Pas principal", "F10 : passer par-dessus les appels")
  btnStepOut = bar.toolButton("Sortir", "Maj+F11 : terminer la fonction en cours")
  btnPause = bar.toolButton("Pause", "Interrompre à la prochaine instruction")
  btnStop = bar.toolButton("■ Arrêter", "Maj+F5")
  let spacer = bar.addChild(newLabel(""))
  spacer.weight = 1

  let sb = win.addChild(newSupercontrol(lkHorizontal))
  sb.dock = dkBottom
  let ls = sb.addChild(newLabel("Prêt"))
  ls.weight = 1
  lblStatus = ls.id
  let lp = sb.addChild(newLabel("Ln 1, Col 1"))
  lp.fixedWidth = 140
  lblPos = lp.id

  let split = win.addChild(newSplitter(vertical = true, position = 0.22))
  split.dock = dkCenter

  let left = split.addChild(newTab())
  tabLeft = left.id
  let pgProj = left.addPage("Projet", lkVertical)
  let tp = pgProj.addChild(newTreeView())
  tp.weight = 1
  trProj = tp.id
  let pgOut = left.addPage("Structure", lkVertical)
  let lo = pgOut.addChild(newListBox())
  lo.weight = 1
  lstOutline = lo.id
  let pgApi = left.addPage("Paquets", lkVertical)
  let ta = pgApi.addChild(newTreeView())
  ta.weight = 2
  trApi = ta.id
  let ad = pgApi.addChild(newMultilineEdit(""))
  ad.weight = 1
  edApiDoc = ad.id
  edApiDoc.state = csReadOnly

  let right = split.addChild(newSplitter(vertical = false, position = 0.70))
  let ed = right.addChild(newLuaEditor())
  ed.weight = 1
  edId = ed.id

  let bottom = right.addChild(newTab())
  tabBottom = bottom.id
  let pgProb = bottom.addPage("Problèmes", lkVertical)
  let tb = pgProb.addChild(newTable(multiSelection = false))
  tb.weight = 1
  tblProb = tb.id
  tableAddColumn(tblProb, "Type", 110)
  tableAddColumn(tblProb, "Fichier", 140)
  tableAddColumn(tblProb, "Ligne", 60, alRight)
  tableAddColumn(tblProb, "Col", 50, alRight)
  tableAddColumn(tblProb, "Message", 700)

  let pgCon = bottom.addPage("Console", lkBorder)
  let conHead = pgCon.addChild(newSupercontrol(lkHorizontal))
  conHead.dock = dkTop
  btnCopy = conHead.toolButton("Copier", "Copier tout le contenu de la console")
  btnClear = conHead.toolButton("Effacer", "Vider la console")
  let conSpacer = conHead.addChild(newLabel(""))
  conSpacer.weight = 1
  let inRow = pgCon.addChild(newSupercontrol(lkHorizontal))
  inRow.dock = dkBottom
  let ei = inRow.addChild(newEdit(placeholder = "Saisie pour io.read (Entrée pour envoyer)"))
  ei.weight = 1
  edIn = ei.id
  btnSend = inRow.toolButton("Envoyer", "Envoie la ligne au programme")
  # zone de texte multiligne : défilement, sélection et Cmd/Ctrl+C natifs (comme wdnim)
  let eo = pgCon.addChild(newEdit("", multiline = true,
                                  placeholder = "Sortie du programme (print, io.write, erreurs)"))
  eo.dock = dkCenter
  edOut = eo.id

  let pgVars = bottom.addPage("Variables", lkVertical)
  let tv = pgVars.addChild(newTable(multiSelection = false))
  tv.weight = 1
  tblVars = tv.id
  tableAddColumn(tblVars, "Nom", 160)
  tableAddColumn(tblVars, "Valeur", 520)
  tableAddColumn(tblVars, "Type", 90)
  tableAddColumn(tblVars, "Portée", 90)

  let pgStack = bottom.addPage("Pile d'appels", lkVertical)
  let lsk = pgStack.addChild(newListBox())
  lsk.weight = 1
  lstStack = lsk.id

  editorSetOptions(edId, s.minimap, s.dark)
  fillApiTree()
  setRunButtons(false, false)
  if startDir.len > 0: openProject(startDir)
  if startFile.len > 0:
    try: discard editorOpen(edId, startFile, readFile(startFile))
    except IOError, OSError: discard

when isMainModule:
  buildUi()
  runApplication()
