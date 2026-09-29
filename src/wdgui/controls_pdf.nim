# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
# PdfViewer: a PDF viewer and editor control built on PDFium (see pdfium.nim).
#
# A composite control: two command bars, a sidebar (page thumbnails / outline), the pages in
# continuous scrolling (rendered by a background thread), and a status line.
#
# * Reading: open (with password), first / previous / next / last page, go to page, zoom in /
#   out, fit width, fit page, actual size, thumbnails, outline (bookmarks), text search
#   (match case, whole word, backwards) with highlighted results, text selection and copy,
#   document information (metadata).
# * Editing: rotate, delete, move up / down and insert blank pages; insert (merge) pages of
#   another PDF at a chosen position; add text, sticky notes, rectangles and highlights of
#   the selected text.
# * Creating: new blank document, then pages, text and annotations; save / save as.
#
# Commands that need a dialog (open, save as, go to, find, insert, add text...) run on their
# own thread, so the control is self-contained. Every operation is also available through
# the thread-safe `pdf...` procedures (by ControlId), which emit evChange (text = operation)
# and evSelection (index = current page, 1-based).
import std/[os, strutils, math, locks, typedthreads]
import ../[sdl3, pdfium], core, controls_basic, dialogs

type
  PdfTool* = enum
    ptSelect = "Select", ptHand = "Hand", ptText = "Text", ptNote = "Note", ptRect = "Rectangle"
  PageRect = tuple[l, t, r, b: float]                             # PDF points, origin bottom-left.
  RenderJob = tuple[key: string, gen, page, w, h: int]
  RenderDone = tuple[key: string, w, h, stride: int, pixels: seq[byte]]
  PdfData = ref object
    bytes: string

  PdfToolButton = ref object of Button
    viewer: PdfViewer
    cmd: string

  PdfPageView = ref object of Control
    viewer: PdfViewer
    scrollX, scrollY, totalH: float
    boxes: seq[Rect]             # page rectangles in content coordinates.
    screen: seq[Rect]            # page rectangles on screen (last frame).
    panning, selecting, drawingRect: bool
    panX, panY, panSX, panSY: float
    rectPage: int
    rectA, rectB: tuple[x, y: float]

  PdfSidebar = ref object of Control
    viewer: PdfViewer
    mode: int                    # 0 = pages, 1 = outline.
    scroll: float
    items: seq[tuple[r: Rect, page: int]]

  PdfViewer* = ref object of Container
    doc: FPDF_DOCUMENT
    data: PdfData
    path*: string
    modified*: bool
    gen: int
    sizes: seq[tuple[w, h: float]]
    outline*: seq[tuple[level: int, title: string, page: int]]
    zoom*: float
    fitMode*: int                # 0 free zoom, 1 fit width, 2 fit page.
    current*: int                # current page (0-based).
    tool*: PdfTool
    view: PdfPageView
    sidebar: PdfSidebar
    pageButton: PdfToolButton
    zoomLabel, status: Label
    toolButtons: seq[PdfToolButton]
    jobs: seq[RenderJob]         # under pdfLock.
    done: seq[RenderDone]        # under pdfLock.
    textures: seq[tuple[key: string, tex: SDL_Texture, w, h: int]]
    flushTextures: bool
    lastZoom: float
    pendingGoto: int
    hitPage, hitIndex: int
    hitRects: seq[PageRect]
    selPage, selStart: int
    selRects: seq[PageRect]
    selText*: string
    cachedPage: FPDF_PAGE
    cachedIndex, cachedGen: int
    findReq: FindRequest
    message*: string
    showSidebar*: bool

  CmdArg = tuple[id: ControlId, cmd: string, page: int, x, y: float]

var
  queueLock: Lock                                                 # jobs / done queues of every viewer.
  renderViewers: seq[PdfViewer]                                   # under queueLock.
  renderThread: Thread[void]
  renderStarted: bool
  cmdThreads: seq[ptr Thread[CmdArg]]                             # under guarded.

initLock(queueLock)

# PDFium helpers (call with pdfLock held)

proc dropCache(v: PdfViewer) =
  if v.cachedPage != nil: FPDF_ClosePage(v.cachedPage)
  v.cachedPage = nil
  v.cachedIndex = -1

proc pageHandle(v: PdfViewer, i: int): FPDF_PAGE =
  if v.doc == nil or i < 0 or i >= v.sizes.len: return nil
  if v.cachedPage != nil and v.cachedIndex == i and v.cachedGen == v.gen: return v.cachedPage
  v.dropCache()
  v.cachedPage = FPDF_LoadPage(v.doc, i.cint)
  v.cachedIndex = i
  v.cachedGen = v.gen
  v.cachedPage

proc toDevice(v: PdfViewer, i: int, box: Rect, px, py: float): tuple[x, y: float] =
  let p = v.pageHandle(i)
  if p == nil: return (box.x, box.y)
  var dx, dy: cint
  discard FPDF_PageToDevice(p, 0, 0, box.w.cint, box.h.cint, 0, px, py, addr dx, addr dy)
  (box.x + float(dx), box.y + float(dy))

proc toPage(v: PdfViewer, i: int, box: Rect, x, y: float): tuple[x, y: float] =
  let p = v.pageHandle(i)
  if p == nil: return (0.0, 0.0)
  var px, py: cdouble
  discard FPDF_DeviceToPage(p, 0, 0, box.w.cint, box.h.cint, 0, cint(x - box.x), cint(y - box.y), addr px, addr py)
  (float(px), float(py))

proc titleOf(bm: FPDF_BOOKMARK): string =
  let n = FPDFBookmark_GetTitle(bm, nil, 0)
  if n <= 2: return ""
  var buf = newSeq[uint16](int(n) div 2 + 1)
  discard FPDFBookmark_GetTitle(bm, buf[0].addr, n)
  fromUtf16(buf)

proc walkOutline(v: PdfViewer, parent: FPDF_BOOKMARK, level: int) =
  if level > 16: return
  var b = FPDFBookmark_GetFirstChild(v.doc, parent)
  var guard = 0
  while b != nil and guard < 5000:
    var dest = FPDFBookmark_GetDest(v.doc, b)
    if dest == nil and FPDFBookmark_GetAction != nil and FPDFAction_GetDest != nil:
      let act = FPDFBookmark_GetAction(b)
      if act != nil: dest = FPDFAction_GetDest(v.doc, act)
    let page = if dest != nil: int(FPDFDest_GetDestPageIndex(v.doc, dest)) else: -1
    v.outline.add((level, titleOf(b), page))
    v.walkOutline(b, level + 1)
    b = FPDFBookmark_GetNextSibling(v.doc, b)
    inc guard

proc refreshStructure(v: PdfViewer) =
  # Page sizes and outline after opening or any structural change; invalidates renders.
  v.dropCache()
  inc v.gen
  withLock queueLock:
    v.jobs.setLen(0)
    v.done.setLen(0)
  v.flushTextures = true
  v.sizes.setLen(0)
  v.outline.setLen(0)
  v.hitRects.setLen(0)
  v.hitPage = -1
  v.selRects.setLen(0)
  v.selPage = -1
  v.selText = ""
  if v.doc == nil: return
  let n = int(FPDF_GetPageCount(v.doc))
  for i in 0 ..< n:
    var w, h: cdouble
    if FPDF_GetPageSizeByIndex != nil and FPDF_GetPageSizeByIndex(v.doc, i.cint, addr w, addr h) != 0:
      v.sizes.add((float(w), float(h)))
    else:
      let p = FPDF_LoadPage(v.doc, i.cint)
      if p != nil:
        v.sizes.add((float(FPDF_GetPageWidth(p)), float(FPDF_GetPageHeight(p))))
        FPDF_ClosePage(p)
      else: v.sizes.add((595.0, 842.0))
  v.walkOutline(nil, 0)
  v.current = clamp(v.current, 0, max(0, n - 1))

proc closeDoc(v: PdfViewer) =
  v.dropCache()
  if v.doc != nil: FPDF_CloseDocument(v.doc)
  v.doc = nil
  v.data = nil

proc renderPage(v: PdfViewer, page, w, h: int): tuple[stride: int, pixels: seq[byte]] =
  let p = FPDF_LoadPage(v.doc, page.cint)
  if p == nil: return
  let bmp = FPDFBitmap_Create(w.cint, h.cint, 1)
  if bmp != nil:
    FPDFBitmap_FillRect(bmp, 0, 0, w.cint, h.cint, 0xFFFFFFFF'u.culong)
    FPDF_RenderPageBitmap(bmp, p, 0, 0, w.cint, h.cint, 0, FPDF_ANNOT)
    let stride = int(FPDFBitmap_GetStride(bmp))
    let buf = FPDFBitmap_GetBuffer(bmp)
    if buf != nil and stride > 0:
      result.stride = stride
      result.pixels = newSeq[byte](stride * h)
      copyMem(result.pixels[0].addr, buf, stride * h)
    FPDFBitmap_Destroy(bmp)
  FPDF_ClosePage(p)

proc renderLoop() {.thread.} =
  # Background renderer shared by every viewer.
  {.cast(gcsafe).}:
    while true:
      var worked: PdfViewer = nil
      var job: RenderJob
      withLock queueLock:
        for v in renderViewers:
          if v.jobs.len > 0:
            job = v.jobs[0]
            v.jobs.delete(0)
            worked = v
            break
      if worked != nil:
        var r: tuple[stride: int, pixels: seq[byte]]
        withLock pdfLock:
          if worked.doc != nil and job.gen == worked.gen:
            r = worked.renderPage(job.page, job.w, job.h)
        if r.pixels.len > 0:
          withLock queueLock: worked.done.add((job.key, job.w, job.h, r.stride, r.pixels))
      if worked == nil: sleep(10)
      else:
        markDirty(worked)
        wakeUI()

# operations (gui lock held by the caller)

proc changedBy(v: PdfViewer, what: string) =
  v.modified = true
  emit(v, evChange, text = what)

proc loadData(v: PdfViewer, data: PdfData, path, password: string): tuple[ok, needPassword: bool, msg: string] =
  withLock pdfLock:
    if not loadPdfium(): return (false, false, pdfiumError)
    if data.bytes.len == 0: return (false, false, "empty file")
    let d = FPDF_LoadMemDocument(data.bytes[0].addr, data.bytes.len.cint,
                                 (if password.len > 0: password.cstring else: nil))
    if d == nil:
      let err = FPDF_GetLastError()
      if err == FPDF_ERR_PASSWORD: return (false, true, "password required")
      return (false, false, "cannot read this PDF (error " & $err & ")")
    v.closeDoc()
    v.doc = d
    v.data = data
    v.path = path
    v.modified = false
    v.current = 0
    v.pendingGoto = 0
    v.refreshStructure()
  v.message = ""
  emit(v, evChange, text = "open")
  (true, false, "")

proc newDoc(v: PdfViewer, w = 595.0, h = 842.0): bool =
  withLock pdfLock:
    if not loadPdfium():
      v.message = pdfiumError
      return false
    let d = FPDF_CreateNewDocument()
    if d == nil: return false
    let p = FPDFPage_New(d, 0, w, h)
    if p != nil: FPDF_ClosePage(p)
    v.closeDoc()
    v.doc = d
    v.path = ""
    v.current = 0
    v.pendingGoto = 0
    v.refreshStructure()
  v.changedBy("new")
  true

type Writer = object
  base: FPDF_FILEWRITE
  buf: ptr string

proc writeBlock(pThis: ptr FPDF_FILEWRITE, data: pointer, size: culong): cint {.cdecl.} =
  let w = cast[ptr Writer](pThis)
  let old = w.buf[].len
  w.buf[].setLen(old + int(size))
  if size > 0: copyMem(w.buf[][old].addr, data, int(size))
  1

proc saveTo(v: PdfViewer, path: string): bool =
  var bytes = ""
  withLock pdfLock:
    if v.doc == nil: return false
    v.dropCache()
    var w = Writer(base: FPDF_FILEWRITE(version: 1, writeBlock: writeBlock), buf: addr bytes)
    if FPDF_SaveAsCopy(v.doc, addr w.base, FPDF_NO_INCREMENTAL) == 0: return false
  try:
    writeFile(path, bytes)
  except CatchableError:
    return false
  v.path = path
  v.modified = false
  emit(v, evChange, text = "save")
  true

proc rotatePage(v: PdfViewer, i, quarter: int) =
  withLock pdfLock:
    let p = v.pageHandle(i)
    if p == nil: return
    FPDFPage_SetRotation(p, cint((int(FPDFPage_GetRotation(p)) + quarter + 4) mod 4))
    v.refreshStructure()
  v.changedBy("rotate")

proc deletePage(v: PdfViewer, i: int) =
  withLock pdfLock:
    if v.doc == nil or i < 0 or i >= v.sizes.len or v.sizes.len <= 1: return
    v.dropCache()
    FPDFPage_Delete(v.doc, i.cint)
    v.refreshStructure()
  v.changedBy("delete")

proc movePage(v: PdfViewer, i, to: int): bool =
  withLock pdfLock:
    if v.doc == nil or FPDF_MovePages == nil or i < 0 or i >= v.sizes.len: return false
    let dest = clamp(to, 0, v.sizes.len - 1)
    if dest == i: return false
    v.dropCache()
    var idx = i.cint
    if FPDF_MovePages(v.doc, addr idx, 1, dest.cint) == 0: return false
    v.refreshStructure()
    v.current = dest
    v.pendingGoto = dest
  v.changedBy("move")
  true

proc insertBlank(v: PdfViewer, at: int, w, h: float) =
  withLock pdfLock:
    if v.doc == nil: return
    v.dropCache()
    let p = FPDFPage_New(v.doc, clamp(at, 0, v.sizes.len).cint, w, h)
    if p != nil: FPDF_ClosePage(p)
    v.refreshStructure()
    v.current = clamp(at, 0, v.sizes.len - 1)
    v.pendingGoto = v.current
  v.changedBy("insert")

proc importPages(v: PdfViewer, src: PdfData, pageRange: string, at: int): string =
  # Inserts pages of another PDF before page `at` (0-based); "" on success, else a message.
  withLock pdfLock:
    if v.doc == nil: return "no document"
    if src.bytes.len == 0: return "empty file"
    let s = FPDF_LoadMemDocument(src.bytes[0].addr, src.bytes.len.cint, nil)
    if s == nil: return "cannot read the source PDF"
    v.dropCache()
    let ok = FPDF_ImportPages(v.doc, s, (if pageRange.strip.len > 0: pageRange.strip.cstring else: nil),
                              clamp(at, 0, v.sizes.len).cint)
    FPDF_CloseDocument(s)
    if ok == 0: return "the pages could not be imported (check the page range)"
    v.refreshStructure()
    v.current = clamp(at, 0, v.sizes.len - 1)
    v.pendingGoto = v.current
  v.changedBy("import")
  ""

proc addText(v: PdfViewer, i: int, x, y: float, text: string, size: float, c: Color) =
  withLock pdfLock:
    let p = v.pageHandle(i)
    if p == nil: return
    var yy = y
    for line in text.splitLines:
      let obj = FPDFPageObj_NewTextObj(v.doc, "Helvetica", size.cfloat)
      if obj == nil: continue
      var w = toUtf16z(line)
      discard FPDFText_SetText(obj, w[0].addr)
      discard FPDFPageObj_SetFillColor(obj, c.r.cuint, c.g.cuint, c.b.cuint, c.a.cuint)
      FPDFPageObj_Transform(obj, 1, 0, 0, 1, x, yy)
      FPDFPage_InsertObject(p, obj)
      yy -= size * 1.25
    discard FPDFPage_GenerateContent(p)
    v.refreshStructure()
  v.changedBy("text")

proc addRect(v: PdfViewer, i: int, r: PageRect, c: Color, width: float) =
  withLock pdfLock:
    let p = v.pageHandle(i)
    if p == nil: return
    let obj = FPDFPageObj_CreateNewRect(r.l.cfloat, r.b.cfloat, (r.r - r.l).cfloat, (r.t - r.b).cfloat)
    if obj == nil: return
    discard FPDFPageObj_SetStrokeColor(obj, c.r.cuint, c.g.cuint, c.b.cuint, c.a.cuint)
    discard FPDFPageObj_SetStrokeWidth(obj, width.cfloat)
    discard FPDFPath_SetDrawMode(obj, 0, 1)
    FPDFPage_InsertObject(p, obj)
    discard FPDFPage_GenerateContent(p)
    v.refreshStructure()
  v.changedBy("rectangle")

proc addNote(v: PdfViewer, i: int, x, y: float, text: string) =
  withLock pdfLock:
    let p = v.pageHandle(i)
    if p == nil: return
    let a = FPDFPage_CreateAnnot(p, FPDF_ANNOT_TEXT)
    if a == nil: return
    var r = FS_RECTF(left: x.cfloat, top: y.cfloat, right: cfloat(x + 22), bottom: cfloat(y - 22))
    discard FPDFAnnot_SetRect(a, addr r)
    discard FPDFAnnot_SetColor(a, FPDFANNOT_COLORTYPE_Color, 255, 205, 40, 255)
    var w = toUtf16z(text)
    discard FPDFAnnot_SetStringValue(a, "Contents", w[0].addr)
    FPDFPage_CloseAnnot(a)
    v.refreshStructure()
  v.changedBy("note")

proc highlightSelection(v: PdfViewer, c: Color): bool =
  if v.selPage < 0 or v.selRects.len == 0: return false
  let page = v.selPage
  let rects = v.selRects
  withLock pdfLock:
    let p = v.pageHandle(page)
    if p == nil: return false
    let a = FPDFPage_CreateAnnot(p, FPDF_ANNOT_HIGHLIGHT)
    if a == nil: return false
    var bound = rects[0]
    for r in rects:
      var q = FS_QUADPOINTSF(x1: r.l.cfloat, y1: r.t.cfloat, x2: r.r.cfloat, y2: r.t.cfloat,
                             x3: r.l.cfloat, y3: r.b.cfloat, x4: r.r.cfloat, y4: r.b.cfloat)
      discard FPDFAnnot_AppendAttachmentPoints(a, addr q)
      bound = (min(bound.l, r.l), max(bound.t, r.t), max(bound.r, r.r), min(bound.b, r.b))
    var br = FS_RECTF(left: bound.l.cfloat, top: bound.t.cfloat, right: bound.r.cfloat, bottom: bound.b.cfloat)
    discard FPDFAnnot_SetRect(a, addr br)
    discard FPDFAnnot_SetColor(a, FPDFANNOT_COLORTYPE_Color, c.r.cuint, c.g.cuint, c.b.cuint, c.a.cuint)
    FPDFPage_CloseAnnot(a)
    v.refreshStructure()
  v.changedBy("highlight")
  true

proc textRects(tp: FPDF_TEXTPAGE, start, count: int): seq[PageRect] =
  let n = int(FPDFText_CountRects(tp, start.cint, count.cint))
  for k in 0 ..< n:
    var l, t, r, b: cdouble
    if FPDFText_GetRect(tp, k.cint, addr l, addr t, addr r, addr b) != 0:
      result.add((float(l), float(t), float(r), float(b)))

proc findText(v: PdfViewer, text: string, matchCase, wholeWord, backwards: bool): bool =
  # Next (or previous) occurrence from the last hit, wrapping around the document.
  if text.len == 0: return false
  var flags: culong = 0
  if matchCase: flags = flags or FPDF_MATCHCASE
  if wholeWord: flags = flags or FPDF_MATCHWHOLEWORD
  var what = toUtf16z(text)
  withLock pdfLock:
    let n = v.sizes.len
    if v.doc == nil or n == 0: return false
    let startPage = if v.hitPage >= 0: v.hitPage else: v.current
    for k in 0 .. n:
      let p = ((startPage + (if backwards: -k else: k)) mod n + n) mod n
      let page = FPDF_LoadPage(v.doc, p.cint)
      if page == nil: continue
      let tp = FPDFText_LoadPage(page)
      var startIdx = if backwards: -1 else: 0
      if k == 0 and v.hitPage == p: startIdx = if backwards: v.hitIndex - 1 else: v.hitIndex + 1
      if k == 0 and v.hitPage == p and backwards and startIdx < 0: startIdx = 0
      var found = false
      if tp != nil:
        let h = FPDFText_FindStart(tp, what[0].addr, flags, startIdx.cint)
        if h != nil:
          let ok = if backwards: FPDFText_FindPrev(h) else: FPDFText_FindNext(h)
          if ok != 0:
            let idx = int(FPDFText_GetSchResultIndex(h))
            let cnt = int(FPDFText_GetSchCount(h))
            if not (k == n and ((not backwards and idx >= v.hitIndex) or (backwards and idx <= v.hitIndex))):
              v.hitPage = p
              v.hitIndex = idx
              v.hitRects = textRects(tp, idx, cnt)
              v.current = p
              v.pendingGoto = p
              found = true
          FPDFText_FindClose(h)
        FPDFText_ClosePage(tp)
      FPDF_ClosePage(page)
      if found: return true
  false

proc selectText(v: PdfViewer, page, a, b: int) =
  # Selection between two character indices of a page (pdfLock held).
  let p = v.pageHandle(page)
  if p == nil: return
  let tp = FPDFText_LoadPage(p)
  if tp == nil: return
  let lo = min(a, b)
  let count = abs(b - a) + 1
  v.selPage = page
  v.selRects = textRects(tp, lo, count)
  var buf = newSeq[uint16](count + 2)
  discard FPDFText_GetText(tp, lo.cint, count.cint, buf[0].addr)
  v.selText = fromUtf16(buf)
  FPDFText_ClosePage(tp)

proc charAt(v: PdfViewer, page: int, px, py: float): int =
  let p = v.pageHandle(page)
  if p == nil: return -1
  let tp = FPDFText_LoadPage(p)
  if tp == nil: return -1
  result = int(FPDFText_GetCharIndexAtPos(tp, px, py, 6, 6))
  FPDFText_ClosePage(tp)

proc metaText(v: PdfViewer, tag: string): string =
  let n = FPDF_GetMetaText(v.doc, tag.cstring, nil, 0)
  if n <= 2: return ""
  var buf = newSeq[uint16](int(n) div 2 + 1)
  discard FPDF_GetMetaText(v.doc, tag.cstring, buf[0].addr, n)
  fromUtf16(buf)

proc info(v: PdfViewer): seq[tuple[key, value: string]] =
  withLock pdfLock:
    if v.doc == nil: return
    result.add(("File", (if v.path.len > 0: v.path else: "(not saved)")))
    result.add(("Pages", $v.sizes.len))
    var ver: cint
    if FPDF_GetFileVersion(v.doc, addr ver) != 0: result.add(("PDF version", $(ver div 10) & "." & $(ver mod 10)))
    if v.sizes.len > 0:
      result.add(("Page size", $int(round(v.sizes[0].w)) & " x " & $int(round(v.sizes[0].h)) & " pt"))
    for tag in ["Title", "Author", "Subject", "Keywords", "Creator", "Producer", "CreationDate", "ModDate"]:
      let t = v.metaText(tag)
      if t.len > 0: result.add((tag, t))
    if v.data != nil: result.add(("Size", formatSize(v.data.bytes.len)))
    result.add(("Modified", (if v.modified: "yes" else: "no")))

# thread-safe API

proc pdfAvailable*(): bool =
  # True when the PDFium library can be loaded.
  withLock pdfLock: result = loadPdfium()

proc pdfError*(): string =
  withLock pdfLock: result = pdfiumError

proc pdfOpen*(id: ControlId, path: string, password = ""): bool =
  # Opens a PDF file. If it is protected and `password` is empty, asks for the password
  # (when called from a handler thread).
  var data = PdfData()
  try:
    data.bytes = readFile(path)
  except CatchableError:
    return false
  var pw = password
  while true:
    var r: tuple[ok, needPassword: bool, msg: string]
    withControl(id, PdfViewer, v):
      r = v.loadData(data, normalizedPath(absolutePath(path)), pw)
      if not r.ok and not r.needPassword: v.message = r.msg
    if r.ok: return true
    if not r.needPassword: return false
    pw = prompt(iconQuestion, "\"" & extractFilename(path) & "\" is protected.\nPassword:", "", "Password")
    if pw.len == 0: return false

proc pdfNew*(id: ControlId, width = 595.0, height = 842.0): bool =
  # New document with one blank page (default A4, in points).
  withControl(id, PdfViewer, v): result = v.newDoc(width, height)

proc pdfSave*(id: ControlId, path = ""): bool =
  # Saves to `path`, or to the current file when empty.
  withControl(id, PdfViewer, v):
    let target = if path.len > 0: path else: v.path
    if target.len > 0: result = v.saveTo(target)

proc pdfClose*(id: ControlId) =
  withControl(id, PdfViewer, v):
    withLock pdfLock:
      v.closeDoc()
      v.refreshStructure()
    v.path = ""
    v.modified = false

proc pdfPath*(id: ControlId): string =
  readControl(id, PdfViewer, v): result = v.path

proc pdfModified*(id: ControlId): bool =
  readControl(id, PdfViewer, v): result = v.modified

proc pdfPageCount*(id: ControlId): int =
  readControl(id, PdfViewer, v): result = v.sizes.len

proc pdfCurrentPage*(id: ControlId): int =
  readControl(id, PdfViewer, v): result = v.current + 1

proc pdfGoto*(id: ControlId, page: int) =
  withControl(id, PdfViewer, v):
    if v.sizes.len > 0:
      v.current = clamp(page - 1, 0, v.sizes.len - 1)
      v.pendingGoto = v.current

proc pdfSetZoom*(id: ControlId, zoom: float) =
  # Zoom factor (1.0 = one pixel per point); disables the fit modes.
  withControl(id, PdfViewer, v):
    v.zoom = clamp(zoom, 0.05, 8.0)
    v.fitMode = 0

proc pdfSetFit*(id: ControlId, mode: int) =
  # 1 = fit width, 2 = fit page, 0 = keep the zoom factor.
  withControl(id, PdfViewer, v): v.fitMode = clamp(mode, 0, 2)

proc pdfSetTool*(id: ControlId, tool: PdfTool) =
  withControl(id, PdfViewer, v):
    v.tool = tool
    for b in v.toolButtons: b.isDefault = b.cmd == toLowerAscii($tool)

proc pdfRotatePage*(id: ControlId, page: int, quarterTurns = 1) =
  withControl(id, PdfViewer, v): v.rotatePage(page - 1, quarterTurns)

proc pdfDeletePage*(id: ControlId, page: int) =
  withControl(id, PdfViewer, v): v.deletePage(page - 1)

proc pdfMovePage*(id: ControlId, page, toPage: int): bool =
  # Moves a page (1-based) to a new position (needs a PDFium with FPDF_MovePages).
  withControl(id, PdfViewer, v): result = v.movePage(page - 1, toPage - 1)

proc pdfInsertBlankPage*(id: ControlId, beforePage: int, width = 595.0, height = 842.0) =
  withControl(id, PdfViewer, v): v.insertBlank(beforePage - 1, width, height)

proc pdfImportPages*(id: ControlId, sourcePath, pageRange: string, beforePage: int): string =
  # Merges pages of another PDF: `pageRange` like "1,3,5-7" ("" = every page), inserted
  # before `beforePage` (1-based; pageCount + 1 = at the end). Returns "" or an error.
  var src = PdfData()
  try:
    src.bytes = readFile(sourcePath)
  except CatchableError:
    return "cannot read " & sourcePath
  result = "no PDF viewer"
  withControl(id, PdfViewer, v): result = v.importPages(src, pageRange, beforePage - 1)

proc pdfAddText*(id: ControlId, page: int, x, y: float, text: string, size = 14.0, color = Black) =
  # Adds text at (x, y) in PDF points (origin bottom-left); several lines allowed.
  withControl(id, PdfViewer, v): v.addText(page - 1, x, y, text, size, color)

proc pdfAddNote*(id: ControlId, page: int, x, y: float, text: string) =
  withControl(id, PdfViewer, v): v.addNote(page - 1, x, y, text)

proc pdfAddRect*(id: ControlId, page: int, left, bottom, width, height: float,
                 color = hex"#D13438", lineWidth = 2.0) =
  withControl(id, PdfViewer, v):
    v.addRect(page - 1, (left, bottom + height, left + width, bottom), color, lineWidth)

proc pdfHighlightSelection*(id: ControlId, color = hex"#FFE14D"): bool =
  withControl(id, PdfViewer, v): result = v.highlightSelection(color)

proc pdfSelectedText*(id: ControlId): string =
  readControl(id, PdfViewer, v): result = v.selText

proc pdfFind*(id: ControlId, text: string, matchCase = false, wholeWord = false, backwards = false): bool =
  withControl(id, PdfViewer, v): result = v.findText(text, matchCase, wholeWord, backwards)

proc pdfInfo*(id: ControlId): seq[tuple[key, value: string]] =
  withControl(id, PdfViewer, v): result = v.info()

proc pdfOutline*(id: ControlId): seq[tuple[level: int, title: string, page: int]] =
  readControl(id, PdfViewer, v): result = v.outline

# commands with dialogs (own thread)

proc folderOf(id: ControlId): string =
  let p = pdfPath(id)
  if p.len > 0: p.parentDir else: getCurrentDir()

proc confirmDiscard(id: ControlId): bool =
  not pdfModified(id) or
    confirm(iconExclamation, "The document has unsaved changes.\nDiscard them?", "PDF") == drOk

proc runCommandThread(a: CmdArg) =
  let id = a.id
  case a.cmd
  of "open":
    if not confirmDiscard(id): return
    let p = openFileDialog("Open PDF", folderOf(id), "PDF files|*.pdf\nAll files|*")
    if p.len > 0 and not pdfOpen(id, p):
      var msg = ""
      readControl(id, PdfViewer, v): msg = v.message
      alert(iconStop, "Cannot open \"" & extractFilename(p) & "\".\n" & msg, "PDF")
  of "new":
    if confirmDiscard(id) and not pdfNew(id): alert(iconStop, pdfError(), "PDF")
  of "save", "saveAs":
    var path = if a.cmd == "save": pdfPath(id) else: ""
    if path.len == 0:
      let cur = pdfPath(id)
      path = saveFileDialog("Save PDF As", folderOf(id),
                            (if cur.len > 0: extractFilename(cur) else: "document.pdf"), "PDF files|*.pdf")
    if path.len > 0 and not pdfSave(id, path): alert(iconStop, "Cannot save \"" & path & "\".", "PDF")
  of "goto":
    let n = pdfPageCount(id)
    if n == 0: return
    let s = prompt(iconQuestion, "Go to page (1 - " & $n & "):", $pdfCurrentPage(id), "Go to Page")
    try: pdfGoto(id, parseInt(s.strip))
    except ValueError: discard
  of "find", "findNext":
    var req: FindRequest
    readControl(id, PdfViewer, v): req = v.findReq
    if a.cmd == "findNext" and req.findText.len > 0:
      if not pdfFind(id, req.findText, req.matchCase, req.wholeWord, req.backwards):
        alert(iconInformation, "\"" & req.findText & "\" not found.", "Find")
      return
    while findDialog(req) == drOk:
      withControl(id, PdfViewer, v): v.findReq = req
      if not pdfFind(id, req.findText, req.matchCase, req.wholeWord, req.backwards):
        alert(iconInformation, "\"" & req.findText & "\" not found.", "Find")
        break
  of "insert":
    let n = pdfPageCount(id)
    if n == 0: return
    let src = openFileDialog("Insert Pages From PDF", folderOf(id), "PDF files|*.pdf")
    if src.len == 0: return
    let pages = prompt(iconQuestion, "Pages of \"" & extractFilename(src) &
                       "\" to insert (e.g. 1,3,5-7; empty = all):", "", "Insert Pages")
    let pos = prompt(iconQuestion, "Insert before page (1 - " & $(n + 1) & ", " & $(n + 1) & " = at the end):",
                     $(pdfCurrentPage(id) + 1), "Insert Pages")
    var before = n + 1
    try: before = parseInt(pos.strip)
    except ValueError: return
    let err = pdfImportPages(id, src, pages, clamp(before, 1, n + 1))
    if err.len > 0: alert(iconStop, err, "Insert Pages")
  of "addText":
    let t = prompt(iconQuestion, "Text to add on page " & $(a.page + 1) & ":", "", "Add Text")
    if t.len > 0: pdfAddText(id, a.page + 1, a.x, a.y, t)
  of "addNote":
    let t = prompt(iconQuestion, "Note:", "", "Add Note")
    if t.len > 0: pdfAddNote(id, a.page + 1, a.x, a.y, t)
  of "info":
    let items = pdfInfo(id)
    if items.len == 0: return
    var lines: seq[string]
    for (k, v) in items: lines.add k & ": " & v
    alert(iconInformation, lines.join("\n"), "Document Information")
  else: discard

proc cmdWorker(a: CmdArg) {.thread.} =
  {.cast(gcsafe).}: runCommandThread(a)

proc spawnCommand(v: PdfViewer, cmd: string, page = -1, x = 0.0, y = 0.0) =
  {.cast(gcsafe).}:
    var i = 0
    while i < cmdThreads.len:
      if not running(cmdThreads[i][]):
        joinThread(cmdThreads[i][])
        deallocShared(cmdThreads[i])
        cmdThreads.del(i)
      else: inc i
    let th = cast[ptr Thread[CmdArg]](allocShared0(sizeof(Thread[CmdArg])))
    createThread(th[], cmdWorker, (v.id, cmd, page, x, y))
    cmdThreads.add th

proc command(v: PdfViewer, cmd: string) =
  # Commands of the bars and the keyboard (UI thread, gui lock held).
  let n = v.sizes.len
  case cmd
  of "first", "prev", "next", "last":
    if n == 0: return
    v.current = case cmd
                of "first": 0
                of "prev": max(0, v.current - 1)
                of "next": min(n - 1, v.current + 1)
                else: n - 1
    v.pendingGoto = v.current
  of "zoomIn", "zoomOut":
    v.zoom = clamp((if v.lastZoom > 0: v.lastZoom else: 1.0) * (if cmd == "zoomIn": 1.25 else: 0.8), 0.1, 8.0)
    v.fitMode = 0
  of "fitWidth": v.fitMode = 1
  of "fitPage": v.fitMode = 2
  of "actual":
    v.zoom = 1.0
    v.fitMode = 0
  of "select", "hand", "text", "note", "rectangle":
    v.tool = case cmd
             of "hand": ptHand
             of "text": ptText
             of "note": ptNote
             of "rectangle": ptRect
             else: ptSelect
    for b in v.toolButtons: b.isDefault = b.cmd == cmd
  of "sidebar":
    v.showSidebar = not v.showSidebar
    v.sidebar.visible = v.showSidebar
  of "rotate": v.rotatePage(v.current, 1)
  of "delete": v.deletePage(v.current)
  of "up": discard v.movePage(v.current, v.current - 1)
  of "down": discard v.movePage(v.current, v.current + 1)
  of "blank":
    let s = if n > 0: v.sizes[v.current] else: (w: 595.0, h: 842.0)
    v.insertBlank(v.current + 1, s.w, s.h)
  of "highlight":
    if not v.highlightSelection(hex"#FFE14D"): v.message = "Select some text first (Select tool)."
  of "copy":
    if v.selText.len > 0: discard SDL_SetClipboardText(v.selText.cstring)
  of "open", "new", "save", "saveAs", "goto", "find", "findNext", "insert", "info":
    v.spawnCommand(cmd)
  else: discard
  markDirty(v)

# texture cache (UI thread)

proc pump(v: PdfViewer, d: Drawing) =
  if v.flushTextures:
    for t in v.textures: SDL_DestroyTexture(t.tex)
    v.textures.setLen(0)
    v.flushTextures = false
  var ready: seq[RenderDone]
  withLock queueLock:
    ready = v.done
    v.done.setLen(0)
  let prefix = $v.gen & "/"
  for r in ready.mitems:
    if not r.key.startsWith(prefix) or r.pixels.len == 0: continue
    let tex = SDL_CreateTexture(d.ren, SDL_PIXELFORMAT_ARGB8888, SDL_TEXTUREACCESS_STATIC, r.w.cint, r.h.cint)
    if tex == nil: continue
    discard SDL_UpdateTexture(tex, nil, r.pixels[0].addr, r.stride.cint)
    v.textures.add((r.key, tex, r.w, r.h))
  while v.textures.len > 48:
    SDL_DestroyTexture(v.textures[0].tex)
    v.textures.delete(0)

proc textureFor(v: PdfViewer, page, w, h: int): SDL_Texture =
  # Cached texture of a page at a pixel size, or nil (a render is then requested).
  let key = $v.gen & "/" & $page & "/" & $w
  for i in 0 ..< v.textures.len:
    if v.textures[i].key == key:
      let t = v.textures[i]
      v.textures.delete(i)
      v.textures.add t                    # most recently used last
      return t.tex
  let big = w > 200
  withLock queueLock:
    var queued = false
    for j in countdown(v.jobs.high, 0):
      if v.jobs[j].key == key: queued = true
      elif v.jobs[j].page == page and (v.jobs[j].w > 200) == big: v.jobs.delete(j)   # stale zoom
    if not queued:
      if big: v.jobs.insert((key, v.gen, page, w, h), 0)                             # pages first
      else: v.jobs.add((key, v.gen, page, w, h))
  nil

# tool buttons

proc newToolButton(v: PdfViewer, caption, cmd, tip: string): PdfToolButton =
  result = PdfToolButton(viewer: v, cmd: cmd)
  initControl(result, caption)
  result.flat = true
  result.stretch = false
  result.tooltip = tip

method isDefaultButton*(b: PdfToolButton): bool = false
method onMouse*(b: PdfToolButton, e: MouseEvent) =
  if e.action == maRelease and e.button == mbLeft and b.rect.containsPoint(e.x, e.y) and b.isActive:
    b.viewer.command(b.cmd)

# page view

proc pageAt(pv: PdfPageView, x, y: float): int =
  for i, r in pv.screen:
    if r.containsPoint(x, y): return i
  -1

method acceptsText*(pv: PdfPageView): bool = false

method mouseCursor*(pv: PdfPageView, x, y: float): int =
  case pv.viewer.tool
  of ptHand: SDL_SYSTEM_CURSOR_MOVE
  of ptSelect: (if pv.pageAt(x, y) >= 0: SDL_SYSTEM_CURSOR_TEXT else: SDL_SYSTEM_CURSOR_DEFAULT)
  else: SDL_SYSTEM_CURSOR_POINTER

method draw*(pv: PdfPageView, d: Drawing, t: Theme) =
  let v = pv.viewer
  v.pump(d)
  let r = pv.rect
  d.fillRect(r, mix(t.windowBg, Black, (if t.dark: 0.35 else: 0.14)))
  let n = v.sizes.len
  if v.doc == nil or n == 0:
    let msg = if v.message.len > 0: v.message else: "Open a PDF (Open) or create a new document (New)."
    d.textIn(r, msg, t.textSecondary, alCenter)
    v.pageButton.caption = "0 / 0"
    return
  var maxW = 1.0
  for s in v.sizes: maxW = max(maxW, s.w)
  let availW = max(50.0, r.w - 40)
  let availH = max(50.0, r.h - 24)
  var z = v.zoom
  if v.fitMode == 1: z = availW / maxW
  elif v.fitMode == 2:
    let s = v.sizes[clamp(v.current, 0, n - 1)]
    z = min(availW / s.w, availH / s.h)
  z = clamp(z, 0.05, 8.0)
  if v.lastZoom > 0 and abs(z - v.lastZoom) > 1e-6 and v.pendingGoto < 0: v.pendingGoto = v.current
  v.lastZoom = z
  v.zoomLabel.caption = $int(round(z * 100)) & " %"
  pv.boxes.setLen(n)
  pv.screen.setLen(n)
  var y = 12.0
  var totalW = 0.0
  for i, s in v.sizes:
    pv.boxes[i] = rect(0, y, round(s.w * z), round(s.h * z))
    y += pv.boxes[i].h + 12
    totalW = max(totalW, pv.boxes[i].w + 40)
  pv.totalH = y
  if v.pendingGoto >= 0 and v.pendingGoto < n:
    pv.scrollY = pv.boxes[v.pendingGoto].y - 8
    v.pendingGoto = -1
  pv.scrollY = clamp(pv.scrollY, 0.0, max(0.0, pv.totalH - r.h))
  pv.scrollX = clamp(pv.scrollX, 0.0, max(0.0, totalW - r.w))
  d.pushClip(r)
  var best = -1
  let mid = r.y + r.h / 3
  for i in 0 ..< n:
    let b = pv.boxes[i]
    let dr = rect(r.x + max(20.0, (r.w - b.w) / 2) - pv.scrollX, r.y + b.y - pv.scrollY, b.w, b.h)
    pv.screen[i] = dr
    if dr.y <= mid and dr.y + dr.h + 12 > mid: best = i
    if dr.y > r.y + r.h or dr.y + dr.h < r.y: continue
    d.shadow(dr, 2, t.shadow)
    d.fillRect(dr, White)
    let pw = min(int(b.w), 5000)
    let ph = int(round(b.h * float(pw) / max(1.0, b.w)))
    let tex = v.textureFor(i, pw, ph)
    if tex != nil: d.drawTexture(tex, dr)
    else:
      # while rendering: show a smaller version if one is cached
      var shown = false
      for tx in v.textures:
        if tx.key.startsWith($v.gen & "/" & $i & "/"):
          d.drawTexture(tx.tex, dr)
          shown = true
          break
      if not shown: d.textIn(dr, "…", hex"#9A9A9A", alCenter)
    # search hit and selection
    withLock pdfLock:
      if v.hitPage == i:
        for hr in v.hitRects:
          let a = v.toDevice(i, dr, hr.l, hr.t)
          let c = v.toDevice(i, dr, hr.r, hr.b)
          d.fillRect(rect(min(a.x, c.x), min(a.y, c.y), abs(c.x - a.x), abs(c.y - a.y)), hex"#FF9F1C80")
      if v.selPage == i:
        for sr in v.selRects:
          let a = v.toDevice(i, dr, sr.l, sr.t)
          let c = v.toDevice(i, dr, sr.r, sr.b)
          d.fillRect(rect(min(a.x, c.x), min(a.y, c.y), abs(c.x - a.x), abs(c.y - a.y)), t.accent.withAlpha(90))
    if i == v.current: d.strokeRect(dr.shrink(-2), t.accent.withAlpha(150), 2)
  if pv.drawingRect and pv.rectPage >= 0:
    let ra = pv.rectA
    let rb = pv.rectB
    d.strokeRect(rect(min(ra.x, rb.x), min(ra.y, rb.y), abs(rb.x - ra.x), abs(rb.y - ra.y)), hex"#D13438", 2)
  d.popClip()
  if best >= 0 and best != v.current and not pv.panning:
    v.current = best
    emit(v, evSelection, index = best + 1)
  v.pageButton.caption = $(v.current + 1) & " / " & $n
  drawScrollIndicator(d, t, rect(r.x + r.w - 10, r.y + 2, 8, r.h - 4), pv.totalH, r.h, pv.scrollY)
  var line = ""
  if v.message.len > 0: line = v.message
  elif v.path.len > 0: line = extractFilename(v.path) & (if v.modified: " (modified)" else: "")
  else: line = "New document" & (if v.modified: " (not saved)" else: "")
  v.status.caption = line & "   ·   tool: " & $v.tool

method onMouse*(pv: PdfPageView, e: MouseEvent) =
  let v = pv.viewer
  if v.doc == nil: return
  case e.action
  of maPress:
    v.message = ""
    let i = pv.pageAt(e.x, e.y)
    if v.tool == ptHand or e.button == mbMiddle or i < 0:
      pv.panning = true
      pv.panX = e.x
      pv.panY = e.y
      pv.panSX = pv.scrollX
      pv.panSY = pv.scrollY
      return
    v.current = i
    var p: tuple[x, y: float]
    withLock pdfLock: p = v.toPage(i, pv.screen[i], e.x, e.y)
    case v.tool
    of ptSelect:
      withLock pdfLock:
        v.selStart = v.charAt(i, p.x, p.y)
        v.selPage = i
        v.selRects.setLen(0)
        v.selText = ""
        if e.clicks >= 2 and v.selStart >= 0: v.selectText(i, v.selStart, v.selStart)
      pv.selecting = v.selStart >= 0
    of ptText: v.spawnCommand("addText", i, p.x, p.y)
    of ptNote: v.spawnCommand("addNote", i, p.x, p.y)
    of ptRect:
      pv.drawingRect = true
      pv.rectPage = i
      pv.rectA = (e.x, e.y)
      pv.rectB = (e.x, e.y)
    of ptHand: discard
  of maMove:
    if pv.panning:
      pv.scrollX = pv.panSX - (e.x - pv.panX)
      pv.scrollY = pv.panSY - (e.y - pv.panY)
    elif pv.selecting and v.selPage >= 0 and v.selPage < pv.screen.len:
      withLock pdfLock:
        let p = v.toPage(v.selPage, pv.screen[v.selPage], e.x, e.y)
        let c = v.charAt(v.selPage, p.x, p.y)
        if c >= 0: v.selectText(v.selPage, v.selStart, c)
    elif pv.drawingRect:
      pv.rectB = (e.x, e.y)
  of maRelease:
    if pv.drawingRect and pv.rectPage >= 0:
      pv.drawingRect = false
      if abs(pv.rectB.x - pv.rectA.x) > 3 and abs(pv.rectB.y - pv.rectA.y) > 3:
        var a, b: tuple[x, y: float]
        withLock pdfLock:
          a = v.toPage(pv.rectPage, pv.screen[pv.rectPage], pv.rectA.x, pv.rectA.y)
          b = v.toPage(pv.rectPage, pv.screen[pv.rectPage], pv.rectB.x, pv.rectB.y)
        v.addRect(pv.rectPage, (min(a.x, b.x), max(a.y, b.y), max(a.x, b.x), min(a.y, b.y)), hex"#D13438", 2)
    pv.panning = false
    pv.selecting = false

method onWheel*(pv: PdfPageView, dx, dy: float): bool =
  let v = pv.viewer
  if (SDL_GetModState() and KMOD_CMD) != 0:
    v.command(if dy > 0: "zoomIn" else: "zoomOut")
    return true
  pv.scrollY -= dy * 60
  pv.scrollX -= dx * 60
  true

method onKey*(pv: PdfPageView, e: KeyEvent): bool =
  let v = pv.viewer
  let cmd = (e.mods and KMOD_CMD) != 0
  case e.key
  of SDLK_PAGEDOWN, SDLK_SPACE: pv.scrollY += pv.rect.h * 0.9
  of SDLK_PAGEUP: pv.scrollY -= pv.rect.h * 0.9
  of SDLK_DOWN: pv.scrollY += 40
  of SDLK_UP: pv.scrollY -= 40
  of SDLK_LEFT:
    if cmd: v.command("prev")
    else: pv.scrollX -= 40
  of SDLK_RIGHT:
    if cmd: v.command("next")
    else: pv.scrollX += 40
  of SDLK_HOME: v.command("first")
  of SDLK_END: v.command("last")
  of SDLK_C:
    if not cmd: return false
    v.command("copy")
  of SDLK_F2: v.command("goto")
  of 0x3D'u32, 0x2B'u32:                          # '=' / '+'
    if not cmd: return false
    v.command("zoomIn")
  of 0x2D'u32:                                     # '-'
    if not cmd: return false
    v.command("zoomOut")
  of 0x66'u32:                                     # 'f'
    if not cmd: return false
    v.command("find")
  of 0x6F'u32:                                     # 'o'
    if not cmd: return false
    v.command("open")
  of 0x73'u32:                                     # 's'
    if not cmd: return false
    v.command(if (e.mods and KMOD_SHIFT) != 0: "saveAs" else: "save")
  of 0x4000003C'u32: v.command("findNext")         # F3
  else: return false
  true

# sidebar

method draw*(sb: PdfSidebar, d: Drawing, t: Theme) =
  let v = sb.viewer
  v.pump(d)
  let r = sb.rect
  d.fillRect(r, t.header)
  d.fillRect(rect(r.x + r.w - 1, r.y, 1, r.h), t.border)
  let tabH = t.lineHeight + 4
  for k, caption in ["Pages", "Outline"]:
    let tr = rect(r.x + 6 + float(k) * (r.w - 12) / 2, r.y + 4, (r.w - 12) / 2, tabH)
    if k == sb.mode: d.fillRoundRect(tr, 5, t.surface)
    d.textIn(tr, caption, (if k == sb.mode: t.text else: t.textSecondary), alCenter)
  sb.items.setLen(0)
  let area = rect(r.x, r.y + tabH + 8, r.w - 1, r.h - tabH - 8)
  d.pushClip(area)
  var y = area.y + 6 - sb.scroll
  if sb.mode == 0:
    let tw = r.w - 50
    for i, s in v.sizes:
      let th = tw * s.h / max(1.0, s.w)
      let tr = rect(r.x + (r.w - tw) / 2, y, tw, th)
      if tr.y + tr.h >= area.y and tr.y <= area.y + area.h:
        d.fillRect(tr, White)
        let pw = int(round(tw))
        let tex = v.textureFor(i, pw, int(round(th)))
        if tex != nil: d.drawTexture(tex, tr)
        if i == v.current: d.strokeRect(tr.shrink(-3), t.accent, 2)
        else: d.strokeRect(tr, t.border, 1)
      d.textIn(rect(r.x, tr.y + tr.h + 2, r.w, t.lineHeight), $(i + 1),
               (if i == v.current: t.accent else: t.textSecondary), alCenter)
      sb.items.add((rect(r.x, tr.y, r.w, th + t.lineHeight + 4), i))
      y += th + t.lineHeight + 14
  else:
    if v.outline.len == 0:
      d.textIn(rect(area.x, y, area.w, t.lineHeight), "No outline", t.textSecondary, alCenter)
    for o in v.outline:
      let rr = rect(r.x + 8 + float(min(o.level, 8)) * 12, y, r.w - 16 - float(min(o.level, 8)) * 12, t.lineHeight)
      if o.page == v.current: d.fillRoundRect(rr, 4, t.surfaceHover)
      d.textIn(rr, o.title, (if o.page >= 0: t.text else: t.textSecondary))
      sb.items.add((rr, o.page))
      y += t.lineHeight
  d.popClip()

method onMouse*(sb: PdfSidebar, e: MouseEvent) =
  if e.action != maPress: return
  let v = sb.viewer
  let tabH = sb.win.theme.lineHeight + 4
  if e.y < sb.rect.y + tabH + 8:
    sb.mode = if e.x < sb.rect.x + sb.rect.w / 2: 0 else: 1
    sb.scroll = 0
    return
  for it in sb.items:
    if it.r.containsPoint(e.x, e.y) and it.page >= 0 and it.page < v.sizes.len:
      v.current = it.page
      v.pendingGoto = it.page
      emit(v, evSelection, index = it.page + 1)
      return

method onWheel*(sb: PdfSidebar, dx, dy: float): bool =
  sb.scroll = max(0.0, sb.scroll - dy * 40)
  true

# construction

method typeName*(v: PdfViewer): string = "PDF Viewer"
method preferredSize*(v: PdfViewer, d: Drawing, t: Theme): tuple[w, h: float] = (800.0, 600.0)

proc newPdfViewer*(): PdfViewer =
  # The complete viewer / editor (command bars, sidebar, pages, status line).
  result = PdfViewer(layout: lkBorder, margin: 0, spacing: 0, zoom: 1, fitMode: 1, showSidebar: true,
                     pendingGoto: -1, hitPage: -1, selPage: -1, cachedIndex: -1)
  initControl(result)
  let v = result
  proc bar(v: PdfViewer, items: openArray[tuple[caption, cmd, tip: string]]): Toolbar =
    result = newToolbar()
    result.dock = dkTop
    for it in items:
      if it.cmd == "|":
        let s = result.addChild(newShape(skVLine))
        s.fixedWidth = 10
        s.stretch = true
      else:
        let b = result.addChild(newToolButton(v, it.caption, it.cmd, it.tip))
        if it.cmd in ["select", "hand", "text", "note", "rectangle"]: v.toolButtons.add b
    discard v.addChild(result)
  let tb1 = v.bar([("Open", "open", "Open a PDF (Cmd/Ctrl+O)"), ("Save", "save", "Save (Cmd/Ctrl+S)"),
                   ("Save As", "saveAs", "Save under another name"), ("New", "new", "New blank document"),
                   ("|", "|", ""),
                   ("|<", "first", "First page"), ("<", "prev", "Previous page"), (">", "next", "Next page"),
                   (">|", "last", "Last page"), ("|", "|", ""),
                   ("-", "zoomOut", "Zoom out (Cmd/Ctrl+-)"), ("+", "zoomIn", "Zoom in (Cmd/Ctrl++)"),
                   ("Fit width", "fitWidth", "Fit the page width"), ("Fit page", "fitPage", "Whole page"),
                   ("100 %", "actual", "Actual size"), ("|", "|", ""),
                   ("Find", "find", "Search the text (Cmd/Ctrl+F, F3 = next)"), ("Info", "info", "Document information"),
                   ("Sidebar", "sidebar", "Show / hide thumbnails and outline")])
  let pb = tb1.addChild(newToolButton(v, "0 / 0", "goto", "Go to page (F2)"))
  v.pageButton = pb
  let zl = tb1.addChild(newLabel("100 %"))
  v.zoomLabel = zl
  discard v.bar([("Select", "select", "Select and copy text (Cmd/Ctrl+C)"), ("Hand", "hand", "Pan the pages"),
                 ("|", "|", ""),
                 ("Add text", "text", "Click on a page to add text"),
                 ("Note", "note", "Click on a page to add a note"),
                 ("Rectangle", "rectangle", "Drag on a page to draw a rectangle"),
                 ("Highlight", "highlight", "Highlight the selected text"), ("|", "|", ""),
                 ("Rotate", "rotate", "Rotate the current page 90°"), ("Delete page", "delete", "Delete the current page"),
                 ("Page up", "up", "Move the current page up"), ("Page down", "down", "Move the current page down"),
                 ("Blank page", "blank", "Insert a blank page after the current one"),
                 ("Insert PDF…", "insert", "Merge pages of another PDF at a chosen position")])
  for b in v.toolButtons: b.isDefault = b.cmd == "select"
  let st = v.addChild(newLabel(""))
  st.dock = dkBottom
  st.style.text = some(hex"#8C8F96")
  v.status = st
  let sb = PdfSidebar(viewer: v)
  initControl(sb)
  sb.dock = dkLeft
  sb.fixedWidth = 170
  discard v.addChild(sb)
  v.sidebar = sb
  let pv = PdfPageView(viewer: v, rectPage: -1)
  initControl(pv)
  pv.focusable = true
  pv.dock = dkCenter
  discard v.addChild(pv)
  v.view = pv
  {.cast(gcsafe).}:
    withLock queueLock:
      renderViewers.add v
      if not renderStarted:
        renderStarted = true
        createThread(renderThread, renderLoop)
