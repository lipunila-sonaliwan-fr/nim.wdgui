# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
#
# gfx.nim - Drawing adapter
#
# Every graphics primitive used by wdreka goes through this module. At
# compile time (`when compiles`) it tries the plausible signatures of the
# wdgui `Drawing` API (drawing.nim). If your wdgui version differs, this
# is the ONLY file to adjust: an explicit error names the primitive
# concerned.
#
# Colors are handled as "#RRGGBB" or "#RRGGBBAA" strings
# (mix / alpha functions below) then converted with `hex`.

import std/[math, strutils]
import ../../src/wdgui

#
# Colors
#

proc col*(s: string): Color = hex(s)

proc parseHexColor(s: string): (int, int, int, int) =
  var h = s.strip()
  if h.startsWith("#"): h = h[1 .. ^1]
  if h.len == 3:
    h = h[0] & h[0] & h[1] & h[1] & h[2] & h[2]
  var a = 255
  try:
    let r = parseHexInt(h[0 .. 1])
    let g = parseHexInt(h[2 .. 3])
    let b = parseHexInt(h[4 .. 5])
    if h.len >= 8: a = parseHexInt(h[6 .. 7])
    result = (r, g, b, a)
  except ValueError, IndexDefect:
    result = (128, 128, 128, 255)

proc toHex2(v: int): string = toHex(max(0, min(255, v)), 2)

proc rgbaHex*(r, g, b, a: int): string =
  "#" & toHex2(r) & toHex2(g) & toHex2(b) & toHex2(a)

proc alpha*(s: string, a: float): string =
  # same color, opacity a (0..1)
  let (r, g, b, _) = parseHexColor(s)
  rgbaHex(r, g, b, int(a * 255))

proc mix*(s1, s2: string, t: float): string =
  # linear blend s1 -> s2
  let (r1, g1, b1, a1) = parseHexColor(s1)
  let (r2, g2, b2, a2) = parseHexColor(s2)
  template m(a, b: int): int = int(float(a) + (float(b) - float(a)) * t)
  rgbaHex(m(r1, r2), m(g1, g2), m(b1, b2), m(a1, a2))

proc lighten*(s: string, t: float): string = mix(s, "#FFFFFF", t)
proc darken*(s: string, t: float): string = mix(s, "#000000", t)

#
# Rectangles
#

proc mkRect*(x, y, w, h: float): auto =
  when compiles(rect(x, y, w, h)):
    rect(x, y, w, h)
  else:
    rect(float32(x), float32(y), float32(w), float32(h))

template ctlRect*(c: untyped): (float, float, float, float) =
  # rectangle of a control as floats (x, y, w, h)
  (float(c.rect.x), float(c.rect.y), float(c.rect.w), float(c.rect.h))

#
# Primitives
#

proc gFillRect*(d: Drawing, x, y, w, h: float, c: string) =
  if w <= 0 or h <= 0: return
  let r = mkRect(x, y, w, h)
  when compiles(d.fillRect(r, col(c))):
    d.fillRect(r, col(c))
  elif compiles(d.fillRect(x, y, w, h, col(c))):
    d.fillRect(x, y, w, h, col(c))
  else:
    {.error: "gfx.gFillRect: adapt the call to Drawing.fillRect".}

proc gFillRound*(d: Drawing, x, y, w, h, rad: float, c: string) =
  if w <= 0 or h <= 0: return
  let rr = max(0.0, min(rad, min(w, h) / 2))
  let r = mkRect(x, y, w, h)
  when compiles(d.fillRoundRect(r, rr, col(c))):
    d.fillRoundRect(r, rr, col(c))
  elif compiles(d.fillRoundRect(x, y, w, h, rr, col(c))):
    d.fillRoundRect(x, y, w, h, rr, col(c))
  else:
    d.gFillRect(x, y, w, h, c)

proc gStrokeRound*(d: Drawing, x, y, w, h, rad: float, c: string, width = 1.0) =
  if w <= 0 or h <= 0: return
  let rr = max(0.0, min(rad, min(w, h) / 2))
  let n = max(1, int(round(width)))
  for k in 0 ..< n:
    let o = float(k)
    let r = mkRect(x + o, y + o, w - 2*o, h - 2*o)
    when compiles(d.strokeRoundRect(r, rr, col(c))):
      d.strokeRoundRect(r, rr, col(c))
    elif compiles(d.strokeRoundRect(x + o, y + o, w - 2*o, h - 2*o, rr, col(c))):
      d.strokeRoundRect(x + o, y + o, w - 2*o, h - 2*o, rr, col(c))
    elif compiles(d.strokeRect(r, col(c))):
      d.strokeRect(r, col(c))
    else:
      {.error: "gfx.gStrokeRound: adapt the call to Drawing.strokeRoundRect".}

proc gCircle*(d: Drawing, cx, cy, rad: float, c: string) =
  # filled disc (signature confirmed by the wdgui tutorial)
  d.fillCircle(cx, cy, rad, col(c))

proc gRing*(d: Drawing, cx, cy, rad: float, c: string) =
  when compiles(d.strokeCircle(cx, cy, rad, col(c))):
    d.strokeCircle(cx, cy, rad, col(c))
  else:
    discard

proc gLine*(d: Drawing, x1, y1, x2, y2: float, c: string) =
  when compiles(d.line(x1, y1, x2, y2, col(c))):
    d.line(x1, y1, x2, y2, col(c))
  elif compiles(d.line(float32(x1), float32(y1), float32(x2), float32(y2), col(c))):
    d.line(float32(x1), float32(y1), float32(x2), float32(y2), col(c))
  else:
    # fallback: dotted line of small discs
    let len = max(1.0, sqrt((x2 - x1)*(x2 - x1) + (y2 - y1)*(y2 - y1)))
    let steps = int(len / 2)
    for i in 0 .. steps:
      let t = float(i) / float(max(1, steps))
      d.fillCircle(x1 + (x2 - x1) * t, y1 + (y2 - y1) * t, 0.8, col(c))

proc gThickLine*(d: Drawing, x1, y1, x2, y2: float, c: string, width = 2.0) =
  # thick line: parallel lines offset along the normal
  let len = max(0.001, sqrt((x2 - x1)*(x2 - x1) + (y2 - y1)*(y2 - y1)))
  let nx = -(y2 - y1) / len
  let ny = (x2 - x1) / len
  let n = max(1, int(round(width * 2)))
  for k in 0 ..< n:
    let o = (float(k) - float(n - 1) / 2) * 0.5
    d.gLine(x1 + nx*o, y1 + ny*o, x2 + nx*o, y2 + ny*o, c)

proc gPolyline*(d: Drawing, pts: seq[(float, float)], c: string, width = 2.0) =
  for i in 1 ..< pts.len:
    d.gThickLine(pts[i-1][0], pts[i-1][1], pts[i][0], pts[i][1], c, width)

proc gDashed*(d: Drawing, x1, y1, x2, y2: float, c: string, dash = 6.0) =
  let len = sqrt((x2 - x1)*(x2 - x1) + (y2 - y1)*(y2 - y1))
  if len < 1: return
  var t = 0.0
  while t < len:
    let t2 = min(len, t + dash)
    d.gLine(x1 + (x2 - x1) * t / len, y1 + (y2 - y1) * t / len,
            x1 + (x2 - x1) * t2 / len, y1 + (y2 - y1) * t2 / len, c)
    t += dash * 2

proc gTriangle*(d: Drawing, x1, y1, x2, y2, x3, y3: float, c: string) =
  when compiles(d.triangle(x1, y1, x2, y2, x3, y3, col(c))):
    d.triangle(x1, y1, x2, y2, x3, y3, col(c))
  elif compiles(d.fillPolygon(@[(x1, y1), (x2, y2), (x3, y3)], col(c))):
    d.fillPolygon(@[(x1, y1), (x2, y2), (x3, y3)], col(c))
  else:
    d.gLine(x1, y1, x2, y2, c)
    d.gLine(x2, y2, x3, y3, c)
    d.gLine(x3, y3, x1, y1, c)

#
# Text
#

proc gTextW*(d: Drawing, s: string): float =
  float(d.textWidth(s))

proc gTextH*(d: Drawing): float =
  when compiles(d.textHeight()):
    float(d.textHeight())
  elif compiles(d.textHeight("Hg")):
    float(d.textHeight("Hg"))
  else:
    16.0

proc gText*(d: Drawing, x, y: float, s: string, c: string) =
  # text whose top-left corner is at (x, y)
  let h = d.gTextH() + 2
  d.textIn(mkRect(x, y, d.gTextW(s) + 4, h), s, col(c))

proc gTextCenter*(d: Drawing, cx, cy: float, s: string, c: string) =
  let w = d.gTextW(s)
  let h = d.gTextH()
  d.gText(cx - w / 2, cy - h / 2 - 1, s, c)

proc gTextRight*(d: Drawing, xr, y: float, s: string, c: string) =
  d.gText(xr - d.gTextW(s) - 2, y, s, c)

proc gEllipsize*(d: Drawing, s: string, maxW: float): string =
  # truncates with "…" to fit within maxW
  if d.gTextW(s) <= maxW: return s
  var r = s
  while r.len > 1 and d.gTextW(r & "…") > maxW:
    # remove one complete UTF-8 character
    var cut = r.len - 1
    while cut > 0 and (ord(r[cut]) and 0xC0) == 0x80: dec cut
    r = r[0 ..< cut]
  result = r & "…"

#
# Clipping - optional
#

proc gPushClip*(d: Drawing, x, y, w, h: float) =
  when compiles(d.pushClip(mkRect(x, y, w, h))):
    d.pushClip(mkRect(x, y, w, h))
  else:
    discard

proc gPopClip*(d: Drawing) =
  when compiles(d.popClip()):
    d.popClip()
  else:
    discard
