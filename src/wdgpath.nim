# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
# Base directory for resources (linOS/macOS/winOS libraries, ttf/ fonts):
#   1. the WDGUI_PATH environment variable, if it points to a directory;
#   2. the directory containing the executable (when launched via double-click from the Finder—where
#      the current working directory is the user's home folder—or ../Resources within a .app bundle);
#   3. the current working directory (legacy behavior).
import std/os

proc wdguiBase*(probe: string): string =
  # probe: relative path to an expected resource (e.g., "macOS/libSDL3.dylib").
  let env = getEnv("WDGUI_PATH")
  if env.len > 0 and dirExists(env): return env
  let app = getAppDir()
  for d in [app, app / ".." / "Resources", getCurrentDir()]:
    if fileExists(d / probe) or dirExists(d / probe): return d
  "."
