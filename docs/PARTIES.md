# Vibe iPhone — découpage du code en parties

Ce document découpe l'application en **7 parties indépendantes**, pour faire évoluer
la version iPhone partie par partie. Pour chacune : son périmètre (dossiers/fichiers),
son rôle, et ce qui a été adapté pour iOS.

## Principe

- **Aucun fichier n'a été déplacé** : l'arborescence reste celle de Vibe (Android),
  fichier pour fichier. Un correctif fait d'un côté se reporte donc de l'autre par
  simple comparaison de fichiers (`diff -r "Vibe/lib" "Vibe iPhone/lib"`), sans
  table de correspondance à maintenir.
- **Synchronisation avec Android** : ce dossier est la branche `ios` du dépôt Vibe, posée
  sur `main` (Android). Reporter les nouveautés Android : `git fetch origin` puis
  `git merge origin/main` — Git fusionne à 3 voies depuis la dernière synchro.
- **Un seul point de détection de plateforme** : `lib/core/platform/app_platform.dart`
  (`AppPlatform.isIOS` / `AppPlatform.isAndroid`). Chaque adaptation suit la même
  forme : `if (AppPlatform.isIOS) { …iOS… }` puis le code Android d'origine, **inchangé**.
- Sous `flutter test`, `AppPlatform` vaut Android : les 187 tests d'origine exercent
  toujours le chemin Android. Les branches iOS sont testées en simulant la plateforme
  (`debugDefaultTargetPlatformOverride = TargetPlatform.iOS`).

| # | Partie | Périmètre principal | Adaptations iOS |
|---|---|---|---|
| 1 | Socle & Plateforme | `lib/main.dart`, `lib/app/`, `lib/core/platform/`, `lib/core/system/`, `packages/vibe_power/`, `ios/` | Oui (natif + démarrage) |
| 2 | Lecteur | `lib/core/audio_engine/`, `lib/features/player/`, `assets/shaders/` | Oui (interruptions audio) |
| 3 | Recherche / Découverte | `lib/features/discovery/`, `lib/core/networking/` | Oui (trousseau Spotify) |
| 4 | Importation & Stockage | `lib/core/storage/`, `lib/features/onboarding/`, `lib/core/purge/` | Oui (la plus touchée) |
| 5 | Bibliothèque | `lib/features/library/`, widgets « morceau » de `lib/core/shared/widgets/` | Oui (synchro Fichiers) |
| 6 | Playlists | `lib/features/playlists/`, `lib/features/diff/`, `lib/core/playlist_manifest/` | Oui (export, feuilles) |
| 7 | Réglages & Thème | `lib/features/settings/`, `lib/core/theme/global_theme/`, `lib/core/theme/design_system/` | Oui (APK -> Fichiers) |

---

## Partie 1 — Socle & Plateforme

**Rôle** : démarrage de l'app, navigation (3 onglets Découverte / Lecteur / Espace),
mode Focus (écran maintenu allumé), pont natif, projet Xcode.

| Fichier | Contenu |
|---|---|
| `lib/main.dart`, `lib/app/bootstrap.dart` | Conteneur Riverpod unique, `AudioService.init`, tâche de purge |
| `lib/app/app.dart` | Premier lancement / permissions / notifications |
| `lib/app/router.dart` | `go_router`, coque `_TabShell`, mode système immersif |
| `lib/core/platform/` *(nouveau)* | `app_platform.dart` (détection), `gallery_image_picker.dart` |
| `lib/core/system/focus_keep_screen_on.dart` | Règle « écran allumé si Focus et hors économie d'énergie » |
| `lib/core/navigation/`, `lib/core/shared/` (constantes, textes, stockage onboarding) | Utilitaires transverses |
| `packages/vibe_power/` | Plugin local : Java (Android) + **Swift (iOS, nouveau)** |
| `ios/` *(nouveau)* | Projet Xcode configuré |

**Adaptations iOS**
- `ios/` généré (`flutter create --platforms=ios`) puis configuré : `Info.plist`
  (arrière-plan `audio` + `fetch`, identifiant BGTask, partage de fichiers, descriptions
  de confidentialité), `Podfile` (iOS 15), `AppDelegate.swift` (workmanager, notifications),
  cible **iPhone uniquement**, icône Vibe identique à l'icône Android.
- `packages/vibe_power/ios/` : `VibePowerPlugin.swift` — `isIdleTimerDisabled`,
  `isLowPowerModeEnabled`, notification `NSProcessInfoPowerStateDidChange` ; intégration
  CocoaPods (`vibe_power.podspec`) **et** Swift Package Manager (`Package.swift`).
- `packages/vibe_power/lib/vibe_power.dart` : appels conditionnés par
  `Platform.isAndroid` / `Platform.isIOS` (no-op ailleurs).
- `main.dart` : réalignement des chemins de fichiers en base au démarrage
  (voir Partie 4, `SandboxPathRelocator`).
- `app.dart` : pas de `Permission.audio` sur iOS ; synchronisation du dossier Fichiers
  au lancement et au retour au premier plan.
- `router.dart` : la barre d'onglets se prolonge sous l'indicateur d'accueil (iOS).

## Partie 2 — Lecteur

**Rôle** : moteur audio, file d'attente, lecture en arrière-plan, écran Lecteur, Vibes
(fonds fluides, shaders, vidéo), mode Focus visuel.

| Fichier | Contenu |
|---|---|
| `lib/core/audio_engine/player_controller.dart` | `just_audio`, découpe des silences (`ClippingAudioSource`), reprise de session |
| `lib/core/audio_engine/playlist_audio_handler.dart` | Pont `audio_service` : écran verrouillé / Centre de contrôle |
| `lib/core/audio_engine/ios_interruption_resume_policy.dart` *(nouveau)* | Reprise après interruption (iOS) |
| `lib/core/audio_engine/` (queue, preview, état persistant, mode immersif) | Logique de lecture |
| `lib/features/player/` | `MasterPlayerScreen`, `FluidBackground`, `VibeVideoBackground`, widgets |
| `lib/core/animation/`, `lib/core/theme/vibe_engine/` | Tempo, presets de Vibe, haptique |
| `assets/shaders/*.frag` | Particules audio-réactives, nébuleuse Space |

**Adaptations iOS**
- Reprise automatique après un appel/Siri/alarme : ExoPlayer le fait seul sur Android,
  AVFoundation jamais — `IosInterruptionResumePolicy` relance la lecture si elle était en
  cours ET si iOS l'autorise (`shouldResume`).
- **Vérifié sans modification** : `ClippingAudioSource` est implémenté par `just_audio`
  iOS ; `audio_service` publie titre / artiste / album / pochette (fichier local ou URL
  téléchargée) / durée / position dans `MPNowPlayingInfoCenter` et gère
  lecture-pause-suivant-précédent-seek via `MPRemoteCommandCenter`.
- **Shaders Metal** : les deux shaders compilent avec `impellerc --runtime-stage-metal`
  (la cible exacte de `flutter build ios`) ; le MSL produit conserve l'ordre des
  uniforms (`setFloat`) et le sampler `uBackdrop`. Aucune modification GLSL nécessaire.

## Partie 3 — Recherche / Découverte

**Rôle** : recherche iTunes, autocomplétion, fiches artiste, albums, extraits 30 s,
import de liens Spotify, enrichissement MusicBrainz / Cover Art Archive (repli d'iTunes).

| Dossier | Contenu |
|---|---|
| `lib/features/discovery/` | Écrans Découverte / Artiste / Import, dépôts de recherche |
| `lib/core/networking/` | Clients iTunes (throttle, retries), Spotify, MusicBrainz, Dio |
| `lib/core/identity/` | Clés de correspondance des morceaux |

**Adaptations iOS** : réseau 100 % HTTPS (compatible ATS), code Dart pur. La feuille
« album » a reçu la borne de zone sûre (voir Partie 6). Identifiants Spotify : trousseau
iOS (`flutter_secure_storage`) ; le trousseau survivant à la désinstallation (contrairement
au Keystore Android), ceux d'une installation précédente sont effacés au premier accès.

## Partie 4 — Importation & Stockage

**Rôle** : base SQLite (Drift), scan des fichiers, lecture des tags (ffprobe), découpe des
silences (ffmpeg), copie/renommage des imports, onboarding, purge des orphelins.

| Fichier | Contenu |
|---|---|
| `lib/core/storage/database/` | `AppDatabase`, dépôts, enrichissement, **`sandbox_path_relocator.dart`** *(nouveau)* |
| `lib/core/storage/music_folder_resolver.dart` | Dossier `Music/AppFolder` |
| `lib/core/storage/file_scanner/` | Racine de scan, filtre des fichiers |
| `lib/core/storage/scanner/` | Scan complet, pipeline d'import, **`documents_library_sync.dart`** *(nouveau)* |
| `lib/core/storage/storage_manager/` | Copie des imports, pochettes, fonds |
| `lib/core/storage/metadata_extractor/`, `silence_trimmer/`, `filename_sanitizer/` | ffprobe, ffmpeg, nettoyage des noms |
| `lib/features/onboarding/` | Premier lancement |
| `lib/core/purge/` | Purge mensuelle, notifications locales, workmanager |

**Adaptations iOS**
- **Dossier de bibliothèque** : `Documents/Music/AppFolder` (pas de stockage externe
  sur iOS — `getExternalStorageDirectory` y lève `UnsupportedError`). Documents est
  visible dans l'app Fichiers (« Sur mon iPhone › Vibe »).
- **Base SQLite** : déplacée dans `Library/Application Support` (sinon visible, et
  supprimable, dans l'app Fichiers).
- **Scan** : racine = dossier Documents de l'app ; `.ogg` exclu (non décodable par
  AVFoundation) ; `Music/AppFolder` (copies déjà en base), `Inbox` et `.Trash`
  (corbeille de l'app Fichiers) exclus.
- **Synchronisation Fichiers** (`DocumentsLibrarySync`) : les morceaux déposés via l'app
  Fichiers ou le Finder sont indexés au lancement, au retour dans l'app et à la demande
  (au plus une fois toutes les 30 s en automatique). L'enrichissement des morceaux renommés
  (iTunes puis MusicBrainz) respecte Paramètres › Confidentialité (`enrichSyncedTrack`).
- **Import** : extension d'origine conservée (`.m4a`, `.flac`…) — AVFoundation choisit son
  décodeur d'après l'extension ; Android garde le renommage historique en `.mp3`.
- **Chemins absolus** : iOS change l'UUID du conteneur de l'app à chaque mise à jour ;
  `SandboxPathRelocator` réécrit au démarrage tous les chemins en base (morceaux,
  pochettes, fonds de Vibe), avant que le lecteur ne restaure la dernière session.
- **Permissions** : pas de `Permission.audio` (inexistante sur iOS) ; l'autorisation de
  notification est demandée par `flutter_local_notifications` lui-même.
- **Purge** : identifiant `orphan_purge_daily_check` déclaré comme BGAppRefreshTask
  (Info.plist + AppDelegate) ; le contrôle au lancement reste le filet de sécurité.

## Partie 5 — Bibliothèque

**Rôle** : liste des morceaux, catégories, doublons, fusion d'artistes, éditeur de
métadonnées, actions sur un morceau (appui long).

| Fichier | Contenu |
|---|---|
| `lib/features/library/` | Écrans Bibliothèque / doublons / fusion / nettoyage, éditeur, **`documents_sync_controller.dart`** *(nouveau)* |
| `lib/core/shared/widgets/track_actions_sheet.dart`, `local_track_file_actions.dart`, `library_category_picker.dart`, `local_track_picker_sheet.dart`, `enrichment_source_dialog.dart` | Actions sur les morceaux |

**Adaptations iOS**
- Section « Actualiser depuis l'app Fichiers » (bouton, progression, rappel de
  l'emplacement), affichée uniquement sur iOS.
- Choix de pochette via PHPicker **sans** demande d'accès à toute la photothèque
  (`pickGalleryImage`, partagé avec les Parties 6 et 7).
- Feuille d'actions bornée à la zone sûre (encoche / Dynamic Island).

## Partie 6 — Playlists

**Rôle** : Mon espace, éditeur de playlist, Vibe Creator, export/import JSON, matching,
différences entre versions.

| Dossier | Contenu |
|---|---|
| `lib/features/playlists/` | Espace perso, éditeur, Vibe Creator, export/import JSON |
| `lib/features/diff/` | Aperçu des différences, morceaux manquants |
| `lib/core/playlist_manifest/` | Format JSON des playlists |
| `lib/core/shared/widgets/playlist_card.dart`, `playlist_cover_image.dart`, `add_to_playlist_sheet.dart` | Widgets playlists |

**Adaptations iOS**
- Export JSON : sélecteur d'export natif iOS ; en repli, message indiquant
  « Fichiers › Sur mon iPhone › Vibe › exports » plutôt qu'un chemin de conteneur.
- Feuilles « Ajouter par artiste » et « album » bornées à la zone sûre.
- Pochettes / fonds image via `pickGalleryImage` (PHPicker).

## Partie 7 — Réglages & Thème

**Rôle** : thème clair/sombre/système, couleur d'accent, maintenance, design system.

| Dossier | Contenu |
|---|---|
| `lib/features/settings/` | Écran Paramètres |
| `lib/core/theme/global_theme/`, `lib/core/theme/design_system/` | Thème global, typographie Outfit, espacements |

**Adaptations iOS** : « Mise à jour de l'application (APK) » remplacée par
« Tes fichiers audio » (où déposer ses morceaux) — aucune installation hors
App Store / TestFlight / Xcode n'est possible sur iPhone. Page Légal : textes iOS pour
le stockage chiffré (trousseau), les autorisations et l'effacement des données.

---

## Tests ajoutés pour les adaptations iOS (29)

| Fichier | Ce qui est vérifié |
|---|---|
| `test/core/platform/app_platform_test.dart` | Détection de plateforme ; `vibe_power` sans exception hors Android/iOS |
| `test/core/storage/database/sandbox_path_relocator_test.dart` | Chemins appareil/simulateur, idempotence, conflit d'unicité |
| `test/core/storage/file_scanner/file_scanner_ios_test.dart` | Filtrage iOS ; comportement Android inchangé |
| `test/core/storage/storage_manager/target_audio_extension_test.dart` | `.mp3` sur Android, extension d'origine sur iOS |
| `test/core/audio_engine/ios_interruption_resume_policy_test.dart` | Règle de reprise après interruption |
| `test/core/storage/scanner/documents_library_sync_test.dart` | Indexation puis enrichissement des seuls morceaux renommés |
| `test/features/library/data/documents_sync_controller_test.dart` | Inactif sur Android, progression, anti-doublon, espacement ; refus de l'enrichissement auto respecté |
| `test/core/networking/spotify_credentials_test.dart` | iOS : identifiants d'une installation précédente effacés, ceux de l'installation courante conservés |
| `test/features/settings/legal_screen_test.dart` | iOS : confidentialité et suppression décrivent iOS, jamais Android |
