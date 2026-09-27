# wdgui - Nim GUI library on top of SDL3 modelled on WD-style controls and API.
#                _              _
#   __      ____| |_ __ _ _   _(_)
#   \ \ /\ / / _` (_) _` | | | | |
#    \ V  V / (_| || (_| | |_| | |
#     \_/\_/ \__,_(_)__, |\__,_|_|
#                   |___/
#
#   import wdgui
#   proc handler(ev: var Event) {.nimcall, gcsafe.} = echo ev.kind, " ", ev.id
#   let w = newWindow("Hello", 400, 200, handler)
#   discard w.addChild(newButton("OK", isDefault = true))
#   runApplication()
#
# Build: nim c --threads:on --mm:atomicArc [-d:sdlttf] [-d:sdlimage] myprog.nim
import wdgui/[core, controls_basic, controls_lists, controls_charts, controls_grid, controls_panel, application, api]
import sdl3
export core, controls_basic, controls_lists, controls_charts, controls_grid, controls_panel, application, api

# Keyboard constants that are handy inside event handlers.
export SDLK_RETURN, SDLK_ESCAPE, SDLK_TAB, SDLK_SPACE, SDLK_BACKSPACE, SDLK_DELETE,
       SDLK_LEFT, SDLK_RIGHT, SDLK_UP, SDLK_DOWN, SDLK_HOME, SDLK_END,
       SDLK_PAGEUP, SDLK_PAGEDOWN, SDLK_F2, SDLK_INSERT, SDLK_A, SDLK_C, SDLK_V, SDLK_X,
       KMOD_SHIFT, KMOD_CTRL, KMOD_ALT, KMOD_GUI, KMOD_CMD,
       SDL_SYSTEM_CURSOR_DEFAULT, SDL_SYSTEM_CURSOR_TEXT, SDL_SYSTEM_CURSOR_POINTER,
       SDL_SYSTEM_CURSOR_EW_RESIZE, SDL_SYSTEM_CURSOR_NS_RESIZE, SDL_SYSTEM_CURSOR_MOVE
