# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
#   wdgui – Vector PDF generation from 'vscene' scenes (document pages, slides, plates).
#
# * Shapes rendered as precise PDF paths (Bézier curves), linear gradients (axial shadings), opacity
#   (graphics states), dashed lines, arrows, and drop shadows.
# * Real text (selectable, searchable): TrueType fonts embedded as subsets
#   (Identity-H, glyph widths, ToUnicode table); baselines match those on-screen;
#   bold and italic styles simulated when the specific variant is unavailable.
# * Images: PNG, JPEG (without re-encoding), BMP, transparency (SMask); embedded SVG
#   in vector format; optional downsampling (standard PDF / high-definition).
# * Links (URLs and internal anchors), hierarchical bookmarks, metadata, language,
#   accessibility tagging (StructTreeRoot: H1–H6, P, LI, TD, Figure + alt-text, Code;
#   decorative elements marked as 'Artifact'), and crop marks (for print-ready PDFs).

import std/[strutils, tables, math, os, algorithm, times, sets, unicode]
import vscene
import ../ide/zflate

type
  TtfFont = ref object
    path, psName: string
    data: string
    upem: int
    ascent, descent, capH: int
    bbox: array[4, int]
    italicAngle: float
    flags: int
    cmap: Table[int32, int]
    adv: seq[int]
    numGlyphs: int
    used: Table[int, int32]           # glyph -> character (ToUnicode)
    resName: string
    tables: Table[string, tuple[off, len: int]]

  PdfImg = object
    w, h: int
    data, smask: string
    filter, colorSpace: string
    bpc: int
    resName: string

  PdfOutline* = object
    level*: int
    title*: string
    page*: int        # 1..n
    y*: float         # within the scene (top of page = 0)

  PdfOptions* = object
    title*, author*, subject*, keywords*, lang*: string
    outlines*: seq[PdfOutline]
    anchors*: Table[string, tuple[page: int, y: float]]
    maxImagePx*: int                  # 0: original images (HD); otherwise, the longer side
    cropMarks*: bool                  # Printable PDF: crop marks, 3 mm bleed
    tagged*: bool
    links*: bool

  PageRec = object
    content: string
    w, h: float
    annots: seq[string]               # dictionaries (Dest resolved at the end)
    mcids: seq[int]                   # MCID -> structure element (index in structs)
    offX, offY: float                 # offset (crop marks)
    boxW, boxH: float

  StructElem = object
    role: string
    alt: string
    page: int
    mcids: seq[int]
    key: string

  PdfWriter* = ref object
    opts: PdfOptions
    pages: seq[PageRec]
    fonts: Table[string, TtfFont]     # path -> font
    fontOrder: seq[string]
    images: Table[string, PdfImg]
    imageOrder: seq[string]
    gstates: Table[string, string]    # "ca/CA" -> name
    shadings: seq[string]             # shading dictionaries
    structs: seq[StructElem]
    structByKey: Table[string, int]

#
# TrueType
#

proc u16(s: string, i: int): int = (ord(s[i]) shl 8) or ord(s[i + 1])
proc i16(s: string, i: int): int =
  let v = u16(s, i)
  if v >= 0x8000: v - 0x10000 else: v
proc u32(s: string, i: int): int = (u16(s, i) shl 16) or u16(s, i + 2)

proc be16(v: int): string = $char((v shr 8) and 0xFF) & $char(v and 0xFF)
proc be32(v: int): string = be16((v shr 16) and 0xFFFF) & be16(v and 0xFFFF)

var ttfCache {.global.}: Table[string, string]

proc loadTtf(path: string): TtfFont =
  var data = ""
  {.cast(gcsafe).}:
    if ttfCache.hasKey(path): data = ttfCache[path]
    else:
      try: data = readFile(path)
      except IOError, OSError: return nil
      ttfCache[path] = data
  if data.len < 12: return nil
  result = TtfFont(path: path, data: data)
  let n = u16(data, 4)
  for k in 0 ..< n:
    let r = 12 + 16 * k
    result.tables[data[r ..< r + 4]] = (u32(data, r + 8), u32(data, r + 12))
  let f = result
  proc tb(name: string): int = (if f.tables.hasKey(name): f.tables[name].off else: -1)
  let head = tb("head")
  let hhea = tb("hhea")
  let maxp = tb("maxp")
  let hmtx = tb("hmtx")
  if head < 0 or hhea < 0 or maxp < 0 or hmtx < 0: return nil
  f.upem = u16(data, head + 18)
  f.bbox = [i16(data, head + 36), i16(data, head + 38), i16(data, head + 40), i16(data, head + 42)]
  f.ascent = i16(data, hhea + 4)
  f.descent = i16(data, hhea + 6)
  f.numGlyphs = u16(data, maxp + 4)
  let nh = u16(data, hhea + 34)
  var last = 0
  for g in 0 ..< f.numGlyphs:
    if g < nh: last = u16(data, hmtx + 4 * g)
    f.adv.add last
  let os2 = tb("OS/2")
  f.capH = f.ascent
  if os2 >= 0 and u16(data, os2) >= 2 and f.tables["OS/2"].len >= 90: f.capH = i16(data, os2 + 88)
  let post = tb("post")
  if post >= 0: f.italicAngle = float(i16(data, post + 4)) + float(u16(data, post + 6)) / 65536
  f.flags = 32 or (if f.italicAngle != 0: 64 else: 0)
  # nom PostScript
  let nm = tb("name")
  if nm >= 0:
    let cnt = u16(data, nm + 2)
    let strOff = nm + u16(data, nm + 4)
    for k in 0 ..< cnt:
      let r = nm + 6 + 12 * k
      if u16(data, r + 6) == 6:
        let plat = u16(data, r)
        let ln = u16(data, r + 8)
        let off = strOff + u16(data, r + 10)
        var s = ""
        if plat == 3 or plat == 0:
          var i = 0
          while i + 1 < ln:
            s.add char(u16(data, off + i) and 0xFF)
            i += 2
        else: s = data[off ..< off + ln]
        if s.len > 0:
          f.psName = s
          break
  if f.psName.len == 0: f.psName = path.splitFile.name
  var clean = ""
  for ch in f.psName:
    if ch in {'A' .. 'Z', 'a' .. 'z', '0' .. '9', '-', '_'}: clean.add ch
  f.psName = clean
  # cmap (3,10 format 12 ou 3,1 format 4)
  let cm = tb("cmap")
  if cm >= 0:
    let cnt = u16(data, cm + 2)
    var best = -1
    var bestScore = -1
    for k in 0 ..< cnt:
      let r = cm + 4 + 8 * k
      let plat = u16(data, r)
      let enc = u16(data, r + 2)
      let off = cm + u32(data, r + 4)
      let fmt = u16(data, off)
      let score = if plat == 3 and enc == 10 and fmt == 12: 3 elif fmt == 12: 2 elif plat == 3 and enc == 1 and fmt == 4: 1 elif fmt == 4: 0 else: -1
      if score > bestScore:
        bestScore = score
        best = off
    if best >= 0:
      let fmt = u16(data, best)
      if fmt == 4:
        let segX2 = u16(data, best + 6)
        let ends = best + 14
        let starts = ends + segX2 + 2
        let deltas = starts + segX2
        let ranges = deltas + segX2
        for sgi in 0 ..< segX2 div 2:
          let e = u16(data, ends + 2 * sgi)
          let s = u16(data, starts + 2 * sgi)
          let d = u16(data, deltas + 2 * sgi)
          let ro = u16(data, ranges + 2 * sgi)
          if s == 0xFFFF: continue
          for ch in s .. e:
            var g = 0
            if ro == 0: g = (ch + d) and 0xFFFF
            else:
              let gi = ranges + 2 * sgi + ro + 2 * (ch - s)
              if gi + 1 < data.len:
                g = u16(data, gi)
                if g != 0: g = (g + d) and 0xFFFF
            if g != 0: f.cmap[int32(ch)] = g
      elif fmt == 12:
        let ng = u32(data, best + 12)
        for k in 0 ..< ng:
          let r = best + 16 + 12 * k
          let s = u32(data, r)
          let e = u32(data, r + 4)
          let g0 = u32(data, r + 8)
          if e - s > 70000: continue
          for ch in s .. e: f.cmap[int32(ch)] = g0 + (ch - s)

proc glyphOf(f: TtfFont, r: Rune): int =
  let k = int32(r)
  if f.cmap.hasKey(k): f.cmap[k] else: 0

proc textWidth(f: TtfFont, s: string, size: float): float =
  var w = 0
  for r in s.runes:
    let g = f.glyphOf(r)
    w += (if g < f.adv.len: f.adv[g] else: 0)
  w.float * size / f.upem.float

proc subsetFont(f: TtfFont): string =
  # Subsetting: same glyph indices, unused glyphs removed (loca table rebuilt).
  let data = f.data
  if not (f.tables.hasKey("glyf") and f.tables.hasKey("loca")): return data
  let head = f.tables["head"].off
  let longLoca = i16(data, head + 50) == 1
  let loca = f.tables["loca"].off
  let glyf = f.tables["glyf"].off
  proc locaAt(g: int): int =
    if longLoca: u32(data, loca + 4 * g) else: u16(data, loca + 2 * g) * 2
  var keep = initHashSet[int]()
  keep.incl 0
  var stack: seq[int]
  for g in f.used.keys: stack.add g
  while stack.len > 0:
    let g = stack.pop
    if g in keep and g != 0: continue
    keep.incl g
    if g >= f.numGlyphs: continue
    let a = locaAt(g)
    let b = locaAt(g + 1)
    if b - a >= 10 and i16(data, glyf + a) < 0:
      # glyphe composé : composants
      var p = glyf + a + 10
      while true:
        let flags = u16(data, p)
        let comp = u16(data, p + 2)
        if comp notin keep: stack.add comp
        p += 4
        p += (if (flags and 1) != 0: 4 else: 2)
        if (flags and 8) != 0: p += 2
        elif (flags and 0x40) != 0: p += 4
        elif (flags and 0x80) != 0: p += 8
        if (flags and 0x20) == 0: break
  var newGlyf = ""
  var newLoca = ""
  for g in 0 .. f.numGlyphs:
    newLoca.add be32(newGlyf.len)
    if g == f.numGlyphs: break
    if g in keep:
      let a = locaAt(g)
      let b = locaAt(g + 1)
      if b > a:
        newGlyf.add data[glyf + a ..< glyf + b]
        while newGlyf.len mod 4 != 0: newGlyf.add '\0'
  var tbls: seq[(string, string)]
  for name in ["cvt ", "fpgm", "glyf", "head", "hhea", "hmtx", "loca", "maxp", "prep", "OS/2", "post", "name"]:
    if name == "glyf": tbls.add (name, newGlyf)
    elif name == "loca": tbls.add (name, newLoca)
    elif f.tables.hasKey(name):
      let t = f.tables[name]
      var body = data[t.off ..< t.off + t.len]
      if name == "head":
        body[8 ..< 12] = "\0\0\0\0"
        body[50 ..< 52] = be16(1)
      if name == "post" and body.len >= 32:
        body = body[0 ..< 32]
        body[0 ..< 4] = be32(0x00030000)
      tbls.add (name, body)
  let n = tbls.len
  var es = 1
  var sel = 0
  while es * 2 <= n:
    es *= 2
    inc sel
  result = be32(0x00010000) & be16(n) & be16(es * 16) & be16(sel) & be16(n * 16 - es * 16)
  var off = 12 + 16 * n
  var bodies = ""
  for (name, body) in tbls:
    var sum = 0'u32
    var padded = body
    while padded.len mod 4 != 0: padded.add '\0'
    var i = 0
    while i < padded.len:
      sum += uint32(u32(padded, i))
      i += 4
    result.add name & be32(int(sum)) & be32(off) & be32(body.len)
    bodies.add padded
    off += padded.len
  result.add bodies

#
# tools
#

proc num(f: float): string =
  if abs(f) < 0.00005: return "0"
  result = formatFloat(f, ffDecimal, 4)
  if '.' in result:
    result = result.strip(leading = false, chars = {'0'})
    if result.endsWith("."): result.setLen(result.len - 1)
  if result == "-0": result = "0"

proc pdfStr(s: string): string =
  # PDF text string (UTF-16BE with BOM if necessary).
  var ascii = true
  for ch in s:
    if ord(ch) >= 128: ascii = false
  if ascii:
    result = "("
    for ch in s:
      if ch in {'(', ')', '\\'}: result.add '\\'
      result.add ch
    return result & ")"
  result = "<FEFF"
  for r in s.runes:
    var c = int(r)
    if c > 0xFFFF:
      c -= 0x10000
      result.add toHex(0xD800 + (c shr 10), 4) & toHex(0xDC00 + (c and 0x3FF), 4)
    else: result.add toHex(c, 4)
  result.add ">"

proc newPdfWriter*(opts: PdfOptions): PdfWriter =
  PdfWriter(opts: opts)

proc gstate(p: PdfWriter, fillA, strokeA: float): string =
  let key = num(fillA) & "/" & num(strokeA)
  if not p.gstates.hasKey(key): p.gstates[key] = "GS" & $(p.gstates.len + 1)
  p.gstates[key]

proc fontRes(p: PdfWriter, path: string): TtfFont =
  if p.fonts.hasKey(path): return p.fonts[path]
  let f = loadTtf(path)
  if f == nil: return nil
  f.resName = "F" & $(p.fonts.len + 1)
  p.fonts[path] = f
  p.fontOrder.add path
  f

proc colorOps(c: VColor, stroke: bool): string =
  num(c.r) & " " & num(c.g) & " " & num(c.b) & (if stroke: " RG\n" else: " rg\n")

#
# images
#

proc jpegInfo(data: string): tuple[w, h, comps: int] =
  var i = 2
  while i + 9 < data.len:
    if data[i] != '\xFF':
      inc i
      continue
    let m = ord(data[i + 1])
    if m in [0xD8, 0x01] or (m >= 0xD0 and m <= 0xD7):
      i += 2
      continue
    let len = (ord(data[i + 2]) shl 8) or ord(data[i + 3])
    if m in [0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF]:
      return ((ord(data[i + 7]) shl 8) or ord(data[i + 8]), (ord(data[i + 5]) shl 8) or ord(data[i + 6]), ord(data[i + 9]))
    i += 2 + len

proc imageRes(p: PdfWriter, path: string): string =
  if p.images.hasKey(path): return p.images[path].resName
  var img = PdfImg(bpc: 8, colorSpace: "/DeviceRGB")
  let low = path.toLowerAscii
  var done = false
  if (low.endsWith(".jpg") or low.endsWith(".jpeg")) and p.opts.maxImagePx == 0:
    try:
      let data = readFile(path)
      let info = jpegInfo(data)
      if info.w > 0 and info.comps in [1, 3]:
        img.w = info.w
        img.h = info.h
        img.data = data
        img.filter = "/DCTDecode"
        if info.comps == 1: img.colorSpace = "/DeviceGray"
        done = true
    except IOError, OSError: discard
  if not done:
    var rgba = loadRgba(path)
    if rgba.w <= 0 or rgba.h <= 0: return ""
    # downsampling (box averaging)
    let maxPx = p.opts.maxImagePx
    if maxPx > 0 and max(rgba.w, rgba.h) > maxPx:
      let f = max(rgba.w, rgba.h).float / maxPx.float
      let nw = max(1, int(rgba.w.float / f))
      let nh = max(1, int(rgba.h.float / f))
      var px = newSeq[uint8](nw * nh * 4)
      for y in 0 ..< nh:
        let y0 = int(y.float * f)
        let y1 = max(y0 + 1, min(rgba.h, int((y + 1).float * f)))
        for x in 0 ..< nw:
          let x0 = int(x.float * f)
          let x1 = max(x0 + 1, min(rgba.w, int((x + 1).float * f)))
          var acc: array[4, int]
          var n = 0
          for yy in y0 ..< y1:
            for xx in x0 ..< x1:
              for k in 0 .. 3: acc[k] += int(rgba.px[(yy * rgba.w + xx) * 4 + k])
              inc n
          for k in 0 .. 3: px[(y * nw + x) * 4 + k] = uint8(acc[k] div max(1, n))
      rgba.w = nw
      rgba.h = nh
      rgba.px = px
    var rgb = newString(rgba.w * rgba.h * 3)
    var alpha = newString(rgba.w * rgba.h)
    var hasAlpha = false
    for i in 0 ..< rgba.w * rgba.h:
      rgb[3 * i] = char(rgba.px[4 * i])
      rgb[3 * i + 1] = char(rgba.px[4 * i + 1])
      rgb[3 * i + 2] = char(rgba.px[4 * i + 2])
      let a = rgba.px[4 * i + 3]
      alpha[i] = char(a)
      if a < 255: hasAlpha = true
    img.w = rgba.w
    img.h = rgba.h
    img.data = zlibCompress(rgb)
    img.filter = "/FlateDecode"
    if hasAlpha: img.smask = zlibCompress(alpha)
  img.resName = "Im" & $(p.images.len + 1)
  p.images[path] = img
  p.imageOrder.add path
  img.resName

#
# outlines
#

proc pathOps(s: VShape): string =
  # Outlining the shape (scene reference frame, excluding its rotation).
  case s.kind
  of vkRect:
    let r = clamp(s.rx, 0, min(s.w, s.h) / 2)
    if r <= 0.01:
      return num(s.x) & " " & num(s.y) & " " & num(s.w) & " " & num(s.h) & " re\n"
    let k = 0.5523 * r
    let x0 = s.x
    let y0 = s.y
    let x1 = s.x + s.w
    let y1 = s.y + s.h
    result = num(x0 + r) & " " & num(y0) & " m\n"
    result.add num(x1 - r) & " " & num(y0) & " l\n"
    result.add num(x1 - r + k) & " " & num(y0) & " " & num(x1) & " " & num(y0 + r - k) & " " & num(x1) & " " & num(y0 + r) & " c\n"
    result.add num(x1) & " " & num(y1 - r) & " l\n"
    result.add num(x1) & " " & num(y1 - r + k) & " " & num(x1 - r + k) & " " & num(y1) & " " & num(x1 - r) & " " & num(y1) & " c\n"
    result.add num(x0 + r) & " " & num(y1) & " l\n"
    result.add num(x0 + r - k) & " " & num(y1) & " " & num(x0) & " " & num(y1 - r + k) & " " & num(x0) & " " & num(y1 - r) & " c\n"
    result.add num(x0) & " " & num(y0 + r) & " l\n"
    result.add num(x0) & " " & num(y0 + r - k) & " " & num(x0 + r - k) & " " & num(y0) & " " & num(x0 + r) & " " & num(y0) & " c\nh\n"
  of vkEllipse:
    let cx = s.x + s.w / 2
    let cy = s.y + s.h / 2
    let rx = s.w / 2
    let ry = s.h / 2
    let kx = 0.5523 * rx
    let ky = 0.5523 * ry
    result = num(cx + rx) & " " & num(cy) & " m\n"
    result.add num(cx + rx) & " " & num(cy + ky) & " " & num(cx + kx) & " " & num(cy + ry) & " " & num(cx) & " " & num(cy + ry) & " c\n"
    result.add num(cx - kx) & " " & num(cy + ry) & " " & num(cx - rx) & " " & num(cy + ky) & " " & num(cx - rx) & " " & num(cy) & " c\n"
    result.add num(cx - rx) & " " & num(cy - ky) & " " & num(cx - kx) & " " & num(cy - ry) & " " & num(cx) & " " & num(cy - ry) & " c\n"
    result.add num(cx + kx) & " " & num(cy - ry) & " " & num(cx + rx) & " " & num(cy - ky) & " " & num(cx + rx) & " " & num(cy) & " c\nh\n"
  of vkLine, vkPath:
    for sub in s.subs:
      if sub.pts.len == 0: continue
      let p0 = sub.pts[0]
      result.add num(p0.x) & " " & num(p0.y) & " m\n"
      let n = sub.pts.len
      let segs = if sub.closed: n else: n - 1
      for i in 0 ..< segs:
        let a = sub.pts[i]
        let b = sub.pts[(i + 1) mod n]
        if a.ox == 0 and a.oy == 0 and b.ix == 0 and b.iy == 0:
          result.add num(b.x) & " " & num(b.y) & " l\n"
        else:
          result.add num(a.x + a.ox) & " " & num(a.y + a.oy) & " " & num(b.x + b.ix) & " " & num(b.y + b.iy) & " " &
                     num(b.x) & " " & num(b.y) & " c\n"
      if sub.closed: result.add "h\n"
  of vkImage, vkText:
    let w = if s.kind == vkText: s.textBoxWidth else: s.w
    result = num(s.x) & " " & num(s.y) & " " & num(w) & " " & num(s.h) & " re\n"

proc polyOps(poly: seq[FPoint]): string =
  if poly.len < 2: return
  result = num(poly[0].x) & " " & num(poly[0].y) & " m\n"
  for i in 1 ..< poly.len: result.add num(poly[i].x) & " " & num(poly[i].y) & " l\n"
  result.add "h\n"

proc cmOps(m: Affine): string =
  num(m[0]) & " " & num(m[1]) & " " & num(m[2]) & " " & num(m[3]) & " " & num(m[4]) & " " & num(m[5]) & " cm\n"

proc gradientRes(p: PdfWriter, g: Gradient, box: tuple[x, y, w, h: float]): string =
  let a = degToRad(g.angle)
  let cx = box.x + box.w / 2
  let cy = box.y + box.h / 2
  let half = (abs(cos(a)) * box.w + abs(sin(a)) * box.h) / 2
  let x1 = cx - cos(a) * half
  let y1 = cy - sin(a) * half
  let x2 = cx + cos(a) * half
  let y2 = cy + sin(a) * half
  let fn = "<< /FunctionType 2 /Domain [0 1] /C0 [" & num(g.c1.r) & " " & num(g.c1.g) & " " & num(g.c1.b) &
           "] /C1 [" & num(g.c2.r) & " " & num(g.c2.g) & " " & num(g.c2.b) & "] /N 1 >>"
  p.shadings.add "<< /ShadingType 2 /ColorSpace /DeviceRGB /Coords [" & num(x1) & " " & num(y1) & " " & num(x2) &
                 " " & num(y2) & "] /Function " & fn & " /Extend [true true] >>"
  "Sh" & $p.shadings.len

proc paintFill(p: PdfWriter, spec: string, path: string, box: tuple[x, y, w, h: float], opacity: float,
               evenOdd: bool, ops: var string) =
  var g: Gradient
  if parseGradient(spec, g):
    let a = opacity * min(g.c1.a, g.c2.a)
    let sh = p.gradientRes(g, box)
    ops.add "q\n"
    if a < 0.999: ops.add "/" & p.gstate(a, a) & " gs\n"
    ops.add path & (if evenOdd: "W* n\n" else: "W n\n") & "/" & sh & " sh\nQ\n"
    return
  var ok: bool
  let c = parseColor(spec, ok)
  if not ok: return
  let a = c.a * opacity
  if a <= 0.001: return
  ops.add "q\n"
  if a < 0.999: ops.add "/" & p.gstate(a, a) & " gs\n"
  ops.add colorOps(c, false) & path & (if evenOdd: "f*\n" else: "f\n") & "Q\n"

proc dashOps(s: VShape): string =
  var parts: seq[string]
  for part in s.dash.replace(" ", ",").split(','):
    if part.strip.len > 0:
      try: parts.add num(parseFloat(part.strip))
      except ValueError: discard
  if parts.len > 0: "[" & parts.join(" ") & "] 0 d\n" else: ""

#
# text
#

proc textOps(p: PdfWriter, s: VShape, page: var PageRec): string =
  var ok: bool
  let col = parseColor(s.fill, ok)
  if not ok or s.text.len == 0: return
  let ff = fontFile(s.font, s.bold, s.italic)
  if ff.path.len == 0: return
  let f = p.fontRes(ff.path)
  if f == nil: return
  let lines = s.wrapLines
  let boxW = s.textBoxWidth
  let a = col.a * s.opacity
  result = "q\n"
  if a < 0.999: result.add "/" & p.gstate(a, a) & " gs\n"
  result.add colorOps(col, false)
  if ff.synthBold:
    result.add colorOps(col, true) & num(s.fontSize * 0.028) & " w 2 Tr\n"
  for i, line in lines:
    if line.len == 0: continue
    let lw = measureText(s.font, s.fontSize, s.bold, s.italic, line)
    let pw = f.textWidth(line, s.fontSize)
    let lx = case s.align
             of "centre", "center", "middle": s.x + (boxW - lw) / 2
             of "droite", "right", "end": s.x + boxW - lw
             else: s.x
    let base = s.baselineOf(i)
    var hex = ""
    for r in line.runes:
      let g = f.glyphOf(r)
      if g != 0 and not f.used.hasKey(g): f.used[g] = int32(r)
      hex.add toHex(g, 4)
    let skew = if ff.synthItalic: 0.2 else: 0.0
    result.add "BT\n/" & f.resName & " " & num(s.fontSize) & " Tf\n"
    if pw > 0 and abs(lw - pw) / pw > 0.003: result.add num(100 * lw / pw) & " Tz\n"
    result.add "1 0 " & num(-skew) & " -1 " & num(lx) & " " & num(base) & " Tm\n<" & hex & "> Tj\nET\n"
  result.add "Q\n"

#
# forms
#

proc roleOf(s: VShape): tuple[role, link, alt, blk: string] =
  for part in s.data.split(';'):
    let k = part.find('=')
    if k < 0: continue
    let key = part[0 ..< k]
    let v = part[k + 1 .. ^1]
    case key
    of "role": result.role = v
    of "lien": result.link = v
    of "alt": result.alt = v
    of "b": result.blk = v
    else: discard

proc sceneOps(p: PdfWriter, sc: VScene, page: var PageRec, pageIdx: int, depth = 0, m: Affine = Identity): string

proc shapeOps(p: PdfWriter, sc: VScene, s: VShape, page: var PageRec, pageIdx: int, depth: int, m: Affine): string =
  let box = s.rawBounds
  let rot = s.shapeMatrix
  var body = ""
  if s.shadow:
    for k in 0 .. 3:
      var polys = s.outline(Identity)
      let off = 6.0
      for poly in polys.mitems:
        var cx, cy = 0.0
        for q in poly:
          cx += q.x; cy += q.y
        cx /= max(1, poly.len).float; cy /= max(1, poly.len).float
        let f = 1 + (k.float * 3) / max(1.0, max(box.w, box.h))
        for q in poly.mitems: q = (cx + (q.x - cx) * f + off, cy + (q.y - cy) * f + off * 1.4)
      var path = ""
      for poly in polys: path.add polyOps(poly)
      body.add "q /" & p.gstate(0.07 * s.opacity, 0.07 * s.opacity) & " gs 0 0 0 rg\n" & path & "f\nQ\n"
  var inner = ""
  case s.kind
  of vkText:
    inner = p.textOps(s, page)
  of vkImage:
    let path = resolveHref(sc, s.href)
    if path.toLowerAscii.endsWith(".svg"):
      if depth < 4:
        let sub = loadSvgScene(path)
        if sub != nil and sub.width > 0 and sub.height > 0:
          let place = mul(translateM(s.x, s.y), scaleM(s.w / sub.width, s.h / sub.height))
          inner = "q\n" & cmOps(place) & "0 0 " & num(sub.width) & " " & num(sub.height) & " re W n\n"
          if s.opacity < 0.999: inner.add "/" & p.gstate(s.opacity, s.opacity) & " gs\n"
          inner.add p.sceneOps(sub, page, pageIdx, depth + 1, mul(m, place)) & "Q\n"
    else:
      let res = p.imageRes(path)
      if res.len > 0:
        inner = "q\n"
        if s.opacity < 0.999: inner.add "/" & p.gstate(s.opacity, s.opacity) & " gs\n"
        inner.add num(s.w) & " 0 0 " & num(-s.h) & " " & num(s.x) & " " & num(s.y + s.h) & " cm\n/" & res & " Do\nQ\n"
  else:
    let path = pathOps(s)
    let closedShape = s.kind in {vkRect, vkEllipse, vkPath}
    if s.kind != vkLine and closedShape:
      p.paintFill(s.fill, path, box, s.opacity, s.evenOdd, inner)
    var ok: bool
    let sc0 = parseColor(s.stroke, ok)
    var g: Gradient
    let isGrad = parseGradient(s.stroke, g)
    if (ok or isGrad) and s.strokeWidth > 0:
      let c = if isGrad: g.c1 else: sc0
      let a = c.a * s.opacity
      inner.add "q\n"
      if a < 0.999: inner.add "/" & p.gstate(a, a) & " gs\n"
      inner.add colorOps(c, true) & num(s.strokeWidth) & " w 1 J 1 j\n" & dashOps(s) & path & "S\nQ\n"
      if s.kind in {vkLine, vkPath} and s.subs.len > 0:
        let pts = s.outline(Identity)
        if pts.len > 0 and pts[0].len >= 2:
          let aa = pts[0]
          let sz = max(8.0, s.strokeWidth * 3.2)
          var arrows = ""
          if s.arrowEnd: arrows.add polyOps(arrowPoly(aa[^1], aa[^2], sz))
          if s.arrowStart: arrows.add polyOps(arrowPoly(aa[0], aa[1], sz))
          if arrows.len > 0:
            inner.add "q\n"
            if a < 0.999: inner.add "/" & p.gstate(a, a) & " gs\n"
            inner.add colorOps(c, false) & arrows & "f\nQ\n"
  if rot != Identity: body.add "q\n" & cmOps(rot) & inner & "Q\n"
  else: body.add inner
  if body.len == 0: return ""
  # marking
  let info = s.roleOf
  if p.opts.tagged and depth == 0:
    if info.role.len == 0 or info.role == "Artifact":
      result = "/Artifact BMC\n" & body & "EMC\n"
    else:
      let mcid = page.mcids.len
      let key = $pageIdx & ":" & info.role & ":" & info.blk
      var si = -1
      if info.blk.len > 0 and p.structByKey.hasKey(key): si = p.structByKey[key]
      else:
        p.structs.add StructElem(role: info.role, alt: info.alt, page: pageIdx, key: key)
        si = p.structs.high
        if info.blk.len > 0: p.structByKey[key] = si
      p.structs[si].mcids.add mcid
      page.mcids.add si
      result = "/" & info.role & " <</MCID " & $mcid & ">> BDC\n" & body & "EMC\n"
  else:
    result = body
  # links
  if p.opts.links and info.link.len > 0 and depth == 0:
    let b = s.bounds
    let x0 = b.x + page.offX
    let y0 = page.boxH - (b.y + b.h) + page.offY
    let x1 = b.x + b.w + page.offX
    let y1 = page.boxH - b.y + page.offY
    let rect = "[" & num(x0) & " " & num(y0) & " " & num(x1) & " " & num(y1) & "]"
    if info.link.startsWith("#"):
      page.annots.add "<< /Type /Annot /Subtype /Link /Border [0 0 0] /Rect " & rect & " /Dest «" & info.link[1 .. ^1] & "» >>"
    else:
      page.annots.add "<< /Type /Annot /Subtype /Link /Border [0 0 0] /Rect " & rect &
                      " /A << /S /URI /URI " & pdfStr(info.link) & " >> >>"

proc sceneOps(p: PdfWriter, sc: VScene, page: var PageRec, pageIdx: int, depth = 0, m: Affine = Identity): string =
  if sc.background.len > 0:
    let bgPath = "0 0 " & num(sc.width) & " " & num(sc.height) & " re\n"
    var bg = ""
    p.paintFill(sc.background, bgPath, (0.0, 0.0, sc.width, sc.height), 1, false, bg)
    if bg.len > 0:
      result.add (if p.opts.tagged and depth == 0: "/Artifact BMC\n" & bg & "EMC\n" else: bg)
  for li in 0 ..< sc.layers.len:
    if not sc.layers[li].visible: continue
    for s in sc.shapes:
      let k = sc.layerOf(s.layer)
      if (k == li or (k < 0 and li == 0)) and not s.hidden:
        result.add p.shapeOps(sc, s, page, pageIdx, depth, m)

proc addScene*(p: PdfWriter, sc: VScene) =
  # Add a page (scene size, in points).
  var page = PageRec(w: sc.width, h: sc.height, boxW: sc.width, boxH: sc.height)
  let bleed = if p.opts.cropMarks: 8.5 + 20 else: 0.0
  if p.opts.cropMarks:
    page.offX = bleed
    page.offY = bleed
    page.w = sc.width + 2 * bleed
    page.h = sc.height + 2 * bleed
  var ops = ""
  ops.add "1 0 0 -1 " & num(page.offX) & " " & num(page.h - page.offY) & " cm\n"
  ops.add p.sceneOps(sc, page, p.pages.len)
  if p.opts.cropMarks:
    # crop marks (excluding boundary markers)
    let W = sc.width
    let H = sc.height
    var mk = "/Artifact BMC\nq 0 0 0 RG 0.3 w\n"
    for (x, y, dx, dy) in [(0.0, 0.0, -1.0, -1.0), (W, 0.0, 1.0, -1.0), (0.0, H, -1.0, 1.0), (W, H, 1.0, 1.0)]:
      mk.add num(x) & " " & num(y + dy * 3) & " m " & num(x) & " " & num(y + dy * 20) & " l S\n"
      mk.add num(x + dx * 3) & " " & num(y) & " m " & num(x + dx * 20) & " " & num(y) & " l S\n"
    mk.add "Q\nEMC\n"
    ops.add mk
  page.content = ops
  p.pages.add page

#
# assembly
#

proc toBytes*(p: PdfWriter): string =
  var objs: seq[string] = @["", ""]          # 1 : catalogue, 2 : arbre des pages
  proc put(objs: var seq[string], body: string): int =
    objs.add body
    objs.len
  proc stream(dict, data: string, compress = true): string =
    if compress:
      let z = zlibCompress(data)
      "<< " & dict & " /Filter /FlateDecode /Length " & $z.len & " >>\nstream\n" & z & "\nendstream"
    else:
      "<< " & dict & " /Length " & $data.len & " >>\nstream\n" & data & "\nendstream"
  # fonts
  var fontRefs = ""
  for path in p.fontOrder:
    let f = p.fonts[path]
    if f.used.len == 0: continue
    let sub = f.subsetFont()
    let ff = objs.put stream("/Length1 " & $sub.len, sub)
    let tag = block:
      var h = 0
      for ch in f.psName: h = (h * 31 + ord(ch)) mod 308915776
      var t = ""
      for k in 0 .. 5:
        t.add char(ord('A') + h mod 26)
        h = h div 26
      t
    let fname = tag & "+" & f.psName
    let sc = 1000 / f.upem
    let desc = objs.put "<< /Type /FontDescriptor /FontName /" & fname & " /Flags " & $f.flags &
      " /FontBBox [" & $int(f.bbox[0].float * sc) & " " & $int(f.bbox[1].float * sc) & " " & $int(f.bbox[2].float * sc) &
      " " & $int(f.bbox[3].float * sc) & "] /ItalicAngle " & num(f.italicAngle) & " /Ascent " & $int(f.ascent.float * sc) &
      " /Descent " & $int(f.descent.float * sc) & " /CapHeight " & $int(f.capH.float * sc) & " /StemV 80 /FontFile2 " & $ff & " 0 R >>"
    var gids: seq[int]
    for g in f.used.keys: gids.add g
    gids.sort()
    var w = "["
    for g in gids: w.add $g & " [" & $int(round(f.adv[g].float * sc)) & "] "
    w.add "]"
    let cid = objs.put "<< /Type /Font /Subtype /CIDFontType2 /BaseFont /" & fname &
      " /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /FontDescriptor " & $desc &
      " 0 R /DW " & $int(round(f.adv[0].float * sc)) & " /W " & w & " /CIDToGIDMap /Identity >>"
    var cmap = "/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n/CMapName /Adobe-Identity-UCS def\n/CMapType 2 def\n1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n"
    var k = 0
    while k < gids.len:
      let n = min(100, gids.len - k)
      cmap.add $n & " beginbfchar\n"
      for q in 0 ..< n:
        let g = gids[k + q]
        var u = int(f.used[g])
        var hex = ""
        if u > 0xFFFF:
          u -= 0x10000
          hex = toHex(0xD800 + (u shr 10), 4) & toHex(0xDC00 + (u and 0x3FF), 4)
        else: hex = toHex(u, 4)
        cmap.add "<" & toHex(g, 4) & "> <" & hex & ">\n"
      cmap.add "endbfchar\n"
      k += n
    cmap.add "endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n"
    let tu = objs.put stream("", cmap)
    let font = objs.put "<< /Type /Font /Subtype /Type0 /BaseFont /" & fname &
      " /Encoding /Identity-H /DescendantFonts [" & $cid & " 0 R] /ToUnicode " & $tu & " 0 R >>"
    fontRefs.add "/" & f.resName & " " & $font & " 0 R "
  # images
  var imgRefs = ""
  for path in p.imageOrder:
    let im = p.images[path]
    var smask = ""
    if im.smask.len > 0:
      let sm = objs.put stream("/Type /XObject /Subtype /Image /Width " & $im.w & " /Height " & $im.h &
                               " /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode", im.smask, false)
      smask = " /SMask " & $sm & " 0 R"
    let o = objs.put "<< /Type /XObject /Subtype /Image /Width " & $im.w & " /Height " & $im.h & " /ColorSpace " &
                     im.colorSpace & " /BitsPerComponent " & $im.bpc & " /Filter " & im.filter & smask &
                     " /Length " & $im.data.len & " >>\nstream\n" & im.data & "\nendstream"
    imgRefs.add "/" & im.resName & " " & $o & " 0 R "
  var gsRefs = ""
  for key, name in p.gstates:
    let parts = key.split('/')
    let o = objs.put "<< /Type /ExtGState /ca " & parts[0] & " /CA " & parts[1] & " >>"
    gsRefs.add "/" & name & " " & $o & " 0 R "
  var shRefs = ""
  for i, sh in p.shadings:
    let o = objs.put sh
    shRefs.add "/Sh" & $(i + 1) & " " & $o & " 0 R "
  let res = objs.put "<< /ProcSet [/PDF /Text /ImageB /ImageC] /Font << " & fontRefs & ">> /XObject << " & imgRefs &
                     ">> /ExtGState << " & gsRefs & ">> /Shading << " & shRefs & ">> >>"
  # pages (object numbers reserved for resolving destinations)
  var pageIds: seq[int]
  for i in 0 ..< p.pages.len: pageIds.add objs.put("")
  proc dest(p: PdfWriter, pageIds: seq[int], id: string): string =
    if p.opts.anchors.hasKey(id):
      let a = p.opts.anchors[id]
      let pi = clamp(a.page - 1, 0, p.pages.high)
      let pg = p.pages[pi]
      return "[" & $pageIds[pi] & " 0 R /XYZ 0 " & num(pg.boxH - a.y + pg.offY + 12) & " null]"
    if id.startsWith("page-"):
      try:
        let pi = clamp(parseInt(id[5 .. ^1]) - 1, 0, p.pages.high)
        return "[" & $pageIds[pi] & " 0 R /Fit]"
      except ValueError: discard
    "[" & $pageIds[0] & " 0 R /Fit]"
  for i, pg in p.pages:
    let content = objs.put stream("", pg.content)
    var annots = ""
    for a in pg.annots:
      var s = a
      let k = s.find("«")
      if k >= 0:
        let e = s.find("»", k)
        let id = s[k + "«".len ..< e]
        s = s[0 ..< k] & p.dest(pageIds, id) & s[e + "»".len .. ^1]
      let o = objs.put s
      annots.add $o & " 0 R "
    var extra = ""
    if annots.len > 0: extra.add " /Annots [" & annots & "]"
    if p.opts.tagged: extra.add " /StructParents " & $i & " /Tabs /S"
    if p.opts.cropMarks:
      extra.add " /TrimBox [" & num(pg.offX) & " " & num(pg.offY) & " " & num(pg.offX + pg.boxW) & " " &
                num(pg.offY + pg.boxH) & "] /BleedBox [" & num(pg.offX - 8.5) & " " & num(pg.offY - 8.5) & " " &
                num(pg.offX + pg.boxW + 8.5) & " " & num(pg.offY + pg.boxH + 8.5) & "]"
    objs[pageIds[i] - 1] = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 " & num(pg.w) & " " & num(pg.h) &
                           "] /Resources " & $res & " 0 R /Contents " & $content & " 0 R" & extra & " >>"
  var kids = ""
  for id in pageIds: kids.add $id & " 0 R "
  objs[1] = "<< /Type /Pages /Kids [" & kids & "] /Count " & $pageIds.len & " >>"
  # bookmarks
  var outlineRef = ""
  if p.opts.outlines.len > 0:
    let ol = p.opts.outlines
    var ids: seq[int]
    for i in 0 ..< ol.len: ids.add objs.put("")
    let root = objs.put("")
    var parent = newSeq[int](ol.len)
    for i in 0 ..< ol.len:
      parent[i] = -1
      var k = i - 1
      while k >= 0:
        if ol[k].level < ol[i].level:
          parent[i] = k
          break
        dec k
    proc children(par: int): seq[int] =
      for i in 0 ..< ol.len:
        if parent[i] == par: result.add i
    proc countDesc(i: int): int =
      for c in children(i): result += 1 + countDesc(c)
    for i in 0 ..< ol.len:
      let sib = children(parent[i])
      let pos = sib.find(i)
      var d = "<< /Title " & pdfStr(ol[i].title) & " /Parent " & $(if parent[i] < 0: root else: ids[parent[i]]) & " 0 R"
      if pos > 0: d.add " /Prev " & $ids[sib[pos - 1]] & " 0 R"
      if pos < sib.high: d.add " /Next " & $ids[sib[pos + 1]] & " 0 R"
      let ch = children(i)
      if ch.len > 0:
        d.add " /First " & $ids[ch[0]] & " 0 R /Last " & $ids[ch[^1]] & " 0 R /Count -" & $countDesc(i)
      let pi = clamp(ol[i].page - 1, 0, max(0, p.pages.high))
      if p.pages.len > 0:
        let pg = p.pages[pi]
        d.add " /Dest [" & $pageIds[pi] & " 0 R /XYZ 0 " & num(pg.boxH - ol[i].y + pg.offY + 12) & " null]"
      d.add " >>"
      objs[ids[i] - 1] = d
    let top = children(-1)
    objs[root - 1] = "<< /Type /Outlines /First " & $ids[top[0]] & " 0 R /Last " & $ids[top[^1]] & " 0 R /Count " & $top.len & " >>"
    outlineRef = " /Outlines " & $root & " 0 R /PageMode /UseOutlines"
  # structure
  var structRef = ""
  if p.opts.tagged and p.structs.len > 0:
    let rootId = objs.put("")
    let docId = objs.put("")
    var elemIds: seq[int]
    for i in 0 ..< p.structs.len: elemIds.add objs.put("")
    for i, se in p.structs:
      var k = ""
      for m in se.mcids: k.add $m & " "
      var d = "<< /Type /StructElem /S /" & se.role & " /P " & $docId & " 0 R /Pg " & $pageIds[se.page] & " 0 R /K [" & k & "]"
      if se.alt.len > 0: d.add " /Alt " & pdfStr(se.alt)
      d.add " >>"
      objs[elemIds[i] - 1] = d
    var kidsS = ""
    for e in elemIds: kidsS.add $e & " 0 R "
    objs[docId - 1] = "<< /Type /StructElem /S /Document /P " & $rootId & " 0 R /K [" & kidsS & "] >>"
    var nums = ""
    for i, pg in p.pages:
      var arr = ""
      for si in pg.mcids: arr.add $elemIds[si] & " 0 R "
      nums.add $i & " [" & arr & "] "
    let pt = objs.put "<< /Nums [" & nums & "] >>"
    objs[rootId - 1] = "<< /Type /StructTreeRoot /K " & $docId & " 0 R /ParentTree " & $pt & " 0 R /ParentTreeNextKey " & $p.pages.len & " >>"
    structRef = " /StructTreeRoot " & $rootId & " 0 R /MarkInfo << /Marked true >>"
  let lang = if p.opts.lang.len > 0: p.opts.lang else: "fr-FR"
  objs[0] = "<< /Type /Catalog /Pages 2 0 R /Lang " & pdfStr(lang) &
            " /ViewerPreferences << /DisplayDocTitle true >>" & outlineRef & structRef & " >>"
  let now = now().utc.format("yyyyMMddHHmmss")
  var info = "<< /Producer (Kaleido - Lexis+) /Creator (Kaleido) /CreationDate (D:" & now & "Z)"
  if p.opts.title.len > 0: info.add " /Title " & pdfStr(p.opts.title)
  if p.opts.author.len > 0: info.add " /Author " & pdfStr(p.opts.author)
  if p.opts.subject.len > 0: info.add " /Subject " & pdfStr(p.opts.subject)
  if p.opts.keywords.len > 0: info.add " /Keywords " & pdfStr(p.opts.keywords)
  info.add " >>"
  let infoId = objs.put info
  # exit
  result = "%PDF-1.7\n%\xE2\xE3\xCF\xD3\n"
  var offsets: seq[int]
  for i, o in objs:
    offsets.add result.len
    result.add $(i + 1) & " 0 obj\n" & o & "\nendobj\n"
  let xref = result.len
  result.add "xref\n0 " & $(objs.len + 1) & "\n0000000000 65535 f \n"
  for o in offsets: result.add align($o, 10, '0') & " 00000 n \n"
  result.add "trailer\n<< /Size " & $(objs.len + 1) & " /Root 1 0 R /Info " & $infoId & " 0 R >>\nstartxref\n" & $xref & "\n%%EOF\n"

proc save*(p: PdfWriter, path: string) =
  writeFile(path, p.toBytes)
