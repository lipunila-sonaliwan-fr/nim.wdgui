# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
# Project helpers for wdnim: file tree, git status, nimble metadata and statistics.
import std/[os, strutils, osproc, algorithm]

type
  ProjectEntry* = tuple[rel: string, isDir: bool]
  GitInfo* = object
    isRepo*: bool
    branch*, lastCommit*, remote*: string
    changes*: int
  NimbleInfo* = object
    file*: string
    fields*: seq[tuple[key, value: string]]
    requires*: seq[string]
  ProjectStats* = object
    nimFiles*, lines*, codeLines*, commentLines*: int
    bytes*: BiggestInt

const
  ignoredDirs = [".git", ".hg", ".svn", "nimcache", "node_modules", ".idea", ".vscode", "htmldocs", "testresults"]
  maxEntries = 5000

proc scanProject*(root: string): seq[ProjectEntry] =
  # Folders first, then files, sorted by name, recursively (relative "/"-separated paths).
  proc walk(dir, rel: string, acc: var seq[ProjectEntry]) =
    var dirs, files: seq[string]
    try:
      for kind, p in walkDir(dir, relative = true):
        if p.startsWith(".") and p notin [".nimble"]: continue
        case kind
        of pcDir, pcLinkToDir:
          if p notin ignoredDirs: dirs.add p
        else: files.add p
    except CatchableError: return
    dirs.sort(cmpIgnoreCase)
    files.sort(cmpIgnoreCase)
    for d in dirs:
      if acc.len >= maxEntries: return
      let r = if rel.len > 0: rel & "/" & d else: d
      acc.add((r, true))
      walk(dir / d, r, acc)
    for f in files:
      if acc.len >= maxEntries: return
      let r = if rel.len > 0: rel & "/" & f else: f
      acc.add((r, false))
  walk(root, "", result)

proc findGitRoot*(root: string): string =
  var d = absolutePath(root)
  while d.len > 0:
    if dirExists(d / ".git") or fileExists(d / ".git"): return d
    let p = d.parentDir
    if p == d: break
    d = p
  ""

proc gitBranch*(root: string): string =
  # Current branch read from .git/HEAD (no git executable needed).
  let g = findGitRoot(root)
  if g.len == 0: return ""
  try:
    let head = readFile(g / ".git" / "HEAD").strip
    if head.startsWith("ref: refs/heads/"): result = head["ref: refs/heads/".len .. ^1]
    elif head.len >= 7: result = "detached@" & head[0 ..< 7]
  except CatchableError: discard

proc gitInfo*(root: string): GitInfo =
  # Branch, last commit, remote and number of changed files (uses the git command when present).
  result.branch = gitBranch(root)
  result.isRepo = result.branch.len > 0
  if not result.isRepo: return
  let q = quoteShell(root)
  try:
    let (st, c1) = execCmdEx("git -C " & q & " status --porcelain")
    if c1 == 0:
      for l in st.splitLines:
        if l.strip.len > 0: inc result.changes
    let (lc, c2) = execCmdEx("git -C " & q & " log -1 --format=%h%x20%s%x20(%cr)")
    if c2 == 0: result.lastCommit = lc.strip
    let (rm, c3) = execCmdEx("git -C " & q & " remote get-url origin")
    if c3 == 0: result.remote = rm.strip
  except CatchableError: discard

proc nimbleInfo*(root: string): NimbleInfo =
  # Fields of the first *.nimble file of the folder (version, author, description...).
  for kind, p in walkDir(root):
    if kind == pcFile and p.endsWith(".nimble"):
      result.file = p
      break
  if result.file.len == 0: return
  try:
    for raw in readFile(result.file).splitLines:
      let l = raw.strip
      if l.startsWith("requires"):
        for part in l["requires".len .. ^1].split(','):
          let r = part.strip.strip(chars = {'"', ' ', '(', ')'})
          if r.len > 0: result.requires.add r
      elif '=' in l and not l.startsWith("#") and not l.startsWith("task"):
        let k = l.split('=', 1)
        let key = k[0].strip
        if key in ["version", "author", "description", "license", "srcDir", "bin", "binDir", "backend"]:
          result.fields.add((key, k[1].strip.strip(chars = {'"', '@', '[', ']', ' '})))
  except CatchableError: discard

proc projectStats*(entries: seq[ProjectEntry], root: string): ProjectStats =
  for e in entries:
    if e.isDir or not (e.rel.endsWith(".nim") or e.rel.endsWith(".nims")): continue
    inc result.nimFiles
    try:
      let content = readFile(root / e.rel)
      result.bytes += BiggestInt(content.len)
      for l in content.splitLines:
        inc result.lines
        let s = l.strip
        if s.startsWith("#"): inc result.commentLines
        elif s.len > 0: inc result.codeLines
    except CatchableError: discard

proc nimFiles*(entries: seq[ProjectEntry]): seq[string] =
  for e in entries:
    if not e.isDir and e.rel.endsWith(".nim"): result.add e.rel

proc guessMainFile*(root: string, entries: seq[ProjectEntry]): string =
  # bin entry of the nimble file, else a .nim named like the folder, else the first .nim.
  let info = nimbleInfo(root)
  var src = ""
  for (k, v) in info.fields:
    if k == "srcDir": src = v
  for (k, v) in info.fields:
    if k == "bin":
      let name = v.split(',')[0].strip.strip(chars = {'"', ' '})
      for cand in [src / name & ".nim", name & ".nim"]:
        if fileExists(root / cand): return cand.replace('\\', '/')
  let base = extractFilename(root)
  for cand in [base & ".nim", "src/" & base & ".nim"]:
    if fileExists(root / cand): return cand
  let files = nimFiles(entries)
  if files.len > 0: files[0] else: ""
