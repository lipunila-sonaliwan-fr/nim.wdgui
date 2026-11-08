# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
#   wdgui - image decoding in pure Nim (no C libraries): PNG and JPEG.
#
#   decodeImageData(data) / decodeImageFile(path) -> RgbaImage (8-bit RGBA)
#
# Used for reports (on-screen previews, PNG images from PDFs): this code is part of
# the runtime for generated applications, which is transpiled into C without the
# 'stb' headers; it must therefore remain in pure Nim.
#   PNG: all bit depths (1 to 16 bits), palette, transparency, non-interlaced.
#   JPEG: sequential (baseline and extended, Huffman), grayscale, YCbCr, CMYK;
#         progressive JPEG is not supported ("progressive JPEG format not supported").

import std/math
import zflate

type
  RgbaImage* = object
    w*, h*: int
    px*: seq[uint8]              # R, G, B, A ligne par ligne (w * h * 4 bytes)

proc be16(s: string, i: int): int = (ord(s[i]) shl 8) or ord(s[i + 1])
proc be32(s: string, i: int): int =
  (ord(s[i]) shl 24) or (ord(s[i + 1]) shl 16) or (ord(s[i + 2]) shl 8) or ord(s[i + 3])

# ------------------------------------------------------------------ PNG

proc paeth(a, b, c: int): int =
  let p = a + b - c
  let pa = abs(p - a)
  let pb = abs(p - b)
  let pc = abs(p - c)
  if pa <= pb and pa <= pc: a elif pb <= pc: b else: c

proc decodePng*(data: string): RgbaImage =
  if data.len < 33 or data[0 ..< 8] != "\x89PNG\r\n\x1a\n": raise newException(ValueError, "PNG invalide")
  var w, h, depth, ctype, interlace = 0
  var plte, trns, idat = ""
  var i = 8
  while i + 8 <= data.len:
    let len = be32(data, i)
    let typ = data[i + 4 ..< i + 8]
    if len < 0 or i + 8 + len > data.len: break
    let body = data[i + 8 ..< i + 8 + len]
    case typ
    of "IHDR":
      w = be32(body, 0)
      h = be32(body, 4)
      depth = ord(body[8])
      ctype = ord(body[9])
      interlace = ord(body[12])
    of "PLTE": plte = body
    of "tRNS": trns = body
    of "IDAT": idat.add body
    of "IEND": break
    else: discard
    i += 12 + len
  if w <= 0 or h <= 0: raise newException(ValueError, "PNG sans dimensions")
  if interlace != 0: raise newException(ValueError, "PNG entrelacé non pris en charge")
  let channels = case ctype
    of 0: 1
    of 2: 3
    of 3: 1
    of 4: 2
    of 6: 4
    else: raise newException(ValueError, "type de couleur PNG inconnu")
  let bitsPx = channels * depth
  let stride = (w * bitsPx + 7) div 8
  let bpp = max(1, bitsPx div 8)
  let raw = zlibDecompress(idat)
  if raw.len < h * (stride + 1): raise newException(ValueError, "PNG tronqué")
  var pix = newString(h * stride)
  var prevRow = newString(stride)
  for y in 0 ..< h:
    let f = ord(raw[y * (stride + 1)])
    var row = raw[y * (stride + 1) + 1 ..< (y + 1) * (stride + 1)]
    for x in 0 ..< stride:
      let a = if x >= bpp: ord(row[x - bpp]) else: 0
      let b = ord(prevRow[x])
      let c = if x >= bpp: ord(prevRow[x - bpp]) else: 0
      let v = ord(row[x])
      row[x] = char(case f
        of 1: (v + a) and 0xFF
        of 2: (v + b) and 0xFF
        of 3: (v + (a + b) div 2) and 0xFF
        of 4: (v + paeth(a, b, c)) and 0xFF
        else: v)
    if stride > 0: copyMem(addr pix[y * stride], addr row[0], stride)
    prevRow = row
  proc sample(y, k: int): int =
    case depth
    of 8: ord(pix[y * stride + k])
    of 16: ord(pix[y * stride + k * 2])
    else:
      let bit = k * depth
      let byte = ord(pix[y * stride + bit div 8])
      let v = (byte shr (8 - depth - bit mod 8)) and ((1 shl depth) - 1)
      if ctype == 3: v else: v * 255 div ((1 shl depth) - 1)
  let grayKey = if ctype == 0 and trns.len >= 2:
                  (if depth == 16: ord(trns[0]) else: be16(trns, 0) * (if depth < 8: 255 div ((1 shl depth) - 1) else: 1))
                else: -1
  result.w = w
  result.h = h
  result.px = newSeq[uint8](w * h * 4)
  var o = 0
  for y in 0 ..< h:
    for x in 0 ..< w:
      var r, g, b, a = 255
      case ctype
      of 0:
        r = sample(y, x)
        g = r
        b = r
        if r == grayKey: a = 0
      of 2:
        r = sample(y, x * 3)
        g = sample(y, x * 3 + 1)
        b = sample(y, x * 3 + 2)
      of 3:
        let idx = sample(y, x)
        if idx * 3 + 2 < plte.len:
          r = ord(plte[idx * 3])
          g = ord(plte[idx * 3 + 1])
          b = ord(plte[idx * 3 + 2])
        if idx < trns.len: a = ord(trns[idx])
      of 4:
        r = sample(y, x * 2)
        g = r
        b = r
        a = sample(y, x * 2 + 1)
      else:
        r = sample(y, x * 4)
        g = sample(y, x * 4 + 1)
        b = sample(y, x * 4 + 2)
        a = sample(y, x * 4 + 3)
      result.px[o] = uint8(r)
      result.px[o + 1] = uint8(g)
      result.px[o + 2] = uint8(b)
      result.px[o + 3] = uint8(a)
      o += 4

# ------------------------------------------------------------------ JPEG

const ZigZag = [0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48,
                41, 34, 27, 20, 13, 6, 7, 14, 21, 28, 35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15,
                23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63]

type
  JHuff = object
    maxCode: array[18, int]
    valPtr: array[17, int]
    minCode: array[17, int]
    vals: seq[int]
    present: bool
  JComp = object
    id, h, v, tq, td, ta: int
    bw, bh: int                         # blocks per line / per column (full MCUs)
    plane: seq[uint8]
    pred: int
  JReader = object
    data: string
    pos: int
    acc: uint32
    n: int

proc buildHuff(counts: openArray[int], vals: seq[int]): JHuff =
  result.vals = vals
  result.present = true
  var code = 0
  var k = 0
  for l in 1 .. 16:
    result.valPtr[l] = k
    result.minCode[l] = code
    code += counts[l - 1]
    k += counts[l - 1]
    result.maxCode[l] = if counts[l - 1] > 0: code - 1 else: -1
    code = code shl 1
  result.maxCode[17] = int.high

proc fill(r: var JReader) =
  while r.n <= 24:
    var b = 0
    if r.pos < r.data.len:
      b = ord(r.data[r.pos])
      if b == 0xFF:
        let nx = if r.pos + 1 < r.data.len: ord(r.data[r.pos + 1]) else: 0
        if nx == 0:
          r.pos += 2
        else:
          b = 0                         # marker: pad with zeros
      else: inc r.pos
    r.acc = r.acc or (uint32(b) shl (24 - r.n))
    r.n += 8

proc bit(r: var JReader): int =
  r.fill()
  result = int(r.acc shr 31)
  r.acc = r.acc shl 1
  dec r.n

proc bits(r: var JReader, n: int): int =
  for _ in 0 ..< n: result = (result shl 1) or r.bit()

proc decodeSym(r: var JReader, h: JHuff): int =
  var code = 0
  for l in 1 .. 16:
    code = (code shl 1) or r.bit()
    if h.maxCode[l] >= 0 and code <= h.maxCode[l]:
      return h.vals[h.valPtr[l] + code - h.minCode[l]]
  raise newException(ValueError, "JPEG : code de Huffman invalide")

proc extend(v, t: int): int =
  if t == 0: 0 elif v < (1 shl (t - 1)): v - (1 shl t) + 1 else: v

proc makeIdctCos(): array[8, array[8, float]] =
  for x in 0 .. 7:
    for u in 0 .. 7:
      let cu = if u == 0: 1.0 / sqrt(2.0) else: 1.0
      result[x][u] = cu * cos(float((2 * x + 1) * u) * PI / 16.0) / 2.0

const idctCos = makeIdctCos()

proc idct(blk: var array[64, float], dst: var seq[uint8], stride, x0, y0: int) =
  var tmp: array[64, float]
  for y in 0 .. 7:
    for u in 0 .. 7:
      var s = 0.0
      for v in 0 .. 7: s += idctCos[y][v] * blk[v * 8 + u]
      tmp[y * 8 + u] = s
  for y in 0 .. 7:
    for x in 0 .. 7:
      var s = 0.0
      for u in 0 .. 7: s += idctCos[x][u] * tmp[y * 8 + u]
      let v = int(round(s + 128.0))
      dst[(y0 + y) * stride + x0 + x] = uint8(clamp(v, 0, 255))

proc decodeJpeg*(data: string): RgbaImage =
  if data.len < 4 or data[0] != '\xFF' or data[1] != '\xD8': raise newException(ValueError, "JPEG invalide")
  var qt: array[4, array[64, int]]
  var dcT, acT: array[4, JHuff]
  var comps: seq[JComp]
  var w, h, hmax, vmax = 0
  var restart = 0
  var adobe = -1
  var i = 2
  var done = false
  while i + 4 <= data.len and not done:
    if data[i] != '\xFF':
      inc i
      continue
    let m = ord(data[i + 1])
    if m == 0xFF:
      inc i
      continue
    if m == 0xD8 or (m >= 0xD0 and m <= 0xD7) or m == 0x01:
      i += 2
      continue
    if m == 0xD9: break
    let len = be16(data, i + 2)
    let seg = i + 4
    let segEnd = i + 2 + len
    if segEnd > data.len: raise newException(ValueError, "JPEG tronqué")
    case m
    of 0xDB:                                       # quantization tables
      var p = seg
      while p < segEnd:
        let pq = ord(data[p]) shr 4
        let tq = ord(data[p]) and 3
        inc p
        for k in 0 .. 63:
          qt[tq][ZigZag[k]] = if pq == 0: ord(data[p + k]) else: be16(data, p + k * 2)
        p += (if pq == 0: 64 else: 128)
    of 0xC4:                                       # Huffman tables
      var p = seg
      while p < segEnd:
        let tc = ord(data[p]) shr 4
        let th = ord(data[p]) and 3
        var counts: array[16, int]
        var total = 0
        for k in 0 .. 15:
          counts[k] = ord(data[p + 1 + k])
          total += counts[k]
        var vals = newSeq[int](total)
        for k in 0 ..< total: vals[k] = ord(data[p + 17 + k])
        if tc == 0: dcT[th] = buildHuff(counts, vals) else: acT[th] = buildHuff(counts, vals)
        p += 17 + total
    of 0xC0, 0xC1:                                 # sequential (Huffman)
      h = be16(data, seg + 1)
      w = be16(data, seg + 3)
      let nc = ord(data[seg + 5])
      for k in 0 ..< nc:
        let b = seg + 6 + k * 3
        comps.add JComp(id: ord(data[b]), h: ord(data[b + 1]) shr 4, v: ord(data[b + 1]) and 15,
                        tq: ord(data[b + 2]) and 3)
        hmax = max(hmax, comps[^1].h)
        vmax = max(vmax, comps[^1].v)
    of 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF:
      raise newException(ValueError, "Progressive (or arithmetic) JPEG format not supported")
    of 0xDD: restart = be16(data, seg)
    of 0xEE:
      if len >= 12 and data[seg ..< seg + 5] == "Adobe": adobe = ord(data[seg + 11])
    of 0xDA:                                       # start of scan
      if comps.len == 0 or w <= 0 or h <= 0: raise newException(ValueError, "JPEG without dimensions")
      let ns = ord(data[seg])
      var scomp: seq[int]
      for k in 0 ..< ns:
        let cid = ord(data[seg + 1 + k * 2])
        let t = ord(data[seg + 2 + k * 2])
        for ci in 0 ..< comps.len:
          if comps[ci].id == cid:
            comps[ci].td = t shr 4
            comps[ci].ta = t and 15
            scomp.add ci
      let mcuW = 8 * hmax
      let mcuH = 8 * vmax
      let mcusX = (w + mcuW - 1) div mcuW
      let mcusY = (h + mcuH - 1) div mcuH
      for c in comps.mitems:
        c.bw = mcusX * c.h
        c.bh = mcusY * c.v
        c.plane = newSeq[uint8](c.bw * 8 * c.bh * 8)
        c.pred = 0
      var r = JReader(data: data, pos: segEnd)
      var blk: array[64, float]
      var mcu = 0
      let total = mcusX * mcusY
      while mcu < total:
        if restart > 0 and mcu > 0 and mcu mod restart == 0:
          # resynchronisation sur le marqueur RSTn
          r.acc = 0
          r.n = 0
          while r.pos + 1 < data.len and not (data[r.pos] == '\xFF' and ord(data[r.pos + 1]) in 0xD0 .. 0xD7):
            inc r.pos
          r.pos += 2
          for c in comps.mitems: c.pred = 0
        let my = mcu div mcusX
        let mx = mcu mod mcusX
        for ci in scomp:
          let c = addr comps[ci]
          for by in 0 ..< c.v:
            for bx in 0 ..< c.h:
              for k in 0 .. 63: blk[k] = 0
              let t = r.decodeSym(dcT[c.td])
              c.pred += extend(r.bits(t), t)
              blk[0] = float(c.pred * qt[c.tq][0])
              var k = 1
              while k < 64:
                let rs = r.decodeSym(acT[c.ta])
                let run = rs shr 4
                let s = rs and 15
                if s == 0:
                  if run == 15:
                    k += 16
                    continue
                  break
                k += run
                if k > 63: break
                blk[ZigZag[k]] = float(extend(r.bits(s), s) * qt[c.tq][ZigZag[k]])
                inc k
              idct(blk, c.plane, c.bw * 8, (mx * c.h + bx) * 8, (my * c.v + by) * 8)
        inc mcu
      done = true
    else: discard
    i = segEnd
  if not done: raise newException(ValueError, "JPEG without an image")
  result.w = w
  result.h = h
  result.px = newSeq[uint8](w * h * 4)
  let nc = comps.len
  var o = 0
  for y in 0 ..< h:
    for x in 0 ..< w:
      var v: array[4, float]
      for ci in 0 ..< min(nc, 4):
        let c = addr comps[ci]
        let pw = c.bw * 8
        if c.h == hmax and c.v == vmax:
          v[ci] = float(c.plane[y * pw + x])
        else:                                      # downsampling: bilinear interpolation
          let fx = max(0.0, (float(x) + 0.5) * float(c.h) / float(hmax) - 0.5)
          let fy = max(0.0, (float(y) + 0.5) * float(c.v) / float(vmax) - 0.5)
          let x0 = int(fx)
          let y0 = int(fy)
          let x1 = min(x0 + 1, (w * c.h + hmax - 1) div hmax - 1).max(x0)
          let y1 = min(y0 + 1, (h * c.v + vmax - 1) div vmax - 1).max(y0)
          let ax = fx - float(x0)
          let ay = fy - float(y0)
          let top = float(c.plane[y0 * pw + x0]) * (1 - ax) + float(c.plane[y0 * pw + x1]) * ax
          let bot = float(c.plane[y1 * pw + x0]) * (1 - ax) + float(c.plane[y1 * pw + x1]) * ax
          v[ci] = top * (1 - ay) + bot * ay
      var rr, gg, bb: float
      if nc == 1:
        rr = v[0]
        gg = v[0]
        bb = v[0]
      elif nc == 3 and adobe != 0:
        rr = v[0] + 1.402 * (v[2] - 128)
        gg = v[0] - 0.344136 * (v[1] - 128) - 0.714136 * (v[2] - 128)
        bb = v[0] + 1.772 * (v[1] - 128)
      elif nc == 3:
        rr = v[0]
        gg = v[1]
        bb = v[2]
      else:
        var cc = v[0]
        var mm = v[1]
        var yy = v[2]
        if adobe == 2:                             # YCCK
          cc = v[0] + 1.402 * (v[2] - 128)
          mm = v[0] - 0.344136 * (v[1] - 128) - 0.714136 * (v[2] - 128)
          yy = v[0] + 1.772 * (v[1] - 128)
        # JPEG Adobe : CMJN inversé
        rr = cc * v[3] / 255
        gg = mm * v[3] / 255
        bb = yy * v[3] / 255
      result.px[o] = uint8(clamp(int(round(rr)), 0, 255))
      result.px[o + 1] = uint8(clamp(int(round(gg)), 0, 255))
      result.px[o + 2] = uint8(clamp(int(round(bb)), 0, 255))
      result.px[o + 3] = 255
      o += 4

# ------------------------------------------------------------------ entry

proc decodeImageData*(data: string): RgbaImage =
  if data.len > 3 and data[0 .. 2] == "\xFF\xD8\xFF": decodeJpeg(data)
  elif data.len > 8 and data[0 .. 3] == "\x89PNG": decodePng(data)
  else: raise newException(ValueError, "format non pris en charge (PNG ou JPEG)")

proc decodeImageFile*(path: string): RgbaImage = decodeImageData(readFile(path))
