# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
# Run configurations and process execution for wdnim.
# Commands run on the calling (handler) thread; their output is streamed line by line.
import std/[osproc, streams, os, strutils, locks]

type
  RunMode* = enum
    rmRun = "Run", rmBuild = "Build", rmCheck = "Check",
    rmRelease = "Run (release)", rmTest = "Nimble test", rmCustom = "Custom command"
  RunConfig* = object
    mode*: RunMode
    mainFile*: string            # relative to the project; "" = current file.
    backend*: string             # c, cpp, js.
    threads*, atomicArc*, sdlttf*, hintsOff*: bool
    extraFlags*: string          # e.g. "-d:debugLog --opt:speed".
    args*: string                # program arguments.
    customCommand*: string
    clearConsole*: bool

  LineSink* = proc (line: string) {.nimcall, gcsafe.}

var
  procLock: Lock
  current: Process
  running: bool

initLock(procLock)

proc defaultRunConfig*(): RunConfig =
  RunConfig(mode: rmRun, backend: "c", threads: true, atomicArc: true, sdlttf: true,
            hintsOff: true, clearConsole: true)

proc commandFor*(cfg: RunConfig, mode: RunMode, file: string): string =
  # Command line for a mode (the configured one, or a quick Run / Build / Check).
  var flags: seq[string]
  if cfg.threads: flags.add "--threads:on"
  if cfg.atomicArc: flags.add "--mm:atomicArc"
  if cfg.sdlttf: flags.add "-d:sdlttf"
  if cfg.hintsOff: flags.add "--hints:off"
  if cfg.extraFlags.strip.len > 0: flags.add cfg.extraFlags.strip
  let backend = if cfg.backend.len > 0: cfg.backend else: "c"
  let f = quoteShell(file)
  case mode
  of rmRun: "nim " & backend & " -r " & flags.join(" ") & " " & f & " " & cfg.args
  of rmBuild: "nim " & backend & " " & flags.join(" ") & " " & f
  of rmCheck: "nim check " & flags.join(" ") & " " & f
  of rmRelease: "nim " & backend & " -r -d:release " & flags.join(" ") & " " & f & " " & cfg.args
  of rmTest: "nimble test"
  of rmCustom: cfg.customCommand

proc isRunning*(): bool =
  {.cast(gcsafe).}:
    withLock procLock: result = running

proc stopRunning*(): bool =
  # Terminates the running process; false if nothing runs.
  {.cast(gcsafe).}:
    withLock procLock:
      if running and current != nil:
        current.terminate()
        result = true

proc runCommand*(cmd, workDir: string, sink: LineSink): int =
  # Runs `cmd` through the shell in `workDir`, sends every output line (stdout and stderr)
  # to `sink`, and returns the exit code (-1 if it could not start or one already runs).
  var p: Process
  {.cast(gcsafe).}:
    withLock procLock:
      if running: return -1
      try:
        p = startProcess(cmd, workingDir = workDir,
                         options = {poEvalCommand, poStdErrToStdOut, poUsePath})
      except CatchableError as e:
        sink("cannot start: " & e.msg)
        return -1
      current = p
      running = true
  try:
    var line = ""
    let s = p.outputStream
    while s.readLine(line): sink(line)
    result = p.waitForExit()
  except CatchableError as e:
    sink("error: " & e.msg)
    result = -1
  finally:
    p.close()
    {.cast(gcsafe).}:
      withLock procLock:
        running = false
        current = nil

proc parseLocation*(line, root: string): tuple[path: string, line, col: int] =
  # "path/file.nim(12, 5) Error: ..." → (absolute path, 12, 5); path = "" if none.
  let p = line.find(".nim(")
  if p < 0: return ("", 0, 0)
  var start = p
  while start > 0 and line[start - 1] notin {' ', '\t', '"', '\''}: dec start
  let path = line[start ..< p + 4]
  let close = line.find(')', p)
  if close < 0: return ("", 0, 0)
  let nums = line[p + 5 ..< close].split(',')
  try:
    let l = parseInt(nums[0].strip)
    let c = if nums.len > 1: parseInt(nums[1].strip) else: 1
    let full = if isAbsolute(path): path else: root / path
    result = (full, l, c)
  except ValueError:
    result = ("", 0, 0)
