```
   _._
 o|- -|o This file is licensed under CC BY-NC-SA 4.0 international license.
  ( l )  To view a copy of this license, visit http://creativecommons.org/licenses/by-nc-sa/4.0/
    =    Author: jean-marc "jihem" quere 2026
```
![](wdnotes.png)
# wdnotes
wdnotes - notes Markdown arborescentes, liées, mises en forme.

**wdnotes** gère un ensemble de notes texte au format Markdown organisées en
arbre. On les rédige en **mode conception**, on les lit mises en page en
**mode consultation**, on visualise leurs liens dans un **graphe**, on étudie
leur vocabulaire dans un **lexique** et on exporte le tout en **PDF**,
**HTML/CSS/JS**, **RTF** et **LibreOffice**.

```
┌ Fichier  Note  Édition  Affichage  Aide ─────────────────────────────────────────────────────────────────────┐
│ H1 H2 H3 │ G I S </> │ ❝ • 1. ☐ │ Lien [[Note]] Image Table ``` — Saut │ ::: [ ]{.} { } │ Enregistrer ⇩PDF ◐ │
├────────────────┬────────────────────────────────────────────────────────────────────────────┬────────────────┤
│ Projet         │                ✎ Conception │ ◉ Consultation │ ⬡ Graphe                │ ¶ │ Termes│Familles│
│ [filtrer…]     │                                                                            │ terme    occ.  │
│ ▾ Jardin ★     │   éditeur Markdown coloré                                                  │ compost   12   │
│   ▾ Organis.   │   ou document mis en page                                                  │ tomates    9   │
│   ▾ Plantes    │   ou graphe des liens                                                      │ ───────────────│
│   …            │   ou formats / modèles                                                     │ notes / lignes │
│ ＋ ↳ ↑ ↓ → ← ✕ │                                                                            │ ◂ Retour       │
├────────────────┴────────────────────────────────────────────────────────────────────────────┴────────────────┤
│ statut                                                               format · étiquettes · mots · Ln, Col    │
└──────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
```
(Priére de ne pas critiquer mes magnifiques schémas... 😂)

## Lancer

Depuis la racine de wdgui (celle qui contient `src`) :

```
nim c -r -o:apps/wdnotes/wdnotes apps/wdnotes/wdnotes.nim            # config.nims fournit les options
nim c -r --threads:on --mm:atomicArc -d:sdlttf apps/wdnotes/wdnotes.nim apps/wdnotes/demo
```

ou ajoutez cette tâche à `wdgui.nimble` :

```nim
task wdnotes, "Build and run wdnotes, the Markdown notes example application":
  exec "nim c -r --threads:on --mm:atomicArc -d:sdlttf -o:apps/wdnotes/wdnotes apps/wdnotes/wdnotes.nim"
```

Sans argument, l'application ouvre le projet de démonstration `apps/wdnotes/demo`
(un « jardin partagé » : 10 notes, liens, étiquettes, formats, balises, lexique).

Le moteur (Markdown, formats, lexique, graphe, exports) n'a pas besoin de SDL :

```
nim c -d:release apps/wdnotes/wdnotes_cli.nim
apps/wdnotes/wdnotes_cli apps/wdnotes/demo export pdf  jardin.pdf
apps/wdnotes/wdnotes_cli apps/wdnotes/demo export html site_jardin
apps/wdnotes/wdnotes_cli apps/wdnotes/demo export odt  jardin.fodt "Plantes"
apps/wdnotes/wdnotes_cli apps/wdnotes/demo words 20 | families | links | stats
```

## Fonctionnalités

### Arbre des notes (gauche)
Navigation, filtre instantané (titre, contenu, étiquettes), menu contextuel
(clic droit) et boutons : nouvelle note, sous-note, monter, descendre,
indenter (devient enfant de la précédente), désindenter, *Déplacer vers…*,
renommer (les liens `[[…]]` des autres notes sont mis à jour), étiquettes,
format, suppression. ★ marque la note principale, ◈ la note lexique,
`#étiquette` les étiquettes. Double-clic : aperçu en consultation.

### Conception
Éditeur Markdown écrit pour l'occasion (contrôle personnalisé wdgui) :
coloration (titres, listes, citations, code, liens, `[[liens]]`,
`{ instructions }`), retour à la ligne doux, numéros de ligne, sélection
souris / clavier, double et triple clic, presse-papiers, annuler / rétablir,
continuation automatique des listes, tâches et citations, Tab / Maj+Tab pour
indenter. Raccourcis : Ctrl+B, Ctrl+I, Ctrl+K (lien vers une note), Ctrl+S,
Ctrl+F (recherche globale), Ctrl+E ou Ctrl+Entrée (aperçu), Ctrl+N, Ctrl+D
(dupliquer la ligne). Le premier `# Titre` de la note est son titre.

La **barre du haut** insère les balises : titres, gras, italique, barré, code,
citation, listes, tâches, lien web, lien vers une note (sélecteur filtrable),
image, tableau, bloc de code, filet, saut de page, bloc stylé `::: balise`,
passage stylé `[texte]{.balise}` et instructions `{ … }` en fin de ligne.

### Consultation
Le document est mis en page avec les paramètres du projet : une « feuille »
par note, aux marges, fond, en-tête et pied de page de son format, avec la
police, la taille, la couleur, l'alignement, les espacements, retraits et
cadres de chaque balise. Trois portées :

* **Document du projet** — à partir de la note principale (puis le reste du projet) ;
* **Note courante** — aperçu rapide ;
* **Note courante et ses sous-notes**.

Les liens sont cliquables : `[[note]]` (navigation), note absente (proposition
de la créer), URL (navigateur). Chaque note affiche ses rétroliens.

### Graphe
Chaque note est un point (taille selon le nombre de liens, couleur selon
l'étiquette ou la branche, anneau doré pour la note principale) ; les liens
`[[…]]` sont des traits pleins, la hiérarchie des pointillés (masquable).
Molette : zoom autour du pointeur. Glisser le fond : déplacement. Glisser un
point : le repositionner. Clic : bulle d'extrait + fiche à droite avec
*Éditer* / *Consulter*. Double-clic : ouvrir la note. La disposition est
calculée par forces (Fruchterman-Reingold), de façon déterministe.

### Lexique (droite)
**Termes** : tous les mots (hors mots vides, ≥ 3 lettres) avec leur nombre
d'occurrences, triables, filtrables. Un clic sur un terme liste les notes qui
l'utilisent avec le nombre d'occurrences ; un nouveau clic sur une note liste
les lignes concernées ; un double-clic ouvre la note à la ligne. *◂ Retour*
remonte d'un niveau.

**Familles** : la *note lexique* du projet (◈) range les mots par famille :

```markdown
# Lexique
## Légumes
tomates, radis, épinards
## Sol et compost
compost, terreau, paille
```

La vue offre les mêmes possibilités par famille (notes, puis lignes). Les mots
sans famille sont rattachés à la famille **« isolé »**.

## Markdown étendu : `{ instructions }`

Tout bloc (titre, paragraphe, élément de liste, tableau, filet, bloc de code,
bloc `:::`) et tout élément en ligne peut être suffixé par `{ … }` :

```markdown
# Titre centré {align: center; color: #7a2e2e}
Un paragraphe d'avertissement. {.alerte}
- Un élément de liste en vert {color: vert}
Texte [surligné]{.surligne}, **gras rouge**{color: rouge}, `code`{bg: #fff3a3}.
::: encadre
Plusieurs paragraphes dans un cadre.
:::
{ size: 9; italic }        ← une ligne seule stylise le bloc précédent
\pagebreak                 ← saut de page (aussi <<< ou \newpage)
```

`.nom` applique une **balise du modèle** (personnalisée) ; les autres paires
complètent ou remplacent les propriétés. Clés reconnues (alias français
entre parenthèses) : `font` (police), `size` (taille, `+2`, `-1`, `120%`),
`bold` (gras), `italic` (italique), `underline` (souligne), `strike` (barre),
`upper` (majuscules), `color` (couleur), `bg` (fond), `align` (alignement :
left/gauche, center/centre, right/droite, justify/justifie), `before` (avant),
`after` (apres), `indent` (retrait), `line` (interligne), `border` (bordure),
`frame` (cadre : left, box, bottom, top), `prefix` (prefixe), `break` (saut).
Les couleurs acceptent `#rgb`, `#rrggbb` et des noms (rouge, bleu, vert,
marine, or…).

## Formats, étiquettes, modèles

* Un **format** définit la page (papier, orientation, marges, en-tête, pied de
  page, fond — avec `{project}`, `{title}`, `{page}`, `{pages}`, `{date}`) et
  la mise en forme de **toutes les balises** Markdown (`body`, `title`, `h1`…`h6`,
  `p`, `quote`, `li`, `task`, `codeblock`, `code`, `strong`, `em`, `strike`,
  `link`, `wikilink`, `table`, `th`, `td`, `hr`, `image`, `header`, `footer`) ainsi
  que des balises personnalisées. Une cellule vide hérite du format par défaut.
* Une **étiquette** a une couleur et peut être **associée à un format**.
* Un **modèle** regroupe formats, étiquettes et balises. Le modèle par défaut
  « Classique » (serif, marine et or) est intégré et en lecture seule : il se
  **clone** sous un nouveau nom pour être modifié (« Moderne » est fourni en
  exemple dans la démo). Les modèles clonés sont enregistrés dans
  `templates/*.json`.

**Héritage** : le format d'une note est, dans l'ordre, son format propre, le
format associé à l'une de ses étiquettes, celui de son parent, le format global
du projet, puis le format par défaut du modèle.

**Application** (onglet ¶ Formats, cible = une note ou le projet entier) :

| Politique | Effet |
|---|---|
| Note seule | la note reçoit le format, ses enfants l'héritent sauf s'ils ont le leur |
| Forcer sur tous les descendants | tous les descendants reçoivent le format |
| Descendants sans format | seuls les descendants sans format propre le reçoivent |
| Descendants portant l'étiquette… | seuls ceux qui portent l'étiquette choisie |
| Descendants sans format portant l'étiquette… | combinaison des deux |

*Retirer (hériter)* rend la note (et éventuellement ses descendants) à l'héritage.
Les dialogues natifs de wdgui sont utilisés pour la couleur, la police et la
mise en page.

## Exports

Tous les exports partagent le même modèle de rendu (`render.nim`) que la vue
consultation : formats, étiquettes, balises et `{ }` sont respectés partout.

| Format | Fichier | Contenu |
|---|---|---|
| PDF | `.pdf` | moteur de mise en page intégré, sans dépendance : polices standard (Helvetica, Times, Courier) en WinAnsi (accents, œ, « », —), justification, pagination, format de page par note, en-têtes / pieds avec numéros, tableaux (en-tête répété), cadres, liens internes et web, signets |
| HTML/CSS/JS | dossier `index.html`, `style.css`, `script.js` | une « feuille » par note, sommaire latéral actif, recherche, thème sombre, impression avec `@page` |
| RTF | `.rtf` | tables de polices/couleurs, page, en-tête et pied avec champs PAGE/NUMPAGES, signets et hyperliens, tableaux |
| LibreOffice | `.fodt` (Flat ODT) | ouvert nativement par LibreOffice Writer : styles automatiques, mise en page, en-tête/pied avec numéro de page, titres de plan, signets, liens, tableaux |

## Organisation du code

| Fichier | Rôle | Dépend de wdgui |
|---|---|---|
| `wdnotes.nim` | fenêtre, mise en page, gestionnaire d'événements, commandes | oui |
| `wdcompat.nim` | **couche d'adaptation** à l'API de dessin wdgui | oui |
| `ctl_editor.nim` | contrôle `MdEditor` (conception) | oui |
| `ctl_docview.nim` | contrôle `DocView` (consultation) | oui |
| `ctl_graph.nim` | contrôle `GraphView` (graphe) | oui |
| `mdmodel.nim` | analyseur Markdown + `{ }` | non |
| `styles.nim` | styles, formats, étiquettes, modèles, modèle intégré | non |
| `project.nim` | projet, arbre, persistance, liens, héritage des formats | non |
| `lexicon.nim` | occurrences, familles, lignes | non |
| `render.nim` | document mis en forme commun à la vue et aux exports | non |
| `graphlayout.nim` | disposition du graphe | non |
| `exp_pdf.nim`, `exp_html.nim`, `exp_rtf.nim`, `exp_odt.nim`, `exporters.nim` | exports | non |
| `wdnotes_cli.nim` | outil en ligne de commande | non |

Un projet est un dossier : `wdnotes.json` (arbre, titres, formats, étiquettes,
réglages), `notes/<id>.md` (une note par fichier, éditable avec n'importe quel
outil) et `templates/*.json`.

Les gestionnaires wdgui s'exécutent chacun dans leur thread (tutoriel, étape 6) :
l'état de l'application est protégé par un verrou réentrant, relâché pendant les
boîtes de dialogue bloquantes. Les contrôles personnalisés reçoivent leurs
commandes par l'API par identifiant (`id.value = "commande" & Sep & argument`),
ce qui garantit l'accès thread-safe prévu par la bibliothèque.

## Points d'adaptation

wdnotes a été écrit à partir du README et du TUTORIAL de wdgui, sans pouvoir être
compilé dans l'environnement où il a été produit. Le tutoriel décrit précisément
les événements, l'API par identifiant, les conteneurs, listes, grilles et
dialogues, mais ne fait que **nommer** la plupart des primitives de dessin. Tout
ce qui n'est pas documenté est donc concentré dans `wdcompat.nim`, avec des
alternatives `when compiles(...)` :

* rectangles, rectangles arrondis, traits, cercles, ombre, découpage (`gfx*`) ;
* choix de police et de taille pendant le dessin (`gfxFont`) — si wdgui ne
  l'expose pas, la consultation utilise la police du thème (le gras est simulé
  et la mise en page reste cohérente) ;
* champs de `KeyEvent` (`keyCode`, `keyMods`, type `WdKeyEvent`) et codes SDL3 ;
* presse-papiers SDL, bouton plat, focus, sélection d'onglet et de nœud d'arbre,
  dialogue de mise en page ;
* `SplitSideBySide` : sens de `newSplitter(vertical = …)`.

Si une erreur de compilation apparaît, c'est en principe dans ce fichier (ou
dans la signature d'une méthode des trois contrôles : `onKey`, `onWheel`)
qu'il faut ajuster un nom.

### Encore une chose !
Un p'tit geste qui peut - grandement - nous aider... \[La caféïne c'est important pour une équipe de neuro-atypiques : TSA, TDAH, TAG, HPI et/ou THPI (membres de **mensa.fr** et de **triplenine.org**).\]

[![Buy Me a Coffee](../../buymeacoffe-fre.png)](https://buymeacoffee.com/sonaliwan.fr)
