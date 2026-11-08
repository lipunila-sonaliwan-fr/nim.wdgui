# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
#   wdgui - loading images as textures (Image control, grid icons,
#   dialog box icons).
#
#   PNG and JPEG files are decoded using pure Nim (ide/imagedecode) and then passed to
#   wdgui’s SDL instance. This eliminates the need for external libraries and avoids
#   a common pitfall with SDL3_image: if it is linked against a *different*
#   instance of SDL3 (for example, the Homebrew version of libSDL3_image, which links
#   to /opt/homebrew/.../libSDL3.0.dylib), the surface it returns belongs to that
#   other SDL instance. wdgui’s SDL instance will reject this surface—throwing a
#   "Parameter 'surface' is invalid" error—which previously resulted in an empty
#   image with no accompanying error message.
#   BMP files are handled via SDL_LoadBMP. Other formats (GIF, WEBP, TIFF, etc.),
#   as well as interlaced PNGs and progressive JPEGs, are processed using
#   SDL3_image (provided wdgui is compiled with the -d:sdlimage flag).
#   Failures are reported to standard error, logged once per file path.

import std/[strutils, os, sets, locks]
import ../sdl3
import imagedecode

const PixRGBA32 = 0x16762004'u32        #SDL_PIXELFORMAT_ABGR8888: bytes R, G, B, A (little-endian)

var reported: HashSet[string]
var reportLock: Lock
initLock(reportLock)

proc report(path, msg: string) =
  {.cast(gcsafe).}:
    withLock reportLock:
      if path in reported: return
      reported.incl path
  try: stderr.writeLine "wdgui: image « " & path & " » non chargée : " & msg
  except IOError: discard

proc fromSurface(ren: SDL_Renderer, s: SDL_Surface): tuple[tex: SDL_Texture, w, h: float, err: string] =
  result.tex = SDL_CreateTextureFromSurface(ren, s)
  if result.tex == nil:
    result.err = $SDL_GetError()
    return
  var w, h: cfloat
  discard SDL_GetTextureSize(result.tex, addr w, addr h)
  result.w = float(w)
  result.h = float(h)

proc loadTexture*(ren: SDL_Renderer, path: string): tuple[tex: SDL_Texture, w, h: float, err: string] =
  # Image texture at `path` (`nil` and `err` are set in the event of failure).
  if path.len == 0: return
  if not fileExists(path):
    result.err = "fichier introuvable"
    report(path, result.err)
    return
  let ext = path.splitFile.ext.toLowerAscii
  var native = ""
  if ext == ".bmp":
    let s = SDL_LoadBMP(path.cstring)
    if s != nil:
      result = fromSurface(ren, s)
      SDL_DestroySurface(s)
    else: result.err = $SDL_GetError()
  else:
    try:
      var img = decodeImageFile(path)
      if img.w > 0 and img.h > 0:
        let s = SDL_CreateSurfaceFrom(cint(img.w), cint(img.h), PixRGBA32, addr img.px[0], cint(img.w * 4))
        if s != nil:
          result = fromSurface(ren, s)
          SDL_DestroySurface(s)
        else: result.err = $SDL_GetError()
    except CatchableError as e:
      native = e.msg             # format non pris en charge en Nim pur : SDL3_image ensuite.
    if result.tex == nil and native.len > 0:
      when defined(sdlimage):
        let s = IMG_Load(path.cstring)
        if s != nil:
          result = fromSurface(ren, s)
          SDL_DestroySurface(s)
          if result.tex == nil:
            result.err = result.err & " (SDL3_image est-elle liée à un autre exemplaire de SDL3 ?)"
        else: result.err = native & " ; SDL3_image : " & $SDL_GetError()
      else:
        result.err = native & " (compilez avec -d:sdlimage pour les autres formats)"
  if result.tex == nil and result.err.len > 0: report(path, result.err)
