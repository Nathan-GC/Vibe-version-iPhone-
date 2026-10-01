# Documentation Master & Guide Utilisateur — Vibe Player

---

## Part 1 — Cahier des Charges Synthétisé & Architecture

### CONTEXTE ET ARCHITECTURE DU PROJET

Ce document sert de référence contextuelle et technique pour l'application mobile Android **Vibe Player**, une solution de lecture musicale *local-first*, haute performance, développée avec Flutter.

#### Stack Technique & Dépendances
* **Framework :** Flutter (Canal Stable), ciblant Android (optimisé 60/120 Hz).
* **Navigation :** GoRouter avec `StatefulShellRoute.indexedStack` (maintien permanent des 3 onglets principaux en mémoire via `IndexedStack`).
* **State Management :** Riverpod 2.x (`Notifier` / `AsyncNotifier` / Code generation).
* **Base de données Locale :** Drift (SQLite) v7 avec migrations gérées (`coverImagePath`, `enrichmentAttempts`, `enrichmentStatus`).
* **Moteur Audio :** `just_audio` couplé à `audio_service` (ExoPlayer natif pour Android avec gestion automatique du focus audio et reprise après appel).
* **Réseau / Enrichissement :** Dio / http (API iTunes) + `youtube_explode_dart` (Enrichissement YouTube sans clé d'API).
* **Moteur Graphique (Vibe Engine) :** Shaders GLSL natifs (`vibe_particles.frag`) combinés à des architectures en `Stack` Flutter 3 couches, sélecteurs d'effets dynamiques et lecteur vidéo local en arrière-plan avec conservation d'éléments via `GlobalKey`.
* **UI / Design System :** Directives adaptées de Spotify (`vibe_design_system.dart`, `app_spacing.dart`, typographie Google Fonts *Outfit*, coins arrondis 12-16px, pill buttons 30px, `SafeArea` système).

---

### ARCHITECTURE DU VIBE ENGINE (PRESETS SHADERS & STACK)

1. **Preset Neon / Cyberpunk (Inspiration Blade Runner) :**
   * **Structure Stack :**
     * *Couche 1 (Fond) :* Image HD ou vidéo locale (.mp4) verticalement alignée.
     * *Couche 2 (Overlay GLSL) :* Shader `vibe_particles.frag` en semi-transparence.
     * *Couche 3 (UI) :* Contrôles du lecteur intégrés dans un `PageView` doté d'une `GlobalKey` pour préserver le sous-arbre visuel lors des bascules d'arrière-plan et d'onglets.
   * **Physique de la pluie :** Gouttes elliptiques à réfraction convexe (échantillonnage décalé de la texture `uBackdrop`), reflet spéculaire supérieur et ombre portée basse.
   * **Grésillement des Néons :** Isolation des enseignes lumineuses et scintillation bidirectionnelle calée sur le pulse BPM (`u_tempo`).
   * **Respiration globale :** Modulation sinusoïdale lente (`sin(u_time * 0.5)`) de l'ombrage global (7% max, période de ~12,5s).

2. **Effets et Personnalisation Vibe Personnalisée :**
   * **Saisie Hexadécimale (`#HEX`) :** Champ de saisie directe pour appliquer n'importe quelle teinte personnalisée.
   * **Nouveaux Effets Dynamiques :** Mode *Fluide*, *Dégradé animé*, et *Radiation* (diffusion dynamique des couleurs extraites de la pochette).
   * **Vidéo d'Arrière-Plan :** Option "Ajouter une vidéo" permettant de charger une vidéo courte locale en boucle.

---

### RÈGLES MÉTIER, LOGIQUE DE BASE DE DONNÉES & STABILITÉ

1. **Enrichissement Hybride & Anti-Bouclage (*Circuit Breaker*) :**
   * **Scan Onboarding (1 Passe Stricte) :** Exécution d'une seule tentative de renommage et d'enrichissement par titre lors du premier scan, sans boucle infinie.
   * Modale de sélection de source uniquement lors du clic sur le bouton global `✨` (iTunes par défaut vs YouTube).
   * Nettoyage automatique des bruits de titres YouTube (`(Official Video)`, `[Clip Officiel]`, `(Lyrics)`).
   * **Verrou d'Enrichissement :** Limite stricte à 2 tentatives échouées (`enrichmentAttempts`) avant passage en `failed_permanently`.

2. **Parsing & Séparation Multi-Artistes :**
   * Déduplication explicite des artistes à l'écriture en base (résout les contraintes `UNIQUE` sur les titres type *"Hunter X Hunter"*).
   * Découpage intelligent sur les séparateurs (`,`, `&`, `x`, `vs`, `feat.`, `ft.`) pour isoler l'Artiste Principal des Collaborateurs.

3. **Gestion des Erreurs de Lecture & Robustesse :**
   * **Fichiers manquants/supprimés :** Fallback automatique sautant la piste absente pour enchaîner sur le morceau suivant dans la file d'attente.
   * **Focus Audio :** Reprise automatique officielle de la musique après la fin d'une interruption prioritaire (ex: appel téléphonique entrant).

---

## Part 2 — Guide Fonctionnel Exhaustif de l'Application

### BARRE DE NAVIGATION & ERGONOMIE ANDROID

```
+-------------------------------------------------------+
|                       CONTENU                          |
|                     DE L'ONGLET                         |
|                                                         |
+-------------------------------------------------------+
| [Play] Title - Artist (Mini-Player)                    |
+-------------------------------------------------------+
| [1] Accueil | [2] Découverte | [3] Réglages            |
+-------------------------------------------------------+
| [ SafeArea (Bottom Insets) ]                           |
+-------------------------------------------------------+
```

* **Protection des Insets (`SafeArea`) :** La barre de navigation et le Mini-Player sont surélevés dynamiquement par rapport à la barre système d'Android (navigation à 3 boutons ou gestuelle).
* **Gestion Hiérarchique du Bouton Retour (`PopScope`) :**
  1. Ferme la modale, l'éditeur de métadonnées ou le filtre actif.
  2. Réduit le lecteur plein écran / Mode Immersif (`immersiveSticky`).
  3. Redirige depuis *Découverte* ou *Réglages* vers l'onglet *Lecteur*.
  4. Quitte l'application via `SystemNavigator.pop()` uniquement depuis la racine du *Lecteur*.

---

### ONGLET 1 : ACCUEIL / MA BIBLIOTHÈQUE ("Mon Espace")

* **Gestion des Playlists Personnelles :** Création, édition du nom, réordonnancement et attribution de couverture personnalisée.
* **Lecture Directe :** Un appui simple sur la pochette d'une playlist lance immédiatement sa lecture.
* **Filtres d'État ("À vérifier" / "À enrichir") :** Tri instantané des morceaux nécessitant une révision manuelle ou un enrichissement.

---

### ONGLET 2 : DÉCOUVERTE

* **Carrousel "Suggestions d'Artistes" (Top 7) :**
  * Calculé en direct à partir des 7 artistes les plus présents dans les fichiers téléchargés.
  * Les cartes utilisent la pochette du morceau le plus écouté de l'artiste sans polluer "Mon Espace".
* **Page de Playlist Découverte :**
  * Liste les titres locaux de l'artiste accompagnés de suggestions d'extraits en ligne de 30 secondes.
  * **Règle Audio Stricte :** Les extraits de 30s ne sont joués que sur clic direct et sont automatiquement ignorés lors de la lecture continue d'une playlist.

---

### ONGLET 3 : RÉGLAGES & PERSONNALISATION

* **Sélecteur Vibe & Palette Couleurs :** Gestion du nuancier, saisie du code Hexadécimal et sélection des effets (*Fluide*, *Dégradé*, *Radiation*).
* **Importation de Vidéo Vibe :** Sélection du fichier vidéo vertical pour l'arrière-plan du lecteur.
* **Maintenance :** Nettoyeur d'orphelins et fusion manuelle d'artistes.

---

### LECTEUR FULLSCREEN (MASTER PLAYER) & MODE FOCUS

* **Fallback de Pochette :** Si un morceau ne possède pas de visuel propre, la pochette de la playlist en cours est affichée automatiquement.
* **Bouclage Automatique (Loop) :** La lecture repart au titre n°1 (index 0) dès que le dernier morceau de la playlist se termine.
* **Persistance du Fond Vibe :** Le fond animé/shader/vidéo reste visible en arrière-plan lors du balayage latéral vers la file d'attente (Queue) grâce à la conservation d'élément par `GlobalKey`.
* **Mode Focus (Immersif) :** Fondu progressif des éléments d'interface après 7 secondes d'inactivité avec masquage système `immersiveSticky`.

---

## Part 3 — Guide Utilisateur Pas à Pas

### Étape 1 : Importer et Gérer la Bibliothèque
1. Lancer l'application : le premier scan s'exécute en une passe rapide et silencieuse via l'API iTunes.
2. Pour traiter les titres à réviser, aller dans la **Bibliothèque** et sélectionner le filtre **"À vérifier"** ou **"À enrichir"**.
3. Cliquer sur un titre pour ouvrir l'éditeur : modifier manuellement ou utiliser l'onglet de recherche réseau (iTunes par défaut / YouTube).

---

### Étape 2 : Lancer un Enrichissement Automatique Global
1. Sur l'écran Bibliothèque, cliquer sur le bouton **Enrichir tout (icône ✨)** en haut à droite.
2. Dans la boîte de dialogue, choisir la source d'enrichissement (**API iTunes** par défaut ou **API YouTube**).
3. À la fin de la passe, valider la proposition de fusion automatique des doublons d'artistes si elle est présentée.

---

### Étape 3 : Configurer une Vibe Personnalisée
1. Ouvrir le **Master Player** ou aller dans les **Réglages**.
2. Choisir un effet visuel (*Fluide*, *Dégradé animé*, ou *Radiation*).
3. Entrer un code couleur spécifique (ex: `#FF0055`) ou cliquer sur **"Ajouter une vidéo"** pour charger un fichier vidéo vertical `.mp4`.

---

### Étape 4 : Utiliser la Navigation & le Mode Immersif
1. Balayer l'écran du lecteur vers la gauche pour consulter la file d'attente (Queue) sans interrompre le fond visuel Vibe.
2. Utiliser le bouton **Retour** physique du téléphone à tout moment : il fermera les modales, quittera le mode plein écran ou vous ramènera vers le lecteur avant de quitter l'application.

---

## Consignes pour la prochaine intervention

Si une nouvelle fonctionnalité ou un refactoring doit être ajouté :
* Conserver la règle d'or : `flutter analyze` doit rester strictement à 0 avertissement / 0 erreur.
* Ne pas modifier la logique du `PopScope` ou du `SafeArea(bottom: true)` sans tester l'ergonomie sur émulateur.
* Conserver l'utilisation de `IndexedStack` et des `GlobalKey` stables pour toutes les vues en arrière-plan du Master Player afin de préserver l'état visuel.
