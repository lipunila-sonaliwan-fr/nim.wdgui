# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
# PDF viewer / editor demo.
#
#   nim c -r --threads:on --mm:atomicArc -d:sdlttf examples/pdf_demo.nim [file.pdf]
#
# Needs the PDFium library (https://github.com/bblanchon/pdfium-binaries): put
# libpdfium.dylib / libpdfium.so / pdfium.dll next to the program, in `./linOS`, `./macOS`, `./winOS`, or set
# `WDGUI_PATH` to the root of the `xxxOS` folders.
import std/os
import ../src/wdgui

var gPdf, gStatus: ControlId

proc handler(ev: var Event) {.nimcall, gcsafe.} =
  if ev.current != ev.id or ev.id != gPdf: return
  case ev.kind
  of evChange:                   # open, new, save, rotate, delete, move, insert, import, text, note, rectangle, highlight.
    gStatus.caption = "Last operation: " & ev.text & " - " & $pdfPageCount(gPdf) & " page(s)" &
                      (if pdfModified(gPdf): " - not saved" else: "")
  of evSelection:                # current page changed.
    gStatus.caption = "Page " & $ev.index & " / " & $pdfPageCount(gPdf)
  else: discard

proc main() =
  let win = newWindow("wdgui - PDF viewer and editor", 1240, 880, handler, layout = lkBorder)
  win.root.margin = 0
  win.root.spacing = 0
  let st = win.addChild(newLabel("Open a PDF, or click New to create one."))
  st.dock = dkBottom
  gStatus = st.id
  let pdf = win.addChild(newPdfViewer())
  pdf.dock = dkCenter
  gPdf = pdf.id
  if not pdfAvailable():
    gStatus.caption = pdfError()
  elif paramCount() > 0:
    discard pdfOpen(gPdf, paramStr(1))
  runApplication()

main()
