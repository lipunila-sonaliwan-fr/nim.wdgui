# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
# 2D drawing primitives on top of the SDL3 renderer (rounded rectangles, circles,
# polygons, text, clipping). Reusable to draw custom controls.
import std/[math, algorithm, unicode, os, tables]
import ../sdl3, colors_themes

type
  Rect* = object
    x*, y*, w*, h*: float

  Alignment* = enum
    alLeft = "Left", alCenter = "Center", alRight = "Right"

  Point* = tuple[x, y: float]

  Drawing* = ref object
    ren*: SDL_Renderer
    clips: seq[Rect]
    clipEmpty: bool              # the current clip is empty: nothing must be drawn
    scale*: float
    cacheKey: string
    when defined(sdlttf):
      font: TTF_Font
      fontHeight: float
      cache: Table[string, tuple[tex: SDL_Texture, w, h: float]]

proc rect*(x, y, w, h: float): Rect {.inline.} = Rect(x: x, y: y, w: w, h: h)

proc containsPoint*(r: Rect, x, y: float): bool =
  x >= r.x and y >= r.y and x < r.x + r.w and y < r.y + r.h

proc shrink*(r: Rect, m: float): Rect =
  Rect(x: r.x + m, y: r.y + m, w: max(0.0, r.w - 2*m), h: max(0.0, r.h - 2*m))

proc shrink*(r: Rect, mx, my: float): Rect =
  Rect(x: r.x + mx, y: r.y + my, w: max(0.0, r.w - 2*mx), h: max(0.0, r.h - 2*my))

proc intersect*(a, b: Rect): Rect =
  let x1 = max(a.x, b.x)
  let y1 = max(a.y, b.y)
  let x2 = min(a.x + a.w, b.x + b.w)
  let y2 = min(a.y + a.h, b.y + b.h)
  Rect(x: x1, y: y1, w: max(0.0, x2 - x1), h: max(0.0, y2 - y1))

proc newDrawing*(ren: SDL_Renderer): Drawing = Drawing(ren: ren, scale: 2.0)

proc color(d: Drawing, c: Color) {.inline.} =
  discard SDL_SetRenderDrawColor(d.ren, c.r, c.g, c.b, c.a)

proc applyClip(d: Drawing, s = 1.0) =
  d.clipEmpty = false
  if d.clips.len == 0:
    discard SDL_SetRenderClipRect(d.ren, nil)
    return
  let c = d.clips[^1]
  if c.w < 0.5 or c.h < 0.5:
    # Empty clip. Some SDL back ends (Metal, GPU... turn a degenerate or off-screen
    # scissor rectangle into "no clipping at all", so we never send one: we draw nothing.
    d.clipEmpty = true
    var r = SDL_Rect(x: 0, y: 0, w: 1, h: 1)
    discard SDL_SetRenderClipRect(d.ren, addr r)
    return
  var r = SDL_Rect(x: cint(floor(c.x / s)), y: cint(floor(c.y / s)),
                   w: max(1.cint, cint(ceil(c.w / s))), h: max(1.cint, cint(ceil(c.h / s))))
  discard SDL_SetRenderClipRect(d.ren, addr r)

proc clipRect*(d: Drawing): Rect =
  # Current clip rectangle (a huge one when there is no clip).
  if d.clips.len > 0: d.clips[^1] else: Rect(x: -1e9, y: -1e9, w: 2e9, h: 2e9)

proc isClippedOut*(d: Drawing, r: Rect): bool =
  # True when nothing of `r` can be visible with the current clip.
  if d.clipEmpty: return true
  let i = intersect(d.clipRect, r)
  i.w <= 0 or i.h <= 0

proc pushClip*(d: Drawing, r: Rect) =
  d.clips.add(if d.clips.len > 0: intersect(d.clips[^1], r) else: r)
  d.applyClip()

proc popClip*(d: Drawing) =
  if d.clips.len > 0: d.clips.setLen(d.clips.len - 1)
  d.applyClip()

proc suspendClip*(d: Drawing): seq[Rect] =
  result = d.clips
  d.clips = @[]
  d.applyClip()

proc restoreClip*(d: Drawing, s: seq[Rect]) =
  d.clips = s
  d.applyClip()

#  shapes

proc clearWith*(d: Drawing, c: Color) =
  d.color(c)
  discard SDL_RenderClear(d.ren)

proc fillRect*(d: Drawing, r: Rect, c: Color) =
  if c.a == 0 or r.w <= 0 or r.h <= 0: return
  d.color(c)
  var fr = SDL_FRect(x: r.x.cfloat, y: r.y.cfloat, w: r.w.cfloat, h: r.h.cfloat)
  discard SDL_RenderFillRect(d.ren, addr fr)

proc line*(d: Drawing, x1, y1, x2, y2: float, c: Color, ep = 1.0) =
  if d.clipEmpty: return
  if c.a == 0: return
  d.color(c)
  if ep <= 1.0:
    discard SDL_RenderLine(d.ren, x1.cfloat, y1.cfloat, x2.cfloat, y2.cfloat)
    return
  let dx = x2 - x1
  let dy = y2 - y1
  let l = max(1e-6, sqrt(dx*dx + dy*dy))
  let nx = -dy / l
  let ny = dx / l
  let n = int(ceil(ep * 2))
  for i in 0 .. n:
    let o = -ep / 2 + ep * float(i) / float(n)
    discard SDL_RenderLine(d.ren, cfloat(x1 + nx*o), cfloat(y1 + ny*o), cfloat(x2 + nx*o), cfloat(y2 + ny*o))

proc fillRoundRect*(d: Drawing, r: Rect, radius: float, c: Color) =
  if d.clipEmpty: return
  if c.a == 0 or r.w <= 0 or r.h <= 0: return
  let x = round(r.x)
  let y = round(r.y)
  let w = round(r.w)
  let h = round(r.h)
  let rad = min(max(0.0, radius), min(w, h) / 2)
  if rad < 1.0:
    d.fillRect(rect(x, y, w, h), c)
    return
  d.color(c)
  let ir = int(ceil(rad))
  var middle = SDL_FRect(x: x.cfloat, y: cfloat(y + ir.float), w: w.cfloat, h: cfloat(h - 2*ir.float))
  if middle.h > 0: discard SDL_RenderFillRect(d.ren, addr middle)
  let hi = int(h)
  for i in 0 ..< ir:
    let top = i
    let bottom = hi - 1 - i
    if top > bottom: break
    let dy = rad - (float(i) + 0.5)
    let dx = if dy > 0: rad - sqrt(max(0.0, rad*rad - dy*dy)) else: 0.0
    let x1 = x + round(dx)
    let lw = max(0.0, w - 2 * round(dx))
    var l1 = SDL_FRect(x: x1.cfloat, y: cfloat(y + top.float), w: lw.cfloat, h: 1)
    discard SDL_RenderFillRect(d.ren, addr l1)
    if bottom != top:
      var l2 = SDL_FRect(x: x1.cfloat, y: cfloat(y + bottom.float), w: lw.cfloat, h: 1)
      discard SDL_RenderFillRect(d.ren, addr l2)

proc strokeRoundRect*(d: Drawing, r: Rect, radius: float, c: Color, ep = 1.0) =
  if d.clipEmpty: return
  if c.a == 0 or r.w <= 0 or r.h <= 0: return
  d.color(c)
  for k in 0 ..< max(1, int(round(ep))):
    let kf = k.float
    let q = rect(round(r.x) + kf, round(r.y) + kf, round(r.w) - 2*kf, round(r.h) - 2*kf)
    if q.w <= 1 or q.h <= 1: break
    let rad = min(max(0.0, radius - kf), min(q.w, q.h) / 2)
    let x2 = q.x + q.w - 1
    let y2 = q.y + q.h - 1
    discard SDL_RenderLine(d.ren, cfloat(q.x + rad), q.y.cfloat, cfloat(x2 - rad), q.y.cfloat)
    discard SDL_RenderLine(d.ren, cfloat(q.x + rad), y2.cfloat, cfloat(x2 - rad), y2.cfloat)
    discard SDL_RenderLine(d.ren, q.x.cfloat, cfloat(q.y + rad), q.x.cfloat, cfloat(y2 - rad))
    discard SDL_RenderLine(d.ren, x2.cfloat, cfloat(q.y + rad), x2.cfloat, cfloat(y2 - rad))
    if rad >= 1:
      let n = int(rad * 2) + 2
      let (c1x, c1y) = (q.x + rad, q.y + rad)
      let (c2x, c2y) = (x2 - rad, y2 - rad)
      for i in 0 .. n:
        let a = float(i) / float(n) * PI / 2
        let px = rad * cos(a)
        let py = rad * sin(a)
        discard SDL_RenderPoint(d.ren, cfloat(c1x - px), cfloat(c1y - py))
        discard SDL_RenderPoint(d.ren, cfloat(c2x + px), cfloat(c1y - py))
        discard SDL_RenderPoint(d.ren, cfloat(c1x - px), cfloat(c2y + py))
        discard SDL_RenderPoint(d.ren, cfloat(c2x + px), cfloat(c2y + py))

proc strokeRect*(d: Drawing, r: Rect, c: Color, ep = 1.0) = d.strokeRoundRect(r, 0, c, ep)

proc fillEllipse*(d: Drawing, r: Rect, c: Color) =
  if d.clipEmpty: return
  if c.a == 0 or r.w <= 0 or r.h <= 0: return
  d.color(c)
  let a = r.w / 2
  let b = r.h / 2
  let cx = r.x + a
  for i in 0 ..< int(ceil(r.h)):
    let dy = (float(i) + 0.5 - b) / b
    if abs(dy) > 1: continue
    let dx = a * sqrt(1 - dy*dy)
    var l = SDL_FRect(x: cfloat(round(cx - dx)), y: cfloat(r.y + float(i)), w: cfloat(round(2*dx)), h: 1)
    discard SDL_RenderFillRect(d.ren, addr l)

proc strokeEllipse*(d: Drawing, r: Rect, c: Color, ep = 1.0) =
  if d.clipEmpty: return
  if c.a == 0 or r.w <= 0 or r.h <= 0: return
  d.color(c)
  for k in 0 ..< max(1, int(ep)):
    let a = r.w / 2 - k.float - 0.5
    let b = r.h / 2 - k.float - 0.5
    if a <= 0 or b <= 0: break
    let n = int((a + b) * 3) + 8
    for i in 0 ..< n:
      let t = float(i) / float(n) * 2 * PI
      discard SDL_RenderPoint(d.ren, cfloat(r.x + r.w/2 + a*cos(t)), cfloat(r.y + r.h/2 + b*sin(t)))

proc fillCircle*(d: Drawing, cx, cy, radius: float, c: Color) =
  d.fillEllipse(rect(cx - radius, cy - radius, 2*radius, 2*radius), c)

proc strokeCircle*(d: Drawing, cx, cy, radius: float, c: Color, ep = 1.0) =
  d.strokeEllipse(rect(cx - radius, cy - radius, 2*radius, 2*radius), c, ep)

proc fillPolygon*(d: Drawing, pts: openArray[Point], c: Color) =
  if d.clipEmpty: return
  # Scanline fill (even-odd rule).
  if pts.len < 3 or c.a == 0: return
  d.color(c)
  var miny = pts[0].y
  var maxy = pts[0].y
  for p in pts:
    miny = min(miny, p.y)
    maxy = max(maxy, p.y)
  var xs: seq[float]
  for yi in int(floor(miny)) .. int(ceil(maxy)):
    let sy = float(yi) + 0.5
    xs.setLen(0)
    for i in 0 ..< pts.len:
      let (x1, y1) = pts[i]
      let (x2, y2) = pts[(i + 1) mod pts.len]
      if (y1 <= sy and y2 > sy) or (y2 <= sy and y1 > sy):
        xs.add(x1 + (sy - y1) / (y2 - y1) * (x2 - x1))
    xs.sort()
    var i = 0
    while i + 1 < xs.len:
      var l = SDL_FRect(x: cfloat(round(xs[i])), y: yi.cfloat, w: cfloat(round(xs[i+1]) - round(xs[i])), h: 1)
      if l.w > 0: discard SDL_RenderFillRect(d.ren, addr l)
      i += 2

proc triangle*(d: Drawing, cx, cy, size: float, dir: char, c: Color) =
  # dir: 'v' down, '^' up, '<' left, '>' right.
  let s = size / 2
  case dir
  of 'v': d.fillPolygon([(cx - s, cy - s/2), (cx + s, cy - s/2), (cx, cy + s/2)], c)
  of '^': d.fillPolygon([(cx - s, cy + s/2), (cx + s, cy + s/2), (cx, cy - s/2)], c)
  of '<': d.fillPolygon([(cx + s/2, cy - s), (cx + s/2, cy + s), (cx - s/2, cy)], c)
  else: d.fillPolygon([(cx - s/2, cy - s), (cx - s/2, cy + s), (cx + s/2, cy)], c)

proc drawCheckMark*(d: Drawing, r: Rect, c: Color, ep = 2.0) =
  d.line(r.x + r.w*0.15, r.y + r.h*0.52, r.x + r.w*0.40, r.y + r.h*0.76, c, ep)
  d.line(r.x + r.w*0.40, r.y + r.h*0.76, r.x + r.w*0.85, r.y + r.h*0.25, c, ep)

proc shadow*(d: Drawing, r: Rect, radius: float, c: Color) =
  for i in countdown(4, 1):
    d.fillRoundRect(rect(r.x - i.float/2, r.y + i.float/2, r.w + i.float, r.h + i.float),
                       radius + i.float/2, withAlpha(c, int(c.a) div (i + 1)))

proc drawFocus*(d: Drawing, t: Theme, r: Rect, radius: float) =
  case t.focusStyle
  of fsHalo: d.strokeRoundRect(r.shrink(-3), radius + 3, t.focus, 3)
  of fsRing: d.strokeRoundRect(r.shrink(-2), radius + 2, t.focus, 2)
  of fsUnderline: d.strokeRoundRect(r.shrink(-3), radius + 3, t.focus, 2)

proc drawTexture*(d: Drawing, tex: SDL_Texture, dst: Rect) =
  if d.clipEmpty: return
  var r = SDL_FRect(x: dst.x.cfloat, y: dst.y.cfloat, w: dst.w.cfloat, h: dst.h.cfloat)
  discard SDL_RenderTexture(d.ren, tex, nil, addr r)

# text

proc clearCache(d: Drawing) =
  when defined(sdlttf):
    for v in d.cache.values: SDL_DestroyTexture(v.tex)
    d.cache.clear()

proc configure*(d: Drawing, t: Theme) =
  # (Re)loads the font if the theme changed.
  let cacheKey = t.name & "|" & $t.fontSize & "|" & $t.textScale
  if cacheKey == d.cacheKey: return
  d.cacheKey = cacheKey
  d.scale = max(1.0, t.textScale)
  when defined(sdlttf):
    d.clearCache()
    if d.font != nil:
      TTF_CloseFont(d.font)
      d.font = nil
    for p in t.fonts:
      if fileExists(p):
        d.font = TTF_OpenFont(p.cstring, t.fontSize.cfloat)
        if d.font != nil: break
    if d.font != nil: d.fontHeight = float(TTF_GetFontHeight(d.font))

proc dispose*(d: Drawing) =
  d.clearCache()
  when defined(sdlttf):
    if d.font != nil: TTF_CloseFont(d.font)
    d.font = nil

proc textHeight*(d: Drawing): float =
  when defined(sdlttf):
    if d.font != nil: return d.fontHeight
  8.0 * d.scale

proc textWidth*(d: Drawing, s: string): float =
  if s.len == 0: return 0
  when defined(sdlttf):
    if d.font != nil:
      var w, h: cint
      if TTF_GetStringSize(d.font, s.cstring, csize_t(s.len), addr w, addr h): return float(w)
  float(s.runeLen) * 8.0 * d.scale

proc text*(d: Drawing, x, y: float, s: string, c: Color) =
  if d.clipEmpty: return
  if s.len == 0 or c.a == 0: return
  when defined(sdlttf):
    if d.font != nil:
      var e = d.cache.getOrDefault(s)
      if e.tex == nil:
        if d.cache.len > 1000: d.clearCache()
        let surf = TTF_RenderText_Blended(d.font, s.cstring, csize_t(s.len), SDL_Color(r: 255, g: 255, b: 255, a: 255))
        if surf == nil: return
        let tex = SDL_CreateTextureFromSurface(d.ren, surf)
        SDL_DestroySurface(surf)
        if tex == nil: return
        var w, h: cfloat
        discard SDL_GetTextureSize(tex, addr w, addr h)
        e = (tex, float(w), float(h))
        d.cache[s] = e
      discard SDL_SetTextureColorMod(e.tex, c.r, c.g, c.b)
      discard SDL_SetTextureAlphaMod(e.tex, c.a)
      d.drawTexture(e.tex, rect(round(x), round(y), e.w, e.h))
      return
  d.color(c)
  let s2 = d.scale
  if s2 != 1.0:
    discard SDL_SetRenderScale(d.ren, s2.cfloat, s2.cfloat)
    d.applyClip(s2)
  discard SDL_RenderDebugText(d.ren, cfloat(round(x) / s2), cfloat(round(y) / s2), s.cstring)
  if s2 != 1.0:
    discard SDL_SetRenderScale(d.ren, 1, 1)
    d.applyClip(1)

proc ellipsize*(d: Drawing, s: string, width: float): string =
  # Ellipsizes the text with "..." if it exceeds the available width.
  if d.textWidth(s) <= width: return s
  let pts = "..."
  let wp = d.textWidth(pts)
  var res = ""
  for r in s.runes:
    let attempt = res & $r
    if d.textWidth(attempt) + wp > width: break
    res = attempt
  res & pts

proc textIn*(d: Drawing, r: Rect, s: string, c: Color, al = alLeft, margin = 0.0) =
  # Ellipsized text, vertically centered in r, horizontally aligned.
  let t = d.ellipsize(s, r.w - 2*margin)
  let tw = d.textWidth(t)
  let x = case al
          of alLeft: r.x + margin
          of alCenter: r.x + (r.w - tw) / 2
          of alRight: r.x + r.w - tw - margin
  d.text(x, r.y + (r.h - d.textHeight) / 2, t, c)
