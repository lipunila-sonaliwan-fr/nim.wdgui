# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
#   wdgui - vector scene: shape model, SVG reading and writing, text layout,
#   and anti-aliased rendering (RGBA).
#
# * Shapes: rectangle (rounded corners), ellipse, line (with arrows), path (sub-paths,
#   straight or cubic Bézier segments, even-odd fill rule), text (bounding box,
#   line breaks, alignment, line spacing), image (PNG, JPEG, BMP, or nested SVG).
#   Supports solid or linear-gradient fills, strokes (thickness, dashed patterns),
#   opacity, rotation, layers, groups, names, custom data attributes (data-*),
#   locking, and visibility.
# * SVG: supports reading a broad subset (g, transform, style, rect, circle, ellipse,
#   line, polyline, polygon, path M/L/H/V/C/S/Q/T/A/Z, text/tspan, image, linearGradient)
#   and writing clean, compact, standard-compliant SVG (layers as <g> elements,
#   groups, gradients and markers in <defs>, rounded numerical values).
# * Rendering: analytical scanline coverage (4 sub-scanlines, precise horizontal
#   coverage), premultiplied "over" compositing, text rendering via SDL3_ttf
#   (Poppins, Lora, DejaVu Sans Mono, Go Noto), and bilinear image resampling.
#
# This module is independent of any specific UI control; it is utilized by the
# canvas (vcanvas), the Markdown view, the drawing package (thumbnails,
# vectorization), and the publishing package (PDF).

import std/[strutils, math, tables, algorithm, os, locks, sets, base64, sequtils, times, unicode]
import ../sdl3, ../wdgpath
import imagedecode
import imagepure

type
  VColor* = object
    r*, g*, b*, a*: float          # 0..1, non-premultiplied alpha

  VPt* = object
    x*, y*: float                  # node (scene coordinates)
    ix*, iy*: float                # entry handle, relative to the node
    ox*, oy*: float                # exit handle, relative to the node
    smooth*: bool                  # linked handles (smooth node)

  VSub* = object
    pts*: seq[VPt]
    closed*: bool

  VKind* = enum
    vkRect = "rectangle", vkEllipse = "ellipse", vkLine = "ligne", vkPath = "chemin",
    vkText = "texte", vkImage = "image"

  VShape* = ref object
    id*, name*: string
    kind*: VKind
    x*, y*, w*, h*: float          # box (rectangle, ellipse, text, image)
    rx*: float                     # corner radius (rectangle)
    subs*: seq[VSub]               # line (2 nodes) and path
    evenOdd*: bool
    fill*, stroke*: string         # CSS color, "none", or "linear(angle,#c1,#c2)"
    strokeWidth*, opacity*: float
    dash*: string                  # "6,4"; "": continuous line
    arrowStart*, arrowEnd*: bool
    text*, font*: string
    fontSize*, lineHeight*: float  # lineHeight: factor (1.25)
    bold*, italic*: bool
    align*: string                 # left | center | right
    href*: string                  # image: path (absolute, or relative to scene.base)
    rotation*: float               # degrees, around the center of the box
    layer*, group*, data*: string
    locked*, hidden*: bool
    shadow*: bool                  # soft drop shadow

  VLayer* = object
    name*: string
    visible*, locked*: bool

  VScene* = ref object
    width*, height*: float
    background*: string            # "": transparent
    shapes*: seq[VShape]
    layers*: seq[VLayer]
    base*: string                  # folder for related images
    version*: int

  Affine* = array[6, float]        # a b c d e f (x' = a x + c y + e ; y' = b x + d y + f)

  FPoint* = tuple[x, y: float]

  Raster* = object
    w*, h*: int
    px*: seq[float32]              # premultiplied RGBA

  PaintKind = enum pkSolid, pkLinear
  Paint = object
    kind: PaintKind
    c1, c2: VColor
    x1, y1, x2, y2: float          # gradient end points (output pixels)
    opacity: float

type SurfView = object      # start of the SDL3 SDL_Surface structure
  flags, format: uint32
  w, h, pitch: cint
  pixels: pointer

const Identity*: Affine = [1.0, 0, 0, 1, 0, 0]

#
# colors
#

const NamedColors = {
  "black": 0x000000, "white": 0xffffff, "red": 0xff0000, "green": 0x008000, "lime": 0x00ff00,
  "blue": 0x0000ff, "yellow": 0xffff00, "cyan": 0x00ffff, "aqua": 0x00ffff, "magenta": 0xff00ff,
  "fuchsia": 0xff00ff, "gray": 0x808080, "grey": 0x808080, "silver": 0xc0c0c0, "maroon": 0x800000,
  "olive": 0x808000, "purple": 0x800080, "teal": 0x008080, "navy": 0x000080, "orange": 0xffa500,
  "pink": 0xffc0cb, "brown": 0xa52a2a, "gold": 0xffd700, "skyblue": 0x87ceeb, "lightblue": 0xadd8e6,
  "darkblue": 0x00008b, "darkgreen": 0x006400, "lightgreen": 0x90ee90, "lightgray": 0xd3d3d3,
  "lightgrey": 0xd3d3d3, "darkgray": 0xa9a9a9, "darkgrey": 0xa9a9a9, "beige": 0xf5f5dc,
  "violet": 0xee82ee, "indigo": 0x4b0082, "coral": 0xff7f50, "salmon": 0xfa8072, "crimson": 0xdc143c,
  "khaki": 0xf0e68c, "turquoise": 0x40e0d0, "tomato": 0xff6347, "orangered": 0xff4500,
  "steelblue": 0x4682b4, "royalblue": 0x4169e1, "midnightblue": 0x191970, "seagreen": 0x2e8b57,
  "darkred": 0x8b0000, "lavender": 0xe6e6fa, "ivory": 0xfffff0, "dodgerblue": 0x1e90ff,
  "hotpink": 0xff69b4, "slategray": 0x708090, "whitesmoke": 0xf5f5f5, "darkorange": 0xff8c00,
  "deepskyblue": 0x00bfff, "firebrick": 0xb22222, "goldenrod": 0xdaa520, "dimgray": 0x696969,
  "chocolate": 0xd2691e, "tan": 0xd2b48c, "plum": 0xdda0dd, "orchid": 0xda70d6, "wheat": 0xf5deb3}.toTable

proc parseColor*(s: string, ok: var bool): VColor =
  ## CSS color: #rgb, #rrggbb, #rrggbbaa, rgb(), rgba(), name; ok = false if "none"
  ## or unreadable.
  ok = false
  var t = s.strip.toLowerAscii
  if t.len == 0 or t in ["none", "transparent"]: return
  if t == "currentcolor": t = "black"
  if t[0] == '#':
    var h = t[1 .. ^1]
    if h.len in [3, 4]:
      var e = ""
      for ch in h: e.add ch; e.add ch
      h = e
    if h.len notin [6, 8]: return
    try:
      let v = parseHexInt(h[0 .. 5])
      result = VColor(r: float((v shr 16) and 255) / 255, g: float((v shr 8) and 255) / 255,
                      b: float(v and 255) / 255, a: 1)
      if h.len == 8: result.a = float(parseHexInt(h[6 .. 7])) / 255
      ok = true
    except ValueError: discard
    return
  if t.startsWith("rgb"):
    let a = t.find('(')
    let b = t.rfind(')')
    if a < 0 or b < a: return
    let parts = t[a + 1 ..< b].replace("/", ",").replace(" ", ",").split(',')
    var nums: seq[float]
    for p in parts:
      let q = p.strip
      if q.len == 0: continue
      try:
        if q.endsWith("%"): nums.add parseFloat(q[0 .. ^2]) * 2.55
        else: nums.add parseFloat(q)
      except ValueError: return
    if nums.len < 3: return
    result = VColor(r: clamp(nums[0] / 255, 0, 1), g: clamp(nums[1] / 255, 0, 1), b: clamp(nums[2] / 255, 0, 1), a: 1)
    if nums.len >= 4: result.a = clamp((if nums[3] > 1: nums[3] / 255 else: nums[3]), 0, 1)
    ok = true
    return
  if NamedColors.hasKey(t):
    let v = NamedColors[t]
    result = VColor(r: float((v shr 16) and 255) / 255, g: float((v shr 8) and 255) / 255,
                    b: float(v and 255) / 255, a: 1)
    ok = true

proc parseColor*(s: string): VColor =
  var ok: bool
  result = parseColor(s, ok)

proc hexColor*(c: VColor): string =
  proc h2(v: float): string = toHex(int(round(clamp(v, 0, 1) * 255)), 2).toLowerAscii
  result = "#" & h2(c.r) & h2(c.g) & h2(c.b)
  if c.a < 0.999: result &= h2(c.a)

type Gradient* = object
  angle*: float
  c1*, c2*: VColor

proc parseGradient*(s: string, g: var Gradient): bool =
  ## "linear(angle,#c1,#c2)" (angle in degrees: 0 = left to right, 90 = top to bottom).
  let t = s.strip.toLowerAscii
  if not t.startsWith("linear(") or not t.endsWith(")"): return false
  let parts = t[7 .. ^2].split(',')
  if parts.len < 3: return false
  try: g.angle = parseFloat(parts[0].strip)
  except ValueError: return false
  var ok1, ok2: bool
  g.c1 = parseColor(parts[1], ok1)
  g.c2 = parseColor(parts[2 .. ^1].join(","), ok2)
  ok1 and ok2

proc paintVisible(s: string): bool =
  var g: Gradient
  if parseGradient(s, g): return true
  var ok: bool
  discard parseColor(s, ok)
  ok

#
# affine transforms
#

proc mul*(m, n: Affine): Affine =
  ## m ∘ n: applies n, then m.
  [m[0]*n[0] + m[2]*n[1], m[1]*n[0] + m[3]*n[1],
   m[0]*n[2] + m[2]*n[3], m[1]*n[2] + m[3]*n[3],
   m[0]*n[4] + m[2]*n[5] + m[4], m[1]*n[4] + m[3]*n[5] + m[5]]

proc apply*(m: Affine, x, y: float): FPoint {.inline.} =
  (m[0]*x + m[2]*y + m[4], m[1]*x + m[3]*y + m[5])

proc applyVec(m: Affine, x, y: float): FPoint {.inline.} = (m[0]*x + m[2]*y, m[1]*x + m[3]*y)

proc translateM*(x, y: float): Affine = [1.0, 0, 0, 1, x, y]
proc scaleM*(sx, sy: float): Affine = [sx, 0, 0, sy, 0, 0]
proc rotateM*(deg: float, cx = 0.0, cy = 0.0): Affine =
  let a = degToRad(deg)
  let r: Affine = [cos(a), sin(a), -sin(a), cos(a), 0, 0]
  mul(translateM(cx, cy), mul(r, translateM(-cx, -cy)))

proc invert*(m: Affine): Affine =
  let det = m[0]*m[3] - m[1]*m[2]
  if abs(det) < 1e-12: return Identity
  let a = m[3] / det
  let b = -m[1] / det
  let c = -m[2] / det
  let d = m[0] / det
  [a, b, c, d, -(a*m[4] + c*m[5]), -(b*m[4] + d*m[5])]

proc scaleOf*(m: Affine): float = sqrt(abs(m[0]*m[3] - m[1]*m[2]))

#
# shapes: creation
#

var idCounter {.global.}: int
var idLock: Lock
initLock(idLock)

proc newId*(prefix = "f"): string =
  {.cast(gcsafe).}:
    withLock idLock:
      inc idCounter
      result = prefix & $idCounter & "_" & toHex(int(epochTime() * 1000) and 0xFFFFFF, 6).toLowerAscii

proc newShape*(kind: VKind, id = ""): VShape =
  VShape(id: (if id.len > 0: id else: newId()), kind: kind, fill: "#4f7cff", stroke: "none",
         strokeWidth: 2, opacity: 1, font: "Poppins", fontSize: 24, lineHeight: 1.25,
         align: "gauche", layer: "")

proc newScene*(w = 800.0, h = 600.0): VScene =
  VScene(width: w, height: h, layers: @[VLayer(name: "Calque 1", visible: true)])

proc clone*(s: VShape): VShape =
  new(result)
  result[] = s[]

proc cloneScene*(sc: VScene): VScene =
  result = VScene(width: sc.width, height: sc.height, background: sc.background, layers: sc.layers,
                  base: sc.base, version: sc.version)
  for s in sc.shapes: result.shapes.add s.clone

proc findShape*(sc: VScene, id: string): VShape =
  for s in sc.shapes:
    if s.id == id: return s

proc layerOf*(sc: VScene, name: string): int =
  for i, l in sc.layers:
    if l.name == name: return i
  -1

proc ensureLayer*(sc: VScene, name: string) =
  if name.len > 0 and sc.layerOf(name) < 0: sc.layers.add VLayer(name: name, visible: true)

proc layerVisible*(sc: VScene, s: VShape): bool =
  if s.hidden: return false
  let i = sc.layerOf(s.layer)
  i < 0 or sc.layers[i].visible

proc layerLocked*(sc: VScene, s: VShape): bool =
  if s.locked: return true
  let i = sc.layerOf(s.layer)
  i >= 0 and sc.layers[i].locked

#
# path geometry
#

proc cubicPt(p0, p1, p2, p3: FPoint, t: float): FPoint {.inline.} =
  let u = 1 - t
  (u*u*u*p0.x + 3*u*u*t*p1.x + 3*u*t*t*p2.x + t*t*t*p3.x,
   u*u*u*p0.y + 3*u*u*t*p1.y + 3*u*t*t*p2.y + t*t*t*p3.y)

proc hasHandles(a, b: VPt): bool {.inline.} =
  a.ox != 0 or a.oy != 0 or b.ix != 0 or b.iy != 0

proc flattenSub*(sub: VSub, m: Affine, tol = 0.25): seq[FPoint] =
  ## Sub-path points transformed by m (curves subdivided according to their on-screen size).
  let n = sub.pts.len
  if n == 0: return
  result.add m.apply(sub.pts[0].x, sub.pts[0].y)
  let segs = if sub.closed: n else: n - 1
  for i in 0 ..< segs:
    let a = sub.pts[i]
    let b = sub.pts[(i + 1) mod n]
    let p3 = m.apply(b.x, b.y)
    if hasHandles(a, b):
      let p0 = m.apply(a.x, a.y)
      let p1 = m.apply(a.x + a.ox, a.y + a.oy)
      let p2 = m.apply(b.x + b.ix, b.y + b.iy)
      let L = hypot(p1.x - p0.x, p1.y - p0.y) + hypot(p2.x - p1.x, p2.y - p1.y) + hypot(p3.x - p2.x, p3.y - p2.y)
      let steps = clamp(int(sqrt(L / max(tol, 0.05)) * 1.2), 2, 200)
      for k in 1 .. steps: result.add cubicPt(p0, p1, p2, p3, k.float / steps.float)
    else:
      result.add p3
  if sub.closed and result.len > 1 and result[^1] == result[0]: result.setLen(result.len - 1)

proc ellipsePts(cx, cy, rx, ry: float, m: Affine): seq[FPoint] =
  let s = scaleOf(m)
  let k = clamp(int(2 * PI * max(rx, ry) * s / 3), 24, 720)
  for i in 0 ..< k:
    let t = 2 * PI * i.float / k.float
    result.add m.apply(cx + rx * cos(t), cy + ry * sin(t))

proc roundRectPts(x, y, w, h, r0: float, m: Affine): seq[FPoint] =
  let r = clamp(r0, 0, min(w, h) / 2)
  if r <= 0.01:
    return @[m.apply(x, y), m.apply(x + w, y), m.apply(x + w, y + h), m.apply(x, y + h)]
  let s = scaleOf(m)
  let k = clamp(int(r * s / 2), 4, 64)
  proc arc(cx, cy, a0: float, res: var seq[FPoint]) =
    for i in 0 .. k:
      let t = degToRad(a0 + 90.0 * i.float / k.float)
      res.add m.apply(cx + r * cos(t), cy + r * sin(t))
  arc(x + w - r, y + r, -90, result)
  arc(x + w - r, y + h - r, 0, result)
  arc(x + r, y + h - r, 90, result)
  arc(x + r, y + r, 180, result)

proc shapeMatrix*(s: VShape): Affine =
  ## Rotation of the shape around the center of its box.
  if s.rotation == 0 or s.kind in {vkLine, vkPath}: return Identity
  rotateM(s.rotation, s.x + s.w / 2, s.y + s.h / 2)

proc rawBounds*(s: VShape): tuple[x, y, w, h: float] =
  ## Unrotated box (paths: bounding box of the points, curves included).
  case s.kind
  of vkLine, vkPath:
    var x0 = Inf
    var y0 = Inf
    var x1 = -Inf
    var y1 = -Inf
    for sub in s.subs:
      for p in flattenSub(sub, Identity, 1.0):
        x0 = min(x0, p.x); y0 = min(y0, p.y); x1 = max(x1, p.x); y1 = max(y1, p.y)
    if x0 == Inf: return (0.0, 0.0, 0.0, 0.0)
    (x0, y0, x1 - x0, y1 - y0)
  of vkText: (s.x, s.y, abs(s.w), s.h)
  else: (s.x, s.y, s.w, s.h)

proc bounds*(s: VShape): tuple[x, y, w, h: float] =
  ## Bounding box in the scene (rotation included).
  let b = s.rawBounds
  if s.rotation == 0 or s.kind in {vkLine, vkPath}: return b
  let m = s.shapeMatrix
  var x0 = Inf
  var y0 = Inf
  var x1 = -Inf
  var y1 = -Inf
  for (px, py) in [(b.x, b.y), (b.x + b.w, b.y), (b.x + b.w, b.y + b.h), (b.x, b.y + b.h)]:
    let p = m.apply(px, py)
    x0 = min(x0, p.x); y0 = min(y0, p.y); x1 = max(x1, p.x); y1 = max(y1, p.y)
  (x0, y0, x1 - x0, y1 - y0)

proc syncPathBox*(s: VShape) =
  if s.kind in {vkLine, vkPath}:
    let b = s.rawBounds
    s.x = b.x; s.y = b.y; s.w = b.w; s.h = b.h

proc moveShape*(s: VShape, dx, dy: float) =
  s.x += dx
  s.y += dy
  for sub in s.subs.mitems:
    for p in sub.pts.mitems:
      p.x += dx
      p.y += dy

proc scaleShape*(s: VShape, src, dst: tuple[x, y, w, h: float]) =
  ## Moves the shape from box src to box dst (resizing).
  let sx = if src.w > 1e-9: dst.w / src.w else: 1.0
  let sy = if src.h > 1e-9: dst.h / src.h else: 1.0
  proc fx(x: float): float = dst.x + (x - src.x) * sx
  proc fy(y: float): float = dst.y + (y - src.y) * sy
  case s.kind
  of vkLine, vkPath:
    for sub in s.subs.mitems:
      for p in sub.pts.mitems:
        p.x = fx(p.x); p.y = fy(p.y)
        p.ix *= sx; p.iy *= sy; p.ox *= sx; p.oy *= sy
    s.syncPathBox
  else:
    let nx = fx(s.x)
    let ny = fy(s.y)
    s.w = max(1.0, (fx(s.x + s.w) - nx))
    s.h = max(1.0, (fy(s.y + s.h) - ny))
    s.x = nx
    s.y = ny

#
# fonts and text
#

type FontKey = tuple[path: string, px: int, style: int]

var fontLock: Lock
initLock(fontLock)
var fontCache {.global.}: Table[FontKey, TTF_Font]
var ttfReady {.global.}: bool
var fontDirs* {.global.}: seq[string]      # additional folders (a program's fonts)

proc fontDirList(): seq[string] =
  {.cast(gcsafe).}:
    result = fontDirs
  result.add wdguiBase("ttf/Poppins-Regular.ttf") / "ttf"
  result.add wdguiBase("ttf/GoNotoEuropeAmericas.ttf") / "ttf"
  result.add getAppDir() / "ttf"

proc findFont(file: string): string =
  for d in fontDirList():
    if fileExists(d / file): return d / file
  ""

proc fontFile*(family: string, bold, italic: bool): tuple[path: string, synthBold, synthItalic: bool] =
  ## Font file for a family (Poppins, Lora, Mono, Sans); bold and italic
  ## simulated when the variant is missing.
  let f = family.toLowerAscii
  var cands: seq[(string, bool, bool)]
  if "lora" in f or "serif" == f or "serif" in f and "sans" notin f or "georgia" in f or "times" in f:
    if bold and italic: cands.add ("Lora-BoldItalic.ttf", false, false)
    if bold: cands.add ("Lora-Bold.ttf", false, italic)
    if italic: cands.add ("Lora-Italic.ttf", bold, false)
    cands.add ("Lora-Regular.ttf", bold, italic)
  elif "mono" in f or "courier" in f or "code" in f:
    cands.add ("DejaVuSansMono.ttf", bold, italic)
  else:
    if bold and italic: cands.add ("Poppins-BoldItalic.ttf", false, false)
    if bold: cands.add ("Poppins-Bold.ttf", false, italic)
    if italic: cands.add ("Poppins-Italic.ttf", bold, false)
    if "light" in f: cands.add ("Poppins-Light.ttf", bold, italic)
    if "medium" in f: cands.add ("Poppins-Medium.ttf", bold, italic)
    cands.add ("Poppins-Regular.ttf", bold, italic)
  cands.add ("GoNotoEuropeAmericas.ttf", bold, italic)
  for (file, sb, si) in cands:
    let p = findFont(file)
    if p.len > 0: return (p, sb, si)
  ("", bold, italic)

proc fontAt(family: string, bold, italic: bool, px: int): TTF_Font =
  ## Font opened at size px (shared cache, under the fontLock lock).
  when defined(sdlttf):
    if not ttfReady:
      discard TTF_Init()
      ttfReady = true
    let ff = fontFile(family, bold, italic)
    if ff.path.len == 0: return nil
    let style = (if ff.synthBold: 1 else: 0) or (if ff.synthItalic: 2 else: 0)
    let key: FontKey = (ff.path, max(1, px), style)
    if fontCache.hasKey(key): return fontCache[key]
    if fontCache.len > 160:
      for f in fontCache.values:
        if f != nil: TTF_CloseFont(f)
      fontCache.clear()
    result = TTF_OpenFont(ff.path.cstring, cfloat(max(1, px)))
    if result != nil and style != 0: TTF_SetFontStyle(result, uint32(style))
    fontCache[key] = result
  else:
    nil

proc runeLenSafe(s: string): int =
  for ch in s:
    if (ord(ch) and 0xC0) != 0x80: inc result

proc measureText*(family: string, size: float, bold, italic: bool, s: string): float =
  ## Width of a text (scene units) at size `size`.
  if s.len == 0: return 0
  {.cast(gcsafe).}:
    withLock fontLock:
      # measure at 64 px at least: advances not rounded to the pixel (no accumulated error)
      let px = max(64, int(round(size)))
      let f = fontAt(family, bold, italic, px)
      when defined(sdlttf):
        if f != nil:
          var w, h: cint
          if TTF_GetStringSize(f, s.cstring, csize_t(s.len), addr w, addr h):
            return float(w) * size / px.float
  float(s.runeLenSafe) * size * 0.55

var metricCache {.global.}: Table[string, tuple[ascent, height: float]]

proc fontMetrics*(family: string, size: float, bold, italic: bool): tuple[ascent, height: float] =
  ## Font ascent and line height (scene units): those of the renderer
  ## (SDL_ttf), measured at 200 px then scaled; used to align baselines.
  let ff = fontFile(family, bold, italic)
  var m0 = (ascent: 0.93, height: 1.2)
  {.cast(gcsafe).}:
    withLock fontLock:
      if not metricCache.hasKey(ff.path):
        var m = (ascent: 0.93, height: 1.2)
        when defined(sdlttf):
          let f = fontAt(family, bold, italic, 200)
          if f != nil:
            m = (ascent: TTF_GetFontAscent(f).float / 200, height: TTF_GetFontHeight(f).float / 200)
        metricCache[ff.path] = m
      m0 = metricCache[ff.path]
  (m0.ascent * size, m0.height * size)

proc wrapLines*(s: VShape): seq[string] =
  ## Lines of a shape's text (wrapped to the box width, if w > 0).
  let paras = s.text.replace("\r\n", "\n").split('\n')
  for para in paras:
    if s.w <= 0 or para.len == 0:
      result.add para
      continue
    let words = para.split(' ')
    var cur = ""
    for w in words:
      let attempt = if cur.len == 0: w else: cur & " " & w
      if cur.len > 0 and measureText(s.font, s.fontSize, s.bold, s.italic, attempt) > s.w:
        result.add cur
        cur = w
      else: cur = attempt
    result.add cur

proc lineStep*(s: VShape): float = s.fontSize * (if s.lineHeight > 0: s.lineHeight else: 1.25)

proc fitTextHeight*(s: VShape) =
  ## Height of a text box from its lines; automatic width if w = 0.
  if s.kind != vkText: return
  let lines = s.wrapLines
  s.h = max(s.fontSize, lines.len.float * s.lineStep)
  if s.w <= 0:
    var mw = 0.0
    for l in lines: mw = max(mw, measureText(s.font, s.fontSize, s.bold, s.italic, l))
    s.w = -mw          # automatic width (negative: no wrapping)

proc textBoxWidth*(s: VShape): float =
  if s.w < 0: -s.w else: s.w

#
# RGBA raster
#

proc newRaster*(w, h: int, bg = VColor()): Raster =
  result = Raster(w: max(1, w), h: max(1, h))
  result.px = newSeq[float32](result.w * result.h * 4)
  if bg.a > 0:
    for i in 0 ..< result.w * result.h:
      result.px[4*i] = float32(bg.r * bg.a)
      result.px[4*i+1] = float32(bg.g * bg.a)
      result.px[4*i+2] = float32(bg.b * bg.a)
      result.px[4*i+3] = float32(bg.a)

proc paintAt(p: Paint, x, y: float): VColor {.inline.} =
  case p.kind
  of pkSolid: p.c1
  of pkLinear:
    let dx = p.x2 - p.x1
    let dy = p.y2 - p.y1
    let L2 = dx*dx + dy*dy
    let t = if L2 < 1e-9: 0.0 else: clamp(((x - p.x1)*dx + (y - p.y1)*dy) / L2, 0, 1)
    VColor(r: p.c1.r + (p.c2.r - p.c1.r)*t, g: p.c1.g + (p.c2.g - p.c1.g)*t,
           b: p.c1.b + (p.c2.b - p.c1.b)*t, a: p.c1.a + (p.c2.a - p.c1.a)*t)

proc blendPx(r: var Raster, x, y: int, c: VColor, cov: float) {.inline.} =
  let a = clamp(c.a * cov, 0, 1)
  if a <= 0.0005: return
  let o = (y * r.w + x) * 4
  let ia = float32(1 - a)
  r.px[o] = float32(c.r * a) + r.px[o] * ia
  r.px[o+1] = float32(c.g * a) + r.px[o+1] * ia
  r.px[o+2] = float32(c.b * a) + r.px[o+2] * ia
  r.px[o+3] = float32(a) + r.px[o+3] * ia

const SubLines = 4

proc fillPolys*(r: var Raster, polys: seq[seq[FPoint]], paint: Paint, evenOdd = false) =
  ## Anti-aliased fill (non-zero or even-odd rule).
  type Edge = tuple[x0, y0, x1, y1, slope: float, dir: int]
  var edges: seq[Edge]
  var minY = Inf
  var maxY = -Inf
  var minX = Inf
  var maxX = -Inf
  for poly in polys:
    let n = poly.len
    if n < 2: continue
    for i in 0 ..< n:
      let a = poly[i]
      let b = poly[(i + 1) mod n]
      minX = min(minX, a.x); maxX = max(maxX, a.x)
      if abs(a.y - b.y) < 1e-12: continue
      if a.y < b.y: edges.add (a.x, a.y, b.x, b.y, (b.x - a.x) / (b.y - a.y), 1)
      else: edges.add (b.x, b.y, a.x, a.y, (a.x - b.x) / (a.y - b.y), -1)
      minY = min(minY, min(a.y, b.y)); maxY = max(maxY, max(a.y, b.y))
  if edges.len == 0: return
  let y0 = max(0, int(floor(minY)))
  let y1 = min(r.h - 1, int(ceil(maxY)))
  if y1 < y0: return
  let xa = max(0, int(floor(minX)))
  let xb = min(r.w - 1, int(ceil(maxX)))
  if xb < xa: return
  edges.sort(proc (a, b: Edge): int = cmp(a.y0, b.y0))
  var cov = newSeq[float32](xb - xa + 2)
  var active: seq[int]
  var next = 0
  var xs: seq[(float, int)]
  let inv = float32(1.0 / SubLines.float)
  for y in y0 .. y1:
    var rowMin = high(int)
    var rowMax = -1
    for s in 0 ..< SubLines:
      let sy = y.float + (s.float + 0.5) / SubLines.float
      while next < edges.len and edges[next].y0 <= sy:
        active.add next
        inc next
      var k = 0
      xs.setLen(0)
      while k < active.len:
        let e = edges[active[k]]
        if e.y1 <= sy:
          active.del(k)
          continue
        if sy >= e.y0: xs.add (e.x0 + (sy - e.y0) * e.slope, e.dir)
        inc k
      if xs.len < 2: continue
      xs.sort(proc (a, b: (float, int)): int = cmp(a[0], b[0]))
      var wind = 0
      for i in 0 ..< xs.len - 1:
        wind += (if evenOdd: 1 else: xs[i][1])
        let inside = if evenOdd: (wind and 1) != 0 else: wind != 0
        if not inside: continue
        let l = clamp(xs[i][0], xa.float, xb.float + 1)
        let rr = clamp(xs[i + 1][0], xa.float, xb.float + 1)
        if rr <= l: continue
        let il = int(floor(l))
        let ir = int(floor(rr))
        rowMin = min(rowMin, il)
        rowMax = max(rowMax, min(ir, xb))
        if il == ir:
          cov[il - xa] += float32(rr - l) * inv
        else:
          cov[il - xa] += float32(il.float + 1 - l) * inv
          for x in il + 1 ..< ir: cov[x - xa] += inv
          if ir <= xb: cov[ir - xa] += float32(rr - ir.float) * inv
    if rowMax >= rowMin:
      for x in rowMin .. rowMax:
        let c = cov[x - xa]
        if c > 0:
          r.blendPx(x, y, paint.paintAt(x.float + 0.5, y.float + 0.5), min(1.0, c.float) * paint.opacity)
          cov[x - xa] = 0

proc solid*(c: VColor, opacity = 1.0): Paint = Paint(kind: pkSolid, c1: c, opacity: opacity)

proc orientCcw(p: var seq[FPoint]) =
  var area = 0.0
  for i in 0 ..< p.len:
    let q = p[(i + 1) mod p.len]
    area += p[i].x * q.y - q.x * p[i].y
  if area < 0: p.reverse()

proc strokePolys*(pts: seq[FPoint], width: float, closed: bool): seq[seq[FPoint]] =
  ## Outline of a stroke (segments, round joins and caps), to be filled with the
  ## non-zero rule.
  if pts.len == 0 or width <= 0: return
  let hw = width / 2
  let n = if closed: pts.len else: pts.len - 1
  for i in 0 ..< n:
    let a = pts[i]
    let b = pts[(i + 1) mod pts.len]
    let dx = b.x - a.x
    let dy = b.y - a.y
    let L = sqrt(dx*dx + dy*dy)
    if L < 1e-9: continue
    let nx = -dy / L * hw
    let ny = dx / L * hw
    var q = @[(a.x + nx, a.y + ny), (b.x + nx, b.y + ny), (b.x - nx, b.y - ny), (a.x - nx, a.y - ny)]
    q.orientCcw
    result.add q
  if hw >= 0.6:
    let k = clamp(int(hw * 2.5), 8, 48)
    for p in pts:
      var c: seq[FPoint]
      for i in 0 ..< k:
        let t = 2 * PI * i.float / k.float
        c.add (p.x + hw * cos(t), p.y + hw * sin(t))
      c.orientCcw
      result.add c

proc dashed*(pts: seq[FPoint], closed: bool, pattern: seq[float]): seq[seq[FPoint]] =
  ## Splits a polyline into dashes (pattern in output units).
  var pat: seq[float]
  for v in pattern:
    if v > 0: pat.add v
  if pat.len == 0 or pts.len < 2: return @[pts]
  var all = pts
  if closed: all.add pts[0]
  var idx = 0
  var left = pat[0]
  var on = true
  var cur: seq[FPoint] = @[all[0]]
  for i in 0 ..< all.len - 1:
    var a = all[i]
    let b = all[i + 1]
    var segL = hypot(b.x - a.x, b.y - a.y)
    while segL > 1e-9:
      if left >= segL:
        left -= segL
        if on: cur.add b
        segL = 0
      else:
        let t = left / segL
        let p = (a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)
        if on:
          cur.add p
          result.add cur
        cur = @[p]
        segL -= left
        a = p
        idx = (idx + 1) mod pat.len
        left = pat[idx]
        on = not on
  if on and cur.len > 1: result.add cur

proc arrowPoly*(tip, frm: FPoint, size: float): seq[FPoint] =
  let dx = tip.x - frm.x
  let dy = tip.y - frm.y
  let L = max(1e-9, hypot(dx, dy))
  let ux = dx / L
  let uy = dy / L
  let bx = tip.x - ux * size
  let by = tip.y - uy * size
  result = @[tip, (bx - uy * size * 0.45, by + ux * size * 0.45), (bx + uy * size * 0.45, by - ux * size * 0.45)]
  result.orientCcw

proc blendMask*(r: var Raster, mask: seq[uint8], mw, mh: int, m: Affine, c: VColor, opacity: float) =
  ## Alpha mask (mw×mh) placed by m (mask coordinates -> output); bilinear
  ## sampling by inverse transformation.
  if mw <= 0 or mh <= 0: return
  let inv = invert(m)
  var x0 = Inf
  var y0 = Inf
  var x1 = -Inf
  var y1 = -Inf
  for (px, py) in [(0.0, 0.0), (mw.float, 0.0), (mw.float, mh.float), (0.0, mh.float)]:
    let p = m.apply(px, py)
    x0 = min(x0, p.x); y0 = min(y0, p.y); x1 = max(x1, p.x); y1 = max(y1, p.y)
  let ya = max(0, int(floor(y0)))
  let yb = min(r.h - 1, int(ceil(y1)))
  let xa = max(0, int(floor(x0)))
  let xb = min(r.w - 1, int(ceil(x1)))
  let axisAligned = abs(m[1]) < 1e-9 and abs(m[2]) < 1e-9 and abs(m[0] - 1) < 1e-9 and abs(m[3] - 1) < 1e-9
  for y in ya .. yb:
    for x in xa .. xb:
      let p = inv.apply(x.float + 0.5, y.float + 0.5)
      var a: float
      if axisAligned:
        let ix = int(floor(p.x))
        let iy = int(floor(p.y))
        if ix < 0 or iy < 0 or ix >= mw or iy >= mh: continue
        a = mask[iy * mw + ix].float / 255
      else:
        let fx = p.x - 0.5
        let fy = p.y - 0.5
        let ix = int(floor(fx))
        let iy = int(floor(fy))
        if ix < -1 or iy < -1 or ix >= mw or iy >= mh: continue
        let tx = fx - ix.float
        let ty = fy - iy.float
        proc g(xx, yy: int): float =
          if xx < 0 or yy < 0 or xx >= mw or yy >= mh: 0.0 else: mask[yy * mw + xx].float / 255
        a = g(ix, iy) * (1 - tx) * (1 - ty) + g(ix + 1, iy) * tx * (1 - ty) +
            g(ix, iy + 1) * (1 - tx) * ty + g(ix + 1, iy + 1) * tx * ty
      if a > 0: r.blendPx(x, y, c, a * opacity)

proc blendImage*(r: var Raster, img: RgbaImage, m: Affine, opacity: float) =
  ## RGBA image placed by m (image pixels -> output), bilinear.
  if img.w <= 0 or img.h <= 0: return
  let inv = invert(m)
  var x0 = Inf
  var y0 = Inf
  var x1 = -Inf
  var y1 = -Inf
  for (px, py) in [(0.0, 0.0), (img.w.float, 0.0), (img.w.float, img.h.float), (0.0, img.h.float)]:
    let p = m.apply(px, py)
    x0 = min(x0, p.x); y0 = min(y0, p.y); x1 = max(x1, p.x); y1 = max(y1, p.y)
  let ya = max(0, int(floor(y0)))
  let yb = min(r.h - 1, int(ceil(y1)) - 1)
  let xa = max(0, int(floor(x0)))
  let xb = min(r.w - 1, int(ceil(x1)) - 1)
  let sc = scaleOf(m)
  for y in ya .. yb:
    for x in xa .. xb:
      let p = inv.apply(x.float + 0.5, y.float + 0.5)
      if p.x < 0 or p.y < 0 or p.x >= img.w.float or p.y >= img.h.float: continue
      var cr, cg, cb, ca: float
      if sc >= 1.0:
        let fx = clamp(p.x - 0.5, 0, img.w.float - 1)
        let fy = clamp(p.y - 0.5, 0, img.h.float - 1)
        let ix = int(fx)
        let iy = int(fy)
        let ix2 = min(ix + 1, img.w - 1)
        let iy2 = min(iy + 1, img.h - 1)
        let tx = fx - ix.float
        let ty = fy - iy.float
        for (xx, yy, wgt) in [(ix, iy, (1 - tx) * (1 - ty)), (ix2, iy, tx * (1 - ty)),
                              (ix, iy2, (1 - tx) * ty), (ix2, iy2, tx * ty)]:
          let o = (yy * img.w + xx) * 4
          let al = img.px[o + 3].float / 255
          cr += img.px[o].float / 255 * al * wgt
          cg += img.px[o + 1].float / 255 * al * wgt
          cb += img.px[o + 2].float / 255 * al * wgt
          ca += al * wgt
      else:
        # downscaling: average of a small area of the source image
        let k = clamp(int(1 / sc), 1, 8)
        let ix = int(p.x)
        let iy = int(p.y)
        var n = 0.0
        for yy in max(0, iy - k div 2) .. min(img.h - 1, iy + k div 2):
          for xx in max(0, ix - k div 2) .. min(img.w - 1, ix + k div 2):
            let o = (yy * img.w + xx) * 4
            let al = img.px[o + 3].float / 255
            cr += img.px[o].float / 255 * al
            cg += img.px[o + 1].float / 255 * al
            cb += img.px[o + 2].float / 255 * al
            ca += al
            n += 1
        if n > 0:
          cr /= n; cg /= n; cb /= n; ca /= n
      if ca <= 0.001: continue
      r.blendPx(x, y, VColor(r: cr / ca, g: cg / ca, b: cb / ca, a: ca), opacity)

proc toRgba8*(r: Raster): seq[uint8] =
  ## R, G, B, A bytes (non-premultiplied).
  result = newSeq[uint8](r.w * r.h * 4)
  for i in 0 ..< r.w * r.h:
    let a = r.px[4*i+3]
    if a <= 0.0001: continue
    result[4*i] = uint8(clamp(r.px[4*i] / a * 255 + 0.5, 0, 255))
    result[4*i+1] = uint8(clamp(r.px[4*i+1] / a * 255 + 0.5, 0, 255))
    result[4*i+2] = uint8(clamp(r.px[4*i+2] / a * 255 + 0.5, 0, 255))
    result[4*i+3] = uint8(clamp(a * 255 + 0.5, 0, 255))

#
# images (cache)
#

var imgLock: Lock
initLock(imgLock)
var imgCache {.global.}: Table[string, tuple[stamp: int64, img: RgbaImage]]
var svgCache {.global.}: Table[string, tuple[stamp: int64, scene: VScene]]

proc resolveHref*(sc: VScene, href: string): string =
  if href.len == 0 or href.startsWith("data:"): return href
  if isAbsolute(href) or sc == nil or sc.base.len == 0: href else: sc.base / href

proc stampOf(path: string): int64 =
  try: getLastModificationTime(path).toUnix * 1000 + int64(getFileSize(path) mod 1000)
  except CatchableError: -1

proc decodeBmp*(data: string): RgbaImage =
  ## Uncompressed 24- or 32-bit BMP.
  if data.len < 54 or data[0 .. 1] != "BM": raise newException(ValueError, "BMP illisible")
  proc u32(i: int): int = ord(data[i]) or (ord(data[i+1]) shl 8) or (ord(data[i+2]) shl 16) or (ord(data[i+3]) shl 24)
  proc u16(i: int): int = ord(data[i]) or (ord(data[i+1]) shl 8)
  let off = u32(10)
  let w = u32(18)
  var h = int(cast[int32](uint32(u32(22))))
  let bpp = u16(28)
  if bpp notin [24, 32]: raise newException(ValueError, "BMP : profondeur non prise en charge")
  let topDown = h < 0
  h = abs(h)
  result.w = w
  result.h = h
  result.px = newSeq[uint8](w * h * 4)
  let stride = ((w * bpp div 8) + 3) and not 3
  for y in 0 ..< h:
    let sy = if topDown: y else: h - 1 - y
    for x in 0 ..< w:
      let o = off + sy * stride + x * (bpp div 8)
      if o + 2 >= data.len: continue
      let d = (y * w + x) * 4
      result.px[d] = uint8(ord(data[o + 2]))
      result.px[d + 1] = uint8(ord(data[o + 1]))
      result.px[d + 2] = uint8(ord(data[o]))
      result.px[d + 3] = (if bpp == 32: uint8(ord(data[o + 3])) else: 255'u8)

proc loadRgba*(path: string): RgbaImage =
  ## Decoded image (PNG, JPEG, BMP; data:image/...;base64 too), cached.
  if path.startsWith("data:"):
    let k = path.find(",")
    if k < 0: return
    try: return decodeImageData(decode(path[k + 1 .. ^1]))
    except CatchableError: return
  let st = stampOf(path)
  if st < 0: return
  {.cast(gcsafe).}:
    withLock imgLock:
      if imgCache.hasKey(path) and imgCache[path].stamp == st: return imgCache[path].img
  try:
    if path.toLowerAscii.endsWith(".bmp"):
      result = decodeBmp(readFile(path))
    elif path.toLowerAscii.endsWith(".gif"):
      result = decodeGif(readFile(path))
    else:
      result = decodeImageFile(path)
  except CatchableError:
    return
  {.cast(gcsafe).}:
    withLock imgLock:
      if imgCache.len > 64: imgCache.clear()
      imgCache[path] = (st, result)

#
# rendering
#

proc parseSvgScene*(code: string, base = ""): VScene

proc loadSvgScene*(path: string): VScene =
  let st = stampOf(path)
  if st < 0: return nil
  {.cast(gcsafe).}:
    withLock imgLock:
      if svgCache.hasKey(path) and svgCache[path].stamp == st: return svgCache[path].scene
  try:
    result = parseSvgScene(readFile(path), path.parentDir)
  except CatchableError:
    return nil
  {.cast(gcsafe).}:
    withLock imgLock:
      if svgCache.len > 64: svgCache.clear()
      svgCache[path] = (st, result)

proc shapePaint(fillSpec: string, box: tuple[x, y, w, h: float], m: Affine, opacity: float): (bool, Paint) =
  var g: Gradient
  if parseGradient(fillSpec, g):
    let a = degToRad(g.angle)
    let cx = box.x + box.w / 2
    let cy = box.y + box.h / 2
    let half = (abs(cos(a)) * box.w + abs(sin(a)) * box.h) / 2
    let p1 = m.apply(cx - cos(a) * half, cy - sin(a) * half)
    let p2 = m.apply(cx + cos(a) * half, cy + sin(a) * half)
    return (true, Paint(kind: pkLinear, c1: g.c1, c2: g.c2, x1: p1.x, y1: p1.y, x2: p2.x, y2: p2.y, opacity: opacity))
  var ok: bool
  let c = parseColor(fillSpec, ok)
  if not ok: return (false, Paint())
  (true, solid(c, opacity))

proc outline*(s: VShape, m: Affine): seq[seq[FPoint]] =
  ## Outlines of the shape (output), rotation included.
  let mm = mul(m, s.shapeMatrix)
  case s.kind
  of vkRect: @[roundRectPts(s.x, s.y, s.w, s.h, s.rx, mm)]
  of vkEllipse: @[ellipsePts(s.x + s.w / 2, s.y + s.h / 2, s.w / 2, s.h / 2, mm)]
  of vkImage: @[roundRectPts(s.x, s.y, s.w, s.h, 0, mm)]
  of vkText:
    @[roundRectPts(s.x, s.y, s.textBoxWidth, s.h, 0, mm)]
  of vkLine, vkPath:
    var res: seq[seq[FPoint]]
    for sub in s.subs: res.add flattenSub(sub, mm)
    res

proc renderScene*(sc: VScene, r: var Raster, m: Affine, skip: HashSet[string] = initHashSet[string](),
                  depth = 0)

proc renderText(s: VShape, r: var Raster, m: Affine) =
  when defined(sdlttf):
    var ok: bool
    let col = parseColor(s.fill, ok)
    if not ok: return
    let sc = scaleOf(m)
    let px = int(round(s.fontSize * sc))
    if px < 3: return
    let lines = s.wrapLines
    let boxW = s.textBoxWidth
    let mm = mul(m, s.shapeMatrix)
    {.cast(gcsafe).}:
      withLock fontLock:
        let f = fontAt(s.font, s.bold, s.italic, px)
        if f == nil: return
        for i, line in lines:
          if line.len == 0: continue
          let surf = TTF_RenderText_Blended(f, line.cstring, csize_t(line.len), SDL_Color(r: 255, g: 255, b: 255, a: 255))
          if surf == nil: continue
          let sv = cast[ptr SurfView](surf)
          let sw = int(sv.w)
          let sh = int(sv.h)
          var mask = newSeq[uint8](sw * sh)
          let base = cast[ptr UncheckedArray[uint8]](sv.pixels)
          for yy in 0 ..< sh:
            for xx in 0 ..< sw:
              mask[yy * sw + xx] = base[yy * int(sv.pitch) + xx * 4 + 3]
          SDL_DestroySurface(surf)
          # line width in the scene (measured at the rendering size)
          let lw = sw.float / sc
          let lx = case s.align
                   of "centre", "center", "middle": s.x + (boxW - lw) / 2
                   of "droite", "right", "end": s.x + boxW - lw
                   else: s.x
          let ly = s.y + i.float * s.lineStep + (s.lineStep - sh.float / sc) / 2
          # mask (render pixels) -> scene -> output
          let place = mul(mm, mul(translateM(lx, ly), scaleM(1 / sc, 1 / sc)))
          r.blendMask(mask, sw, sh, place, col, s.opacity)

proc renderShape*(sc: VScene, s: VShape, r: var Raster, m: Affine, depth = 0) =
  let mm = mul(m, s.shapeMatrix)
  let sScale = scaleOf(m)
  let box = s.rawBounds
  if s.shadow:
    var polys = s.outline(m)
    let off = 6 * sScale
    for p in polys.mitems:
      for q in p.mitems: q = (q.x + off, q.y + off * 1.4)
    for k in 0 .. 3:
      var grown: seq[seq[FPoint]]
      for p in polys:
        var cx, cy: float
        for q in p: cx += q.x; cy += q.y
        cx /= max(1, p.len).float; cy /= max(1, p.len).float
        let f = 1 + (k.float * 3 * sScale) / max(1.0, max(box.w, box.h) * sScale)
        var g: seq[FPoint]
        for q in p: g.add (cx + (q.x - cx) * f, cy + (q.y - cy) * f)
        grown.add g
      r.fillPolys(grown, solid(VColor(r: 0, g: 0, b: 0, a: 0.07), s.opacity), s.evenOdd)
  case s.kind
  of vkImage:
    let path = resolveHref(sc, s.href)
    if path.toLowerAscii.endsWith(".svg"):
      if depth < 4:
        let sub = loadSvgScene(path)
        if sub != nil and sub.width > 0 and sub.height > 0:
          let place = mul(mm, mul(translateM(s.x, s.y), scaleM(s.w / sub.width, s.h / sub.height)))
          var tmp = newRaster(r.w, r.h)
          renderScene(sub, tmp, place, initHashSet[string](), depth + 1)
          # compositing with the image opacity
          for i in 0 ..< r.w * r.h:
            let a = tmp.px[4*i+3] * float32(s.opacity)
            if a <= 0.0001: continue
            let ia = 1 - a
            r.px[4*i] = tmp.px[4*i] * float32(s.opacity) + r.px[4*i] * ia
            r.px[4*i+1] = tmp.px[4*i+1] * float32(s.opacity) + r.px[4*i+1] * ia
            r.px[4*i+2] = tmp.px[4*i+2] * float32(s.opacity) + r.px[4*i+2] * ia
            r.px[4*i+3] = a + r.px[4*i+3] * ia
    else:
      let img = loadRgba(path)
      if img.w > 0 and img.h > 0:
        let place = mul(mm, mul(translateM(s.x, s.y), scaleM(s.w / img.w.float, s.h / img.h.float)))
        r.blendImage(img, place, s.opacity)
      else:
        r.fillPolys(s.outline(m), solid(VColor(r: 0.6, g: 0.62, b: 0.66, a: 0.35), s.opacity))
    if paintVisible(s.stroke) and s.strokeWidth > 0:
      let (_, p) = shapePaint(s.stroke, box, m, s.opacity)
      for poly in s.outline(m): r.fillPolys(strokePolys(poly, s.strokeWidth * sScale, true), p)
    return
  of vkText:
    if paintVisible(s.stroke) and s.stroke != s.fill:
      discard
    renderText(s, r, m)
    return
  else: discard
  let polys = s.outline(m)
  let closedShape = s.kind in {vkRect, vkEllipse} or (s.kind == vkPath and s.subs.len > 0 and s.subs.allIt(it.closed))
  if s.kind != vkLine and paintVisible(s.fill):
    var fillPolys: seq[seq[FPoint]]
    if s.kind == vkPath:
      for i, sub in s.subs:
        if i < polys.len and polys[i].len >= 3: fillPolys.add polys[i]
    else: fillPolys = polys
    if not closedShape and s.kind == vkPath:
      discard        # open path: filled anyway (as in SVG)
    let (ok, p) = shapePaint(s.fill, box, m, s.opacity)
    if ok: r.fillPolys(fillPolys, p, s.evenOdd)
  if paintVisible(s.stroke) and s.strokeWidth > 0:
    let (ok, p) = shapePaint(s.stroke, box, m, s.opacity)
    if ok:
      let w = s.strokeWidth * sScale
      var pattern: seq[float]
      for part in s.dash.replace(" ", ",").split(','):
        try:
          if part.strip.len > 0: pattern.add parseFloat(part.strip) * sScale
        except ValueError: discard
      for i, poly in polys:
        let closed = s.kind in {vkRect, vkEllipse} or (s.kind == vkPath and i < s.subs.len and s.subs[i].closed)
        if pattern.len > 0:
          for piece in dashed(poly, closed, pattern): r.fillPolys(strokePolys(piece, w, false), p)
        else:
          r.fillPolys(strokePolys(poly, w, closed), p)
      if s.kind in {vkLine, vkPath} and polys.len > 0 and polys[0].len >= 2:
        let a = polys[0]
        let sz = max(8.0 * sScale, w * 3.2)
        if s.arrowEnd: r.fillPolys(@[arrowPoly(a[^1], a[^2], sz)], p)
        if s.arrowStart: r.fillPolys(@[arrowPoly(a[0], a[1], sz)], p)

proc renderScene*(sc: VScene, r: var Raster, m: Affine, skip: HashSet[string] = initHashSet[string](),
                  depth = 0) =
  ## Draws the visible shapes (layer order, then shape order).
  var bg: Gradient
  if sc.background.len > 0:
    let bbox = (x: 0.0, y: 0.0, w: sc.width, h: sc.height)
    let (ok, p) = shapePaint(sc.background, bbox, m, 1)
    if ok:
      r.fillPolys(@[roundRectPts(0, 0, sc.width, sc.height, 0, m)], p)
  discard bg
  var order: seq[int]
  for li in 0 ..< sc.layers.len: order.add li
  # shapes without a known layer: with the first layer
  for li in order:
    if not sc.layers[li].visible: continue
    for s in sc.shapes:
      if s.id in skip or s.hidden: continue
      let k = sc.layerOf(s.layer)
      let lk = if k < 0: 0 else: k
      if lk != li: continue
      renderShape(sc, s, r, m, depth)
  if sc.layers.len == 0:
    for s in sc.shapes:
      if s.id notin skip and not s.hidden: renderShape(sc, s, r, m, depth)

proc renderToRgba*(sc: VScene, w, h: int, bg = VColor()): seq[uint8] =
  ## Renders the whole scene into w×h pixels (scaled without distortion, centered).
  var r = newRaster(w, h, bg)
  if sc.width > 0 and sc.height > 0:
    let k = min(w.float / sc.width, h.float / sc.height)
    let m = mul(translateM((w.float - sc.width * k) / 2, (h.float - sc.height * k) / 2), scaleM(k, k))
    renderScene(sc, r, m)
  r.toRgba8

#
# hit testing
#

proc pointInPolys(polys: seq[seq[FPoint]], x, y: float, evenOdd: bool): bool =
  var wind = 0
  var cross = 0
  for poly in polys:
    let n = poly.len
    for i in 0 ..< n:
      let a = poly[i]
      let b = poly[(i + 1) mod n]
      if (a.y <= y) != (b.y <= y):
        let t = (y - a.y) / (b.y - a.y)
        if a.x + t * (b.x - a.x) > x:
          inc cross
          wind += (if b.y > a.y: 1 else: -1)
  if evenOdd: (cross and 1) == 1 else: wind != 0

proc distToPoly(poly: seq[FPoint], x, y: float, closed: bool): float =
  result = Inf
  let n = poly.len
  if n == 1: return hypot(poly[0].x - x, poly[0].y - y)
  let segs = if closed: n else: n - 1
  for i in 0 ..< segs:
    let a = poly[i]
    let b = poly[(i + 1) mod n]
    let dx = b.x - a.x
    let dy = b.y - a.y
    let L2 = dx*dx + dy*dy
    let t = if L2 < 1e-12: 0.0 else: clamp(((x - a.x)*dx + (y - a.y)*dy) / L2, 0, 1)
    result = min(result, hypot(a.x + t*dx - x, a.y + t*dy - y))

proc hitShape*(s: VShape, x, y, tol: float): bool =
  ## True if the point (scene) touches the shape (tol: tolerance in scene units).
  let b = s.bounds
  if x < b.x - tol - s.strokeWidth or y < b.y - tol - s.strokeWidth or
     x > b.x + b.w + tol + s.strokeWidth or y > b.y + b.h + tol + s.strokeWidth: return false
  case s.kind
  of vkText, vkImage: true
  of vkRect, vkEllipse:
    let polys = s.outline(Identity)
    if paintVisible(s.fill) and pointInPolys(polys, x, y, false): return true
    distToPoly(polys[0], x, y, true) <= tol + s.strokeWidth / 2
  of vkLine, vkPath:
    let polys = s.outline(Identity)
    if s.kind == vkPath and paintVisible(s.fill) and pointInPolys(polys, x, y, s.evenOdd): return true
    for i, p in polys:
      let closed = s.kind == vkPath and i < s.subs.len and s.subs[i].closed
      if distToPoly(p, x, y, closed) <= tol + s.strokeWidth / 2: return true
    false

#
# SVG reading
#

type
  XNode = ref object
    tag: string
    attrs: Table[string, string]
    kids: seq[XNode]
    text: string

proc xmlUnescape(s: string): string =
  if '&' notin s: return s
  result = s.multiReplace(("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&#39;", "'"),
                          ("&nbsp;", " "))
  var i = 0
  var o = ""
  while i < result.len:
    if result[i] == '&' and i + 2 < result.len and result[i + 1] == '#':
      let e = result.find(';', i)
      if e > 0:
        let num = result[i + 2 ..< e]
        try:
          let v = if num.startsWith("x"): parseHexInt(num[1 .. ^1]) else: parseInt(num)
          o.add $Rune(v)
          i = e + 1
          continue
        except ValueError: discard
    o.add result[i]
    inc i
  result = o.replace("&amp;", "&")

proc parseXml(s: string): XNode =
  ## Minimal XML parser (elements, attributes, text; comments, CDATA, <?…?> ignored).
  result = XNode(tag: "#document")
  var stack = @[result]
  var i = 0
  let n = s.len
  while i < n:
    if s[i] == '<':
      if s.continuesWith("<!--", i):
        let e = s.find("-->", i + 4)
        i = if e < 0: n else: e + 3
        continue
      if s.continuesWith("<![CDATA[", i):
        let e = s.find("]]>", i + 9)
        let t = if e < 0: s[i + 9 .. ^1] else: s[i + 9 ..< e]
        stack[^1].text.add t
        i = if e < 0: n else: e + 3
        continue
      if s.continuesWith("<?", i) or s.continuesWith("<!", i):
        let e = s.find('>', i)
        i = if e < 0: n else: e + 1
        continue
      if s.continuesWith("</", i):
        let e = s.find('>', i)
        if stack.len > 1: stack.setLen(stack.len - 1)
        i = if e < 0: n else: e + 1
        continue
      # opening tag
      var j = i + 1
      while j < n and s[j] notin {' ', '\t', '\n', '\r', '/', '>'}: inc j
      let node = XNode(tag: s[i + 1 ..< j].toLowerAscii)
      if ':' in node.tag: node.tag = node.tag.split(':')[^1]
      var selfClose = false
      while j < n:
        while j < n and s[j] in {' ', '\t', '\n', '\r'}: inc j
        if j >= n: break
        if s[j] == '/':
          selfClose = true
          inc j
          continue
        if s[j] == '>':
          inc j
          break
        var k = j
        while k < n and s[k] notin {'=', ' ', '\t', '\n', '\r', '>', '/'}: inc k
        let name = s[j ..< k].toLowerAscii
        j = k
        while j < n and s[j] in {' ', '\t', '\n', '\r'}: inc j
        var value = ""
        if j < n and s[j] == '=':
          inc j
          while j < n and s[j] in {' ', '\t', '\n', '\r'}: inc j
          if j < n and s[j] in {'"', '\''}:
            let q = s[j]
            let e = s.find(q, j + 1)
            value = if e < 0: s[j + 1 .. ^1] else: s[j + 1 ..< e]
            j = if e < 0: n else: e + 1
          else:
            var e = j
            while e < n and s[e] notin {' ', '>', '\t', '\n'}: inc e
            value = s[j ..< e]
            j = e
        if name.len > 0: node.attrs[name] = xmlUnescape(value)
      stack[^1].kids.add node
      if not selfClose: stack.add node
      i = j
    else:
      let e = s.find('<', i)
      let t = if e < 0: s[i .. ^1] else: s[i ..< e]
      stack[^1].text.add xmlUnescape(t)
      i = if e < 0: n else: e

proc numbersIn(s: string): seq[float] =
  var i = 0
  let n = s.len
  while i < n:
    while i < n and s[i] notin {'0'..'9', '-', '+', '.'}: inc i
    if i >= n: break
    var j = i
    if s[j] in {'-', '+'}: inc j
    var dot = false
    while j < n and (s[j] in {'0'..'9'} or (s[j] == '.' and not dot)):
      if s[j] == '.': dot = true
      inc j
    if j < n and s[j] in {'e', 'E'}:
      var k = j + 1
      if k < n and s[k] in {'-', '+'}: inc k
      if k < n and s[k] in {'0'..'9'}:
        j = k
        while j < n and s[j] in {'0'..'9'}: inc j
    try: result.add parseFloat(s[i ..< j])
    except ValueError: discard
    i = max(j, i + 1)

proc parseTransform*(s: string): Affine =
  result = Identity
  var i = 0
  while i < s.len:
    let a = s.find('(', i)
    if a < 0: break
    let b = s.find(')', a)
    if b < 0: break
    let name = s[i ..< a].strip(chars = {' ', ',', '\t', '\n'}).toLowerAscii
    let v = numbersIn(s[a + 1 ..< b])
    var t = Identity
    case name
    of "matrix":
      if v.len == 6: t = [v[0], v[1], v[2], v[3], v[4], v[5]]
    of "translate":
      if v.len >= 1: t = translateM(v[0], if v.len > 1: v[1] else: 0)
    of "scale":
      if v.len >= 1: t = scaleM(v[0], if v.len > 1: v[1] else: v[0])
    of "rotate":
      if v.len >= 1: t = rotateM(v[0], if v.len > 2: v[1] else: 0, if v.len > 2: v[2] else: 0)
    of "skewx":
      if v.len >= 1: t = [1.0, 0, tan(degToRad(v[0])), 1, 0, 0]
    of "skewy":
      if v.len >= 1: t = [1.0, tan(degToRad(v[0])), 0, 1, 0, 0]
    else: discard
    result = mul(result, t)
    i = b + 1

proc arcToCubics(x1, y1, rx0, ry0, phiDeg: float, large, sweep: bool, x2, y2: float): seq[array[6, float]] =
  ## SVG elliptical arc as cubic Bézier curves (c1x c1y c2x c2y x y).
  if (x1 == x2 and y1 == y2): return
  var rx = abs(rx0)
  var ry = abs(ry0)
  if rx < 1e-9 or ry < 1e-9:
    return @[[x1, y1, x2, y2, x2, y2]]
  let phi = degToRad(phiDeg)
  let cp = cos(phi)
  let sp = sin(phi)
  let dx = (x1 - x2) / 2
  let dy = (y1 - y2) / 2
  let x1p = cp * dx + sp * dy
  let y1p = -sp * dx + cp * dy
  var lam = (x1p*x1p) / (rx*rx) + (y1p*y1p) / (ry*ry)
  if lam > 1:
    rx *= sqrt(lam); ry *= sqrt(lam)
  var num = rx*rx*ry*ry - rx*rx*y1p*y1p - ry*ry*x1p*x1p
  if num < 0: num = 0
  var coef = sqrt(num / (rx*rx*y1p*y1p + ry*ry*x1p*x1p))
  if large == sweep: coef = -coef
  let cxp = coef * rx * y1p / ry
  let cyp = -coef * ry * x1p / rx
  let cx = cp * cxp - sp * cyp + (x1 + x2) / 2
  let cy = sp * cxp + cp * cyp + (y1 + y2) / 2
  proc ang(ux, uy, vx, vy: float): float =
    let d = arctan2(ux*vy - uy*vx, ux*vx + uy*vy)
    d
  let th1 = ang(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
  var dth = ang((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
  if not sweep and dth > 0: dth -= 2 * PI
  elif sweep and dth < 0: dth += 2 * PI
  let segs = max(1, int(ceil(abs(dth) / (PI / 2) - 1e-9)))
  let delta = dth / segs.float
  let t = 4.0 / 3.0 * tan(delta / 4)
  var th = th1
  for i in 0 ..< segs:
    let c1 = cos(th)
    let s1 = sin(th)
    let c2 = cos(th + delta)
    let s2 = sin(th + delta)
    proc pt(x, y: float): (float, float) = (cp * rx * x - sp * ry * y + cx, sp * rx * x + cp * ry * y + cy)
    let p1 = pt(c1 - t * s1, s1 + t * c1)
    let p2 = pt(c2 + t * s2, s2 - t * c2)
    let p3 = pt(c2, s2)
    result.add [p1[0], p1[1], p2[0], p2[1], p3[0], p3[1]]
    th += delta

proc parsePathData*(d: string): seq[VSub] =
  ## SVG path data as sub-paths (quadratic curves and arcs converted to cubics).
  var subs: seq[VSub]
  var cur: VSub
  var x, y, sx, sy: float
  var lastCtrlX, lastCtrlY: float
  var lastCmd = ' '
  var i = 0
  let n = d.len
  proc flush() =
    if cur.pts.len > 0: subs.add cur
    cur = VSub()
  proc readNum(): (bool, float) =
    while i < n and d[i] in {' ', ',', '\t', '\n', '\r'}: inc i
    if i >= n: return (false, 0.0)
    if d[i] notin {'0'..'9', '-', '+', '.'}: return (false, 0.0)
    var j = i
    if d[j] in {'-', '+'}: inc j
    var dot = false
    while j < n and (d[j] in {'0'..'9'} or (d[j] == '.' and not dot)):
      if d[j] == '.': dot = true
      inc j
    if j < n and d[j] in {'e', 'E'}:
      var k = j + 1
      if k < n and d[k] in {'-', '+'}: inc k
      if k < n and d[k] in {'0'..'9'}:
        j = k
        while j < n and d[j] in {'0'..'9'}: inc j
    var v = 0.0
    try: v = parseFloat(d[i ..< j])
    except ValueError: discard
    i = j
    (true, v)
  proc readFlag(): (bool, bool) =
    while i < n and d[i] in {' ', ',', '\t', '\n', '\r'}: inc i
    if i < n and d[i] in {'0', '1'}:
      let f = d[i] == '1'
      inc i
      return (true, f)
    (false, false)
  proc lineTo(nx, ny: float) =
    cur.pts.add VPt(x: nx, y: ny)
    x = nx
    y = ny
  proc cubicTo(c1x, c1y, c2x, c2y, nx, ny: float) =
    if cur.pts.len == 0: cur.pts.add VPt(x: x, y: y)
    cur.pts[^1].ox = c1x - cur.pts[^1].x
    cur.pts[^1].oy = c1y - cur.pts[^1].y
    cur.pts.add VPt(x: nx, y: ny, ix: c2x - nx, iy: c2y - ny)
    lastCtrlX = c2x
    lastCtrlY = c2y
    x = nx
    y = ny
  var cmd = ' '
  while i < n:
    while i < n and d[i] in {' ', ',', '\t', '\n', '\r'}: inc i
    if i >= n: break
    if d[i] in {'a'..'z', 'A'..'Z'}:
      cmd = d[i]
      inc i
    elif cmd == ' ': break
    let rel = cmd in {'a'..'z'}
    let up = cmd.toUpperAscii
    case up
    of 'M':
      let (ok1, a) = readNum()
      let (ok2, b) = readNum()
      if not (ok1 and ok2): break
      flush()
      let nx = if rel: x + a else: a
      let ny = if rel: y + b else: b
      cur.pts.add VPt(x: nx, y: ny)
      x = nx; y = ny; sx = nx; sy = ny
      cmd = if rel: 'l' else: 'L'
      lastCmd = 'M'
      continue
    of 'L':
      let (ok1, a) = readNum()
      let (ok2, b) = readNum()
      if not (ok1 and ok2): break
      if cur.pts.len == 0: cur.pts.add VPt(x: x, y: y)
      lineTo(if rel: x + a else: a, if rel: y + b else: b)
    of 'H':
      let (ok1, a) = readNum()
      if not ok1: break
      if cur.pts.len == 0: cur.pts.add VPt(x: x, y: y)
      lineTo(if rel: x + a else: a, y)
    of 'V':
      let (ok1, a) = readNum()
      if not ok1: break
      if cur.pts.len == 0: cur.pts.add VPt(x: x, y: y)
      lineTo(x, if rel: y + a else: a)
    of 'C':
      var v: array[6, float]
      var ok = true
      for k in 0 .. 5:
        let (o, a) = readNum()
        if not o: ok = false
        v[k] = a
      if not ok: break
      if rel:
        for k in 0 .. 2:
          v[2*k] += x; v[2*k+1] += y
      cubicTo(v[0], v[1], v[2], v[3], v[4], v[5])
    of 'S':
      var v: array[4, float]
      var ok = true
      for k in 0 .. 3:
        let (o, a) = readNum()
        if not o: ok = false
        v[k] = a
      if not ok: break
      if rel:
        v[0] += x; v[1] += y; v[2] += x; v[3] += y
      var c1x = x
      var c1y = y
      if lastCmd in {'C', 'S'}:
        c1x = 2 * x - lastCtrlX
        c1y = 2 * y - lastCtrlY
      cubicTo(c1x, c1y, v[0], v[1], v[2], v[3])
    of 'Q', 'T':
      var qx, qy, nx, ny: float
      if up == 'Q':
        var v: array[4, float]
        var ok = true
        for k in 0 .. 3:
          let (o, a) = readNum()
          if not o: ok = false
          v[k] = a
        if not ok: break
        if rel:
          v[0] += x; v[1] += y; v[2] += x; v[3] += y
        qx = v[0]; qy = v[1]; nx = v[2]; ny = v[3]
      else:
        let (o1, a) = readNum()
        let (o2, b) = readNum()
        if not (o1 and o2): break
        nx = if rel: x + a else: a
        ny = if rel: y + b else: b
        if lastCmd in {'Q', 'T'}:
          qx = 2 * x - lastCtrlX
          qy = 2 * y - lastCtrlY
        else:
          qx = x; qy = y
      let c1x = x + 2 / 3 * (qx - x)
      let c1y = y + 2 / 3 * (qy - y)
      let c2x = nx + 2 / 3 * (qx - nx)
      let c2y = ny + 2 / 3 * (qy - ny)
      cubicTo(c1x, c1y, c2x, c2y, nx, ny)
      lastCtrlX = qx
      lastCtrlY = qy
    of 'A':
      let (o1, rx) = readNum()
      let (o2, ry) = readNum()
      let (o3, rot) = readNum()
      let (o4, lg) = readFlag()
      let (o5, sw) = readFlag()
      let (o6, a) = readNum()
      let (o7, b) = readNum()
      if not (o1 and o2 and o3 and o4 and o5 and o6 and o7): break
      let nx = if rel: x + a else: a
      let ny = if rel: y + b else: b
      if cur.pts.len == 0: cur.pts.add VPt(x: x, y: y)
      let cs = arcToCubics(x, y, rx, ry, rot, lg, sw, nx, ny)
      if cs.len == 0: lineTo(nx, ny)
      for c in cs: cubicTo(c[0], c[1], c[2], c[3], c[4], c[5])
    of 'Z':
      if cur.pts.len > 0:
        cur.closed = true
        # last node coincides with the first: merge
        if cur.pts.len > 1 and abs(cur.pts[^1].x - cur.pts[0].x) < 1e-6 and abs(cur.pts[^1].y - cur.pts[0].y) < 1e-6:
          cur.pts[0].ix = cur.pts[^1].ix
          cur.pts[0].iy = cur.pts[^1].iy
          cur.pts.setLen(cur.pts.len - 1)
      flush()
      x = sx; y = sy
      cur.pts = @[]
      lastCmd = 'Z'
      # a following command without M restarts from the starting point
      cur.pts.add VPt(x: x, y: y)
      cmd = ' '
      continue
    else:
      inc i
      continue
    lastCmd = up
  if cur.pts.len > 1 or (cur.pts.len == 1 and cur.closed): subs.add cur
  # removes the single-point sub-paths left by Z
  for s in subs:
    if s.pts.len > 1: result.add s

type StyleState = object
  fill, stroke: string
  color: string                  # current color ("currentColor")
  strokeWidth, opacity, fontSize: float
  font, align, layer, group, dash: string
  bold, italic, hidden: bool
  m: Affine

proc styleMap(at: Table[string, string]): Table[string, string] =
  result = at
  if at.hasKey("style"):
    for decl in at["style"].split(';'):
      let k = decl.find(':')
      if k > 0: result[decl[0 ..< k].strip.toLowerAscii] = decl[k + 1 .. ^1].strip

proc num(at: Table[string, string], k: string, d = 0.0): float =
  if not at.hasKey(k): return d
  let v = numbersIn(at[k])
  if v.len == 0: d else: v[0]

proc parseSvgScene*(code: string, base = ""): VScene =
  ## Reads an SVG document into an editable scene (transforms are applied to the
  ## coordinates: rotation kept for boxes, otherwise converted to a path).
  result = newScene(0, 0)
  result.base = base
  let sc = result
  let doc = parseXml(code)
  var gradients: Table[string, string]
  # gradients (first and last stop)
  proc collect(nd: XNode) =
    if nd.tag == "lineargradient" and nd.attrs.hasKey("id"):
      var stops: seq[string]
      for k in nd.kids:
        if k.tag == "stop":
          let st = styleMap(k.attrs)
          var c = st.getOrDefault("stop-color", "#000000")
          if st.hasKey("stop-opacity"):
            var ok: bool
            var col = parseColor(c, ok)
            if ok:
              col.a = num(st, "stop-opacity", 1)
              c = hexColor(col)
          stops.add c
      if stops.len >= 1:
        let x1 = num(nd.attrs, "x1", 0)
        let y1 = num(nd.attrs, "y1", 0)
        var x2 = num(nd.attrs, "x2", 1)
        var y2 = num(nd.attrs, "y2", 0)
        if nd.attrs.hasKey("x2") and nd.attrs["x2"].endsWith("%"): x2 /= 100
        if nd.attrs.hasKey("y2") and nd.attrs["y2"].endsWith("%"): y2 /= 100
        let ang = radToDeg(arctan2(y2 - y1, x2 - x1))
        gradients[nd.attrs["id"]] = "linear(" & formatFloat(ang, ffDecimal, 1) & "," & stops[0] & "," & stops[^1] & ")"
    for k in nd.kids: collect(k)
  collect(doc)
  # named elements (targets of <use href="#id">)
  var ids: Table[string, XNode]
  proc index(nd: XNode) =
    if nd.attrs.hasKey("id") and not ids.hasKey(nd.attrs["id"]): ids[nd.attrs["id"]] = nd
    for k in nd.kids: index(k)
  index(doc)
  var useDepth = 0
  proc paintOf(v, inherited: string): string =
    let t = v.strip
    if t.startsWith("url("):
      let a = t.find('#')
      let b = t.find(')')
      if a > 0 and b > a:
        let id = t[a + 1 ..< b].strip(chars = {'\'', '"', ' '})
        return gradients.getOrDefault(id, "#808080")
      return "#808080"
    if t == "inherit": return inherited
    t
  var root: XNode
  proc findSvg(nd: XNode): XNode =
    if nd.tag == "svg": return nd
    for k in nd.kids:
      let r = findSvg(k)
      if r != nil: return r
  root = findSvg(doc)
  if root == nil: raise newException(ValueError, "pas d'élément <svg>")
  var m0 = Identity
  let ra = root.attrs
  var w = num(ra, "width", 0)
  var h = num(ra, "height", 0)
  if ra.hasKey("width") and ra["width"].endsWith("%"): w = 0
  if ra.hasKey("height") and ra["height"].endsWith("%"): h = 0
  if ra.hasKey("viewbox"):
    let vb = numbersIn(ra["viewbox"])
    if vb.len == 4 and vb[2] > 0 and vb[3] > 0:
      if w <= 0: w = vb[2]
      if h <= 0: h = vb[3]
      m0 = mul(scaleM(w / vb[2], h / vb[3]), translateM(-vb[0], -vb[1]))
  if w <= 0: w = 800
  if h <= 0: h = 600
  sc.width = w
  sc.height = h
  sc.layers = @[]
  var groupSeq = 0
  proc applyAttrs(st: var StyleState, at: Table[string, string]) =
    let m = styleMap(at)
    if m.hasKey("color") and m["color"].toLowerAscii notin ["inherit", "currentcolor"]: st.color = m["color"]
    let curCol = if st.color.len > 0: st.color else: "#000000"
    proc cur(v: string): string =
      if v.strip.toLowerAscii == "currentcolor": curCol else: v
    if m.hasKey("fill"): st.fill = paintOf(cur(m["fill"]), st.fill)
    if m.hasKey("stroke"): st.stroke = paintOf(cur(m["stroke"]), st.stroke)
    if m.hasKey("stroke-width"): st.strokeWidth = num(m, "stroke-width", 1)
    if m.hasKey("opacity"): st.opacity *= num(m, "opacity", 1)
    if m.hasKey("fill-opacity") and st.fill notin ["", "none"] and not st.fill.startsWith("linear"):
      var ok: bool
      var c = parseColor(st.fill, ok)
      if ok:
        c.a *= num(m, "fill-opacity", 1)
        st.fill = hexColor(c)
    if m.hasKey("stroke-opacity") and st.stroke notin ["", "none"] and not st.stroke.startsWith("linear"):
      var ok: bool
      var c = parseColor(st.stroke, ok)
      if ok:
        c.a *= num(m, "stroke-opacity", 1)
        st.stroke = hexColor(c)
    if m.hasKey("stroke-dasharray"): st.dash = (if m["stroke-dasharray"] == "none": "" else: m["stroke-dasharray"])
    if m.hasKey("font-size"): st.fontSize = num(m, "font-size", st.fontSize)
    if m.hasKey("font-family"): st.font = m["font-family"].split(',')[0].strip(chars = {'\'', '"', ' '})
    if m.hasKey("font-weight"):
      let fw = m["font-weight"]
      st.bold = fw == "bold" or fw == "bolder" or (fw.len > 0 and fw[0] in {'6'..'9'})
    if m.hasKey("font-style"): st.italic = m["font-style"] in ["italic", "oblique"]
    if m.hasKey("text-anchor"):
      st.align = case m["text-anchor"]
                 of "middle": "centre"
                 of "end": "droite"
                 else: "gauche"
    if m.hasKey("display") and m["display"] == "none": st.hidden = true
    if m.hasKey("visibility") and m["visibility"] == "hidden": st.hidden = true
    if at.hasKey("transform"): st.m = mul(st.m, parseTransform(at["transform"]))
  proc finish(s: VShape, nd: XNode, st: StyleState) =
    s.fill = (if st.fill.len == 0: "#000000" else: st.fill)
    s.stroke = (if st.stroke.len == 0: "none" else: st.stroke)
    s.strokeWidth = st.strokeWidth * scaleOf(st.m)
    s.opacity = st.opacity
    s.dash = st.dash
    s.hidden = st.hidden
    s.layer = st.layer
    s.group = st.group
    if nd.attrs.hasKey("id"): s.id = nd.attrs["id"]
    if nd.attrs.hasKey("data-nom"): s.name = nd.attrs["data-nom"]
    if nd.attrs.hasKey("data-composant"): s.data = nd.attrs["data-composant"]
    if nd.attrs.hasKey("data-ombre"): s.shadow = true
    if nd.attrs.hasKey("data-verrou"): s.locked = true
    if nd.attrs.hasKey("marker-end") or nd.attrs.hasKey("data-fleche-fin"): s.arrowEnd = true
    if nd.attrs.hasKey("marker-start") or nd.attrs.hasKey("data-fleche-debut"): s.arrowStart = true
    if sc.findShape(s.id) != nil: s.id = newId()
    sc.shapes.add s
  proc boxed(s: VShape, x, y, w, h: float, m: Affine): VShape =
    ## Box (x, y, w, h) transformed by m: translation and scale applied, rotation
    ## kept; skew: nil (the caller converts to a path).
    let det = m[0]*m[3] - m[1]*m[2]
    let sx = hypot(m[0], m[1])
    let sy = if sx > 1e-12: det / sx else: 0.0
    let ang = radToDeg(arctan2(m[1], m[0]))
    let shear = if sx > 1e-12: (m[0]*m[2] + m[1]*m[3]) / (sx * sx) else: 0.0
    if abs(shear) > 1e-6 or sy <= 0: return nil
    let c = m.apply(x + w / 2, y + h / 2)
    s.w = w * sx
    s.h = h * sy
    s.x = c.x - s.w / 2
    s.y = c.y - s.h / 2
    s.rotation = (if abs(ang) < 1e-6: 0.0 else: ang)
    s
  proc toPath(polyPts: seq[VSub], m: Affine): VShape =
    let s = newShape(vkPath)
    for sub in polyPts:
      var t = sub
      for p in t.pts.mitems:
        let q = m.apply(p.x, p.y)
        let i = m.applyVec(p.ix, p.iy)
        let o = m.applyVec(p.ox, p.oy)
        p.x = q.x; p.y = q.y; p.ix = i.x; p.iy = i.y; p.ox = o.x; p.oy = o.y
      s.subs.add t
    s.syncPathBox
    s
  proc rectSubs(x, y, w, h, r: float): seq[VSub] =
    if r <= 0:
      return @[VSub(closed: true, pts: @[VPt(x: x, y: y), VPt(x: x + w, y: y), VPt(x: x + w, y: y + h), VPt(x: x, y: y + h)])]
    let k = 0.5523 * r
    @[VSub(closed: true, pts: @[
      VPt(x: x + r, y: y, ix: -k), VPt(x: x + w - r, y: y, ox: k), VPt(x: x + w, y: y + r, iy: -k),
      VPt(x: x + w, y: y + h - r, oy: k), VPt(x: x + w - r, y: y + h, ix: k), VPt(x: x + r, y: y + h, ox: -k),
      VPt(x: x, y: y + h - r, iy: k), VPt(x: x, y: y + r, oy: -k)])]
  proc ellipseSubs(cx, cy, rx, ry: float): seq[VSub] =
    let kx = 0.5523 * rx
    let ky = 0.5523 * ry
    @[VSub(closed: true, pts: @[
      VPt(x: cx + rx, y: cy, iy: -ky, oy: ky, smooth: true), VPt(x: cx, y: cy + ry, ix: kx, ox: -kx, smooth: true),
      VPt(x: cx - rx, y: cy, iy: ky, oy: -ky, smooth: true), VPt(x: cx, y: cy - ry, ix: -kx, ox: kx, smooth: true)])]
  proc walk(nd: XNode, st0: StyleState, inDefs: bool) =
    var st = st0
    case nd.tag
    of "defs", "clippath", "mask", "pattern", "symbol", "marker", "style", "lineargradient",
       "radialgradient", "title", "desc", "metadata", "script":
      return
    else: discard
    st.applyAttrs(nd.attrs)
    case nd.tag
    of "g", "svg", "a", "switch":
      if nd != root and nd.tag == "svg": discard
      if nd.attrs.hasKey("data-calque"):
        st.layer = nd.attrs["data-calque"]
        if sc.layerOf(st.layer) < 0:
          sc.layers.add VLayer(name: st.layer, visible: not (nd.attrs.getOrDefault("display") == "none"),
                               locked: nd.attrs.hasKey("data-verrou"))
        st.hidden = false
      elif nd.attrs.hasKey("data-groupe"):
        st.group = nd.attrs["data-groupe"]
      elif nd.tag == "g" and nd.kids.len > 1 and nd != root:
        inc groupSeq
        st.group = (if nd.attrs.hasKey("id"): nd.attrs["id"] else: "g" & $groupSeq)
      for k in nd.kids: walk(k, st, inDefs)
    of "rect":
      let a = styleMap(nd.attrs)
      let x = num(a, "x")
      let y = num(a, "y")
      let w = num(a, "width")
      let h = num(a, "height")
      if w <= 0 or h <= 0: return
      var r = max(num(a, "rx", 0), num(a, "ry", 0))
      if not a.hasKey("rx") and a.hasKey("ry"): r = num(a, "ry")
      var s = newShape(vkRect)
      if boxed(s, x, y, w, h, st.m) != nil:
        s.rx = r * hypot(st.m[0], st.m[1])
      else:
        s = toPath(rectSubs(x, y, w, h, r), st.m)
      finish(s, nd, st)
    of "circle", "ellipse":
      let a = styleMap(nd.attrs)
      let cx = num(a, "cx")
      let cy = num(a, "cy")
      let rx = if nd.tag == "circle": num(a, "r") else: num(a, "rx")
      let ry = if nd.tag == "circle": num(a, "r") else: num(a, "ry")
      if rx <= 0 or ry <= 0: return
      var s = newShape(vkEllipse)
      if boxed(s, cx - rx, cy - ry, 2 * rx, 2 * ry, st.m) == nil:
        s = toPath(ellipseSubs(cx, cy, rx, ry), st.m)
      finish(s, nd, st)
    of "line":
      let a = styleMap(nd.attrs)
      let s = toPath(@[VSub(pts: @[VPt(x: num(a, "x1"), y: num(a, "y1")), VPt(x: num(a, "x2"), y: num(a, "y2"))])], st.m)
      s.kind = vkLine
      var st2 = st
      if st2.stroke.len == 0 or st2.stroke == "none": st2.stroke = "#000000"
      finish(s, nd, st2)
      s.fill = "none"
    of "polyline", "polygon":
      let v = numbersIn(nd.attrs.getOrDefault("points"))
      var sub = VSub(closed: nd.tag == "polygon")
      var k = 0
      while k + 1 < v.len:
        sub.pts.add VPt(x: v[k], y: v[k + 1])
        k += 2
      if sub.pts.len < 2: return
      let s = toPath(@[sub], st.m)
      finish(s, nd, st)
    of "path":
      let subs = parsePathData(nd.attrs.getOrDefault("d"))
      if subs.len == 0: return
      let s = toPath(subs, st.m)
      s.evenOdd = styleMap(nd.attrs).getOrDefault("fill-rule") == "evenodd"
      finish(s, nd, st)
      if subs.len == 2 and not subs[0].closed and subs[0].pts.len == 2 and st.fill in ["", "none"]:
        discard
    of "text":
      var lines: seq[string]
      var firstX = num(nd.attrs, "x")
      var firstY = num(nd.attrs, "y")
      var gotPos = nd.attrs.hasKey("x") or nd.attrs.hasKey("y")
      var size = st.fontSize
      var bold = st.bold
      if nd.text.strip.len > 0: lines.add nd.text.strip
      for k in nd.kids:
        if k.tag == "tspan":
          let ks = styleMap(k.attrs)
          if ks.hasKey("font-size"): size = num(ks, "font-size", size)
          if ks.hasKey("font-weight") and ks["font-weight"].len > 0: bold = ks["font-weight"] == "bold" or ks["font-weight"][0] in {'6'..'9'}
          if not gotPos and (k.attrs.hasKey("x") or k.attrs.hasKey("y")):
            firstX = num(k.attrs, "x", firstX)
            firstY = num(k.attrs, "y", firstY)
            gotPos = true
          lines.add k.text
      if lines.len == 0: return
      let s = newShape(vkText)
      s.text = lines.join("\n")
      s.font = (if st.font.len > 0: st.font else: "Poppins")
      s.bold = bold
      s.italic = st.italic
      s.align = (if st.align.len > 0: st.align else: "gauche")
      let k = hypot(st.m[0], st.m[1])
      s.fontSize = size * k
      if nd.attrs.hasKey("data-interligne"): s.lineHeight = num(nd.attrs, "data-interligne", 1.25)
      if nd.attrs.hasKey("data-boite"):
        let b = numbersIn(nd.attrs["data-boite"])
        if b.len >= 3:
          let p = st.m.apply(b[0], b[1])
          s.x = p.x; s.y = p.y; s.w = b[2] * k
      else:
        let p = st.m.apply(firstX, firstY)
        s.w = 0
        var mw = 0.0
        for l in lines: mw = max(mw, measureText(s.font, s.fontSize, s.bold, s.italic, l))
        s.x = case s.align
              of "centre": p.x - mw / 2
              of "droite": p.x - mw
              else: p.x
        s.y = p.y - s.fontSize * 0.95 - (s.lineStep - s.fontSize) / 2
      let ang = radToDeg(arctan2(st.m[1], st.m[0]))
      if abs(ang) > 1e-6: s.rotation = ang
      finish(s, nd, st)
      s.fill = (if st.fill.len == 0 or st.fill == "none": "#000000" else: st.fill)
      s.stroke = "none"
      s.fitTextHeight
    of "use":
      # instance of a symbol or named element: <use href="#id" x y width height>
      var href = nd.attrs.getOrDefault("href", nd.attrs.getOrDefault("xlink:href"))
      if not href.startsWith("#") or useDepth > 8: return
      href = href[1 .. ^1]
      if not ids.hasKey(href): return
      let target = ids[href]
      if target == nd: return
      var st2 = st
      st2.m = mul(st2.m, translateM(num(nd.attrs, "x"), num(nd.attrs, "y")))
      inc groupSeq
      st2.group = (if nd.attrs.hasKey("id"): nd.attrs["id"] else: "use" & $groupSeq)
      inc useDepth
      if target.tag == "symbol":
        let vb = numbersIn(target.attrs.getOrDefault("viewbox"))
        if vb.len == 4 and vb[2] > 0 and vb[3] > 0:
          let w = num(nd.attrs, "width", num(target.attrs, "width", vb[2]))
          let h = num(nd.attrs, "height", num(target.attrs, "height", vb[3]))
          # default preserveAspectRatio: xMidYMid meet
          let k = min(w / vb[2], h / vb[3])
          st2.m = mul(st2.m, mul(translateM((w - vb[2] * k) / 2, (h - vb[3] * k) / 2),
                                 mul(scaleM(k, k), translateM(-vb[0], -vb[1]))))
        st2.applyAttrs(target.attrs)
        for k in target.kids: walk(k, st2, inDefs)
      else:
        walk(target, st2, inDefs)
      dec useDepth
    of "image":
      let a = styleMap(nd.attrs)
      let href = if nd.attrs.hasKey("href"): nd.attrs["href"] else: nd.attrs.getOrDefault("xlink:href", nd.attrs.getOrDefault("href"))
      let s = newShape(vkImage)
      s.href = href
      var w = num(a, "width")
      var h = num(a, "height")
      if w <= 0 or h <= 0:
        let img = loadRgba(resolveHref(sc, href))
        if w <= 0: w = img.w.float
        if h <= 0: h = img.h.float
      if boxed(s, num(a, "x"), num(a, "y"), w, h, st.m) == nil: return
      finish(s, nd, st)
      s.fill = "none"
      s.stroke = "none"
    else:
      for k in nd.kids: walk(k, st, inDefs)
  var st = StyleState(fill: "#000000", stroke: "none", strokeWidth: 1, opacity: 1, fontSize: 16,
                      font: "Poppins", m: m0)
  walk(root, st, false)
  if sc.layers.len == 0: sc.layers.add VLayer(name: "Calque 1", visible: true)
  for s in sc.shapes:
    if s.layer.len == 0: s.layer = sc.layers[0].name
  # background: first rectangle covering the whole scene marked data-fond
  if sc.shapes.len > 0 and sc.shapes[0].kind == vkRect and sc.shapes[0].id == "fond":
    sc.background = sc.shapes[0].fill
    sc.shapes.delete(0)

#
# symbol sheets
#

type SvgSymbol* = tuple[id, title, svg: string; w, h: float]

proc extractSymbols*(code: string, color = "", size = 256.0): seq[SvgSymbol] =
  ## Splits a symbol sheet (<symbol id=… viewBox=…>) into standalone SVGs: the original
  ## content is copied as is (case, gradients), the presentation attributes of the root
  ## and of the symbol are moved onto a group, referenced gradients and symbols are included;
  ## `color` (if not empty) becomes the group's current color (value of "currentColor").
  proc fmtNum(v: float): string =
    let r = round(v * 1000) / 1000
    if abs(r - round(r)) < 1e-9: return $int(round(r))
    result = formatFloat(r, ffDecimal, 3).strip(leading = false, chars = {'0'})
    if result.endsWith("."): result.setLen(result.len - 1)
  let low = code.toLowerAscii
  # presentation attributes inherited from the root <svg>
  const pres = ["fill", "stroke", "stroke-width", "stroke-linecap", "stroke-linejoin", "stroke-miterlimit",
                "fill-rule", "opacity", "color", "style"]
  proc attrsOf(openTag: string): Table[string, string] =
    let doc = parseXml(openTag & "</x>")
    if doc.kids.len > 0: result = doc.kids[0].attrs
  proc presOf(at: Table[string, string]): string =
    for k in pres:
      if not at.hasKey(k): continue
      var v = at[k]
      if k == "style":
        # a sheet often hides itself (display:none): do not carry it over
        var keep: seq[string]
        for d in v.split(';'):
          let n = d.split(':')[0].strip.toLowerAscii
          if d.strip.len > 0 and n notin ["display", "visibility", "position", "width", "height", "overflow"]: keep.add d.strip
        v = keep.join(";")
        if v.len == 0: continue
      result.add " " & k & "=\"" & v.multiReplace(("&", "&amp;"), ("\"", "&quot;")) & "\""
  var rootPres = ""
  let rs = low.find("<svg")
  if rs >= 0:
    let re = code.find('>', rs)
    if re > 0: rootPres = presOf(attrsOf(code[rs .. re]))
  # symbols: position of the raw content
  var syms: seq[tuple[id: string, at: Table[string, string], inner: string, raw: string]]
  var i = 0
  while true:
    let a = low.find("<symbol", i)
    if a < 0: break
    let e = code.find('>', a)
    if e < 0: break
    let selfClose = code[e - 1] == '/'
    let at = attrsOf(code[a .. e])
    var inner = ""
    var stop = e + 1
    if not selfClose:
      let c = low.find("</symbol>", e)
      if c < 0: break
      inner = code[e + 1 ..< c]
      stop = c + "</symbol>".len
    syms.add (at.getOrDefault("id"), at, inner, code[a ..< stop])
    i = stop
  # shared definitions (excluding symbols): content of the <defs>
  var shared = ""
  i = 0
  while true:
    let a = low.find("<defs", i)
    if a < 0: break
    let e = code.find('>', a)
    let c = low.find("</defs>", e)
    if e < 0 or c < 0: break
    var blk = code[e + 1 ..< c]
    for sy in syms:
      if sy.raw.len > 0: blk = blk.replace(sy.raw, "")
    shared.add blk.strip
    i = c + 7
  var bySym: Table[string, int]
  for k, sy in syms:
    if sy.id.len > 0: bySym[sy.id] = k
  for sy in syms:
    if sy.id.len == 0 or sy.inner.strip.len == 0: continue
    var vb = numbersIn(sy.at.getOrDefault("viewbox"))
    if vb.len != 4 or vb[2] <= 0 or vb[3] <= 0:
      # no viewBox: bounding box of the shapes
      let probe = parseSvgScene("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"4096\" height=\"4096\">" & sy.inner & "</svg>")
      var x0 = 1e18
      var y0 = 1e18
      var x1 = -1e18
      var y1 = -1e18
      for s in probe.shapes:
        x0 = min(x0, s.x); y0 = min(y0, s.y); x1 = max(x1, s.x + s.w); y1 = max(y1, s.y + s.h)
      if x1 <= x0 or y1 <= y0: continue
      vb = @[x0, y0, x1 - x0, y1 - y0]
    # title: <title>, aria-label, data-nom, otherwise the id
    var title = ""
    let tl = sy.inner.toLowerAscii
    let ta = tl.find("<title")
    if ta >= 0:
      let tb = sy.inner.find('>', ta)
      let tc = tl.find("</title>", tb)
      if tb > 0 and tc > tb: title = xmlUnescape(sy.inner[tb + 1 ..< tc]).strip
    if title.len == 0: title = sy.at.getOrDefault("aria-label", sy.at.getOrDefault("data-nom"))
    if title.len == 0:
      var t = sy.id
      for pre in ["icon-", "icone-", "ico-", "sym-", "symbol-", "symbole-", "i-"]:
        if t.toLowerAscii.startsWith(pre) and t.len > pre.len: t = t[pre.len .. ^1]
      t = t.replace('-', ' ').replace('_', ' ').strip
      if t.len > 0: t[0] = t[0].toUpperAscii
      title = t
    # required defs: shared gradients if a url(#…) is used, symbols referenced by <use>
    var defs = ""
    if shared.len > 0 and ("url(#" in sy.inner or "href=\"#" in sy.inner): defs.add shared
    var j = 0
    var seen: seq[string]
    var pending = @[sy.inner]
    while pending.len > 0:
      let txt = pending.pop
      j = 0
      while true:
        let h = txt.find("href=\"#", j)
        if h < 0: break
        let q = txt.find('"', h + 7)
        if q < 0: break
        let rid = txt[h + 7 ..< q]
        j = q
        if rid != sy.id and bySym.hasKey(rid) and rid notin seen:
          seen.add rid
          defs.add syms[bySym[rid]].raw
          pending.add syms[bySym[rid]].inner
    let k = if size > 0: size / max(vb[2], vb[3]) else: 1.0
    let w = vb[2] * k
    let h = vb[3] * k
    var body = "<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\" width=\"" & fmtNum(w) &
               "\" height=\"" & fmtNum(h) & "\" viewBox=\"" & fmtNum(vb[0]) & " " & fmtNum(vb[1]) & " " & fmtNum(vb[2]) & " " & fmtNum(vb[3]) & "\">"
    if title.len > 0: body.add "<title>" & title.multiReplace(("&", "&amp;"), ("<", "&lt;")) & "</title>"
    if defs.len > 0: body.add "<defs>" & defs & "</defs>"
    var gp = rootPres & presOf(sy.at)
    # current color: inherited through "currentColor" (including in referenced symbols)
    if color.len > 0 and " color=" notin gp: gp = " color=\"" & color & "\"" & gp
    body.add (if gp.len > 0: "<g" & gp & ">" else: "<g>") & sy.inner & "</g></svg>"
    result.add (sy.id, title, body, w, h)

#
# SVG writing
#

proc fmt(v: float): string =
  let r = round(v * 100) / 100
  if abs(r - round(r)) < 1e-9: return $int(round(r))
  result = formatFloat(r, ffDecimal, 2)
  result = result.strip(leading = false, chars = {'0'})
  if result.endsWith("."): result.setLen(result.len - 1)
  if result == "-0": result = "0"

proc xmlEsc(s: string): string =
  s.multiReplace(("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"), ("\"", "&quot;"))

proc pathData*(subs: seq[VSub]): string =
  for sub in subs:
    let n = sub.pts.len
    if n == 0: continue
    if result.len > 0: result.add " "
    result.add "M" & fmt(sub.pts[0].x) & " " & fmt(sub.pts[0].y)
    let segs = if sub.closed: n else: n - 1
    for i in 0 ..< segs:
      let a = sub.pts[i]
      let b = sub.pts[(i + 1) mod n]
      if hasHandles(a, b):
        result.add "C" & fmt(a.x + a.ox) & " " & fmt(a.y + a.oy) & " " & fmt(b.x + b.ix) & " " &
                   fmt(b.y + b.iy) & " " & fmt(b.x) & " " & fmt(b.y)
      elif i == segs - 1 and sub.closed:
        discard          # Z closes it
      else:
        result.add "L" & fmt(b.x) & " " & fmt(b.y)
    if sub.closed: result.add "Z"

proc toSvg*(sc: VScene, embedImages = false, pretty = true): string =
  ## Standard, compact SVG for the scene.
  var defs = ""
  var gradIds: Table[string, string]
  var markerIds: Table[string, string]
  proc paintRef(spec: string): string =
    var g: Gradient
    if parseGradient(spec, g):
      if not gradIds.hasKey(spec):
        let id = "deg" & $(gradIds.len + 1)
        gradIds[spec] = id
        let a = degToRad(g.angle)
        let x1 = 0.5 - cos(a) / 2
        let y1 = 0.5 - sin(a) / 2
        let x2 = 0.5 + cos(a) / 2
        let y2 = 0.5 + sin(a) / 2
        defs.add "<linearGradient id=\"" & id & "\" x1=\"" & fmt(x1) & "\" y1=\"" & fmt(y1) & "\" x2=\"" &
                 fmt(x2) & "\" y2=\"" & fmt(y2) & "\"><stop offset=\"0\" stop-color=\"" & hexColor(VColor(r: g.c1.r, g: g.c1.g, b: g.c1.b, a: 1)) &
                 "\"" & (if g.c1.a < 0.999: " stop-opacity=\"" & fmt(g.c1.a) & "\"" else: "") &
                 "/><stop offset=\"1\" stop-color=\"" & hexColor(VColor(r: g.c2.r, g: g.c2.g, b: g.c2.b, a: 1)) & "\"" &
                 (if g.c2.a < 0.999: " stop-opacity=\"" & fmt(g.c2.a) & "\"" else: "") & "/></linearGradient>"
      return "url(#" & gradIds[spec] & ")"
    var ok: bool
    let c = parseColor(spec, ok)
    if not ok: return "none"
    hexColor(c)
  proc marker(color: string): string =
    if not markerIds.hasKey(color):
      let id = "fleche" & $(markerIds.len + 1)
      markerIds[color] = id
      defs.add "<marker id=\"" & id & "\" viewBox=\"0 0 10 10\" refX=\"8\" refY=\"5\" markerWidth=\"5\" markerHeight=\"5\" orient=\"auto-start-reverse\"><path d=\"M0 0L10 5L0 10z\" fill=\"" & color & "\"/></marker>"
    markerIds[color]
  var body = ""
  let nl = if pretty: "\n" else: ""
  proc common(s: VShape): string =
    result = " id=\"" & xmlEsc(s.id) & "\""
    if s.name.len > 0: result.add " data-nom=\"" & xmlEsc(s.name) & "\""
    if s.data.len > 0: result.add " data-composant=\"" & xmlEsc(s.data) & "\""
    if s.locked: result.add " data-verrou=\"1\""
    if s.shadow: result.add " data-ombre=\"1\""
    if s.opacity < 0.999: result.add " opacity=\"" & fmt(s.opacity) & "\""
    if s.hidden: result.add " display=\"none\""
    if s.rotation != 0 and s.kind notin {vkLine, vkPath}:
      result.add " transform=\"rotate(" & fmt(s.rotation) & " " & fmt(s.x + s.textBoxWidth / 2) & " " & fmt(s.y + s.h / 2) & ")\""
  proc strokeAttrs(s: VShape): string =
    let st = paintRef(s.stroke)
    if st == "none" or s.strokeWidth <= 0: return ""
    result = " stroke=\"" & st & "\" stroke-width=\"" & fmt(s.strokeWidth) & "\""
    if s.dash.len > 0: result.add " stroke-dasharray=\"" & s.dash.replace(" ", ",") & "\""
    if s.kind in {vkLine, vkPath}: result.add " stroke-linecap=\"round\" stroke-linejoin=\"round\""
  proc shapeSvg(s: VShape): string =
    case s.kind
    of vkRect:
      result = "<rect x=\"" & fmt(s.x) & "\" y=\"" & fmt(s.y) & "\" width=\"" & fmt(s.w) & "\" height=\"" & fmt(s.h) & "\""
      if s.rx > 0: result.add " rx=\"" & fmt(s.rx) & "\""
      result.add " fill=\"" & paintRef(s.fill) & "\"" & strokeAttrs(s) & common(s) & "/>"
    of vkEllipse:
      result = "<ellipse cx=\"" & fmt(s.x + s.w / 2) & "\" cy=\"" & fmt(s.y + s.h / 2) & "\" rx=\"" & fmt(s.w / 2) &
               "\" ry=\"" & fmt(s.h / 2) & "\" fill=\"" & paintRef(s.fill) & "\"" & strokeAttrs(s) & common(s) & "/>"
    of vkLine, vkPath:
      var mk = ""
      let st = paintRef(s.stroke)
      if st != "none" and not st.startsWith("url"):
        if s.arrowEnd: mk.add " marker-end=\"url(#" & marker(st) & ")\""
        if s.arrowStart: mk.add " marker-start=\"url(#" & marker(st) & ")\""
      if s.kind == vkLine and s.subs.len > 0 and s.subs[0].pts.len == 2 and not hasHandles(s.subs[0].pts[0], s.subs[0].pts[1]):
        let a = s.subs[0].pts[0]
        let b = s.subs[0].pts[1]
        result = "<line x1=\"" & fmt(a.x) & "\" y1=\"" & fmt(a.y) & "\" x2=\"" & fmt(b.x) & "\" y2=\"" & fmt(b.y) & "\"" &
                 strokeAttrs(s) & mk & common(s) & "/>"
      else:
        let fill = if s.kind == vkLine: "none" else: paintRef(s.fill)
        result = "<path d=\"" & pathData(s.subs) & "\" fill=\"" & fill & "\"" &
                 (if s.evenOdd: " fill-rule=\"evenodd\"" else: "") & strokeAttrs(s) & mk & common(s) & "/>"
    of vkText:
      let lines = s.wrapLines
      let anchor = case s.align
                   of "centre", "center": "middle"
                   of "droite", "right": "end"
                   else: "start"
      let bw = s.textBoxWidth
      let ax = case anchor
               of "middle": s.x + bw / 2
               of "end": s.x + bw
               else: s.x
      result = "<text font-family=\"" & xmlEsc(s.font) & (if "lora" in s.font.toLowerAscii: ", serif" elif "mono" in s.font.toLowerAscii: ", monospace" else: ", sans-serif") &
               "\" font-size=\"" & fmt(s.fontSize) & "\""
      if s.bold: result.add " font-weight=\"bold\""
      if s.italic: result.add " font-style=\"italic\""
      result.add " fill=\"" & paintRef(s.fill) & "\""
      if anchor != "start": result.add " text-anchor=\"" & anchor & "\""
      result.add " data-boite=\"" & fmt(s.x) & " " & fmt(s.y) & " " & fmt(if s.w > 0: s.w else: 0) & "\""
      if abs(s.lineHeight - 1.25) > 0.001 and s.lineHeight > 0: result.add " data-interligne=\"" & fmt(s.lineHeight) & "\""
      result.add common(s) & ">"
      for i, l in lines:
        let base = s.y + i.float * s.lineStep + (s.lineStep - s.fontSize) / 2 + s.fontSize * 0.95
        result.add "<tspan x=\"" & fmt(ax) & "\" y=\"" & fmt(base) & "\">" & xmlEsc(if l.len == 0: " " else: l) & "</tspan>"
      result.add "</text>"
    of vkImage:
      var href = s.href
      if embedImages and not href.startsWith("data:"):
        let p = resolveHref(sc, href)
        let ext = p.splitFile.ext.toLowerAscii
        let mime = case ext
                   of ".png": "image/png"
                   of ".jpg", ".jpeg": "image/jpeg"
                   of ".svg": "image/svg+xml"
                   of ".gif": "image/gif"
                   else: "image/bmp"
        try: href = "data:" & mime & ";base64," & encode(readFile(p))
        except CatchableError: discard
      result = "<image x=\"" & fmt(s.x) & "\" y=\"" & fmt(s.y) & "\" width=\"" & fmt(s.w) & "\" height=\"" & fmt(s.h) &
               "\" href=\"" & xmlEsc(href) & "\" preserveAspectRatio=\"none\"" & common(s) & "/>"
  var layers = sc.layers
  if layers.len == 0: layers = @[VLayer(name: "Calque 1", visible: true)]
  for li, l in layers:
    var group = ""
    var inner = ""
    for s in sc.shapes:
      let k = sc.layerOf(s.layer)
      if (if k < 0: 0 else: k) != li: continue
      if s.kind == vkText: s.fitTextHeight
      if s.group != group:
        if group.len > 0: inner.add "</g>" & nl
        group = s.group
        if group.len > 0: inner.add "<g data-groupe=\"" & xmlEsc(group) & "\">" & nl
      inner.add shapeSvg(s) & nl
    if group.len > 0: inner.add "</g>" & nl
    body.add "<g id=\"" & xmlEsc("calque-" & l.name.replace(" ", "-")) & "\" data-calque=\"" & xmlEsc(l.name) & "\"" &
             (if not l.visible: " display=\"none\"" else: "") & (if l.locked: " data-verrou=\"1\"" else: "") & ">" & nl &
             inner & "</g>" & nl
  let bgRef = if sc.background.len > 0: paintRef(sc.background) else: ""
  result = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"" & fmt(sc.width) & "\" height=\"" & fmt(sc.height) &
           "\" viewBox=\"0 0 " & fmt(sc.width) & " " & fmt(sc.height) & "\">" & nl
  if defs.len > 0: result.add "<defs>" & defs & "</defs>" & nl
  if sc.background.len > 0:
    result.add "<rect id=\"fond\" width=\"" & fmt(sc.width) & "\" height=\"" & fmt(sc.height) & "\" fill=\"" & bgRef & "\"/>" & nl
  result.add body
  result.add "</svg>" & nl

#
# properties (text)
#

proc boolStr(b: bool): string = (if b: "vrai" else: "faux")
proc strBool(v: string): bool = v.toLowerAscii in ["vrai", "true", "1", "oui", "yes"]
proc strNum(v: string, d: float): float =
  try: parseFloat(v.strip.replace(',', '.'))
  except ValueError: d

proc shapeProps*(s: VShape): seq[(string, string)] =
  ## Properties of a shape (French names, values as text).
  let b = s.bounds
  result = @[("id", s.id), ("genre", $s.kind), ("nom", s.name),
             ("x", fmt(b.x)), ("y", fmt(b.y)), ("largeur", fmt(b.w)), ("hauteur", fmt(b.h)),
             ("rotation", fmt(s.rotation)), ("opacite", fmt(s.opacity)),
             ("remplissage", s.fill), ("contour", s.stroke), ("epaisseur", fmt(s.strokeWidth)),
             ("pointilles", s.dash), ("calque", s.layer), ("groupe", s.group), ("donnees", s.data),
             ("verrouille", boolStr(s.locked)), ("masque", boolStr(s.hidden)), ("ombre", boolStr(s.shadow))]
  case s.kind
  of vkRect: result.add ("rayon", fmt(s.rx))
  of vkLine, vkPath:
    result.add ("chemin", pathData(s.subs))
    result.add ("flechedebut", boolStr(s.arrowStart))
    result.add ("flechefin", boolStr(s.arrowEnd))
    result.add ("pairimpair", boolStr(s.evenOdd))
    if s.kind == vkLine and s.subs.len > 0 and s.subs[0].pts.len >= 2:
      result.add ("x1", fmt(s.subs[0].pts[0].x)); result.add ("y1", fmt(s.subs[0].pts[0].y))
      result.add ("x2", fmt(s.subs[0].pts[^1].x)); result.add ("y2", fmt(s.subs[0].pts[^1].y))
  of vkText:
    result.add ("texte", s.text); result.add ("police", s.font); result.add ("taille", fmt(s.fontSize))
    result.add ("gras", boolStr(s.bold)); result.add ("italique", boolStr(s.italic))
    result.add ("alignement", s.align); result.add ("interligne", fmt(s.lineHeight))
  of vkImage: result.add ("image", s.href)
  else: discard

proc setShapeProp*(s: VShape, key0, v: string): bool =
  ## Changes a property (names from shapeProps); false if unknown.
  let key = key0.toLowerAscii
  result = true
  case key
  of "nom": s.name = v
  of "x":
    let b = s.bounds
    s.moveShape(strNum(v, b.x) - b.x, 0)
  of "y":
    let b = s.bounds
    s.moveShape(0, strNum(v, b.y) - b.y)
  of "largeur":
    let b = s.rawBounds
    let nw = max(0.5, strNum(v, b.w))
    if s.kind == vkText: s.w = nw
    else: s.scaleShape(b, (b.x, b.y, nw, b.h))
  of "hauteur":
    let b = s.rawBounds
    let nh = max(0.5, strNum(v, b.h))
    if s.kind != vkText: s.scaleShape(b, (b.x, b.y, b.w, nh))
  of "rotation": s.rotation = strNum(v, s.rotation)
  of "opacite": s.opacity = clamp(strNum(v, s.opacity), 0, 1)
  of "remplissage": s.fill = v
  of "contour": s.stroke = v
  of "epaisseur": s.strokeWidth = max(0.0, strNum(v, s.strokeWidth))
  of "pointilles": s.dash = v
  of "calque": s.layer = v
  of "groupe": s.group = v
  of "donnees": s.data = v
  of "verrouille": s.locked = strBool(v)
  of "masque": s.hidden = strBool(v)
  of "ombre": s.shadow = strBool(v)
  of "rayon": s.rx = max(0.0, strNum(v, s.rx))
  of "chemin":
    let subs = parsePathData(v)
    if subs.len > 0:
      s.subs = subs
      s.syncPathBox
  of "flechedebut": s.arrowStart = strBool(v)
  of "flechefin": s.arrowEnd = strBool(v)
  of "pairimpair": s.evenOdd = strBool(v)
  of "x1", "y1", "x2", "y2":
    if s.subs.len > 0 and s.subs[0].pts.len >= 2:
      let f = strNum(v, 0)
      case key
      of "x1": s.subs[0].pts[0].x = f
      of "y1": s.subs[0].pts[0].y = f
      of "x2": s.subs[0].pts[^1].x = f
      else: s.subs[0].pts[^1].y = f
      s.syncPathBox
  of "texte":
    s.text = v
    s.fitTextHeight
  of "police":
    s.font = v
    s.fitTextHeight
  of "taille":
    s.fontSize = max(1.0, strNum(v, s.fontSize))
    s.fitTextHeight
  of "gras":
    s.bold = strBool(v)
    s.fitTextHeight
  of "italique":
    s.italic = strBool(v)
    s.fitTextHeight
  of "alignement": s.align = v
  of "interligne":
    s.lineHeight = max(0.5, strNum(v, s.lineHeight))
    s.fitTextHeight
  of "image": s.href = v
  else: result = false

proc shapeFromProps*(kind: string, props: seq[(string, string)]): VShape =
  ## New shape of a given kind (rectangle, ellipse, ligne, fleche, chemin, texte, image)
  ## from properties; x, y, largeur, hauteur position the box.
  var k = vkRect
  case kind.toLowerAscii
  of "ellipse", "cercle": k = vkEllipse
  of "ligne", "fleche", "flèche": k = vkLine
  of "chemin", "path": k = vkPath
  of "texte", "text": k = vkText
  of "image": k = vkImage
  else: k = vkRect
  result = newShape(k)
  var x, y = 0.0
  var w = 100.0
  var h = 60.0
  for (key, v) in props:
    case key.toLowerAscii
    of "x": x = strNum(v, x)
    of "y": y = strNum(v, y)
    of "largeur": w = strNum(v, w)
    of "hauteur": h = strNum(v, h)
    of "id": (if v.len > 0: result.id = v)
    else: discard
  case k
  of vkLine:
    result.subs = @[VSub(pts: @[VPt(x: x, y: y), VPt(x: x + w, y: y + h)])]
    result.fill = "none"
    result.stroke = "#1f2937"
    result.arrowEnd = kind.toLowerAscii in ["fleche", "flèche"]
    result.syncPathBox
  of vkPath:
    result.subs = @[VSub(closed: true, pts: @[VPt(x: x, y: y), VPt(x: x + w, y: y), VPt(x: x + w / 2, y: y + h)])]
    result.syncPathBox
  of vkText:
    result.x = x; result.y = y; result.w = w
    result.fill = "#1f2937"
    result.text = "Texte"
  of vkImage:
    result.x = x; result.y = y; result.w = w; result.h = h
    result.fill = "none"
  else:
    result.x = x; result.y = y; result.w = w; result.h = h
  for (key, v) in props:
    if key.toLowerAscii notin ["x", "y", "largeur", "hauteur", "id"]:
      discard result.setShapeProp(key, v)
  if k == vkText: result.fitTextHeight

proc cubicPtPub*(p0, p1, p2, p3: FPoint, t: float): FPoint = cubicPt(p0, p1, p2, p3, t)

proc baselineOf*(s: VShape, line = 0): float =
  ## Baseline of line `line` of a text (shape coordinates).
  let fm = fontMetrics(s.font, s.fontSize, s.bold, s.italic)
  s.y + line.float * s.lineStep + (s.lineStep - fm.height) / 2 + fm.ascent

