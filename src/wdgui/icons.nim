# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
# Vector icons (symbol buttons, trees): drawn using Drawing primitives,
# independent of the font. Based on a 16 × 16 unit grid, scaled to fit the target rectangle.
import std/[strutils, math]
import drawing, colors_themes

const IconNames* = ["open", "folder", "new", "save", "verify", "execute", "debug",
  "continue", "step-into", "step-over", "exit", "pause", "stop", "panel", "bottom-panel",
  "window", "attach", "hide", "show", "copy", "clear", "send", "duplicate",
  "rename", "delete", "lock", "code", "form", "state", "image", "markdown", "text",
  "sql", "pdf", "file", "plus", "minus", "adjust", "previous", "next", "first", "last",
  "search", "find", "print", "rotate", "thumbnails", "preview", "blueprint", "designer",
  "palette", "hierarchy", "refresh", "close", "menu", "zoom-in", "zoom-out", "full-page",
  "up", "down", "connect", "custom", "select", "variables", "stack", "console", "problems",
  "k-select", "k-rect", "k-ellipse", "k-line", "k-arrow", "k-pen", "k-text", "k-image", "k-hand", "k-nodes", "k-alignl", "k-alignc", "k-alignr", "k-alignt", "k-alignm", "k-alignb", "k-disth", "k-distv", "k-group", "k-ungroup", "k-front", "k-back", "k-bold", "k-italic", "k-h1", "k-list", "k-olist", "k-quote", "k-table", "k-link", "k-component", "k-variable", "k-slide", "k-scene", "k-graph", "k-variant", "k-branch", "k-publish", "k-web", "k-play", "k-presenter", "k-prompter", "k-layers", "k-grid", "k-magnet", "k-vectorize", "k-union", "k-subtract", "k-intersect", "k-undo", "k-redo", "k-ai", "k-library", "k-settings", "k-document", "k-preview", "k-split", "k-source", "k-snippet", "k-checklist", "k-callout", "k-timeline", "k-character", "k-comment", "k-star", "k-impact", "k-up", "k-down", "k-history", "k-eye", "k-lock", "k-search", "k-command", "k-sun", "k-moon", "k-export"]

proc isIcon*(name: string): bool = name.toLowerAscii in IconNames

proc drawIcon*(d: Drawing, name: string, r: Rect, c: Color, ep = 1.6) =
  ## Dessine l'icône `name` centrée dans `r` (carré inscrit).
  let s = min(r.w, r.h) / 16.0
  let ox = r.x + (r.w - 16 * s) / 2
  let oy = r.y + (r.h - 16 * s) / 2
  let w = max(1.0, ep * s * 0.9)
  proc X(v: float): float = ox + v * s
  proc Y(v: float): float = oy + v * s
  proc R(x, y, ww, hh: float): Rect = rect(X(x), Y(y), ww * s, hh * s)
  proc L(x1, y1, x2, y2: float) = d.line(X(x1), Y(y1), X(x2), Y(y2), c, w)
  proc P(pts: openArray[(float, float)]) =
    var q: seq[Point]
    for (a, b) in pts: q.add (x: X(a), y: Y(b))
    d.fillPolygon(q, c)
  proc arc(cx, cy, rx, ry, a0, a1: float) =
    # arc d'ellipse de a0 à a1 (degrés, 0 = droite, sens horaire à l'écran)
    let n = 14
    for i in 0 ..< n:
      let t0 = degToRad(a0 + (a1 - a0) * float(i) / float(n))
      let t1 = degToRad(a0 + (a1 - a0) * float(i + 1) / float(n))
      L(cx + rx * cos(t0), cy + ry * sin(t0), cx + rx * cos(t1), cy + ry * sin(t1))
  proc arrowR(x, y: float) = P([(x - 3.0, y - 3.0), (x + 1.0, y), (x - 3.0, y + 3.0)])
  proc arrowD(x, y: float) = P([(x - 3.0, y - 3.0), (x + 3.0, y - 3.0), (x, y + 1.0)])
  proc sheet() =
    d.strokeRoundRect(R(3, 1.5, 10, 13), 1.2 * s, c, w)
  case name.toLowerAscii
  of "open", "folder":
    d.strokeRoundRect(R(1.5, 4, 13, 9.5), 1.2 * s, c, w)
    P([(1.5, 5.0), (1.5, 2.5), (6.0, 2.5), (7.5, 4.0)])
    if name.toLowerAscii == "ouvrir": L(4, 8.5, 12, 8.5)
  of "file": sheet()
  of "new":
    sheet(); L(8, 5, 8, 11); L(5, 8, 11, 8)
  of "plus", "zoom-in":
    if name.toLowerAscii == "zoom-in":
      d.strokeCircle(X(7), Y(7), 4.8 * s, c, w); L(10.5, 10.5, 14.5, 14.5); L(7, 4.8, 7, 9.2); L(4.8, 7, 9.2, 7)
    else: L(8, 3, 8, 13); L(3, 8, 13, 8)
  of "minus", "zoom-out":
    if name.toLowerAscii == "zoom-out":
      d.strokeCircle(X(7), Y(7), 4.8 * s, c, w); L(10.5, 10.5, 14.5, 14.5); L(4.8, 7, 9.2, 7)
    else: L(3, 8, 13, 8)
  of "save":
    d.strokeRoundRect(R(2, 2, 12, 12), 1.5 * s, c, w)
    d.fillRect(R(5, 2, 6, 4), c)
    d.strokeRoundRect(R(4.5, 9, 7, 5), 0.5 * s, c, w)
  of "verify":
    L(2.5, 8.5, 6.5, 12.5); L(6.5, 12.5, 13.5, 3.5)
  of "execute", "continue":
    P([(4.0, 2.5), (13.5, 8.0), (4.0, 13.5)])
    if name.toLowerAscii == "continue": d.fillRect(R(1.5, 2.5, 1.8, 11), c)
  of "debug":
    d.strokeEllipse(R(4.5, 5, 7, 9.5), c, w)
    L(8, 6, 8, 14); L(4.5, 9, 1.5, 8); L(11.5, 9, 14.5, 8); L(4.8, 12, 2, 14); L(11.2, 12, 14, 14)
    L(5.5, 5.5, 4, 2.5); L(10.5, 5.5, 12, 2.5)
  of "step-into":
    # entrer dans la procédure : flèche qui descend vers l'instruction (point)
    L(2, 3, 9, 3); L(9, 3, 9, 8); P([(5.5, 7.5), (12.5, 7.5), (9.0, 11.5)]); d.fillCircle(X(9), Y(14), 1.7 * s, c)
  of "step-over":
    # passer par-dessus : arc au-dessus de l'instruction (point)
    arc(8, 9, 5.5, 5.5, 185, 320)
    P([(11.0, 4.0), (15.0, 6.5), (11.5, 9.5)])
    d.fillCircle(X(8), Y(13.5), 1.7 * s, c)
  of "exit":
    # sortir de la procédure : flèche qui remonte depuis l'instruction (point)
    d.fillCircle(X(3), Y(13), 1.7 * s, c); L(5.5, 13, 10, 13); L(10, 13, 10, 6); P([(6.5, 6.5), (13.5, 6.5), (10.0, 2.0)])
  of "pause":
    d.fillRoundRect(R(3.5, 2.5, 3.2, 11), 0.8 * s, c); d.fillRoundRect(R(9.3, 2.5, 3.2, 11), 0.8 * s, c)
  of "stop":
    d.fillRoundRect(R(3, 3, 10, 10), 1.4 * s, c)
  of "panel":
    d.strokeRoundRect(R(1.5, 2.5, 13, 11), 1.2 * s, c, w); d.fillRect(R(1.5, 2.5, 4.5, 11), c)
  of "bottom-panel":
    d.strokeRoundRect(R(1.5, 2.5, 13, 11), 1.2 * s, c, w); d.fillRect(R(1.5, 9.5, 13, 4), c)
  of "window":
    d.strokeRoundRect(R(4.5, 1.5, 10, 9), 1 * s, c, w); d.fillRect(R(4.5, 1.5, 10, 2.5), c)
    d.strokeRoundRect(R(1.5, 6, 8.5, 8.5), 1 * s, c, w)
  of "attach":
    d.strokeRoundRect(R(1.5, 2.5, 13, 11), 1.2 * s, c, w)
    L(14, 3, 8, 9); P([(6.5, 6.0), (6.5, 10.5), (11.0, 10.5)])
  of "hide":
    P([(9.0, 3.0), (4.0, 8.0), (9.0, 13.0)]); P([(14.0, 3.0), (9.0, 8.0), (14.0, 13.0)])
  of "show":
    P([(2.0, 3.0), (7.0, 8.0), (2.0, 13.0)]); P([(7.0, 3.0), (12.0, 8.0), (7.0, 13.0)])
  of "previous": P([(11.0, 2.5), (4.5, 8.0), (11.0, 13.5)])
  of "next": P([(5.0, 2.5), (11.5, 8.0), (5.0, 13.5)])
  of "first": P([(13.0, 2.5), (6.5, 8.0), (13.0, 13.5)]); d.fillRect(R(3, 2.5, 2, 11), c)
  of "last": P([(3.0, 2.5), (9.5, 8.0), (3.0, 13.5)]); d.fillRect(R(11, 2.5, 2, 11), c)
  of "copy", "duplicate":
    d.strokeRoundRect(R(5, 5, 9, 9.5), 1.2 * s, c, w)
    L(2, 11, 2, 2.5); L(2, 2, 10.5, 2)
    if name.toLowerAscii == "duplicate": L(9.5, 7.5, 9.5, 12); L(7.3, 9.75, 11.7, 9.75)
  of "clear":
    P([(2.0, 10.0), (8.5, 3.5), (13.5, 8.5), (8.0, 14.0)]); L(5, 14.5, 14.5, 14.5)
  of "send":
    P([(1.5, 2.0), (14.5, 8.0), (1.5, 14.0), (3.5, 8.0)])
  of "rename":
    d.strokeRoundRect(R(1.5, 4.5, 13, 7), 1 * s, c, w)
    L(5, 2, 5, 14); L(3.5, 2, 6.5, 2); L(3.5, 14, 6.5, 14)
  of "delete":
    L(2, 4, 14, 4); L(6, 4, 6.5, 1.8); L(6.5, 1.8, 9.5, 1.8); L(9.5, 1.8, 10, 4)
    d.strokeRoundRect(R(3.5, 4, 9, 10.5), 1.2 * s, c, w); L(6.5, 7, 6.5, 12); L(9.5, 7, 9.5, 12)
  of "lock":
    d.fillRoundRect(R(3, 7, 10, 8), 1.4 * s, c)
    d.strokeRoundRect(R(5, 1.8, 6, 9), 3 * s, c, w)
  of "code":
    L(5, 4, 1.5, 8); L(1.5, 8, 5, 12); L(11, 4, 14.5, 8); L(14.5, 8, 11, 12); L(9.5, 2.5, 6.5, 13.5)
  of "form", "designer":
    d.strokeRoundRect(R(1.5, 2, 13, 12), 1.2 * s, c, w); d.fillRect(R(1.5, 2, 13, 3), c)
    d.strokeRect(R(4, 7.5, 8, 2.2), c, w * 0.8); d.fillRoundRect(R(8, 11, 4, 1.8), 0.5 * s, c)
  of "state", "print":
    sheet(); L(5.5, 5, 10.5, 5); L(5.5, 8, 10.5, 8); L(5.5, 11, 8.5, 11)
  of "image", "preview":
    d.strokeRoundRect(R(1.5, 2.5, 13, 11), 1.2 * s, c, w)
    P([(3.0, 12.0), (7.0, 7.0), (10.0, 10.5), (11.5, 9.0), (13.0, 12.0)]); d.fillCircle(X(11), Y(5.5), 1.4 * s, c)
  of "markdown":
    d.strokeRoundRect(R(0.8, 3.5, 14.4, 9), 1.4 * s, c, w)
    L(3, 10.5, 3, 5.5); L(3, 5.5, 5, 8); L(5, 8, 7, 5.5); L(7, 5.5, 7, 10.5)
    L(11, 5.5, 11, 10); P([(9.0, 8.5), (13.0, 8.5), (11.0, 11.0)])
  of "text":
    sheet(); L(5.5, 5, 10.5, 5); L(5.5, 7.5, 10.5, 7.5); L(5.5, 10, 10.5, 10); L(5.5, 12.5, 9, 12.5)
  of "sql":
    d.strokeEllipse(R(2.5, 1.5, 11, 4), c, w)
    L(2.5, 3.5, 2.5, 12.5); L(13.5, 3.5, 13.5, 12.5)
    arc(8, 12.5, 5.5, 2, 0, 180); arc(8, 8, 5.5, 2, 0, 180)
  of "pdf":
    sheet(); d.fillRoundRect(R(1, 8.5, 14, 5), 1 * s, c)
  of "adjust", "full-page":
    L(1.5, 5, 1.5, 1.5); L(1.5, 1.5, 5, 1.5); L(11, 1.5, 14.5, 1.5); L(14.5, 1.5, 14.5, 5)
    L(14.5, 11, 14.5, 14.5); L(14.5, 14.5, 11, 14.5); L(5, 14.5, 1.5, 14.5); L(1.5, 14.5, 1.5, 11)
  of "search", "find":
    d.strokeCircle(X(6.5), Y(6.5), 4.6 * s, c, w); L(10, 10, 14.5, 14.5)
  of "rotate":
    arc(8, 8.5, 5.5, 5.5, -60, 230); P([(9.0, 0.8), (13.0, 3.0), (9.0, 5.5)])
  of "thumbnails":
    d.fillRoundRect(R(2, 2, 5, 5), 0.8 * s, c); d.fillRoundRect(R(9, 2, 5, 5), 0.8 * s, c)
    d.fillRoundRect(R(2, 9, 5, 5), 0.8 * s, c); d.fillRoundRect(R(9, 9, 5, 5), 0.8 * s, c)
  of "blueprint":
    d.strokeRoundRect(R(1, 2, 6, 5), 1 * s, c, w); d.strokeRoundRect(R(9, 9, 6, 5), 1 * s, c, w)
    L(7, 4.5, 10, 4.5); L(10, 4.5, 10, 9)
  of "palette":
    d.fillRoundRect(R(1.5, 1.5, 5.5, 5.5), 1 * s, c); d.strokeRoundRect(R(9, 1.5, 5.5, 5.5), 1 * s, c, w)
    d.strokeRoundRect(R(1.5, 9, 5.5, 5.5), 1 * s, c, w); d.fillRoundRect(R(9, 9, 5.5, 5.5), 1 * s, c)
  of "hierarchy":
    d.fillRect(R(1.5, 1.5, 5, 3.5), c); L(4, 5, 4, 12.5); L(4, 8.5, 8, 8.5); L(4, 12.5, 8, 12.5)
    d.fillRect(R(8.5, 7, 6, 3), c); d.fillRect(R(8.5, 11, 6, 3), c)
  of "refresh":
    arc(8, 8, 5.5, 5.5, -50, 250); P([(10.0, 0.5), (14.0, 3.0), (10.0, 5.5)])
  of "up":
    L(8, 14, 8, 4); P([(3.5, 6.5), (8.0, 1.5), (12.5, 6.5)])
  of "down":
    L(8, 2, 8, 12); P([(3.5, 9.5), (8.0, 14.5), (12.5, 9.5)])
  of "connect":
    d.strokeRoundRect(R(1, 5.5, 7, 5), 2.5 * s, c, w); d.strokeRoundRect(R(8, 5.5, 7, 5), 2.5 * s, c, w)
    L(5, 8, 11, 8)
  of "custom":
    d.strokeRoundRect(R(1.5, 1.5, 9, 9), 1.2 * s, c, w); L(12.5, 8.5, 12.5, 14.5); L(9.5, 11.5, 15.5, 11.5)
  of "select":
    P([(3.0, 1.5), (13.0, 9.0), (8.5, 9.5), (11.0, 14.5), (9.0, 15.0), (6.8, 10.5), (3.0, 13.5)])
  of "variables":
    L(2, 3, 2, 13); L(2, 3, 4, 3); L(2, 13, 4, 13); L(14, 3, 14, 13); L(14, 3, 12, 3); L(14, 13, 12, 13)
    L(5.5, 5.5, 10.5, 10.5); L(10.5, 5.5, 5.5, 10.5)
  of "stack":
    d.strokeRoundRect(R(2, 2, 12, 3.5), 1 * s, c, w); d.strokeRoundRect(R(2, 6.3, 12, 3.5), 1 * s, c, w)
    d.fillRoundRect(R(2, 10.6, 12, 3.5), 1 * s, c)
  of "console":
    d.strokeRoundRect(R(1, 2, 14, 12), 1.5 * s, c, w); L(4, 6, 7, 8.5); L(7, 8.5, 4, 11); L(8.5, 11, 12, 11)
  of "problems":
    P([(8.0, 1.5), (15.0, 14.0), (1.0, 14.0)])
  of "close":
    L(3.5, 3.5, 12.5, 12.5); L(12.5, 3.5, 3.5, 12.5)
  of "menu":
    L(2, 4, 14, 4); L(2, 8, 14, 8); L(2, 12, 14, 12)
  # ---- icônes de Kaléido (outils de conception)
  of "k-select":
    P([(4.0, 1.5), (12.5, 9.5), (8.6, 9.8), (10.8, 14.2), (9.0, 15.0), (6.9, 10.6), (4.0, 13.4)])
  of "k-rect":
    d.strokeRoundRect(R(2, 3.5, 12, 9), 1.6 * s, c, w)
  of "k-ellipse":
    d.strokeEllipse(R(1.8, 3, 12.4, 10), c, w)
  of "k-line":
    L(2.5, 13.5, 13.5, 2.5); d.fillCircle(X(2.5), Y(13.5), 1.5 * s, c); d.fillCircle(X(13.5), Y(2.5), 1.5 * s, c)
  of "k-arrow":
    L(2.5, 13.5, 12.5, 3.5); P([(14.5, 1.5), (13.6, 7.6), (8.4, 2.4)])
  of "k-pen":
    P([(8.0, 1.5), (12.5, 8.5), (9.5, 14.5), (6.5, 14.5), (3.5, 8.5)]); L(8, 3, 8, 9)
    d.fillCircle(X(8), Y(9), 1.4 * s, Color(r: 255, g: 255, b: 255, a: 230))
  of "k-text":
    L(3, 3, 13, 3); L(8, 3, 8, 14); L(3, 3, 3, 5); L(13, 3, 13, 5); L(6, 14, 10, 14)
  of "k-image":
    d.strokeRoundRect(R(1.5, 2.5, 13, 11), 1.5 * s, c, w); P([(3.0, 12.0), (7.0, 7.0), (10.0, 10.0), (11.5, 8.5), (13.5, 12.0)])
    d.fillCircle(X(11), Y(5.5), 1.3 * s, c)
  of "k-hand":
    d.strokeRoundRect(R(4, 6.5, 8.5, 8), 3 * s, c, w); L(5.5, 7, 5.5, 3); L(7.8, 6.5, 7.8, 2); L(10, 6.5, 10, 2.8); L(12.3, 8, 12.3, 4.5)
  of "k-nodes":
    arc(8, 12, 6, 8, 200, 340); d.fillRect(R(1, 9.5, 3, 3), c); d.fillRect(R(12, 9.5, 3, 3), c); d.fillRect(R(6.5, 2.5, 3, 3), c)
  of "k-alignl":
    L(2, 1.5, 2, 14.5); d.fillRect(R(3.5, 3, 9, 3.5), c); d.fillRect(R(3.5, 9.5, 6, 3.5), c)
  of "k-alignc":
    L(8, 1.5, 8, 14.5); d.fillRect(R(3, 3, 10, 3.5), c); d.fillRect(R(5, 9.5, 6, 3.5), c)
  of "k-alignr":
    L(14, 1.5, 14, 14.5); d.fillRect(R(3.5, 3, 9, 3.5), c); d.fillRect(R(6.5, 9.5, 6, 3.5), c)
  of "k-alignt":
    L(1.5, 2, 14.5, 2); d.fillRect(R(3, 3.5, 3.5, 9), c); d.fillRect(R(9.5, 3.5, 3.5, 6), c)
  of "k-alignm":
    L(1.5, 8, 14.5, 8); d.fillRect(R(3, 3, 3.5, 10), c); d.fillRect(R(9.5, 5, 3.5, 6), c)
  of "k-alignb":
    L(1.5, 14, 14.5, 14); d.fillRect(R(3, 3.5, 3.5, 9), c); d.fillRect(R(9.5, 6.5, 3.5, 6), c)
  of "k-disth":
    L(1.5, 2, 1.5, 14); L(14.5, 2, 14.5, 14); d.fillRect(R(6, 4, 4, 8), c)
  of "k-distv":
    L(2, 1.5, 14, 1.5); L(2, 14.5, 14, 14.5); d.fillRect(R(4, 6, 8, 4), c)
  of "k-group":
    d.strokeRoundRect(R(1.5, 1.5, 13, 13), 1 * s, c, w * 0.7); d.fillRoundRect(R(3.5, 3.5, 5, 5), 1 * s, c)
    d.fillRoundRect(R(7.5, 7.5, 5, 5), 1 * s, c)
  of "k-ungroup":
    d.fillRoundRect(R(2, 2, 5.5, 5.5), 1 * s, c); d.strokeRoundRect(R(8.5, 8.5, 5.5, 5.5), 1 * s, c, w)
  of "k-front":
    d.strokeRoundRect(R(1.5, 1.5, 8, 8), 1 * s, c, w); d.fillRoundRect(R(6.5, 6.5, 8, 8), 1 * s, c)
  of "k-back":
    d.fillRoundRect(R(1.5, 1.5, 8, 8), 1 * s, c); d.strokeRoundRect(R(6.5, 6.5, 8, 8), 1 * s, c, w)
  of "k-bold":
    d.strokeRoundRect(R(4, 2, 7, 5.5), 2.5 * s, c, w * 1.5); d.strokeRoundRect(R(4, 7.5, 8, 6.5), 2.8 * s, c, w * 1.5)
    L(4, 2, 4, 14)
  of "k-italic":
    L(6, 2.5, 13, 2.5); L(3, 13.5, 10, 13.5); L(10.5, 2.5, 5.5, 13.5)
  of "k-h1":
    L(2, 3, 2, 13); L(9, 3, 9, 13); L(2, 8, 9, 8); L(11.5, 6, 13.5, 4); L(13.5, 4, 13.5, 13)
  of "k-list":
    d.fillCircle(X(2.5), Y(4), 1.3 * s, c); d.fillCircle(X(2.5), Y(8), 1.3 * s, c); d.fillCircle(X(2.5), Y(12), 1.3 * s, c)
    L(5.5, 4, 14, 4); L(5.5, 8, 14, 8); L(5.5, 12, 14, 12)
  of "k-olist":
    L(2.5, 2.5, 2.5, 6); L(1.8, 10, 3.5, 10); L(3.5, 10, 1.8, 13.5); L(1.8, 13.5, 3.8, 13.5)
    L(6, 4, 14, 4); L(6, 8, 14, 8); L(6, 12, 14, 12)
  of "k-quote":
    d.fillRect(R(2, 2.5, 2, 11), c); L(6.5, 4, 14, 4); L(6.5, 8, 14, 8); L(6.5, 12, 11, 12)
  of "k-table":
    d.strokeRoundRect(R(1.5, 2.5, 13, 11), 1.2 * s, c, w); L(1.5, 6.2, 14.5, 6.2); L(1.5, 9.8, 14.5, 9.8); L(6, 2.5, 6, 13.5)
  of "k-link":
    d.strokeRoundRect(R(1.5, 6, 7.5, 4.5), 2.2 * s, c, w); d.strokeRoundRect(R(7, 5.5, 7.5, 4.5), 2.2 * s, c, w)
  of "k-component":
    P([(8.0, 1.0), (11.0, 4.0), (8.0, 7.0), (5.0, 4.0)]); P([(8.0, 9.0), (11.0, 12.0), (8.0, 15.0), (5.0, 12.0)])
    P([(4.0, 5.0), (7.0, 8.0), (4.0, 11.0), (1.0, 8.0)]); P([(12.0, 5.0), (15.0, 8.0), (12.0, 11.0), (9.0, 8.0)])
  of "k-variable":
    arc(5, 8, 3, 6, 100, 260); arc(11, 8, 3, 6, -80, 80); d.fillCircle(X(8), Y(8), 1.3 * s, c)
  of "k-slide":
    d.strokeRoundRect(R(1.5, 2.5, 13, 9), 1.2 * s, c, w); L(8, 11.5, 8, 14); L(5, 14, 11, 14); L(4, 6, 10, 6); L(4, 8.5, 8, 8.5)
  of "k-scene":
    d.strokeRoundRect(R(1.5, 3, 13, 10), 1.2 * s, c, w); L(4.5, 3, 4.5, 13); L(11.5, 3, 11.5, 13)
    d.fillRect(R(2.2, 5, 1.6, 1.5), c); d.fillRect(R(2.2, 9.5, 1.6, 1.5), c); d.fillRect(R(12.2, 5, 1.6, 1.5), c); d.fillRect(R(12.2, 9.5, 1.6, 1.5), c)
  of "k-graph":
    L(4, 4, 12, 4); L(4, 4, 8, 12); L(12, 4, 8, 12); d.fillCircle(X(4), Y(4), 2.2 * s, c); d.fillCircle(X(12), Y(4), 2.2 * s, c)
    d.fillCircle(X(8), Y(12), 2.2 * s, c)
  of "k-variant":
    d.strokeRoundRect(R(1.5, 4, 8, 10), 1.2 * s, c, w); d.fillRoundRect(R(6.5, 2, 8, 10), 1.2 * s, c)
  of "k-branch":
    L(4.5, 3, 4.5, 13); arc(9, 7.5, 4.5, 4.5, 90, 180); L(9, 12, 9, 12); d.fillCircle(X(4.5), Y(3), 1.8 * s, c)
    d.fillCircle(X(4.5), Y(13), 1.8 * s, c); d.fillCircle(X(11.5), Y(5), 1.8 * s, c); L(11.5, 5, 11.5, 7); arc(8, 7, 3.5, 4.5, 0, 90)
  of "k-publish":
    L(8, 11, 8, 2); P([(4.0, 6.0), (8.0, 1.5), (12.0, 6.0)]); L(2.5, 10, 2.5, 14); L(2.5, 14, 13.5, 14); L(13.5, 14, 13.5, 10)
  of "k-web":
    d.strokeCircle(X(8), Y(8), 6.3 * s, c, w); d.strokeEllipse(R(5, 1.7, 6, 12.6), c, w); L(1.7, 8, 14.3, 8)
  of "k-play":
    P([(4.5, 2.0), (13.5, 8.0), (4.5, 14.0)])
  of "k-presenter":
    d.strokeRoundRect(R(1.5, 1.5, 13, 8.5), 1 * s, c, w); L(8, 10, 8, 12); d.fillCircle(X(8), Y(13.3), 1.8 * s, c)
    P([(6.0, 3.8), (10.5, 5.8), (6.0, 7.8)])
  of "k-prompter":
    L(2.5, 3, 13.5, 3); L(2.5, 6, 13.5, 6); L(2.5, 9, 10, 9); L(2.5, 12, 12, 12); P([(14.5, 9.0), (12.0, 11.0), (14.5, 13.0)])
  of "k-layers":
    P([(8.0, 2.0), (14.5, 5.5), (8.0, 9.0), (1.5, 5.5)]); L(1.5, 8.5, 8, 12); L(8, 12, 14.5, 8.5); L(1.5, 11.5, 8, 15); L(8, 15, 14.5, 11.5)
  of "k-grid":
    d.strokeRoundRect(R(1.5, 1.5, 13, 13), 1 * s, c, w * 0.8); L(6, 1.5, 6, 14.5); L(10, 1.5, 10, 14.5); L(1.5, 6, 14.5, 6); L(1.5, 10, 14.5, 10)
  of "k-magnet":
    arc(8, 8, 5, 5, 0, 180); L(3, 8, 3, 3); L(13, 8, 13, 3); d.fillRect(R(1.8, 2, 2.4, 2.5), c); d.fillRect(R(11.8, 2, 2.4, 2.5), c)
  of "k-vectorize":
    d.strokeRoundRect(R(1.5, 1.5, 7, 7), 0.5 * s, c, w * 0.8)
    for i in 0 .. 2:
      for j in 0 .. 2:
        if (i + j) mod 2 == 0: d.fillRect(R(1.5 + i.float * 2.33, 1.5 + j.float * 2.33, 2.33, 2.33), c)
    arc(11, 11, 3.5, 3.5, 180, 450); d.fillCircle(X(7.5), Y(11), 1.2 * s, c)
  of "k-union":
    d.fillEllipse(R(1.5, 3, 8, 8), c); d.fillEllipse(R(6.5, 5, 8, 8), c)
  of "k-subtract":
    d.fillEllipse(R(1.5, 3, 8, 8), c); d.strokeEllipse(R(6.5, 5, 8, 8), c, w)
  of "k-intersect":
    d.strokeEllipse(R(1.5, 3, 8, 8), c, w); d.strokeEllipse(R(6.5, 5, 8, 8), c, w); d.fillEllipse(R(6.8, 5.6, 2.4, 4.8), c)
  of "k-undo":
    arc(8.5, 9, 5, 4.5, 200, 400); P([(1.0, 7.5), (5.5, 4.0), (5.5, 10.0)])
  of "k-redo":
    arc(7.5, 9, 5, 4.5, 140, 340); P([(15.0, 7.5), (10.5, 4.0), (10.5, 10.0)])
  of "k-ai":
    P([(7.0, 1.0), (8.6, 6.4), (14.0, 8.0), (8.6, 9.6), (7.0, 15.0), (5.4, 9.6), (0.5, 8.0), (5.4, 6.4)])
    P([(13.0, 1.0), (13.7, 2.8), (15.5, 3.5), (13.7, 4.2), (13.0, 6.0), (12.3, 4.2), (10.5, 3.5), (12.3, 2.8)])
  of "k-library":
    d.strokeRoundRect(R(1.5, 2, 3.5, 12), 0.6 * s, c, w); d.strokeRoundRect(R(6, 2, 3.5, 12), 0.6 * s, c, w)
    L(11, 3, 14.5, 13.5); L(11, 3, 12.8, 2.4); L(14.5, 13.5, 12.7, 14.1)
  of "k-settings":
    d.strokeCircle(X(8), Y(8), 2.6 * s, c, w)
    for k in 0 .. 7:
      let a = k.float * PI / 4
      L(8 + cos(a) * 4.6, 8 + sin(a) * 4.6, 8 + cos(a) * 6.8, 8 + sin(a) * 6.8)
    d.strokeCircle(X(8), Y(8), 4.6 * s, c, w)
  of "k-document":
    sheet(); L(5.5, 5, 10.5, 5); L(5.5, 7.5, 10.5, 7.5); L(5.5, 10, 9, 10)
  of "k-preview":
    d.strokeEllipse(R(1.2, 4, 13.6, 8), c, w); d.fillCircle(X(8), Y(8), 2.4 * s, c)
  of "k-eye":
    d.strokeEllipse(R(1.2, 4, 13.6, 8), c, w); d.fillCircle(X(8), Y(8), 2.4 * s, c)
  of "k-split":
    d.strokeRoundRect(R(1.5, 2.5, 13, 11), 1.2 * s, c, w); L(8, 2.5, 8, 13.5); L(3.5, 6, 6, 6); L(3.5, 8.5, 6, 8.5)
    d.fillRect(R(9.5, 5, 3.5, 5), c)
  of "k-source":
    L(5, 4, 1.5, 8); L(1.5, 8, 5, 12); L(11, 4, 14.5, 8); L(14.5, 8, 11, 12); L(9.5, 2.5, 6.5, 13.5)
  of "k-snippet":
    d.strokeRoundRect(R(1.5, 1.5, 13, 13), 2 * s, c, w); L(4.5, 6, 7, 8); L(7, 8, 4.5, 10); L(8.5, 10.5, 11.5, 10.5)
  of "k-checklist":
    d.strokeRoundRect(R(1.5, 2.5, 4, 4), 0.8 * s, c, w); L(2.3, 11.5, 3.5, 12.8); L(3.5, 12.8, 5.8, 9.5)
    L(8, 4.5, 14.5, 4.5); L(8, 11.5, 14.5, 11.5)
  of "k-callout":
    d.strokeRoundRect(R(1.5, 2, 13, 9.5), 2 * s, c, w); P([(4.0, 11.0), (4.0, 15.0), (8.0, 11.0)]); d.fillRect(R(7.3, 4, 1.4, 3.6), c)
    d.fillCircle(X(8), Y(9.2), 0.8 * s, c)
  of "k-timeline":
    L(1.5, 8, 14.5, 8); d.fillRect(R(2, 3, 4, 3), c); d.fillRect(R(7, 10, 5, 3), c); L(4, 6, 4, 8); L(9.5, 8, 9.5, 10)
  of "k-character":
    d.strokeCircle(X(8), Y(5), 3 * s, c, w); arc(8, 15, 5.5, 5.5, 180, 360)
  of "k-comment":
    d.strokeRoundRect(R(1.5, 2, 13, 9.5), 3 * s, c, w); P([(5.0, 11.0), (4.0, 14.5), (8.5, 11.0)])
  of "k-star":
    var pts: seq[(float, float)]
    for k in 0 .. 9:
      let a = -PI / 2 + k.float * PI / 5
      let rr = if k mod 2 == 0: 7.0 else: 3.0
      pts.add (8 + cos(a) * rr, 8.5 + sin(a) * rr)
    P(pts)
  of "k-impact":
    d.strokeCircle(X(8), Y(8), 6.3 * s, c, w * 0.8); d.strokeCircle(X(8), Y(8), 3.6 * s, c, w * 0.8); d.fillCircle(X(8), Y(8), 1.4 * s, c)
  of "k-up":
    P([(3.0, 10.5), (8.0, 4.5), (13.0, 10.5)])
  of "k-down":
    P([(3.0, 5.5), (8.0, 11.5), (13.0, 5.5)])
  of "k-history":
    d.strokeCircle(X(8.5), Y(8), 6 * s, c, w); L(8.5, 4.5, 8.5, 8); L(8.5, 8, 11, 10); P([(0.5, 6.5), (3.5, 9.5), (5.0, 5.5)])
  of "k-lock":
    d.fillRoundRect(R(3, 7, 10, 7.5), 1.5 * s, c); arc(8, 7, 3.2, 4.2, 180, 360)
  of "k-search":
    d.strokeCircle(X(7), Y(7), 4.8 * s, c, w); L(10.5, 10.5, 14.5, 14.5)
  of "k-command":
    d.strokeRoundRect(R(1.5, 2.5, 13, 11), 2 * s, c, w); L(4.5, 6, 7, 8); L(7, 8, 4.5, 10); L(8.5, 10.5, 11.5, 10.5)
  of "k-sun":
    d.fillCircle(X(8), Y(8), 3.2 * s, c)
    for k in 0 .. 7:
      let a = k.float * PI / 4
      L(8 + cos(a) * 5, 8 + sin(a) * 5, 8 + cos(a) * 7, 8 + sin(a) * 7)
  of "k-moon":
    P([(9.0, 1.5), (12.5, 3.0), (14.5, 7.0), (13.5, 11.5), (10.0, 14.3), (5.5, 14.3), (2.0, 11.5), (5.5, 12.0), (9.0, 10.0), (10.0, 6.0)])
  of "k-export":
    d.strokeRoundRect(R(1.5, 5, 9, 9.5), 1.2 * s, c, w); L(7, 9, 14, 2); P([(14.5, 1.5), (14.5, 6.5), (9.5, 1.5)])
  else:
    d.strokeRoundRect(R(2, 2, 12, 12), 2 * s, c, w)
