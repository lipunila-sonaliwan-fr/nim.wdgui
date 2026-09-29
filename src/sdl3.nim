# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
# Minimal FFI bindings for SDL3 (>= 3.2), loaded dynamically: no C headers required.
# Compile-time options:
#   -d:sdlttf    use SDL3_ttf for TrueType fonts (otherwise SDL3's built-in bitmap font)
#   -d:sdlimage  use SDL3_image to load PNG/JPG... (otherwise BMP only)
import std/os

proc sdlLibName(sfx: string): string =
  var env = getEnv("WDGUI_PATH")
  var SdlLib =
    when defined(windows):
      "winOS/SDL3" & sfx & ".dll"
    elif defined(macosx):
      "macOS/libSDL3" & sfx & ".dylib"
    else:
      "linOS/libSDL3" & sfx & ".so"
  if env.len > 0 and dirExists(env):
    env = env & "/" & SdlLib
  else:
    env = SdlLib
  result = env

type
  SDL_Window* = ptr object
  SDL_Renderer* = ptr object
  SDL_Texture* = ptr object
  SDL_Surface* = ptr object
  SDL_Cursor* = ptr object
  SDL_FRect* {.bycopy.} = object
    x*, y*, w*, h*: cfloat
  SDL_Rect* {.bycopy.} = object
    x*, y*, w*, h*: cint
  SDL_Color* {.bycopy.} = object
    r*, g*, b*, a*: uint8
  SDL_Event* {.bycopy.} = object
    brut*: array[16, uint64]          # SDL_Event union: 128 bytes, 8-byte alignment.

  SDL_CommonEvent* = object
    typ*, reserved*: uint32
    timestamp*: uint64

  SDL_WindowEvent* = object
    typ*, reserved*: uint32
    timestamp*: uint64
    windowID*: uint32
    data1*, data2*: int32

  SDL_KeyboardEvent* = object
    typ*, reserved*: uint32
    timestamp*: uint64
    windowID*, which*, scancode*, key*: uint32
    modifiers*, raw*: uint16
    down*, repeat*: bool

  SDL_TextInputEvent* = object
    typ*, reserved*: uint32
    timestamp*: uint64
    windowID*: uint32
    text*: cstring

  SDL_MouseMotionEvent* = object
    typ*, reserved*: uint32
    timestamp*: uint64
    windowID*, which*, state*: uint32
    x*, y*, xrel*, yrel*: cfloat

  SDL_MouseButtonEvent* = object
    typ*, reserved*: uint32
    timestamp*: uint64
    windowID*, which*: uint32
    button*: uint8
    down*: bool
    clicks*, padding*: uint8
    x*, y*: cfloat

  SDL_MouseWheelEvent* = object
    typ*, reserved*: uint32
    timestamp*: uint64
    windowID*, which*: uint32
    x*, y*: cfloat
    direction*: uint32
    mouseX*, mouseY*: cfloat

  SDL_UserEvent* = object
    typ*, reserved*: uint32
    timestamp*: uint64
    windowID*: uint32
    code*: int32
    data1*, data2*: pointer

const
  SDL_INIT_VIDEO* = 0x20'u32
  SDL_WINDOW_RESIZABLE* = 0x20'u64
  SDL_BLENDMODE_BLEND* = 0x1'u32
  SDL_PIXELFORMAT_ARGB8888* = 0x16362004'u32                      # B,G,R,A bytes in memory (little-endian)
  SDL_TEXTUREACCESS_STATIC* = 0.cint
  SDL_MOUSEWHEEL_FLIPPED* = 1'u32

  SDL_EVENT_QUIT* = 0x100'u32
  SDL_EVENT_WINDOW_SHOWN* = 0x202'u32
  SDL_EVENT_WINDOW_EXPOSED* = 0x204'u32
  SDL_EVENT_WINDOW_MOVED* = 0x205'u32
  SDL_EVENT_WINDOW_RESIZED* = 0x206'u32
  SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED* = 0x207'u32
  SDL_EVENT_WINDOW_MINIMIZED* = 0x209'u32
  SDL_EVENT_WINDOW_MAXIMIZED* = 0x20A'u32
  SDL_EVENT_WINDOW_RESTORED* = 0x20B'u32
  SDL_EVENT_WINDOW_MOUSE_ENTER* = 0x20C'u32
  SDL_EVENT_WINDOW_MOUSE_LEAVE* = 0x20D'u32
  SDL_EVENT_WINDOW_FOCUS_GAINED* = 0x20E'u32
  SDL_EVENT_WINDOW_FOCUS_LOST* = 0x20F'u32
  SDL_EVENT_WINDOW_CLOSE_REQUESTED* = 0x210'u32
  SDL_EVENT_KEY_DOWN* = 0x300'u32
  SDL_EVENT_KEY_UP* = 0x301'u32
  SDL_EVENT_TEXT_INPUT* = 0x303'u32
  SDL_EVENT_MOUSE_MOTION* = 0x400'u32
  SDL_EVENT_MOUSE_BUTTON_DOWN* = 0x401'u32
  SDL_EVENT_MOUSE_BUTTON_UP* = 0x402'u32
  SDL_EVENT_MOUSE_WHEEL* = 0x403'u32

  SDLK_BACKSPACE* = 0x08'u32
  SDLK_TAB* = 0x09'u32
  SDLK_RETURN* = 0x0D'u32
  SDLK_ESCAPE* = 0x1B'u32
  SDLK_SPACE* = 0x20'u32
  SDLK_A* = 0x61'u32
  SDLK_C* = 0x63'u32
  SDLK_V* = 0x76'u32
  SDLK_X* = 0x78'u32
  SDLK_DELETE* = 0x7F'u32
  SDLK_F2* = 0x4000003B'u32
  SDLK_INSERT* = 0x40000049'u32
  SDLK_HOME* = 0x4000004A'u32
  SDLK_PAGEUP* = 0x4000004B'u32
  SDLK_END* = 0x4000004D'u32
  SDLK_PAGEDOWN* = 0x4000004E'u32
  SDLK_RIGHT* = 0x4000004F'u32
  SDLK_LEFT* = 0x40000050'u32
  SDLK_DOWN* = 0x40000051'u32
  SDLK_UP* = 0x40000052'u32
  SDLK_KP_ENTER* = 0x40000058'u32

  KMOD_SHIFT* = 0x0003'u16
  KMOD_CTRL* = 0x00C0'u16
  KMOD_ALT* = 0x0300'u16
  KMOD_GUI* = 0x0C00'u16

  SDL_SYSTEM_CURSOR_DEFAULT* = 0
  SDL_SYSTEM_CURSOR_TEXT* = 1
  SDL_SYSTEM_CURSOR_EW_RESIZE* = 7
  SDL_SYSTEM_CURSOR_NS_RESIZE* = 8
  SDL_SYSTEM_CURSOR_MOVE* = 9
  SDL_SYSTEM_CURSOR_POINTER* = 11

when defined(macosx):
  const KMOD_CMD* = KMOD_GUI          # shortcut modifier (Cmd on macOS).
else:
  const KMOD_CMD* = KMOD_CTRL         # shortcut modifier (Ctrl elsewhere).

{.push dynlib: sdlLibName(""), cdecl, importc.}
proc SDL_Init*(flags: uint32): bool
proc SDL_Quit*()
proc SDL_GetError*(): cstring
proc SDL_free*(p: pointer)
proc SDL_GetTicks*(): uint64
proc SDL_CreateWindow*(title: cstring, w, h: cint, flags: uint64): SDL_Window
proc SDL_DestroyWindow*(w: SDL_Window)
proc SDL_GetWindowID*(w: SDL_Window): uint32
proc SDL_GetWindowSize*(w: SDL_Window, pw, ph: ptr cint): bool
proc SDL_SetWindowTitle*(w: SDL_Window, title: cstring): bool
proc SDL_SetWindowParent*(w, parent: SDL_Window): bool
proc SDL_SetWindowModal*(w: SDL_Window, modal: bool): bool
proc SDL_GetWindowPosition*(w: SDL_Window, px, py: ptr cint): bool
proc SDL_SetWindowPosition*(w: SDL_Window, x, y: cint): bool
proc SDL_RaiseWindow*(w: SDL_Window): bool
proc SDL_CreateRenderer*(w: SDL_Window, name: cstring): SDL_Renderer
proc SDL_DestroyRenderer*(r: SDL_Renderer)
proc SDL_SetRenderVSync*(r: SDL_Renderer, vsync: cint): bool
proc SDL_SetRenderDrawColor*(r: SDL_Renderer, cr, cg, cb, ca: uint8): bool
proc SDL_SetRenderDrawBlendMode*(r: SDL_Renderer, mode: uint32): bool
proc SDL_RenderClear*(r: SDL_Renderer): bool
proc SDL_RenderPresent*(r: SDL_Renderer): bool
proc SDL_RenderFillRect*(r: SDL_Renderer, rect: ptr SDL_FRect): bool
proc SDL_RenderRect*(r: SDL_Renderer, rect: ptr SDL_FRect): bool
proc SDL_RenderLine*(r: SDL_Renderer, x1, y1, x2, y2: cfloat): bool
proc SDL_RenderPoint*(r: SDL_Renderer, x, y: cfloat): bool
proc SDL_RenderDebugText*(r: SDL_Renderer, x, y: cfloat, s: cstring): bool
proc SDL_SetRenderScale*(r: SDL_Renderer, sx, sy: cfloat): bool
proc SDL_SetRenderClipRect*(r: SDL_Renderer, rect: ptr SDL_Rect): bool
proc SDL_RenderTexture*(r: SDL_Renderer, t: SDL_Texture, src, dst: ptr SDL_FRect): bool
proc SDL_CreateTexture*(r: SDL_Renderer, format: uint32, access: cint, w, h: cint): SDL_Texture
proc SDL_UpdateTexture*(t: SDL_Texture, rect: ptr SDL_Rect, pixels: pointer, pitch: cint): bool
proc SDL_CreateTextureFromSurface*(r: SDL_Renderer, s: SDL_Surface): SDL_Texture
proc SDL_DestroyTexture*(t: SDL_Texture)
proc SDL_GetTextureSize*(t: SDL_Texture, w, h: ptr cfloat): bool
proc SDL_SetTextureColorMod*(t: SDL_Texture, cr, cg, cb: uint8): bool
proc SDL_SetTextureAlphaMod*(t: SDL_Texture, a: uint8): bool
proc SDL_LoadBMP*(file: cstring): SDL_Surface
proc SDL_DestroySurface*(s: SDL_Surface)
proc SDL_WaitEventTimeout*(e: ptr SDL_Event, ms: int32): bool
proc SDL_PollEvent*(e: ptr SDL_Event): bool
proc SDL_PushEvent*(e: ptr SDL_Event): bool
proc SDL_RegisterEvents*(n: cint): uint32
proc SDL_StartTextInput*(w: SDL_Window): bool
proc SDL_StopTextInput*(w: SDL_Window): bool
proc SDL_SetClipboardText*(t: cstring): bool
proc SDL_GetClipboardText*(): cstring
proc SDL_GetModState*(): uint16
proc SDL_CreateSystemCursor*(id: cint): SDL_Cursor
proc SDL_SetCursor*(c: SDL_Cursor): bool
proc SDL_DestroyCursor*(c: SDL_Cursor)
{.pop.}

when defined(sdlttf):
  type TTF_Font* = ptr object
  {.push dynlib: sdlLibName("_ttf"), cdecl, importc.}
  proc TTF_Init*(): bool
  proc TTF_OpenFont*(file: cstring, ptsize: cfloat): TTF_Font
  proc TTF_CloseFont*(f: TTF_Font)
  proc TTF_GetFontHeight*(f: TTF_Font): cint
  proc TTF_GetStringSize*(f: TTF_Font, text: cstring, length: csize_t, w, h: ptr cint): bool
  proc TTF_RenderText_Blended*(f: TTF_Font, text: cstring, length: csize_t, fg: SDL_Color): SDL_Surface
  {.pop.}

when defined(sdlimage):
  proc IMG_Load*(file: cstring): SDL_Surface {.dynlib: sdlLibName("_image"), cdecl, importc.}
