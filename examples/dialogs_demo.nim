# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
# Modal dialog boxes demo: alert, confirm, prompt, open / save, print, page setup,
# color, font, find and replace.
#
#   nim c -r --threads:on --mm:atomicArc -d:sdlttf examples/dialogs_demo.nim
import std/strutils
import ../src/wdgui

var
  gStatus, gText, gLogo: ControlId
  gAlert, gConfirm, gPrompt, gOpen, gSave, gPrint, gPage, gColor, gFont, gFind, gReplace: ControlId
  gCustomIcon: IconId

# settings kept between two calls (plain value objects: safe to read from handler threads).
var
  printSettings = defaultPrintSettings()
  pageSettings = defaultPageSettings()
  chosenColor = hex"#005FB8"
  chosenFont = FontChoice(size: 14)
  findRequest = FindRequest(findText: "reality")

proc say(s: string) {.gcsafe.} = gStatus.caption = s

proc handler(ev: var Event) {.nimcall, gcsafe.} =
  if ev.kind != evClick or ev.current != ev.id: return
  # Each call below BLOCKS this handler thread until the dialog is closed;
  # the interface keeps running.
  {.cast(gcsafe).}:
    if ev.id == gAlert:
      alert(iconStop, "You have not entered the date.")
      say("alert closed")
    elif ev.id == gConfirm:
      let r = confirm(iconQuestion, "Do you want to delete this record?")
      say("confirm returned " & $r)
    elif ev.id == gPrompt:
      let name = prompt(gCustomIcon, "File name?", "report.txt")
      say("prompt returned \"" & name & "\"")
    elif ev.id == gOpen:
      let path = openFileDialog(filter = "Nim sources|*.nim\nImages|*.bmp;*.png\nAll files|*")
      say(if path.len == 0: "Open cancelled" else: "Open: " & path)
    elif ev.id == gSave:
      let path = saveFileDialog(defaultName = "export", filter = "CSV files|*.csv\nAll files|*")
      say(if path.len == 0: "Save cancelled" else: "Save as: " & path)
    elif ev.id == gPrint:
      if printDialog(printSettings) == drOk:
        say("Print on " & printSettings.printer & ", " & $printSettings.copies & " copies" &
            (if printSettings.allPages: "" else: ", pages " & $printSettings.fromPage & "-" & $printSettings.toPage))
      else: say("Print cancelled")
    elif ev.id == gPage:
      if pageSetupDialog(pageSettings) == drOk:
        say("Page: " & $pageSettings.paper & " " & $pageSettings.orientation &
            ", margins " & formatNumber(pageSettings.marginLeft) & " mm")
      else: say("Page setup cancelled")
    elif ev.id == gColor:
      if colorDialog(chosenColor) == drOk:
        gText.color = chosenColor
        say("Color " & hexOf(chosenColor))
      else: say("Color cancelled")
    elif ev.id == gFont:
      if fontDialog(chosenFont) == drOk:
        say("Font " & chosenFont.family & " " & chosenFont.style & " " & formatNumber(chosenFont.size) &
            (if chosenFont.underline: " underlined" else: ""))
      else: say("Font cancelled")
    elif ev.id == gFind:
      discard findDialog(findRequest, target = gText)        # acts on the Edit, stays open
      say("Find closed, last search: \"" & findRequest.findText & "\"")
    elif ev.id == gReplace:
      discard findDialog(findRequest, target = gText, replace = true)
      say("Replace closed")

proc main() =
  let win = newWindow("wdgui - dialog boxes", 1168, 520, handler, layout = lkBorder)
  gCustomIcon = loadIcon("examples/logo.bmp")

  let bar = win.addChild(newContainer(lkFlow, 0))
  bar.dock = dkTop
  gAlert = bar.addChild(newButton("alert")).id
  gConfirm = bar.addChild(newButton("confirm")).id
  gPrompt = bar.addChild(newButton("prompt (custom icon)")).id
  gOpen = bar.addChild(newButton("Open…")).id
  gSave = bar.addChild(newButton("Save As…")).id
  gPrint = bar.addChild(newButton("Print…")).id
  gPage = bar.addChild(newButton("Page Setup…")).id
  gColor = bar.addChild(newButton("Color…")).id
  gFont = bar.addChild(newButton("Font…")).id
  gFind = bar.addChild(newButton("Find…")).id
  gReplace = bar.addChild(newButton("Replace…")).id

  let st = win.addChild(newLabel("Click a button: the dialog captures the focus until it is closed."))
  st.dock = dkBottom
  gStatus = st.id

  let text = win.addChild(newEdit("""
    The website sonaliwan.fr offers an in-depth exploration of language, thought, and our representations
    of the world through the use of Toki Pona, a minimalist language comprising 137 words. It presents a
    psycho-, socio-, and ethnolinguistic examination of cognitive biases, reasoning, general semantics,
    and the limits of our certainties, drawing notably on the concept that language structures our
    perception of reality. The site provides educational resources-such as lecture materials, learning
    guides, and workshop documents-and facilitates the discovery of Toki Pona as a tool for clarifying
    thought, avoiding cultural assumptions, and adopting a more stripped-down perspective on the world.
    ==> Find and replace work directly on this text.
    """, multiline = true))
  text.dock = dkCenter
  gText = text.id

  runApplication()

main()
