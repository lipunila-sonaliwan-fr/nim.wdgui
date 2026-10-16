# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026
#   wdlua - tous les paquets fournis
#
# Importer ce module enregistre les paquets (effet de bord à l'initialisation).
# Pour ajouter un paquet : écrire packages/pkg_xxx.nim (voir lua/api.nim) et
# l'ajouter ci-dessous ; il apparaît alors dans require, la complétion et l'aide.

import ../lua/stdlib
import pkg_io, pkg_data, pkg_os, pkg_net, pkg_sqlite, pkg_task, pkg_ui

export newFullInterp, LuaExit, openWindows, closeAllWindows, loopNeeded, uiState, UiState
