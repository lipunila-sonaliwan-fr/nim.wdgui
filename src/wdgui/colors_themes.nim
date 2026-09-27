# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
# Colors, themes (Windows 11 / macOS / Linux-GNOME look & feel) and per-control styles.
import std/[options, strutils]
export options

type
  Color* = object
    r*, g*, b*, a*: uint8

proc rgb*(r, g, b: int, a = 255): Color =
  Color(r: uint8(clamp(r, 0, 255)), g: uint8(clamp(g, 0, 255)),
          b: uint8(clamp(b, 0, 255)), a: uint8(clamp(a, 0, 255)))

proc hex*(s: string): Color =
  # "#RRGGBB" or "#RRGGBBAA"
  var h = s.strip
  if h.startsWith("#"): h = h[1 .. ^1]
  if h.len < 6: return rgb(255, 0, 255)
  try:
    result = rgb(parseHexInt(h[0 .. 1]), parseHexInt(h[2 .. 3]), parseHexInt(h[4 .. 5]),
                 (if h.len >= 8: parseHexInt(h[6 .. 7]) else: 255))
  except ValueError:
    result = rgb(255, 0, 255)

proc withAlpha*(c: Color, a: int): Color = rgb(c.r.int, c.g.int, c.b.int, a)

proc mix*(a, b: Color, t: float): Color =
  template m(x, y: uint8): int = int(float(x) + (float(y) - float(x)) * t)
  rgb(m(a.r, b.r), m(a.g, b.g), m(a.b, b.b), m(a.a, b.a))

const
  Transparent* = Color(r: 0, g: 0, b: 0, a: 0)
  White* = Color(r: 255, g: 255, b: 255, a: 255)
  Black* = Color(r: 0, g: 0, b: 0, a: 255)

type
  FocusStyle* = enum
    fsRing      # accent ring (GNOME/Adwaita).
    fsUnderline # accent underline on edits + contrasting ring (Windows 11).
    fsHalo      # translucent halo (MacOS).
  ButtonStyle* = enum
    bsFlat, bsRaised, bsPill
  LookFeel* = enum
    lfWindows = "Windows", lfMacOS = "macOS", lfLinux = "Linux", lfCustom = "Custom"

  Theme* = object
    name*: string
    look*: LookFeel
    dark*: bool
    windowBg*, surface*, surfaceHover*, surfacePressed*, fieldBg*: Color
    border*, text*, textSecondary*, textDisabled*: Color
    accent*, accentHover*, textOnAccent*: Color
    selection*, textSelection*, header*, shadow*, focus*: Color
    radius*, fieldRadius*, checkRadius*, borderWidth*: float
    focusStyle*: FocusStyle
    buttonStyle*: ButtonStyle
    accentSelection*: bool     # list selection drawn in the accent color (MacOS).
    controlHeight*, lineHeight*, margin*, spacing*, checkSize*: float
    textScale*: float          # SDL bitmap font (8 px × scale).
    fonts*: seq[string]        # candidate TrueType fonts (-d:sdlttf).
    fontSize*: float
    palette*: seq[Color]       # series colors (charts, treemap...).

  Style* = object
    # Per-control graphical overrides (none = theme value).
    background*, text*, border*, accent*: Option[Color]
    radius*, borderWidth*: Option[float]

proc paletteFor(accent: Color): seq[Color] =
  @[accent, hex"#E3008C", hex"#107C10", hex"#FF8C00", hex"#8764B8",
    hex"#00B7C3", hex"#D13438", hex"#498205", hex"#CA5010", hex"#4F6BED"]

proc themeWindows11*(dark = false): Theme =
  result = Theme(name: "Windows 11" & (if dark: " sombre" else: ""), look: lfWindows, dark: dark,
    radius: 4, fieldRadius: 4, checkRadius: 4, borderWidth: 1, focusStyle: fsUnderline,
    buttonStyle: bsRaised, accentSelection: false, controlHeight: 32, lineHeight: 28,
    margin: 12, spacing: 8, checkSize: 20, textScale: 2, fontSize: 14,
    fonts: @["C:/Windows/Fonts/segoeui.ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
               "/System/Library/Fonts/Supplemental/Arial.ttf"])
  if dark:
    result.windowBg = hex"#202020"; result.surface = hex"#2D2D2D"
    result.surfaceHover = hex"#323232"; result.surfacePressed = hex"#272727"
    result.fieldBg = hex"#2D2D2D"; result.border = hex"#454545"
    result.text = hex"#FFFFFF"; result.textSecondary = hex"#C5C5C5"
    result.textDisabled = hex"#787878"; result.accent = hex"#60CDFF"
    result.accentHover = hex"#5AB9E8"; result.textOnAccent = hex"#000000"
    result.selection = hex"#3A3A3A"; result.textSelection = hex"#FFFFFF"
    result.header = hex"#272727"; result.shadow = hex"#00000055"; result.focus = hex"#FFFFFF"
  else:
    result.windowBg = hex"#F3F3F3"; result.surface = hex"#FBFBFB"
    result.surfaceHover = hex"#F6F6F6"; result.surfacePressed = hex"#EDEDED"
    result.fieldBg = hex"#FFFFFF"; result.border = hex"#D1D1D1"
    result.text = hex"#1B1B1B"; result.textSecondary = hex"#5F5F5F"
    result.textDisabled = hex"#A0A0A0"; result.accent = hex"#005FB8"
    result.accentHover = hex"#196EBF"; result.textOnAccent = hex"#FFFFFF"
    result.selection = hex"#E5EEF8"; result.textSelection = hex"#1B1B1B"
    result.header = hex"#F9F9F9"; result.shadow = hex"#0000001F"; result.focus = hex"#1B1B1B"
  result.palette = paletteFor(result.accent)

proc themeMacOS*(dark = false): Theme =
  result = Theme(name: "macOS" & (if dark: " sombre" else: ""), look: lfMacOS, dark: dark,
    radius: 6, fieldRadius: 5, checkRadius: 4, borderWidth: 1, focusStyle: fsHalo,
    buttonStyle: bsRaised, accentSelection: true, controlHeight: 28, lineHeight: 24,
    margin: 14, spacing: 8, checkSize: 16, textScale: 2, fontSize: 13,
    fonts: @["/System/Library/Fonts/SFNS.ttf", "/System/Library/Fonts/Helvetica.ttc",
               "/System/Library/Fonts/Supplemental/Arial.ttf",
               "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", "C:/Windows/Fonts/arial.ttf"])
  if dark:
    result.windowBg = hex"#2B2B2B"; result.surface = hex"#5C5C5C"
    result.surfaceHover = hex"#666666"; result.surfacePressed = hex"#4A4A4A"
    result.fieldBg = hex"#1E1E1E"; result.border = hex"#3E3E3E"
    result.text = hex"#F2F2F2"; result.textSecondary = hex"#A8A8A8"
    result.textDisabled = hex"#6E6E6E"; result.accent = hex"#0A84FF"
    result.accentHover = hex"#339AFF"; result.textOnAccent = hex"#FFFFFF"
    result.selection = hex"#0A84FF"; result.textSelection = hex"#FFFFFF"
    result.header = hex"#323232"; result.shadow = hex"#00000066"; result.focus = hex"#0A84FF80"
  else:
    result.windowBg = hex"#ECECEC"; result.surface = hex"#FFFFFF"
    result.surfaceHover = hex"#F7F7F7"; result.surfacePressed = hex"#E3E3E3"
    result.fieldBg = hex"#FFFFFF"; result.border = hex"#C9C9C9"
    result.text = hex"#262626"; result.textSecondary = hex"#7A7A7A"
    result.textDisabled = hex"#B0B0B0"; result.accent = hex"#007AFF"
    result.accentHover = hex"#2B8CFF"; result.textOnAccent = hex"#FFFFFF"
    result.selection = hex"#0064E1"; result.textSelection = hex"#FFFFFF"
    result.header = hex"#F5F5F5"; result.shadow = hex"#00000026"; result.focus = hex"#007AFF80"
  result.palette = paletteFor(result.accent)

proc themeLinux*(dark = false): Theme =
  # Inspired by GNOME / libadwaita,
  result = Theme(name: "Linux (Adwaita)" & (if dark: " sombre" else: ""), look: lfLinux, dark: dark,
    radius: 6, fieldRadius: 6, checkRadius: 4, borderWidth: 1, focusStyle: fsRing,
    buttonStyle: bsFlat, accentSelection: false, controlHeight: 34, lineHeight: 30,
    margin: 12, spacing: 8, checkSize: 18, textScale: 2, fontSize: 14,
    fonts: @["/usr/share/fonts/cantarell/Cantarell-VF.otf",
               "/usr/share/fonts/opentype/cantarell/Cantarell-VF.otf",
               "/usr/share/fonts/truetype/ubuntu/Ubuntu-R.ttf",
               "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
               "/usr/share/fonts/TTF/DejaVuSans.ttf",
               "/usr/share/fonts/dejavu-sans-fonts/DejaVuSans.ttf",
               "/usr/share/fonts/noto/NotoSans-Regular.ttf",
               "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf"])
  if dark:
    result.windowBg = hex"#242424"; result.surface = hex"#3A3A3A"
    result.surfaceHover = hex"#454545"; result.surfacePressed = hex"#505050"
    result.fieldBg = hex"#3A3A3A"; result.border = hex"#484848"
    result.text = hex"#FFFFFF"; result.textSecondary = hex"#BDBDBD"
    result.textDisabled = hex"#7C7C7C"; result.accent = hex"#3584E4"
    result.accentHover = hex"#4A92E8"; result.textOnAccent = hex"#FFFFFF"
    result.selection = hex"#2A4C73"; result.textSelection = hex"#FFFFFF"
    result.header = hex"#303030"; result.shadow = hex"#00000060"; result.focus = hex"#3584E480"
  else:
    result.windowBg = hex"#FAFAFA"; result.surface = hex"#EBEBEB"
    result.surfaceHover = hex"#E0E0E0"; result.surfacePressed = hex"#D4D4D4"
    result.fieldBg = hex"#FFFFFF"; result.border = hex"#D6D6D6"
    result.text = hex"#2E2E2E"; result.textSecondary = hex"#6E6E6E"
    result.textDisabled = hex"#AAAAAA"; result.accent = hex"#3584E4"
    result.accentHover = hex"#4A92E8"; result.textOnAccent = hex"#FFFFFF"
    result.selection = hex"#DAE7F9"; result.textSelection = hex"#1E1E1E"
    result.header = hex"#F2F2F2"; result.shadow = hex"#00000022"; result.focus = hex"#3584E480"
  result.palette = paletteFor(result.accent)

proc themeNative*(dark = false): Theme =
  # Picks the host system's look & feel.
  when defined(windows): themeWindows11(dark)
  elif defined(macosx): themeMacOS(dark)
  else: themeLinux(dark)
