# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
#   wdgui - images in pure Nim for application runtimes (no stb):
#   PNG writing (8-bit RGBA, zlib compression) and GIF reading (first frame).
#
# The runtime for generated applications is transpiled to C without stb headers:
# this module must depend only on Nim (and zflate).

import zflate, imagedecode

proc crc32(s: string): uint32 =
  var table {.global.}: array[256, uint32]
  var ready {.global.} = false
  {.cast(gcsafe).}:
    if not ready:
      for n in 0 .. 255:
        var c = uint32(n)
        for k in 0 .. 7:
          c = if (c and 1) != 0: 0xEDB88320'u32 xor (c shr 1) else: c shr 1
        table[n] = c
      ready = true
    result = 0xFFFFFFFF'u32
    for ch in s:
      result = table[(result xor uint32(ord(ch))) and 0xFF] xor (result shr 8)
  result = result xor 0xFFFFFFFF'u32

proc be32s(v: uint32): string =
  result = newString(4)
  result[0] = char((v shr 24) and 0xFF)
  result[1] = char((v shr 16) and 0xFF)
  result[2] = char((v shr 8) and 0xFF)
  result[3] = char(v and 0xFF)

proc chunk(kind, data: string): string =
  be32s(uint32(data.len)) & kind & data & be32s(crc32(kind & data))

proc encodePngPure*(img: RgbaImage): string =
  # 8-bit RGBA PNG ("Sub" filter applied to each row: provides good compression for areas of solid color).
  var raw = newString((img.w * 4 + 1) * img.h)
  var p = 0
  for y in 0 ..< img.h:
    raw[p] = '\1'
    inc p
    let row = y * img.w * 4
    for x in 0 ..< img.w * 4:
      let cur = int(img.px[row + x])
      let left = if x >= 4: int(img.px[row + x - 4]) else: 0
      raw[p] = char((cur - left) and 0xFF)
      inc p
  result = "\x89PNG\r\n\x1a\n"
  result.add chunk("IHDR", be32s(uint32(img.w)) & be32s(uint32(img.h)) & "\8\6\0\0\0")
  result.add chunk("IDAT", zlibCompress(raw))
  result.add chunk("IEND", "")

proc decodeGif*(data: string): RgbaImage =
  # GIF87a / GIF89a: first image (global and local palettes, transparency, interlacing).
  if data.len < 13 or data[0 .. 2] != "GIF": raise newException(ValueError, "GIF invalide")
  proc u16(i: int): int = ord(data[i]) or (ord(data[i + 1]) shl 8)
  let w = u16(6)
  let h = u16(8)
  let flags = ord(data[10])
  var pos = 13
  var gpal: seq[array[3, uint8]]
  if (flags and 0x80) != 0:
    let n = 1 shl ((flags and 7) + 1)
    for i in 0 ..< n:
      gpal.add [uint8(ord(data[pos])), uint8(ord(data[pos + 1])), uint8(ord(data[pos + 2]))]
      pos += 3
  var transp = -1
  result = RgbaImage(w: w, h: h, px: newSeq[uint8](w * h * 4))
  while pos < data.len:
    let b = ord(data[pos])
    inc pos
    if b == 0x21:                                    # extension
      let label = ord(data[pos])
      inc pos
      if label == 0xF9 and ord(data[pos]) >= 4:
        if (ord(data[pos + 1]) and 1) != 0: transp = ord(data[pos + 4])
      while pos < data.len and ord(data[pos]) != 0: pos += ord(data[pos]) + 1
      inc pos
    elif b == 0x2C:                                  # image
      let ix = u16(pos)
      let iy = u16(pos + 2)
      let iw = u16(pos + 4)
      let ih = u16(pos + 6)
      let lf = ord(data[pos + 8])
      pos += 9
      var pal = gpal
      if (lf and 0x80) != 0:
        pal.setLen(0)
        let n = 1 shl ((lf and 7) + 1)
        for i in 0 ..< n:
          pal.add [uint8(ord(data[pos])), uint8(ord(data[pos + 1])), uint8(ord(data[pos + 2]))]
          pos += 3
      let interlaced = (lf and 0x40) != 0
      let minCode = ord(data[pos])
      inc pos
      var lzw = ""
      while pos < data.len and ord(data[pos]) != 0:
        let n = ord(data[pos])
        lzw.add data[pos + 1 .. pos + n]
        pos += n + 1
      inc pos
      # LZW decompression
      let clear = 1 shl minCode
      let eoi = clear + 1
      var prefix = newSeq[int](4096)
      var suffix = newSeq[uint8](4096)
      var first = newSeq[uint8](4096)
      for i in 0 ..< clear:
        suffix[i] = uint8(i)
        first[i] = uint8(i)
        prefix[i] = -1
      var size = minCode + 1
      var next = eoi + 1
      var old = -1
      var bitPos = 0
      var indices: seq[uint8]
      var stack: seq[uint8]
      let total = iw * ih
      while indices.len < total:
        if (bitPos + size) > lzw.len * 8: break
        var code = 0
        for k in 0 ..< size:
          let bit = (ord(lzw[(bitPos + k) shr 3]) shr ((bitPos + k) and 7)) and 1
          code = code or (bit shl k)
        bitPos += size
        if code == clear:
          size = minCode + 1
          next = eoi + 1
          old = -1
          continue
        if code == eoi: break
        var c = code
        stack.setLen(0)
        if code >= next:
          if old < 0: break
          stack.add first[old]
          c = old
        while c >= 0 and stack.len < 4096:
          stack.add suffix[c]
          c = prefix[c]
        for k in countdown(stack.high, 0): indices.add stack[k]
        if old >= 0 and next < 4096:
          prefix[next] = old
          suffix[next] = stack[^1]
          first[next] = first[old]
          inc next
          if next == (1 shl size) and size < 12: inc size
        old = code
      # placement (interlacing: passes 8, 8, 4, 2)
      var rows: seq[int]
      if interlaced:
        for (start, step) in [(0, 8), (4, 8), (2, 4), (1, 2)]:
          var r = start
          while r < ih:
            rows.add r
            r += step
      else:
        for r in 0 ..< ih: rows.add r
      for k, idx in indices:
        if k >= total: break
        let ry = rows[k div iw]
        let x = ix + k mod iw
        let y = iy + ry
        if x >= w or y >= h: continue
        let ci = int(idx)
        if ci == transp or ci >= pal.len: continue
        let d = (y * w + x) * 4
        result.px[d] = pal[ci][0]
        result.px[d + 1] = pal[ci][1]
        result.px[d + 2] = pal[ci][2]
        result.px[d + 3] = 255
      return
    elif b == 0x3B: break
    else: break
