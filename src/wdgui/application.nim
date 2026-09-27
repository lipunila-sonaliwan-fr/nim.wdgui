# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
# UI loop (UI thread) and event dispatcher.
#
# * The UI thread reads SDL events, updates the visual state of controls and PUSHES
#   `Event`s into `eventQueue`. It never runs user code, so the interface
#   never freezes during a long process.
# * The dispatcher thread POPS events; each pop starts a dedicated thread
#   (default mode) that calls the window handler for the target, then for each
#   parent up to the window, unless `ev.stopPropagation()` was called.
import std/[atomics, typedthreads]
import ../sdl3, core

type
  DispatchMode* = enum
    dmThreadPerEvent   # one dedicated thread per popped event (default).
    dmSequential       # in-order processing, on the dispatcher thread.

var
  dispatchMode* = dmThreadPerEvent
  maxConcurrentThreads* = 64
  quitFlag: Atomic[bool]
  dispatchThread: Thread[void]
  uiThread {.used.}: Thread[void]
  cursors: array[12, SDL_Cursor]
  currentCursor = -1

# dispatcher

proc worker(ev: Event) {.thread.} =
  {.cast(gcsafe).}:
    var e = ev
    var chain: seq[ControlId]
    var cb: DispatchProc = nil
    guarded:
      chain = propagationChain(e.id)
      let f = control(e.window)
      if f != nil and f of Window: cb = Window(f).dispatch
    if cb.isNil: return
    for cid in chain:
      e.current = cid
      try:
        cb(e)
      except CatchableError as ex:
        stderr.writeLine("wdgui: exception in event handler: ", ex.msg)
      if e.propagationStopped: break

proc reap(activeThreads: var seq[ptr Thread[Event]], waitAll: bool) =
  var i = 0
  while i < activeThreads.len:
    if waitAll or not running(activeThreads[i][]):
      joinThread(activeThreads[i][])
      deallocShared(activeThreads[i])
      activeThreads.del(i)
    else:
      inc i

proc dispatchLoop() {.thread.} =
  {.cast(gcsafe).}:
    var activeThreads: seq[ptr Thread[Event]]
    while true:
      let ev = eventQueue.recv()              # pop (blocking).
      if int(ev.id) < 0: break                # stop sentinel.
      reap(activeThreads, false)
      if dispatchMode == dmSequential:
        worker(ev)
        continue
      while activeThreads.len >= max(1, maxConcurrentThreads):
        joinThread(activeThreads[0][])
        deallocShared(activeThreads[0])
        activeThreads.delete(0)
      let th = cast[ptr Thread[Event]](allocShared0(sizeof(Thread[Event])))
      createThread(th[], worker, ev)     # thread dedicated to this event.
      activeThreads.add th
    reap(activeThreads, true)

var spawned: seq[ptr Thread[Event]]

proc spawnNow(e: Event) {.nimcall, gcsafe.} =
  # Runs an event on a new thread immediately (windows with `alwaysThreaded`, e.g. dialogs):
  # they keep working even while the dispatcher is blocked by a handler waiting for them.
  guarded:
    reap(spawned, false)
    let th = cast[ptr Thread[Event]](allocShared0(sizeof(Thread[Event])))
    createThread(th[], worker, e)
    spawned.add th

proc pendingEvents*(): int =
  # Number of events pushed but not yet popped.
  {.cast(gcsafe).}:
    result = eventQueue.peek()

# UI helpers

proc topModal(): Window =
  for i in countdown(allWindows.high, 0):
    let w = allWindows[i]
    if w.isModal and w.opened and not w.closeRequested: return w

proc blocked(f: Window, bringToFront = false): bool =
  # True when a modal window other than `f` is open (it then gets the focus back).
  let m = topModal()
  result = m != nil and m != f
  if result and bringToFront and m.sdlWin != nil: discard SDL_RaiseWindow(m.sdlWin)

proc windowFromSdl(id: uint32): Window =
  for f in allWindows:
    if f.sdlWin != nil and f.sdlId == id: return f

proc buttonFrom(b: uint8): MouseButton =
  case b
  of 1: mbLeft
  of 2: mbMiddle
  of 3: mbRight
  else: mbNone

proc updateCursor(c: Control, x, y: float) =
  var id = SDL_SYSTEM_CURSOR_DEFAULT
  if c != nil and c.isActive: id = c.mouseCursor(x, y)
  if id < 0 or id > cursors.high: id = 0
  if id != currentCursor:
    if cursors[id] == nil: cursors[id] = SDL_CreateSystemCursor(id.cint)
    if cursors[id] != nil: discard SDL_SetCursor(cursors[id])
    currentCursor = id

proc updateHover(f: Window, c: Control, x, y: float) =
  if c == f.hoveredControl: return
  let a = f.hoveredControl
  if a != nil:
    a.hovered = false
    emit(a, evMouseLeave, x = x, y = y)
  f.hoveredControl = c
  f.hoverSince = SDL_GetTicks()
  f.tooltipShown = false
  if c != nil:
    c.hovered = true
    emit(c, evMouseEnter, x = x, y = y)
  f.dirty = true

proc findButton(c: Control, isCancel: bool): Control =
  if not c.visible or not c.isActive: return nil
  if (isCancel and c.isCancelButton) or (not isCancel and c.isDefaultButton): return c
  if c of Container:
    let k = Container(c)
    for i, e in k.children:
      if k.childShown(i):
        let r = findButton(e, isCancel)
        if r != nil: return r

proc realize(f: Window) =
  let flags = if f.resizable: SDL_WINDOW_RESIZABLE else: 0'u64
  f.sdlWin = SDL_CreateWindow(f.title.cstring, f.width.cint, f.height.cint, flags)
  if f.sdlWin == nil:
    stderr.writeLine("wdgui: cannot create window: ", $SDL_GetError())
    f.closed = true
    return
  f.sdlRen = SDL_CreateRenderer(f.sdlWin, nil)
  discard SDL_SetRenderVSync(f.sdlRen, 1)
  discard SDL_SetRenderDrawBlendMode(f.sdlRen, SDL_BLENDMODE_BLEND)
  f.sdlId = SDL_GetWindowID(f.sdlWin)
  let owner = f.modalFor
  if owner != nil and owner.sdlWin != nil:
    # child window of its owner, centered horizontally, in the upper third
    discard SDL_SetWindowParent(f.sdlWin, owner.sdlWin)
    if f.isModal: discard SDL_SetWindowModal(f.sdlWin, true)
    var ox, oy, ow, oh: cint
    discard SDL_GetWindowPosition(owner.sdlWin, addr ox, addr oy)
    discard SDL_GetWindowSize(owner.sdlWin, addr ow, addr oh)
    discard SDL_SetWindowPosition(f.sdlWin, cint(int(ox) + (int(ow) - f.width) div 2),
                                  cint(int(oy) + max(0, (int(oh) - f.height) div 3)))
  if f.isModal:
    discard SDL_RaiseWindow(f.sdlWin)
    activeWindow = f
  f.drawing = newDrawing(f.sdlRen)
  f.appliedTitle = f.title
  f.opened = true
  f.dirty = true
  emit(f, evWindowOpen)

proc destroyWindow(f: Window) =
  if f.sdlWin != nil:
    if f.sdlTextInputActive: discard SDL_StopTextInput(f.sdlWin)
    if f.drawing != nil: f.drawing.dispose()
    SDL_DestroyRenderer(f.sdlRen)
    SDL_DestroyWindow(f.sdlWin)
  f.sdlWin = nil
  f.sdlRen = nil
  f.drawing = nil
  f.opened = false
  f.closed = true

proc drawTooltip(f: Window, d: Drawing, t: Theme) =
  let c = f.hoveredControl
  let w = d.textWidth(c.tooltip) + 16
  let h = d.textHeight + 10
  var x = f.mouseX + 12
  var y = f.mouseY + 20
  if x + w > float(f.width): x = float(f.width) - w - 2
  if y + h > float(f.height): y = f.mouseY - h - 6
  let r = rect(x, y, w, h)
  d.shadow(r, 4, t.shadow)
  d.fillRoundRect(r, 4, t.border)
  d.fillRoundRect(r.shrink(1), 3, if t.dark: t.surface else: t.fieldBg)
  d.textIn(r, c.tooltip, t.text, alCenter)

proc drawWindow(f: Window) =
  f.animating = false
  let d = f.drawing
  let t = f.theme
  d.configure(t)
  if f.appliedTitle != f.title:
    discard SDL_SetWindowTitle(f.sdlWin, f.title.cstring)
    f.appliedTitle = f.title
  var w, h: cint
  discard SDL_GetWindowSize(f.sdlWin, addr w, addr h)
  f.width = int(w)
  f.height = int(h)
  layoutControl(f.root, rect(0, 0, float(w), float(h)), d, t)
  d.clearWith(t.windowBg)
  drawTree(f.root, d, t)
  if f.popup != nil or (f.tooltipShown and f.hoveredControl != nil and f.hoveredControl.tooltip.len > 0):
    let saved = d.suspendClip()
    if f.popup != nil: f.popup.draw(d, t)
    elif f.tooltipShown and f.hoveredControl != nil and f.hoveredControl.tooltip.len > 0: drawTooltip(f, d, t)
    d.restoreClip(saved)
  discard SDL_RenderPresent(f.sdlRen)
  f.dirty = f.animating      # a control asked for another frame (animation)
# SDL event translation
proc handleEvent(e: var SDL_Event) =
  let typ = cast[ptr SDL_CommonEvent](addr e).typ
  let mods = SDL_GetModState()
  case typ
  of SDL_EVENT_QUIT:
    for f in allWindows:
      if f.opened and not f.manualClose: f.closeRequested = true
  of SDL_EVENT_WINDOW_SHOWN .. SDL_EVENT_WINDOW_CLOSE_REQUESTED:
    let we = cast[ptr SDL_WindowEvent](addr e)
    let f = windowFromSdl(we.windowID)
    if f == nil: return
    f.dirty = true
    case typ
    of SDL_EVENT_WINDOW_CLOSE_REQUESTED:
      if blocked(f, true): return
      emit(f, evWindowClose)
      if not f.manualClose: f.closeRequested = true
    of SDL_EVENT_WINDOW_RESIZED:
      emit(f, evWindowResize, x = float(we.data1), y = float(we.data2))
    of SDL_EVENT_WINDOW_FOCUS_GAINED:
      if blocked(f, true): return
      activeWindow = f
      emit(f, evWindowActivate)
    of SDL_EVENT_WINDOW_FOCUS_LOST:
      closePopup(f)
      emit(f, evWindowDeactivate)
    of SDL_EVENT_WINDOW_MOUSE_LEAVE: updateHover(f, nil, f.mouseX, f.mouseY)
    else: discard
  of SDL_EVENT_MOUSE_MOTION:
    let me = cast[ptr SDL_MouseMotionEvent](addr e)
    let f = windowFromSdl(me.windowID)
    if f == nil or blocked(f): return
    let x = float(me.x)
    let y = float(me.y)
    f.mouseX = x
    f.mouseY = y
    let inPopup = f.popup != nil and f.popup.rect.containsPoint(x, y)
    let under = if inPopup: nil else: controlAt(f.root, x, y)
    let target = if f.capturedControl != nil: f.capturedControl
                elif inPopup: f.popup
                else: under
    if not inPopup: updateHover(f, under, x, y)
    if f.tooltipShown:
      f.tooltipShown = false
      f.hoverSince = SDL_GetTicks()
    updateCursor(target, x, y)
    if target != nil and (target == f.popup or target.isActive):
      target.onMouse(MouseEvent(action: maMove, x: x, y: y, mods: mods))
    if f.mouseMoveEvents and target != nil and target != f.popup:
      emit(target, evMouseMove, x = x, y = y, mods = mods)
    f.dirty = true
  of SDL_EVENT_MOUSE_BUTTON_DOWN:
    let be = cast[ptr SDL_MouseButtonEvent](addr e)
    let f = windowFromSdl(be.windowID)
    if f == nil or blocked(f, true): return
    activeWindow = f
    let x = float(be.x)
    let y = float(be.y)
    let b = buttonFrom(be.button)
    f.dirty = true
    f.tooltipShown = false
    if f.popup != nil:
      if f.popup.rect.containsPoint(x, y):
        f.popup.onMouse(MouseEvent(action: maPress, x: x, y: y, button: b, clicks: int(be.clicks), mods: mods))
        return
      closePopup(f)
      return
    let c = controlAt(f.root, x, y)
    if c == nil or not c.isActive: return
    var fc = c
    while fc != nil and not fc.focusable: fc = fc.parent
    if b == mbLeft and fc != nil: setFocusInternal(f, fc)
    f.capturedControl = c
    f.pressedOn[b] = c
    if b == mbLeft: c.pressed = true
    let hi = c.hitInfo(x, y)
    c.onMouse(MouseEvent(action: maPress, x: x, y: y, button: b, clicks: int(be.clicks), mods: mods))
    emit(c, evButtonDown, x = x, y = y, button = b, mods = mods, index = hi.index, column = hi.column)
  of SDL_EVENT_MOUSE_BUTTON_UP:
    let be = cast[ptr SDL_MouseButtonEvent](addr e)
    let f = windowFromSdl(be.windowID)
    if f == nil or blocked(f): return
    let x = float(be.x)
    let y = float(be.y)
    let b = buttonFrom(be.button)
    f.dirty = true
    if f.capturedControl == nil and f.popup != nil:
      if f.popup.rect.containsPoint(x, y):
        f.popup.onMouse(MouseEvent(action: maRelease, x: x, y: y, button: b, clicks: int(be.clicks), mods: mods))
      return
    let c = if f.capturedControl != nil: f.capturedControl else: controlAt(f.root, x, y)
    f.capturedControl = nil
    if c == nil: return
    c.pressed = false
    let under = controlAt(f.root, x, y)
    let hi = c.hitInfo(x, y)
    c.onMouse(MouseEvent(action: maRelease, x: x, y: y, button: b, clicks: int(be.clicks), mods: mods))
    emit(c, evButtonUp, x = x, y = y, button = b, mods = mods, index = hi.index, column = hi.column)
    if under == c and f.pressedOn[b] == c and c.isActive:
      let isDouble = be.clicks >= 2
      let kind = case b
                   of mbLeft: (if isDouble: evDoubleClick else: evClick)
                   of mbRight: (if isDouble: evRightDoubleClick else: evRightClick)
                   of mbMiddle: (if isDouble: evMiddleDoubleClick else: evMiddleClick)
                   of mbNone: evNone
      if kind != evNone:
        emit(c, kind, x = x, y = y, button = b, mods = mods, index = hi.index, column = hi.column)
    f.pressedOn[b] = nil
  of SDL_EVENT_MOUSE_WHEEL:
    let we = cast[ptr SDL_MouseWheelEvent](addr e)
    let f = windowFromSdl(we.windowID)
    if f == nil or blocked(f): return
    var dx = float(we.x)
    var dy = float(we.y)
    if we.direction == SDL_MOUSEWHEEL_FLIPPED:
      dx = -dx
      dy = -dy
    f.dirty = true
    if f.popup != nil and f.popup.rect.containsPoint(f.mouseX, f.mouseY):
      discard f.popup.onWheel(dx, dy)
      return
    let c = controlAt(f.root, f.mouseX, f.mouseY)
    var p = c
    while p != nil and not (p.isActive and p.onWheel(dx, dy)): p = p.parent
    if c != nil: emit(c, evWheel, x = f.mouseX, y = f.mouseY, dx = dx, dy = dy, mods = mods)
  of SDL_EVENT_KEY_DOWN, SDL_EVENT_KEY_UP:
    let ke = cast[ptr SDL_KeyboardEvent](addr e)
    let f = windowFromSdl(ke.windowID)
    if f == nil or blocked(f): return
    f.dirty = true
    let target: Control = if f.focusedControl != nil: f.focusedControl else: f
    if typ == SDL_EVENT_KEY_UP:
      emit(target, evKeyUp, key = ke.key, mods = ke.modifiers)
      return
    let ek = KeyEvent(key: ke.key, mods: ke.modifiers, isRepeat: ke.repeat)
    if f.popup != nil:
      if ke.key == SDLK_ESCAPE:
        closePopup(f)
        return
      if f.popup.onKey(ek): return
    var consumed = false
    if ke.key == SDLK_TAB and (ke.modifiers and KMOD_CTRL) == 0 and
       not (f.focusedControl != nil and f.focusedControl.isActive and f.focusedControl.acceptsTab):
      focusNext(f, if (ke.modifiers and KMOD_SHIFT) != 0: -1 else: 1)
      consumed = true
    elif f.focusedControl != nil and f.focusedControl.isActive:
      consumed = f.focusedControl.onKey(ek)
    if not consumed and (ke.key == SDLK_RETURN or ke.key == SDLK_KP_ENTER):
      let b = findButton(f.root, false)
      if b != nil: emit(b, evClick, button = mbLeft)
    elif not consumed and ke.key == SDLK_ESCAPE:
      let b = findButton(f.root, true)
      if b != nil: emit(b, evClick, button = mbLeft)
    emit(target, evKeyDown, key = ke.key, mods = ke.modifiers, isRepeat = ke.repeat)
  of SDL_EVENT_TEXT_INPUT:
    let te = cast[ptr SDL_TextInputEvent](addr e)
    let f = windowFromSdl(te.windowID)
    if f == nil or te.text == nil or blocked(f): return
    let s = $te.text
    let c = f.focusedControl
    if c != nil and c.isActive and c.acceptsText:
      c.onText(s)
      emit(c, evTextInput, text = s)
    f.dirty = true
  else: discard   # wakeEvent and others: just one loop pass (redraw).

proc tick() =
  let nowTicks = SDL_GetTicks()
  for f in allWindows:
    if not f.opened: continue
    let s = f.hoveredControl
    if s != nil and s.tooltip.len > 0 and not f.tooltipShown and f.popup == nil and
       nowTicks - f.hoverSince > 600:
      f.tooltipShown = true
      f.dirty = true
    let c = f.focusedControl
    let wantsText = c != nil and c.isActive and c.acceptsText
    if wantsText != f.sdlTextInputActive:
      if wantsText: discard SDL_StartTextInput(f.sdlWin)
      else: discard SDL_StopTextInput(f.sdlWin)
      f.sdlTextInputActive = wantsText
    if wantsText:
      let blink = (nowTicks div 530) mod 2 == 0
      if blink != f.caretVisible:
        f.caretVisible = blink
        f.dirty = true

# UI loop

proc uiLoop() {.thread.} =
  {.cast(gcsafe).}:
    if not SDL_Init(SDL_INIT_VIDEO):
      stderr.writeLine("wdgui: SDL_Init failed: ", $SDL_GetError())
      quitFlag.store(true)
      return
    when defined(sdlttf):
      if not TTF_Init(): stderr.writeLine("wdgui: TTF_Init failed, using bitmap font")
    guarded:
      wakeEvent = SDL_RegisterEvents(1)
      directSpawn = spawnNow
      uiThreadId = getThreadId()
      sdlReady = true
    var hadWindow = false
    while not quitFlag.load:
      var finished = false
      guarded:
        var openCount = 0
        for f in allWindows:
          if f.closeRequested and not f.closed: destroyWindow(f)
          elif not f.closed and f.sdlWin == nil: realize(f)
          if f.opened: inc openCount
        if openCount > 0: hadWindow = true
        elif hadWindow: finished = true
      if finished: break
      var e: SDL_Event
      if SDL_WaitEventTimeout(addr e, 16):
        guarded: handleEvent(e)
        while SDL_PollEvent(addr e):
          guarded: handleEvent(e)
      guarded:
        tick()
        for f in allWindows:
          if f.opened and f.dirty: drawWindow(f)
    guarded:
      for f in allWindows:
        if not f.closed: destroyWindow(f)
      sdlReady = false
      directSpawn = nil
      uiThreadId = 0
    reap(spawned, true)
    for c in cursors:
      if c != nil: SDL_DestroyCursor(c)
    SDL_Quit()

proc stopDispatcher() =
  eventQueue.send(Event(kind: evNone, id: ControlId(-1)))
  joinThread(dispatchThread)

proc runApplication*() =
  # Starts the interface: the UI loop runs on the calling thread (mandatory on macOS:
  # call it from the main thread); the dispatcher runs on its own thread.
  # Returns when every window is closed or after `quitApplication()`.
  quitFlag.store(false)
  createThread(dispatchThread, dispatchLoop)
  uiLoop()
  stopDispatcher()

proc runApplicationInBackground*() =
  # Non-blocking variant: the UI loop runs on a dedicated thread (Windows / Linux).
  # On macOS Cocoa requires the main thread, so this procedure then behaves
  # like `runApplication` (blocking).
  when defined(macosx):
    runApplication()
  else:
    quitFlag.store(false)
    createThread(dispatchThread, dispatchLoop)
    createThread(uiThread, uiLoop)

proc waitApplicationEnd*() =
  # Waits for the end of an application started with `runApplicationInBackground`.
  when not defined(macosx):
    joinThread(uiThread)
    stopDispatcher()

proc quitApplication*() =
  # Closes every window and ends the UI loop (callable from any thread).
  guarded:
    for f in allWindows: f.closeRequested = true
  quitFlag.store(true)
  wakeUI()
