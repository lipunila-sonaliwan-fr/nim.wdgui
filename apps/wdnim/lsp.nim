# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
# Minimal Language Server Protocol client for nimlangserver
# (https://github.com/nim-lang/langserver), over JSON-RPC on the server's stdin / stdout.
#
# * a reader thread decodes the server messages: responses, diagnostics
#   (textDocument/publishDiagnostics) and requests from the server
#   (workspace/configuration, progress, capability registration), which are answered;
# * a sync thread sends the edited text (textDocument/didChange) after a short pause
#   in typing, so the server checks the file on the fly;
# * requests (completion, hover, signature help, definition) block the calling thread,
#   with a timeout. In wdnim they are called from event handlers, never from the UI thread.
import std/[osproc, streams, json, locks, os, strutils, tables, times, strtabs]
import lsptypes
export lsptypes

type
  ServerState* = enum
    srvOff = "off", srvStarting = "starting", srvReady = "ready", srvFailed = "failed",
    srvMissing = "not installed"

  TextProvider* = proc (path: string): tuple[found: bool, text: string] {.nimcall, gcsafe.}
  DiagnosticsHandler* = proc (path: string) {.nimcall, gcsafe.}

var
  lk, sendLock: Lock
  process: Process
  inStream, outStream, errStream: Stream
  state = srvOff
  stopping: bool
  nextId = 1
  responses: Table[int, JsonNode]
  diagnostics: Table[string, seq[Diagnostic]]
  versions: Table[string, int]             # open documents → version
  pendingChanges: Table[string, float]     # path → time of the last edit not yet sent
  rootDir, lastMessage, serverPath: string
  readerThread, errThread, syncThread: Thread[void]
  threadsStarted: bool
  textProvider: TextProvider
  onDiagnostics: DiagnosticsHandler

initLock(lk)
initLock(sendLock)

# helpers

proc uriOf*(path: string): string =
  var p = absolutePath(path).replace('\\', '/')
  if not p.startsWith("/"): p = "/" & p
  result = "file://"
  for c in p:
    if c.isAlphaNumeric or c in {'/', '-', '_', '.', '~', ':'}: result.add c
    else: result.add '%' & toHex(ord(c), 2)

proc pathOf*(uri: string): string =
  var s = uri
  if s.startsWith("file://"): s = s[7 .. ^1]
  var i = 0
  while i < s.len:
    if s[i] == '%' and i + 2 < s.len:
      try:
        result.add chr(parseHexInt(s[i + 1 .. i + 2]))
        i += 3
        continue
      except ValueError: discard
    result.add s[i]
    inc i
  when defined(windows):
    if result.len > 2 and result[0] == '/' and result[2] == ':': result = result[1 .. ^1]
  result = normalizedPath(result)

proc nimSettings(): JsonNode =
  %*{"autoCheckFile": true, "autoCheckProject": false, "checkOnSave": true,
     "useNimCheck": true, "notificationVerbosity": "none", "autoRestart": true,
     "inlayHints": {"typeHints": false, "exceptionHints": false, "parameterHints": false}}

proc findServer*(): string =
  # nimlangserver on the PATH, else in ~/.nimble/bin.
  result = findExe("nimlangserver")
  if result.len > 0: return
  for c in [getHomeDir() / ".nimble" / "bin" / "nimlangserver",
            getHomeDir() / ".nimble" / "bin" / "nimlangserver.exe"]:
    if fileExists(c): return c

proc serverEnv(exe: string): StringTableRef =
  # Environment for the server: PATH extended with the usual Nim locations, since an
  # application started from the desktop may not inherit the shell PATH (nimsuggest, nim…).
  result = newStringTable(modeCaseSensitive)
  for k, v in envPairs(): result[k] = v
  var extra: seq[string]
  for d in [exe.parentDir, getHomeDir() / ".nimble" / "bin", findExe("nim").parentDir,
            "/opt/homebrew/bin", "/usr/local/bin"]:
    if d.len > 0 and dirExists(d) and d notin extra: extra.add d
  result["PATH"] = extra.join($PathSep) & $PathSep & getEnv("PATH")

# transport

proc sendRaw(msg: JsonNode) =
  let body = $msg
  {.cast(gcsafe).}:
    withLock sendLock:
      if inStream == nil: return
      try:
        inStream.write("Content-Length: " & $body.len & "\r\n\r\n" & body)
        inStream.flush()
      except CatchableError: discard

proc notify(meth: string, params: JsonNode) =
  sendRaw(%*{"jsonrpc": "2.0", "method": meth, "params": params})

proc reply(id: JsonNode, res: JsonNode) =
  sendRaw(%*{"jsonrpc": "2.0", "id": id, "result": res})

proc request(meth: string, params: JsonNode, timeoutMs = 4000): JsonNode =
  # Sends a request and waits for its result (nil on timeout, error or when not ready).
  var id: int
  {.cast(gcsafe).}:
    withLock lk:
      if state notin {srvStarting, srvReady}: return nil
      id = nextId
      inc nextId
  sendRaw(%*{"jsonrpc": "2.0", "id": id, "method": meth, "params": params})
  let t0 = epochTime()
  while epochTime() - t0 < float(timeoutMs) / 1000:
    {.cast(gcsafe).}:
      withLock lk:
        if id in responses:
          let msg = responses[id]
          responses.del(id)
          return msg{"result"}
        if state in {srvOff, srvFailed}: return nil
    sleep(4)
  nil

# incoming messages

proc configurationFor(params: JsonNode): JsonNode =
  result = newJArray()
  let items = params{"items"}
  if items == nil or items.kind != JArray: return
  for item in items:
    let section = item{"section"}.getStr
    if section.len == 0 or section == "nim": result.add nimSettings()
    elif section.startsWith("nim."):
      let v = nimSettings(){section[4 .. ^1]}
      result.add(if v == nil: newJNull() else: v)
    else: result.add newJNull()

proc handleMessage(msg: JsonNode) =
  let hasMethod = msg.hasKey("method")
  if msg.hasKey("id") and not hasMethod:                          # response to one of our requests.
    {.cast(gcsafe).}:
      withLock lk: responses[msg["id"].getInt] = msg
    return
  if not hasMethod: return
  let meth = msg["method"].getStr
  let params = msg{"params"}
  if msg.hasKey("id"):                                            # request from the server.
    case meth
    of "workspace/configuration": reply(msg["id"], configurationFor(params))
    else: reply(msg["id"], newJNull())
    return
  case meth                                                       # notifications.
  of "textDocument/publishDiagnostics":
    let path = pathOf(params{"uri"}.getStr)
    var list: seq[Diagnostic]
    let ds = params{"diagnostics"}
    if ds == nil or ds.kind != JArray: return
    for d in ds:
      let r = d{"range"}
      list.add Diagnostic(line: r{"start"}{"line"}.getInt, col: r{"start"}{"character"}.getInt,
                          endLine: r{"end"}{"line"}.getInt, endCol: r{"end"}{"character"}.getInt,
                          severity: d{"severity"}.getInt(1), message: d{"message"}.getStr,
                          source: d{"source"}.getStr)
    var handler: DiagnosticsHandler
    {.cast(gcsafe).}:
      withLock lk:
        diagnostics[path] = list
        handler = onDiagnostics
    if handler != nil: handler(path)
  of "window/showMessage", "window/logMessage":
    if meth == "window/showMessage" or params{"type"}.getInt(4) <= 1:
      {.cast(gcsafe).}:
        withLock lk: lastMessage = params{"message"}.getStr
  else: discard

proc readerLoop() {.thread.} =
  {.cast(gcsafe).}:
    let s = outStream
    while true:
      var length = -1
      var line = ""
      var alive = true
      while true:
        if not s.readLine(line):
          alive = false
          break
        let l = line.strip
        if l.len == 0:
          if length >= 0: break
          continue
        if l.toLowerAscii.startsWith("content-length:"):
          try: length = parseInt(l.split(':')[1].strip)
          except ValueError: length = -1
      if not alive or length < 0: break
      let body = s.readStr(length)
      var msg: JsonNode = nil
      try:
        msg = parseJson(body)
      except CatchableError:
        msg = nil
      if msg != nil: handleMessage(msg)
    withLock lk:
      if not stopping: lastMessage = "the language server stopped"
      state = if stopping: srvOff else: srvFailed

proc errLoop() {.thread.} =
  # Drains stderr (server logs) so that the pipe never fills up.
  {.cast(gcsafe).}:
    var line = ""
    while errStream != nil and errStream.readLine(line): discard

proc syncLoop() {.thread.} =
  # Sends pending edits after 350 ms without typing.
  {.cast(gcsafe).}:
    while true:
      sleep(120)
      var due: seq[string]
      var provider: TextProvider
      withLock lk:
        if stopping: break
        let now = epochTime()
        for path, t in pendingChanges:
          if now - t > 0.35: due.add path
        for p in due: pendingChanges.del(p)
        provider = textProvider
      if provider == nil: continue
      for path in due:
        let r = provider(path)
        if not r.found: continue
        var v = 0
        withLock lk:
          if path in versions:
            inc versions[path]
            v = versions[path]
        if v > 0:
          notify("textDocument/didChange", %*{"textDocument": {"uri": uriOf(path), "version": v},
                                              "contentChanges": [{"text": r.text}]})

# life cycle

proc lspSetCallbacks*(provider: TextProvider, diagnosticsHandler: DiagnosticsHandler) =
  {.cast(gcsafe).}:
    withLock lk:
      textProvider = provider
      onDiagnostics = diagnosticsHandler

proc lspState*(): ServerState =
  {.cast(gcsafe).}:
    withLock lk: result = state

proc lspLastMessage*(): string =
  {.cast(gcsafe).}:
    withLock lk: result = lastMessage

proc lspServerPath*(): string =
  {.cast(gcsafe).}:
    withLock lk: result = serverPath

proc lspStop*() =
  # Graceful shutdown (shutdown request, exit notification), then terminates the process.
  if lspState() == srvReady: discard request("shutdown", newJNull(), 1500)
  notify("exit", newJNull())
  {.cast(gcsafe).}:
    withLock lk:
      stopping = true
      if process != nil:
        try: process.terminate()
        except CatchableError: discard
    if threadsStarted:
      joinThread(readerThread)
      joinThread(errThread)
      joinThread(syncThread)
      threadsStarted = false
    withLock lk:
      if process != nil: process.close()
      process = nil
      withLock sendLock:
        inStream = nil
      versions.clear()
      pendingChanges.clear()
      diagnostics.clear()
      responses.clear()
      state = srvOff

proc lspStart*(root: string, exe = ""): bool =
  # Starts nimlangserver for the project `root` and performs the initialize handshake
  # (blocks up to 20 s). Returns false if the server is missing or does not answer.
  if lspState() != srvOff: lspStop()
  let path = if exe.len > 0: exe else: findServer()
  {.cast(gcsafe).}:
    withLock lk:
      serverPath = path
      rootDir = root
      stopping = false
      if path.len == 0:
        state = srvMissing
        lastMessage = "nimlangserver not found: nimble install -g nimlangserver"
        return false
      try:
        process = startProcess(path, workingDir = root, args = newSeq[string](), env = serverEnv(path), options = {})
      except CatchableError as e:
        state = srvFailed
        lastMessage = "cannot start nimlangserver: " & e.msg
        return false
      withLock sendLock:
        inStream = process.inputStream
      outStream = process.outputStream
      errStream = process.errorStream
      state = srvStarting
    createThread(readerThread, readerLoop)
    createThread(errThread, errLoop)
    createThread(syncThread, syncLoop)
    threadsStarted = true
  let caps = %*{
    "textDocument": {
      "synchronization": {"didSave": true, "dynamicRegistration": false},
      "completion": {"completionItem": {"snippetSupport": false,
                                        "documentationFormat": ["plaintext", "markdown"]}},
      "hover": {"contentFormat": ["plaintext", "markdown"]},
      "signatureHelp": {"signatureInformation": {"documentationFormat": ["plaintext"]}},
      "definition": {"linkSupport": false},
      "publishDiagnostics": {"relatedInformation": false}},
    "workspace": {"configuration": true},
    "window": {"workDoneProgress": false}}
  let init = request("initialize", %*{
    "processId": getCurrentProcessId(), "rootUri": uriOf(root), "rootPath": root,
    "clientInfo": {"name": "wdnim", "version": "0.2"}, "capabilities": caps,
    "initializationOptions": {"nim": nimSettings()}}, 20000)
  if init == nil:
    {.cast(gcsafe).}:
      withLock lk:
        lastMessage = "nimlangserver did not answer the initialize request"
    lspStop()
    {.cast(gcsafe).}:
      withLock lk: state = srvFailed
    return false
  notify("initialized", newJObject())
  notify("workspace/didChangeConfiguration", %*{"settings": {"nim": nimSettings()}})
  {.cast(gcsafe).}:
    withLock lk:
      state = srvReady
      lastMessage = ""
  true

# documents

proc isNimFile(path: string): bool =
  path.endsWith(".nim") or path.endsWith(".nims") or path.endsWith(".nimble")

proc lspOpen*(path, text: string) =
  if path.len == 0 or not isNimFile(path) or lspState() != srvReady: return
  var first = false
  {.cast(gcsafe).}:
    withLock lk:
      if path notin versions:
        versions[path] = 1
        first = true
  if first:
    notify("textDocument/didOpen", %*{"textDocument": {"uri": uriOf(path), "languageId": "nim",
                                                       "version": 1, "text": text}})

proc lspMarkChanged*(path: string) =
  # Records an edit; the sync thread sends it after a short pause in typing.
  if path.len == 0: return
  {.cast(gcsafe).}:
    withLock lk:
      if path in versions: pendingChanges[path] = epochTime()

proc syncNow(path, text: string) =
  # Sends the current text immediately (before a request that depends on it).
  var v = 0
  {.cast(gcsafe).}:
    withLock lk:
      if path in versions:
        pendingChanges.del(path)
        inc versions[path]
        v = versions[path]
  if v > 0:
    notify("textDocument/didChange", %*{"textDocument": {"uri": uriOf(path), "version": v},
                                        "contentChanges": [{"text": text}]})

proc lspSave*(path, text: string) =
  if lspState() != srvReady: return
  syncNow(path, text)
  notify("textDocument/didSave", %*{"textDocument": {"uri": uriOf(path)}, "text": text})

proc lspClose*(path: string) =
  var wasOpen = false
  {.cast(gcsafe).}:
    withLock lk:
      if path in versions:
        versions.del(path)
        pendingChanges.del(path)
        diagnostics.del(path)
        wasOpen = true
  if wasOpen and lspState() == srvReady:
    notify("textDocument/didClose", %*{"textDocument": {"uri": uriOf(path)}})

proc lspDiagnostics*(path: string): seq[Diagnostic] =
  {.cast(gcsafe).}:
    withLock lk: result = diagnostics.getOrDefault(path)

proc lspAllDiagnostics*(): seq[tuple[path: string, d: Diagnostic]] =
  {.cast(gcsafe).}:
    withLock lk:
      for path, list in diagnostics:
        for d in list: result.add((path, d))

# language features.

proc position(path: string, line, col: int): JsonNode =
  %*{"textDocument": {"uri": uriOf(path)}, "position": {"line": line, "character": col}}

proc plain(n: JsonNode): string =
  # Text of a MarkupContent / MarkedString / array of them, without code fences.
  if n == nil: return ""
  case n.kind
  of JString: result = n.getStr
  of JObject: result = n{"value"}.getStr
  of JArray:
    var parts: seq[string]
    for x in n: parts.add plain(x)
    result = parts.join("\n")
  else: result = ""
  var lines: seq[string]
  for l in result.splitLines:
    if not l.strip.startsWith("```"): lines.add l
  result = lines.join("\n").strip

proc lspCompletion*(path, text: string, line, col: int): seq[CompletionItem] =
  # Completion items at (line, col) - 0-based, col in characters.
  if lspState() != srvReady: return
  syncNow(path, text)
  let res = request("textDocument/completion", position(path, line, col), 6000)
  if res == nil: return
  let items = if res.kind == JObject: res{"items"} else: res
  if items == nil or items.kind != JArray: return
  for it in items:
    result.add CompletionItem(label: it{"label"}.getStr, detail: it{"detail"}.getStr,
                              insertText: it{"insertText"}.getStr, kind: it{"kind"}.getInt,
                              documentation: plain(it{"documentation"}))

proc lspHover*(path, text: string, line, col: int): string =
  if lspState() != srvReady: return
  syncNow(path, text)
  let res = request("textDocument/hover", position(path, line, col), 5000)
  if res != nil and res.kind == JObject: result = plain(res{"contents"})

proc lspSignature*(path, text: string, line, col: int): string =
  if lspState() != srvReady: return
  syncNow(path, text)
  let res = request("textDocument/signatureHelp", position(path, line, col), 5000)
  if res == nil or res.kind != JObject: return
  let sigs = res{"signatures"}
  if sigs == nil or sigs.kind != JArray or sigs.len == 0: return
  let i = clamp(res{"activeSignature"}.getInt, 0, sigs.len - 1)
  result = sigs[i]{"label"}.getStr
  let doc = plain(sigs[i]{"documentation"})
  if doc.len > 0: result.add "\n" & doc

proc lspDefinition*(path, text: string, line, col: int): tuple[path: string, line, col: int] =
  # Location of the definition of the symbol at (line, col); path = "" if none.
  if lspState() != srvReady: return
  syncNow(path, text)
  var res = request("textDocument/definition", position(path, line, col), 6000)
  if res == nil: return
  if res.kind == JArray:
    if res.len == 0: return
    res = res[0]
  if res.kind != JObject: return
  let uri = if res.hasKey("targetUri"): res{"targetUri"}.getStr else: res{"uri"}.getStr
  let r = if res.hasKey("targetSelectionRange"): res{"targetSelectionRange"} else: res{"range"}
  if uri.len == 0 or r == nil: return
  (pathOf(uri), r{"start"}{"line"}.getInt, r{"start"}{"character"}.getInt)
