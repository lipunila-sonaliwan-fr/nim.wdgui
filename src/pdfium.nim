# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
# PDFium bindings (https://pdfium.googlesource.com/pdfium), loaded at run time with
# std/dynlib: programs that never open a PDF do not need the library.
#
# Get a prebuilt library from https://github.com/bblanchon/pdfium-binaries
# (lib/libpdfium.dylib, lib/libpdfium.so or bin/pdfium.dll) and put it next to the
# executable, in `./linOS`, `./macOS`, `./winOS` folder next to it or set the `WDGUI_PATH`
# environment variable to the root of these folders.
#
# PDFium is not thread-safe: every call must be made while holding `pdfLock`.
import std/[dynlib, os, locks, unicode]

type
  FPDF_DOCUMENT* = pointer
  FPDF_PAGE* = pointer
  FPDF_BITMAP* = pointer
  FPDF_TEXTPAGE* = pointer
  FPDF_SCHHANDLE* = pointer
  FPDF_PAGEOBJECT* = pointer
  FPDF_ANNOTATION* = pointer
  FPDF_BOOKMARK* = pointer
  FPDF_DEST* = pointer
  FPDF_ACTION* = pointer
  FS_RECTF* {.bycopy.} = object
    left*, top*, right*, bottom*: cfloat
  FS_QUADPOINTSF* {.bycopy.} = object
    x1*, y1*, x2*, y2*, x3*, y3*, x4*, y4*: cfloat
  FPDF_FILEWRITE* {.bycopy.} = object
    version*: cint
    writeBlock*: proc (pThis: ptr FPDF_FILEWRITE, data: pointer, size: culong): cint {.cdecl.}

const
  FPDF_ANNOT* = 0x01.cint                                         # render annotations.
  FPDF_ERR_PASSWORD* = 4.culong
  FPDF_ANNOT_TEXT* = 1.cint                                       # sticky note.
  FPDF_ANNOT_HIGHLIGHT* = 9.cint
  FPDF_MATCHCASE* = 1.culong
  FPDF_MATCHWHOLEWORD* = 2.culong
  FPDF_NO_INCREMENTAL* = 2.culong
  FPDFANNOT_COLORTYPE_Color* = 0.cint

var
  pdfLock*: Lock
  pdfiumError*: string
  lib: LibHandle
  tried, loaded: bool

  FPDF_InitLibrary*: proc () {.cdecl.}
  FPDF_LoadMemDocument*: proc (data: pointer, size: cint, password: cstring): FPDF_DOCUMENT {.cdecl.}
  FPDF_CreateNewDocument*: proc (): FPDF_DOCUMENT {.cdecl.}
  FPDF_CloseDocument*: proc (doc: FPDF_DOCUMENT) {.cdecl.}
  FPDF_GetLastError*: proc (): culong {.cdecl.}
  FPDF_GetPageCount*: proc (doc: FPDF_DOCUMENT): cint {.cdecl.}
  FPDF_LoadPage*: proc (doc: FPDF_DOCUMENT, index: cint): FPDF_PAGE {.cdecl.}
  FPDF_ClosePage*: proc (page: FPDF_PAGE) {.cdecl.}
  FPDF_GetPageWidth*: proc (page: FPDF_PAGE): cdouble {.cdecl.}
  FPDF_GetPageHeight*: proc (page: FPDF_PAGE): cdouble {.cdecl.}
  FPDF_GetPageSizeByIndex*: proc (doc: FPDF_DOCUMENT, index: cint, w, h: ptr cdouble): cint {.cdecl.}
  FPDFBitmap_Create*: proc (w, h, alpha: cint): FPDF_BITMAP {.cdecl.}
  FPDFBitmap_FillRect*: proc (bmp: FPDF_BITMAP, left, top, w, h: cint, color: culong) {.cdecl.}
  FPDFBitmap_GetBuffer*: proc (bmp: FPDF_BITMAP): pointer {.cdecl.}
  FPDFBitmap_GetStride*: proc (bmp: FPDF_BITMAP): cint {.cdecl.}
  FPDFBitmap_Destroy*: proc (bmp: FPDF_BITMAP) {.cdecl.}
  FPDF_RenderPageBitmap*: proc (bmp: FPDF_BITMAP, page: FPDF_PAGE, startX, startY, sizeX, sizeY,
                                rotate, flags: cint) {.cdecl.}
  FPDF_DeviceToPage*: proc (page: FPDF_PAGE, startX, startY, sizeX, sizeY, rotate, deviceX, deviceY: cint,
                            pageX, pageY: ptr cdouble): cint {.cdecl.}
  FPDF_PageToDevice*: proc (page: FPDF_PAGE, startX, startY, sizeX, sizeY, rotate: cint,
                            pageX, pageY: cdouble, deviceX, deviceY: ptr cint): cint {.cdecl.}
  FPDF_GetMetaText*: proc (doc: FPDF_DOCUMENT, tag: cstring, buffer: pointer, buflen: culong): culong {.cdecl.}
  FPDF_GetFileVersion*: proc (doc: FPDF_DOCUMENT, version: ptr cint): cint {.cdecl.}
  FPDFPage_New*: proc (doc: FPDF_DOCUMENT, index: cint, w, h: cdouble): FPDF_PAGE {.cdecl.}
  FPDFPage_Delete*: proc (doc: FPDF_DOCUMENT, index: cint) {.cdecl.}
  FPDFPage_GetRotation*: proc (page: FPDF_PAGE): cint {.cdecl.}
  FPDFPage_SetRotation*: proc (page: FPDF_PAGE, rotate: cint) {.cdecl.}
  FPDFPage_GenerateContent*: proc (page: FPDF_PAGE): cint {.cdecl.}
  FPDFPage_InsertObject*: proc (page: FPDF_PAGE, obj: FPDF_PAGEOBJECT) {.cdecl.}
  FPDFPageObj_NewTextObj*: proc (doc: FPDF_DOCUMENT, font: cstring, size: cfloat): FPDF_PAGEOBJECT {.cdecl.}
  FPDFText_SetText*: proc (obj: FPDF_PAGEOBJECT, text: ptr uint16): cint {.cdecl.}
  FPDFPageObj_Transform*: proc (obj: FPDF_PAGEOBJECT, a, b, c, d, e, f: cdouble) {.cdecl.}
  FPDFPageObj_SetFillColor*: proc (obj: FPDF_PAGEOBJECT, r, g, b, a: cuint): cint {.cdecl.}
  FPDFPageObj_SetStrokeColor*: proc (obj: FPDF_PAGEOBJECT, r, g, b, a: cuint): cint {.cdecl.}
  FPDFPageObj_SetStrokeWidth*: proc (obj: FPDF_PAGEOBJECT, width: cfloat): cint {.cdecl.}
  FPDFPageObj_CreateNewRect*: proc (x, y, w, h: cfloat): FPDF_PAGEOBJECT {.cdecl.}
  FPDFPath_SetDrawMode*: proc (path: FPDF_PAGEOBJECT, fillmode: cint, stroke: cint): cint {.cdecl.}
  FPDF_ImportPages*: proc (dest, src: FPDF_DOCUMENT, pagerange: cstring, index: cint): cint {.cdecl.}
  FPDF_MovePages*: proc (doc: FPDF_DOCUMENT, indices: ptr cint, len: culong, dest: cint): cint {.cdecl.}
  FPDF_SaveAsCopy*: proc (doc: FPDF_DOCUMENT, fw: ptr FPDF_FILEWRITE, flags: culong): cint {.cdecl.}
  FPDFText_LoadPage*: proc (page: FPDF_PAGE): FPDF_TEXTPAGE {.cdecl.}
  FPDFText_ClosePage*: proc (tp: FPDF_TEXTPAGE) {.cdecl.}
  FPDFText_CountChars*: proc (tp: FPDF_TEXTPAGE): cint {.cdecl.}
  FPDFText_GetText*: proc (tp: FPDF_TEXTPAGE, start, count: cint, res: ptr uint16): cint {.cdecl.}
  FPDFText_GetCharIndexAtPos*: proc (tp: FPDF_TEXTPAGE, x, y, xTol, yTol: cdouble): cint {.cdecl.}
  FPDFText_CountRects*: proc (tp: FPDF_TEXTPAGE, start, count: cint): cint {.cdecl.}
  FPDFText_GetRect*: proc (tp: FPDF_TEXTPAGE, index: cint, l, t, r, b: ptr cdouble): cint {.cdecl.}
  FPDFText_FindStart*: proc (tp: FPDF_TEXTPAGE, what: ptr uint16, flags: culong, start: cint): FPDF_SCHHANDLE {.cdecl.}
  FPDFText_FindNext*: proc (h: FPDF_SCHHANDLE): cint {.cdecl.}
  FPDFText_FindPrev*: proc (h: FPDF_SCHHANDLE): cint {.cdecl.}
  FPDFText_GetSchResultIndex*: proc (h: FPDF_SCHHANDLE): cint {.cdecl.}
  FPDFText_GetSchCount*: proc (h: FPDF_SCHHANDLE): cint {.cdecl.}
  FPDFText_FindClose*: proc (h: FPDF_SCHHANDLE) {.cdecl.}
  FPDFPage_CreateAnnot*: proc (page: FPDF_PAGE, subtype: cint): FPDF_ANNOTATION {.cdecl.}
  FPDFPage_CloseAnnot*: proc (annot: FPDF_ANNOTATION) {.cdecl.}
  FPDFAnnot_SetRect*: proc (annot: FPDF_ANNOTATION, rect: ptr FS_RECTF): cint {.cdecl.}
  FPDFAnnot_SetColor*: proc (annot: FPDF_ANNOTATION, colorType: cint, r, g, b, a: cuint): cint {.cdecl.}
  FPDFAnnot_AppendAttachmentPoints*: proc (annot: FPDF_ANNOTATION, q: ptr FS_QUADPOINTSF): cint {.cdecl.}
  FPDFAnnot_SetStringValue*: proc (annot: FPDF_ANNOTATION, key: cstring, value: ptr uint16): cint {.cdecl.}
  FPDFBookmark_GetFirstChild*: proc (doc: FPDF_DOCUMENT, bm: FPDF_BOOKMARK): FPDF_BOOKMARK {.cdecl.}
  FPDFBookmark_GetNextSibling*: proc (doc: FPDF_DOCUMENT, bm: FPDF_BOOKMARK): FPDF_BOOKMARK {.cdecl.}
  FPDFBookmark_GetTitle*: proc (bm: FPDF_BOOKMARK, buffer: pointer, buflen: culong): culong {.cdecl.}
  FPDFBookmark_GetDest*: proc (doc: FPDF_DOCUMENT, bm: FPDF_BOOKMARK): FPDF_DEST {.cdecl.}
  FPDFBookmark_GetAction*: proc (bm: FPDF_BOOKMARK): FPDF_ACTION {.cdecl.}
  FPDFAction_GetDest*: proc (doc: FPDF_DOCUMENT, action: FPDF_ACTION): FPDF_DEST {.cdecl.}
  FPDFDest_GetDestPageIndex*: proc (doc: FPDF_DOCUMENT, dest: FPDF_DEST): cint {.cdecl.}

initLock(pdfLock)

proc loadPdfium*(): bool =
  # Loads PDFium once; false (and `pdfiumError` set) when it is not available.
  # Must be called while holding `pdfLock`.
  if tried: return loaded
  tried = true
  when defined(windows):
    const name = "winOS/pdfium.dll"
  elif defined(macosx):
    const name = "macOS/libpdfium.dylib"
  else:
    const name = "linOS/libpdfium.so"
  var env = getEnv("WDGUI_PATH")
  if env.len > 0 and dirExists(env):
    env = env & "/" & name
  else:
    env = name
  lib = loadLib(env)
  if lib == nil:
    pdfiumError = "PDFium library not found (see https://github.com/bblanchon/pdfium-binaries; " &
                  "put the library in '" & env & "' next to the program or set properly WDGUI_PATH.)"
    return false
  template need(v: untyped, name: string) =
    v = cast[typeof(v)](lib.symAddr(name))
    if v == nil:
      pdfiumError = "PDFium: missing function " & name
      return false
  template opt(v: untyped, name: string) =
    v = cast[typeof(v)](lib.symAddr(name))
  need(FPDF_InitLibrary, "FPDF_InitLibrary")
  need(FPDF_LoadMemDocument, "FPDF_LoadMemDocument")
  need(FPDF_CreateNewDocument, "FPDF_CreateNewDocument")
  need(FPDF_CloseDocument, "FPDF_CloseDocument")
  need(FPDF_GetLastError, "FPDF_GetLastError")
  need(FPDF_GetPageCount, "FPDF_GetPageCount")
  need(FPDF_LoadPage, "FPDF_LoadPage")
  need(FPDF_ClosePage, "FPDF_ClosePage")
  need(FPDF_GetPageWidth, "FPDF_GetPageWidth")
  need(FPDF_GetPageHeight, "FPDF_GetPageHeight")
  opt(FPDF_GetPageSizeByIndex, "FPDF_GetPageSizeByIndex")
  need(FPDFBitmap_Create, "FPDFBitmap_Create")
  need(FPDFBitmap_FillRect, "FPDFBitmap_FillRect")
  need(FPDFBitmap_GetBuffer, "FPDFBitmap_GetBuffer")
  need(FPDFBitmap_GetStride, "FPDFBitmap_GetStride")
  need(FPDFBitmap_Destroy, "FPDFBitmap_Destroy")
  need(FPDF_RenderPageBitmap, "FPDF_RenderPageBitmap")
  need(FPDF_DeviceToPage, "FPDF_DeviceToPage")
  need(FPDF_PageToDevice, "FPDF_PageToDevice")
  need(FPDF_GetMetaText, "FPDF_GetMetaText")
  need(FPDF_GetFileVersion, "FPDF_GetFileVersion")
  need(FPDFPage_New, "FPDFPage_New")
  need(FPDFPage_Delete, "FPDFPage_Delete")
  need(FPDFPage_GetRotation, "FPDFPage_GetRotation")
  need(FPDFPage_SetRotation, "FPDFPage_SetRotation")
  need(FPDFPage_GenerateContent, "FPDFPage_GenerateContent")
  need(FPDFPage_InsertObject, "FPDFPage_InsertObject")
  need(FPDFPageObj_NewTextObj, "FPDFPageObj_NewTextObj")
  need(FPDFText_SetText, "FPDFText_SetText")
  need(FPDFPageObj_Transform, "FPDFPageObj_Transform")
  need(FPDFPageObj_SetFillColor, "FPDFPageObj_SetFillColor")
  need(FPDFPageObj_SetStrokeColor, "FPDFPageObj_SetStrokeColor")
  need(FPDFPageObj_SetStrokeWidth, "FPDFPageObj_SetStrokeWidth")
  need(FPDFPageObj_CreateNewRect, "FPDFPageObj_CreateNewRect")
  need(FPDFPath_SetDrawMode, "FPDFPath_SetDrawMode")
  need(FPDF_ImportPages, "FPDF_ImportPages")
  opt(FPDF_MovePages, "FPDF_MovePages")
  need(FPDF_SaveAsCopy, "FPDF_SaveAsCopy")
  need(FPDFText_LoadPage, "FPDFText_LoadPage")
  need(FPDFText_ClosePage, "FPDFText_ClosePage")
  need(FPDFText_CountChars, "FPDFText_CountChars")
  need(FPDFText_GetText, "FPDFText_GetText")
  need(FPDFText_GetCharIndexAtPos, "FPDFText_GetCharIndexAtPos")
  need(FPDFText_CountRects, "FPDFText_CountRects")
  need(FPDFText_GetRect, "FPDFText_GetRect")
  need(FPDFText_FindStart, "FPDFText_FindStart")
  need(FPDFText_FindNext, "FPDFText_FindNext")
  need(FPDFText_FindPrev, "FPDFText_FindPrev")
  need(FPDFText_GetSchResultIndex, "FPDFText_GetSchResultIndex")
  need(FPDFText_GetSchCount, "FPDFText_GetSchCount")
  need(FPDFText_FindClose, "FPDFText_FindClose")
  need(FPDFPage_CreateAnnot, "FPDFPage_CreateAnnot")
  need(FPDFPage_CloseAnnot, "FPDFPage_CloseAnnot")
  need(FPDFAnnot_SetRect, "FPDFAnnot_SetRect")
  need(FPDFAnnot_SetColor, "FPDFAnnot_SetColor")
  need(FPDFAnnot_AppendAttachmentPoints, "FPDFAnnot_AppendAttachmentPoints")
  need(FPDFAnnot_SetStringValue, "FPDFAnnot_SetStringValue")
  need(FPDFBookmark_GetFirstChild, "FPDFBookmark_GetFirstChild")
  need(FPDFBookmark_GetNextSibling, "FPDFBookmark_GetNextSibling")
  need(FPDFBookmark_GetTitle, "FPDFBookmark_GetTitle")
  need(FPDFBookmark_GetDest, "FPDFBookmark_GetDest")
  opt(FPDFBookmark_GetAction, "FPDFBookmark_GetAction")
  opt(FPDFAction_GetDest, "FPDFAction_GetDest")
  need(FPDFDest_GetDestPageIndex, "FPDFDest_GetDestPageIndex")
  FPDF_InitLibrary()
  loaded = true
  true

# UTF-16 helpers

proc toUtf16z*(s: string): seq[uint16] =
  # Null-terminated UTF-16LE (FPDF_WIDESTRING).
  for r in s.runes:
    let c = int(r)
    if c < 0x10000: result.add uint16(c)
    else:
      let v = c - 0x10000
      result.add uint16(0xD800 + (v shr 10))
      result.add uint16(0xDC00 + (v and 0x3FF))
  result.add 0'u16

proc fromUtf16*(buf: openArray[uint16]): string =
  var i = 0
  while i < buf.len and buf[i] != 0:
    var c = int(buf[i])
    if c >= 0xD800 and c < 0xDC00 and i + 1 < buf.len:
      c = 0x10000 + ((c - 0xD800) shl 10) + (int(buf[i + 1]) - 0xDC00)
      inc i
    result.add $Rune(c)
    inc i
