# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
# wdgui core: controls, containers, windows, thread-safe registry (id-based
# access), event emission, layouts, hit testing, focus.
import std/[locks, math, strutils]
import ../sdl3, colors_themes, drawing
export colors_themes, drawing

type
  ControlId* = distinct int      # id of a control (or of a window)

proc `==`*(a, b: ControlId): bool {.borrow.}
proc `$`*(a: ControlId): string = "#" & $int(a)
const NoControl* = ControlId(0)

type
  EventKind* = enum
    evNone = "None", evClick = "Click", evRightClick = "RightClick", evMiddleClick = "MiddleClick",
    evDoubleClick = "DoubleClick", evRightDoubleClick = "RightDoubleClick",
    evMiddleDoubleClick = "MiddleDoubleClick",
    evButtonDown = "ButtonDown", evButtonUp = "ButtonUp",
    evMouseEnter = "MouseEnter", evMouseLeave = "MouseLeave", evMouseMove = "MouseMove",
    evWheel = "Wheel", evKeyDown = "KeyDown", evKeyUp = "KeyUp",
    evTextInput = "TextInput", evFocusGained = "FocusGained", evFocusLost = "FocusLost",
    evChange = "Change", evSelection = "Selection",
    evExpand = "Expand", evCollapse = "Collapse", evValidate = "Validate",
    evWindowOpen = "WindowOpen", evWindowClose = "WindowClose",
    evWindowResize = "WindowResize", evWindowActivate = "WindowActivate",
    evWindowDeactivate = "WindowDeactivate"

  MouseButton* = enum
    mbNone = "None", mbLeft = "Left", mbMiddle = "Middle", mbRight = "Right"

  Event* = object
    window*: ControlId       # source window.
    id*: ControlId           # target control (origin of the event).
    current*: ControlId      # level reached during propagation (target, parents..., window).
    kind*: EventKind
    x*, y*: float            # mouse position (window coordinates).
    button*: MouseButton
    key*: uint32             # SDL key code (SDLK_*).
    modifiers*: uint16       # KMOD_*.
    isRepeat*: bool
    text*: string                # typed text, menu item, tree path...
    index*: int                  # affected row / option / tab (1-based).
    column*: int                 # affected column for grids (1-based, 0 = none).
    dx*, dy*: float              # wheel.
    timestamp*: uint64
    stopped: bool

  DispatchProc* = proc (ev: var Event) {.nimcall, gcsafe.}
    # Window event handler, called on a dedicated thread.

  ControlState* = enum
    csActive = "Active", csGrayed = "Grayed", csReadOnly = "ReadOnly"

  Dock* = enum
    dkCenter, dkTop, dkBottom, dkRight, dkLeft

  LayoutKind* = enum
    lkAbsolute = "Absolute", lkVertical = "Vertical", lkHorizontal = "Horizontal",
    lkGrid = "Grid", lkFlow = "Flow", lkBorder = "Border", lkStack = "Stack"

  MouseAction* = enum
    maPress, maRelease, maMove

  MouseEvent* = object
    action*: MouseAction
    x*, y*: float
    button*: MouseButton
    clicks*: int
    mods*: uint16

  KeyEvent* = object
    key*: uint32
    mods*: uint16
    isRepeat*: bool

  Control* = ref object of RootObj
    id*: ControlId
    name*: string
    caption*: string
    parent*: Container
    win*: Window
    rect*: Rect                        # computed position (window coordinates).
    fixedX*, fixedY*: float            # position for the absolute layout.
    fixedWidth*, fixedHeight*: float   # 0 = preferred size.
    weight*: float                     # share of the free space (vertical/horizontal layouts).
    stretch*: bool                     # stretching along the cross axis.
    dock*: Dock                        # border layout.
    visible*: bool
    state*: ControlState
    tooltip*: string                   # tooltip.
    style*: Style
    hovered*, pressed*, focus*: bool
    focusable*: bool

  Container* = ref object of Control
    children*: seq[Control]
    layout*: LayoutKind
    columns*: int
    margin*: float        # < 0: theme value.
    spacing*: float       # < 0: theme value.
    activePage*: int      # stack layout / tabs (0-based).
    framed*: bool

  Window* = ref object of Control
    title*: string
    appliedTitle*: string
    width*, height*: int
    root*: Container
    dispatch*: DispatchProc
    theme*: Theme
    sdlWin*: SDL_Window
    sdlRen*: SDL_Renderer
    sdlId*: uint32
    drawing*: Drawing
    focusedControl*, hoveredControl*, capturedControl*: Control
    popup*: Control
    pressedOn*: array[MouseButton, Control]
    opened*, closed*, closeRequested*, dirty*: bool
    manualClose*: bool        # if true, the close box emits the event without closing (call closeWindow).
    mouseMoveEvents*: bool    # emit evMouseMove on every move (costly: disabled by default).
    sdlTextInputActive*: bool
    mouseX*, mouseY*: float
    hoverSince*: uint64
    tooltipShown*: bool
    caretVisible*: bool
    animating*: bool          # set during draw by a control that needs another frame (fades...)
    resizable*: bool          # the user may resize the window (default true)
    isModal*: bool            # modal window: blocks input to every other window while open
    modalFor*: Window         # owner of a modal window (it is centered on it)
    alwaysThreaded*: bool     # events go straight to a new thread, bypassing the dispatcher queue

var
  guiLock*: Lock
  registry*: seq[Control] = @[Control(nil)]
  allWindows*: seq[Window]
  eventQueue*: Channel[Event]
  wakeEvent*: uint32
  sdlReady*: bool
  lockDepth* {.threadvar.}: int
  activeWindow*: Window          # last window that received the focus.
  uiThreadId*: int               # id of the thread running the UI loop (0 = not running).
  directSpawn*: proc (e: Event) {.nimcall, gcsafe.}               # set by the UI loop (see alwaysThreaded).

initLock(guiLock)
open(eventQueue)

template guarded*(body: untyped) =
  # Re-entrant critical section on the control tree.
  {.cast(gcsafe).}:
    if lockDepth == 0: acquire(guiLock)
    inc lockDepth
    try:
      body
    finally:
      dec lockDepth
      if lockDepth == 0: release(guiLock)

proc stopPropagation*(ev: var Event) = ev.stopped = true
  # Stops propagation to the parents.

proc propagationStopped*(ev: Event): bool = ev.stopped

proc wakeUI*() =
  # Wakes the UI loop (thread-safe) so that it redraws.
  {.cast(gcsafe).}:
    if sdlReady and wakeEvent != 0:
      var e: SDL_Event
      cast[ptr SDL_UserEvent](addr e).typ = wakeEvent
      discard SDL_PushEvent(addr e)

proc markDirty*(c: Control) =
  if c != nil and c.win != nil: c.win.dirty = true

proc control*(id: ControlId): Control =
  # Raw access to the control (use inside `guarded`).
  let i = int(id)
  {.cast(gcsafe).}:
    if i > 0 and i < registry.len: result = registry[i]

template withControl*(id: ControlId, T: typedesc, c, body: untyped) =
  # Runs `body` under the lock if `id` denotes a control of type T, then redraws.
  block:
    var done0 = false
    guarded:
      let raw0 = control(id)
      when Control is T:   # T is exactly Control (not a subtype).
        if raw0 != nil:
          let c = raw0
          body
          markDirty(raw0)
          done0 = true
      else:
        if raw0 != nil and raw0 of T:
          let c = T(raw0)
          body
          markDirty(raw0)
          done0 = true
    if done0: wakeUI()

template readControl*(id: ControlId, T: typedesc, c, body: untyped) =
  # Reads under the lock if `id` denotes a control of type T.
  guarded:
    let raw0 = control(id)
    when Control is T:   # T is exactly Control (not a subtype).
      if raw0 != nil:
        let c = raw0
        body
    else:
      if raw0 != nil and raw0 of T:
        let c = T(raw0)
        body

proc initControl*(c: Control, caption = "") =
  c.caption = caption
  c.visible = true
  c.state = csActive
  c.stretch = true

# Called when the control is attached to a window (lets composite controls attach sub-controls).
method onAttach*(c: Control, w: Window) {.base.} = discard

proc attach*(c: Control, f: Window) =
  # Registers the control (and its descendants) and sets its window.
  {.cast(gcsafe).}:
    if int(c.id) == 0:
      c.id = ControlId(registry.len)
      registry.add c
  c.win = f
  c.onAttach(f)
  if c of Container:
    for e in Container(c).children: attach(e, f)

proc emit*(c: Control, kind: EventKind, index = 0, text = "", column = 0,
           x = 0.0, y = 0.0, button = mbNone, key = 0'u32, mods = 0'u16,
           dx = 0.0, dy = 0.0, isRepeat = false) =
  # Pushes an event onto the queue; the dispatcher will pop it.
  if c == nil or c.win == nil or int(c.id) <= 0: return
  var e = Event(window: c.win.id, id: c.id, current: c.id, kind: kind, index: index, column: column,
                    text: text, x: x, y: y, button: button, key: key,
                    modifiers: mods, dx: dx, dy: dy, isRepeat: isRepeat)
  {.cast(gcsafe).}:
    if sdlReady: e.timestamp = SDL_GetTicks()
    if c.win.alwaysThreaded and directSpawn != nil: directSpawn(e)
    else: eventQueue.send(e)

proc propagationChain*(id: ControlId): seq[ControlId] =
  # Propagation chain: target → parents → root → window.
  var c = control(id)
  if c == nil: return
  if c of Window: return @[id]
  let f = c.win
  while c != nil:
    result.add c.id
    c = c.parent
  if f != nil: result.add f.id

proc isActive*(c: Control): bool =
  # True if the control and all its parents are active and visible.
  var p = c
  while p != nil:
    if p.state != csActive or not p.visible: return false
    p = p.parent
  true

proc isGrayed*(c: Control): bool =
  var p = c
  while p != nil:
    if p.state == csGrayed: return true
    p = p.parent

proc textColor*(c: Control, t: Theme): Color =
  if c.isGrayed: t.textDisabled else: c.style.text.get(t.text)

proc radiusOf*(c: Control, t: Theme): float = c.style.radius.get(t.radius)

proc formatNumber*(v: float): string =
  if v == floor(v) and abs(v) < 1e15: $int64(v)
  else: formatFloat(v, ffDecimal, 3).strip(leading = false, chars = {'0'}).strip(leading = false, chars = {'.'})

# overridable methods

method draw*(c: Control, d: Drawing, t: Theme) {.base.} = discard

method preferredSize*(c: Control, d: Drawing, t: Theme): tuple[w, h: float] {.base.} =
  (100.0, t.controlHeight)

method onMouse*(c: Control, e: MouseEvent) {.base.} = discard

method onKey*(c: Control, e: KeyEvent): bool {.base.} = false      # true = key consumed

method onText*(c: Control, s: string) {.base.} = discard

method onWheel*(c: Control, dx, dy: float): bool {.base.} = false  # true = consumed

method onFocus*(c: Control, gained: bool) {.base.} = discard

method acceptsText*(c: Control): bool {.base.} = false

method acceptsTab*(c: Control): bool {.base.} = false  # true: Tab goes to onKey instead of moving the focus

method mouseCursor*(c: Control, x, y: float): int {.base.} = SDL_SYSTEM_CURSOR_DEFAULT

method valueText*(c: Control): string {.base.} = c.caption

method setValueText*(c: Control, v: string) {.base.} = c.caption = v

method valueNum*(c: Control): float {.base.} =
  try:
    result = parseFloat(c.valueText.strip)
  except ValueError:
    result = 0.0

method setValueNum*(c: Control, v: float) {.base.} = c.setValueText(formatNumber(v))

method typeName*(c: Control): string {.base.} = "Control"

method isDefaultButton*(c: Control): bool {.base.} = false

method isCancelButton*(c: Control): bool {.base.} = false

# Row / column under (x, y), 1-based (0 = none); copied into click events.
method hitInfo*(c: Control, x, y: float): tuple[index, column: int] {.base.} = (0, 0)

method onPopupChoice*(c: Control, i: int, text: string) {.base.} =
  # Called when the user picks an item of a drop-down list / menu opened by this control.
  emit(c, evSelection, index = i + 1, text = text)

method typeName*(c: Container): string = "Supercontrol"

method typeName*(c: Window): string = "Window"

proc marginOf*(k: Container, t: Theme): float = (if k.margin >= 0: k.margin else: t.margin)

proc spacingOf*(k: Container, t: Theme): float = (if k.spacing >= 0: k.spacing else: t.spacing)

method contentArea*(k: Container, t: Theme): Rect {.base.} = k.rect.shrink(k.marginOf(t))

method childShown*(k: Container, i: int): bool {.base.} =
  k.layout != lkStack or i == k.activePage

proc prefSizeOf*(c: Control, d: Drawing, t: Theme): tuple[w, h: float] =
  result = c.preferredSize(d, t)
  if c.fixedWidth > 0: result.w = c.fixedWidth
  if c.fixedHeight > 0: result.h = c.fixedHeight

proc layoutControl*(c: Control, r: Rect, d: Drawing, t: Theme)

proc placeCross(e: Control, r: Rect, vertical: bool, d: Drawing, t: Theme) =
  # Places `e` inside r honouring `stretch` on the cross axis.
  if e.stretch:
    layoutControl(e, r, d, t)
  else:
    let p = prefSizeOf(e, d, t)
    if vertical: layoutControl(e, rect(r.x, r.y, min(p.w, r.w), r.h), d, t)
    else: layoutControl(e, rect(r.x, r.y + max(0.0, (r.h - p.h) / 2), r.w, min(p.h, r.h)), d, t)

method layoutChildren*(k: Container, d: Drawing, t: Theme) {.base.} =
  let z = k.contentArea(t)
  let sp = k.spacingOf(t)
  var vis: seq[int]
  for i, e in k.children:
    if e.visible and k.childShown(i): vis.add i
  case k.layout
  of lkAbsolute:
    for i in vis:
      let e = k.children[i]
      let p = prefSizeOf(e, d, t)
      layoutControl(e, rect(z.x + e.fixedX, z.y + e.fixedY, p.w, p.h), d, t)
  of lkStack:
    for i in vis: layoutControl(k.children[i], z, d, t)
  of lkVertical, lkHorizontal:
    let isVert = k.layout == lkVertical
    var total, weight = 0.0
    var sizes: seq[float]
    for i in vis:
      let p = prefSizeOf(k.children[i], d, t)
      let s = if isVert: p.h else: p.w
      sizes.add s
      total += s
      weight += k.children[i].weight
    total += sp * float(max(0, vis.len - 1))
    let remaining = (if isVert: z.h else: z.w) - total
    var pos = if isVert: z.y else: z.x
    for j, i in vis:
      let e = k.children[i]
      var s = sizes[j]
      if remaining > 0 and weight > 0: s += remaining * e.weight / weight
      if isVert:
        let w = if e.fixedWidth > 0: min(e.fixedWidth, z.w) else: z.w
        placeCross(e, rect(z.x, pos, w, s), true, d, t)
      else:
        let h = if e.fixedHeight > 0: min(e.fixedHeight, z.h) else: z.h
        placeCross(e, rect(pos, z.y, s, h), false, d, t)
      pos += s + sp
  of lkGrid:
    let cols = max(1, k.columns)
    let cw = (z.w - sp * float(cols - 1)) / float(cols)
    var y = z.y
    var j = 0
    while j < vis.len:
      var hmax = 0.0
      for m in j ..< min(j + cols, vis.len): hmax = max(hmax, prefSizeOf(k.children[vis[m]], d, t).h)
      for m in j ..< min(j + cols, vis.len):
        let col = m - j
        placeCross(k.children[vis[m]], rect(z.x + float(col) * (cw + sp), y, cw, hmax), true, d, t)
      y += hmax + sp
      j += cols
  of lkFlow:
    var x = z.x
    var y = z.y
    var hl = 0.0
    for i in vis:
      let e = k.children[i]
      let p = prefSizeOf(e, d, t)
      if x > z.x and x + p.w > z.x + z.w:
        x = z.x
        y += hl + sp
        hl = 0
      layoutControl(e, rect(x, y, p.w, p.h), d, t)
      x += p.w + sp
      hl = max(hl, p.h)
  of lkBorder:
    var r = z
    for dk in [dkTop, dkBottom, dkLeft, dkRight]:
      for i in vis:
        let e = k.children[i]
        if e.dock != dk: continue
        let p = prefSizeOf(e, d, t)
        case dk
        of dkTop:
          layoutControl(e, rect(r.x, r.y, r.w, p.h), d, t)
          r.y += p.h + sp
          r.h = max(0.0, r.h - p.h - sp)
        of dkBottom:
          layoutControl(e, rect(r.x, r.y + r.h - p.h, r.w, p.h), d, t)
          r.h = max(0.0, r.h - p.h - sp)
        of dkLeft:
          layoutControl(e, rect(r.x, r.y, p.w, r.h), d, t)
          r.x += p.w + sp
          r.w = max(0.0, r.w - p.w - sp)
        of dkRight:
          layoutControl(e, rect(r.x + r.w - p.w, r.y, p.w, r.h), d, t)
          r.w = max(0.0, r.w - p.w - sp)
        else: discard
    for i in vis:
      if k.children[i].dock == dkCenter: layoutControl(k.children[i], r, d, t)

proc layoutControl*(c: Control, r: Rect, d: Drawing, t: Theme) =
  c.rect = r
  if c of Container: Container(c).layoutChildren(d, t)

method preferredSize*(k: Container, d: Drawing, t: Theme): tuple[w, h: float] =
  let m = k.marginOf(t)
  let sp = k.spacingOf(t)
  var w, h = 0.0
  var n = 0
  case k.layout
  of lkVertical:
    for e in k.children:
      if not e.visible: continue
      let p = prefSizeOf(e, d, t)
      w = max(w, p.w)
      h += p.h
      inc n
    h += sp * float(max(0, n - 1))
  of lkHorizontal, lkFlow:
    for e in k.children:
      if not e.visible: continue
      let p = prefSizeOf(e, d, t)
      h = max(h, p.h)
      w += p.w
      inc n
    w += sp * float(max(0, n - 1))
  of lkGrid:
    let cols = max(1, k.columns)
    var cw = 0.0
    var rowH = 0.0
    for e in k.children:
      if not e.visible: continue
      let p = prefSizeOf(e, d, t)
      cw = max(cw, p.w)
      rowH = max(rowH, p.h)
      inc n
      if n mod cols == 0:
        h += rowH + sp
        rowH = 0
    h += rowH
    if n mod cols == 0 and n > 0: h -= sp
    w = cw * float(cols) + sp * float(cols - 1)
  of lkAbsolute:
    for e in k.children:
      if not e.visible: continue
      let p = prefSizeOf(e, d, t)
      w = max(w, e.fixedX + p.w)
      h = max(h, e.fixedY + p.h)
  of lkStack:
    for e in k.children:
      let p = prefSizeOf(e, d, t)
      w = max(w, p.w)
      h = max(h, p.h)
  of lkBorder:
    var wc, hc = 0.0
    for e in k.children:
      if not e.visible: continue
      let p = prefSizeOf(e, d, t)
      case e.dock
      of dkTop, dkBottom: h += p.h + sp; w = max(w, p.w)
      of dkLeft, dkRight: wc += p.w + sp; hc = max(hc, p.h)
      of dkCenter: wc += p.w; hc = max(hc, p.h)
    w = max(w, wc)
    h += hc
  (w + 2*m, h + 2*m)

# tree: drawing, hit testing

# Containers may keep some areas for themselves (e.g. a panel's scrollbars).
method hitChildren*(k: Container, x, y: float): bool {.base.} = true

# Drawn after (over) the children, inside the container's clip.
method drawOverlay*(k: Container, d: Drawing, t: Theme) {.base.} = discard

# Called on every ancestor when a descendant receives the focus (e.g. to scroll it into view).
method onDescendantFocus*(k: Container, c: Control) {.base.} = discard

proc controlAt*(c: Control, x, y: float): Control =
  # Deepest visible control under point (x, y).
  if c == nil or not c.visible or not c.rect.containsPoint(x, y): return nil
  if c of Container and Container(c).hitChildren(x, y):
    let k = Container(c)
    for i in countdown(k.children.high, 0):
      if k.childShown(i):
        let r = controlAt(k.children[i], x, y)
        if r != nil: return r
  c

proc drawTree*(c: Control, d: Drawing, t: Theme) =
  if not c.visible or c.rect.w <= 0 or c.rect.h <= 0: return
  c.draw(d, t)
  if c of Container:
    let k = Container(c)
    d.pushClip(k.rect)
    for i, e in k.children:
      if k.childShown(i) and not d.isClippedOut(e.rect):  # skip what cannot be seen!
        drawTree(e, d, t)
    k.drawOverlay(d, t)
    d.popClip()

# focus and popups

proc setFocusInternal*(f: Window, c: Control) =
  if f == nil or f.focusedControl == c: return
  let previous = f.focusedControl
  if previous != nil:
    previous.focus = false
    previous.onFocus(false)
    emit(previous, evFocusLost)
  f.focusedControl = c
  if c != nil:
    c.focus = true
    c.onFocus(true)
    emit(c, evFocusGained)
    var p = c.parent
    while p != nil:
      p.onDescendantFocus(c)
      p = p.parent
  f.dirty = true

proc collectFocusables(c: Control, acc: var seq[Control]) =
  if not c.visible: return
  if c.focusable and c.isActive: acc.add c
  if c of Container:
    let k = Container(c)
    for i, e in k.children:
      if k.childShown(i): collectFocusables(e, acc)

proc focusNext*(f: Window, direction: int) =
  var l: seq[Control]
  collectFocusables(f.root, l)
  if l.len == 0: return
  var i = l.find(f.focusedControl)
  i = if i < 0: (if direction > 0: 0 else: l.high) else: (i + direction + l.len) mod l.len
  f.setFocusInternal(l[i])

proc openPopup*(f: Window, p: Control, r: Rect) =
  # Shows `p` as an overlay (drop-down list, menu). A click outside closes it.
  p.win = f
  p.rect = r
  f.popup = p
  f.dirty = true

proc closePopup*(f: Window) =
  if f != nil:
    f.popup = nil
    f.dirty = true

# internal scroll indicator

proc drawScrollIndicator*(d: Drawing, t: Theme, area: Rect, total, span, pos: float) =
  if total <= span or area.h <= 0: return
  let lp = max(18.0, area.h * span / total)
  let y = area.y + (area.h - lp) * clamp(pos / (total - span), 0.0, 1.0)
  d.fillRoundRect(rect(area.x + area.w - 6, y, 4, lp), 2, withAlpha(t.textSecondary, 140))

proc scrollFromBar*(area: Rect, total, span, y: float): float =
  if total <= span: return 0
  let lp = max(18.0, area.h * span / total)
  clamp((y - area.y - lp / 2) / max(1.0, area.h - lp), 0.0, 1.0) * (total - span)

# construction

proc newContainer*(layout = lkVertical, margin = -1.0, spacing = -1.0, columns = 2): Container =
  result = Container(layout: layout, margin: margin, spacing: spacing, columns: columns)
  initControl(result)

proc newSupercontrol*(layout = lkHorizontal, spacing = -1.0): Container =
  # Supercontrol: grouping without margin or decoration.
  newContainer(layout, 0, spacing)

proc newWindow*(title: string, width = 800, height = 600,
                      dispatch: DispatchProc = nil, theme = themeNative(),
                      layout = lkVertical): Window =
  # Creates a window (realized on screen by the UI loop, from any thread).
  result = Window(title: title, width: width, height: height, dispatch: dispatch, theme: theme,
                  resizable: true)
  initControl(result, title)
  result.root = newContainer(layout)
  let f = result
  guarded:
    attach(f, f)
    attach(f.root, f)
    allWindows.add f
  wakeUI()

proc addChild*[T: Control](parent: Container, c: T): T =
  # Adds a control (or container) to a container; returns the control (its id: `.id`).
  guarded:
    if c.parent != nil:
      let cc: Control = c
      let i = c.parent.children.find(cc)
      if i >= 0: c.parent.children.delete(i)
    c.parent = parent
    parent.children.add c
    attach(c, parent.win)
    markDirty(parent)
  wakeUI()
  c

proc addChild*[T: Control](f: Window, c: T): T = addChild(f.root, c)

proc addChild*(parentId: ControlId, c: Control): ControlId =
  # Id-based add (usable from a callback).
  var p: Container
  guarded:
    let b = control(parentId)
    if b of Container: p = Container(b)
    elif b of Window: p = Window(b).root
  if p == nil: return NoControl
  discard addChild(p, c)
  c.id
