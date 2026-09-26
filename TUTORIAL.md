```
   _._
 o|- -|o This file is licensed under CC BY-NC-SA 4.0 international license.
  ( l )  To view a copy of this license, visit http://creativecommons.org/licenses/by-nc-sa/4.0/
    =    Author: jean-marc "jihem" quere 2026
```

[![wdgui](wdgui.png)](https://lipunila.sonaliwan.fr)
## wdgui - Getting started, step by step

This course takes you from an empty file to a multi-window application with lists, charts, a non-blocking long process and a custom control. Each step builds on the previous one and ends with a program you can compile and run.

If you have already developed software for a desktop operating system, you will feel at home: a window has one event handler, controls are addressed by an id, their properties are read and written like `..Value` or `..Caption`, and list/table/tree functions have the familiar names (`listAdd`, `tableAddLine`, `treeAdd`...).

---

## Step 0 - Install the toolchain

You need **Nim 2.0+** and **SDL 3.2+**. SDL3_ttf is optional but gives much nicer text; SDL3_image is optional and adds PNG/JPG images.

**macOS (Homebrew)**

```bash
brew install nim sdl3 sdl3_ttf sdl3_image
```

On Apple Silicon, Homebrew installs libraries in `/opt/homebrew/lib`, which the dynamic loader does not search by default. Add this to your shell profile, otherwise you will get *could not load: libSDL3...* at startup:

```bash
export DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/lib:$DYLD_FALLBACK_LIBRARY_PATH
```

**Linux (Debian/Ubuntu, Fedora, Arch...)**

Install Nim (`choosenim` or your package manager) and the SDL3 packages (`libsdl3-dev`, `libsdl3-ttf-dev`, `libsdl3-image-dev` or equivalent). If your distribution does not ship SDL3 yet, build it from source and run `sudo ldconfig`.

**Windows**

Install Nim, then download the SDL3 (and optionally SDL3_ttf / SDL3_image) release DLLs and place `SDL3.dll`, `SDL3_ttf.dll`, `SDL3_image.dll` next to your executable.

**Check the installation** by running the demo from the project root:

```bash
nim c -r --threads:on --mm:atomicArc -d:sdlttf examples/demo.nim
```

The three flags matter:

| Flag | Why |
|---|---|
| `--threads:on` | the UI and your handlers run on different threads |
| `--mm:atomicArc` | thread-safe reference counting |
| `-d:sdlttf` | TrueType fonts through SDL3_ttf (omit it to use the built-in bitmap font) |

Add `-d:sdlimage` if you want to load PNG/JPG images.

---

## Step 1 - Your first window

Create `hello.nim` next to the `src` folder:

```nim
import src/wdgui

let win = newWindow("Hello wdgui", 400, 200)
discard win.addChild(newLabel("Hello, world!", alCenter))
discard win.addChild(newButton("OK", isDefault = true))
runApplication()
```

```bash
nim c -r --threads:on --mm:atomicArc -d:sdlttf hello.nim
```

What happens:

- `newWindow(title, width, height)` creates a window. It is shown by the UI loop, so you may create windows from any thread.
- Every window has a **root container** (`win.root`) with a vertical layout by default. `win.addChild(...)` adds to it.
- `addChild` returns the control you passed in, so you can keep a reference or read its `.id`.
- `runApplication()` runs the UI loop and returns when every window is closed. On macOS it **must** be called from the main thread (the normal case for a program's top-level code).

The window already has keyboard navigation (Tab / Shift+Tab), a default button (Enter), hover and focus rendering in the native look of your OS.

---

## Step 2 - Handling events

Each window gets **one handler**. It receives every event of every control of the window:

```nim
import src/wdgui

var btnHello, lblOut: ControlId          # ids are plain values: safe to share between threads

proc handler(ev: var Event) {.nimcall, gcsafe.} =
  if ev.kind == evClick and ev.id == btnHello:
    lblOut.caption = "Hello at " & $ev.x & ", " & $ev.y

let win = newWindow("Events", 400, 200, handler)
lblOut   = win.addChild(newLabel("Click the button")).id
btnHello = win.addChild(newButton("Say hello")).id
runApplication()
```

The handler signature is always `proc (ev: var Event) {.nimcall, gcsafe.}`.

The most useful `Event` fields:

| Field | Meaning |
|---|---|
| `kind` | the event kind (see below) |
| `id` | the control where the event happened (the target) |
| `current` | the level currently being notified during propagation (step 7) |
| `window` | the window id |
| `x`, `y` | mouse position in window coordinates |
| `button` | `mbLeft`, `mbMiddle`, `mbRight` |
| `key`, `modifiers`, `isRepeat` | keyboard (`SDLK_*`, `KMOD_*`) |
| `text` | typed text, chosen menu item, tree path, card text... |
| `index` | affected row / option / tab, **1-based** |
| `dx`, `dy` | wheel deltas |

Event kinds:

| Group | Kinds |
|---|---|
| Mouse clicks | `evClick`, `evRightClick`, `evMiddleClick`, `evDoubleClick`, `evRightDoubleClick`, `evMiddleDoubleClick` |
| Mouse buttons | `evButtonDown`, `evButtonUp` |
| Hover | `evMouseEnter`, `evMouseLeave`, `evMouseMove` (opt-in: `win.mouseMoveEvents = true`) |
| Wheel | `evWheel` |
| Keyboard | `evKeyDown`, `evKeyUp`, `evTextInput` |
| Focus | `evFocusGained`, `evFocusLost` |
| Content | `evChange` (value modified by the user), `evSelection` (row/item/menu chosen) |
| Tree | `evExpand`, `evCollapse` |
| Window | `evWindowOpen`, `evWindowClose`, `evWindowResize`, `evWindowActivate`, `evWindowDeactivate` |

A click is emitted when the button is released over the same control where it was pressed, like native toolkits. Programmatic changes (`id.value = ...`) do **not** emit `evChange`.

---

## Step 3 - Layouts and containers

A window contains a root container; containers contain controls and other containers. Seven layouts are available:

| Layout | Behaviour |
|---|---|
| `lkVertical` | children stacked top to bottom |
| `lkHorizontal` | children side by side |
| `lkGrid` | `columns` equal columns, rows as tall as their tallest child |
| `lkFlow` | left to right, wrapping |
| `lkBorder` | children docked with `dock = dkTop / dkBottom / dkLeft / dkRight / dkCenter` |
| `lkStack` | children on top of each other, only `activePage` shown |
| `lkAbsolute` | each child at `fixedX`, `fixedY` |

Per-control sizing: `fixedWidth`, `fixedHeight` (0 = preferred size), `weight` (share of the free space in vertical/horizontal layouts), `stretch` (fill the cross axis; buttons default to `false`).

A classic form:

```nim
import src/wdgui

let win = newWindow("Form", 520, 360, layout = lkBorder)

# a two-column grid in the center
let form = win.addChild(newContainer(lkGrid, columns = 2))
form.dock = dkCenter
discard form.addChild(newLabel("Name"))
discard form.addChild(newEdit(placeholder = "Your name"))
discard form.addChild(newLabel("Country"))
discard form.addChild(newComboBox(["France", "Belgium", "Canada"]))
discard form.addChild(newLabel("Options"))
discard form.addChild(newCheckBox(["Newsletter", "Expert mode"]))

# buttons at the bottom, right-aligned thanks to a weighted spacer
let buttons = win.addChild(newSupercontrol(lkHorizontal))
buttons.dock = dkBottom
let spacer = buttons.addChild(newLabel(""))
spacer.weight = 1
discard buttons.addChild(newButton("Cancel", isCancel = true))
discard buttons.addChild(newButton("OK", isDefault = true))

runApplication()
```

Specialised containers:

- `newCell(layout, title)` — a framed group box.
- `newTab()` then `tab.addPage("Title", layout)` — returns the page container.
- `newSplitter(vertical = true, position = 0.4)` — add exactly two children; the user drags the bar.
- `newToolbar()` then `toolbar.addTool("Open", tooltip = "Open a file")`.
- `newSupercontrol(layout)` — a container without margin or decoration.

`margin` and `spacing` default to the theme values (set them to `0` for tight packing).

---

## Step 4 - Properties: reading and writing by id

Inside a handler you only have ids. Every property is available as a thread-safe getter/setter on `ControlId`:

| WD-style | wdgui |
|---|---|
| `EDT_Name..Value` | `edtName.value` / `edtName.value = "Bob"` |
| numeric value | `id.valueNum` / `id.valueNum = 42` |
| `..Caption` | `id.caption` / `id.caption = "..."` (window title for a window id) |
| `..Visible` | `id.visible = false` |
| `..State` | `id.state = csGrayed` (`csActive`, `csGrayed`, `csReadOnly`) |
| `..Note` / tooltip | `id.tooltip = "..."` |
| `..Name` | `id.name = "EDT_Name"`, then `controlByName(winId, "EDT_Name")` |
| `..X`, `..Width`... | `id.x`, `id.y`, `id.width`, `id.height` (setters fix the size/position) |
| `..Color`, `..BackgroundColor` | `id.color = hex"#D13438"`, `id.backgroundColor = ...`, `id.borderColor`, `id.accentColor`, `id.radius` |
| `SetFocus` | `setFocus(id)` |
| `CurrentControl` | `currentControl(winId)` |
| `Close` | `closeWindow(winId)` |

What `value` contains depends on the control, following WD-style:

| Control | `value` |
|---|---|
| Edit, Label, Bar Code | the text |
| Check Box (single) | `"1"` / `"0"` |
| Check Box (several options) | bit mask (`"5"` = options 1 and 3) |
| Radio Button, List Box, Combo Box, Table, Tab, Looper | 1-based index of the selection |
| Spin, Progress Bar, Slider, Scrollbar, Rating | the number (also `valueNum`) |
| Range Slider | `"low;high"` (also `rangeValues`, `rangeSet`) |
| Calendar | `"YYYYMMDD"` |
| TreeView | the TAB-separated path of the selected node |
| Image | the file path |
| Splitter | bar position 0..1 |

Example - mirror an edit into a label while typing:

```nim
var edt, lbl: ControlId

proc handler(ev: var Event) {.nimcall, gcsafe.} =
  if ev.kind == evChange and ev.id == edt:
    lbl.caption = "You typed: " & edt.value

let win = newWindow("Mirror", 400, 150, handler)
edt = win.addChild(newEdit(placeholder = "Type here")).id
lbl = win.addChild(newLabel("")).id
runApplication()
```

---

## Step 5 - Lists, tables and trees

All list functions take the control id and use **1-based** indexes.

```nim
import std/strutils
import src/wdgui

var lst, tbl, tree, status: ControlId

proc handler(ev: var Event) {.nimcall, gcsafe.} =
  if ev.current != ev.id: return                 # handle each event once (see step 7)
  case ev.kind
  of evSelection:
    if ev.id == lst:  status.caption = "List: " & listItem(lst, ev.index)
    if ev.id == tbl:  status.caption = "Table: " & tableCell(tbl, ev.index, 1)
    if ev.id == tree: status.caption = "Tree: " & ev.text.replace("\t", " > ")
  of evDoubleClick:
    if ev.id == tbl:
      let row = tableSelect(tbl)
      if row > 0: tableDelete(tbl, row)
  else: discard

let win = newWindow("Lists", 800, 400, handler, layout = lkBorder)
let body = win.addChild(newContainer(lkHorizontal))
body.dock = dkCenter
status = win.addChild(newLabel("Ready")).id
win.root.children[^1].dock = dkBottom

let l = body.addChild(newListBox(multiSelection = true))
l.weight = 1
lst = l.id
for fruit in ["Apple", "Pear", "Cherry"]: discard listAdd(lst, fruit)
listSelectPlus(lst, 2)

let t = body.addChild(newTable())
t.weight = 2
tbl = t.id
tableAddColumn(tbl, "Name", 140)
tableAddColumn(tbl, "Revenue", 100, alRight)
discard tableAddLine(tbl, "Smith", "120")
discard tableAddLine(tbl, "Jones", "85")
tableSort(tbl, 2, ascending = false)             # users can also click the header

let tr = body.addChild(newTreeView())
tr.weight = 1
tree = tr.id
treeAdd(tree, "Europe" & TreeSep & "France")
treeAdd(tree, "Europe" & TreeSep & "Belgium")
treeAdd(tree, "America" & TreeSep & "Canada")
treeExpand(tree, "Europe")

runApplication()
```

Function families (WD-style English names, Nim-cased):

- **List Box / Combo Box**: `listAdd`, `listInsert`, `listDelete`, `listDeleteAll`, `listSelect`, `listSelectPlus`, `listSelectMinus`, `listCount`, `listItem`, `listModify`, `listSeek`.
- **Table**: `tableAddColumn`, `tableAddLine`, `tableInsertLine`, `tableDelete`, `tableDeleteAll`, `tableSelect`, `tableSelectPlus`, `tableCount`, `tableCell`, `tableSetCell`, `tableLine`, `tableSort`.
- **TreeView**: `treeAdd`, `treeDelete`, `treeDeleteAll`, `treeExpand`, `treeCollapse`, `treeIsExpanded`, `treeSelect`, `treeSelectPlus`, `treeCount`.
- **Looper**: `looperAdd`, `looperDelete`, `looperDeleteAll`, `looperSelect`, `looperSelectPlus`, `looperCount`, `looperValue`.
- **Check Box / Radio Button**: `checkBoxValue`, `checkBoxSet`, `checkBoxAdd`, `radioAdd`.
- **Bounds**: `minBound`, `maxBound` (and their setters) for Progress Bar, Slider, Range Slider, Spin, Scrollbar.

Context menus are one call away:

```nim
if ev.kind == evRightClick and ev.id == lst and ev.current == ev.id:
  openContextMenu(lst, ["Delete", "Duplicate", "-", "Properties"])
# the choice comes back as evSelection on lst, with ev.index and ev.text
```

Menu bars: `let m = win.addChild(newMenuBar())` then `menuAdd(m.id, "File" & TreeSep & "Open")`. The choice comes back as `evSelection` with `ev.text = "File\tOpen"`.

---

## Step 6 - Long processing without freezing the UI

This is where wdgui differs from most toolkits. The UI thread never runs your code: it pushes events onto a queue, and a dispatcher thread pops them and runs **each event on its own thread**. You can therefore block, sleep or compute inside a handler, and the interface keeps repainting and responding.

```nim
import std/os
import src/wdgui

var btn, bar: ControlId

proc handler(ev: var Event) {.nimcall, gcsafe.} =
  if ev.kind == evClick and ev.id == btn:
    btn.state = csGrayed                  # prevent a second start
    for i in 0 .. 100:
      bar.valueNum = float(i)             # thread-safe, the UI redraws immediately
      sleep(30)
    btn.state = csActive

let win = newWindow("Long process", 400, 150, handler)
btn = win.addChild(newButton("Start (3 s)")).id
bar = win.addChild(newProgressBar()).id
runApplication()
```

While the loop runs you can still move the window, type in edits, open menus, even click other buttons: their events run on other threads.

Tuning:

| Setting | Effect |
|---|---|
| `dispatchMode = dmThreadPerEvent` | default: one thread per popped event, maximum parallelism |
| `dispatchMode = dmSequential` | events handled one after another, in order, on the dispatcher thread |
| `maxConcurrentThreads = 64` | upper bound on simultaneous handler threads |
| `pendingEvents()` | number of events waiting in the queue |

Because handlers can run in parallel, protect your own shared data (a `Lock`, atomics or channels). Everything you do through `ControlId` is already locked for you.

On Windows and Linux you can also keep your main thread free:

```nim
runApplicationInBackground()   # UI on its own thread
# ... your own main-thread work ...
waitApplicationEnd()
```

On macOS this falls back to the blocking `runApplication()`, since Cocoa requires the main thread.

`quitApplication()` closes every window from any thread.

---

## Step 7 - Event propagation

After the target control, the same handler is called again for each parent container, then for the window. `ev.id` stays the original target; `ev.current` tells you which level is being notified.

```nim
var cell, btnA, btnB: ControlId

proc handler(ev: var Event) {.nimcall, gcsafe.} =
  if ev.kind != evClick: return
  if ev.current == btnA:
    echo "A handles its own click and stops it here"
    ev.stopPropagation()
  elif ev.current == cell:
    echo "The cell sees a click coming from ", name(ev.id)   # only B reaches this point

let win = newWindow("Propagation", 300, 200, handler)
let c = win.addChild(newCell(lkVertical, "Group"))
cell = c.id
let a = c.addChild(newButton("A"))
a.name = "BTN_A"
btnA = a.id
let b = c.addChild(newButton("B"))
b.name = "BTN_B"
btnB = b.id
runApplication()
```

Two common patterns:

- **Handle once**: start the handler with `if ev.current != ev.id: return`.
- **Handle at a group level**: test `ev.current == groupId` to react to any child in the group (like a WD-style procedure placed on a supercontrol).

---

## Step 8 - Look & feel, themes and styles

Four ready-made themes, each light or dark:

```nim
let win = newWindow("Themes", 500, 300, theme = themeMacOS(dark = true))
```

`themeWindows11`, `themeMacOS`, `themeLinux` (GNOME/Adwaita) and `themeNative()` (picks the host OS). They differ in colors, corner radius, control height, focus indicator (underline on Windows, halo on macOS, ring on GNOME), button style and selection style.

Switch at runtime, from any handler:

```nim
winId.theme = themeLinux(dark = false)
```

Build your own theme by starting from one and changing fields:

```nim
var t = themeWindows11()
t.name = "Corporate"
t.accent = hex"#E3008C"
t.accentHover = hex"#F0209C"
t.radius = 8
t.controlHeight = 36
t.fontSize = 15
let win = newWindow("Custom theme", 500, 300, theme = t)
```

Per-control overrides through `style` (object) or the id API:

```nim
let danger = win.addChild(newButton("Delete"))
danger.style.background = some(hex"#D13438")
danger.style.text = some(White)
danger.style.radius = some(16.0)

# or later, from a handler:
dangerId.backgroundColor = hex"#A4262C"
```

`Style` fields: `background`, `text`, `border`, `accent`, `radius`, `borderWidth` (all `Option`).

---

## Step 9 - Creating your own controls

Subclass an existing control, or `Control` itself, and override its methods:

| Method | Purpose |
|---|---|
| `draw(c, d, t)` | paint the control with the `Drawing` primitives |
| `preferredSize(c, d, t)` | natural size used by layouts |
| `onMouse(c, e)` | press / release / move (`e.action` = `maPress`, `maRelease`, `maMove`) |
| `onKey(c, e): bool` | keyboard; return `true` if consumed |
| `onText(c, s)`, `acceptsText(c)` | typed text |
| `onWheel(c, dx, dy): bool` | wheel; return `true` if consumed |
| `onFocus(c, gained)` | focus change |
| `valueText` / `setValueText`, `valueNum` / `setValueNum` | what `id.value` reads and writes |
| `mouseCursor(c, x, y)` | `SDL_SYSTEM_CURSOR_*` to show |
| `typeName(c)` | returned by `controlType(id)` |

A LED indicator built from scratch:

```nim
import src/wdgui

type Led = ref object of Control
  isOn: bool

proc newLed(caption: string): Led =
  result = Led()
  initControl(result, caption)
  result.stretch = false

method typeName(c: Led): string = "Led"
method preferredSize(c: Led, d: Drawing, t: Theme): tuple[w, h: float] =
  (d.textWidth(c.caption) + 36, t.controlHeight)
method draw(c: Led, d: Drawing, t: Theme) =
  let cy = c.rect.y + c.rect.h / 2
  d.fillCircle(c.rect.x + 10, cy, 8, if c.isOn: hex"#2EC940" else: t.border)
  d.textIn(rect(c.rect.x + 26, c.rect.y, c.rect.w - 26, c.rect.h), c.caption, textColor(c, t))
method valueText(c: Led): string = (if c.isOn: "1" else: "0")
method setValueText(c: Led, s: string) = c.isOn = s == "1"
method onMouse(c: Led, e: MouseEvent) =
  if e.action == maRelease and e.button == mbLeft:
    c.isOn = not c.isOn
    emit(c, evChange, text = c.valueText)     # notify the window handler

var led: ControlId
proc handler(ev: var Event) {.nimcall, gcsafe.} =
  if ev.kind == evChange and ev.id == led: echo "LED is now ", led.value

let win = newWindow("Custom control", 300, 120, handler)
led = win.addChild(newLed("Power")).id
runApplication()
```

Useful drawing primitives: `fillRect`, `strokeRect`, `fillRoundRect`, `strokeRoundRect`, `fillCircle`, `strokeCircle`, `fillEllipse`, `fillPolygon`, `line`, `triangle`, `drawCheckMark`, `shadow`, `text`, `textIn`, `textWidth`, `textHeight`, `pushClip` / `popClip`, `drawFocus`. Reusable look & feel helpers: `drawPanel` (button background), `drawFieldFrame` (edit frame + native focus), `drawThumb` (slider thumb).

`examples/custom_control.nim` shows the other approach: subclassing `Button` to change only its look and behaviour.

---

## Step 10 - Charts, calendar and planning

```nim
let chart = win.addChild(newChart(ckColumn, "Quarterly sales"))
let c = chart.id
for i, q in ["Q1", "Q2", "Q3", "Q4"]:
  grCategoryLabel(c, i + 1, q)
  grAddData(c, 1, i + 1, [12.0, 18, 9, 22][i])
  grAddData(c, 2, i + 1, [8.0, 11, 14, 17][i])
grSeriesLabel(c, 1, "2025")
grSeriesLabel(c, 2, "2026")
grType(c, ckLine)          # ckColumn, ckLine, ckArea, ckPie
```

- **Calendar**: `newCalendar("20261231")`; `value` is `"YYYYMMDD"`; `evChange` when the user picks a day; `calendarShow(id, year, month)`.
- **Kanban**: `discard kanbanAddList(id, "To do")`, `discard kanbanAdd(id, 1, "Title\nDescription")`; users drag cards between lists, which emits `evChange` with `ev.index` = destination list.
- **TreeMap**: `treeMapAdd(id, "Paris", 2100)`; `evSelection` on click.
- **Gantt**: `discard ganttAddTask(id, "Design", start = 4, duration = 6, progress = 0.6)`; `ganttSetProgress(id, task, 0.8)`.

---

## Step 11 - Putting it together

`examples/demo.nim` combines everything above: a menu bar, a toolbar, five tab pages with every control, live theme switching (combo + dark switch in the status bar), a long process updating a progress bar, a context menu on the list, and propagation to a cell. Read it top to bottom; it is written to be copied from.

```bash
nimble demo      # or: nim c -r --threads:on --mm:atomicArc -d:sdlttf examples/demo.nim
nimble custom    # the custom-control example
```

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `could not load: libSDL3...` | SDL3 is not installed or not on the loader path. macOS/Homebrew: set `DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/lib`. Windows: put the DLLs next to the `.exe`. |
| Tiny pixelated text | compile with `-d:sdlttf` and install SDL3_ttf. |
| `'handler' is not GC-safe` | the handler must be `{.nimcall, gcsafe.}` and only touch globals of plain types (e.g. `ControlId`), or wrap access in `{.cast(gcsafe).}` with your own locking. |
| Events handled out of order | set `dispatchMode = dmSequential`. |
| Window does not appear on macOS | call `runApplication()` from the main thread (top-level code or `main()`). |
| A setter seems ignored | check the id belongs to the right kind of control: the id API silently ignores mismatched types (e.g. `listAdd` on a button). |

## WD-style → wdgui cheat sheet

| WD-style (FR) | WD-style (EN) | wdgui |
|---|---|---|
| Libellé | Static / Label | `newLabel` |
| Bouton | Button | `newButton` |
| Champ de saisie | Edit control | `newEdit` |
| Interrupteur | Check Box | `newCheckBox` |
| Sélecteur | Radio Button | `newRadioButton` |
| Liste | List Box | `newListBox` |
| Combo | Combo Box | `newComboBox` |
| Table | Table | `newTable` |
| Arbre | TreeView | `newTreeView` |
| Zone répétée | Looper | `newLooper` |
| Onglet | Tab | `newTab` / `addPage` |
| Jauge | Progress Bar | `newProgressBar` |
| Potentiomètre | Slider | `newSlider` |
| Potentiomètre de plage | Range Slider | `newRangeSlider` |
| Ascenseur | Scrollbar | `newScrollbar` |
| Spin | Spin | `newSpin` |
| Notation | Rating | `newRating` |
| Forme | Shape | `newShape` |
| Image | Image | `newImage` |
| Code-barres | Bar Code | `newBarCode` |
| Cellule | Cell | `newCell` |
| Superchamp | Supercontrol | `newSupercontrol` |
| Séparateur | Splitter | `newSplitter` |
| Barre d'outils | Toolbar | `newToolbar` |
| Menu | Menu | `newMenuBar`, `openContextMenu` |
| Graphe | Chart | `newChart` |
| Calendrier | Calendar | `newCalendar` |
| Kanban | Kanban | `newKanban` |
| TreeMap | TreeMap | `newTreeMap` |
| Diagramme de Gantt | Gantt Chart | `newGantt` |
| ListeAjoute / ListAdd | | `listAdd` |
| TableAjouteLigne / TableAddLine | | `tableAddLine` |
| ArbreAjoute / TreeAdd | | `treeAdd` |
| grAjouteDonnée / grAddData | | `grAddData` |
| DonneFocus / SetFocus | | `setFocus` |
| ChampEnCours / CurrentControl | | `currentControl` |
| Ferme / Close | | `closeWindow` |
