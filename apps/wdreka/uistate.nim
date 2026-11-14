# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
#
# uistate.nim - Control identifiers and UI helpers
#
# ControlIds are plain values: they can be shared between threads.
# These functions call the wdgui API: never call them while holding gLock.

import std/[times, strutils, atomics]
import ../../src/wdgui
import model, canvas

type
  UiIds* = object
    win*: ControlId
    canvas*, dash*, sched*: ControlId
    ncp*, autoCompile*: ControlId
    tree*, search*, compDoc*: ControlId
    props*, propTitle*, propDoc*, nodeCode*: ControlId
    vars*, log*: ControlId
    tabs*: ControlId
    status*, progress*, zoomLbl*: ControlId
    btnSolve*, btnStop*: ControlId

var
  ui*: UiIds
  gCanvas*: GraphCanvas           # canvas instance (for fitView, flash)
  gStamp: Atomic[int]
  gStop*: Atomic[bool]            # solver stop request

const
  tabModel* = 1
  tabSolve* = 2
  tabVars* = 3
  tabLog* = 4

proc nextStamp(): string =
  result = $gStamp.fetchAdd(1)

proc refreshCanvas*() =
  {.cast(gcsafe).}:
    ui.canvas.value = nextStamp()

proc refreshResults*() =
  {.cast(gcsafe).}:
    ui.dash.value = nextStamp()
    ui.sched.value = nextStamp()

proc setStatus*(msg: string) =
  {.cast(gcsafe).}:
    ui.status.caption = msg

proc setProgress*(pct: float) =
  {.cast(gcsafe).}:
    ui.progress.valueNum = max(0.0, min(100.0, pct))

proc logMsg*(msg: string) =
  # appends a timestamped line to the log
  let line = now().format("HH:mm:ss") & "  " & msg
  withApp:
    addLog(line)
  {.cast(gcsafe).}:
    discard listAdd(ui.log, line)
    let n = listCount(ui.log)
    if n > 0:
      discard listSelect(ui.log, n)

proc showTab*(index: int) =
  {.cast(gcsafe).}:
    ui.tabs.value = $index

proc flash*(msg: string) =
  {.cast(gcsafe).}:
    if gCanvas != nil:
      withApp:
        gCanvas.flashMessage(msg)
  refreshCanvas()
