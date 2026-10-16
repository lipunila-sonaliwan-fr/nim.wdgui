CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026\
LPCS, Lab'Oratoire (metalab at sonaliwan.fr)

[![](wdlua.png)]()

# wdlua — IDE et interpréteur Lua construits sur wdgui

wdlua est une application sœur de wdnim : un environnement complet pour le Lua décrit
par le manuel fourni avec Lua 5.4 **et quelques raccourcis à la [Pico8](https://www.lexaloffle.com/)** de mon ami Joseph "Zep" White (Haaaa... l'époque de *Picoscope* 😅).

- un **interpréteur Lua écrit en Nim**, intégré à l'IDE et disponible en runtime autonome ;
- un **IDE** : éditeur avec coloration, complétion et analyse en continu, exécution
  directe ou **pas à pas** (points d'arrêt, variables, pile d'appels), console avec saisie ;
- un **système de paquets** écrits en Nim qui étendent le langage : E/S standard,
  fichiers (texte, binaire, CSV, JSON), réseau (TCP/UDP, HTTP/HTTPS, FTP, SSH/SFTP),
  SQLite, multitâche, et **l'accès complet à wdgui** depuis Lua.

L'application est en français (bien que la bibliothèque `wdgui` soit en anglais 😅 — vous pouvez récupérer le code source de `wdgui` dans le projet **nim.wdlexis** pour vous assurer que tout est en français). C'est en développant cet exemple qu'une idée a germé dans mon esprit. Il est vraiment regrettable que tous les langages de programmation soient en anglais. Cela constitue un frein à l'apprentissage et — à mon sens — une forme d'impérialisme. Au-delà de cet exemple précis (l'utilisation de `wdgui`), quelle est la réelle valeur d'un tel outil ? Et là, une révélation : pourquoi ne pas réunir tous les concepts qui me tiennent à cœur au sein d'un nouveau langage de programmation en français - **Lexis+** ? Je n'ai pas la prétention de révolutionner le secteur ; mon seul objectif est d'offrir, à toute personne intéressée, des outils accessibles, bien documentés et faciles à utiliser, lui permettant de concrétiser rapidement ses projets.

En conclusion : sauf si l'approche à la [lua](https://www.lua.org/license.html)* est votre principal centre d'intérêt, allez plutôt voir ce qui se passe chez [Lexis+](https://github.com/lipunila-sonaliwan-fr/nim.wdlexis/tree/main). 

## Arborescence

```
wdlua/
  wdlua.nim            IDE (fenêtre principale)
  wdluart.nim          runtime autonome
  config.nims          options de compilation
  lua/                 interpréteur
    core.nim           valeurs, tables, arbre syntaxique, état
    lexer.nim          analyse lexicale (avec les extensions du manuel)
    parser.nim         analyse syntaxique et résolution des variables
    interp.nim         évaluation, métatables, coroutines, débogueur
    lpattern.nim       motifs Lua (find, match, gmatch, gsub)
    stdlib.nim         base, string, table, math, coroutine, utf8 + fonctions du manuel
    api.nim            API pour écrire des paquets en Nim
  packages/            paquets fournis (all.nim les enregistre tous)
  ide/                 éditeur (portage de celui de wdnim), coloration, analyse,
                       session de débogage, compatibilité wdgui
  examples/            programmes d'exemple
  tests/lang.lua       tests du langage
```

## Compilation

wdlua s'installe comme wdnim, dans `apps/wdlua` du dépôt nim.wdgui (le chemin
`../../src` de `config.nims` pointe vers wdgui ; adaptez-le sinon).

```
cd apps/wdlua
nim c -d:release wdlua.nim       # l'IDE
nim c -d:release wdluart.nim     # le runtime
./wdluart tests/lang.lua         # tests du langage
```

Options utilisées : `--threads:on --mm:atomicArc -d:sdlttf -d:ssl`.
Bibliothèques chargées à l'exécution : SDL3, SDL3_ttf (wdgui), OpenSSL (HTTPS/TLS),
SQLite 3 (paquet sqlite). SSH/SFTP utilisent le client OpenSSH installé.

## Le langage

Lua 5.4 : entiers et flottants distincts, closures, métatables, retours multiples,
`...`, `<const>`, coroutines, bibliothèque standard (string avec motifs Lua, table,
math, utf8, os, io).

Extensions décrites par le manuel (§9.2), toutes reconnues :

| Forme | Équivalent |
|---|---|
| `a += 2` (aussi `-= *= /= //= \= %= ^= ..= &= \|= <<= >>=`) | `a = a + 2` |
| `x \ y` | `x // y` |
| `a != b` | `a ~= b` |
| `if (cond) instr [else instr]` sur une ligne | `if cond then ... end` |
| `while (cond) instr` sur une ligne | `while cond do ... end` |
| `?expr, ...` | `print(expr, ...)` |
| `0b1010` | littéral binaire |

Fonctions du manuel conservées (§10.5, §10.6) : `add`, `del`, `deli`, `count`, `all`,
`foreach`, `split`, `chr`, `ord`, `flr`, `ceil`, `rnd`, `srand`, `mid`, `sgn`,
`tostr`, `tonum`, `time`/`t`, `printh`.

Non pris en charge, car hors du langage décrit : `goto` et les étiquettes, `<close>`.

## L'IDE

- **Projet** : un dossier ; `main.lua` est le point d'entrée (modifiable dans
  *Exécuter > Arguments et fichier principal*). `require "module"` charge `module.lua`
  du projet ; les documents ouverts sont exécutés tels qu'à l'écran, même non enregistrés.
- **Analyse** : les erreurs de syntaxe viennent du vrai analyseur de l'interpréteur ;
  avertissement pour les appels de fonctions inconnues ; option pour signaler les
  extensions du manuel (portabilité vers Lua standard).
- **Complétion** (Ctrl+Espace ou automatique) : mots-clés, fonctions, paquets, membres
  après `.`, méthodes après `:`, propriétés et gestionnaires `on...` des objets ui,
  symboles du projet. La barre d'état affiche la signature de la fonction en cours d'appel.
- **Panneau Paquets** : toute la documentation des paquets ; double-clic pour insérer l'appel.

### Exécution et débogage

| Touche | Action |
|---|---|
| Ctrl+R | exécuter (sans débogueur, plus rapide) |
| F5 | déboguer (s'arrête aux points d'arrêt) / continuer |
| F9, clic dans la marge | point d'arrêt |
| F11 / F10 / Maj+F11 | pas à pas / pas principal / sortir de la fonction |
| Maj+F5 | arrêter |

En pause : ligne courante surlignée, onglet **Variables** (locales, upvalues, globales
du programme), onglet **Pile d'appels** (cliquer un niveau affiche ses variables).
`io.read` lit la ligne saisie dans la **Console**. Les fenêtres créées par le programme
s'ouvrent dans l'IDE ; le programme reste actif jusqu'à leur fermeture.

## Le runtime

```
wdluart programme.lua [arguments...]
wdluart --check programme.lua
wdluart -e "print(1 + 1)"
wdluart --packages
```

Même interpréteur et mêmes paquets. Si le programme ouvre des fenêtres sans appeler
`ui.run()`, la boucle de wdgui démarre à la fin du programme.

## Paquets

| Paquet | Accès | Contenu |
|---|---|---|
| `io` | global | `io.write/read/lines/open`, fichiers `f:read/write/lines/seek/close` |
| `os` | global | `time`, `date`, `clock`, `getenv`, `execute`, `capture`, `sleep`, `exit`, `args` |
| `file` | `require` | lecture/écriture texte et binaire, dossiers, `ls/cp/mv/rm/mkdir/pwd/cd/fstat` (§10.8) |
| `bin` | `require` | `pack`/`unpack`/`size`, `tohex`/`fromhex` (et `string.pack`) |
| `csv` | `require` | `parse`, `read`, `encode`, `write` (en-têtes, séparateur, conversion) |
| `json` | `require` | `encode`, `decode`, `read`, `write`, `json.null` |
| `net` | `require` | TCP client/serveur, TLS, UDP, DNS |
| `http` | `require` | `get`, `post`, `request`, `download` (HTTPS avec `-d:ssl`) |
| `ftp` | `require` | session FTP passive : `list`, `get`, `put`, `cd`, `mkdir`, `delete`, `rename` |
| `ssh`, `sftp` | `require` | `exec`, `get`, `put`, `list`, `mkdir`, `remove`, `rename` (via OpenSSH) |
| `sqlite` | `require` | `open`, `exec`, `query`, `first`, `rows`, `transaction`, `lastid` |
| `task` | `require` | tâches coopératives, `sleep`, `yield`, `run`, canaux |
| `thread` | `require` | vrais threads (interpréteur séparé), messages `send`/`receive` |
| `ui` | `require` | wdgui : fenêtres, contrôles, propriétés, événements, dialogues |

### Le paquet ui

```lua
local ui = require "ui"
local win = ui.window{title = "Démo", width = 500, height = 300, layout = "vertical"}
local nom = win:add(ui.edit{placeholder = "Votre nom"})
local liste = win:add(ui.list())
local ajout = win:add(ui.button("Ajouter", {default = true}))

ajout.onclick = function(ev)
  liste:add(nom.value)
  nom.value = ""
end
liste.onselection = function(ev) print("choisi :", liste:item(liste:selected())) end
ui.run()
```

- Propriétés : `value`, `num`, `caption`, `visible`, `state`, `enabled`, `tooltip`,
  `name`, `x`, `y`, `width`, `height`, `color`, `background`, `dock`, `weight`,
  `fixedwidth`, `fixedheight`, `stretch`, `margin`, `spacing`, `min`, `max`...
- Événements : `on` + nom de l'événement wdgui en minuscules (`onclick`, `onchange`,
  `onselection`, `ondoubleclick`, `onkeydown`, `onwindowclose`...) ou `onevent`.
  Le gestionnaire reçoit `ev` (`kind`, `id`, `x`, `y`, `button`, `key`, `text`,
  `index`, `path`...) ; `ev:stop()` arrête la propagation.
- Méthodes selon le contrôle : listes, tables, arbres, menus, grille (colonnes typées,
  pieds, mises en forme, CSV/JSON), graphes, calendrier, kanban, Gantt, panneau, PDF.

## Écrire un paquet

```nim
# packages/pkg_hello.nim
import ../lua/api

proc openHello(L: Interp): Value =
  let m = newLib()
  m.fn "bonjour", proc (L: Interp, a: seq[Value]): seq[Value] =
    ret strV("Bonjour " & L.checkStr(a, 1, "bonjour"))
  tableV(m)

registerPackage PackageDef(name: "hello", open: openHello,
  description: "Exemple",
  docs: docs("hello", ["hello.bonjour(nom)", "Renvoie une salutation."]))
```

Ajoutez `pkg_hello` à `packages/all.nim` : `require "hello"` fonctionne, et la
complétion, l'aide et la coloration de l'IDE le connaissent. `api.nim` fournit la
vérification des arguments (`checkStr`, `checkInt`, `optNum`, `checkTable`...), les
types natifs (`wrap`, `checkUser`), les options en table (`optField`) et
`L.blocking:` pour libérer l'interpréteur pendant une attente.

## Fonctionnement interne

- Interpréteur par parcours d'arbre ; chaque variable locale est une cellule
  capturable par les closures.
- Un verrou global sérialise le programme principal et les gestionnaires
  d'événements wdgui (qui tournent sur leurs propres threads) ; les attentes
  (`ui.run`, `os.sleep`, réseau, `io.read`) le libèrent.
- Chaque coroutine s'exécute sur un thread, avec passage de relais : une seule
  s'exécute à la fois, ce qui permet de suspendre n'importe où (y compris dans un
  rappel appelé par une fonction native).
- Le débogueur est consulté avant chaque instruction ; une pause bloque le fil
  courant jusqu'à la commande suivante.

## Points à vérifier à la première compilation

Le TUTORIAL de wdgui ne précise pas toutes les signatures internes. Elles sont
isolées dans `ide/compat.nim` (et protégées par `when compiles` dans `packages/pkg_ui.nim`) :

1. le type du paramètre de `method onKey` (supposé `KeyEvent`) ;
2. les primitives de dessin (`fillRect`, `pushClip`, `textIn`), les champs des
   événements souris/clavier, le presse-papiers SDL ;
3. `Window.id`, le type `Container`, l'option multiligne de `newEdit` ;
4. les constructeurs cités sans paramètres (`newSlider`, `newSpin`, `newKanban`...) ;
5. le sens de `newSplitter(vertical = true)` (supposé : barre verticale, panneaux côte à côte).

Limites connues : pas de `goto` ni de `<close>` ; l'arrêt d'un programme bloqué dans
une fonction native (connexion réseau sans délai) attend la fin de l'appel ;
l'authentification SSH par mot de passe demande `sshpass`.
