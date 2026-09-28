# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
# wdnim - a Nim editor built with wdgui

wdnim is the showcase application of wdgui. It is written only in Nim, on top of the wdgui controls and dialogs: a tabbed, syntax-highlighting code editor with a project tree, a minimap, a jGRASP-like control structure diagram, git status, run configurations and a launch console.

```bash
nimble wdnim                     # from the wdgui root: opens the wdgui project itself.
nim c -r --threads:on --mm:atomicArc -d:sdlttf apps/wdnim/wdnim.nim ~/my/nim/project
nim c -r --threads:on --mm:atomicArc -d:sdlttf apps/wdnim/wdnim.nim ~/my/project/src/main.nim
```

Build with `-d:sdlttf`: the editor then uses a real monospaced TrueType font (SF Mono / Menlo on macOS, Cascadia / Consolas on Windows, JetBrains Mono / DejaVu Sans Mono on Linux). Without it the SDL bitmap font is used.

## Window layout

| Area | Content |
|---|---|
| Menu bar | File, Edit, View, Project, Run, Help |
| Toolbar | New, Open, Save, Save All · Undo, Redo, Find, Replace · Run, Build, Check, Stop, Configure.. · Console, Project, Theme |
| Left | project tree (folders first; `.git`, `nimcache`... hidden). Click a file to open it |
| Center | the editor: one tab per open file (a gold dot marks unsaved changes; × or middle-click closes) |
| Right of the code | minimap of the whole file with the visible part highlighted (click or drag to scroll) |
| Bottom | launch console (Run / Stop / Clear / Hide) and status bar: file, last action, cursor line and column, selection length, line count, encoding, git branch and number of changed files |

## Line numbers

The number column is 5 characters wide:

- **multiples of 10**: the line number divided by 1000, left-aligned, e.g. `0.010`, `0.120`, `1.230`;
- **other lines**: the line number modulo 1000, right-aligned, e.g. `    1`, `  231`.

The column reads like a ruler: every tenth line shows the full position, and the others only show their last digits.

## Control Structure Diagram

Between the line numbers and the code, a gutter draws the structure of the code in the spirit of the jGRASP CSD viewer. Every structure is a vertical bar spanning its body, indented by nesting level, ending with a small tick, and linked to the code by a thin connector. A glyph on the header line tells the kind of processing:

| Glyph | Structure | Nim statements |
|---|---|---|
| ▪ box | routine | `proc`, `func`, `method`, `iterator`, `template`, `macro`, `converter` |
| ◆ diamond (and one per branch) | decision | `if` / `elif` / `else`, `case` / `of`, `when` (hollow center) |
| ○ ring with arrow, double bar | loop | `for`, `while` |
| ▲ triangle (▼ per handler) | exception handling | `try` / `except` / `finally` |
| ⌐ bracket | block / section | `block`, `type`, `const`, `let`, `var`, `import` sections |

Colors follow the same families as the syntax highlighting. The structure is computed from the indentation and the tokens (comments and strings are ignored), and it is updated as you type. View > Structure Diagram hides it.

## Editing

| Keys (Cmd on macOS, Ctrl elsewhere) | Action |
|---|---|
| Cmd+N / Cmd+O / Cmd+Shift+O | new file / open file / open folder |
| Cmd+S / Cmd+Shift+S / Cmd+Alt+S | save / save as / save all |
| Cmd+W | close the tab |
| Cmd+Z / Cmd+Y (Cmd+Shift+Z) | undo / redo |
| Cmd+X / Cmd+C / Cmd+V / Cmd+A | cut / copy / paste / select all |
| Cmd+F / Cmd+Alt+F / F3 | find / replace / find next |
| Cmd+G | go to line |
| Cmd+/ | toggle comment |
| Cmd+D | duplicate line(s) |
| Tab / Shift+Tab | indent / outdent (the selection, or insert 2 spaces) |
| Alt+Left / Alt+Right (Ctrl on Windows / Linux) | word by word |
| Home | smart home (first non-blank character, then column 1) |
| Enter | new line keeping the indentation, +2 after `:` or `=` |
| Cmd+B | show / hide the console |
| Ctrl+Space / Cmd+I / F12 / F8 | suggestions / information / go to definition / next problem |

Tabs are converted to 2 spaces when a file is opened (Nim does not allow tabs).

## Language server: completion, suggestions and errors

wdnim embeds a Language Server Protocol client for [nimlangserver](https://github.com/nim-lang/langserver), the official Nim language server (based on nimsuggest). Install it once:

```bash
nimble install -g nimlangserver      # needs a nimsuggest that supports --v3 (Nim 1.6+)
```

wdnim finds it on the `PATH` or in `~/.nimble/bin`, starts it when the window opens, and restarts it when you open another project folder. If it is missing, the editor keeps working without it; Language > Language Server Status… explains how to install it.

| Feature | How to use it |
|---|---|
| Errors and warnings | checked on the fly while you type (after a short pause) and on save; faulty code is underlined with a red (error), orange (warning) or blue (info) wavy line, marked in the gutter and on the minimap; hover it to read the message |
| Problems list | Language > Problems opens the Problems tab next to the console: severity, file, line, column, message; double-click a row to jump there. The status bar counts errors and warnings |
| Next problem | F8 moves the cursor to the next diagnostic of the file |
| Completion | appears after `.` and after 3 characters of an identifier; Ctrl+Space asks for it at any time. The list keeps filtering as you type; ↑ / ↓ choose, Enter or Tab insert, Esc closes. Each entry shows its kind (p proc, f field, v variable, t type, m module, k keyword, c constant), its signature, and its documentation at the bottom |
| Signature help | typing `(` or `,` in a call shows the signature of the routine above the cursor |
| Information | Cmd/Ctrl+I shows the type and documentation of the symbol under the cursor |
| Go to definition | F12 or Cmd/Ctrl+click opens the file of the definition at the right line |

How it works (`lsp.nim`):
- JSON-RPC runs over the server's stdin and stdout.
- A reader thread decodes responses and diagnostics (`textDocument/publishDiagnostics`). It also answers the server's own requests, such as `workspace/configuration` (wdnim enables `autoCheckFile` and `checkOnSave`).
- A sync thread sends `textDocument/didChange` with the full text after 350 ms without typing.
- Requests (`completion`, `hover`, `signatureHelp`, `definition`) run on the event-handler threads, with a timeout, so the interface never waits for nimsuggest.

## Form designer

Design > **New Form for the Current File…** (or the **Designer** toolbar button) opens the form designer for the Nim file being edited. That file receives the event handlers and registrations. Design > **Open Form…** reopens an existing `form_<name>.nim`.

The designer window has four parts.

**Palette (left).** Layouts: Container, Cell, Panel, Splitter, Tab, Tab page, Toolbar. Controls: Label, Button, Edit, Spin, CheckBox, RadioButton, ComboBox, ListBox, Slider, RangeSlider, ProgressBar, Rating, Scrollbar, Shape, Image, BarCode. Data: Calendar, Chart, TreeView, Table, Grid.
- Drag an item onto the form, or click it to add it at the end of the selected container.
- **Custom Control…** adds a control derived from an existing one. You give its type, its base (Button, Label, Container…), its constructor expression (e.g. `newRoundButton($caption)`, where `$prop` is replaced by the property value) and the module to import. It is stored in the project's `wdnim_palette.json`, which you can also edit to add properties (`"props": [{"name": "counter", "type": "int", "default": "0"}]`). The preview uses the base control; the generated code uses your constructor.

**Canvas (center).** A live preview built with the real wdgui controls, inside a window frame.
- Click to select (Esc selects the parent). The handles resize, and the window's own handles change its size.
- Dragging a control moves it:
  - in vertical, horizontal, grid or flow layouts, a blue bar shows where it will be inserted;
  - in a border layout, the highlighted region gives its dock (top, bottom, left, right, center);
  - dropped on another container, it moves inside it;
  - in an absolute layout, it moves freely (arrow keys: 1 px, Shift: 10 px).
- **Dynamic guides** (magenta) snap while you move or resize:
  - edges and centers aligned with the other controls and with the container;
  - width or height equal to another control ("= btnOk");
  - proportions of the container ("1/4", "1/3", "1/2", "2/3", "3/4", "full").
  
  A badge shows the position or the size.

**Hierarchy (right, top).** The tree of the form; selecting a node selects the control. The toolbar gives **Up / Down** (display order, and stacking order in absolute layouts), **Out** (move out of the container), **Delete** (or the Del key) and **Form** (select the window).

**Inspector (right).**
- **Properties.** Every property is edited in place. Examples: name, caption / text, options and items (`a;b;c`), grid columns (`name:Title;…`), layout, margins, spacing, columns, fixed width / height / position, weight, stretch, dock, state, tooltip, colors (with a color picker).
- **Window properties.** When the form is selected: name, title, width, height, layout, theme, resizable, manual close.
- **Events.** Every event of the control (evClick, evChange, evSelection, evDoubleClick…) has a list:
  - **(none)** removes the association;
  - an existing handler of the edited code (a proc taking `ev: var Event`, declared before the registrations) associates it;
  - **+ new handler…** writes a stub `proc onBtnOkClick(ev: var Event)` in the edited code, associates it and puts the cursor in it.

### Generated files

The form is saved on every change in **`form_<name>.nim`** in the project folder. `<name>` is the window's *name* property; for a new form it defaults to the first number `N` for which no `form_N.nim` exists yet (1, 2, …). Renaming the form renames the file and updates the edited code.

`form_<name>.nim` contains:
- the `Form<Name>` type (one `ControlId` per named control) and `build<Name>`;
- `show<Name>()`, which creates the window;
- `on<Name>(control, event, handler)`, which registers a handler;
- the design itself, in a `#[wdform … ]#` block, used to reopen it.

The edited code receives:
- `import form_<name>` after its imports;
- a marked block just before the program start (`when isMainModule`, or a top-level call such as `main()`), holding the created handler stubs and the registrations, rewritten on every change:

```nim
# ---- wdnim form "1": begin (generated by the designer, keep these markers) ----
# call showForm1() to open the form

proc onBtnOkClick(ev: var Event) =
  ## evClick on btnOk (form "1")
  discard  # TODO

onForm1("btnOk", evClick, onBtnOkClick)
# ---- wdnim form "1": end ----
```

Open the form with `showForm1()` (for example in `main()` before `runApplication()`). The ids of its controls are in `form1`, e.g. `form1.edtName.value`.

## Running

| Command | Default key | What it runs |
|---|---|---|
| Run | F5 | `nim c -r <flags> <main file> <arguments>` |
| Build | F6 | `nim c <flags> <main file>` |
| Check | F7 | `nim check <flags> <main file>` |
| Stop | Shift+F5 | terminates the running process |
| Run Configuration... | F9 | dialog: mode (Run, Build, Check, Run (release), Nimble test, Custom command), main file, backend (c, cpp, js, objc), `--threads:on`, `--mm:atomicArc`, `-d:sdlttf`, `--hints:off`, extra flags, program arguments, custom command, clear console; live command preview; Save or Save & Run |

The main file is guessed from the `.nimble` file (`bin`), else a `.nim` named like the folder, else the first `.nim` file. "(current file)" runs the file being edited. Files are saved before each run. The output is streamed into the console. **Double-click an error line** such as `src/app.nim(12, 5) Error: ...` to open the file at that position.

## Project information

Project > Project Information... (F1) shows, in a read-only Grid:

- the folder and the `.nimble` metadata (version, author, description, license, srcDir, bin, requires);
- the number of Nim files, lines (code / comments), total size, and folders and files in the tree;
- the git branch, last commit, remote and number of changed files.

## Source layout

| File | Role |
|---|---|
| `wdnim.nim` | window, menus, toolbar, status bar, console, commands and shortcuts |
| `editor.nim` | the `CodeEditor` control: documents, tabs, line numbers, CSD gutter, highlighting, minimap, undo/redo, find/replace, thread-safe `editor...` API |
| `nimlexer.nim` | line-by-line Nim lexer (keywords, types, builtins, routine names, strings, numbers, comments, pragmas, operators) |
| `project.nim` | project tree scan, git info (reads `.git/HEAD`, and runs `git` when available), `.nimble` parsing, statistics |
| `lsp.nim`, `lsptypes.nim` | Language Server Protocol client for nimlangserver: process, JSON-RPC, document sync, diagnostics, completion, hover, signature help, definition |
| `designer.nim`, `formmodel.nim` | form designer (canvas, palette, guides, hierarchy, inspector) and the form model: palette (built-in + wdnim_palette.json), JSON persistence, code generation, wiring of the edited code |
| `runner.nim` | run configurations, command lines, process execution with streamed output, error-location parsing |
| `wdnim_dialogs.nim` | Project Information and Run Configuration dialog boxes |

It is a good place to see wdgui used for real:
- a large custom control (`CodeEditor`) that draws everything itself and uses `onKey`, `onText`, `onMouse`, `onWheel`, `acceptsTab`, `mouseCursor`;
- the thread-safe id API called from event handlers;
- modal dialogs (built-in ones and custom ones);
- a Splitter, a TreeView, a Grid, a Toolbar, a MenuBar;
- long-running processes that never freeze the interface.
