# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
# wdnim - a Nim editor built with wdgui (example application).
#                _         _
#   __      ____| |_ _ __ (_)_ __ ___
#   \ \ /\ / / _` (_) '_ \| | '_ ` _ \
#    \ V  V / (_| |_| | | | | | | | | |
#     \_/\_/ \__,_(_)_| |_|_|_| |_| |_|
#
#   nim c -r --threads:on --mm:atomicArc -d:sdlttf apps/wdnim/wdnim.nim [project folder or file]
#
# Layout: menu bar, toolbar, file tree | tabbed code editor (line numbers, jGRASP-like
# control structure diagram, syntax highlighting, minimap), launch console, status bar.
import std/[os, strutils, sets, tables, times, algorithm]
import ../../src/wdgui
import editor, project, runner, wdnim_dialogs, lsp, designer

when defined(macosx):
  const modName = "Cmd"
else:
  const modName = "Ctrl"

const
  SDLK_B = 0x62'u32
  SDLK_F = 0x66'u32
  SDLK_G = 0x67'u32
  SDLK_N = 0x6E'u32
  SDLK_O = 0x6F'u32
  SDLK_Q = 0x71'u32
  SDLK_S = 0x73'u32
  SDLK_W = 0x77'u32
  SDLK_F1 = 0x4000003A'u32
  SDLK_F3 = 0x4000003C'u32
  SDLK_F5 = 0x4000003E'u32
  SDLK_F6 = 0x4000003F'u32
  SDLK_F7 = 0x40000040'u32
  SDLK_F9 = 0x40000042'u32
  SDLK_I = 0x69'u32
  SDLK_F8 = 0x40000041'u32
  SDLK_F12 = 0x40000045'u32

var
  gMain, gMenu, gEditor, gTree, gProjectLabel, gConsole, gConsoleBox, gConsoleCmd: ControlId
  gStatusFile, gStatusPos, gStatusLines, gStatusGit, gStatusRun, gSplitter: ControlId
  gStatusLsp, gProblems, gBottomTabs: ControlId
  problemList: seq[tuple[path: string, d: Diagnostic]]
  completionBusy: bool
  projectRoot: string
  projectEntries: seq[ProjectEntry]
  projectDirs: HashSet[string]
  runConfig = defaultRunConfig()
  lastFind: FindRequest
  darkMode = true
  toolCommands: seq[tuple[id: ControlId, cmd: string]]
  menuCommands: Table[string, string]
  logoIcon: IconId

# theme

proc wdnimTheme(dark: bool): Theme =
  # macOS-like look on every platform, Nim-gold accent.
  result = themeMacOS(dark)
  result.name = if dark: "wdnim dark" else: "wdnim light"
  result.accent = hex"#FFC200"
  result.accentHover = hex"#FFD24D"
  result.textOnAccent = hex"#1E1F22"
  result.focus = hex"#FFC20080"
  if dark:
    result.windowBg = hex"#2B2D30"
    result.surface = hex"#393B40"
    result.surfaceHover = hex"#43454A"
    result.surfacePressed = hex"#4E5157"
    result.fieldBg = hex"#1E1F22"
    result.border = hex"#1E1F22"
    result.text = hex"#DFE1E5"
    result.textSecondary = hex"#8C8F96"
    result.header = hex"#2B2D30"
    result.selection = hex"#2E436E"
    result.textSelection = hex"#FFFFFF"
  else:
    result.windowBg = hex"#F2F3F5"
    result.header = hex"#EBECF0"
    result.selection = hex"#D4E2FF"
    result.textSelection = hex"#1B1B1B"
    result.textOnAccent = hex"#1B1B1B"

# small helpers

proc root(): string =
  guarded: result = projectRoot

proc say(s: string) = gStatusRun.caption = s

proc relToRoot(path: string): string =
  let r = root()
  if r.len > 0 and path.startsWith(r):
    path[r.len .. ^1].strip(trailing = false, chars = {'/', '\\'})
  else: path

proc appendConsole(line: string) {.nimcall, gcsafe.} =
  withControl(gConsole, Edit, e):
    var t = e.text & line & "\n"
    if t.len > 400_000: t = t[t.len - 300_000 .. ^1]
    e.setValueText(t)            # keeps the end visible.

proc showConsole(visible = true, page = 1) =
  gConsoleBox.visible = visible
  if visible: gBottomTabs.value = $page

# language server (nimlangserver)

proc refreshStatus()

proc lspStatusCaption(): string =
  let st = lspState()
  if st != srvReady: return "LSP " & $st
  var errors, warnings = 0
  for p in lspAllDiagnostics():
    if p.d.severity == 1: inc errors
    elif p.d.severity == 2: inc warnings
  result = "LSP ready"
  if errors > 0: result.add " · " & $errors & (if errors == 1: " error" else: " errors")
  if warnings > 0: result.add " · " & $warnings & (if warnings == 1: " warning" else: " warnings")

proc refreshProblems() =
  # Problems page: every diagnostic of every open file, errors first.
  var diags = lspAllDiagnostics()
  proc before(a, b: tuple[path: string, d: Diagnostic]): bool =
    # errors first, then by file and line
    if a.d.severity != b.d.severity: return a.d.severity < b.d.severity
    if a.path != b.path: return a.path < b.path
    a.d.line < b.d.line
  for i in 1 ..< diags.len:                     # insertion sort (small lists)
    let x = diags[i]
    var j = i - 1
    while j >= 0 and before(x, diags[j]):
      diags[j + 1] = diags[j]
      dec j
    diags[j + 1] = x
  guarded: problemList = diags
  gridDeleteAll(gProblems)
  for p in diags:
    discard gridAddLine(gProblems, severityName(p.d.severity), relToRoot(p.path),
                        $(p.d.line + 1), $(p.d.col + 1), p.d.message.replace("\n", " "))
  gStatusLsp.caption = lspStatusCaption()

proc lspText(path: string): tuple[found: bool, text: string] {.nimcall, gcsafe.} =
  {.cast(gcsafe).}:
    result = editorTextOf(gEditor, path)

proc lspDiagnosticsChanged(path: string) {.nimcall, gcsafe.} =
  {.cast(gcsafe).}:
    editorSetDiagnostics(gEditor, path, lspDiagnostics(path))
    refreshProblems()

proc openAllInLsp() =
  let n = editorInfo(gEditor).tabs
  for i in 1 .. n:
    let d = editorDocument(gEditor, i)
    if d.path.len > 0:
      let t = editorTextOf(gEditor, d.path)
      if t.found: lspOpen(d.path, t.text)

proc startLanguageServer() =
  gStatusLsp.caption = "LSP starting…"
  lspSetCallbacks(lspText, lspDiagnosticsChanged)
  if lspStart(root()):
    openAllInLsp()
  gStatusLsp.caption = lspStatusCaption()
  let msg = lspLastMessage()
  if msg.len > 0: say(msg)

proc completionRequest() =
  var busy = false
  guarded:
    busy = completionBusy
    completionBusy = true
  if busy: return
  try:
    let pos = editorCursorPos(gEditor)
    if pos.path.len == 0 or lspState() != srvReady: return
    let t = editorTextOf(gEditor, pos.path)
    if not t.found: return
    let items = lspCompletion(pos.path, t.text, pos.line, pos.col)
    let now = editorCursorPos(gEditor)
    if items.len > 0 and now.line == pos.line and now.path == pos.path:
      editorShowCompletion(gEditor, items)
  finally:
    guarded: completionBusy = false

proc infoRequest(signature: bool) =
  let pos = editorCursorPos(gEditor)
  if pos.path.len == 0 or lspState() != srvReady: return
  let t = editorTextOf(gEditor, pos.path)
  if not t.found: return
  let text = if signature: lspSignature(pos.path, t.text, pos.line, pos.col)
             else: lspHover(pos.path, t.text, pos.line, pos.col)
  if text.len > 0: editorShowInfo(gEditor, text)
  elif not signature: say("No information at the cursor")

proc gotoDefinition() =
  let pos = editorCursorPos(gEditor)
  if pos.path.len == 0: return
  if lspState() != srvReady:
    say("The language server is " & $lspState())
    return
  let t = editorTextOf(gEditor, pos.path)
  let loc = lspDefinition(pos.path, t.text, pos.line, pos.col)
  if loc.path.len == 0:
    say("No definition found")
    return
  if editorOpenFile(gEditor, loc.path):
    let t2 = editorTextOf(gEditor, loc.path)
    if t2.found: lspOpen(loc.path, t2.text)
    editorGotoLine(gEditor, loc.line + 1, loc.col + 1)
    setFocus(gEditor)
    refreshStatus()

proc jumpToProblem(row: int) =
  var p: tuple[path: string, d: Diagnostic]
  var ok = false
  guarded:
    if row >= 1 and row <= problemList.len:
      p = problemList[row - 1]
      ok = true
  if not ok: return
  if editorOpenFile(gEditor, p.path):
    editorGotoLine(gEditor, p.d.line + 1, p.d.col + 1)
    setFocus(gEditor)
    refreshStatus()

proc refreshStatus() =
  let info = editorInfo(gEditor)
  if not info.hasDoc:
    gStatusFile.caption = "No file"
    gStatusPos.caption = ""
    gStatusLines.caption = ""
    gMain.caption = "wdnim - " & extractFilename(root())
    return
  let name = if info.path.len > 0: relToRoot(info.path) else: info.title
  gStatusFile.caption = (if info.modified: "* " else: "") & name
  gStatusPos.caption = "Ln " & $info.line & ", Col " & $info.col &
                       (if info.selected > 0: "  (" & $info.selected & " selected)" else: "")
  gStatusLines.caption = $info.lines & " lines · UTF-8 · LF · Nim"
  gMain.caption = "wdnim - " & info.title & (if info.modified: " *" else: "") & " - " & extractFilename(root())

proc refreshGit() =
  let g = gitInfo(root())
  gStatusGit.caption = if not g.isRepo: "no git"
                       elif g.changes > 0: "git " & g.branch & "  +" & $g.changes
                       else: "git " & g.branch

proc loadProject(dir: string, restartLsp = true) =
  let full = normalizedPath(absolutePath(dir))
  let entries = scanProject(full)
  var dirs = initHashSet[string]()
  for e in entries:
    if e.isDir: dirs.incl e.rel
  guarded:
    projectRoot = full
    projectEntries = entries
    projectDirs = dirs
    if runConfig.mainFile.len == 0 or not fileExists(full / runConfig.mainFile):
      runConfig.mainFile = guessMainFile(full, entries)
  treeDeleteAll(gTree)
  for e in entries: treeAdd(gTree, e.rel.replace("/", TreeSep))
  gProjectLabel.caption = extractFilename(full).toUpperAscii
  refreshGit()
  refreshStatus()
  if restartLsp and lspState() in {srvReady, srvStarting, srvFailed}: startLanguageServer()   # new project root.

proc onFormFileCreated(path: string) {.nimcall, gcsafe.} =
  # The designer created form_<name>.nim: show it in the project tree.
  {.cast(gcsafe).}:
    loadProject(root(), restartLsp = false)

# file commands

proc openPdfWindow(path: string) =
  # PDF files open in their own window with the wdgui PDF viewer / editor.
  var dark: bool
  guarded: dark = darkMode
  var pid: ControlId
  guarded:
    let w = newWindow("PDF - " & extractFilename(path), 1120, 840, nil, wdnimTheme(dark), lkBorder)
    w.root.margin = 0
    w.root.spacing = 0
    let v = w.addChild(newPdfViewer())
    v.dock = dkCenter
    pid = v.id
  if not pdfAvailable():
    alert(iconExclamation, pdfError(), "PDF")
  elif path.len > 0 and not pdfOpen(pid, path):
    alert(iconStop, "Cannot open \"" & path & "\".", "PDF")

proc openPath(path: string) =
  if path.toLowerAscii.endsWith(".pdf"):
    openPdfWindow(path)
    return
  if editorOpenFile(gEditor, path):
    let full = normalizedPath(absolutePath(path))
    let t = editorTextOf(gEditor, full)
    if t.found: lspOpen(full, t.text)
    setFocus(gEditor)
    refreshStatus()
  else:
    alert(iconStop, "Cannot open \"" & path & "\".")

proc saveCurrent(saveAs = false): bool =
  let d = editorDocument(gEditor, 0)
  if d.title.len == 0: return false
  var r = if saveAs: (ok: false, path: "") else: editorSave(gEditor)
  if not r.ok and r.path.len > 0:
    alert(iconStop, "Cannot write \"" & r.path & "\".")
    return false
  if not r.ok:
    let folder = if d.path.len > 0: d.path.parentDir else: root()
    let p = saveFileDialog(folder = folder, defaultName = d.title,
                           filter = "Nim files|*.nim\nNimScript|*.nims\nNimble|*.nimble\nAll files|*")
    if p.len == 0: return false
    r = editorSave(gEditor, 0, p)
    if not r.ok:
      alert(iconStop, "Cannot write \"" & p & "\".")
      return false
    if r.path.startsWith(root()): loadProject(root())             # new file in the tree.
  say("Saved " & relToRoot(r.path))
  let t = editorTextOf(gEditor, r.path)
  if t.found:
    lspOpen(r.path, t.text)                                       # a new file becomes known to the server.
    lspSave(r.path, t.text)
  refreshStatus()
  refreshGit()
  true

proc saveAll(askForUntitled: bool) =
  let n = editorInfo(gEditor).tabs
  for i in 1 .. n:
    let d = editorDocument(gEditor, i)
    if not d.modified: continue
    if d.path.len > 0:
      if editorSave(gEditor, i).ok:
        let t = editorTextOf(gEditor, d.path)
        if t.found: lspSave(d.path, t.text)
    elif askForUntitled:
      editorSelectTab(gEditor, i)
      discard saveCurrent()
  refreshStatus()
  refreshGit()

proc closeTab(index: int) =
  let d = editorDocument(gEditor, index)
  if d.modified and confirm(iconExclamation, "\"" & d.title & "\" has unsaved changes.\nClose it anyway?",
                            "Close") != drOk:
    return
  editorClose(gEditor, index)
  if d.path.len > 0:
    lspClose(d.path)
    refreshProblems()
  refreshStatus()

proc quitCommand() =
  let n = editorInfo(gEditor).tabs
  var unsaved: seq[string]
  for i in 1 .. n:
    let d = editorDocument(gEditor, i)
    if d.modified: unsaved.add d.title
  if unsaved.len > 0 and confirm(iconExclamation, "Unsaved changes in:\n" & unsaved.join(", ") &
                                 "\n\nQuit anyway?", "Quit wdnim") != drOk:
    return
  lspStop()
  quitApplication()

# edit / search commands

proc findCommand(replace: bool) =
  var req: FindRequest
  guarded: req = lastFind
  let sel = editorInfo(gEditor)
  if not sel.hasDoc: return
  while findDialog(req, replace = replace) == drOk:
    guarded: lastFind = req
    let n = editorFind(gEditor, req)
    case req.action
    of faReplaceAll:
      say($n & " replacement(s)")
      break
    of faReplace: say(if n > 0: "Replaced" else: "No selected match to replace")
    else: say(if n > 0: "Found \"" & req.findText & "\"" else: "\"" & req.findText & "\" not found")
  refreshStatus()

proc findNextCommand() =
  var req: FindRequest
  guarded: req = lastFind
  if req.findText.len == 0:
    findCommand(false)
    return
  req.action = faFindNext
  say(if editorFind(gEditor, req) > 0: "Found \"" & req.findText & "\"" else: "\"" & req.findText & "\" not found")

proc gotoCommand() =
  let info = editorInfo(gEditor)
  if not info.hasDoc: return
  let s = prompt(iconQuestion, "Go to line (1 - " & $info.lines & "):", $info.line, "Go to Line")
  try: editorGotoLine(gEditor, parseInt(s.strip))
  except ValueError: discard

# run commands

proc runMode(mode: RunMode) =
  if isRunning():
    say("A process is already running")
    return
  saveAll(false)
  var cfg: RunConfig
  guarded: cfg = runConfig
  var file = ""
  if mode notin {rmTest, rmCustom}:
    let info = editorInfo(gEditor)
    if cfg.mainFile.len > 0: file = root() / cfg.mainFile
    elif info.path.endsWith(".nim"): file = info.path
    if file.len == 0:
      alert(iconExclamation, "No Nim file to " & toLowerAscii($mode) &
            ".\nOpen a .nim file or choose a main file in Run > Run Configuration.", "Run")
      return
  let cmd = commandFor(cfg, mode, file)
  showConsole(true)
  if cfg.clearConsole: gConsole.value = ""
  gConsoleCmd.caption = cmd
  appendConsole("$ " & cmd)
  say($mode & "…")
  let t0 = epochTime()
  let code = runCommand(cmd, root(), appendConsole)
  let dt = epochTime() - t0
  appendConsole("- exit code " & $code & " in " & formatFloat(dt, ffDecimal, 2) & " s")
  say(if code == 0: $mode & ": success" else: $mode & ": failed (exit code " & $code & ")")

proc jumpFromConsole() =
  # Double-click on "file.nim(line, col) Error: …" in the console opens the location.
  let text = gConsole.value
  let sel = editSelection(gConsole)
  var a = min(sel.start, text.len)
  while a > 0 and text[a - 1] != '\n': dec a
  var b = min(sel.start, text.len)
  while b < text.len and text[b] != '\n': inc b
  let loc = parseLocation(text[a ..< b], root())
  if loc.path.len > 0 and fileExists(loc.path):
    openPath(loc.path)
    editorGotoLine(gEditor, loc.line, loc.col)

# command dispatcher

proc command(cmd: string) =
  case cmd
  of "new":
    discard editorNewDocument(gEditor)
    setFocus(gEditor)
    refreshStatus()
  of "open":
    let p = openFileDialog(folder = root(), filter = "Nim files|*.nim;*.nims;*.nimble\nAll files|*")
    if p.len > 0: openPath(p)
  of "openFolder":
    let d = prompt(iconQuestion, "Project folder:", root(), "Open Folder")
    if d != root():
      if dirExists(d): loadProject(d)
      else: alert(iconStop, "\"" & d & "\" is not a folder.")
  of "save": discard saveCurrent()
  of "saveAs": discard saveCurrent(saveAs = true)
  of "saveAll": saveAll(true)
  of "close": closeTab(0)
  of "quit": quitCommand()
  of "undo", "redo", "cut", "copy", "paste", "selectAll", "toggleComment", "duplicate", "indent", "dedent":
    editorCommand(gEditor, cmd)
  of "find": findCommand(false)
  of "replace": findCommand(true)
  of "findNext": findNextCommand()
  of "goto": gotoCommand()
  of "toggleMinimap", "toggleCsd":
    let o = editorOptions(gEditor)
    if cmd == "toggleMinimap": editorSetOptions(gEditor, not o.minimap, o.csd)
    else: editorSetOptions(gEditor, o.minimap, not o.csd)
  of "toggleConsole": showConsole(not gConsoleBox.visible)
  of "toggleTheme":
    var dark: bool
    guarded:
      darkMode = not darkMode
      dark = darkMode
    gMain.theme = wdnimTheme(dark)
  of "refreshTree": loadProject(root())
  of "projectInfo":
    var entries: seq[ProjectEntry]
    guarded: entries = projectEntries
    showProjectInfo(root(), entries)
  of "runConfig":
    var cfg: RunConfig
    var entries: seq[ProjectEntry]
    guarded:
      cfg = runConfig
      entries = projectEntries
    let r = showRunConfig(cfg, nimFiles(entries))
    if r > 0:
      guarded: runConfig = cfg
      if r == 2: runMode(cfg.mode)
  of "runConfigured":
    var m: RunMode
    guarded: m = runConfig.mode
    runMode(m)
  of "run": runMode(rmRun)
  of "build": runMode(rmBuild)
  of "check": runMode(rmCheck)
  of "test": runMode(rmTest)
  of "stop": say(if stopRunning(): "Process stopped" else: "Nothing is running")
  of "clearConsole": gConsole.value = ""
  of "complete": completionRequest()
  of "hover": infoRequest(false)
  of "signature": infoRequest(true)
  of "gotoDef": gotoDefinition()
  of "nextProblem":
    let m = editorNextDiagnostic(gEditor)
    say(if m.len > 0: m.splitLines()[0] else: "No problem in this file")
  of "problems":
    refreshProblems()
    showConsole(true, 2)
  of "lspRestart": startLanguageServer()
  of "lspStatus":
    let path = lspServerPath()
    let st = lspState()
    var msg = "State: " & $st & "\nServer: " & (if path.len > 0: path else: "not found")
    let last = lspLastMessage()
    if last.len > 0: msg.add "\n\n" & last
    if st in {srvMissing, srvFailed}:
      msg.add "\n\nInstall it with:\n    nimble install -g nimlangserver\n" &
              "It needs a nimsuggest that supports --v3 (Nim 1.6 or later)."
    alert((if st == srvReady: iconInformation else: iconExclamation), msg, "Language Server")
  of "designerNew", "designerOpen":
    if designerIsOpen():
      say("The form designer is already open")
      return
    let info = editorInfo(gEditor)
    let code = info.path
    if code.len == 0 or not code.endsWith(".nim") or extractFilename(code).startsWith("form_"):
      alert(iconExclamation, "Open (and save) the Nim file that will use the form first:\n" &
            "the designer adds its event handlers and registrations to that file.", "Form Designer")
      return
    var form = ""
    if cmd == "designerOpen":
      form = openFileDialog("Open Form", root(), "Forms|form_*.nim\nNim files|*.nim")
      if form.len == 0: return
    var dark: bool
    guarded: dark = darkMode
    if openDesigner(root(), code, form, gEditor, wdnimTheme(dark)):
      say("Form designer opened for " & extractFilename(code))
  of "openPdf":
    let p = openFileDialog("Open PDF", root(), "PDF files|*.pdf")
    if p.len > 0: openPdfWindow(p)
  of "newPdf": openPdfWindow("")
  of "about":
    alert(logoIcon, "wdnim 0.1\n\nA Nim editor written by Jean-Marc Quéré\n" &
          "LPCS, Lab'Oratoire (metalab at sonaliwan.fr)\n" &
          "in Nim with the wdgui library :\n" &
          "syntax highlighting, control structure diagram, minimap, " &
          "project tree, git status and launch console.", "About wdnim")
  else: discard

proc shortcut(key: uint32, mods: uint16): string =
  let cmd = (mods and KMOD_CMD) != 0
  let shift = (mods and KMOD_SHIFT) != 0
  let alt = (mods and KMOD_ALT) != 0
  result = ""
  case key
  of SDLK_F1: result = "projectInfo"
  of SDLK_F3: result = "findNext"
  of SDLK_F5: result = (if shift: "stop" else: "run")
  of SDLK_F6: result = "build"
  of SDLK_F7: result = "check"
  of SDLK_F9: result = "runConfig"
  of SDLK_F8: result = "nextProblem"
  of SDLK_F12: result = "gotoDef"
  of SDLK_I:
    if cmd: result = "hover"
  of SDLK_N:
    if cmd: result = "new"
  of SDLK_O:
    if cmd: result = (if shift: "openFolder" else: "open")
  of SDLK_S:
    if cmd: result = (if shift: "saveAs" elif alt: "saveAll" else: "save")
  of SDLK_W:
    if cmd: result = "close"
  of SDLK_F:
    if cmd: result = (if alt or shift: "replace" else: "find")
  of SDLK_G:
    if cmd: result = "goto"
  of SDLK_B:
    if cmd: result = "toggleConsole"
  of SDLK_Q:
    if cmd: result = "quit"
  else: discard

# event handler

proc handler(ev: var Event) {.nimcall, gcsafe.} =
  if ev.current != ev.id: return
  {.cast(gcsafe).}:
    case ev.kind
    of evSelection:
      if ev.id == gEditor: refreshStatus()
      elif ev.id == gTree:
        let rel = ev.text.replace(TreeSep, "/")
        var isDir = true
        guarded: isDir = rel in projectDirs
        if not isDir: openPath(root() / rel)
      elif ev.id == gMenu:
        let c = menuCommands.getOrDefault(ev.text)
        if c.len > 0: command(c)
    of evChange:
      if ev.id == gEditor:
        let pos = editorCursorPos(gEditor)
        lspMarkChanged(pos.path)
        refreshStatus()
        if ev.text == "complete": completionRequest()
        elif ev.text == "signature": infoRequest(true)
    of evClick:
      if ev.id == gEditor:
        if ev.text == "close-tab": closeTab(ev.index)
        elif ev.text == "goto-definition": gotoDefinition()
      else:
        for t in toolCommands:
          if t.id == ev.id:
            command(t.cmd)
            break
    of evDoubleClick:
      if ev.id == gConsole: jumpFromConsole()
      elif ev.id == gProblems and ev.index > 0: jumpToProblem(ev.index)
    of evWindowOpen:
      if ev.id == gMain: startLanguageServer()
    of evKeyDown:
      let c = shortcut(ev.key, ev.modifiers)
      if c.len > 0: command(c)
    of evWindowClose:
      if ev.id == gMain: quitCommand()
    else: discard

# user interface

proc buildMenu(win: Window) =
  let m = win.addChild(newMenuBar())
  gMenu = m.id
  let items = [
    ("File", "New File", "new", "N"), ("File", "Open File…", "open", "O"),
    ("File", "Open Folder…", "openFolder", "Shift+O"),
    ("File", "Open PDF…", "openPdf", ""), ("File", "PDF Viewer / Editor", "newPdf", ""), ("File", "-", "", ""),
    ("File", "Save", "save", "S"), ("File", "Save As…", "saveAs", "Shift+S"),
    ("File", "Save All", "saveAll", "Alt+S"), ("File", "-", "", ""),
    ("File", "Close Tab", "close", "W"), ("File", "Quit", "quit", "Q"),
    ("Edit", "Undo", "undo", "Z"), ("Edit", "Redo", "redo", "Y"), ("Edit", "-", "", ""),
    ("Edit", "Cut", "cut", "X"), ("Edit", "Copy", "copy", "C"), ("Edit", "Paste", "paste", "V"),
    ("Edit", "Select All", "selectAll", "A"), ("Edit", "-", "", ""),
    ("Edit", "Find…", "find", "F"), ("Edit", "Find Next", "findNext", "F3"),
    ("Edit", "Replace…", "replace", "Alt+F"), ("Edit", "Go to Line…", "goto", "G"),
    ("Edit", "-", "", ""), ("Edit", "Toggle Comment", "toggleComment", "/"),
    ("Edit", "Duplicate Line", "duplicate", "D"), ("Edit", "Indent", "indent", "Tab"),
    ("Edit", "Outdent", "dedent", "Shift+Tab"), ("Edit", "-", "", ""),
    ("Edit", "Trigger Suggestions", "complete", "Ctrl+Space"), ("Edit", "Show Information", "hover", "I"),
    ("Edit", "Signature Help", "signature", ""),
    ("Edit", "Go to Definition", "gotoDef", "F12"), ("Edit", "Next Problem", "nextProblem", "F8"),
    ("View", "Minimap", "toggleMinimap", ""), ("View", "Structure Diagram", "toggleCsd", ""),
    ("View", "Console", "toggleConsole", "B"), ("View", "Light / Dark Theme", "toggleTheme", ""),
    ("View", "Refresh Project Tree", "refreshTree", ""),
    ("Project", "Project Information…", "projectInfo", "F1"), ("Project", "Open Folder…", "openFolder", ""),
    ("Run", "Run", "run", "F5"), ("Run", "Build", "build", "F6"), ("Run", "Check", "check", "F7"),
    ("Run", "Nimble Test", "test", ""), ("Run", "Run Configured Mode", "runConfigured", ""),
    ("Run", "-", "", ""), ("Run", "Run Configuration…", "runConfig", "F9"),
    ("Run", "Stop", "stop", "Shift+F5"), ("Run", "Clear Console", "clearConsole", ""),
    ("Language", "Problems", "problems", ""), ("Language", "Restart Language Server", "lspRestart", ""),
    ("Language", "Language Server Status…", "lspStatus", ""),
    ("Design", "New Form for the Current File…", "designerNew", ""),
    ("Design", "Open Form…", "designerOpen", ""),
    ("Help", "About wdnim", "about", "")]
  for (menu, label, cmd, key) in items:
    var caption = label
    if key.len > 0:
      let k = if key.startsWith("F") or key in ["Tab", "Shift+Tab", "Shift+F5", "Ctrl+Space"]: key
              else: modName & "+" & key
      caption = label & "    " & k
    menuAdd(m.id, menu & TreeSep & caption)
    if cmd.len > 0: menuCommands[menu & TreeSep & caption] = cmd

proc buildToolbar(win: Window) =
  let tb = win.addChild(newToolbar())
  tb.dock = dkTop
  proc tool(tb: Toolbar, caption, cmd, tip: string) =
    let b = tb.addTool(caption, tip)
    toolCommands.add((b.id, cmd))
  proc gap(tb: Toolbar) =
    let s = tb.addChild(newShape(skVLine))
    s.fixedWidth = 12
    s.stretch = true
  tb.tool("New", "new", "New file (" & modName & "+N)")
  tb.tool("Open", "open", "Open a file (" & modName & "+O)")
  tb.tool("Save", "save", "Save (" & modName & "+S)")
  tb.tool("Save All", "saveAll", "Save all files")
  tb.gap()
  tb.tool("Undo", "undo", "Undo (" & modName & "+Z)")
  tb.tool("Redo", "redo", "Redo (" & modName & "+Y)")
  tb.tool("Find", "find", "Find (" & modName & "+F)")
  tb.tool("Replace", "replace", "Replace (" & modName & "+Alt+F)")
  tb.gap()
  tb.tool("Run", "run", "Run the main file (F5)")
  tb.tool("Build", "build", "Compile only (F6)")
  tb.tool("Check", "check", "nim check (F7)")
  tb.tool("Stop", "stop", "Stop the running process (Shift+F5)")
  tb.tool("Configure…", "runConfig", "Run configuration (F9)")
  tb.gap()
  tb.tool("Console", "toggleConsole", "Show / hide the console (" & modName & "+B)")
  tb.tool("Project", "projectInfo", "Project information (F1)")
  tb.tool("Theme", "toggleTheme", "Light / dark theme")
  tb.gap()
  tb.tool("Designer", "designerNew", "Form designer for the current file")

proc buildStatusBar(win: Window) =
  let bar = win.addChild(newCell(lkHorizontal))
  bar.dock = dkBottom
  bar.margin = 4
  bar.spacing = 18
  bar.style.background = some(win.theme.header)
  bar.style.border = some(win.theme.header)
  bar.style.radius = some(0.0)
  let f = bar.addChild(newLabel("No file"))
  f.weight = 1
  gStatusFile = f.id
  gStatusRun = bar.addChild(newLabel("Ready")).id
  gStatusPos = bar.addChild(newLabel("")).id
  gStatusLines = bar.addChild(newLabel("")).id
  gStatusLsp = bar.addChild(newLabel("LSP off")).id
  let g = bar.addChild(newLabel("no git"))
  g.style.text = some(win.theme.accent)
  gStatusGit = g.id

proc buildConsole(win: Window) =
  let box = win.addChild(newContainer(lkBorder, 4, 4))
  box.dock = dkBottom
  box.fixedHeight = 230
  box.visible = false
  gConsoleBox = box.id
  let tabs = box.addChild(newTab())
  tabs.dock = dkCenter
  gBottomTabs = tabs.id
  let page = tabs.addPage("Console", lkBorder)
  let probs = tabs.addPage("Problems", lkBorder)
  let grid = probs.addChild(newGrid())
  grid.dock = dkCenter
  discard grid.addColumn("severity", "Severity", gcText, 90)
  discard grid.addColumn("file", "File", gcText, 220)
  discard grid.addColumn("line", "Line", gcNumber, 60)
  discard grid.addColumn("col", "Col", gcNumber, 50)
  discard grid.addColumn("message", "Message", gcText, 700)
  grid.formats.add ConditionalFormat(column: 0, op: coEquals, value: "Error", text: hex"#F14C4C", wholeRow: false)
  grid.formats.add ConditionalFormat(column: 0, op: coEquals, value: "Warning", text: hex"#E5A33B", wholeRow: false)
  gProblems = grid.id
  let head = page.addChild(newSupercontrol(lkHorizontal, 6))
  head.dock = dkTop
  let t = head.addChild(newLabel("CONSOLE"))
  t.style.text = some(win.theme.accent)
  let c = head.addChild(newLabel(""))
  c.weight = 1
  c.style.text = some(win.theme.textSecondary)
  gConsoleCmd = c.id
  for (caption, cmd) in [("Run", "run"), ("Stop", "stop"), ("Clear", "clearConsole"), ("Hide", "toggleConsole")]:
    let b = head.addChild(newButton(caption))
    b.flat = true
    toolCommands.add((b.id, cmd))
  let e = page.addChild(newEdit("", multiline = true, placeholder = "Output of Run / Build / Check. " &
                                    "Double-click an error line to open its location."))
  e.dock = dkCenter
  gConsole = e.id

proc main() =
  var target = if paramCount() > 0: paramStr(1) else: getCurrentDir()
  var fileToOpen = ""
  if fileExists(target):
    fileToOpen = target
    target = target.parentDir
  let win = newWindow("wdnim", 1380, 880, handler, wdnimTheme(true), lkBorder)
  win.manualClose = true
  win.root.margin = 0
  win.root.spacing = 0
  gMain = win.id
  designerFileCreated = onFormFileCreated
  logoIcon = loadIcon(currentSourcePath().parentDir / ".." / ".." / "examples" / "logo.bmp")
  buildMenu(win)
  buildToolbar(win)
  buildStatusBar(win)
  buildConsole(win)
  # file tree | editor
  let split = win.addChild(newSplitter(vertical = true, position = 0.2))
  split.dock = dkCenter
  gSplitter = split.id
  let left = split.addChild(newContainer(lkBorder, 6, 4))
  let pl = left.addChild(newLabel("PROJECT"))
  pl.dock = dkTop
  pl.style.text = some(win.theme.textSecondary)
  gProjectLabel = pl.id
  let tree = left.addChild(newTreeView())
  tree.dock = dkCenter
  gTree = tree.id
  let ed = split.addChild(newCodeEditor())
  gEditor = ed.id
  win.focusedControl = ed
  ed.focus = true
  loadProject(target)
  if fileToOpen.len > 0: discard editorOpenFile(gEditor, fileToOpen)
  else:
    guarded:
      let main0 = runConfig.mainFile
      if main0.len > 0: discard editorOpenFile(gEditor, projectRoot / main0)
  refreshStatus()
  runApplication()

main()
