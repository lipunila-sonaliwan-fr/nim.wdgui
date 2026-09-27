# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
# Panel demo: scrollable containers with macOS-style scrollbars, nested panels,
# children that keep their natural size, and the panel API.
#
#   nim c -r --threads:on --mm:atomicArc -d:sdlttf examples/panel_demo.nim
import ../src/wdgui

var gLeft, gRight, gMode, gStatus, gBtnTop, gBtnEnd, gTarget: ControlId

proc showPosition(id: ControlId) {.gcsafe.} =
  let p = panelScrollPosition(id)
  let c = panelContentSize(id)
  let v = panelViewportSize(id)
  gStatus.caption = "scroll " & $int(p.x) & ", " & $int(p.y) &
                    "   content " & $int(c.w) & " x " & $int(c.h) &
                    "   viewport " & $int(v.w) & " x " & $int(v.h)

proc handler(ev: var Event) {.nimcall, gcsafe.} =
  if ev.current != ev.id: return
  case ev.kind
  of evSelection:
    if ev.id == gMode:
      let m = case listSelect(gMode)
              of 2: smAutomatic
              of 3: smHidden
              else: smAlways
      panelSetScrollbars(gLeft, m)
      panelSetScrollbars(gRight, m)
  of evClick:
    if ev.id == gBtnTop: panelScrollTo(gLeft, 0, 0)
    elif ev.id == gBtnEnd: panelScrollTo(gLeft, 1e9, 1e9)     # clamped to the end
    elif ev.id == gTarget: gStatus.caption = "You found the hidden button!"
    else: showPosition(gLeft)
  of evWheel, evButtonUp:
    showPosition(gLeft)
  else: discard

proc main() =
  let win = newWindow("wdgui - Panel (scrollable container)", 1000, 620, handler, layout = lkBorder)

  # toolbar
  let top = win.addChild(newContainer(lkHorizontal, 0))
  top.dock = dkTop
  discard top.addChild(newLabel("Scroll bars:"))
  gMode = top.addChild(newComboBox(["Always (default)", "Automatic (overlay, fades out)", "Hidden"], 0)).id
  gBtnTop = top.addChild(newButton("Scroll to top")).id
  gBtnEnd = top.addChild(newButton("Scroll to end")).id

  # status.
  let st = win.addChild(newLabel("Scroll with the wheel / trackpad, drag a thumb, click a track (Alt-click jumps)."))
  st.dock = dkBottom
  gStatus = st.id

  let body = win.addChild(newContainer(lkHorizontal, 0))
  body.dock = dkCenter

  # left: a panel holding a 12 x 12 grid of fixed-size buttons (larger than the window).
  let left = body.addChild(newPanel(lkGrid, columns = 12))
  left.weight = 1
  left.framed = true
  gLeft = left.id
  for i in 1 .. 144:
    let b = left.addChild(newButton("Button " & $i))
    b.fixedWidth = 110
    if i == 144:
      b.caption = "Hidden target"
      b.isDefault = true
      gTarget = b.id

  # right: a panel holding a wide image and a nested panel.
  let right = body.addChild(newPanel(lkVertical))
  right.weight = 1
  right.framed = true
  gRight = right.id
  discard right.addChild(newLabel("A wide (and wild!) image:"))
  let img = right.addChild(newImage("examples/wdgui-panel.bmp", imStretch))
  img.fixedWidth = 1200
  img.fixedHeight = 240
  discard right.addChild(newLabel("A nested panel (the wheel scrolls it first, then this one):"))
  let inner = right.addChild(newPanel(lkVertical))
  inner.fixedWidth = 360
  inner.fixedHeight = 180
  inner.framed = true
  for i in 1 .. 20:
    discard inner.addChild(newEdit("Field " & $i))
  discard right.addChild(newLabel("Tab into a hidden field: the panel scrolls to it."))
  for i in 1 .. 8:
    discard right.addChild(newCheckBox("Option " & $i))

  runApplication()

main()
