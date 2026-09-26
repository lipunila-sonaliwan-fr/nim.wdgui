```
   _._
 o|- -|o This file is licensed under CC BY-NC-SA 4.0 international license.
  ( l )  To view a copy of this license, visit http://creativecommons.org/licenses/by-nc-sa/4.0/
    =    Author: jean-marc "jihem" quere 2026
```

[![wdgui](wdgui.png)](https://lipunila.sonaliwan.fr)
## wdgui - WD-style controls for Nim, on SDL3
> Lab'Oratoire / Projet magenta - Laboratory of Cognitive and Social Psycholinguistics \
> https://lipunila.sonaliwan.fr - metalab(at)sonaliwan.fr

wdgui is a GUI library written in Nim on top of SDL3. It reproduces the usual native controls of desktop OS and the way you program them: one event handler per window that receives the control id and the event kind, properties read and written through getters and setters (`..Value`, `..Caption`, `..State`...), and WD-like functions such as `listAdd`, `tableAddLine`, `treeAdd` or `grAddData`. Indexes are 1-based and tree paths are TAB-separated.

New to the library? Start with **[TUTORIAL.md](TUTORIAL.md)**, a step-by-step getting-started course.

## Requirements

Nim 2.0 or later and SDL 3.2 or later. SDL3_ttf is optional but strongly recommended (without it text uses SDL's 8×8 bitmap font). SDL3_image is optional and adds PNG/JPG support. All libraries are loaded dynamically; no C headers are needed.

```
nim c -r --threads:on --mm:atomicArc -d:sdlttf examples/demo.nim
```
or
```
nimble demo
```
(from wdgui root folder which store `src` folder)

`--threads:on` is required. `--mm:atomicArc` makes reference counting safe across threads; the control tree is also protected by a global lock.

## Architecture in one paragraph

The UI thread reads SDL events, updates the visual state of controls and pushes `Event` objects onto a queue; it never runs user code, so the interface never freezes. A dispatcher thread pops the queue and, for each event, starts a dedicated thread that calls the window handler for the target control, then for each parent container, then for the window, unless `ev.stopPropagation()` is called. Handlers modify the interface through the thread-safe id-based API. On macOS the UI loop must run on the main thread (`runApplication()`); on Windows and Linux `runApplicationInBackground()` runs it on its own thread.

## Controls

Basic: Label (and link), Button (default, cancel, flat), Check Box (boxes or switch; value is a bit mask), Radio Button, Edit (text, integer, real, password, multiline, placeholder, clipboard), Spin, Progress Bar, Slider, Range Slider, Scrollbar, Rating, Shape, Image, Bar Code (Code 39).

Containers: Supercontrol, Cell, Tab, Splitter, Toolbar, with seven layouts (absolute, vertical, horizontal, grid, flow, border, stack).

Lists: List Box (multi-selection), Combo Box, Table (header sorting, resizable columns), TreeView, Looper, Menu bar and context menus.

Charts and planning: Chart (column, line, area, pie), Calendar (value `"YYYYMMDD"`), Kanban (drag and drop), TreeMap, Gantt Chart.

Not covered: HTML, PDF viewer, Word processor, Spreadsheet, Camera, Conference, Multimedia, OLE/ActiveX/.NET, Map, Pivot table, Scheduler/Organizer, Org chart, Hierarchical table, Image list, Ribbon, Internal window, Dashboard. They can be added by subclassing `Control` (see the tutorial, step 9).

## Look & feel

`themeWindows11`, `themeMacOS` and `themeLinux` (GNOME/Adwaita), each light or dark, plus `themeNative()`. Switch at runtime with `winId.theme = themeMacOS(dark = true)`. Every `Theme` field can be edited, and each control has a `style` (background, text, border, accent, radius, border width) that overrides the theme.

[![Buy Me a Coffee](demo.png)](https://buymeacoffee.com/sonaliwan.fr)

## Project layout

```
src/wdgui.nim                    entry module (import wdgui)
src/sdl3.nim                     SDL3 / SDL3_ttf / SDL3_image bindings
src/wdgui/colors_themes.nim      Color, Theme, Style, native themes
src/wdgui/drawing.nim            2D drawing primitives and text
src/wdgui/core.nim               Control, Container, Window, events, layouts, focus
src/wdgui/controls_basic.nim     basic controls and containers
src/wdgui/controls_lists.nim     list-type controls and popups
src/wdgui/controls_charts.nim    chart, calendar, kanban, treemap, gantt
src/wdgui/application.nim        UI loop and threaded dispatcher
src/wdgui/api.nim                id-based WD-style API
examples/demo.nim                tour of every control
examples/custom_control.nim      subclassing example
```

## Known limitations

No anti-aliasing of shapes; bitmap font without `-d:sdlttf`; containers do not scroll (list-type controls do); no IME beyond SDL text input; no accessibility support. With the default thread-per-event mode, two close events may be handled out of order; use `dispatchMode = dmSequential` when order matters.


### One more thing!
A small gesture that can - greatly - help us... \[Caffeine matters a lot for a team of neurodivergent folks: ASD, ADHD, GAD, HPI and/or THPI (members of **mensa.fr** and **triplenine.org**).\]

[![Buy Me a Coffee](buymeacoffe-eng.png)](https://buymeacoffee.com/sonaliwan.fr)
