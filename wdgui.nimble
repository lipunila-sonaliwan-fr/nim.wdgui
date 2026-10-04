version       = "1.5.3"
author        = "wdgui"
description   = "Nim GUI library on top of SDL3 modelled on WD-style controls and API"
license       = "MIT"
srcDir        = "src"

requires "nim >= 2.0.0"

task demo, "Build and run the full demo":
  exec "nim c -r --threads:on --mm:atomicArc -d:sdlttf examples/demo.nim"

task grid, "Build and run the grid example":
  exec "nim c -r --threads:on --mm:atomicArc -d:sdlttf examples/grid_demo.nim"

task custom, "Build and run the custom-control example":
  exec "nim c -r --threads:on --mm:atomicArc -d:sdlttf examples/custom_demo.nim"

task panel, "Build and run the Panel demo":
  exec "nim c -r --threads:on --mm:atomicArc -d:sdlttf examples/panel_demo.nim"

task dialogs, "Build and run the dialog boxes demo":
  exec "nim c -r --threads:on --mm:atomicArc -d:sdlttf examples/dialogs_demo.nim"

task wdnim, "Build and run wdnim, the Nim editor example application":
  exec "nim c -r --threads:on --mm:atomicArc -d:sdlttf -d:release -o:apps/wdnim/wdnim apps/wdnim/wdnim.nim ."

task pdf, "Build and run the PDF viewer / editor demo":
  exec "nim c -r --threads:on --mm:atomicArc -d:sdlttf examples/pdf_demo.nim"

#task wdreka, "Build and run wdreka, the visual CP-SAT constraint editor (apps/wdreka)":
##exec "nim c -r --threads:on --mm:atomicArc --app:gui -d:sdlttf -d:sdlimage -d:release -o:apps/wdreka/wdreka apps/wdreka/wdreka.nim"
# exec "nim c -r --threads:on --mm:atomicArc -d:sdlttf -o:apps/wdreka/wdreka apps/wdreka/wdreka.nim"

task wdnotes, "Hierarchical, linked, and formatted Markdown notes":
# exec "nim c -r --threads:on --mm:atomicArc --app:gui -d:sdlttf -d:sdlimage -d:release -o:apps/wdnotes/wdnotes apps/wdnotes/wdnotes.nim"
  exec "nim c -r --threads:on --mm:atomicArc -d:sdlttf -d:release -o:apps/wdnotes/wdnotes apps/wdnotes/wdnotes.nim"
