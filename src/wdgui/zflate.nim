# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
#   wdgui - zlib compression (RFC 1950 / 1951) in pure Nim, with no C library dependencies:
#   used by the report PDF generator (compressed streams, PNG images), which
#   must also function within the generated applications.
#
#   zlibCompress(data)    zlib stream (deflate, fixed Huffman codes, LZ77)
#   zlibDecompress(data)  zlib stream -> data (PNG: IDAT)
#   inflateRaw(data)      raw deflate stream -> data

# ---------------------------------------------------------------- compression

type BitWriter = object
  buf: string
  acc: uint32
  n: int

proc putBits(w: var BitWriter, v: uint32, count: int) =
  # bits de poids faible d'abord (ordre deflate).
  w.acc = w.acc or (v shl w.n)
  w.n += count
  while w.n >= 8:
    w.buf.add char(w.acc and 0xFF)
    w.acc = w.acc shr 8
    w.n -= 8

proc putRev(w: var BitWriter, code: uint32, len: int) =
  # codes de Huffman : bit de poids fort d'abord.
  var r = 0'u32
  for i in 0 ..< len:
    if (code and (1'u32 shl i)) != 0: r = r or (1'u32 shl (len - 1 - i))
  w.putBits(r, len)

proc flush(w: var BitWriter) =
  if w.n > 0:
    w.buf.add char(w.acc and 0xFF)
    w.acc = 0
    w.n = 0

const
  LenBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59,
             67, 83, 99, 115, 131, 163, 195, 227, 258]
  LenExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
  DistBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769,
              1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
  DistExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10,
               11, 11, 12, 12, 13, 13]

proc putLitLen(w: var BitWriter, sym: int) =
  # fixed codes: 0–143 in 8 bits, 144–255 in 9 bits, 256–279 in 7 bits, 280–287 in 8 bits.
  if sym < 144: w.putRev(uint32(0x30 + sym), 8)
  elif sym < 256: w.putRev(uint32(0x190 + sym - 144), 9)
  elif sym < 280: w.putRev(uint32(sym - 256), 7)
  else: w.putRev(uint32(0xC0 + sym - 280), 8)

proc adler32(data: string): uint32 =
  var a = 1'u32
  var b = 0'u32
  for c in data:
    a = (a + uint32(ord(c))) mod 65521
    b = (b + a) mod 65521
  (b shl 16) or a

proc zlibCompress*(data: string): string =
  # zlib stream: a deflate block with fixed codes, LZ77 search via hash chains.
  result = "\x78\x9C"
  var w: BitWriter
  w.putBits(1, 1)          # last block
  w.putBits(1, 2)          # fixed codes
  const HashSize = 1 shl 15
  const Window = 32768
  const MaxChain = 48
  var head = newSeq[int32](HashSize)
  for i in 0 ..< HashSize: head[i] = -1
  var prev = newSeq[int32](data.len)
  template hashAt(i: int): int =
    ((ord(data[i]) shl 10) xor (ord(data[i + 1]) shl 5) xor ord(data[i + 2])) and (HashSize - 1)
  template insert(i: int) =
    if i + 2 < data.len:
      let h = hashAt(i)
      prev[i] = head[h]
      head[h] = int32(i)
  var i = 0
  while i < data.len:
    var bestLen = 0
    var bestDist = 0
    if i + 2 < data.len:
      var cand = int(head[hashAt(i)])
      var chain = 0
      while cand >= 0 and i - cand <= Window and chain < MaxChain:
        var l = 0
        let maxL = min(258, data.len - i)
        while l < maxL and data[cand + l] == data[i + l]: inc l
        if l > bestLen:
          bestLen = l
          bestDist = i - cand
          if l == maxL: break
        cand = int(prev[cand])
        inc chain
    if bestLen >= 3:
      var li = 0
      while li + 1 < LenBase.len and LenBase[li + 1] <= bestLen: inc li
      w.putLitLen(257 + li)
      if LenExtra[li] > 0: w.putBits(uint32(bestLen - LenBase[li]), LenExtra[li])
      var di = 0
      while di + 1 < DistBase.len and DistBase[di + 1] <= bestDist: inc di
      w.putRev(uint32(di), 5)
      if DistExtra[di] > 0: w.putBits(uint32(bestDist - DistBase[di]), DistExtra[di])
      for k in 0 ..< bestLen:
        insert(i + k)
      i += bestLen
    else:
      w.putLitLen(ord(data[i]))
      insert(i)
      inc i
  w.putLitLen(256)
  w.flush()
  if w.buf.len > data.len + data.len div 64 + 16:
    # incompressible data (photo, already compressed): stored as blocks.
    w.buf.setLen(0)
    var p = 0
    while true:
      let n = min(65535, data.len - p)
      let last = p + n >= data.len
      w.buf.add char(if last: 1 else: 0)
      w.buf.add char(n and 0xFF)
      w.buf.add char(n shr 8)
      w.buf.add char((not n) and 0xFF)
      w.buf.add char(((not n) shr 8) and 0xFF)
      w.buf.add data[p ..< p + n]
      p += n
      if last: break
  result.add w.buf
  let a = adler32(data)
  for s in [24, 16, 8, 0]: result.add char((a shr s) and 0xFF)

# -------------------------------------------------------------- decompression

type
  BitReader = object
    data: string
    pos: int
    acc: uint32
    n: int
  Huff = object
    counts: array[16, int]
    symbols: seq[int]

proc need(r: var BitReader, count: int) =
  while r.n < count:
    if r.pos >= r.data.len: raise newException(ValueError, "truncated deflate stream")
    r.acc = r.acc or (uint32(ord(r.data[r.pos])) shl r.n)
    inc r.pos
    r.n += 8

proc bits(r: var BitReader, count: int): int =
  if count == 0: return 0
  r.need(count)
  result = int(r.acc and ((1'u32 shl count) - 1))
  r.acc = r.acc shr count
  r.n -= count

proc build(lengths: openArray[int]): Huff =
  result.symbols = newSeq[int](lengths.len)
  for l in lengths: inc result.counts[l]
  result.counts[0] = 0
  var offs: array[16, int]
  for i in 1 .. 15: offs[i] = offs[i - 1] + result.counts[i - 1]
  for s, l in lengths:
    if l > 0:
      result.symbols[offs[l]] = s
      inc offs[l]

proc decode(r: var BitReader, h: Huff): int =
  var code, first, index = 0
  for l in 1 .. 15:
    code = code or r.bits(1)
    let count = h.counts[l]
    if code - count < first: return h.symbols[index + (code - first)]
    index += count
    first += count
    first = first shl 1
    code = code shl 1
  raise newException(ValueError, "invalid Huffman code")

proc inflateRaw*(data: string, start = 0): string =
  var r = BitReader(data: data, pos: start)
  var fixedLit, fixedDist: Huff
  block:
    var l = newSeq[int](288)
    for i in 0 ..< 288: l[i] = (if i < 144: 8 elif i < 256: 9 elif i < 280: 7 else: 8)
    fixedLit = build(l)
    var d = newSeq[int](30)
    for i in 0 ..< 30: d[i] = 5
    fixedDist = build(d)
  while true:
    let final = r.bits(1)
    let typ = r.bits(2)
    case typ
    of 0:
      r.acc = 0
      r.n = 0
      if r.pos + 4 > r.data.len: raise newException(ValueError, "truncated deflate stream")
      let len = ord(r.data[r.pos]) or (ord(r.data[r.pos + 1]) shl 8)
      r.pos += 4
      if r.pos + len > r.data.len: raise newException(ValueError, "truncated deflate stream")
      result.add r.data[r.pos ..< r.pos + len]
      r.pos += len
    of 1, 2:
      var lit, dist: Huff
      if typ == 1:
        lit = fixedLit
        dist = fixedDist
      else:
        let hlit = r.bits(5) + 257
        let hdist = r.bits(5) + 1
        let hclen = r.bits(4) + 4
        const order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
        var cl = newSeq[int](19)
        for i in 0 ..< hclen: cl[order[i]] = r.bits(3)
        let clh = build(cl)
        var lens = newSeq[int]()
        while lens.len < hlit + hdist:
          let s = r.decode(clh)
          if s < 16: lens.add s
          elif s == 16:
            if lens.len == 0: raise newException(ValueError, "invalid lengths")
            let p = lens[^1]
            for _ in 0 ..< 3 + r.bits(2): lens.add p
          elif s == 17:
            for _ in 0 ..< 3 + r.bits(3): lens.add 0
          else:
            for _ in 0 ..< 11 + r.bits(7): lens.add 0
        lit = build(lens[0 ..< hlit])
        dist = build(lens[hlit ..< hlit + hdist])
      while true:
        let s = r.decode(lit)
        if s < 256: result.add char(s)
        elif s == 256: break
        else:
          let li = s - 257
          if li >= LenBase.len: raise newException(ValueError, "invalid lengths")
          let length = LenBase[li] + r.bits(LenExtra[li])
          let di = r.decode(dist)
          if di >= DistBase.len: raise newException(ValueError, "invalid distance")
          let d = DistBase[di] + r.bits(DistExtra[di])
          if d > result.len: raise newException(ValueError, "invalid distance")
          let from0 = result.len - d
          for k in 0 ..< length: result.add result[from0 + k]
    else: raise newException(ValueError, "invalid deflate block")
    if final == 1: break

proc zlibDecompress*(data: string): string =
  if data.len < 2: raise newException(ValueError, "empty zlib stream")
  inflateRaw(data, 2)
