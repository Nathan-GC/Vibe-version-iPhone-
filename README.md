# Vibe Player

Lecteur de musique Android **local-first** développé en Flutter : bibliothèque
100 % locale (Drift/SQLite), modes visuels immersifs (« Vibes » : shaders GLSL,
nébuleuse, fonds vidéo) et interface pensée pour les dalles OLED.

Référence fonctionnelle et architecture détaillée :
[`documentation_master_vibe_player.md`](documentation_master_vibe_player.md).

---

## Version iPhone (ce dossier : `Vibe iPhone`)

Déclinaison iOS du même code Flutter (v1.3.1+8, synchronisée avec Vibe Android 1.3.1+8), le dossier `Vibe` (Android) restant
intact. Toutes les divergences passent par `AppPlatform.isIOS`
(`lib/core/platform/app_platform.dart`) : sur Android, ce code se comporte
exactement comme Vibe.

- Découpage du code en 7 parties et adaptations iOS de chacune :
  [`docs/PARTIES.md`](docs/PARTIES.md).
- Compiler / exécuter sur simulateur ou iPhone, recette iOS :
  [`docs/IOS_BUILD.md`](docs/IOS_BUILD.md).
- `flutter analyze` : **0 issue** ; `flutter test` : **216 / 216 verts**
  (187 d'origine + 29 tests des adaptations iOS).
- Le dossier `ios/` est versionné (voir `.gitignore`), contrairement à Vibe Android.

---

## Passation — v1.1.0

| Élément | Valeur |
| :--- | :--- |
| Version (`pubspec.yaml`) | `1.1.0+3` (release précédente : tag `v1.0.0`) |
| Schéma de base Drift | **12** (migration 11 → 12 : table `playlist_missing_tracks`) |
| `flutter analyze` | **0 issue** (0 erreur / 0 warning / 0 lint) |
| Tests (`flutter test --concurrency=1`) | **128 / 128 verts** |
| Formatage | `dart format .` — largeur 120 colonnes (`analysis_options.yaml`) |
| Binaire de référence | `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk` |

### Branding Android

- Libellé : `android:label="Vibe"` (Manifest) ; titre de tâche `MaterialApp.title = 'Vibe'`.
- Icône adaptative `mipmap-anydpi-v26/ic_launcher.xml` + `ic_launcher_round.xml` :
  fond vectoriel noir pur `#000000` plein cadre 108×108 dp, 5 barres néon `#6A0DAD`
  dans la zone de sécurité de 66 dp, calque `<monochrome>` pour les icônes à thème.
- ⚠️ Le dossier `android/` est **gitignoré** : Manifest, icônes et code natif n'apparaissent
  jamais dans `git status`. Les sauvegarder à part avant toute réinstallation du poste.
  Le code natif versionné vit donc dans des **plugins locaux** (`packages/`), voir ci-dessous.

### Identifiants à ne jamais renommer

- Nom de base SQLite `playlist_app` (`AppDatabase._openConnection`) : le changer perdrait
  la bibliothèque existante des utilisateurs.
- Package Android `com.example.playlist_app` et canal de notification
  `com.example.playlist_app.channel.audio` : les changer casserait la mise à jour en place.
- Valeurs de `VibePreset` stockées en base (`oled` = « Space », `newOled` = « OLED ») :
  rétrocompatibilité des playlists existantes.

### Plugin local `packages/vibe_power`

Pont natif Java (versionné, contrairement à `android/`) du mode Focus :
`FLAG_KEEP_SCREEN_ON` et état/bascules du mode économie d'énergie
(`ACTION_POWER_SAVE_MODE_CHANGED`). Préféré à `wakelock_plus`/`battery_plus`, qui
exigeaient le téléchargement de l'AGP 8.12.1 : sur ce poste, Gradle échoue sur toute
nouvelle dépendance Maven (`PKIX path validation failed` — le certificat intercepté par
le réseau local n'est pas reconnu par le JDK d'Android Studio). Tant que ce point n'est
pas réglé côté poste, éviter les plugins qui ajoutent des artefacts Maven non déjà en cache.

---

## Commandes

```bash
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter analyze
flutter test --concurrency=1
flutter build apk --release --split-per-abi
```

Les fichiers générés (`*.g.dart`) sont **gitignorés** : un clone neuf doit lancer
`build_runner` avant toute compilation, et après chaque modification d'une classe
annotée (Riverpod) ou d'une table Drift.

`flutter test` **sans** `--concurrency=1` n'exécute silencieusement qu'un seul fichier
de test sur ce poste : toujours passer le flag pour obtenir la suite complète.

---

## Conventions du projet

- **Qualité** : `flutter analyze` à 0 issue et suite de tests entièrement verte avant tout commit.
- **Gestes** : appui simple = action principale immédiate (lecture d'une playlist/artiste) ;
  appui long = vue détaillée (éditeur, fiche artiste, actions de morceau). Exception : listes
  réordonnables (file d'attente, éditeur), où l'appui long sert au glisser-déposer.
- **Mode Focus** : jamais déclenché sans interaction utilisateur sur le Lecteur ; annulé dès
  que le Lecteur n'est plus au premier plan (onglet, sous-page, arrière-plan) —
  voir `ShellRouteVisibility` et `_PlayerPageState`. Conservé lors d'un changement de
  piste (seuls Titre/Artiste se mettent à jour). Écran maintenu allumé pendant le Focus,
  sauf en économie d'énergie (`FocusKeepScreenOnController`).
- **Playlists importées (JSON)** : un titre sans morceau local est une ligne de
  `playlist_missing_tracks` (grisée, à sa position, jamais lue — `fetchOrderedTracks`
  ne renvoie que les morceaux lisibles), dégrisée automatiquement par
  `TrackRepository.upsertTrack` dès qu'un morceau correspondant entre en bibliothèque.
  Les positions sont communes aux deux tables d'une même playlist.
- **OLED** : les bords d'écran des Vibes sombres restent strictement `#000000`
  (nébuleuse Space bornée par une ellipse à 85 % de la distance aux bords).
- **Barre d'état** : icônes claires sur Vibe sombre, sombres sur Vibe claire
  (`AnnotatedRegion` du `MasterPlayerScreen`).
- **Logs** : aucun `print`/`log` dans `lib/` ; tout futur log de diagnostic doit être
  encapsulé dans `if (kDebugMode)`.

---

## Journal v1.1.0

- **Focus** : plus de sortie du Focus à chaque changement de piste ; écran maintenu
  allumé pendant le Focus hors économie d'énergie (plugin local `vibe_power`).
- **Export JSON** : réservé aux playlists de l'utilisateur (pas « Titres likés » ni
  « Tous les titres importés ») ; fenêtre « Nom de l'auteur de la playlist » (dernier nom
  mémorisé) ; clé `author` dans le JSON ; enregistrement via le sélecteur système.
- **Import JSON** (Découverte → Import, ou Mon espace → « + ») : matching automatique par
  nom de titre (accents, casse, « (Remastered) », « feat. X » ignorés ; associé d'office
  seulement sans ambiguïté), puis fenêtre de matching manuel (suggestions, recherche dans
  la bibliothèque, import d'un fichier, ou « Laisser grisé »). La playlist apparaît dans
  « Tes playlists » (Découverte et Mon espace).
- **Titres grisés** : affichés atténués à leur place dans l'éditeur (associer / retirer),
  sautés à la lecture, dégrisés automatiquement à l'import du fichier correspondant ou à
  la correction manuelle de ses métadonnées.

## Journal v1.0.0 (nettoyage de release)

- Barre d'état du Lecteur lisible sur les Vibes sombres/OLED (icônes blanches).
- Branding « Vibe » dans À propos et le titre de tâche Android.
- Nébuleuse Space : repli indigo sans pochette rehaussé (gain ×1,4, teintes de la charte
  conservées), bords toujours `#000000`.
- Calque `<monochrome>` réintégré à l'icône adaptative.
- Dépendances inutilisées retirées : `json_annotation`, `json_serializable`, `collection`,
  `cupertino_icons`, et la déclaration directe redondante de `sqlite3_flutter_libs`
  (toujours fournie par `drift_flutter`).
- `dart format .` appliqué à tout le projet (120 colonnes).

### Points ouverts

- Poste de build : Gradle ne peut télécharger aucun nouvel artefact Maven (TLS intercepté,
  voir « Plugin local » ci-dessus).
- Paquet transitif `js` signalé *discontinued* par `pub` (dépendance web indirecte, sans
  impact Android) ; 28 paquets ont des versions majeures plus récentes non adoptées.
- `riverpod_lint` est déclaré mais pas branché dans `analysis_options.yaml` (inactif).
- `google_fonts` (police Outfit) télécharge la police au premier lancement : à embarquer
  dans `assets/fonts/` pour une autonomie zéro-réseau stricte.
- « Tes playlists » suit l'ordre de création : une playlist importée arrive en fin de
  carrousel (le message de confirmation propose « Ouvrir »).
- Mise à jour d'une playlist importée (même manifeste, version supérieure) : le matching
  est refait sur le nouveau manifeste — une association manuelle vers un morceau au nom
  sans rapport (ni titre ni artiste communs) est à refaire, faute d'origine mémorisée.
