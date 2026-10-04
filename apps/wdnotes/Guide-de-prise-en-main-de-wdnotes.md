![](wdnotes.png)
# Guide de prise en main de wdnotes

## Introduction

En une heure, ce guide vous fait construire un **carnet de recettes familiales** complet avec wdnotes, et utiliser au passage toutes ses fonctions. Aucune connaissance préalable n'est nécessaire.

wdnotes est un logiciel de prise de notes. Chaque note est un petit texte écrit en **Markdown**, une façon très simple de mettre en forme du texte avec quelques signes (`#` pour un titre, `**` pour du gras). Les notes sont rangées en **arbre**, comme des dossiers et sous-dossiers, et peuvent se citer les unes les autres par des **liens**.

À la fin du guide, vous saurez :

- créer un projet et organiser ses notes en chapitres et sous-chapitres ;
- écrire et mettre en forme une recette, sans connaître le Markdown à l'avance ;
- relier les recettes entre elles et naviguer d'une note à l'autre ;
- relire le carnet mis en page, comme un livre ;
- visualiser les liens sous forme de graphe ;
- analyser le vocabulaire (quels ingrédients reviennent le plus souvent) ;
- choisir polices, couleurs et marges, puis imprimer le carnet en PDF ou l'ouvrir dans LibreOffice.

**Le fil rouge.** Vous allez créer le projet « Recettes de famille », avec trois chapitres (Entrées, Plats, Desserts), quelques recettes, une note « Ingrédients de base » à laquelle les recettes renvoient, et une note lexique qui classe les ingrédients par famille. Chaque étape ajoute une fonction ; faites-les dans l'ordre.

> Conseil : si vous préférez d'abord regarder un projet déjà rempli, wdnotes s'ouvre au premier lancement sur le projet de démonstration « Jardin partagé ». Vous pouvez tout y essayer sans risque, puis revenir à ce guide.

## Découvrir l'écran

La fenêtre de wdnotes se divise en six zones, toujours au même endroit : vous écrivez au centre, vous choisissez la note à gauche et vous analysez le vocabulaire à droite.

```
┌ Fichier  Note  Édition  Affichage  Aide ──────────────────────────────────────┐  ① menu
│ H1 H2 H3 │ G I S </> │ ❝ • 1. ☐ │ Lien [[Note]] … │ Enregistrer ⇩PDF ◐        │  ② barre Markdown
├────────────────┬──────────────────────────────────────────┬───────────────────┤
│ ③ arbre       │ ④ Conception │ Consultation │ Graphe │ ¶ │ ⑤ Termes/Familles │
│   des notes   │                                          │                  │
├───────────────┴──────────────────────────────────────────┴──────────────────┤
│ ⑥ barre d'état                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

| Zone | Où | À quoi elle sert |
| --- | --- | --- |
| ① Menu | tout en haut | Fichier (projets, exports), Note (gestion de l'arbre), Édition (recherche, liens), Affichage (changer de vue), Aide (syntaxe) |
| ② Barre Markdown | sous le menu | insérer titres, gras, listes, tableaux, liens… d'un clic ; à droite : Enregistrer, export PDF rapide, thème clair ou sombre (◐) |
| ③ Arbre des notes | à gauche | voir et choisir les notes ; boutons ＋ ↳ ↑ ↓ → ← ✕ en bas pour les créer et les déplacer |
| ④ Zone centrale | au milieu | quatre onglets : ✎ Conception (écrire), ◉ Consultation (relire), ⬡ Graphe (liens), ¶ Formats (mise en forme) |
| ⑤ Lexique | à droite | deux onglets : Termes (mots les plus fréquents) et Familles (mots classés par thème) |
| ⑥ Barre d'état | tout en bas | messages, format de la note, nombre de mots et de liens, position du curseur (Ln, Col) |

Les séparations entre l'arbre, la zone centrale et le lexique sont mobiles : faites-les glisser avec la souris pour agrandir la partie qui vous intéresse.

## Étape 1 — Lancer wdnotes et créer le projet

Un projet wdnotes est simplement un dossier sur votre disque ; vous allez créer le dossier « RecettesDeFamille ».

**Lancer le programme.** Depuis le dossier de wdgui, tapez dans un terminal :

```
nimble wdnotes
```

Au premier lancement, wdnotes ouvre le projet de démonstration « Jardin partagé ». Vous pouvez aussi ouvrir directement un projet en donnant son dossier : `apps/wdnotes/wdnotes MonDossier`.

**Créer votre projet.**

1. Menu **Fichier › Nouveau projet…**
2. Dans la fenêtre d'enregistrement, choisissez l'emplacement (par exemple vos Documents) et tapez le nom `RecettesDeFamille`.
3. Validez. wdnotes crée le dossier et deux notes de départ :
   - « RecettesDeFamille », la **note principale** (marquée ★ dans l'arbre) : c'est la première page du carnet ;
   - « Lexique », la **note lexique** (marquée ◈) : elle servira à l'étape 8.
4. Le titre de la fenêtre devient « wdnotes — RecettesDeFamille ».

**Où sont vos fichiers ?** Le dossier du projet contient :

| Élément | Contenu |
| --- | --- |
| `wdnotes.json` | l'arbre des notes, leurs titres, étiquettes et formats, les réglages du projet |
| `notes/` | une note par fichier `.md`, en texte brut, lisible par n'importe quel éditeur |
| `templates/` | vos modèles de mise en forme personnels (créés à l'étape 10) |

**Enregistrer.** Votre travail est enregistré automatiquement quand vous changez de note, de vue, de projet ou quand vous fermez la fenêtre. Pour enregistrer à tout moment : **Ctrl+S** (Cmd+S sur Mac), le bouton **Enregistrer** ou **Fichier › Enregistrer**.

**Rouvrir plus tard.** **Fichier › Ouvrir un projet…**, puis sélectionnez le fichier `wdnotes.json` du dossier.

## Étape 2 — Construire l'arbre des notes

Vous allez obtenir l'arbre ci-dessous : trois chapitres sous la note principale, des recettes dans chaque chapitre, et une note de référence à part.

```
RecettesDeFamille  ★
├── Entrées
│   └── Velouté de potiron
├── Plats
│   ├── Gratin dauphinois
│   └── Poulet basquaise
└── Desserts
    ├── Tarte aux pommes de mamie
    └── Crème brûlée
Ingrédients de base
Lexique  ◈
```

**Deux façons de créer une note.** Chaque note est créée à partir de la note sélectionnée dans l'arbre :

| Commande | Bouton | Résultat |
| --- | --- | --- |
| Nouvelle note | ＋ (ou Ctrl+N) | une note **au même niveau**, juste après la note sélectionnée |
| Nouvelle sous-note | ↳ | une note **à l'intérieur** de la note sélectionnée (un enfant) |

Une petite fenêtre demande le titre ; tapez-le et validez. La nouvelle note s'ouvre aussitôt dans l'éditeur.

**Pas à pas.**

1. Cliquez sur « RecettesDeFamille » dans l'arbre, puis sur **↳** : créez « Entrées ».
2. « Entrées » étant sélectionnée, cliquez sur **＋** : créez « Plats », puis encore **＋** pour « Desserts ». Les trois chapitres sont au même niveau.
3. Sélectionnez « Entrées », cliquez sur **↳** et créez « Velouté de potiron ».
4. Faites de même pour les recettes de « Plats » et de « Desserts ».
5. Sélectionnez « Lexique », cliquez sur **＋** et créez « Ingrédients de base ».

**Réorganiser.** Sélectionnez une note, puis utilisez les boutons sous l'arbre :

| Bouton | Effet |
| --- | --- |
| ↑ / ↓ | monte ou descend la note parmi ses sœurs |
| → | **indente** : la note devient l'enfant de la note qui la précède |
| ← | **désindente** : la note remonte d'un niveau, juste après son ancien parent |
| ✕ | supprime la note, après confirmation ; ses sous-notes sont supprimées avec elle |

Une note emporte toujours ses sous-notes quand elle se déplace. Essayez : placez « Ingrédients de base » juste sous « RecettesDeFamille » avec **↑**, puis remettez-la en place avec **↓**.

**Le menu contextuel.** Un **clic droit** sur l'arbre ouvre toutes les commandes de note : Renommer…, Déplacer vers…, Étiquettes…, Format…, Consulter, Supprimer… Les mêmes commandes sont dans le menu **Note**.

- **Déplacer vers…** ouvre une liste de toutes les notes (avec une case de filtre) : choisissez le nouveau parent, ou « (racine du projet) ». C'est le moyen le plus rapide de déplacer une note loin dans l'arbre.
- **Renommer…** change le titre. Les liens qui pointent vers cette note dans les autres notes sont corrigés automatiquement (voir l'étape 4).
- **Définir comme note principale ★** choisit la note par laquelle commence le carnet en consultation et à l'export.

**Retrouver une note.** La case **Filtrer les notes…** au-dessus de l'arbre n'affiche que les notes dont le titre, le texte ou les étiquettes contiennent ce que vous tapez (avec leurs parents, pour garder le repère). Tapez « pomme » : seule la branche de la tarte reste visible. Videz la case pour tout revoir.

Un **double-clic** sur une note l'affiche directement mise en page, dans l'onglet Consultation.

## Étape 3 — Écrire une recette

Vous écrivez dans l'onglet **✎ Conception** : un éditeur de texte qui colore les signes Markdown pour que vous voyiez la structure, sans jamais les cacher.

Ouvrez « Tarte aux pommes de mamie » dans l'arbre. Le haut de l'éditeur rappelle le titre de la note, son chemin dans l'arbre (RecettesDeFamille › Desserts › Tarte…) et son format.

**Le Markdown en 30 secondes.** Vous n'avez rien à retenir : la barre du haut insère les signes pour vous. Il suffit de savoir les reconnaître.

| Vous tapez | Vous obtenez | Bouton |
| --- | --- | --- |
| `# Titre` | un titre de niveau 1 (`##` niveau 2, `###` niveau 3) | H1 H2 H3 |
| `**mot**` | **gras** | G (ou Ctrl+B) |
| `*mot*` | *italique* | I (ou Ctrl+I) |
| `~~mot~~` | ~~barré~~ | S |
| `` `mot` `` | `code` (police à chasse fixe) | \</> |
| `> texte` | une citation, en retrait | ❝ |
| `- texte` | une liste à puces | • |
| `1. texte` | une liste numérotée | 1. |
| `- [ ] texte` | une case à cocher (`- [x]` cochée) | ☐ |
| `---` | un filet horizontal | — |

Pour utiliser un bouton : **sélectionnez** d'abord le texte (glissez la souris dessus), puis cliquez. Sans sélection, le bouton insère un exemple (« texte ») déjà sélectionné : tapez simplement par-dessus. Les boutons de titre, de liste et de citation s'appliquent à toutes les lignes sélectionnées ; cliquez une seconde fois pour les retirer.

**Pas à pas.** Tapez la recette ci-dessous dans la note, en vous aidant des boutons :

```markdown
# Tarte aux pommes de mamie

La tarte du dimanche, transmise par mamie Odette. **Préparation : 20 min**, cuisson : 35 min.

## Ingrédients

- 1 pâte brisée
- 6 pommes golden
- 50 g de beurre
- 3 cuillères de sucre

## Préparation

1. Préchauffer le four à 200 °C.
2. Éplucher les pommes et les couper en lamelles fines.
3. Disposer les lamelles en rosace sur la pâte.
4. Parsemer de beurre et de sucre, enfourner 35 minutes.

> « Le secret, c'est de ne pas être pressé. » — Mamie

## Pour la prochaine fois

- [x] Tester avec des pommes reinettes
- [ ] Ajouter un peu de cannelle
```

**L'éditeur vous aide.**

- **Listes automatiques.** En fin de ligne de liste, **Entrée** crée la puce suivante (le numéro suivant, une nouvelle case à cocher). Appuyez une seconde fois sur Entrée sur une puce vide pour terminer la liste.
- **Sous-listes.** Sur une ligne de liste, **Tab** décale l'élément vers la droite, **Maj+Tab** le ramène à gauche.
- **Tableau.** Le bouton **Table** insère un tableau prêt à remplir : les cellules sont séparées par `|`, la deuxième ligne (`|---|:---:|---:|`) règle l'alignement (`:---:` centré, `---:` à droite).
- **Bloc de code.** Le bouton **\`\`\`** encadre les lignes sélectionnées ; leur texte est affiché tel quel, sans mise en forme.
- **Annuler.** **Ctrl+Z** annule, **Ctrl+Maj+Z** ou **Ctrl+Y** rétablit. Ctrl+D duplique la ligne courante.
- **Sélection rapide.** Double-clic : un mot. Triple-clic : la ligne entière. Ctrl+A : tout. Maj+flèches : étendre la sélection. Ctrl+C, Ctrl+X, Ctrl+V : copier, couper, coller.

**Le titre suit le texte.** Le premier titre `# …` de la note **est** son titre : si vous écrivez `# Tarte aux pommes d'Odette`, l'arbre se met à jour dès l'enregistrement, et les liens des autres notes aussi.

La barre d'état indique en bas à droite la position du curseur (Ln 12, Col 4) et, au centre, le nombre de mots de la note.

Remplissez de la même façon au moins deux autres recettes, par exemple « Gratin dauphinois » et « Velouté de potiron » : elles serviront aux étapes suivantes.

## Étape 4 — Relier les notes

Un lien entre notes s'écrit en mettant le titre de la note visée entre doubles crochets : `[[Ingrédients de base]]`. Pas besoin de taper le titre exact à la main.

**Insérer un lien vers une note.**

1. Dans « Tarte aux pommes de mamie », placez le curseur après « 1 pâte brisée ».
2. Cliquez sur **\[\[Note\]\]** dans la barre (ou **Ctrl+K**).
3. Une fenêtre liste toutes les notes, indentées comme dans l'arbre. Tapez « ingr » dans la case de filtre, sélectionnez « Ingrédients de base », puis **Choisir** (ou double-clic).
4. Le texte devient `- 1 pâte brisée (voir [[Ingrédients de base]])`.

Pour que le lien affiche un autre texte que le titre, **sélectionnez d'abord ce texte** puis faites Ctrl+K. Le lien devient `[[Ingrédients de base|la pâte maison]]` : on lira « la pâte maison », et le clic mènera à la note.

Faites de même dans le gratin (vers la béchamel ou le beurre des ingrédients de base) et dans la note principale, qui peut renvoyer vers chaque chapitre : `Commencez par les [[Entrées]], puis les [[Plats]] et finissez par les [[Desserts]].`

**Les autres sortes de liens.**

| Bouton | Ce qui est inséré | Usage |
| --- | --- | --- |
| Lien | `[texte du lien](https://)` | une page web : remplacez `https://` par l'adresse |
| Image | `![légende](image.png)` | une photo du plat, placée dans le dossier du projet |

**Les rétroliens.** wdnotes connaît aussi les liens dans l'autre sens. La barre d'état indique, pour la note ouverte, le nombre de liens sortants et entrants (« 2 liens sortants · 3 entrants »). En consultation, chaque note se termine par la liste des notes qui la citent : ouvrez « Ingrédients de base » et vous verrez toutes les recettes qui s'en servent.

**Créer une note à partir d'un lien.** Écrivez un lien vers une note qui n'existe pas encore, par exemple `[[Pâte brisée maison]]` dans « Ingrédients de base ». En consultation, ce lien apparaît comme manquant ; cliquez dessus et wdnotes propose de créer la note comme sous-note de la note courante. C'est une façon naturelle d'écrire : on cite d'abord, on rédige ensuite.

**Renommer sans casser les liens.** Clic droit sur « Ingrédients de base » › **Renommer…** › « Ingrédients et bases ». Toutes les notes qui contenaient `[[Ingrédients de base]]` contiennent désormais `[[Ingrédients et bases]]`.

Remettez ensuite l'ancien nom « Ingrédients de base » de la même façon : la suite du guide l'utilise.

**Rechercher dans tout le carnet.** **Ctrl+F** (ou **Édition › Rechercher…**) : tapez « beurre ». La fenêtre de résultats affiche chaque ligne trouvée sous la forme « Titre · L12 · texte de la ligne ». Choisissez un résultat : la note s'ouvre et la ligne est sélectionnée.

## Étape 5 — Étiqueter les recettes

Une étiquette est un mot-clé attaché à une note, comme « végétarien » ou « brouillon ». Une note peut en porter plusieurs ; elles servent à repérer, filtrer, colorer et mettre en forme des groupes de notes.

**Poser des étiquettes.**

1. Sélectionnez « Velouté de potiron ».
2. Clic droit › **Étiquettes…** (ou menu **Note › Étiquettes…**).
3. La fenêtre rappelle les étiquettes disponibles dans le modèle (important, brouillon, annexe, chapitre, référence). Tapez `végétarien, important` et validez : les étiquettes sont séparées par des virgules.
4. Étiquetez aussi « Gratin dauphinois » (`végétarien`) et « Crème brûlée » (`brouillon`), puisque la recette n'est pas encore testée.

Pour retirer une étiquette, rouvrez la fenêtre et effacez-la de la liste.

**Où les voit-on ?**

- Dans l'**arbre** : « Velouté de potiron  #végétarien #important ».
- En haut de l'**éditeur**, à côté du format ; le titre prend la couleur de la première étiquette qui en a une.
- En **consultation**, sous forme de pastilles colorées en haut de la page de la note.
- Dans le **graphe**, les points prennent la couleur de leur étiquette.

**Filtrer par étiquette.** Tapez `végétarien` dans la case **Filtrer les notes…** : l'arbre ne montre plus que les recettes végétariennes.

Vous pouvez écrire n'importe quel mot comme étiquette. Pour lui donner une **couleur** (et éventuellement un **format** de mise en page), il faut la déclarer dans le modèle : ce sera fait à l'étape 10, où « végétarien » deviendra verte.

## Étape 6 — Relire le carnet en consultation

L'onglet **◉ Consultation** montre vos notes telles qu'elles seront imprimées : plus aucun signe Markdown, une feuille par note, avec les polices, couleurs, marges, en-tête et pied de page du format.

**Ouvrir la consultation.** Cliquez sur l'onglet ◉ Consultation, ou **Ctrl+E** (ou Ctrl+Entrée) depuis l'éditeur, ou **double-clic** sur une note de l'arbre.

**Choisir ce qu'on affiche.** La liste **Afficher** en haut propose trois portées :

| Portée | Ce qui s'affiche | Quand l'utiliser |
| --- | --- | --- |
| Document du projet | tout le carnet, en commençant par la note principale ★, puis les autres notes dans l'ordre de l'arbre (la note lexique est exclue) | relire l'ensemble, vérifier l'enchaînement |
| Note courante | uniquement la note sélectionnée | aperçu rapide pendant la rédaction |
| Note courante et ses sous-notes | la note et toute sa branche | relire un chapitre, par exemple « Desserts » |

En portée « Document du projet », la vue se place automatiquement sur la note sélectionnée dans l'arbre.

**Naviguer.**

- La **molette** fait défiler les pages ; les boutons **－** et **＋** réduisent ou agrandissent l'affichage.
- Un clic sur un lien **\[\[note\]\]** amène à cette note ; un clic sur un lien web l'ouvre dans votre navigateur ; un clic sur un lien vers une note manquante propose de la créer.
- **⟳ Actualiser** recalcule la mise en page ; **✎ Éditer** revient à la conception.

**À observer dans votre carnet.** La recette de tarte apparaît avec son titre en couleur, la liste d'ingrédients à puces, les étapes numérotées, la citation de mamie en italique avec un trait à gauche et les cases cochées ou non. En bas de la page, la ligne « Référencée par : » liste, sous forme de liens, les notes qui pointent vers la tarte.

La consultation se met à jour à chaque fois que vous y revenez : écrivez dans l'éditeur, puis Ctrl+E pour voir le résultat.

## Étape 7 — Explorer le graphe des liens

L'onglet **⬡ Graphe** dessine le carnet comme une carte : chaque note est un point, chaque lien `[[…]]` un trait. On voit d'un coup d'œil quelles notes sont centrales et lesquelles sont isolées.

**Lire le graphe.**

| Élément | Signification |
| --- | --- |
| Taille d'un point | nombre de liens de la note : « Ingrédients de base », très citée, est un gros point |
| Couleur d'un point | couleur de l'étiquette de la note, sinon couleur de sa branche |
| Anneau doré | la note principale ★ |
| Trait plein + petite pastille | un lien `[[…]]` ; la pastille est du côté de la note citée |
| Trait en pointillés | la hiérarchie de l'arbre (parent → enfant) |

En bas à gauche, une ligne résume le graphe : nombre de notes, de liens et niveau de zoom.

**Se déplacer.**

- **Molette** : zoom avant ou arrière, centré sur la position de la souris.
- **Glisser le fond** : déplacer toute la carte.
- **Glisser un point** : le repositionner à la main pour clarifier le dessin.
- Boutons **＋**, **－** et **⤢ Ajuster** (tout faire tenir dans la fenêtre) ; **⟳ Recalculer** refait la disposition automatique.
- La case **Afficher la hiérarchie (pointillés)** montre ou masque les liens parent-enfant pour ne garder que les liens écrits.

**Interroger une note.**

1. Survolez le point « Ingrédients de base » : ses voisins restent nets, le reste s'estompe, ses liens passent en doré.
2. **Cliquez** dessus : une bulle affiche le titre et un extrait du texte. La fiche à droite reprend le titre, le format, le nombre de liens sortants (→) et entrants (←) et les étiquettes.
3. Dans la fiche, **✎ Éditer la note** l'ouvre dans l'éditeur ; **◉ Consulter la note** l'affiche mise en page.
4. **Double-cliquez** sur un point pour l'ouvrir directement en conception.

**À quoi ça sert dans le carnet ?** Une recette sans aucun trait plein n'est citée nulle part et ne cite rien : c'est peut-être le signe qu'il manque un renvoi vers « Ingrédients de base » ou vers une recette d'accompagnement.

## Étape 8 — Analyser le vocabulaire

Le panneau de droite compte les mots de tout le carnet. Il répond à des questions comme « dans quelles recettes est-ce que j'utilise du beurre, et à quelle ligne ? ».

**L'onglet Termes.** Il liste chaque mot du carnet avec son nombre d'occurrences, du plus fréquent au moins fréquent. Les mots de moins de trois lettres et les mots vides (le, de, avec, pour…) sont ignorés. La case **Filtrer les termes…** réduit la liste ; un clic sur l'en-tête d'une colonne la trie.

L'exploration se fait en trois clics, du général au détail :

1. **Cliquez sur un terme**, par exemple « pommes ». La partie basse affiche les **notes** qui l'emploient, avec le nombre d'occurrences dans chacune et un extrait.
2. **Cliquez sur une note**, par exemple « Tarte aux pommes de mamie ». La partie basse affiche les **lignes** concernées : numéro (L7), nombre d'occurrences sur la ligne, texte de la ligne.
3. **Double-cliquez sur une ligne** : la note s'ouvre dans l'éditeur, cette ligne sélectionnée.

Le bouton **◂ Retour** remonte d'un niveau (des lignes aux notes, puis des notes à rien).

**La note lexique et l'onglet Familles.** Une famille regroupe des mots de même nature. Vous les déclarez dans la note lexique ◈, avec une règle très simple : un titre de niveau 2 par famille, puis les mots séparés par des virgules.

Ouvrez la note « Lexique » et remplacez son contenu par :

```markdown
# Lexique

## Fruits et légumes
pommes, pomme, potiron, terre, oignon, poivrons, tomates

## Produits laitiers
beurre, crème, lait, fromage, œufs

## Épicerie
sucre, farine, sel, poivre, cannelle, vanille

## Ustensiles
four, moule, casserole, plat, fouet
```

Une famille contient des **mots simples** : « pommes de terre » s'écrit `pommes, terre`, car le lexique compte les mots un par un. Mettez au besoin le singulier et le pluriel (`pomme, pommes`).

Enregistrez (Ctrl+S), puis ouvrez l'onglet **Familles**. Chaque famille apparaît avec son nombre de mots et le total de leurs occurrences dans le carnet. Tous les mots qui n'appartiennent à aucune famille sont rangés dans la famille **« isolé »** : parcourez-la pour repérer les ingrédients que vous avez oublié de classer.

Les familles s'explorent exactement comme les termes : un clic sur « Produits laitiers » liste les recettes qui en contiennent (le libellé rappelle les premiers mots de la famille), un clic sur une recette liste les lignes, un double-clic ouvre la ligne.

Pour désigner une autre note comme note lexique : clic droit sur elle › **Définir comme note lexique ◈**. Une seule note joue ce rôle à la fois.

## Étape 9 — Personnaliser un passage avec { }

wdnotes ajoute au Markdown une seule invention : des **instructions entre accolades** placées à la fin d'une ligne, qui changent l'apparence de cette ligne. Elles sont visibles en violet dans l'éditeur et invisibles en consultation.

**Une instruction sur une ligne.** Dans la tarte, modifiez le titre et la préparation :

```markdown
# Tarte aux pommes de mamie {color: #8b4513; align: center}

La tarte du dimanche, transmise par mamie Odette. {italique; taille: 13}
```

Le titre devient brun et centré, la phrase d'introduction passe en italique un peu plus grande. Plusieurs instructions se séparent par des points-virgules ; une clé seule (`italique`) vaut « oui ».

**Les clés disponibles.** Vous pouvez écrire les noms anglais ou leurs équivalents français.

| Clé (alias) | Effet | Exemple |
| --- | --- | --- |
| `color` (couleur) | couleur du texte | `{couleur: rouge}`, `{color: #a33}` |
| `bg` (fond) | couleur de fond | `{fond: #fff3a3}` |
| `font` (police) | police : Serif, Sans, Mono | `{police: Sans}` |
| `size` (taille) | taille en points, ou relative | `{taille: 14}`, `{size: +2}`, `{size: 120%}` |
| `bold`, `italic`, `underline`, `strike`, `upper` (gras, italique, souligne, barre, majuscules) | style du texte | `{gras; majuscules}` |
| `align` (alignement) | gauche, centre, droite, justifie | `{align: centre}` |
| `before`, `after` (avant, apres) | espace avant et après, en points | `{avant: 12}` |
| `indent` (retrait), `line` (interligne) | retrait gauche, interligne | `{retrait: 20; interligne: 1.6}` |
| `frame` (cadre), `border` (bordure) | cadre : left, box, bottom, top, et sa couleur | `{cadre: box; bordure: #c9a227}` |
| `prefix` (prefixe) | texte ajouté au début | `{prefixe: "Astuce : "}` |
| `break` (saut) | commence une nouvelle page | `{saut}` |

Les couleurs acceptent `#rgb`, `#rrggbb` et des noms courants : rouge, bleu, vert, marine, or, gris…

**Les balises du modèle.** Plutôt que de répéter les mêmes instructions, utilisez une balise toute prête, en la précédant d'un point. Le modèle par défaut en fournit huit :

| Balise | Rendu | Sorte |
| --- | --- | --- |
| `.alerte` | encadré rouge, préfixe d'avertissement | bloc |
| `.astuce` | encadré vert | bloc |
| `.encadre` | cadre complet | bloc |
| `.centre` | texte centré | bloc |
| `.signature` | aligné à droite, en italique | bloc |
| `.surligne` | fond jaune | en ligne |
| `.petit` | texte plus petit | en ligne |
| `.rouge` | texte rouge | en ligne |

Une balise de bloc s'applique à une ligne entière ; une balise en ligne s'applique à un passage. Exemples pour la tarte :

```markdown
Ne jamais ouvrir le four pendant les 20 premières minutes. {.alerte}

Une boule de glace vanille et c'est parfait. {.astuce}

Servir [tiède]{.surligne}, jamais [brûlant]{.rouge}.

**200 °C**{couleur: rouge} pendant 35 minutes.

::: encadre
Variante normande : ajoutez une cuillère de calvados
aux pommes avant la cuisson.
:::

Mamie Odette {.signature}
```

- `[texte]{.balise}` met en forme un passage choisi ; un élément gras, italique ou un lien peut aussi être suivi de `{…}`.
- `::: encadre` … `:::` applique la balise à **plusieurs paragraphes** d'un coup.
- Une ligne qui ne contient **que** des accolades, comme `{ taille: 9 }`, met en forme le paragraphe qui la précède.

**Sans rien taper.** Trois boutons de la barre font tout cela pour vous :

| Bouton | Action |
| --- | --- |
| ::: Bloc | choisissez une balise de bloc dans la liste : les lignes sélectionnées sont entourées par `::: balise` et `:::` |
| \[ \]{.} | choisissez une balise en ligne : le texte sélectionné devient `[texte]{.balise}` |
| { } | choisissez une balise, ou « Instructions libres… » pour taper vos propres instructions : elles sont ajoutées à la fin de la ligne |

**Saut de page.** Le bouton **Saut** insère `\pagebreak` sur sa propre ligne : à l'export PDF ou LibreOffice, la suite commence sur une nouvelle page. En consultation, il est matérialisé par un trait « saut de page ».

Aide-mémoire intégré : menu **Aide › Syntaxe Markdown étendue**.

## Étape 10 — Formats, étiquettes et modèles

Les instructions `{ }` règlent un passage ; les **formats** règlent l'apparence de notes entières, d'un seul geste. Tout se passe dans l'onglet **¶ Formats**.

**Trois notions emboîtées.**

| Notion | Ce qu'elle contient | Exemple dans le carnet |
| --- | --- | --- |
| Modèle | un ensemble de formats, d'étiquettes et de balises personnalisées ; un projet utilise un modèle | « Carnet de cuisine » |
| Format | la page (papier, marges, en-tête, pied de page, fond) et l'apparence de chaque balise Markdown | « Standard », « Dessert » |
| Étiquette | un nom, une couleur et, si on le souhaite, un format associé | « végétarien » en vert |

### 10.1 Cloner le modèle par défaut

Le modèle intégré « Classique » (texte serif, titres bleu marine, filets dorés) est **en lecture seule** : il sert de base sûre. Pour le modifier, on en fait une copie.

1. Onglet **¶ Formats**, ligne **Modèle** : cliquez sur **Cloner…**
2. Nommez la copie « Carnet de cuisine ». Elle est créée, sélectionnée et utilisée par le projet.

Si vous essayez de modifier « Classique » directement, wdnotes vous propose ce clonage de lui-même. La liste **Modèle** permet de passer d'un modèle à l'autre ; **Renommer…** et **Supprimer** ne concernent que vos copies.

### 10.2 Régler le format Standard

Dans la liste **Format**, choisissez « Standard (défaut) » : c'est le format de base dont héritent tous les autres.

**La page.** Le cadre « Page, en-tête et pied de page » propose :

| Champ | Valeur pour le carnet |
| --- | --- |
| Papier, Orientation | A5, Portrait (un petit livret) |
| Marges haut, bas, gauche, droite | 15, 15, 18, 15 (en millimètres) |
| En-tête | `{project} — {title}` |
| Pied de page | `{page} / {pages}` |
| Fond de page | vide (blanc) |

Dans l'en-tête et le pied, `{project}` est remplacé par le nom du projet, `{title}` par le titre de la note, `{page}` et `{pages}` par le numéro de page et le nombre total de pages, `{date}` par la date du jour. Cliquez sur **Appliquer la page**. Le bouton **Mise en page…** ouvre plutôt la fenêtre de mise en page de votre système.

**Les balises.** La grande grille contient une ligne par balise : les balises Markdown (`body` pour le texte courant, `title` pour le titre de la note, `h1` à `h6`, `p`, `quote`, `li`, `task`, `codeblock`, `code`, `strong`, `em`, `strike`, `link`, `wikilink`, `table`, `th`, `td`, `hr`, `image`, `header`, `footer`) puis les balises personnalisées (`alerte`, `astuce`…).

Les colonnes correspondent aux clés de l'étape 9 : Police, Taille, G (gras), I (italique), S (souligné), Couleur, Fond, Align., Avant, Après, Retrait, Cadre, Bordure, Préfixe, et **Autres { }** pour les clés restantes (`line: 1.5; upper`). Pour modifier une valeur, cliquez dans la cellule et tapez ; les cases G, I et S se cochent ; Police, Align. et Cadre proposent une liste.

Exemple : donnons aux sous-titres « Ingrédients » et « Préparation » une couleur chaude.

1. Cliquez sur la ligne `h2`.
2. Cliquez sur **Couleur…** et choisissez un brun orangé dans la palette : la cellule Couleur prend sa valeur (par exemple `#b5541c`).
3. Cliquez sur **Police…** pour choisir police, taille, gras et italique d'un coup.
4. Revenez en Consultation : tous les `##` du carnet ont changé.

**Une balise à vous.** **Nouvelle balise…** › nommez-la `temps` › répondez **OK** (balise en ligne). Donnez-lui Couleur `#b5541c` et cochez G. Dans les recettes, écrivez désormais `[35 min]{.temps}`. **Supprimer la balise** retire une balise personnalisée du modèle.

### 10.3 Créer un format pour les desserts

1. Ligne **Format** : **Nouveau…** › « Dessert ». Le nouveau format est vide : **toutes ses cellules vides héritent** du format Standard. Vous ne réglez que les différences.
2. Fond de page : `#fff8f0` (crème), puis **Appliquer la page**.
3. Dans la grille, ligne `title` : Couleur `#a0522d`, Taille `24`.

**Dupliquer…** part d'une copie du format affiché ; **Par défaut** fait du format affiché le format de base du modèle ; **Supprimer** retire le format (les notes qui l'utilisaient héritent de nouveau).

### 10.4 Appliquer un format

Le cadre « Application du format » applique le format affiché à une **cible**.

1. Sélectionnez « Desserts » dans l'arbre, puis clic droit › **Format…** (ou bouton **Cible = note courante**). La ligne Cible indique « Desserts » et son format actuel.
2. Format : « Dessert ». Politique : **Note seule (les enfants héritent)**.
3. **Appliquer le format**. La barre d'état indique le nombre de notes modifiées.

La tarte et la crème brûlée n'ont rien reçu : elles **héritent** du format de leur parent. Toute nouvelle recette ajoutée sous « Desserts » aura aussi le fond crème.

| Politique | Effet |
| --- | --- |
| Note seule (les enfants héritent) | seule la cible reçoit le format ; ses descendants en héritent sauf s'ils ont le leur |
| Forcer sur tous les descendants | la cible et tous ses descendants reçoivent le format, en écrasant leurs formats propres |
| Descendants sans format | seuls les descendants qui n'ont pas de format propre le reçoivent |
| Descendants portant l'étiquette… | seuls les descendants qui portent l'étiquette choisie dans la liste voisine |
| Descendants sans format portant l'étiquette… | les deux conditions à la fois |

**Retirer (hériter)** efface le format propre de la cible (et, si vous le confirmez, de ses descendants) : elle reprend celui de son parent.

**Mise en forme globale.** Menu **Affichage › Mise en forme globale…** (ou **Cible = projet (global)**) : le format choisi devient celui de tout le projet, pour toutes les notes qui n'en ont pas d'autre.

### 10.5 Étiquettes avec couleur et format

1. Cadre « Étiquettes » : **Nouvelle étiquette…** › `végétarien`.
2. Dans la grille, colonne Couleur : `#2e7d32`. Colonne **Format associé** : choisissez un format (par exemple un format « Végétarien » créé comme à l'étape 10.3, au titre vert).
3. Toutes les notes étiquetées « végétarien » prennent ce format, sauf si elles ont un format propre.

**Comment wdnotes choisit le format d'une note.** Il prend la première réponse dans cet ordre :

1. le format propre de la note ;
2. le format associé à l'une de ses étiquettes ;
3. le format de son parent (et ainsi de suite en remontant l'arbre) ;
4. le format global du projet ;
5. le format par défaut du modèle.

Le haut de l'éditeur affiche toujours le format retenu et son origine (« format « Dessert » (hérité de Desserts) »). Vos modèles sont enregistrés dans le dossier `templates/` du projet : copiez le fichier `.json` dans un autre projet pour y retrouver votre mise en forme.

## Étape 11 — Exporter et partager le carnet

Un export produit le **document du projet** tel que vous le voyez en consultation : la note principale d'abord, puis toutes les notes dans l'ordre de l'arbre (la note lexique est exclue), avec leurs formats, étiquettes, balises et instructions `{ }`.

**Exporter.** Menu **Fichier**, puis l'un des quatre exports. Une fenêtre demande l'emplacement et le nom du fichier ; l'extension est ajoutée si vous l'oubliez.

| Commande | Résultat | Pour quoi faire |
| --- | --- | --- |
| Exporter en PDF… (ou bouton ⇩ PDF) | un fichier `.pdf` paginé, au format de page de chaque note, avec en-têtes et pieds numérotés, liens cliquables et signets | imprimer le carnet, l'envoyer par courriel |
| Exporter en HTML/CSS/JS… | un **dossier** contenant `index.html`, `style.css` et `script.js` : une page par note, sommaire latéral, case de recherche, thème sombre, impression soignée | publier le carnet sur un site, le consulter dans un navigateur |
| Exporter en RTF… | un fichier `.rtf` avec styles, tableaux, liens et numéros de page | l'ouvrir dans Word, TextEdit ou WordPad |
| Exporter pour LibreOffice (.fodt)… | un document `.fodt` (format OpenDocument en un seul fichier) | le retravailler dans LibreOffice Writer |

**Pas à pas : imprimer le livret.**

1. Vérifiez la note principale ★ : c'est la première page. Écrivez-y une préface et, au besoin, un `\pagebreak` à la fin.
2. **Fichier › Exporter en PDF…** › nommez le fichier `Recettes de famille.pdf`.
3. Un message confirme l'emplacement du fichier. Ouvrez-le : les notes s'enchaînent sur des pages A5, les desserts commencent sur une nouvelle page avec leur fond crème, le pied de page affiche « 3 / 12 ».
4. Dans votre lecteur PDF, le panneau des signets liste les recettes ; les liens `[[…]]` mènent à la bonne page.

Les notes se suivent sans saut de page, sauf quand le format de page change (comme pour les desserts) ou quand un `\pagebreak` le demande. Pour que **chaque recette commence sur une nouvelle page**, ajoutez `break: true` dans la colonne **Autres { }** de la ligne `title` du format Standard (étape 10.2).

Pour la version HTML, wdnotes propose à la fin d'ouvrir directement la page dans votre navigateur. Pour LibreOffice, ouvrez le `.fodt` dans Writer puis, si vous le souhaitez, **Fichier › Enregistrer sous** au format `.odt` ou `.docx`.

**Bon à savoir sur les polices.** Le PDF utilise les trois polices standard que tous les lecteurs connaissent : Serif devient Times, Sans devient Helvetica, Mono devient Courier. Les accents, « guillemets », œ et tirets sont bien gérés. Les autres exports transmettent le nom de la police au logiciel qui ouvre le fichier.

**Sans ouvrir l'interface.** Le programme `wdnotes_cli` fait les mêmes exports depuis un terminal, pratique pour automatiser :

```
wdnotes_cli RecettesDeFamille export pdf  recettes.pdf
wdnotes_cli RecettesDeFamille export html site_recettes
wdnotes_cli RecettesDeFamille export odt  desserts.fodt "Desserts"
wdnotes_cli RecettesDeFamille stats
wdnotes_cli RecettesDeFamille words 20
wdnotes_cli RecettesDeFamille families
wdnotes_cli RecettesDeFamille links
```

Avec un titre de note en dernier argument, l'export se limite à cette note et à ses sous-notes (ici, le chapitre Desserts). `stats` résume le carnet, `words 20` affiche les 20 mots les plus fréquents, `families` les familles du lexique, `links` tous les liens entre notes.

## Aide-mémoire et dépannage

**Raccourcis clavier de l'éditeur.** Sur Mac, Cmd fonctionne comme Ctrl.

| Raccourci | Action |
| --- | --- |
| Ctrl+S | enregistrer le projet |
| Ctrl+N | nouvelle note au même niveau |
| Ctrl+K | insérer un lien vers une note |
| Ctrl+F | rechercher dans toutes les notes |
| Ctrl+E ou Ctrl+Entrée | voir la note en consultation |
| Ctrl+B / Ctrl+I | gras / italique |
| Ctrl+Z / Ctrl+Maj+Z ou Ctrl+Y | annuler / rétablir |
| Ctrl+D | dupliquer la ligne |
| Ctrl+A, Ctrl+C, Ctrl+X, Ctrl+V | tout sélectionner, copier, couper, coller |
| Tab / Maj+Tab | indenter / désindenter une liste |
| Ctrl+← / Ctrl+→ | mot précédent / suivant |
| Ctrl+↑ / Ctrl+↓, Début / Fin | début / fin du texte, de la ligne |
| Échap | annuler la sélection |

**Souris.**

| Où | Geste | Effet |
| --- | --- | --- |
| Arbre | clic / double-clic / clic droit | ouvrir la note / la consulter / menu des commandes |
| Éditeur | double-clic / triple-clic | sélectionner le mot / la ligne |
| Consultation | molette / clic sur un lien | défiler / suivre le lien |
| Graphe | molette / glisser / clic / double-clic | zoomer / déplacer / extrait / ouvrir |
| Lexique | clic / double-clic / ◂ Retour | descendre d'un niveau / ouvrir la ligne / remonter |

**La syntaxe en un coup d'œil.**

```markdown
# Titre {color: #8b4513; align: center}
## Sous-titre
**gras**  *italique*  ~~barré~~  `code`
- puce          1. numéro          - [ ] tâche
> citation
[[Titre de note]]   [[Titre de note|texte affiché]]   [lien](https://…)
![légende](image.png)
Paragraphe {.alerte}        [passage]{.surligne}
::: encadre
plusieurs paragraphes
:::
{ taille: 9 }               ← met en forme le paragraphe précédent
\pagebreak                  ← saut de page à l'export
```

**Questions fréquentes.**

- **J'ai perdu une modification ?** Les changements sont enregistrés en changeant de note ou de vue, et à la fermeture. En cas de doute, Ctrl+S. Dans une note, Ctrl+Z remonte loin dans l'historique.
- **Mon lien `[[…]]` n'est pas cliquable en consultation.** Le titre ne correspond à aucune note (faute de frappe, accent) : le lien est signalé comme manquant. Cliquez dessus pour créer la note, ou corrigez le titre avec Ctrl+K.
- **Je ne peux pas modifier la grille des formats.** Le projet utilise le modèle intégré « Classique », en lecture seule : cliquez sur **Cloner…** (étape 10.1).
- **Une note n'a pas le format attendu.** Regardez la ligne d'information en haut de l'éditeur : elle indique le format retenu et son origine (propre, étiquette, parent, global). Un format propre ou une étiquette passe avant le parent (étape 10.5).
- **Un mot manque dans une famille.** Le lexique compte des mots simples : ajoutez le singulier et le pluriel, et coupez les expressions en mots.
- **Le thème est trop clair.** Le bouton **◐** en haut à droite bascule entre thème clair et sombre.
- **Où modifier une note hors de wdnotes ?** Chaque note est un fichier texte dans `notes/` ; vous pouvez l'éditer avec n'importe quel éditeur, wdnotes fermé.

**Pour aller plus loin.** Le projet de démonstration « Jardin partagé » montre toutes ces fonctions déjà en place (formats, balises, familles, modèle « Moderne »). Le fichier `README.md` du dossier `apps/wdnotes` décrit l'organisation du code pour ceux qui veulent modifier le programme.

### Encore une chose !
Un p'tit geste qui peut - grandement - nous aider... \[La caféïne c'est important pour une équipe de neuro-atypiques : TSA, TDAH, TAG, HPI et/ou THPI (membres de **mensa.fr** et de **triplenine.org**).\]

[![Buy Me a Coffee](../../buymeacoffe-fre.png)](https://buymeacoffee.com/sonaliwan.fr)
