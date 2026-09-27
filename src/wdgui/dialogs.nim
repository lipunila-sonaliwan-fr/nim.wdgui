# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
# Modal dialog boxes. Each one opens in its own dialog window, centered on the active
# window, and captures the focus until it is closed (the other windows ignore input).
#
# They are called like WINDEV's Info / YesNo / Input: the call BLOCKS the calling thread
# until the user closes the box, then returns which button was pressed. Call them from a
# window event handler (which runs on its own thread) or from any thread other than the
# UI thread; the interface keeps running while you wait.
#
# * alert(icon, message)                 → OK
# * confirm(icon, message): DialogResult → drOk / drCancel
# * prompt(icon, message, default): string → typed text on OK, `default` on Cancel
# * openFileDialog / saveFileDialog      → chosen path ("" when cancelled)
# * printDialog / pageSetupDialog        → drOk / drCancel, settings updated on OK
# * colorDialog / fontDialog             → drOk / drCancel, value updated on OK
# * findDialog                           → find / replace, optionally applied to an Edit
#
# Icons: iconStop, iconExclamation, iconQuestion, iconInformation, iconNone, or the id
# returned by loadIcon(path) for a custom image.
import std/[os, strutils, tables, times, algorithm, osproc, typedthreads, unicode, math]
import ../sdl3, core, controls_basic, controls_lists, api

type
  IconId* = distinct int
  DialogResult* = enum
    drNone = "None", drOk = "Ok", drCancel = "Cancel"

  DialogState = ref object of RootObj
    win: Window
    done: bool
    result: DialogResult
    buttons: seq[tuple[id: ControlId, res: DialogResult]]
    onEvent: proc (st: DialogState, ev: Event): bool {.nimcall.}

proc `==`*(a, b: IconId): bool {.borrow.}

const
  iconNone* = IconId(0)
  iconStop* = IconId(1)
  iconExclamation* = IconId(2)
  iconQuestion* = IconId(3)
  iconInformation* = IconId(4)

var
  customIcons: seq[string]
  dialogStates: Table[int, DialogState]

proc loadIcon*(path: string): IconId =
  # Registers an image (BMP, or PNG/JPG with -d:sdlimage) usable as a dialog icon.
  guarded:
    customIcons.add path
    result = IconId(100 + customIcons.high)

# icon control

type
  IconView* = ref object of Control
    icon*: IconId
    tex: SDL_Texture
    texW, texH: float
    loaded: bool

proc newIconView*(icon: IconId, size = 48.0): IconView =
  result = IconView(icon: icon)
  initControl(result)
  result.fixedWidth = size
  result.fixedHeight = size
  result.stretch = false

method typeName*(c: IconView): string = "Icon"
method preferredSize*(c: IconView, d: Drawing, t: Theme): tuple[w, h: float] = (48.0, 48.0)

proc thickPolyline(d: Drawing, pts: seq[Point], c: Color, ep: float) =
  for i in 1 ..< pts.len: d.line(pts[i-1].x, pts[i-1].y, pts[i].x, pts[i].y, c, ep)
  for p in pts: d.fillCircle(p.x, p.y, ep / 2, c)

method draw*(c: IconView, d: Drawing, t: Theme) =
  let r = c.rect
  let k = min(r.w, r.h) / 48.0
  let cx = r.x + r.w / 2
  let cy = r.y + r.h / 2
  case int(c.icon)
  of 1:                          # stop: red octagon with a white bar.
    var outer, inner: seq[Point]
    for i in 0 ..< 8:
      let a = PI / 8 + float(i) * PI / 4
      outer.add((cx + 23 * k * cos(a), cy + 23 * k * sin(a)))
      inner.add((cx + 21 * k * cos(a), cy + 21 * k * sin(a)))
    d.fillPolygon(outer, hex"#A4262C")
    d.fillPolygon(inner, hex"#E81123")
    d.fillRoundRect(rect(cx - 13 * k, cy - 4 * k, 26 * k, 8 * k), 3 * k, White)
  of 2:                          # exclamation: yellow warning triangle.
    d.fillPolygon([(cx, cy - 22 * k), (cx + 24 * k, cy + 19 * k), (cx - 24 * k, cy + 19 * k)], hex"#C19C00")
    d.fillPolygon([(cx, cy - 18 * k), (cx + 20.5 * k, cy + 17 * k), (cx - 20.5 * k, cy + 17 * k)], hex"#FFC83D")
    d.fillRoundRect(rect(cx - 2.5 * k, cy - 8 * k, 5 * k, 15 * k), 2.5 * k, hex"#1B1B1B")
    d.fillCircle(cx, cy + 12 * k, 3 * k, hex"#1B1B1B")
  of 3:                          # question: blue disc with a white question mark.
    d.fillCircle(cx, cy, 23 * k, hex"#005FB8")
    d.fillCircle(cx, cy, 21.5 * k, hex"#0078D4")
    var pts: seq[Point]
    for i in 0 .. 16:
      let a = PI + float(i) / 16 * 1.5 * PI
      pts.add((cx + 7 * k * cos(a), cy - 6 * k + 7 * k * sin(a)))
    pts.add((cx, cy + 5 * k))
    d.thickPolyline(pts, White, 4.5 * k)
    d.fillCircle(cx, cy + 12.5 * k, 3 * k, White)
  of 4:                          # information: blue disc with a white 'i'.
    d.fillCircle(cx, cy, 23 * k, hex"#005FB8")
    d.fillCircle(cx, cy, 21.5 * k, hex"#0078D4")
    d.fillCircle(cx, cy - 11 * k, 3 * k, White)
    d.fillRoundRect(rect(cx - 2.5 * k, cy - 5 * k, 5 * k, 17 * k), 2.5 * k, White)
  else:
    let i = int(c.icon) - 100
    if i < 0: return
    if not c.loaded:
      c.loaded = true
      var path = ""
      {.cast(gcsafe).}:
        if i < customIcons.len: path = customIcons[i]
      if path.len > 0:
        when defined(sdlimage):
          let s = IMG_Load(path.cstring)
        else:
          let s = SDL_LoadBMP(path.cstring)
        if s != nil:
          c.tex = SDL_CreateTextureFromSurface(d.ren, s)
          SDL_DestroySurface(s)
          if c.tex != nil:
            var w, h: cfloat
            discard SDL_GetTextureSize(c.tex, addr w, addr h)
            c.texW = float(w)
            c.texH = float(h)
    if c.tex != nil:
      let f = min(r.w / max(1.0, c.texW), r.h / max(1.0, c.texH))
      d.drawTexture(c.tex, rect(cx - c.texW * f / 2, cy - c.texH * f / 2, c.texW * f, c.texH * f))

# modal management.

proc canBlock(): bool =
  {.cast(gcsafe).}:
    result = sdlReady and getThreadId() != uiThreadId
  if not result:
    stderr.writeLine("wdgui: dialogs must be called from an event handler (or any thread but the " &
                     "UI thread) once runApplication() is running; returning the default value")

proc ownerWindow(): Window =
  result = activeWindow
  if result == nil or result.closed or result.closeRequested:
    result = nil
    for w in allWindows:
      if w.opened and not w.closeRequested:
        result = w

proc finish(st: DialogState, r: DialogResult) =
  guarded:
    if not st.done:
      st.result = r
      st.done = true
      st.win.closeRequested = true
  wakeUI()

proc dialogDispatch(ev: var Event) {.nimcall, gcsafe.} =
  if ev.current != ev.id: return
  var st: DialogState
  guarded:
    st = dialogStates.getOrDefault(int(ev.window))
  if st == nil: return
  {.cast(gcsafe).}:
    if st.onEvent != nil and st.onEvent(st, ev): return
    case ev.kind
    of evClick:
      for b in st.buttons:
        if b.id == ev.id:
          finish(st, b.res)
          return
    of evWindowClose: finish(st, drCancel)
    else: discard

proc newDialogWindow(st: DialogState, title: string, w, h: int): Window =
  # Must be called inside `guarded` (so that the UI loop sees a complete dialog).
  let owner = ownerWindow()
  let theme = if owner != nil: owner.theme else: themeNative()
  result = newWindow(title, w, h, dialogDispatch, theme, lkBorder)
  result.resizable = false
  result.isModal = true
  result.modalFor = owner
  result.alwaysThreaded = true
  st.win = result
  dialogStates[int(result.id)] = st

proc dialogTheme(): Theme =
  guarded:
    let o = ownerWindow()
    result = if o != nil: o.theme else: themeNative()

proc runModal(st: DialogState): DialogResult =
  wakeUI()
  while true:
    var finished = false
    guarded: finished = st.done
    if finished: break
    sleep(15)
  guarded: dialogStates.del(int(st.win.id))
  st.result

proc initialFocus(win: Window, c: Control) =
  win.focusedControl = c
  c.focus = true

proc addButtonRow(st: DialogState, win: Window,
                  buttons: openArray[tuple[caption: string, res: DialogResult]]): seq[Button] =
  # Buttons given in macOS order (default last); reversed for Windows.
  let row = win.addChild(newSupercontrol(lkHorizontal))
  row.dock = dkBottom
  let spacer = row.addChild(newLabel(""))
  spacer.weight = 1
  var list = @buttons
  if win.theme.look == lfWindows: list.reverse()
  for b in list:
    let btn = row.addChild(newButton(b.caption, isDefault = b.res == drOk, isCancel = b.res == drCancel))
    st.buttons.add((btn.id, b.res))
    result.add btn

proc wrapText(s: string, maxChars = 48): seq[string] =
  for para in s.split('\n'):
    var line = ""
    for w in strutils.splitWhitespace(para):
      if line.len == 0: line = w
      elif line.runeLen + 1 + w.runeLen <= maxChars: line.add(" " & w)
      else:
        result.add line
        line = w
    result.add line

proc messageBody(win: Window, icon: IconId, message: string): Container =
  # Icon on the left, message on the right; returns the right-hand column.
  let body = win.addChild(newSupercontrol(lkHorizontal, 16))
  body.dock = dkCenter
  if icon != iconNone:
    let iv = body.addChild(newIconView(icon))
    iv.stretch = false
  result = body.addChild(newSupercontrol(lkVertical))
  result.weight = 1
  let lbl = result.addChild(newLabel(wrapText(message).join("\n")))
  lbl.stretch = true

proc messageSize(t: Theme, message: string, extra = 0.0): tuple[w, h: int] =
  let lines = wrapText(message).len
  let h = 2 * t.margin + max(52.0, float(lines) * t.lineHeight) + extra + t.controlHeight + 2 * t.spacing + 8
  (440, int(h))

# alert / confirm / prompt

proc alert*(icon: IconId, message: string, title = "Alert") =
  # Shows a short message with an OK button.
  if not canBlock(): return
  let st = DialogState()
  let sz = messageSize(dialogTheme(), message)
  guarded:
    let win = newDialogWindow(st, title, sz.w, sz.h)
    let btns = st.addButtonRow(win, [("OK", drOk)])
    discard messageBody(win, icon, message)
    initialFocus(win, btns[0])
  discard runModal(st)

proc confirm*(icon: IconId, message: string, title = "Confirm"): DialogResult =
  # Shows a short message with OK and Cancel; returns drOk or drCancel.
  if not canBlock(): return drCancel
  let st = DialogState()
  let sz = messageSize(dialogTheme(), message)
  guarded:
    let win = newDialogWindow(st, title, sz.w, sz.h)
    let btns = st.addButtonRow(win, [("Cancel", drCancel), ("OK", drOk)])
    discard messageBody(win, icon, message)
    for b in btns:
      if b.isDefault: initialFocus(win, b)
  result = runModal(st)
  if result != drOk: result = drCancel

proc prompt*(icon: IconId, message: string, defaultValue = "", title = "Input"): string =
  # Shows a message and an Edit; returns the typed text on OK, `defaultValue` on Cancel.
  if not canBlock(): return defaultValue
  let st = DialogState()
  let t = dialogTheme()
  let sz = messageSize(t, message, t.controlHeight + t.spacing)
  var edit: Edit
  guarded:
    let win = newDialogWindow(st, title, sz.w, sz.h)
    discard st.addButtonRow(win, [("Cancel", drCancel), ("OK", drOk)])
    let col = messageBody(win, icon, message)
    edit = col.addChild(newEdit(defaultValue))
    edit.anchor = 0                    # whole text selected
    initialFocus(win, edit)
  if runModal(st) == drOk: edit.id.value else: defaultValue

# file dialogs

type
  FileDialogState = ref object of DialogState
    saving, confirmOverwrite: bool
    folder, chosen: string
    filters: seq[tuple[label: string, patterns: seq[string]]]
    places: seq[string]
    pathEdit, nameEdit, list, filterCombo, placesList, upButton, okButton: ControlId

proc parseFilters(filter: string): seq[tuple[label: string, patterns: seq[string]]] =
  # "Label|*.a;*.b" entries separated by new lines.
  for line in filter.splitLines:
    if line.strip.len == 0: continue
    let p = line.split('|')
    let pats = (if p.len > 1: p[1] else: p[0]).split(';')
    var clean: seq[string]
    for x in pats:
      if x.strip.len > 0: clean.add x.strip
    result.add((p[0].strip, clean))
  if result.len == 0: result.add(("All files", @["*"]))

proc globMatch(name, pat: string): bool =
  # Case-insensitive wildcard match ('*' and '?').
  let s = name.toLowerAscii
  let p = pat.toLowerAscii
  var i, j = 0
  var star = -1
  var mark = 0
  while i < s.len:
    if j < p.len and (p[j] == '?' or p[j] == s[i]):
      inc i
      inc j
    elif j < p.len and p[j] == '*':
      star = j
      mark = i
      inc j
    elif star >= 0:
      j = star + 1
      inc mark
      i = mark
    else:
      return false
  while j < p.len and p[j] == '*': inc j
  j == p.len

proc currentPatterns(st: FileDialogState): seq[string] =
  let i = listSelect(st.filterCombo)
  if i >= 1 and i <= st.filters.len: st.filters[i - 1].patterns else: @["*"]

proc refreshFolder(st: FileDialogState) =
  let pats = st.currentPatterns
  var dirs, files: seq[tuple[name, size, date: string]]
  try:
    for kind, path in walkDir(st.folder):
      let name = extractFilename(path)
      if name.len == 0 or name.startsWith("."): continue
      var date = ""
      try: date = getLastModificationTime(path).format("yyyy-MM-dd HH:mm")
      except CatchableError: discard
      case kind
      of pcDir, pcLinkToDir: dirs.add((name & "/", "", date))
      of pcFile, pcLinkToFile:
        var ok = false
        for p in pats:
          if globMatch(name, p): ok = true
        if ok:
          var size = ""
          try: size = formatSize(getFileSize(path))
          except CatchableError: discard
          files.add((name, size, date))
  except CatchableError: discard
  dirs.sort(proc (a, b: tuple[name, size, date: string]): int = cmpIgnoreCase(a.name, b.name))
  files.sort(proc (a, b: tuple[name, size, date: string]): int = cmpIgnoreCase(a.name, b.name))
  tableDeleteAll(st.list)
  for e in dirs: discard tableAddLine(st.list, e.name, e.size, e.date)
  for e in files: discard tableAddLine(st.list, e.name, e.size, e.date)
  st.pathEdit.value = st.folder

proc navigate(st: FileDialogState, path: string) =
  if path.len == 0 or not dirExists(path): return
  st.folder = normalizedPath(absolutePath(path))
  st.refreshFolder()

proc accept(st: FileDialogState) =
  let typed = st.nameEdit.value.strip
  let typedFolder = st.pathEdit.value.strip
  if typed.len == 0:
    if typedFolder.len > 0 and typedFolder != st.folder and dirExists(typedFolder):
      st.navigate(typedFolder)
    return
  var path = if isAbsolute(typed): typed else: st.folder / typed
  if dirExists(path):
    st.navigate(path)
    st.nameEdit.value = ""
    return
  if st.saving:
    if path.splitFile.ext.len == 0:
      let pats = st.currentPatterns
      if pats.len > 0 and pats[0].startsWith("*.") and '*' notin pats[0][2 .. ^1]:
        path.add pats[0][1 .. ^1]
    if not dirExists(path.parentDir):
      alert(iconStop, "The folder \"" & path.parentDir & "\" does not exist.", st.win.title)
      return
    if fileExists(path) and st.confirmOverwrite:
      if confirm(iconExclamation, "\"" & extractFilename(path) &
                 "\" already exists.\nDo you want to replace it?", st.win.title) != drOk:
        return
  elif not fileExists(path):
    alert(iconExclamation, "\"" & typed & "\" cannot be found.\nCheck the file name and try again.",
          st.win.title)
    return
  st.chosen = path
  finish(st, drOk)

proc fileEvent(s: DialogState, ev: Event): bool {.nimcall.} =
  let st = FileDialogState(s)
  case ev.kind
  of evSelection:
    if ev.id == st.list:
      let r = tableSelect(st.list)
      if r > 0:
        let n = tableCell(st.list, r, 1)
        if not n.endsWith("/"): st.nameEdit.value = n
      return true
    if ev.id == st.placesList:
      let i = listSelect(st.placesList)
      if i >= 1 and i <= st.places.len: st.navigate(st.places[i - 1])
      return true
    if ev.id == st.filterCombo:
      st.refreshFolder()
      return true
  of evDoubleClick:
    if ev.id == st.list:
      let r = tableSelect(st.list)
      if r > 0:
        let n = tableCell(st.list, r, 1)
        if n.endsWith("/"):
          st.navigate(st.folder / n[0 ..< n.high])
        else:
          st.nameEdit.value = n
          st.accept()
      return true
  of evClick:
    if ev.id == st.upButton:
      st.navigate(st.folder.parentDir)
      return true
    if ev.id == st.okButton:
      st.accept()
      return true
  else: discard
  false

proc fileDialog(title, folder, defaultName, filter: string, saving, confirmOverwrite: bool): string =
  if not canBlock(): return ""
  let st = FileDialogState(saving: saving, confirmOverwrite: confirmOverwrite,
                           filters: parseFilters(filter))
  st.onEvent = fileEvent
  st.folder = if folder.len > 0 and dirExists(folder): normalizedPath(absolutePath(folder)) else: getCurrentDir()
  let home = getHomeDir()
  when defined(windows):
    let rootDir = "C:\\"         # CPM legacy :')
  else:
    let rootDir = "/"            # The way it should be done everywhere.
  var placeNames: seq[string]
  for (n, p) in [("Home", home), ("Desktop", home / "Desktop"), ("Documents", home / "Documents"),
                 ("Downloads", home / "Downloads"), ("Current folder", getCurrentDir()),
                 ("Computer", rootDir)]:
    if dirExists(p):
      placeNames.add n
      st.places.add p
  guarded:
    let win = newDialogWindow(st, title, 720, 480)
    # buttons (bottom), then the file-name row just above them.
    let row = win.addChild(newSupercontrol(lkHorizontal))
    row.dock = dkBottom
    let spacer = row.addChild(newLabel(""))
    spacer.weight = 1
    let okCaption = if saving: "Save" else: "Open"
    let cancel = newButton("Cancel", isCancel = true)
    let ok = newButton(okCaption, isDefault = true)
    if win.theme.look == lfWindows:
      discard row.addChild(ok)
      discard row.addChild(cancel)
    else:
      discard row.addChild(cancel)
      discard row.addChild(ok)
    st.buttons.add((cancel.id, drCancel))
    st.okButton = ok.id
    let nameRow = win.addChild(newSupercontrol(lkHorizontal))
    nameRow.dock = dkBottom
    let nl = nameRow.addChild(newLabel(if saving: "Save as:" else: "File name:"))
    nl.fixedWidth = 100
    let ne = nameRow.addChild(newEdit(defaultName))
    ne.weight = 1
    st.nameEdit = ne.id
    var labels: seq[string]
    for f in st.filters: labels.add f.label
    let fc = nameRow.addChild(newComboBox(labels, 0))
    fc.fixedWidth = 200
    st.filterCombo = fc.id
    # folder bar (top)
    let top = win.addChild(newSupercontrol(lkHorizontal))
    top.dock = dkTop
    st.upButton = top.addChild(newButton("Up")).id
    let pe = top.addChild(newEdit(st.folder))
    pe.weight = 1
    st.pathEdit = pe.id
    # places (left) and the folder content (center).
    let pl = win.addChild(newListBox(placeNames))
    pl.dock = dkLeft
    pl.fixedWidth = 150
    st.placesList = pl.id
    let tb = win.addChild(controls_lists.newTable())
    tb.dock = dkCenter
    tb.addColumn("Name", 300)
    tb.addColumn("Size", 90, alRight)
    tb.addColumn("Modified", 150)
    st.list = tb.id
    initialFocus(win, ne)
  st.refreshFolder()
  if runModal(st) == drOk: st.chosen else: ""

proc openFileDialog*(title = "Open", folder = "", filter = "All files|*"): string =
  # Lets the user pick an existing file; returns its full path, "" if cancelled.
  # filter: one "Label|*.ext1;*.ext2" entry per line, e.g. "Images|*.bmp;*.png\nAll files|*".
  fileDialog(title, folder, "", filter, saving = false, confirmOverwrite = false)

proc saveFileDialog*(title = "Save As", folder = "", defaultName = "", filter = "All files|*",
                     confirmOverwrite = true): string =
  # Asks for a file name to save to; adds the filter's extension when none is typed and
  # asks before replacing an existing file. Returns the full path, "" if cancelled.
  fileDialog(title, folder, defaultName, filter, saving = true, confirmOverwrite = confirmOverwrite)

# print / page setup

type
  PrintSettings* = object
    printer*: string
    copies*: int
    allPages*: bool
    fromPage*, toPage*: int
    collate*, color*: bool
  PaperSize* = enum
    psA4 = "A4", psA3 = "A3", psA5 = "A5", psLetter = "Letter", psLegal = "Legal"
  Orientation* = enum
    orPortrait = "Portrait", orLandscape = "Landscape"
  PageSettings* = object
    paper*: PaperSize
    orientation*: Orientation
    marginLeft*, marginTop*, marginRight*, marginBottom*: float   ## millimetres

proc defaultPrintSettings*(): PrintSettings =
  PrintSettings(copies: 1, allPages: true, fromPage: 1, toPage: 1, collate: true, color: true)

proc defaultPageSettings*(): PageSettings =
  PageSettings(paper: psA4, orientation: orPortrait, marginLeft: 20, marginTop: 20,
               marginRight: 20, marginBottom: 20)

proc paperSizeMm*(p: PaperSize): tuple[w, h: float] =
  case p
  of psA4: (210.0, 297.0)
  of psA3: (297.0, 420.0)
  of psA5: (148.0, 210.0)
  of psLetter: (215.9, 279.4)
  of psLegal: (215.9, 355.6)

proc listPrinters*(): seq[string] =
  # Installed printers (CUPS `lpstat` on macOS / Linux, PowerShell on Windows); may be empty.
  try:
    when defined(windows):       # todo: create a JSON file containing all commands and parameters
                                 # to allow the end user (or local administrator) to adapt them to their specific context.
      let (outp, code) = execCmdEx("powershell -NoProfile -Command \"Get-Printer | ForEach-Object { $_.Name }\"")
    else:
      let (outp, code) = execCmdEx("lpstat -e")
    if code == 0:
      for l in outp.splitLines:
        if l.strip.len > 0: result.add l.strip
  except CatchableError: discard

type
  PrintDialogState = ref object of DialogState
    pages, fromSpin, toSpin: ControlId

proc printEvent(s: DialogState, ev: Event): bool {.nimcall.} =
  let st = PrintDialogState(s)
  if ev.kind == evChange and ev.id == st.pages:
    let isRange = st.pages.value == "2"
    st.fromSpin.state = (if isRange: csActive else: csGrayed)
    st.toSpin.state = (if isRange: csActive else: csGrayed)
    return true
  false

proc printDialog*(settings: var PrintSettings, title = "Print"): DialogResult =
  # Printer, copies, page range, collate, color. Updates `settings` on OK.
  # (wdgui has no print engine: use the settings with your own printing code.)
  if not canBlock(): return drCancel
  let st = PrintDialogState()
  st.onEvent = printEvent
  var printers = listPrinters()
  if printers.len == 0: printers.add "Default printer"
  let s0 = settings
  var combo, copies, collate, color: ControlId
  guarded:
    let win = newDialogWindow(st, title, 460, 330)
    let btns = st.addButtonRow(win, [("Cancel", drCancel), ("OK", drOk)])
    for b in btns:
      if b.isDefault: b.caption = "Print"
    let g = win.addChild(newContainer(lkGrid, 0, -1, 2))
    g.dock = dkCenter
    discard g.addChild(newLabel("Printer:"))
    var sel = printers.find(s0.printer)
    if sel < 0: sel = 0
    combo = g.addChild(newComboBox(printers, sel)).id
    discard g.addChild(newLabel("Copies:"))
    copies = g.addChild(newSpin(float(max(1, s0.copies)), 1, 999)).id
    discard g.addChild(newLabel("Pages:"))
    let pg = g.addChild(newRadioButton(["All", "Range"], (if s0.allPages: 0 else: 1), horizontal = true))
    st.pages = pg.id
    discard g.addChild(newLabel("From / to:"))
    let r = g.addChild(newSupercontrol(lkHorizontal))
    let f = r.addChild(newSpin(float(max(1, s0.fromPage)), 1, 9999))
    let tt = r.addChild(newSpin(float(max(1, s0.toPage)), 1, 9999))
    f.state = (if s0.allPages: csGrayed else: csActive)
    tt.state = f.state
    st.fromSpin = f.id
    st.toSpin = tt.id
    discard g.addChild(newLabel(""))
    collate = g.addChild(newCheckBox("Collate copies", s0.collate)).id
    discard g.addChild(newLabel(""))
    color = g.addChild(newCheckBox("Color", s0.color)).id
  result = runModal(st)
  if result == drOk:
    settings.printer = listItem(combo, listSelect(combo))
    settings.copies = int(copies.valueNum)
    settings.allPages = st.pages.value == "1"
    settings.fromPage = int(st.fromSpin.valueNum)
    settings.toPage = max(settings.fromPage, int(st.toSpin.valueNum))
    settings.collate = collate.value == "1"
    settings.color = color.value == "1"
  else: result = drCancel

type
  PagePreview* = ref object of Control
    paperW*, paperH*: float
    margins*: array[4, float]   ## left, top, right, bottom (mm)

method preferredSize*(c: PagePreview, d: Drawing, t: Theme): tuple[w, h: float] = (190.0, 230.0)

method draw*(c: PagePreview, d: Drawing, t: Theme) =
  let r = c.rect.shrink(10)
  let k = min(r.w / max(1.0, c.paperW), r.h / max(1.0, c.paperH))
  let pw = c.paperW * k
  let ph = c.paperH * k
  let page = rect(r.x + (r.w - pw) / 2, r.y + (r.h - ph) / 2, pw, ph)
  d.shadow(page, 2, t.shadow)
  d.fillRect(page, Black.withAlpha(60))
  d.fillRect(page.shrink(1), White)
  let area = rect(page.x + c.margins[0] * k, page.y + c.margins[1] * k,
                  max(0.0, pw - (c.margins[0] + c.margins[2]) * k),
                  max(0.0, ph - (c.margins[1] + c.margins[3]) * k))
  var y = area.y + 4
  while y + 3 < area.y + area.h:                       # simulated text lines
    d.fillRect(rect(area.x, y, area.w * (if int(y) mod 5 == 0: 0.7 else: 1.0), 2), hex"#C8C8C8")
    y += 6
  d.strokeRect(area, t.accent.withAlpha(160))

type
  PageDialogState = ref object of DialogState
    paper, orient, preview: ControlId
    margins: array[4, ControlId]

proc updatePreview(st: PageDialogState) =
  var p = PaperSize(max(0, listSelect(st.paper) - 1))
  var (w, h) = paperSizeMm(p)
  if st.orient.value == "2": swap(w, h)
  var m: array[4, float]
  for i in 0 .. 3: m[i] = st.margins[i].valueNum
  withControl(st.preview, PagePreview, pv):
    pv.paperW = w
    pv.paperH = h
    pv.margins = m

proc pageEvent(s: DialogState, ev: Event): bool {.nimcall.} =
  let st = PageDialogState(s)
  if ev.kind in {evChange, evSelection}:
    st.updatePreview()
  false

proc pageSetupDialog*(settings: var PageSettings, title = "Page Setup"): DialogResult =
  # Paper size, orientation and margins with a live preview. Updates `settings` on OK.
  if not canBlock(): return drCancel
  let st = PageDialogState()
  st.onEvent = pageEvent
  let s0 = settings
  guarded:
    let win = newDialogWindow(st, title, 560, 360)
    discard st.addButtonRow(win, [("Cancel", drCancel), ("OK", drOk)])
    let pv = PagePreview()
    initControl(pv)
    pv.stretch = false
    let right = win.addChild(pv)
    right.dock = dkRight
    st.preview = pv.id
    let g = win.addChild(newContainer(lkGrid, 0, -1, 2))
    g.dock = dkCenter
    discard g.addChild(newLabel("Paper:"))
    var names: seq[string]
    for p in PaperSize:
      let (w, h) = paperSizeMm(p)
      names.add $p & "  (" & formatNumber(w) & " x " & formatNumber(h) & " mm)"
    st.paper = g.addChild(newComboBox(names, ord(s0.paper))).id
    discard g.addChild(newLabel("Orientation:"))
    st.orient = g.addChild(newRadioButton(["Portrait", "Landscape"], ord(s0.orientation), horizontal = true)).id
    let captions = ["Left margin (mm):", "Top margin (mm):", "Right margin (mm):", "Bottom margin (mm):"]
    let values = [s0.marginLeft, s0.marginTop, s0.marginRight, s0.marginBottom]
    for i in 0 .. 3:
      discard g.addChild(newLabel(captions[i]))
      st.margins[i] = g.addChild(newSpin(values[i], 0, 100)).id
  st.updatePreview()
  result = runModal(st)
  if result == drOk:
    settings.paper = PaperSize(max(0, listSelect(st.paper) - 1))
    settings.orientation = (if st.orient.value == "2": orLandscape else: orPortrait)
    settings.marginLeft = st.margins[0].valueNum
    settings.marginTop = st.margins[1].valueNum
    settings.marginRight = st.margins[2].valueNum
    settings.marginBottom = st.margins[3].valueNum
  else: result = drCancel

#  color dialog

proc hsv(h, s, v: float): Color =
  let c = v * s
  let hh = h / 60
  let x = c * (1 - abs((hh mod 2) - 1))
  let m = v - c
  var r, g, b = 0.0
  case int(hh) mod 6
  of 0:
    r = c
    g = x
  of 1:
    r = x
    g = c
  of 2:
    g = c
    b = x
  of 3:
    g = x
    b = c
  of 4:
    r = x
    b = c
  else:
    r = c
    b = x
  rgb(int(round((r + m) * 255)), int(round((g + m) * 255)), int(round((b + m) * 255)))

proc basicColors(): seq[Color] =
  for i in 0 ..< 8: result.add rgb(i * 255 div 7, i * 255 div 7, i * 255 div 7)
  let hues = [0.0, 30, 55, 120, 180, 210, 270, 320]
  for (s, v) in [(0.25, 1.0), (0.55, 1.0), (1.0, 1.0), (1.0, 0.7), (1.0, 0.45)]:
    for h in hues: result.add hsv(h, s, v)

proc hexOf*(c: Color): string =
  # "#RRGGBB" (or "#RRGGBBAA" when not opaque).
  result = "#" & toHex(int(c.r), 2) & toHex(int(c.g), 2) & toHex(int(c.b), 2)
  if c.a < 255: result.add toHex(int(c.a), 2)

type
  ColorPalette* = ref object of Control
    colors*: seq[Color]
    selected*: int
  ColorSwatch* = ref object of Control
    oldColor*, newColor*: Color

const cell = 26.0

method preferredSize*(c: ColorPalette, d: Drawing, t: Theme): tuple[w, h: float] =
  (8 * cell + 4, float((c.colors.len + 7) div 8) * cell + 4)
method draw*(c: ColorPalette, d: Drawing, t: Theme) =
  for i, col in c.colors:
    let r = rect(c.rect.x + 2 + float(i mod 8) * cell, c.rect.y + 2 + float(i div 8) * cell, cell - 4, cell - 4)
    d.fillRoundRect(r, 4, t.border)
    d.fillRoundRect(r.shrink(1), 3, col)
    if i == c.selected: d.strokeRoundRect(r.shrink(-2), 6, t.accent, 2)
method onMouse*(c: ColorPalette, e: MouseEvent) =
  if e.action != maPress: return
  let i = int((e.y - c.rect.y - 2) / cell) * 8 + int((e.x - c.rect.x - 2) / cell)
  if i >= 0 and i < c.colors.len and e.x < c.rect.x + 2 + 8 * cell:
    c.selected = i
    emit(c, evChange, index = i + 1, text = hexOf(c.colors[i]))

method preferredSize*(c: ColorSwatch, d: Drawing, t: Theme): tuple[w, h: float] = (160.0, 70.0)
method draw*(c: ColorSwatch, d: Drawing, t: Theme) =
  let r = c.rect
  d.fillRoundRect(r, 6, t.border)
  let inner = r.shrink(1)
  var y = inner.y                # checkerboard behind (shows alpha).
  var row = 0
  while y < inner.y + inner.h:
    var x = inner.x
    var col = row mod 2
    while x < inner.x + inner.w:
      d.fillRect(rect(x, y, min(8.0, inner.x + inner.w - x), min(8.0, inner.y + inner.h - y)),
                 if col mod 2 == 0: hex"#FFFFFF" else: hex"#D0D0D0")
      x += 8
      inc col
    y += 8
    inc row
  d.fillRect(rect(inner.x, inner.y, inner.w / 2, inner.h), c.oldColor)
  d.fillRect(rect(inner.x + inner.w / 2, inner.y, inner.w / 2, inner.h), c.newColor)

type
  ColorDialogState = ref object of DialogState
    color: Color
    palette, swatch, hexEdit: ControlId
    sliders, spins: array[4, ControlId]

proc channel(c: Color, i: int): int =
  case i
  of 0: int(c.r)
  of 1: int(c.g)
  of 2: int(c.b)
  else: int(c.a)

proc withChannel(c: Color, i, v: int): Color =
  result = c
  let b = uint8(clamp(v, 0, 255))
  case i
  of 0: result.r = b
  of 1: result.g = b
  of 2: result.b = b
  else: result.a = b

proc syncColor(st: ColorDialogState, skipHex = false) =
  let c = st.color
  for i in 0 .. 3:
    st.sliders[i].valueNum = float(channel(c, i))
    st.spins[i].valueNum = float(channel(c, i))
  if not skipHex: st.hexEdit.value = hexOf(c)
  withControl(st.swatch, ColorSwatch, sw): sw.newColor = c

proc colorEvent(s: DialogState, ev: Event): bool {.nimcall.} =
  let st = ColorDialogState(s)
  if ev.kind != evChange: return false
  if ev.id == st.palette:
    let a = st.color.a
    st.color = hex(ev.text).withAlpha(int(a))
    st.syncColor()
    return true
  if ev.id == st.hexEdit:
    let h = ev.text.strip
    if h.startsWith("#") and h.len in [7, 9] and h[1 .. ^1].allCharsInSet(HexDigits):
      st.color = hex(h)
      st.syncColor(skipHex = true)
    return true
  for i in 0 .. 3:
    if ev.id == st.sliders[i] or ev.id == st.spins[i]:
      st.color = withChannel(st.color, i, int(round(ev.id.valueNum)))
      st.syncColor()
      return true
  false

proc colorDialog*(color: var Color, title = "Colors"): DialogResult =
  # Basic palette, red / green / blue / opacity sliders, hexadecimal code, old/new preview.
  # Updates `color` on OK.
  if not canBlock(): return drCancel
  let st = ColorDialogState(color: color)
  st.onEvent = colorEvent
  guarded:
    let win = newDialogWindow(st, title, 600, 380)
    discard st.addButtonRow(win, [("Cancel", drCancel), ("OK", drOk)])
    let pal = ColorPalette(colors: basicColors(), selected: -1)
    initControl(pal)
    pal.stretch = false
    let left = win.addChild(newSupercontrol(lkVertical))
    left.dock = dkLeft
    discard left.addChild(newLabel("Basic colors"))
    discard left.addChild(pal)
    st.palette = pal.id
    let right = win.addChild(newSupercontrol(lkVertical))
    right.dock = dkCenter
    let sw = ColorSwatch(oldColor: color, newColor: color)
    initControl(sw)
    sw.stretch = false
    discard right.addChild(sw)
    st.swatch = sw.id
    let names = ["Red", "Green", "Blue", "Opacity"]
    for i in 0 .. 3:
      let row = right.addChild(newSupercontrol(lkHorizontal))
      let l = row.addChild(newLabel(names[i]))
      l.fixedWidth = 80
      let sl = row.addChild(newSlider(float(channel(color, i)), 0, 255))
      sl.weight = 1
      let sp = row.addChild(newSpin(float(channel(color, i)), 0, 255))
      sp.fixedWidth = 80
      st.sliders[i] = sl.id
      st.spins[i] = sp.id
    let hr = right.addChild(newSupercontrol(lkHorizontal))
    let hl = hr.addChild(newLabel("Hex"))
    hl.fixedWidth = 80
    let he = hr.addChild(newEdit(hexOf(color)))
    he.fixedWidth = 140
    st.hexEdit = he.id
  result = runModal(st)
  if result == drOk: color = st.color
  else: result = drCancel

# font dialog

type
  FontChoice* = object
    family*, style*, path*: string
    size*: float
    bold*, italic*, underline*: bool
  FontEntry = tuple[family, style, path: string]

proc fontDirs(): seq[string] =
  let home = getHomeDir()
  when defined(windows):         # todo: json.
    @[getEnv("WINDIR", "C:\\Windows") / "Fonts", home / "AppData/Local/Microsoft/Windows/Fonts"]
  elif defined(macosx):
    @["/System/Library/Fonts", "/System/Library/Fonts/Supplemental", "/Library/Fonts", home / "Library/Fonts"]
  else:
    @["/usr/share/fonts", "/usr/local/share/fonts", home / ".fonts", home / ".local/share/fonts"]

proc scanFonts*(): seq[tuple[family, style, path: string]] =
  # TrueType / OpenType fonts installed on the system (family and style from the file name).
  for dir in fontDirs():
    if not dirExists(dir): continue
    try:
      for path in walkDirRec(dir):
        let (_, name, ext) = splitFile(path)
        if ext.toLowerAscii notin [".ttf", ".otf", ".ttc"]: continue
        var family = name
        var style = "Regular"
        let dash = name.rfind('-')
        if dash > 0:
          family = name[0 ..< dash]
          style = name[dash + 1 .. ^1]
        result.add((family, style, path))
        if result.len >= 5000: return
    except CatchableError: discard

type
  FontPreview* = ref object of Control
    path*: string
    size*: float
    underline*: bool
    sample*: string
    when defined(sdlttf):
      font: TTF_Font
      key: string
      tex: SDL_Texture
      texW, texH: float

method preferredSize*(c: FontPreview, d: Drawing, t: Theme): tuple[w, h: float] = (300.0, 90.0)
method draw*(c: FontPreview, d: Drawing, t: Theme) =
  let r = c.rect
  d.fillRoundRect(r, t.fieldRadius, t.border)
  d.fillRoundRect(r.shrink(1), t.fieldRadius - 1, t.fieldBg)
  d.pushClip(r.shrink(2))
  var drawn = false
  when defined(sdlttf):
    let key = c.path & "|" & $c.size & "|" & c.sample
    if key != c.key:
      c.key = key
      if c.tex != nil: SDL_DestroyTexture(c.tex)
      c.tex = nil
      if c.font != nil: TTF_CloseFont(c.font)
      c.font = nil
      if c.path.len > 0: c.font = TTF_OpenFont(c.path.cstring, c.size.cfloat)
      if c.font != nil:
        let surf = TTF_RenderText_Blended(c.font, c.sample.cstring, csize_t(c.sample.len),
                                          SDL_Color(r: t.text.r, g: t.text.g, b: t.text.b, a: 255))
        if surf != nil:
          c.tex = SDL_CreateTextureFromSurface(d.ren, surf)
          SDL_DestroySurface(surf)
          var w, h: cfloat
          if c.tex != nil and SDL_GetTextureSize(c.tex, addr w, addr h):
            c.texW = float(w)
            c.texH = float(h)
    if c.tex != nil:
      let x = r.x + max(8.0, (r.w - c.texW) / 2)
      let y = r.y + (r.h - c.texH) / 2
      d.drawTexture(c.tex, rect(x, y, c.texW, c.texH))
      if c.underline: d.fillRect(rect(x, y + c.texH * 0.9, min(c.texW, r.w - 16), max(1.0, c.size / 14)), t.text)
      drawn = true
  if not drawn:
    d.textIn(r, c.sample, t.text, alCenter)
    d.textIn(rect(r.x, r.y + r.h - 22, r.w, 20), "(build with -d:sdlttf for a true preview)",
             t.textSecondary, alCenter)
  d.popClip()

type
  FontDialogState = ref object of DialogState
    fonts: seq[FontEntry]
    families: seq[string]
    familyList, styleList, sizeSpin, sizeList, underline, preview: ControlId
    stylesShown: seq[FontEntry]

const commonSizes = ["8", "9", "10", "11", "12", "14", "16", "18", "20", "24", "28", "36", "48", "72"]

proc currentFont(st: FontDialogState): FontEntry =
  let s = listSelect(st.styleList)
  if s >= 1 and s <= st.stylesShown.len: st.stylesShown[s - 1] else: ("", "", "")

proc updateFontPreview(st: FontDialogState) =
  let f = st.currentFont
  let size = st.sizeSpin.valueNum
  let u = st.underline.value == "1"
  withControl(st.preview, FontPreview, pv):
    pv.path = f.path
    pv.size = size
    pv.underline = u

proc showStyles(st: FontDialogState, family: string, preferred = "") =
  st.stylesShown.setLen(0)
  for f in st.fonts:
    if f.family == family: st.stylesShown.add f
  st.stylesShown.sort(proc (a, b: FontEntry): int = cmpIgnoreCase(a.style, b.style))
  listDeleteAll(st.styleList)
  var sel = 1
  for i, f in st.stylesShown:
    discard listAdd(st.styleList, f.style)
    if cmpIgnoreCase(f.style, preferred) == 0 or (preferred.len == 0 and cmpIgnoreCase(f.style, "Regular") == 0):
      sel = i + 1
  if st.stylesShown.len > 0: listSelectPlus(st.styleList, sel)
  st.updateFontPreview()

proc fontEvent(s: DialogState, ev: Event): bool {.nimcall.} =
  let st = FontDialogState(s)
  case ev.kind
  of evSelection:
    if ev.id == st.familyList:
      let i = listSelect(st.familyList)
      if i >= 1: st.showStyles(st.families[i - 1], listItem(st.styleList, listSelect(st.styleList)))
      return true
    if ev.id == st.styleList:
      st.updateFontPreview()
      return true
    if ev.id == st.sizeList:
      let i = listSelect(st.sizeList)
      if i >= 1: st.sizeSpin.value = commonSizes[i - 1]
      st.updateFontPreview()
      return true
  of evChange:
    if ev.id == st.sizeSpin or ev.id == st.underline:
      st.updateFontPreview()
      return true
  else: discard
  false

proc fontDialog*(font: var FontChoice, title = "Font", sample = "The quick brown fox jumps over the lazy dog."): DialogResult =
  # Family, style, size and underline, with a live preview (with -d:sdlttf). Updates `font` on OK.
  if not canBlock(): return drCancel
  let st = FontDialogState(fonts: scanFonts())
  st.onEvent = fontEvent
  for f in st.fonts:
    if f.family notin st.families: st.families.add f.family
  st.families.sort(proc (a, b: string): int = cmpIgnoreCase(a, b))
  let f0 = font
  guarded:
    let win = newDialogWindow(st, title, 680, 460)
    discard st.addButtonRow(win, [("Cancel", drCancel), ("OK", drOk)])
    let pv = FontPreview(path: f0.path, size: (if f0.size > 0: f0.size else: 14.0),
                         underline: f0.underline, sample: sample)
    initControl(pv)
    pv.fixedHeight = 96
    let p = win.addChild(pv)
    p.dock = dkBottom
    st.preview = pv.id
    let opts = win.addChild(newSupercontrol(lkHorizontal))
    opts.dock = dkBottom
    st.underline = opts.addChild(newCheckBox("Underline", f0.underline)).id
    let cols = win.addChild(newSupercontrol(lkHorizontal))
    cols.dock = dkCenter
    let c1 = cols.addChild(newSupercontrol(lkVertical))
    c1.weight = 1
    discard c1.addChild(newLabel("Family"))
    let fl = c1.addChild(newListBox(st.families))
    fl.weight = 1
    st.familyList = fl.id
    let c2 = cols.addChild(newSupercontrol(lkVertical))
    c2.fixedWidth = 170
    discard c2.addChild(newLabel("Style"))
    let sl = c2.addChild(newListBox())
    sl.weight = 1
    st.styleList = sl.id
    let c3 = cols.addChild(newSupercontrol(lkVertical))
    c3.fixedWidth = 90
    discard c3.addChild(newLabel("Size"))
    st.sizeSpin = c3.addChild(newSpin((if f0.size > 0: f0.size else: 14.0), 4, 400)).id
    let szl = c3.addChild(newListBox(commonSizes))
    szl.weight = 1
    st.sizeList = szl.id
  var fi = st.families.find(f0.family)
  if fi < 0 and st.families.len > 0: fi = 0
  if fi >= 0:
    listSelectPlus(st.familyList, fi + 1)
    st.showStyles(st.families[fi], f0.style)
  result = runModal(st)
  if result == drOk:
    let f = st.currentFont
    font.family = f.family
    font.style = f.style
    font.path = f.path
    font.size = st.sizeSpin.valueNum
    let low = f.style.toLowerAscii
    font.bold = "bold" in low or "black" in low or "heavy" in low
    font.italic = "italic" in low or "oblique" in low
    font.underline = st.underline.value == "1"
  else: result = drCancel

# find and replace

type
  FindAction* = enum
    faNone = "None", faFindNext = "FindNext", faReplace = "Replace", faReplaceAll = "ReplaceAll"
  FindRequest* = object
    action*: FindAction
    findText*, replaceText*: string
    matchCase*, wholeWord*, backwards*: bool

proc findInText*(text: string, req: FindRequest, start: int, wrap = true): int =
  # Byte position of the next match from `start` (before it when backwards), -1 if none.
  if req.findText.len == 0: return -1
  let hay = if req.matchCase: text else: text.toLowerAscii
  let needle = if req.matchCase: req.findText else: req.findText.toLowerAscii
  let n = hay.len
  let m = needle.len
  if m > n: return -1
  proc isWord(c: char): bool = c.isAlphaNumeric or c == '_' or ord(c) >= 128
  proc at(p: int): bool =
    if p < 0 or p + m > n or not hay.continuesWith(needle, p): return false
    if not req.wholeWord: return true
    (p == 0 or not isWord(hay[p - 1])) and (p + m >= n or not isWord(hay[p + m]))
  if not req.backwards:
    for p in max(0, start) .. n - m:
      if at(p): return p
    if wrap:
      for p in 0 .. min(start - 1, n - m):
        if at(p): return p
  else:
    for p in countdown(min(start - 1, n - m), 0):
      if at(p): return p
    if wrap:
      for p in countdown(n - m, max(0, start)):
        if at(p): return p
  -1

proc applyFind*(target: ControlId, req: FindRequest): int =
  # Runs a request on an Edit control (thread-safe). faFindNext selects the next match and
  # returns its 1-based position (0 = not found); faReplace replaces the selected match then
  # selects the next one; faReplaceAll replaces everything. Both return the replacement count.
  withControl(target, Edit, e):
    let a = min(e.cursor, e.anchor)
    let b = max(e.cursor, e.anchor)
    var text = e.text
    var sel = (-1, 0)
    case req.action
    of faNone, faFindNext:
      let p = findInText(text, req, if req.backwards: a else: b)
      if p >= 0:
        sel = (p, req.findText.len)
        result = p + 1
    of faReplace:
      let cur = text[a ..< b]
      if b > a and (if req.matchCase: cur == req.findText else: cmpIgnoreCase(cur, req.findText) == 0):
        text = text[0 ..< a] & req.replaceText & text[b .. ^1]
        result = 1
      var fwd = req
      fwd.backwards = false
      let p = findInText(text, fwd, a + (if result > 0: req.replaceText.len else: 0))
      if p >= 0: sel = (p, req.findText.len)
    of faReplaceAll:
      var fwd = req
      fwd.backwards = false
      var pos = 0
      while true:
        let p = findInText(text, fwd, pos, wrap = false)
        if p < 0: break
        text = text[0 ..< p] & req.replaceText & text[p + req.findText.len .. ^1]
        pos = p + req.replaceText.len
        inc result
    let changed = text != e.text
    e.setValueText(text)         # also scrolls to the cursor.
    if sel[0] >= 0:
      e.anchor = sel[0]
      e.cursor = sel[0] + sel[1]
    if changed: emit(e, evChange, text = e.text)

type
  FindDialogState = ref object of DialogState
    target: ControlId
    request: FindRequest
    acted: bool
    findEdit, replaceEdit, matchCase, wholeWord, backwards, status: ControlId
    findBtn, replaceBtn, replaceAllBtn, closeBtn: ControlId

proc readRequest(st: FindDialogState, action: FindAction): FindRequest =
  result.action = action
  result.findText = st.findEdit.value
  result.replaceText = (if st.replaceEdit != NoControl: st.replaceEdit.value else: "")
  result.matchCase = st.matchCase.value == "1"
  result.wholeWord = st.wholeWord.value == "1"
  result.backwards = st.backwards != NoControl and st.backwards.value == "1"

proc findEvent(s: DialogState, ev: Event): bool {.nimcall.} =
  let st = FindDialogState(s)
  if ev.kind == evWindowClose:
    finish(st, if st.acted: drOk else: drCancel)
    return true
  if ev.kind != evClick: return false
  var action = faNone
  if ev.id == st.findBtn: action = faFindNext
  elif ev.id == st.replaceBtn: action = faReplace
  elif ev.id == st.replaceAllBtn: action = faReplaceAll
  elif ev.id == st.closeBtn:
    finish(st, if st.acted: drOk else: drCancel)
    return true
  else: return false
  let req = st.readRequest(action)
  st.request = req
  if req.findText.len == 0:
    st.status.caption = "Type the text to find."
    return true
  if st.target == NoControl:     # no target: the caller performs the action.
    finish(st, drOk)
    return true
  st.acted = true
  let n = applyFind(st.target, req)
  var msg = ""
  case action
  of faFindNext:
    msg = if n > 0: "Found at position " & $n & "." else: "\"" & req.findText & "\" not found."
  of faReplace:
    msg = if n > 0: "1 replacement." else: "Nothing selected to replace; next match selected."
  else:
    msg = $n & " replacement(s)."
  st.status.caption = msg
  true

proc findDialog*(request: var FindRequest, target = NoControl, replace = false, title = ""): DialogResult =
  # Find (and Replace when `replace` is true).
  # * With a `target` Edit: the buttons act on it directly and the box stays open until
  #   Close; returns drOk if at least one action was performed.
  # * Without target: the box closes on the first action and `request.action` tells the
  #   caller what to do (see findInText / applyFind).
  if not canBlock(): return drCancel
  let st = FindDialogState(target: target, request: request)
  st.onEvent = findEvent
  let r0 = request
  let caption = if title.len > 0: title elif replace: "Find and Replace" else: "Find"
  guarded:
    let win = newDialogWindow(st, caption, 560, (if replace: 250 else: 210))
    let status = win.addChild(newLabel(""))
    status.dock = dkBottom
    st.status = status.id
    let btns = win.addChild(newSupercontrol(lkVertical))
    btns.dock = dkRight
    btns.fixedWidth = 130
    let fb = btns.addChild(newButton("Find Next", isDefault = true))
    fb.stretch = true
    st.findBtn = fb.id
    if replace:
      let rb = btns.addChild(newButton("Replace"))
      rb.stretch = true
      st.replaceBtn = rb.id
      let ra = btns.addChild(newButton("Replace All"))
      ra.stretch = true
      st.replaceAllBtn = ra.id
    let cb = btns.addChild(newButton("Close", isCancel = true))
    cb.stretch = true
    st.closeBtn = cb.id
    let g = win.addChild(newContainer(lkGrid, 0, -1, 2))
    g.dock = dkCenter
    discard g.addChild(newLabel("Find:"))
    let fe = g.addChild(newEdit(r0.findText))
    fe.anchor = 0
    st.findEdit = fe.id
    if replace:
      discard g.addChild(newLabel("Replace with:"))
      st.replaceEdit = g.addChild(newEdit(r0.replaceText)).id
    discard g.addChild(newLabel(""))
    st.matchCase = g.addChild(newCheckBox("Match case", r0.matchCase)).id
    discard g.addChild(newLabel(""))
    st.wholeWord = g.addChild(newCheckBox("Whole word", r0.wholeWord)).id
    if not replace:
      discard g.addChild(newLabel(""))
      st.backwards = g.addChild(newCheckBox("Search backwards", r0.backwards)).id
    initialFocus(win, fe)
  result = runModal(st)
  if result == drOk: request = st.request
  else: result = drCancel
