# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
#
# views.nim - Solve dashboard and schedule view
#
# Two hand-drawn wdgui controls based on gApp.res:
#  * SolveDashboard: animated status, indicators, objective curve,
#    gap to the bound, time bar;
#  * ScheduleView  : Gantt chart of the tasks, load profiles of the
#    agents / places (with schedules), stock level curves.

import std/[strutils, math, times, tables, algorithm]
import ../../src/wdgui
import model, gfx, canvas

type
  SolveDashboard* = ref object of Control
    stamp: string
  ScheduleView* = ref object of Control
    stamp: string

proc statusLabel*(s: SolveStatus): string =
  case s
  of ssIdle: "Ready"
  of ssCompiling: "Compiling"
  of ssSearching: "Searching…"
  of ssOptimal: "Proven optimal"
  of ssFeasible: "Solution found"
  of ssAllFound: "All solutions"
  of ssInfeasible: "Infeasible"
  of ssStopped: "Stopped"
  of ssTimeout: "Time limit reached"
  of ssError: "Error"

proc statusColor*(s: SolveStatus): string =
  case s
  of ssIdle: "#8A93A6"
  of ssCompiling, ssSearching: "#8B6CFF"
  of ssOptimal, ssAllFound: "#27AE60"
  of ssFeasible: "#2D9CDB"
  of ssInfeasible, ssError: "#EB5757"
  of ssStopped, ssTimeout: "#F2994A"

proc fmtInt(v: int): string =
  # 1234567 -> "1,234,567"
  let s = $abs(v)
  var r = ""
  for i, ch in s:
    if i > 0 and (s.len - i) mod 3 == 0: r.add ','
    r.add ch
  result = (if v < 0: "-" else: "") & r

proc fmtTime(t: float): string =
  if t < 1.0: $int(t * 1000) & " ms"
  elif t < 60.0: formatFloat(t, ffDecimal, 2) & " s"
  else: $int(t / 60) & " min " & $(int(t) mod 60) & " s"

#
# Dashboard
#

proc newSolveDashboard*(): SolveDashboard =
  result = SolveDashboard()
  initControl(result, "")
  result.stretch = true

method typeName*(c: SolveDashboard): string = "wdreka Dashboard"
method preferredSize*(c: SolveDashboard, d: Drawing, t: Theme): tuple[w, h: float] =
  (700.0, 196.0)
method valueText*(c: SolveDashboard): string = c.stamp
method setValueText*(c: SolveDashboard, s: string) = c.stamp = s

proc card(d: Drawing, pal: Palette, x, y, w, h: float, label, value, accentCol: string) =
  d.gFillRound(x, y, w, h, 10, (if gDark: "#20242D" else: "#FFFFFF"))
  d.gStrokeRound(x, y, w, h, 10, pal.bodyBorder)
  d.gFillRound(x, y + 10, 3, h - 20, 2, accentCol)
  d.gText(x + 14, y + 8, label, pal.textFaint)
  d.gText(x + 14, y + h - d.gTextH() - 10, d.gEllipsize(value, w - 22), pal.text)

method draw*(c: SolveDashboard, d: Drawing, t: Theme) =
  let pal = palette()
  let (rx, ry, rw, rh) = ctlRect(c)
  withApp:
    let r = gApp.res
    let now = epochTime()
    let elapsed = (if gApp.solving: now - r.startTime else: r.elapsed)
    d.gFillRect(rx, ry, rw, rh, pal.bg)
    # ---- status ring ----
    let cx = rx + 86
    let cy = ry + rh / 2 - 8
    let sc = statusColor(r.status)
    d.gCircle(cx, cy, 58, alpha(sc, 0.12))
    d.gCircle(cx, cy, 46, pal.bg)
    if r.status in {ssCompiling, ssSearching}:
      # 14 rotating dots
      let phase = now * 1.6
      for k in 0 ..< 14:
        let a = float(k) / 14.0 * 2 * PI + phase
        let fade = float(k) / 14.0
        d.gCircle(cx + cos(a) * 52, cy + sin(a) * 52, 2.0 + 3.0 * fade, alpha(sc, 0.2 + 0.8 * fade))
      when compiles(c.window.animating = true):
        c.window.animating = true
    else:
      for k in 0 ..< 60:
        let a = float(k) / 60.0 * 2 * PI
        d.gCircle(cx + cos(a) * 52, cy + sin(a) * 52, 2.2, sc)
    d.gTextCenter(cx, cy - 9, statusLabel(r.status), pal.text)
    d.gTextCenter(cx, cy + 11, fmtTime(elapsed), pal.textFaint)
    # ---- indicators ----
    let gx = rx + 170
    let cw = 132.0
    let ch = 62.0
    let objTxt = (if r.hasObjective and r.solutions > 0: fmtInt(r.objective)
                  elif r.kind in ["minimize", "maximize"]: "-" else: "no objective")
    let boundTxt = (if r.hasObjective and r.solutions > 0: fmtInt(r.bestBound) else: "-")
    card(d, pal, gx, ry + 12, cw, ch, "Solutions", fmtInt(r.solutions), "#27AE60")
    card(d, pal, gx + cw + 10, ry + 12, cw, ch, "Objective", objTxt, "#F2C94C")
    card(d, pal, gx + 2 * (cw + 10), ry + 12, cw, ch, "Bound", boundTxt, "#56CCF2")
    card(d, pal, gx, ry + 22 + ch, cw, ch, "Conflicts", fmtInt(r.conflicts), "#EB5757")
    card(d, pal, gx + cw + 10, ry + 22 + ch, cw, ch, "Decisions", fmtInt(r.decisions), "#8B6CFF")
    card(d, pal, gx + 2 * (cw + 10), ry + 22 + ch, cw, ch, "Size",
         fmtInt(r.boolVars) & " bool · " & fmtInt(r.props) & " prop", "#BB6BD9")
    # ---- objective curve ----
    let px = gx + 3 * (cw + 10) + 6
    let pw = rx + rw - px - 14
    let py = ry + 12
    let ph = 2 * ch + 10
    if pw > 120:
      d.gFillRound(px, py, pw, ph, 10, (if gDark: "#20242D" else: "#FFFFFF"))
      d.gStrokeRound(px, py, pw, ph, 10, pal.bodyBorder)
      d.gText(px + 12, py + 8, "Objective progress", pal.textFaint)
      if r.curve.len > 0:
        var vmin = r.curve[0][1]
        var vmax = r.curve[0][1]
        for p in r.curve:
          vmin = min(vmin, p[1])
          vmax = max(vmax, p[1])
        if r.hasObjective:
          vmin = min(vmin, r.bestBound)
          vmax = max(vmax, r.bestBound)
        if vmax == vmin: vmax = vmin + 1
        let tmax = max(elapsed, r.curve[^1][0]) * 1.05 + 0.001
        let ax = px + 50
        let aw = pw - 64
        let ay = py + 30
        let ah = ph - 44
        proc sx(tt: float): float = ax + tt / tmax * aw
        proc sy(v: int): float = ay + ah - float(v - vmin) / float(vmax - vmin) * ah
        d.gText(px + 8, ay - 6, fmtInt(vmax), pal.textFaint)
        d.gText(px + 8, ay + ah - 12, fmtInt(vmin), pal.textFaint)
        if r.hasObjective:
          d.gDashed(ax, sy(r.bestBound), ax + aw, sy(r.bestBound), "#56CCF2")
        var pts: seq[(float, float)] = @[]
        for i, p in r.curve:
          if i > 0: pts.add((sx(p[0]), sy(r.curve[i-1][1])))
          pts.add((sx(p[0]), sy(p[1])))
        pts.add((sx(tmax / 1.05), sy(r.curve[^1][1])))
        d.gPolyline(pts, "#F2C94C", 2.0)
        for p in r.curve:
          d.gCircle(sx(p[0]), sy(p[1]), 3.5, "#F2C94C")
        # relative gap
        if r.hasObjective and r.objective != 0:
          let gap = abs(float(r.objective - r.bestBound)) / max(1.0, abs(float(r.objective))) * 100
          d.gTextRight(px + pw - 10, py + 8, "gap " & formatFloat(gap, ffDecimal, 1) & " %",
                       (if gap < 0.001: "#27AE60" else: "#F2994A"))
      else:
        d.gTextCenter(px + pw / 2, py + ph / 2,
                      (if gApp.solving: "waiting for a first solution…"
                       else: "no data"), pal.textFaint)
    # ---- time bar ----
    let by = ry + rh - 26
    let bx = rx + 170
    let bw = rw - 170 - 14
    d.gFillRound(bx, by, bw, 8, 4, pal.grid)
    var frac = 0.0
    if r.timeout > 0: frac = min(1.0, elapsed / r.timeout)
    elif gApp.solving: frac = (sin(now * 2.2) + 1) / 2
    elif r.status notin {ssIdle}: frac = 1.0
    if frac > 0:
      d.gFillRound(bx, by, max(8.0, bw * frac), 8, 4, sc)
    let msg = (if r.message.len > 0: r.message
               else: (if r.timeout > 0: "time limit: " & fmtTime(r.timeout) else: ""))
    d.gText(bx, by - d.gTextH() - 4, d.gEllipsize(msg, bw), pal.textDim)

#
# Schedule view
#

const
  labelW = 190.0
  axisH = 34.0
  taskRowH = 30.0
  agentRowH = 58.0
  stockRowH = 70.0
  sectionH = 30.0

proc newScheduleView*(): ScheduleView =
  result = ScheduleView()
  initControl(result, "")
  result.stretch = true

method typeName*(c: ScheduleView): string = "wdreka Schedule"
method valueText*(c: ScheduleView): string = c.stamp
method setValueText*(c: ScheduleView, s: string) = c.stamp = s

method preferredSize*(c: ScheduleView, d: Drawing, t: Theme): tuple[w, h: float] =
  var h = axisH + 20
  withApp:
    let r = gApp.res
    if r.tasks.len > 0: h += sectionH + float(r.tasks.len) * taskRowH
    if r.agents.len > 0: h += sectionH + float(r.agents.len) * agentRowH
    if r.stocks.len > 0: h += sectionH + float(r.stocks.len) * stockRowH
  result = (900.0, max(260.0, h))

proc niceStep(span: float, px: float): int =
  # readable tick step (≈ 60 px)
  let raw = span / max(1.0, px / 60.0)
  for s in [1, 2, 4, 5, 6, 8, 10, 12, 24, 48, 50, 100, 200, 500, 1000, 5000]:
    if float(s) >= raw: return s
  result = int(raw)

method draw*(c: ScheduleView, d: Drawing, t: Theme) =
  let pal = palette()
  let (rx, ry, rw, rh) = ctlRect(c)
  withApp:
    let r = gApp.res
    d.gFillRect(rx, ry, rw, rh, pal.bg)
    if r.tasks.len == 0 and r.agents.len == 0 and r.stocks.len == 0:
      d.gTextCenter(rx + rw / 2, ry + rh / 2 - 10, "No schedule to display", pal.text)
      d.gTextCenter(rx + rw / 2, ry + rh / 2 + 14,
                    "The tasks, agents and stocks of the solution will appear here after solving.",
                    pal.textFaint)
    else:
      # time scale
      var tmax = 1
      for tk in r.tasks: tmax = max(tmax, tk.start + tk.dur)
      for a in r.agents:
        for u in a.uses: tmax = max(tmax, u[0] + u[1])
      for s in r.stocks:
        for e in s.events: tmax = max(tmax, e[0])
      tmax = int(float(tmax) * 1.08) + 1
      let gx = rx + labelW
      let gw = rw - labelW - 20
      proc tx(v: float): float = gx + v / float(tmax) * gw
      # axis
      let step = niceStep(float(tmax), gw)
      var v = 0
      while v <= tmax:
        let x = tx(float(v))
        d.gLine(x, ry + axisH - 6, x, ry + rh, pal.grid)
        d.gTextCenter(x, ry + 14, $v, pal.textFaint)
        v += step
      d.gText(rx + 14, ry + 8, "time (" & r.unit & ")", pal.textFaint)
      var y = ry + axisH
      # ---- tasks ----
      if r.tasks.len > 0:
        d.gText(rx + 14, y + 8, "TASKS", pal.accent)
        y += sectionH
        for i, tk in r.tasks:
          if i mod 2 == 0:
            d.gFillRect(rx, y, rw, taskRowH, alpha(pal.grid, 0.5))
          d.gText(rx + 14, y + taskRowH / 2 - d.gTextH() / 2 - 1,
                  d.gEllipsize(tk.name, labelW - 24), pal.text)
          let x0 = tx(float(tk.start))
          let x1 = tx(float(tk.start + tk.dur))
          let bw = max(4.0, x1 - x0)
          d.gFillRound(x0 + 1, y + 5, bw, taskRowH - 10, 6, alpha("#000000", 0.25))
          d.gFillRound(x0, y + 4, bw, taskRowH - 10, 6, tk.color)
          d.gFillRect(x0 + 3, y + 5, max(0.0, bw - 6), (taskRowH - 10) / 2 - 1, "#FFFFFF22")
          var lbl = $tk.start & " → " & $(tk.start + tk.dur)
          if tk.agents.len > 0: lbl.add "  ·  " & tk.agents.join(", ")
          if d.gTextW(lbl) + 12 < bw:
            d.gText(x0 + 6, y + taskRowH / 2 - d.gTextH() / 2 - 2, lbl, "#FFFFFF")
          else:
            d.gText(x0 + bw + 6, y + taskRowH / 2 - d.gTextH() / 2 - 2, lbl, pal.textDim)
          y += taskRowH
      # ---- agents and places ----
      if r.agents.len > 0:
        y += 6
        d.gText(rx + 14, y + 8, "AGENTS AND PLACES - load / capacity", pal.accent)
        y += sectionH
        for a in r.agents:
          d.gFillRect(rx, y, rw, agentRowH - 4, alpha(pal.grid, 0.5))
          d.gText(rx + 14, y + 8, d.gEllipsize(a.name, labelW - 24), pal.text)
          d.gText(rx + 14, y + 28, "capacity " & $a.capacity, pal.textFaint)
          # schedules (available time windows)
          for w in a.windows:
            let x0 = tx(float(max(0, w[0])))
            let x1 = tx(float(min(tmax, w[1])))
            if x1 > x0:
              d.gFillRect(x0, y + 2, x1 - x0, agentRowH - 8, alpha("#27AE60", 0.14))
          # load profile (step chart)
          let top = y + 6
          let hh = agentRowH - 16
          let cap = max(1, a.capacity)
          var peak = 0
          for tt in 0 ..< tmax:
            var load = 0
            for u in a.uses:
              if tt >= u[0] and tt < u[0] + u[1]: load += u[2]
            peak = max(peak, load)
            if load > 0:
              let h = min(1.0, float(load) / float(cap)) * hh
              d.gFillRect(tx(float(tt)), top + hh - h, max(1.0, tx(float(tt + 1)) - tx(float(tt))),
                          h, (if load > cap: "#EB5757CC" else: alpha(a.color, 0.75)))
          d.gDashed(gx, top, gx + gw, top, alpha(pal.textFaint, 0.8))
          d.gTextRight(rx + labelW - 10, y + 28, "peak " & $peak & "/" & $cap,
                       (if peak > cap: "#EB5757" else: pal.textDim))
          y += agentRowH
      # ---- stocks ----
      if r.stocks.len > 0:
        y += 6
        d.gText(rx + 14, y + 8, "STOCKS - level over time", pal.accent)
        y += sectionH
        for s in r.stocks:
          d.gFillRect(rx, y, rw, stockRowH - 4, alpha(pal.grid, 0.5))
          d.gText(rx + 14, y + 8, d.gEllipsize(s.name, labelW - 24), pal.text)
          d.gText(rx + 14, y + 28, "min " & $s.lo & " · max " & $s.hi, pal.textFaint)
          # successive levels
          var evs = s.events
          evs.sort(proc (a, b: (int, int)): int = cmp(a[0], b[0]))
          var levels: seq[(int, int)] = @[(0, s.init)]
          var lvl = s.init
          var vmin = s.init
          var vmax = s.init
          for e in evs:
            lvl += e[1]
            levels.add((e[0], lvl))
            vmin = min(vmin, lvl)
            vmax = max(vmax, lvl)
          vmin = min(vmin, s.lo)
          if s.hi < 1_000_000: vmax = max(vmax, s.hi)
          if vmax == vmin: vmax = vmin + 1
          let top = y + 8
          let hh = stockRowH - 20
          proc ly(v: int): float = top + hh - float(v - vmin) / float(vmax - vmin) * hh
          d.gDashed(gx, ly(s.lo), gx + gw, ly(s.lo), "#EB575799")
          if s.hi < 1_000_000:
            d.gDashed(gx, ly(s.hi), gx + gw, ly(s.hi), "#EB575799")
          var pts: seq[(float, float)] = @[]
          var prev = s.init
          for i, (tt, lv) in levels:
            if i > 0: pts.add((tx(float(tt)), ly(prev)))
            pts.add((tx(float(tt)), ly(lv)))
            prev = lv
          pts.add((tx(float(tmax)), ly(prev)))
          d.gPolyline(pts, s.color, 2.2)
          for i, (tt, lv) in levels:
            if i > 0:
              d.gCircle(tx(float(tt)), ly(lv), 3.5, s.color)
          d.gTextRight(rx + labelW - 10, y + 28, "final " & $prev, pal.textDim)
          y += stockRowH
