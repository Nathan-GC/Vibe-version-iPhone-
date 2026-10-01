# Vibe iPhone — compiler et exécuter sur iPhone

> La compilation iOS exige **macOS + Xcode**. Le code a été préparé et validé sous
> Windows (`flutter analyze`, `flutter test`, compilation Metal des shaders) ; la
> première compilation Xcode se fait donc sur un Mac, en suivant ce document.

## 1. Prérequis (Mac)

| Outil | Version |
|---|---|
| macOS + Xcode | Version d'Xcode exigée par Flutter 3.47.3 (contrôlée par `flutter doctor`) |
| Flutter | **3.47.3** (stable) — même version que Vibe Android |
| CocoaPods | `sudo gem install cocoapods` (ou `brew install cocoapods`) |
| Compte Apple | Gratuit pour un iPhone perso (profil valable 7 jours), payant pour TestFlight/App Store |

```bash
flutter doctor -v
```

La section « Xcode » doit être verte (licence acceptée, simulateur iOS installé).

Au premier build, deux dépendances téléchargent des binaires (connexion requise) :
`ffmpeg_kit_flutter_new_min` (xcframeworks FFmpeg, variante LGPL) et le moteur Flutter iOS.

## 2. Préparer le projet

Copier le dossier `Vibe iPhone` sur le Mac, puis à sa racine :

```bash
flutter pub get
```

Les fichiers générés `*.g.dart` sont fournis. S'ils manquent (ils sont exclus de git) :

```bash
dart run build_runner build --delete-conflicting-outputs
```

Installer les pods (fait aussi automatiquement par `flutter run`) :

```bash
cd ios && pod install && cd ..
```

Avec Swift Package Manager activé (défaut récent de Flutter), les plugins compatibles
passent par SwiftPM et les autres (`disk_space_plus`, `open_filex`) par CocoaPods : les
deux cohabitent, le `Podfile` fourni est prévu pour ça. `vibe_power` fournit les deux
intégrations.

## 3. Signature (une seule fois)

```bash
open ios/Runner.xcworkspace
```

Dans Xcode : cible **Runner** › **Signing & Capabilities** :
1. Cocher *Automatically manage signing* et choisir sa **Team**.
2. Remplacer le **Bundle Identifier** `com.example.playlistApp` par un identifiant unique
   (ex. `com.tondomaine.vibe`) : un identifiant `com.example.*` ne peut pas être publié.
3. Vérifier la capacité **Background Modes** : *Audio, AirPlay, and Picture in Picture*
   et *Background fetch* doivent être cochés (ils viennent de `Info.plist`).

## 4. Exécuter sur le simulateur iOS

```bash
open -a Simulator
```

```bash
flutter devices
```

```bash
flutter run -d "iPhone 16 Pro"
```

(remplacer par le nom d'un simulateur listé par `flutter devices`). Limites du
simulateur : pas d'écran verrouillé réel, BGTaskScheduler indisponible (la purge
passe alors par le contrôle au lancement), mode Économie d'énergie non simulable.

## 5. Exécuter sur un iPhone physique

1. Brancher l'iPhone, le déverrouiller, accepter « Faire confiance à cet ordinateur ».
2. Activer le **Mode développeur** : Réglages › Confidentialité et sécurité › Mode
   développeur (redémarrage demandé).
3. Lancer :

```bash
flutter run --release
```

(`--release` : performances réelles des shaders ; en debug, l'app ne se relance pas
depuis l'écran d'accueil une fois le câble débranché). Au premier lancement :
Réglages › Général › VPN et gestion de l'appareil › faire confiance au certificat
développeur.

## 6. Distribuer (TestFlight / App Store)

```bash
flutter build ipa --release
```

L'archive est dans `build/ios/archive/`, l'IPA dans `build/ios/ipa/` ; l'envoyer avec
Xcode (Organizer › Distribute App) ou Transporter. Numéro de version : `version:` du
`pubspec.yaml` (`1.3.1+8`), incrémenter le `+N` à chaque envoi.

## 7. Recette sur iPhone (points non vérifiables sous Windows)

| # | Test | Attendu |
|---|---|---|
| 1 | Premier lancement | Pas de demande « permission audio » ; demande d'autorisation des notifications ; onboarding puis Lecteur |
| 2 | Fichiers › Sur mon iPhone › Vibe : déposer 2 MP3/M4A, revenir dans Vibe | Morceaux ajoutés à la Bibliothèque sans action (ou bouton « Actualiser depuis l'app Fichiers ») |
| 3 | Bibliothèque › « Importer des MP3 » | Sélecteur de documents iOS ; un `.m4a` importé est lisible |
| 4 | Lecture puis verrouillage | Titre, artiste, pochette, progression sur l'écran verrouillé ; lecture/pause/suivant/précédent/déplacement fonctionnels |
| 5 | Centre de contrôle, écouteurs Bluetooth | Mêmes commandes ; débrancher un casque filaire met en pause |
| 6 | Appel entrant pendant la lecture | Pause, puis reprise automatique en raccrochant |
| 7 | Mode Focus (7 s d'inactivité sur le Lecteur) | Barre d'état et indicateur d'accueil masqués ; l'écran ne se met pas en veille |
| 8 | Mode Focus avec Économie d'énergie activée | L'écran se met en veille normalement |
| 9 | Vibes Space (nébuleuse) et Neon (pluie) | Shaders animés, pas d'écran noir |
| 10 | Encoche / Dynamic Island | Aucun contenu masqué ; feuilles tirées au maximum sous la zone sûre |
| 11 | Export JSON d'une playlist | Sélecteur d'export iOS ; fichier visible dans Fichiers |
| 12 | Mise à jour de l'app (réinstaller une nouvelle version) | Bibliothèque, pochettes et fonds de Vibe toujours présents |
| 13 | Paramètres › Confidentialité désactivé, puis déposer un MP3 non tagué dans Fichiers | Morceau ajouté, aucun enrichissement (reste « À enrichir ») |
| 14 | Éditeur d'un morceau › onglet MusicBrainz | Suggestions et pochettes Cover Art Archive affichées |
| 15 | Zap rapide : 5 × Suivant (Lecteur, puis Centre de contrôle) | Avance de 5 titres, un seul chargement audio, aucune cascade |
| 16 | Saisir des identifiants Spotify, supprimer l'app, la réinstaller | Import Spotify sans identifiants (anciens effacés du trousseau) |
| 17 | Paramètres › Légal | Textes iOS (trousseau, autorisations iOS, suppression de l'app) |

Tester la tâche de purge en arrière-plan (app lancée depuis Xcode, mise en pause dans
le débogueur), puis reprendre l'exécution :

```text
e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"orphan_purge_daily_check"]
```

## 8. Dépannage

| Symptôme | Cause / solution |
|---|---|
| `pod install` : « CocoaPods could not find compatible versions » | `pod repo update` puis relancer |
| Erreur de téléchargement FFmpeg au premier build | Connexion requise ; relancer `pod install` (ou `flutter clean` puis `flutter run`) |
| `No such module 'workmanager_apple'` dans `AppDelegate.swift` | Lancer une fois `flutter build ios --config-only` pour régénérer l'intégration des plugins |
| « Untrusted Developer » sur l'iPhone | Étape 5 : faire confiance au certificat |
| Signature refusée (identifiant déjà pris) | Changer le Bundle Identifier (étape 3) |
| Plus de son en arrière-plan | Vérifier *Background Modes › Audio* (étape 3) |
