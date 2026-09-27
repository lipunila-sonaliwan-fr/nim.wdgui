# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
# Panel: a scrollable container. Its children (controls or nested layouts) keep their
# natural size; a horizontal and a vertical scrollbar give access to the parts that do
# not fit. The scrollbars look and behave like macOS ones:
#
# * the thumb is proportional to the visible part of the content (viewport / content);
# * `smAlways` (default): "Show scroll bars: Always" — a light track, a gray pill thumb
#   that darkens on hover; the bars take their own space (15 px);
# * `smAutomatic`: "Show scroll bars: Automatically" — overlay bars that appear while
#   scrolling and fade out after about a second; pointing at a bar widens its thumb and
#   reveals its track; they take no space;
# * `smHidden`: no bar at all, the content still scrolls with the wheel / trackpad;
# * dragging the thumb scrolls; clicking the track jumps one page (Alt/Option-click
#   jumps to the clicked spot, as with the macOS "Jump to the spot" option);
# * wheel and trackpad scroll smoothly on both axes; Shift+wheel scrolls horizontally;
#   a panel that cannot scroll in a direction lets its parent panel scroll instead.
import ../sdl3, core

type
  ScrollbarMode* = enum
    smAlways = "Always", smAutomatic = "Automatic", smHidden = "Hidden"

  DragBar = enum
    dbNone, dbVertical, dbHorizontal

  Panel* = ref object of Container
    scrollbars*: ScrollbarMode
    scrollX*, scrollY*: float     # current offset of the content (pixels).
    lineStep*: float              # pixels per wheel notch.
    contentW*, contentH*: float   # natural size of the content (computed at layout).
    maxX, maxY: float
    showV, showH: bool
    viewport: Rect
    drag: DragBar
    dragOffset: float
    hoverV, hoverH: bool
    lastActivity: uint64

const
  barSpace = 15.0        # thickness of an "Always" bar.
  overlaySpace = 14.0    # hover area of an "Automatic" (overlay) bar.
  minThumb = 18.0
  showDelay = 900'u64    # automatic mode: fully visible for this long after activity.
  fadeTime = 350'u64     # ... then fades out during this time.

proc newPanel*(layout = lkVertical, scrollbars = smAlways, margin = -1.0, spacing = -1.0,
               columns = 2): Panel =
  result = Panel(layout: layout, scrollbars: scrollbars, margin: margin, spacing: spacing,
                 columns: columns, lineStep: 40)
  initControl(result)

method typeName*(p: Panel): string = "Panel"

# geometry

proc thickness(p: Panel): float =
  if p.scrollbars == smAlways: barSpace else: overlaySpace

proc computeBars(p: Panel) =
  # Decides which bars are needed and computes the viewport.
  let r = p.rect
  let space = if p.scrollbars == smAlways: barSpace else: 0.0
  var needV = p.contentH > r.h + 0.5
  let needH = p.contentW > r.w - (if needV: space else: 0.0) + 0.5
  if needH and not needV: needV = p.contentH > r.h - space + 0.5
  p.showV = needV and p.scrollbars != smHidden
  p.showH = needH and p.scrollbars != smHidden
  p.viewport = rect(r.x, r.y,
                    max(0.0, r.w - (if p.showV: space else: 0.0)),
                    max(0.0, r.h - (if p.showH: space else: 0.0)))
  p.maxX = max(0.0, p.contentW - p.viewport.w)
  p.maxY = max(0.0, p.contentH - p.viewport.h)

proc clampScroll(p: Panel) =
  p.scrollX = clamp(p.scrollX, 0.0, p.maxX)
  p.scrollY = clamp(p.scrollY, 0.0, p.maxY)

proc vTrack(p: Panel): Rect =
  let r = p.rect
  let th = p.thickness
  rect(r.x + r.w - th, r.y, th, max(0.0, r.h - (if p.showH: th else: 0.0)))

proc hTrack(p: Panel): Rect =
  let r = p.rect
  let th = p.thickness
  rect(r.x, r.y + r.h - th, max(0.0, r.w - (if p.showV: th else: 0.0)), th)

proc thumbV(p: Panel): Rect =
  # Thumb along the vertical track; its length is proportional to viewport / content.
  let tr = p.vTrack.shrink(0, 2)
  let total = max(1.0, p.contentH)
  let len = clamp(tr.h * p.viewport.h / total, minThumb, tr.h)
  let pos = if p.maxY > 0: (tr.h - len) * p.scrollY / p.maxY else: 0.0
  rect(tr.x, tr.y + pos, tr.w, len)

proc thumbH(p: Panel): Rect =
  let tr = p.hTrack.shrink(2, 0)
  let total = max(1.0, p.contentW)
  let len = clamp(tr.w * p.viewport.w / total, minThumb, tr.w)
  let pos = if p.maxX > 0: (tr.w - len) * p.scrollX / p.maxX else: 0.0
  rect(tr.x + pos, tr.y, len, tr.h)

proc touch(p: Panel) =
  p.lastActivity = SDL_GetTicks()

proc overlayAlpha(p: Panel): float =
  # Visibility (0..1) of automatic-mode bars.
  if p.drag != dbNone or p.hoverV or p.hoverH: return 1.0
  let dt = SDL_GetTicks() - p.lastActivity
  if p.lastActivity == 0 or dt > showDelay + fadeTime: 0.0
  elif dt <= showDelay: 1.0
  else: 1.0 - float(dt - showDelay) / float(fadeTime)

# layout

method preferredSize*(p: Panel, d: Drawing, t: Theme): tuple[w, h: float] =
  # A panel asks for little space: give it a weight, a dock or a fixed size.
  let c = procCall preferredSize(Container(p), d, t)
  (min(c.w, 400.0), min(c.h, 300.0))

method layoutChildren*(p: Panel, d: Drawing, t: Theme) =
  # natural size of the content, laid out with the panel's own layout
  let c = procCall preferredSize(Container(p), d, t)
  p.contentW = c.w
  p.contentH = c.h
  p.computeBars()
  p.clampScroll()
  # lay the children out in a virtual rectangle of the content's natural size,
  # shifted by the scroll offset: children keep their size, only their position moves
  let saved = p.rect
  p.rect = rect(p.viewport.x - p.scrollX, p.viewport.y - p.scrollY, c.w, c.h)
  procCall layoutChildren(Container(p), d, t)
  p.rect = saved

method hitChildren*(p: Panel, x, y: float): bool =
  not ((p.showV and p.vTrack.containsPoint(x, y)) or (p.showH and p.hTrack.containsPoint(x, y)))

# drawing

method draw*(p: Panel, d: Drawing, t: Theme) =
  if p.framed:
    let rad = radiusOf(p, t)
    d.fillRoundRect(p.rect, rad, p.style.border.get(t.border))
    d.fillRoundRect(p.rect.shrink(1), max(0.0, rad - 1), p.style.background.get(t.fieldBg))
  elif p.style.background.isSome:
    d.fillRect(p.rect, p.style.background.get)

proc thumbColor(t: Theme, hover: bool, alpha: float): Color =
  let base = if t.dark: White else: Black
  withAlpha(base, int((if hover: 0.52 else: 0.36) * 255 * alpha))

proc trackColors(t: Theme, alpha: float): tuple[fill, line: Color] =
  if t.dark: (withAlpha(hex"#2B2B2B", int(235 * alpha)), withAlpha(hex"#3D3D3D", int(255 * alpha)))
  else: (withAlpha(hex"#FAFAFA", int(235 * alpha)), withAlpha(hex"#E3E3E3", int(255 * alpha)))

proc drawBar(d: Drawing, t: Theme, track, thumb: Rect, vertical, always, hover: bool, alpha: float) =
  if alpha <= 0.01: return
  let (fill, line) = trackColors(t, alpha)
  if always or hover:
    d.fillRect(track, fill)
    if vertical: d.fillRect(rect(track.x, track.y, 1, track.h), line)
    else: d.fillRect(rect(track.x, track.y, track.w, 1), line)
  # pill thumb: thin when idle, wider when pointed at (overlay mode)
  let w = if always: (if hover: 8.0 else: 7.0) else: (if hover: 9.0 else: 6.0)
  let r = if vertical: rect(track.x + (track.w - w) / 2 + (if always: 0.5 else: 1.0), thumb.y + 1, w, max(0.0, thumb.h - 2))
          else: rect(thumb.x + 1, track.y + (track.h - w) / 2 + (if always: 0.5 else: 1.0), max(0.0, thumb.w - 2), w)
  d.fillRoundRect(r, w / 2, thumbColor(t, hover, alpha))

method drawOverlay*(p: Panel, d: Drawing, t: Theme) =
  if not p.hovered:
    p.hoverV = false
    p.hoverH = false
  if not (p.showV or p.showH): return
  let always = p.scrollbars == smAlways
  let alpha = if always: 1.0 else: p.overlayAlpha
  if not always and alpha > 0 and p.win != nil: p.win.animating = true   # keep fading
  if p.showV:
    d.drawBar(t, p.vTrack, p.thumbV, true, always, p.hoverV or p.drag == dbVertical, alpha)
  if p.showH:
    d.drawBar(t, p.hTrack, p.thumbH, false, always, p.hoverH or p.drag == dbHorizontal, alpha)
  if always and p.showV and p.showH:
    let r = p.rect
    d.fillRect(rect(r.x + r.w - barSpace, r.y + r.h - barSpace, barSpace, barSpace), trackColors(t, 1).fill)

# interaction

proc scrollFromThumb(p: Panel, vertical: bool, pos: float) =
  if vertical:
    let tr = p.vTrack.shrink(0, 2)
    let len = p.thumbV.h
    if tr.h - len > 0: p.scrollY = clamp((pos - tr.y) / (tr.h - len), 0.0, 1.0) * p.maxY
  else:
    let tr = p.hTrack.shrink(2, 0)
    let len = p.thumbH.w
    if tr.w - len > 0: p.scrollX = clamp((pos - tr.x) / (tr.w - len), 0.0, 1.0) * p.maxX

method onMouse*(p: Panel, e: MouseEvent) =
  case e.action
  of maMove:
    p.hoverV = p.showV and p.vTrack.containsPoint(e.x, e.y)
    p.hoverH = p.showH and p.hTrack.containsPoint(e.x, e.y)
    case p.drag
    of dbVertical: p.scrollFromThumb(true, e.y - p.dragOffset)
    of dbHorizontal: p.scrollFromThumb(false, e.x - p.dragOffset)
    of dbNone: discard
    if p.hoverV or p.hoverH or p.drag != dbNone: p.touch()
  of maPress:
    if e.button != mbLeft: return
    let jump = (e.mods and KMOD_ALT) != 0
    if p.showV and p.vTrack.containsPoint(e.x, e.y):
      let th = p.thumbV
      if th.containsPoint(e.x, e.y):
        p.drag = dbVertical
        p.dragOffset = e.y - th.y
      elif jump:
        p.drag = dbVertical
        p.dragOffset = th.h / 2
        p.scrollFromThumb(true, e.y - p.dragOffset)
      else:
        p.scrollY += (if e.y < th.y: -1.0 else: 1.0) * p.viewport.h * 0.9
      p.clampScroll()
      p.touch()
    elif p.showH and p.hTrack.containsPoint(e.x, e.y):
      let th = p.thumbH
      if th.containsPoint(e.x, e.y):
        p.drag = dbHorizontal
        p.dragOffset = e.x - th.x
      elif jump:
        p.drag = dbHorizontal
        p.dragOffset = th.w / 2
        p.scrollFromThumb(false, e.x - p.dragOffset)
      else:
        p.scrollX += (if e.x < th.x: -1.0 else: 1.0) * p.viewport.w * 0.9
      p.clampScroll()
      p.touch()
  of maRelease:
    if p.drag != dbNone:
      p.drag = dbNone
      p.touch()

method onWheel*(p: Panel, dx, dy: float): bool =
  var h = dx
  var v = dy
  if h == 0 and (SDL_GetModState() and KMOD_SHIFT) != 0:
    h = v
    v = 0
  let canV = p.maxY > 0 and v != 0
  let canH = p.maxX > 0 and h != 0
  if not (canV or canH): return false            # let a parent panel scroll.
  if canV: p.scrollY -= v * p.lineStep
  if canH: p.scrollX -= h * p.lineStep
  p.clampScroll()
  p.touch()
  true

proc ensureVisible*(p: Panel, c: Control, margin = 8.0) =
  # Scrolls so that control `c` (a descendant) is inside the viewport.
  let vp = p.viewport
  let r = c.rect
  if r.y < vp.y: p.scrollY -= vp.y - r.y + margin
  elif r.y + r.h > vp.y + vp.h: p.scrollY += min(r.y - vp.y, r.y + r.h - vp.y - vp.h + margin)
  if r.x < vp.x: p.scrollX -= vp.x - r.x + margin
  elif r.x + r.w > vp.x + vp.w: p.scrollX += min(r.x - vp.x, r.x + r.w - vp.x - vp.w + margin)
  p.clampScroll()
  p.touch()

method onDescendantFocus*(p: Panel, c: Control) =
  p.ensureVisible(c)                             # Tab into a hidden child scrolls to it

# id-based API (thread-safe)

proc panelScrollTo*(id: ControlId, x, y: float) =
  # Sets the scroll offset (pixels from the content's top-left corner).
  withControl(id, Panel, p):
    p.scrollX = x
    p.scrollY = y
    p.clampScroll()
    p.touch()

proc panelScrollBy*(id: ControlId, dx, dy: float) =
  withControl(id, Panel, p):
    p.scrollX += dx
    p.scrollY += dy
    p.clampScroll()
    p.touch()

proc panelScrollPosition*(id: ControlId): tuple[x, y: float] =
  readControl(id, Panel, p): result = (p.scrollX, p.scrollY)

proc panelContentSize*(id: ControlId): tuple[w, h: float] =
  # Natural size of the content (as computed by the last layout).
  readControl(id, Panel, p): result = (p.contentW, p.contentH)

proc panelViewportSize*(id: ControlId): tuple[w, h: float] =
  readControl(id, Panel, p): result = (p.viewport.w, p.viewport.h)

proc panelSetScrollbars*(id: ControlId, mode: ScrollbarMode) =
  # smAlways (default), smAutomatic (macOS overlay bars) or smHidden.
  withControl(id, Panel, p): p.scrollbars = mode

proc panelEnsureVisible*(id: ControlId, child: ControlId) =
  # Scrolls the panel so that `child` (a descendant) becomes visible.
  withControl(id, Panel, p):
    let c = control(child)
    if c != nil: p.ensureVisible(c)
