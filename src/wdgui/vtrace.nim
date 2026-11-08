# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
#   wdgui - image import and vectorization (bitmap -> editable SVG).
#
# Import: PNG, JPEG, GIF (first frame), BMP, TGA, PSD (stb_image), WEBP (SDL3_image
# if present, loaded on demand), PDF (page rendered by PDFium).
#
# Vectorization (stack of color layers, no gaps between areas):
#   1. downscaling (at most `maxSide` pixels) and light smoothing (3×3 median: noise, JPEG);
#   2. quantization: monochrome (Otsu threshold), grayscale, colors (k-means);
#   3. for each color (from the largest to the smallest), mask = this color and
#      all those placed after it; contours traced along pixel edges (holes included);
#   4. cleanup (areas < `minArea` removed), straightening of staircase steps,
#      simplification (Douglas-Peucker), then Bézier curves (corners kept);
#   5. one path per color (even-odd rule), grouped: standard, compact SVG.
# Presets: mono, gris (gray), couleurs (colors), logo (few colors, crisp curves),
# technique (thin lines, straight segments), illustration (many colors).

import std/[math, strutils, tables, algorithm, os, dynlib, sequtils]
import vscene
import imagedecode
import imagepure
import ../pdfium

type
  TraceOptions* = object
    mode*: string          # mono, gris, couleurs, logo, technique, illustration
    colors*: int           # number of colors (couleurs, illustration, gris)
    smooth*: float         # 0 (angular) .. 1 (very smooth)
    detail*: float         # 0 (simplified) .. 1 (faithful)
    minArea*: float        # minimum area of a region (pixels of the original image)
    maxSide*: int
    background*: bool      # keep the background color (otherwise transparent)

proc presetOptions*(mode: string): TraceOptions =
  result = TraceOptions(mode: mode, colors: 8, smooth: 0.6, detail: 0.6, minArea: 0, maxSide: 900, background: true)
  case mode
  of "mono": result.colors = 2; result.background = false
  of "gris": result.colors = 5
  of "logo": result.colors = 5; result.smooth = 0.75; result.detail = 0.5
  of "technique": result.colors = 2; result.smooth = 0.1; result.detail = 0.9; result.background = false
  of "illustration": result.colors = 16; result.smooth = 0.55; result.detail = 0.7
  else: discard

#
# import
#

type
  SdlSurf = object
    flags: uint32
    format: uint32
    w, h, pitch: cint
    pixels: pointer

var imgLib {.global.}: LibHandle
var imgLoad {.global.}: proc (f: cstring): pointer {.cdecl, gcsafe.}
var convertSurf {.global.}: proc (s: pointer, fmt: uint32): pointer {.cdecl, gcsafe.}
var destroySurf {.global.}: proc (s: pointer) {.cdecl, gcsafe.}

proc trySdlImage(path: string): RgbaImage =
  ## WEBP and other formats through SDL3_image (if the library is available).
  {.cast(gcsafe).}:
    if imgLib == nil:
      for name in ["libSDL3_image.so.0", "libSDL3_image.so", "libSDL3_image.dylib", "SDL3_image.dll",
                   "libSDL3_image.0.dylib"]:
        imgLib = loadLib(name)
        if imgLib == nil:
          for dir in [getAppDir(), getAppDir() / "macOS", getAppDir() / "linOS", getCurrentDir() / "macOS", getCurrentDir() / "linOS"]:
            imgLib = loadLib(dir / name)
            if imgLib != nil: break
        if imgLib != nil: break
      if imgLib == nil: return
      imgLoad = cast[typeof(imgLoad)](imgLib.symAddr("IMG_Load"))
      let sdl = loadLib(when defined(macosx): "libSDL3.dylib" else: "libSDL3.so.0")
      if sdl != nil:
        convertSurf = cast[typeof(convertSurf)](sdl.symAddr("SDL_ConvertSurface"))
        destroySurf = cast[typeof(destroySurf)](sdl.symAddr("SDL_DestroySurface"))
    if imgLoad == nil or convertSurf == nil: return
    let s = imgLoad(path.cstring)
    if s == nil: return
    let c = convertSurf(s, 0x16762004'u32)   # ABGR8888: bytes R, G, B, A
    destroySurf(s)
    if c == nil: return
    let sv = cast[ptr SdlSurf](c)
    result.w = int(sv.w)
    result.h = int(sv.h)
    result.px = newSeq[uint8](result.w * result.h * 4)
    let base = cast[ptr UncheckedArray[uint8]](sv.pixels)
    for y in 0 ..< result.h:
      for x in 0 ..< result.w * 4:
        result.px[y * result.w * 4 + x] = base[y * int(sv.pitch) + x]
    destroySurf(c)

proc pdfPageImage*(path: string, page = 1, width = 1600): RgbaImage =
  ## Renders a PDF page (PDFium) as an RGBA image.
  if not loadPdfium(): return
  var data = ""
  try: data = readFile(path)
  except IOError, OSError: return
  let doc = FPDF_LoadMemDocument(addr data[0], cint(data.len), nil)
  if doc == nil: return
  let n = FPDF_GetPageCount(doc)
  let pi = clamp(page - 1, 0, max(0, n - 1))
  let pg = FPDF_LoadPage(doc, cint(pi))
  if pg != nil:
    let pw = FPDF_GetPageWidth(pg)
    let ph = FPDF_GetPageHeight(pg)
    let w = width
    let h = max(1, int(float(width) * ph / max(1.0, pw)))
    let bmp = FPDFBitmap_Create(cint(w), cint(h), 1)
    if bmp != nil:
      FPDFBitmap_FillRect(bmp, 0, 0, cint(w), cint(h), 0xFFFFFFFF'u32.culong)
      FPDF_RenderPageBitmap(bmp, pg, 0, 0, cint(w), cint(h), 0, FPDF_ANNOT)
      let stride = int(FPDFBitmap_GetStride(bmp))
      let buf = cast[ptr UncheckedArray[uint8]](FPDFBitmap_GetBuffer(bmp))
      result.w = w
      result.h = h
      result.px = newSeq[uint8](w * h * 4)
      for y in 0 ..< h:
        for x in 0 ..< w:
          let s = y * stride + x * 4
          let d = (y * w + x) * 4
          result.px[d] = buf[s + 2]
          result.px[d + 1] = buf[s + 1]
          result.px[d + 2] = buf[s]
          result.px[d + 3] = buf[s + 3]
      FPDFBitmap_Destroy(bmp)
    FPDF_ClosePage(pg)
  FPDF_CloseDocument(doc)

proc pdfPageCount*(path: string): int =
  if not loadPdfium(): return 0
  var data = ""
  try: data = readFile(path)
  except IOError, OSError: return 0
  let doc = FPDF_LoadMemDocument(addr data[0], cint(data.len), nil)
  if doc == nil: return 0
  result = int(FPDF_GetPageCount(doc))
  FPDF_CloseDocument(doc)

proc importImage*(path: string, page = 1): RgbaImage =
  ## Decoded image, whatever the recognized format.
  let ext = path.splitFile.ext.toLowerAscii
  case ext
  of ".pdf": return pdfPageImage(path, page)
  of ".webp", ".avif", ".tif", ".tiff":
    return trySdlImage(path)
  of ".bmp":
    try: return decodeBmp(readFile(path))
    except CatchableError: return
  else:
    try:
      if ext == ".gif": return decodeGif(readFile(path))
      return decodeImageFile(path)
    except CatchableError:
      return trySdlImage(path)

proc savePng*(img: RgbaImage, path: string): bool =
  try:
    writeFile(path, encodePngPure(img))
    true
  except CatchableError: false

#
# quantization
#

type Rgb = tuple[r, g, b: float]

proc dist2(a, b: Rgb): float = (a.r - b.r)^2 * 0.30 + (a.g - b.g)^2 * 0.59 + (a.b - b.b)^2 * 0.11

proc upscale2(img: RgbaImage): RgbaImage =
  ## Bilinear ×2 upscaling: thin strokes (text) survive quantization.
  result = RgbaImage(w: img.w * 2, h: img.h * 2)
  result.px = newSeq[uint8](result.w * result.h * 4)
  for y in 0 ..< result.h:
    let sy = clamp((y.float + 0.5) / 2 - 0.5, 0, (img.h - 1).float)
    let y0 = int(sy)
    let y1 = min(img.h - 1, y0 + 1)
    let fy = sy - y0.float
    for x in 0 ..< result.w:
      let sx = clamp((x.float + 0.5) / 2 - 0.5, 0, (img.w - 1).float)
      let x0 = int(sx)
      let x1 = min(img.w - 1, x0 + 1)
      let fx = sx - x0.float
      for k in 0 .. 3:
        let a = img.px[(y0 * img.w + x0) * 4 + k].float * (1 - fx) + img.px[(y0 * img.w + x1) * 4 + k].float * fx
        let b = img.px[(y1 * img.w + x0) * 4 + k].float * (1 - fx) + img.px[(y1 * img.w + x1) * 4 + k].float * fx
        result.px[(y * result.w + x) * 4 + k] = uint8(clamp(a * (1 - fy) + b * fy, 0, 255))

proc downscale(img: RgbaImage, maxSide: int): tuple[img: RgbaImage, f: float] =
  if max(img.w, img.h) < 700 and max(img.w, img.h) * 2 <= max(maxSide, 1400): return (upscale2(img), 0.5)
  if max(img.w, img.h) <= maxSide: return (img, 1.0)
  let f = max(img.w, img.h).float / maxSide.float
  var r = RgbaImage(w: max(1, int(img.w.float / f)), h: max(1, int(img.h.float / f)))
  r.px = newSeq[uint8](r.w * r.h * 4)
  for y in 0 ..< r.h:
    let y0 = int(y.float * f)
    let y1 = max(y0 + 1, min(img.h, int((y + 1).float * f)))
    for x in 0 ..< r.w:
      let x0 = int(x.float * f)
      let x1 = max(x0 + 1, min(img.w, int((x + 1).float * f)))
      var acc: array[4, int]
      var n = 0
      for yy in y0 ..< y1:
        for xx in x0 ..< x1:
          for k in 0 .. 3: acc[k] += int(img.px[(yy * img.w + xx) * 4 + k])
          inc n
      for k in 0 .. 3: r.px[(y * r.w + x) * 4 + k] = uint8(acc[k] div max(1, n))
  (r, f)

proc median3(img: RgbaImage): RgbaImage =
  result = img
  for y in 1 ..< img.h - 1:
    for x in 1 ..< img.w - 1:
      for k in 0 .. 2:
        var v: array[9, int]
        var n = 0
        for dy in -1 .. 1:
          for dx in -1 .. 1:
            v[n] = int(img.px[((y + dy) * img.w + x + dx) * 4 + k])
            inc n
        v.sort()
        result.px[(y * img.w + x) * 4 + k] = uint8(v[4])

proc pixelRgb(img: RgbaImage, i: int): Rgb =
  # composited over white (transparency)
  let a = img.px[4 * i + 3].float / 255
  (img.px[4 * i].float * a + 255 * (1 - a), img.px[4 * i + 1].float * a + 255 * (1 - a), img.px[4 * i + 2].float * a + 255 * (1 - a))

proc otsu(lum: seq[float]): float =
  var hist: array[256, int]
  for v in lum: inc hist[clamp(int(v), 0, 255)]
  let total = lum.len
  var sum = 0.0
  for i in 0 .. 255: sum += i.float * hist[i].float
  var sumB = 0.0
  var wB = 0
  var best = 0.0
  result = 128
  for t in 0 .. 255:
    wB += hist[t]
    if wB == 0: continue
    let wF = total - wB
    if wF == 0: break
    sumB += t.float * hist[t].float
    let mB = sumB / wB.float
    let mF = (sum - sumB) / wF.float
    let between = wB.float * wF.float * (mB - mF) ^ 2
    if between > best:
      best = between
      result = t.float

proc quantize(img: RgbaImage, o: TraceOptions): tuple[labels: seq[int], palette: seq[Rgb]] =
  let n = img.w * img.h
  var labels = newSeq[int](n)
  case o.mode
  of "mono", "technique":
    var lum = newSeq[float](n)
    for i in 0 ..< n:
      let c = img.pixelRgb(i)
      lum[i] = 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
    let t = otsu(lum)
    var dark, light: Rgb
    var nd, nl = 0
    for i in 0 ..< n:
      let c = img.pixelRgb(i)
      if lum[i] <= t:
        labels[i] = 1
        dark = (dark.r + c.r, dark.g + c.g, dark.b + c.b); inc nd
      else:
        light = (light.r + c.r, light.g + c.g, light.b + c.b); inc nl
    let dk = if nd > 0: (dark.r / nd.float, dark.g / nd.float, dark.b / nd.float) else: (0.0, 0.0, 0.0)
    let lt = if nl > 0: (light.r / nl.float, light.g / nl.float, light.b / nl.float) else: (255.0, 255.0, 255.0)
    # mono: pure black
    let ink = if o.mode == "mono" or o.mode == "technique": (min(dk[0], 40.0), min(dk[1], 40.0), min(dk[2], 48.0)) else: dk
    return (labels, @[lt, ink])
  of "gris":
    let k = max(2, o.colors)
    var pal: seq[Rgb]
    for j in 0 ..< k:
      let v = 255.0 * (1 - j.float / (k - 1).float)
      pal.add (v, v, v)
    for i in 0 ..< n:
      let c = img.pixelRgb(i)
      let l = 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
      labels[i] = clamp(int(round((255 - l) / 255 * (k - 1).float)), 0, k - 1)
    return (labels, pal)
  else:
    # k-means (deterministic k-means++ initialization, on a sample)
    let k = clamp(o.colors, 2, 64)
    # sample: pixels from flat areas (close neighbors); edge pixels, anti-aliasing
    # blends, must not become palette colors
    var sample: seq[Rgb]
    let step = max(1, n div 40000)
    var i = 0
    while i < n:
      let x = i mod img.w
      let y = i div img.w
      let c = img.pixelRgb(i)
      var flat = x > 0 and y > 0 and x < img.w - 1 and y < img.h - 1
      if flat:
        for q in [i - 1, i + 1, i - img.w, i + img.w]:
          if dist2(c, img.pixelRgb(q)) > 60: flat = false
      if flat: sample.add c
      i += step
    if sample.len < 64:
      sample.setLen(0)
      i = 0
      while i < n:
        sample.add img.pixelRgb(i)
        i += step
    var centers: seq[Rgb] = @[sample[sample.len div 2]]
    var d = newSeq[float](sample.len)
    while centers.len < k:
      var far = 0
      var best = -1.0
      for si, s in sample:
        var m = Inf
        for c in centers: m = min(m, dist2(s, c))
        d[si] = m
        if m > best:
          best = m
          far = si
      if best < 4: break
      centers.add sample[far]
    for iter in 0 ..< 12:
      var acc = newSeq[tuple[r, g, b: float, n: int]](centers.len)
      for s in sample:
        var bi = 0
        var bd = Inf
        for ci, c in centers:
          let dd = dist2(s, c)
          if dd < bd:
            bd = dd
            bi = ci
        acc[bi].r += s.r; acc[bi].g += s.g; acc[bi].b += s.b; inc acc[bi].n
      var moved = 0.0
      for ci in 0 ..< centers.len:
        if acc[ci].n > 0:
          let nc = (acc[ci].r / acc[ci].n.float, acc[ci].g / acc[ci].n.float, acc[ci].b / acc[ci].n.float)
          moved = max(moved, dist2(nc, centers[ci]))
          centers[ci] = nc
      if moved < 1: break
    for p in 0 ..< n:
      let c = img.pixelRgb(p)
      var bi = 0
      var bd = Inf
      for ci, cc in centers:
        let dd = dist2(c, cc)
        if dd < bd:
          bd = dd
          bi = ci
      labels[p] = bi
    return (labels, centers)

proc cleanLabels(labels: var seq[int], w, h: int, minArea: int) =
  ## Small connected areas absorbed by the most frequent neighboring color.
  if minArea <= 1: return
  var seen = newSeq[bool](w * h)
  var stack: seq[int]
  var comp: seq[int]
  for start in 0 ..< w * h:
    if seen[start]: continue
    let lab = labels[start]
    comp.setLen(0)
    stack.setLen(0)
    stack.add start
    seen[start] = true
    var neigh = initCountTable[int]()
    while stack.len > 0:
      let p = stack.pop
      comp.add p
      let x = p mod w
      let y = p div w
      for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]:
        if nx < 0 or ny < 0 or nx >= w or ny >= h: continue
        let q = ny * w + nx
        if labels[q] == lab:
          if not seen[q]:
            seen[q] = true
            stack.add q
        else: neigh.inc labels[q]
    if comp.len < minArea and neigh.len > 0:
      let nl = neigh.largest.key
      for p in comp: labels[p] = nl

#
# contours
#

proc traceMask(mask: seq[bool], w, h: int): seq[seq[FPoint]] =
  ## Contours (pixel edges) of a mask: closed loops, inside on the left;
  ## at saddle points, turn right (diagonal areas kept separate).
  proc inside(x, y: int): bool = x >= 0 and y >= 0 and x < w and y < h and mask[y * w + x]
  # oriented edges: from (x, y) in direction d (0: +x, 1: +y, 2: -x, 3: -y)
  var used = initTable[int, bool]()
  proc key(x, y, d: int): int = ((y * (w + 1) + x) shl 2) or d
  var starts: seq[(int, int, int)]
  for y in 0 .. h:
    for x in 0 .. w:
      # horizontal edge from (x,y) to (x+1,y): pixel below (x,y) inside, above outside -> direction -x?
      discard
  # construction: for each inside pixel, its sides bordering the outside
  for y in 0 ..< h:
    for x in 0 ..< w:
      if not mask[y * w + x]: continue
      # inside on the left (y axis pointing down): top side traversed right to left...
      if not inside(x, y - 1): starts.add (x + 1, y, 2)     # top: (x+1,y) -> (x,y)
      if not inside(x - 1, y): starts.add (x, y, 1)         # left: (x,y) -> (x,y+1)
      if not inside(x, y + 1): starts.add (x, y + 1, 0)     # bottom: (x,y+1) -> (x+1,y+1)
      if not inside(x + 1, y): starts.add (x + 1, y + 1, 3) # right: (x+1,y+1) -> (x+1,y)
  var edgeSet = initTable[int, bool]()
  for (x, y, d) in starts: edgeSet[key(x, y, d)] = true
  const dx = [1, 0, -1, 0]
  const dy = [0, 1, 0, -1]
  for (sx, sy, sd) in starts:
    if used.hasKey(key(sx, sy, sd)): continue
    var poly: seq[FPoint]
    var x = sx
    var y = sy
    var d = sd
    var guard = 0
    while true:
      used[key(x, y, d)] = true
      poly.add (x.float, y.float)
      x += dx[d]
      y += dy[d]
      # next: right turn, straight ahead, left turn (with the inside on the left)
      var found = false
      for turn in [1, 0, 3]:
        let nd = (d + turn) mod 4
        let k = key(x, y, nd)
        if edgeSet.hasKey(k) and not used.hasKey(k):
          d = nd
          found = true
          break
      if not found: break
      inc guard
      if guard > 4 * (w + 1) * (h + 1): break
    if poly.len >= 4: result.add poly

proc polyArea(p: seq[FPoint]): float =
  for i in 0 ..< p.len:
    let a = p[i]
    let b = p[(i + 1) mod p.len]
    result += a.x * b.y - b.x * a.y
  result /= 2

proc removeCollinear(p: seq[FPoint]): seq[FPoint] =
  let n = p.len
  for i in 0 ..< n:
    let a = p[(i - 1 + n) mod n]
    let b = p[i]
    let c = p[(i + 1) mod n]
    if abs((b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)) > 1e-9: result.add b

proc destair(p: seq[FPoint]): seq[FPoint] =
  ## Staircase steps -> edge midpoints (outline without aliasing).
  let n = p.len
  for i in 0 ..< n:
    let a = p[i]
    let b = p[(i + 1) mod n]
    result.add ((a.x + b.x) / 2, (a.y + b.y) / 2)

proc smoothPoly(p: seq[FPoint], k: float, iters: int): seq[FPoint] =
  result = p
  for it in 0 ..< iters:
    var q = result
    let n = result.len
    for i in 0 ..< n:
      let a = result[(i - 1 + n) mod n]
      let b = result[i]
      let c = result[(i + 1) mod n]
      q[i] = (b.x + k * ((a.x + c.x) / 2 - b.x), b.y + k * ((a.y + c.y) / 2 - b.y))
    result = q

proc dpSimplify(p: seq[FPoint], tol: float, closed = true): seq[FPoint] =
  if p.len < 4: return p
  var keep = newSeq[bool](p.len)
  proc rec(i, j: int) =
    if j <= i + 1: return
    let a = p[i]
    let b = p[j]
    let L = hypot(b.x - a.x, b.y - a.y)
    var best = -1.0
    var bi = -1
    for k in i + 1 ..< j:
      let q = p[k]
      let dd = if L < 1e-9: hypot(q.x - a.x, q.y - a.y) else: abs((b.x - a.x) * (a.y - q.y) - (a.x - q.x) * (b.y - a.y)) / L
      if dd > best:
        best = dd
        bi = k
    if best > tol:
      keep[bi] = true
      rec(i, bi)
      rec(bi, j)
  # closed: split at the point farthest from the first
  var far = 0
  var fd = -1.0
  for k in 1 ..< p.len:
    let dd = hypot(p[k].x - p[0].x, p[k].y - p[0].y)
    if dd > fd:
      fd = dd
      far = k
  keep[0] = true
  keep[far] = true
  rec(0, far)
  var tail = p[far .. ^1] & @[p[0]]
  var keep2 = newSeq[bool](tail.len)
  block:
    proc rec2(i, j: int) =
      if j <= i + 1: return
      let a = tail[i]
      let b = tail[j]
      let L = hypot(b.x - a.x, b.y - a.y)
      var best = -1.0
      var bi = -1
      for k in i + 1 ..< j:
        let q = tail[k]
        let dd = if L < 1e-9: hypot(q.x - a.x, q.y - a.y) else: abs((b.x - a.x) * (a.y - q.y) - (a.x - q.x) * (b.y - a.y)) / L
        if dd > best:
          best = dd
          bi = k
      if best > tol:
        keep2[bi] = true
        rec2(i, bi)
        rec2(bi, j)
    rec2(0, tail.high)
  for k in 0 .. far:
    if keep[k]: result.add p[k]
  for k in 1 ..< tail.high:
    if keep2[k]: result.add tail[k]

proc toSub(p: seq[FPoint], curves: bool, cornerDeg: float, scale: float): VSub =
  ## Polygon -> sub-path; curves: Catmull-Rom tangents, sharp corners kept.
  result.closed = true
  let n = p.len
  for i in 0 ..< n:
    let a = p[(i - 1 + n) mod n]
    let b = p[i]
    let c = p[(i + 1) mod n]
    var pt = VPt(x: b.x * scale, y: b.y * scale)
    if curves:
      let v1x = b.x - a.x
      let v1y = b.y - a.y
      let v2x = c.x - b.x
      let v2y = c.y - b.y
      let l1 = hypot(v1x, v1y)
      let l2 = hypot(v2x, v2y)
      if l1 > 1e-9 and l2 > 1e-9:
        let cosang = (v1x * v2x + v1y * v2y) / (l1 * l2)
        let turn = radToDeg(arccos(clamp(cosang, -1, 1)))
        if turn < cornerDeg:
          var tx = c.x - a.x
          var ty = c.y - a.y
          let tl = hypot(tx, ty)
          if tl > 1e-9:
            tx /= tl
            ty /= tl
            pt.ix = -tx * l1 / 3 * scale
            pt.iy = -ty * l1 / 3 * scale
            pt.ox = tx * l2 / 3 * scale
            pt.oy = ty * l2 / 3 * scale
            pt.smooth = true
    result.pts.add pt

proc hexOf(c: Rgb): string =
  "#" & toHex(clamp(int(round(c.r)), 0, 255), 2).toLowerAscii & toHex(clamp(int(round(c.g)), 0, 255), 2).toLowerAscii &
        toHex(clamp(int(round(c.b)), 0, 255), 2).toLowerAscii

proc vectorize*(img0: RgbaImage, o: TraceOptions): VScene =
  ## Image -> vector scene (one path per color, grouped).
  result = newScene(max(1, img0.w).float, max(1, img0.h).float)
  result.layers = @[VLayer(name: "Vectorisation", visible: true)]
  if img0.w <= 0 or img0.h <= 0: return
  var (img, f) = downscale(img0, o.maxSide)
  if o.mode in ["illustration", "gris"]: img = median3(img)
  var (labels, palette) = quantize(img, o)
  let w = img.w
  let h = img.h
  let minPx = max(o.minArea / (f * f), (1 - o.detail) * 12 + 2)
  cleanLabels(labels, w, h, int(minPx))
  # order: the largest color first (background), then the others
  var counts = newSeq[int](palette.len)
  for l in labels: inc counts[l]
  var order: seq[int]
  for i in 0 ..< palette.len:
    if counts[i] > 0: order.add i
  if o.mode in ["mono", "technique"]: order = @[0, 1].filterIt(counts[it] > 0)
  else: order.sort(proc (a, b: int): int = cmp(counts[b], counts[a]))
  let gid = newId("g")
  let curves = o.mode != "technique" and o.smooth > 0.05
  let tol = 0.35 + (1 - o.detail) * 1.6
  let corner = 30 + o.smooth * 45
  var rank = newSeq[int](palette.len)
  for r, ci in order: rank[ci] = r
  for r, ci in order:
    if r == 0 and not o.background: continue
    var mask = newSeq[bool](w * h)
    var any = false
    for p in 0 ..< w * h:
      if rank[labels[p]] >= r:
        mask[p] = true
        any = true
    if not any: continue
    let polys = traceMask(mask, w, h)
    let s = newShape(vkPath)
    s.fill = hexOf(palette[ci])
    s.stroke = "none"
    s.strokeWidth = 0
    s.evenOdd = true
    s.group = gid
    s.layer = "Vectorisation"
    s.name = "Couleur " & $(r + 1)
    for poly in polys:
      # raw contour in one-pixel steps: edge midpoints (no steps), local smoothing
      if abs(polyArea(poly)) < minPx: continue
      var q = destair(poly)
      if curves: q = smoothPoly(q, 0.5, 1 + int(o.smooth * 2))
      q = dpSimplify(q, tol)
      if q.len < 3: continue
      s.subs.add toSub(q, curves, corner, f)
    if s.subs.len == 0: continue
    s.syncPathBox
    result.shapes.add s

#
# optimization of existing SVGs
#

proc simplifyScene*(sc: VScene, tol: float) =
  ## Simplifies paths (tolerance in scene units) then rebuilds the curves.
  for s in sc.shapes:
    if s.kind != vkPath: continue
    var subs: seq[VSub]
    for sub in s.subs:
      var pts: seq[FPoint]
      for p in sub.pts: pts.add (p.x, p.y)
      let curved = sub.pts.anyIt(it.smooth or it.ox != 0 or it.oy != 0)
      if sub.closed and pts.len >= 4:
        let q = dpSimplify(pts, tol)
        if q.len >= 3: subs.add toSub(q, curved, 60, 1.0)
        else: subs.add sub
      else: subs.add sub
    s.subs = subs
    s.syncPathBox

proc mergeScene*(sc: VScene) =
  ## Merges paths with the same fill, same stroke and same layer.
  var keep: seq[VShape]
  var byKey = initTable[string, VShape]()
  for s in sc.shapes:
    if s.kind == vkPath and s.stroke == "none" and s.opacity >= 0.999 and s.rotation == 0:
      let k = s.fill & "|" & s.layer & "|" & s.group
      if byKey.hasKey(k):
        let t = byKey[k]
        for sub in s.subs: t.subs.add sub
        t.evenOdd = true
        t.syncPathBox
        continue
      byKey[k] = s
    keep.add s
  sc.shapes = keep

proc cleanScene*(sc: VScene, minArea: float) =
  ## Removes small sub-paths (specks) and empty shapes.
  var keep: seq[VShape]
  for s in sc.shapes:
    if s.kind == vkPath:
      var subs: seq[VSub]
      for sub in s.subs:
        var pts: seq[FPoint]
        for p in sub.pts: pts.add (p.x, p.y)
        if not sub.closed or abs(polyArea(pts)) >= minArea: subs.add sub
      s.subs = subs
      if s.subs.len == 0: continue
      s.syncPathBox
    keep.add s
  sc.shapes = keep

#
# boolean operations
#

proc shapeMask(s: VShape, sc: VScene, m: Affine, w, h: int): seq[bool] =
  var r = newRaster(w, h)
  let t = s.clone
  t.opacity = 1
  t.shadow = false
  if t.fill == "none" or t.fill.len == 0: t.fill = "#000000"
  renderShape(sc, t, r, m)
  result = newSeq[bool](w * h)
  for i in 0 ..< w * h: result[i] = r.px[4 * i + 3] > 0.5

proc booleanShapes*(sc: VScene, shapes: seq[VShape], op: string): VShape =
  ## Union, difference (the first shape minus the others), intersection, exclusion:
  ## computed on fine masks, then vector outline (curves, corners kept).
  if shapes.len < 2: return nil
  var x0 = Inf
  var y0 = Inf
  var x1 = -Inf
  var y1 = -Inf
  for s in shapes:
    let b = s.bounds
    x0 = min(x0, b.x); y0 = min(y0, b.y); x1 = max(x1, b.x + b.w); y1 = max(y1, b.y + b.h)
  let pad = 4.0
  let k = clamp(1400 / max(1.0, max(x1 - x0, y1 - y0)), 0.5, 16)
  let w = int((x1 - x0) * k + 2 * pad) + 1
  let h = int((y1 - y0) * k + 2 * pad) + 1
  let m: Affine = [k, 0, 0, k, pad - x0 * k, pad - y0 * k]
  var acc = shapeMask(shapes[0], sc, m, w, h)
  for i in 1 ..< shapes.len:
    let b = shapeMask(shapes[i], sc, m, w, h)
    for p in 0 ..< w * h:
      case op
      of "union": acc[p] = acc[p] or b[p]
      of "difference", "soustraction": acc[p] = acc[p] and not b[p]
      of "intersection": acc[p] = acc[p] and b[p]
      of "exclusion": acc[p] = acc[p] xor b[p]
      else: discard
  let polys = traceMask(acc, w, h)
  result = newShape(vkPath)
  result.fill = shapes[0].fill
  result.stroke = shapes[0].stroke
  result.strokeWidth = shapes[0].strokeWidth
  result.opacity = shapes[0].opacity
  result.layer = shapes[0].layer
  result.evenOdd = true
  for poly in polys:
    if abs(polyArea(poly)) < 6: continue
    var q = destair(poly)
    q = smoothPoly(q, 0.5, 1)
    q = dpSimplify(q, 0.7)
    if q.len < 3: continue
    var sub = toSub(q, true, 50, 1 / k)
    for pt in sub.pts.mitems:
      pt.x += x0 - pad / k
      pt.y += y0 - pad / k
    result.subs.add sub
  if result.subs.len == 0: return nil
  result.syncPathBox
