# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
# Building custom controls by subclassing.
#   nim c -r --threads:on --mm:atomicArc examples/custom_demo.nim
import std/strutils
import ../src/wdgui

# 1. subclassing a Button

type
  RoundButton* = ref object of Button
    counter*: int                # added behaviour: counts clicks.

proc newRoundButton(caption: string): RoundButton =
  result = RoundButton()
  initControl(result, caption)
  result.focusable = true
  result.stretch = false

method typeName*(b: RoundButton): string = "RoundButton"
method preferredSize*(b: RoundButton, d: Drawing, t: Theme): tuple[w, h: float] = (96.0, 96.0)

method draw*(b: RoundButton, d: Drawing, t: Theme) =
  # Fully custom rendering: gradient disc + counter.
  let r = b.rect
  let rad = min(r.w, r.h) / 2 - 2
  let cx = r.x + r.w / 2
  let cy = r.y + r.h / 2
  let base = b.style.accent.get(t.accent)
  d.fillCircle(cx, cy + 2, rad, t.shadow)
  for i in 0 .. 10:                     # simple radial gradient.
    let k = float(i) / 10
    let col = if b.pressed: mix(base, Black, 0.25 * k)
              elif b.hovered: mix(mix(base, White, 0.25), base, k)
              else: mix(mix(base, White, 0.15), base, k)
    d.fillCircle(cx, cy, rad * (1 - k * 0.5), col)
  d.textIn(rect(r.x, cy - 22, r.w, 20), b.caption, t.textOnAccent, alCenter)
  d.textIn(rect(r.x, cy + 2, r.w, 20), $b.counter, t.textOnAccent, alCenter)
  if b.focus: d.strokeCircle(cx, cy, rad + 3, t.focus, 2)

method onMouse*(b: RoundButton, e: MouseEvent) =
  # Behaviour: only reacts inside the disc; increments the counter.
  let dx = e.x - (b.rect.x + b.rect.w / 2)
  let dy = e.y - (b.rect.y + b.rect.h / 2)
  if e.action == maRelease and e.button == mbLeft and dx*dx + dy*dy <= (b.rect.w / 2) * (b.rect.w / 2):
    inc b.counter
    emit(b, evChange, index = b.counter)

method valueText*(b: RoundButton): string = $b.counter
method setValueText*(b: RoundButton, v: string) =
  try: b.counter = parseInt(v.strip)
  except ValueError: discard

# 2. control built from scratch
type
  Led* = ref object of Control
    isOn*: bool

proc newLed(caption: string): Led =
  result = Led()
  initControl(result, caption)
  result.stretch = false

method typeName*(v: Led): string = "Led"
method preferredSize*(v: Led, d: Drawing, t: Theme): tuple[w, h: float] =
  (d.textWidth(v.caption) + 36, t.controlHeight)
method draw*(v: Led, d: Drawing, t: Theme) =
  let cy = v.rect.y + v.rect.h / 2
  let on = v.style.background.get(hex"#2EC940")
  d.fillCircle(v.rect.x + 10, cy, 8, if v.isOn: on else: t.border)
  if v.isOn: d.strokeCircle(v.rect.x + 10, cy, 10, withAlpha(on, 90), 2)
  d.textIn(rect(v.rect.x + 26, v.rect.y, v.rect.w - 26, v.rect.h), v.caption, textColor(v, t))
method valueText*(v: Led): string = (if v.isOn: "1" else: "0")
method setValueText*(v: Led, s: string) = v.isOn = s.strip == "1"

# usage

var gRound, gLed, gInfo: ControlId

proc handler(ev: var Event) {.nimcall, gcsafe.} =
  if ev.id == gRound and ev.kind == evChange and ev.current == ev.id:
    gLed.value = (if ev.index mod 2 == 1: "1" else: "0")
    gInfo.caption = "Clicks: " & $ev.index & " (value = " & gRound.value & ")"

proc main() =
  let f = newWindow("Custom controls", 420, 260, handler)
  let row = f.addChild(newSupercontrol(lkHorizontal))
  row.weight = 1
  let roundBtn = row.addChild(newRoundButton("Click"))
  roundBtn.style.accent = some(hex"#8764B8")      # custom graphical property.
  gRound = roundBtn.id
  gLed = row.addChild(newLed("Odd")).id
  gInfo = f.addChild(newLabel("Click the disc")).id
  runApplication()

main()
