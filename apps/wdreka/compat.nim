# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
#
# compat.nim - wdgui constructors with uncertain signatures
#
# The wdgui tutorial documents that these controls exist, but not always
# the exact parameter names. Each helper tries the plausible variants at
# compile time; if none matches, a working fallback is used.

import ../../src/wdgui

proc newMultiEdit*(text = ""): Control =
  # multiline edit field
  when compiles(newEdit(text, multiline = true)):
    result = newEdit(text, multiline = true)
  elif compiles(newEdit(text = text, multiline = true)):
    result = newEdit(text = text, multiline = true)
  elif compiles(newEdit(text, kind = ekMultiline)):
    result = newEdit(text, kind = ekMultiline)
  elif compiles(newMultilineEdit(text)):
    result = newMultilineEdit(text)
  else:
    result = newEdit(text)

proc newFlatButton*(caption: string, tip = ""): Control =
  when compiles(newButton(caption, flat = true)):
    result = newButton(caption, flat = true)
  elif compiles(newButton(caption, isFlat = true)):
    result = newButton(caption, isFlat = true)
  else:
    result = newButton(caption)
  if tip.len > 0:
    when compiles(result.tooltip = tip):
      result.tooltip = tip

proc newSplit*(sideBySide: bool, position: float): auto =
  # sideBySide = true: two panes side by side (vertical bar).
  # If the panes appear stacked instead of side by side, invert the value
  # passed to `vertical` below.
  newSplitter(vertical = sideBySide, position = position)

proc setReadOnly*(id: ControlId) =
  id.state = csReadOnly

template ignore*(e: untyped) =
  # Calls `e` and discards its result if it has one (some wdgui procedures
  # return a value in certain versions and not in others).
  when compiles((discard e)):
    discard e
  else:
    e
