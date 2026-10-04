# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
#   _._
# o|- -|o  wdnotes_cli - the wdnotes engine without the GUI
#  ( l )
#    =     nim c -d:release apps/wdnotes/wdnotes_cli.nim
#
#   wdnotes_cli <project> export pdf|html|rtf|odt <output> [noteTitle]
#   wdnotes_cli <project> stats
#   wdnotes_cli <project> words [n]
#   wdnotes_cli <project> families
#   wdnotes_cli <project> links

import std/[os, strutils, tables]
import project, lexicon, exporters, graphlayout

proc usage() =
  echo """wdnotes_cli <projet> export pdf|html|rtf|odt <sortie> [titre de note]
wdnotes_cli <projet> stats | words [n] | families | links"""
  quit(1)

when isMainModule:
  let args = commandLineParams()
  if args.len < 2: usage()
  let dir = args[0]
  if not isProjectDir(dir):
    echo "Pas de projet wdnotes dans ", dir
    quit(2)
  let p = loadProject(dir)
  case args[1]
  of "export":
    if args.len < 4: usage()
    let kind = parseExportKind(args[2])
    var doc: RenderDoc
    if args.len >= 5:
      let id = p.findByTitle(args[4])
      if id.len == 0:
        echo "Note introuvable : ", args[4]
        quit(3)
      doc = buildDoc(p, id, true)
    else:
      doc = buildProjectDoc(p)
    echo "→ ", exportDoc(doc, kind, args[3])
  of "stats":
    let lex = buildLexicon(p)
    var words = 0
    for id in p.preorder:
      for _, c in countWords(p.notes[id].text): words += c
    echo p.title, " : ", p.notes.len, " notes, ", p.links.len, " liens, ",
      lex.words.len, " termes distincts, ", words, " occurrences, ",
      lex.families.len, " familles"
  of "words":
    let n = if args.len > 2: parseInt(args[2]) else: 30
    let lex = buildLexicon(p)
    for i, wc in lex.sortedWords():
      if i >= n: break
      echo align($wc[1], 6), "  ", wc[0]
  of "families":
    let lex = buildLexicon(p)
    for (f, nw, occ) in lex.familyStats:
      echo alignLeft(f, 20), align($nw, 5), " mots", align($occ, 7), " occ."
  of "links":
    let g = buildGraph(p, withTree = false)
    for e in g.edges:
      echo g.nodes[e.a].title, "  →  ", g.nodes[e.b].title
  else: usage()
