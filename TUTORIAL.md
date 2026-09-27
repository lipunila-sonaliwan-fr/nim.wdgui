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

**Linux (Debian/Ubuntu, Fedora 🤩, Arch...)**

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

- `newCell(layout, title)` - a framed group box.
- `newTab()` then `tab.addPage("Title", layout)` - returns the page container.
- `newSplitter(vertical = true, position = 0.4)` - add exactly two children; the user drags the bar.
- `newToolbar()` then `toolbar.addTool("Open", tooltip = "Open a file")`.
- `newSupercontrol(layout)` - a container without margin or decoration.
- `newPanel(layout)` - a scrollable container with macOS-style scrollbars (step 12).

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

## Step 11 - The Grid control

`Grid` is the most complete control of the library: a spreadsheet-like table for displaying **and** entering business data. It goes much further than the simple `Table` of step 5:

| Feature | How |
|---|---|
| Typed columns | text, number, date, image, button, combo, check box |
| Columns are sub-controls | each column has its own `ControlId` |
| Consultation or entry | at grid, column, line or cell level |
| Selection | single or multiple (Ctrl / Shift) |
| Footers | sum, average, min, max, count |
| Sorting, search | header click or code; `gridSeek`, `gridFind` |
| Column layout | hide, move (drag the header), resize (drag the header edge) |
| Conditional formatting | color a cell or a whole line when a condition matches |
| Breaks | group lines by a column, with per-group aggregates |
| Import / export | CSV and JSON, in memory or to a file |

As everywhere in wdgui, lines and columns are **1-based**. Every function that takes a column accepts either its index or its **name**.

### 11.1 Create a grid and its columns

```nim
import src/wdgui

var grid: ControlId

let win = newWindow("Orders", 900, 500)
let g = win.addChild(newGrid(multiSelection = true))
g.weight = 1
grid = g.id

discard gridAddColumn(grid, "id",       "#",          gcNumber, 50, decimals = 0)
discard gridAddColumn(grid, "customer", "Customer",   gcText,   180)
discard gridAddColumn(grid, "city",     "City",       gcCombo,  130,
                      choices = ["Paris", "Lyon", "Nantes"])
discard gridAddColumn(grid, "date",     "Order date", gcDate,   120)
discard gridAddColumn(grid, "amount",   "Amount",     gcNumber, 120, decimals = 2)
discard gridAddColumn(grid, "paid",     "Paid",       gcCheck,  60)
discard gridAddColumn(grid, "logo",     "Logo",       gcImage,  70)
discard gridAddColumn(grid, "action",   "Action",     gcButton, 100)
gridSetButtonCaption(grid, "action", "Details")

discard gridAddLine(grid, "1", "Alice Smith", "Paris", "20260903", "1250.00", "1", "examples/logo.bmp", "")
discard gridAddLine(grid, "2", "Bob Jones",   "Lyon",  "20260905", "320.50",  "0", "examples/logo.bmp", "")

runApplication()
```

`gridAddColumn(id, name, title, kind, width, choices, decimals)` returns the **column's own id**. The name is the stable key used in code and in CSV/JSON; the title is what the header shows.

Cells are always stored as strings, in a canonical form:

| Kind | Stored value | Displayed |
|---|---|---|
| `gcText` | the text | the text |
| `gcNumber` | `"1250.5"` | formatted with `decimals` (`-1` = as stored), right-aligned |
| `gcDate` | `"YYYYMMDD"` | `YYYY-MM-DD` |
| `gcCheck` | `"1"` / `"0"` | a check box |
| `gcCombo` | the chosen item | the item and a drop-down arrow |
| `gcImage` | an image file path (BMP, or PNG/JPG with `-d:sdlimage`) | the image, fitted |
| `gcButton` | any value | a button (caption = `gridSetButtonCaption`, or the value) |

### 11.2 Reading and writing cells and lines

```nim
echo gridCell(grid, 2, "customer")          # by column name
echo gridCell(grid, 2, 2)                   # by column index
gridSetCell(grid, 2, "amount", "410.00")    # programmatic: no evChange, as in WINDEV
echo gridLine(grid, 1)                      # @["1", "Alice Smith", ...]
echo gridCount(grid), " lines, ", gridColumnCount(grid), " columns"

gridInsertLine(grid, 1, "0", "First!", "Nantes", "20260901", "10", "1", "", "")
gridModifyLine(grid, 3, "3", "Carol Brown", "Nantes", "20260911", "780", "1", "", "")
gridDeleteLine(grid, 2)
gridDeleteAll(grid)
```

Columns can also be changed after creation: `gridDeleteColumn`, `gridSetChoices`, `gridSetDecimals`, `gridSetButtonCaption`.

### 11.3 Columns are sub-controls

Because each column has a `ControlId`, the generic properties of step 4 work on it directly:

```nim
let colAmount = gridColumn(grid, "amount")    # or gridColumn(grid, 5)
colAmount.caption = "Amount (€)"              # header title
colAmount.width = 140                         # column width
colAmount.visible = false                     # hide the column
colAmount.state = csGrayed                    # grayed: read-only and dimmed
colAmount.color = hex"#005FB8"                # header text color
echo controlType(colAmount)                   # "Grid Column"
```

Equivalent grid functions exist: `gridShowColumn(grid, "date", false)`, `gridSetColumnWidth(grid, "customer", 220)`, `gridMoveColumn(grid, "amount", 2)` (moves the column to the 2nd display position).

The user can do the same with the mouse: drag a header to move a column, drag the edge of a header to resize it, click a header to sort (click again to reverse).

### 11.4 Consultation or entry

The edit mode is resolved from the most specific level: **cell → line → column → grid**. Each level is `emInherit` (ask the next level), `emReadOnly` or `emEditable`.

```nim
gridSetEditable(grid, true)                      # grid level: entry mode
gridSetColumnEdit(grid, "id", emReadOnly)        # never edit the "#" column
gridSetLineEdit(grid, 4, emReadOnly)             # line 4 is locked
gridSetCellEdit(grid, 1, "paid", emEditable)     # this cell stays editable even in consultation
```

Image and button columns are never editable. A column whose `state` is not `csActive` is read-only.

How the user edits:

| Action | Effect |
|---|---|
| double-click, Enter or F2 | edit the current cell |
| just start typing | replaces the cell content |
| Enter | confirm |
| Escape | cancel |
| Up / Down while editing | confirm and move to the previous / next line |
| click (or Space) on a check box | toggle it |
| click the current cell of a combo column | opens the list of `choices` |

To start editing from code: `gridStartEdit(grid, 3, "customer")`.

### 11.5 Filling modes

| Mode | Meaning |
|---|---|
| `fmProgrammed` (default) | lines only come from your code |
| `fmManual` | the user can also add a line (Insert key) and delete the selected lines (Delete key) |
| `fmAutomatic` | a CSV / JSON import creates the missing columns automatically |

Set it with `newGrid(fillMode = fmManual)` or `gridSetFillMode(grid, fmManual)`. An empty grid always creates its columns on import, whatever the mode.

### 11.6 Selection

```nim
let first = gridSelect(grid)          # 1-based index of the first selected line, -1 if none
let second = gridSelect(grid, 2)      # 2nd selected line
echo gridSelectCount(grid)
gridSelectPlus(grid, 5)               # select line 5 (added to the selection in multi mode)
gridSelectMinus(grid, 5)
gridSelectAll(grid)
echo grid.value                       # current line, like any list control
echo gridCurrentColumn(grid)          # current column
```

With `multiSelection = true`, Ctrl-click toggles a line, Shift-click and Shift+arrows select a range, Ctrl+A selects everything (Cmd on macOS).

### 11.7 Events

The grid emits its events on its own id. `ev.index` is the line and `ev.column` the column (both 1-based, 0 = none):

| Event | When |
|---|---|
| `evSelection` | the current line changes |
| `evChange` | the user modified a cell (`ev.text` = new value). `ev.column = 0` means lines were inserted or deleted by the user |
| `evValidate` | a modified line is left, Enter is pressed on it, or the grid loses the focus |
| `evClick`, `evDoubleClick`, `evRightClick`... | generic mouse events, which also carry `index` and `column` (`index = 0` on the header) |

Typical handler:

```nim
proc handler(ev: var Event) {.nimcall, gcsafe.} =
  if ev.id != grid or ev.current != ev.id: return
  case ev.kind
  of evChange:
    if ev.column > 0:
      echo "Cell ", ev.index, "/", gridColumn(grid, ev.column).caption, " = ", ev.text
  of evValidate:
    echo "Save line ", ev.index, ": ", gridLine(grid, ev.index)
  of evClick:
    if ev.index > 0 and ev.column == gridColumnIndex(grid, "action"):
      echo "Details button of ", gridCell(grid, ev.index, "customer")
  of evRightClick:
    if ev.index > 0:
      openContextMenu(grid, ["Duplicate", "Delete"])
  else: discard
```

`evValidate` is the natural place to write a line back to a database.

### 11.8 Sorting and searching

```nim
gridSort(grid, "amount", ascending = false)       # also: click the header

let r = gridSeek(grid, "customer", "bob jones")   # exact, case-insensitive; -1 if not found
let r2 = gridSeek(grid, "customer", "smi", exact = false, start = 3)

let found = gridFind(grid, "Lyon")                # any visible column, selects the line
if found.row > 0:
  echo "line ", found.row, ", column ", found.column
```

Numbers and check boxes sort numerically, everything else alphabetically (case-insensitive). The sort is stable.

### 11.9 Footers and aggregates

```nim
gridSetFooter(grid, "amount", fkSum)          # fkSum, fkAverage, fkMin, fkMax, fkCount
gridSetFooter(grid, "customer", fkCount)      # counts non-empty cells
echo gridFooterValue(grid, "amount")                    # the footer's value
echo gridFooterValue(grid, "amount", fkAverage)         # any other aggregate, on demand
```

The footer line appears as soon as one visible column has a footer kind.

### 11.10 Conditional formatting

```nim
# green background on the amount cell when it exceeds 1000
gridAddFormat(grid, "amount", coGreater, "1000", background = hex"#DFF6DD")

# the whole line in red when the order is not paid
gridAddFormat(grid, "paid", coEquals, "0", text = hex"#C42B1C", wholeRow = true)

# explicit colors for one cell
gridSetCellColor(grid, 2, "city", background = hex"#FFF4CE")

gridClearFormats(grid)
```

Operators: `coEquals`, `coNotEquals`, `coLess`, `coLessOrEqual`, `coGreater`, `coGreaterOrEqual`, `coContains`, `coEmpty`, `coNotEmpty`. The comparison is numeric when both values are numbers, otherwise case-insensitive text. Rules are applied in order (later rules win); explicit cell colors win over rules.

### 11.11 Breaks (grouping)

```nim
gridSetBreak(grid, "city")     # group by city
gridSetBreak(grid, "")         # (or 0) remove the break
```

With a break, the lines are kept sorted by the break column first, then by the current sort column. Each group starts with a break line showing the value and the number of lines, plus the group aggregate of every column that has a footer kind.

### 11.12 Import and export (CSV, JSON)

```nim
# CSV - RFC 4180 (quoted fields, doubled quotes); the header line holds the column names
let csv = gridToCsv(grid)                      # sep = ',', header = true
discard gridSaveCsv(grid, "orders.csv", sep = ';')
let n = gridLoadCsv(grid, "orders.csv", sep = ';')        # lines read, -1 if unreadable
discard gridFromCsv(grid, "id,customer\n9,Zoe\n", append = true)

# JSON - an array of objects keyed by column name
let js = gridToJson(grid)                      # pretty = true
discard gridSaveJson(grid, "orders.json")
let m = gridLoadJson(grid, "orders.json")      # -1 if the file or the JSON is invalid
```

On import, columns are matched by name (or title), or by position for a CSV without header. Missing columns are created when the grid is empty or in `fmAutomatic` mode, with their kind guessed from the data (numbers, booleans → check boxes, otherwise text). Numbers and check boxes keep their JSON type on export, and a JSON import also accepts `{"rows": [...]}` or arrays of arrays.

The fastest way to show a data file is therefore:

```nim
let g = win.addChild(newGrid(fillMode = fmAutomatic))
discard gridLoadCsv(g.id, "data.csv")          # columns created from the header
```

### 11.13 The complete example

`examples/grid_demo.nim` puts everything together: typed columns, a toolbar (add, delete, sort, search, CSV / JSON export and import), switches for entry mode, grouping by city and showing the date column, footers, conditional formatting, and a button column.

```bash
nimble grid      # or: nim c -r --threads:on --mm:atomicArc -d:sdlttf examples/grid_demo.nim
```

---

## Step 12 - Scrollable panels

A `Panel` is a container that **scrolls** instead of squeezing its content. Its children, whether simple controls or whole nested layouts, keep their **natural size**. A vertical scrollbar (for the height) and a horizontal one (for the width) give access to what does not fit.

```nim
import src/wdgui

let win = newWindow("Panel", 600, 400)
let panel = win.addChild(newPanel(lkGrid, columns = 12))   # any layout of step 3
panel.weight = 1                                           # give the panel the free space
panel.framed = true                                        # optional border
for i in 1 .. 144:
  let b = panel.addChild(newButton("Button " & $i))
  b.fixedWidth = 110
runApplication()
```

`newPanel(layout = lkVertical, scrollbars = smAlways, margin = -1, spacing = -1, columns = 2)` takes the same layout parameters as `newContainer`. A panel asks for little space itself, at most 400 x 300. Give it a `weight`, a `dock` or a fixed size.

### 12.1 macOS scrollbars

On every platform, the scrollbars look and behave like macOS ones:

| Behaviour | Detail |
|---|---|
| Proportional thumb | thumb length = track length x visible size / content size |
| Drag the thumb | scrolls continuously |
| Click the track | jumps one page (90 % of the visible size) |
| Alt/Option-click the track | jumps to the clicked spot (macOS "Jump to the spot clicked") |
| Wheel, trackpad | smooth scrolling on both axes; Shift+wheel scrolls horizontally |
| Nested panels | the innermost panel scrolls first; at its limit the parent takes over |
| Focus | tabbing into a hidden child scrolls it into view |

Three display modes, like the macOS "Show scroll bars" setting:

| Mode | Appearance |
|---|---|
| `smAlways` (default) | the bars are always visible and take their own 15 px: light track, gray pill thumb that darkens on hover |
| `smAutomatic` | overlay bars that take no space: they appear while scrolling, fade out about a second later, and widen (with their track) when pointed at |
| `smHidden` | no bars; the content still scrolls with the wheel or the trackpad |

A bar is only shown when the content is larger than the panel in that direction. Colors follow the theme's light or dark mode.

```nim
let p = win.addChild(newPanel(lkVertical, scrollbars = smAutomatic))
# or later, from any thread:
panelSetScrollbars(p.id, smHidden)
```

### 12.2 Scrolling from code

```nim
panelScrollTo(panelId, 0, 0)             # top-left
panelScrollTo(panelId, 1e9, 1e9)         # bottom-right (values are clamped)
panelScrollBy(panelId, 0, 200)           # 200 px down
echo panelScrollPosition(panelId)        # (x: ..., y: ...)
echo panelContentSize(panelId)           # natural size of the content
echo panelViewportSize(panelId)          # visible part
panelEnsureVisible(panelId, someChildId) # scroll until a descendant is visible
```

The wheel step is the `lineStep` field (40 px per notch by default).

### 12.3 Nesting

Panels can contain any layout, including other panels:

```nim
let outer = win.addChild(newPanel(lkVertical))
outer.weight = 1
let inner = outer.addChild(newPanel(lkVertical))
inner.fixedWidth = 360          # a nested panel needs a size, otherwise
inner.fixedHeight = 180         # it would grow to its content
for i in 1 .. 20:
  discard inner.addChild(newEdit("Field " & $i))
```

A `Grid`, `ListBox`, `TableControl` or multiline `Edit` inside a panel keeps its own internal scrolling; the panel scrolls only when the pointer is outside them or when they reach their limit.

`examples/panel_demo.nim` shows two side-by-side panels (a 12 × 12 grid of buttons, a 1200 px wide image and a nested panel), the three modes and the API.

```bash
nimble panel     # or: nim c -r --threads:on --mm:atomicArc -d:sdlttf examples/panel_demo.nim
```

To create your own scrollable or composite containers, `Container` has three overridable hooks: `hitChildren(k, x, y)` keeps areas for the container itself, `drawOverlay(k, d, t)` draws above the children, and `onDescendantFocus(k, c)` reacts when a child gets the focus. A control can also set `win.animating = true` while drawing to request another frame, which is how the scrollbars fade out.

---

## Step 13 — Dialog boxes

wdgui provides modal dialog boxes. Each one opens in its **own dialog window**, centered on the active window, and **captures the focus until it is closed**: the other windows ignore the mouse and the keyboard, and clicking them brings the dialog back to the front.

### 13.1 How they are called

Like WINDEV's `Info`, `YesNo` or `Input`, a dialog function **blocks until the user closes the box** and then returns which button was pressed. In wdgui this fits naturally: your event handler already runs on its own thread (step 6), so it simply waits while the interface keeps running.

```nim
proc handler(ev: var Event) {.nimcall, gcsafe.} =
  if ev.kind == evClick and ev.id == btnDelete:
    if confirm(iconQuestion, "Do you want to delete this record?") == drOk:
      deleteRecord()
```

Rules of thumb:

- Call dialogs from an event handler, or from any thread other than the UI thread, once `runApplication()` is running. Called from the UI thread or before the UI starts, they print a warning and return their default value (`drCancel`, the default text, `""`).
- They also work with `dispatchMode = dmSequential`. Events of dialog windows bypass the dispatcher queue and always get their own thread.
- Dialogs can open other dialogs. For example, *Save As* asks for confirmation before replacing a file.
- `Enter` activates the default button and `Escape` the cancel button. The window's close box counts as *Cancel*.

The functions return a `DialogResult`: `drOk` or `drCancel`. Dialogs that edit a value (print, page setup, color, font, find) take it as a `var` parameter and update it only on OK.

### 13.2 Icons

The message dialogs show an icon at the top left, before the message:

| Id | Picture |
|---|---|
| `iconStop` | red "stop" octagon |
| `iconExclamation` | yellow warning triangle with "!" |
| `iconQuestion` | blue disc with "?" |
| `iconInformation` | blue disc with "i" |
| `iconNone` | no icon |
| `loadIcon(path)` | your own picture (BMP, or PNG/JPG with `-d:sdlimage`); returns its `IconId` |

```nim
let logo = loadIcon("examples/logo.bmp")      # once, e.g. at startup
alert(logo, "Welcome!")
```

The same icons are available as a control: `newIconView(iconQuestion, size = 48)`.

### 13.3 alert, confirm, prompt

```nim
alert(iconStop, "You have not entered the date.")              # OK only

if confirm(iconQuestion, "Do you want to delete this record?") == drOk:
  gridDeleteLine(grid, gridSelect(grid))

let name = prompt(iconQuestion, "File name?", "report.txt")
# the typed text on OK, "report.txt" (the proposed value) on Cancel
```

All three accept an optional `title`. Long messages wrap automatically, and `\n` forces a line break. Buttons follow the platform order: *OK* then *Cancel* on Windows, *Cancel* then *OK* on macOS and GNOME.

### 13.4 Open and Save As

```nim
let path = openFileDialog(title = "Open", folder = "",
                          filter = "Images|*.bmp;*.png\nAll files|*")
if path.len > 0: imageId.value = path

let target = saveFileDialog(defaultName = "export", filter = "CSV files|*.csv\nAll files|*")
if target.len > 0: discard gridSaveCsv(grid, target)
```

The box has a folder bar with an *Up* button and an editable path, a list of places (Home, Desktop, Documents, Downloads, current folder, computer root), a sortable table of the folder content (name, size, modified), a file-name field and a filter combo. The `filter` parameter holds one `Label|*.ext1;*.ext2` entry per line.

- A double-click opens a folder or chooses a file. Typing a folder path and pressing Enter goes there.
- *Open* checks that the file exists.
- *Save As* adds the extension of the current filter when none is typed, checks that the folder exists and asks before replacing an existing file (`confirmOverwrite = true`).
- Both return the full path, or `""` when cancelled.

### 13.5 Print and Page Setup

```nim
var print = defaultPrintSettings()
if printDialog(print) == drOk:
  echo print.printer, " ", print.copies, " copies, collate: ", print.collate
  if not print.allPages: echo "pages ", print.fromPage, "-", print.toPage

var page = defaultPageSettings()
if pageSetupDialog(page) == drOk:
  echo page.paper, " ", page.orientation, " margins ", page.marginLeft, " mm"
  echo paperSizeMm(page.paper)                 # (w: 210.0, h: 297.0) for A4
```

`printDialog` lists the installed printers (`listPrinters()`, which uses CUPS `lpstat` on macOS and Linux and PowerShell on Windows) and lets the user choose copies, all pages or a range, collate and color. `pageSetupDialog` sets the paper (A4, A3, A5, Letter, Legal), the orientation and the four margins, with a live page preview.

wdgui has no printing engine: these dialogs **collect settings** for your own printing or PDF code.

### 13.6 Color and Font

```nim
var c = hex"#005FB8"
if colorDialog(c) == drOk:
  labelId.color = c
  echo hexOf(c)                                # "#RRGGBB" or "#RRGGBBAA"

var f = FontChoice(family: "DejaVuSans", size: 14)
if fontDialog(f) == drOk:
  echo f.family, " ", f.style, " ", f.size, " bold: ", f.bold, " italic: ", f.italic
  echo f.path                                  # the font file, e.g. for SDL3_ttf
```

The color dialog has a palette of 48 basic colors, red / green / blue / opacity sliders with numeric fields, a hexadecimal code and an old/new comparison swatch. The font dialog lists the installed TrueType/OpenType fonts (`scanFonts()`) by family, style and size, with an underline option and a live preview (build with `-d:sdlttf` to see the real font).

### 13.7 Find and Replace

With a target `Edit`, the dialog works directly on its text and **stays open** until *Close*: *Find Next* selects the next match, *Replace* replaces the selected match and selects the next one, *Replace All* replaces everything. A status line reports the result.

```nim
var req = FindRequest(findText: "fox")
discard findDialog(req, target = editId)                   # Find
discard findDialog(req, target = editId, replace = true)   # Find and Replace
echo "last search: ", req.findText                         # remembered for next time
```

Without a target, the dialog closes on the first action and returns the request, so you can search anything yourself (a grid, a document, a database...):

```nim
var req = FindRequest()
if findDialog(req) == drOk:          # req.action = faFindNext (or faReplace / faReplaceAll)
  let pos = findInText(myText, req, start = 0)          # -1 if not found
```

Options: *Match case*, *Whole word* and, for Find, *Search backwards*. The search wraps around the end of the text. `applyFind(editId, req)` runs a request on an Edit from code.

`examples/dialogs_demo.nim` opens every dialog from a row of buttons:

```bash
nimble dialogs   # or: nim c -r --threads:on --mm:atomicArc -d:sdlttf examples/dialogs_demo.nim
```

---

## Step 14 - Putting it together

`examples/demo.nim` combines everything above: a menu bar, a toolbar, five tab pages with every control, live theme switching (combo + dark switch in the status bar), a long process updating a progress bar, a context menu on the list, and propagation to a cell. Read it top to bottom; it is written to be copied from.

```bash
nimble demo      # or: nim c -r --threads:on --mm:atomicArc -d:sdlttf examples/demo.nim
nimble custom    # the custom-control example
nimble grid      # the Grid control
nimble panel     # scrollable panels
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
| A grid cell cannot be edited | check the resolution order cell → line → column → grid (`gridSetEditable`, `gridSetColumnEdit`...); image and button columns and grayed columns are never editable. |
| A panel shows no scrollbar | its content fits, or the panel grew to its content: give it a `weight`, a `dock` or a fixed size. |
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
| Table | Table | `newTable` (simple) or `newGrid` (full) |
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
| TableAjouteLigne on a full table | TableAddLine | `gridAddLine` |
| TableCherche / TableSeek | | `gridSeek` |
| TableTrie / TableSort | | `gridSort` |
| ..Rupture / Break | | `gridSetBreak` |
| ArbreAjoute / TreeAdd | | `treeAdd` |
| grAjouteDonnée / grAddData | | `grAddData` |
| DonneFocus / SetFocus | | `setFocus` |
| ChampEnCours / CurrentControl | | `currentControl` |
| Ferme / Close | | `closeWindow` |
| Info | Info | `alert(icon, message)` |
| OuiNon / OKAnnuler | YesNo / OKCancel | `confirm(icon, message)` |
| Saisie (boîte) | Input | `prompt(icon, message, default)` |
| fSélecteur | fSelect | `openFileDialog`, `saveFileDialog` |
| iConfigure / iParamètre | iConfigure / iParameter | `printDialog`, `pageSetupDialog` |
| SélecteurCouleur | ColorSelect | `colorDialog` |
| SélecteurPolice | FontSelect | `fontDialog` |
