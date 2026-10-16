# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
#   wdlua - IDE : préférences persistantes (JSON dans le dossier de configuration)

import std/[json, os]

type
  Settings* = object
    dark*: bool
    minimap*: bool
    flagExtensions*: bool    # signaler +=, !=, \, ?, formes courtes.
    unknownCalls*: bool      # signaler les appels de fonctions inconnues.
    lastProject*: string
    programArgs*: string     # arguments passés au programme (séparés par des espaces).
    mainFile*: string        # fichier lancé par Exécuter ("" = main.lua, sinon le fichier actif).

proc defaultSettings*(): Settings =
  Settings(dark: true, minimap: true, flagExtensions: false, unknownCalls: true)

proc settingsPath(): string = getConfigDir() / "wdlua" / "settings.json"

proc loadSettings*(): Settings =
  result = defaultSettings()
  try:
    let j = parseFile(settingsPath())
    template get(field: untyped, kind: untyped) =
      if j.hasKey(astToStr(field)): result.field = j[astToStr(field)].kind
    get(dark, getBool)
    get(minimap, getBool)
    get(flagExtensions, getBool)
    get(unknownCalls, getBool)
    get(lastProject, getStr)
    get(programArgs, getStr)
    get(mainFile, getStr)
  except CatchableError:
    discard

proc saveSettings*(s: Settings) =
  try:
    createDir(settingsPath().parentDir)
    writeFile(settingsPath(), pretty(%*s))
  except CatchableError:
    discard
