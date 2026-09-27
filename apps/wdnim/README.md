# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
# wdnim — a Nim editor built with wdgui

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

Tabs are converted to 2 spaces when a file is opened (Nim does not allow tabs).

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
| `runner.nim` | run configurations, command lines, process execution with streamed output, error-location parsing |
| `wdnim_dialogs.nim` | Project Information and Run Configuration dialog boxes |

It is a good place to see wdgui used for real:
- a large custom control (`CodeEditor`) that draws everything itself and uses `onKey`, `onText`, `onMouse`, `onWheel`, `acceptsTab`, `mouseCursor`;
- the thread-safe id API called from event handlers;
- modal dialogs (built-in ones and custom ones);
- a Splitter, a TreeView, a Grid, a Toolbar, a MenuBar;
- long-running processes that never freeze the interface.
