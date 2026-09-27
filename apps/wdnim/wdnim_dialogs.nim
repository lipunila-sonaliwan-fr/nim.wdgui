# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
# wdnim dialog boxes: project information and run configuration.
# Like the wdgui dialogs, they are modal windows that block the calling handler thread.
import std/[os, strutils]
import ../../src/wdgui
import project, runner

proc modalWindow(title: string, w, h: int, handler: DispatchProc): Window =
  # Must be called inside `guarded` so the UI loop sees a complete modal window.
  let owner = activeWindow
  let theme = if owner != nil: owner.theme else: themeNative()
  result = newWindow(title, w, h, handler, theme, lkBorder)
  result.resizable = false
  result.isModal = true
  result.modalFor = owner
  result.alwaysThreaded = true

proc waitClosed(win: Window) =
  while true:
    var done = false
    guarded: done = win.closed or win.closeRequested
    if done: break
    sleep(20)

# project information

var infoClose: ControlId

proc infoHandler(ev: var Event) {.nimcall, gcsafe.} =
  if ev.current != ev.id: return
  if ev.kind == evClick and ev.id == infoClose: closeWindow(ev.window)

proc showProjectInfo*(root: string, entries: seq[ProjectEntry]) =
  # Project name, folder, nimble metadata, statistics and git state, in a read-only Grid.
  let nimble = nimbleInfo(root)
  let git = gitInfo(root)
  let stats = projectStats(entries, root)
  var rows: seq[tuple[k, v: string]]
  rows.add(("Project", extractFilename(root)))
  rows.add(("Folder", root))
  rows.add(("Nimble file", (if nimble.file.len > 0: extractFilename(nimble.file) else: "(none)")))
  for (k, v) in nimble.fields: rows.add((capitalizeAscii(k), v))
  if nimble.requires.len > 0: rows.add(("Requires", nimble.requires.join(", ")))
  rows.add(("Nim files", $stats.nimFiles))
  rows.add(("Lines", $stats.lines & "  (" & $stats.codeLines & " code, " & $stats.commentLines & " comments)"))
  rows.add(("Size", formatSize(stats.bytes)))
  var folders, files = 0
  for e in entries:
    if e.isDir: inc folders else: inc files
  rows.add(("Tree", $folders & " folders, " & $files & " files"))
  if git.isRepo:
    rows.add(("Git branch", git.branch))
    rows.add(("Last commit", git.lastCommit))
    rows.add(("Remote", (if git.remote.len > 0: git.remote else: "(none)")))
    rows.add(("Changed files", $git.changes))
  else:
    rows.add(("Git", "not a git repository"))
  var win: Window
  guarded:
    win = modalWindow("Project information", 640, 500, infoHandler)
    let title = win.addChild(newLabel(extractFilename(root)))
    title.dock = dkTop
    title.style.text = some(win.theme.accent)
    let bottom = win.addChild(newSupercontrol(lkHorizontal))
    bottom.dock = dkBottom
    let sp = bottom.addChild(newLabel(""))
    sp.weight = 1
    let close = bottom.addChild(newButton("Close", isDefault = true, isCancel = true))
    infoClose = close.id
    let g = win.addChild(newGrid())
    g.dock = dkCenter
    discard g.addColumn("property", "Property", gcText, 150)
    discard g.addColumn("value", "Value", gcText, 440)
    g.striped = true
    for r in rows: discard g.addLine([r.k, r.v])
    win.focusedControl = close
    close.focus = true
  waitClosed(win)

# run configuration

var
  rcMode, rcMain, rcBackend, rcThreads, rcArc, rcTtf, rcHints, rcClear: ControlId
  rcFlags, rcArgs, rcCustom, rcPreview, rcCancel, rcSave, rcSaveRun: ControlId
  rcResult: int
  rcFiles: seq[string]
  rcConfig: RunConfig

const backends = ["c", "cpp", "js", "objc"]

proc readForm(): RunConfig =
  {.cast(gcsafe).}:
    result.mode = RunMode(max(0, listSelect(rcMode) - 1))
    let m = listSelect(rcMain)
    result.mainFile = if m >= 2 and m - 2 < rcFiles.len: rcFiles[m - 2] else: ""
    result.backend = backends[max(0, listSelect(rcBackend) - 1)]
    result.threads = rcThreads.value == "1"
    result.atomicArc = rcArc.value == "1"
    result.sdlttf = rcTtf.value == "1"
    result.hintsOff = rcHints.value == "1"
    result.clearConsole = rcClear.value == "1"
    result.extraFlags = rcFlags.value
    result.args = rcArgs.value
    result.customCommand = rcCustom.value

proc updatePreview() =
  let cfg = readForm()
  let file = if cfg.mainFile.len > 0: cfg.mainFile else: "<current file>"
  rcPreview.caption = "$ " & commandFor(cfg, cfg.mode, file)
  let custom = cfg.mode == rmCustom
  rcCustom.state = (if custom: csActive else: csGrayed)

proc runConfigHandler(ev: var Event) {.nimcall, gcsafe.} =
  if ev.current != ev.id: return
  {.cast(gcsafe).}:
    case ev.kind
    of evChange, evSelection:
      updatePreview()
    of evClick:
      if ev.id == rcSave or ev.id == rcSaveRun:
        rcConfig = readForm()
        rcResult = (if ev.id == rcSave: 1 else: 2)
        closeWindow(ev.window)
      elif ev.id == rcCancel:
        rcResult = 0
        closeWindow(ev.window)
    of evWindowClose: rcResult = 0
    else: discard

proc showRunConfig*(cfg: var RunConfig, files: seq[string]): int =
  # Edits `cfg`; returns 0 (cancelled), 1 (saved) or 2 (saved, run now).
  let c0 = cfg
  var win: Window
  guarded:
    rcFiles = files
    rcResult = 0
    win = modalWindow("Run configuration", 680, 520, runConfigHandler)
    # buttons.
    let bottom = win.addChild(newSupercontrol(lkHorizontal))
    bottom.dock = dkBottom
    let sp = bottom.addChild(newLabel(""))
    sp.weight = 1
    let cancel = newButton("Cancel", isCancel = true)
    let save = newButton("Save")
    let saveRun = newButton("Save & Run", isDefault = true)
    for b in [cancel, save, saveRun]: discard bottom.addChild(b)
    rcCancel = cancel.id
    rcSave = save.id
    rcSaveRun = saveRun.id
    # command preview.
    let cell = win.addChild(newCell(lkVertical, "Command line"))
    cell.dock = dkBottom
    let pv = cell.addChild(newLabel(""))
    pv.style.text = some(win.theme.accent)
    rcPreview = pv.id
    # form.
    let g = win.addChild(newContainer(lkGrid, 0, -1, 2))
    g.dock = dkCenter
    var modes: seq[string]
    for m in RunMode: modes.add $m
    discard g.addChild(newLabel("Mode"))
    rcMode = g.addChild(newComboBox(modes, ord(c0.mode))).id
    discard g.addChild(newLabel("Main file"))
    var mains = @["(current file)"]
    for f in files: mains.add f
    var sel = files.find(c0.mainFile) + 1
    rcMain = g.addChild(newComboBox(mains, max(0, sel))).id
    discard g.addChild(newLabel("Backend"))
    rcBackend = g.addChild(newComboBox(backends, max(0, backends.find(c0.backend)))).id
    discard g.addChild(newLabel("Options"))
    let opts = g.addChild(newSupercontrol(lkFlow))
    rcThreads = opts.addChild(newCheckBox("--threads:on", c0.threads)).id
    rcArc = opts.addChild(newCheckBox("--mm:atomicArc", c0.atomicArc)).id
    rcTtf = opts.addChild(newCheckBox("-d:sdlttf", c0.sdlttf)).id
    rcHints = opts.addChild(newCheckBox("--hints:off", c0.hintsOff)).id
    discard g.addChild(newLabel("Extra flags"))
    rcFlags = g.addChild(newEdit(c0.extraFlags, placeholder = "-d:release --opt:speed …")).id
    discard g.addChild(newLabel("Program arguments"))
    rcArgs = g.addChild(newEdit(c0.args, placeholder = "arguments passed to the program")).id
    discard g.addChild(newLabel("Custom command"))
    rcCustom = g.addChild(newEdit(c0.customCommand, placeholder = "e.g. nimble docs")).id
    discard g.addChild(newLabel("Console"))
    rcClear = g.addChild(newCheckBox("Clear the console before each run", c0.clearConsole)).id
    win.focusedControl = saveRun
    saveRun.focus = true
  updatePreview()
  waitClosed(win)
  var r = 0
  guarded:
    r = rcResult
    if r > 0: cfg = rcConfig
  r
