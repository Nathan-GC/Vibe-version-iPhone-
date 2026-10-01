import 'package:flutter/material.dart';

import '../../../core/storage/database/app_database.dart';
import '../../../core/theme/vibe_engine/vibe_engine.dart';
import '../domain/playlist_editor_entry.dart';

/// Id fixe de la playlist "Titres likés" (Étape 3) : une playlist ordinaire
/// comme les autres (Vibe personnalisable, export JSON...), juste toujours
/// recréée avec ce même id plutôt que d'introduire un concept de "favori"
/// séparé du modèle playlist existant.
const String kLikedPlaylistId = 'liked-tracks';

/// `Playlist` est l'entité générée par Drift à partir de la table `playlists`
/// (voir core/storage/database/app_database.dart), réutilisée directement
/// comme entité de domaine plutôt que dupliquée.
abstract class PlaylistRepository {
  Stream<List<Playlist>> watchAll();
  Stream<Playlist?> watchPlaylist(String playlistId);

  /// Retrouve une playlist locale déjà forkée depuis ce `manifest.id` — permet
  /// de distinguer une mise à jour (diff) d'un tout nouvel import, alors que
  /// `Playlist.id` local est lui suffixé `-fork-<timestamp>` et ne correspond
  /// jamais directement au `manifest.id` entrant.
  Future<Playlist?> findBySourceManifestId(String manifestId);

  /// Toutes les lignes de la playlist dans l'ordre d'affichage : morceaux de
  /// la bibliothèque ET titres importés introuvables (grisés, voir
  /// [PlaylistEditorEntry.isMissing]). Réagit aux changements des deux tables.
  Stream<List<PlaylistEditorEntry>> watchEditorEntries(String playlistId);

  /// Morceaux LISIBLES uniquement, dans l'ordre — les titres grisés sont
  /// exclus : c'est ce qui les fait sauter par le lecteur (file d'attente
  /// construite à partir de cette liste).
  Future<List<Track>> fetchOrderedTracks(String playlistId);

  /// Crée une playlist locale vide (Tab 3 — pas de fork/import), prête à être
  /// éditée. `sourceManifestId` reste null : elle n'est pas issue d'un JSON.
  Future<Playlist> createEmpty({required String title, required VibePreset vibeStyle});

  /// Crée la playlist "Titres likés" (`kLikedPlaylistId`) si elle n'existe pas
  /// encore — appelé paresseusement au premier "J'aime" plutôt qu'au démarrage.
  Future<Playlist> ensureLikedPlaylist();

  /// Persiste l'ordre après édition : purge `is_pending_placement`, écrit les
  /// `position` (morceaux ET titres grisés, dans une numérotation commune),
  /// incrémente `version` (Étape 5 — "Commit Edits").
  Future<void> commitOrder(String playlistId, List<PlaylistEditorEntry> orderedEntries);

  /// Associe manuellement un titre grisé à un morceau de la bibliothèque :
  /// il devient une entrée lisible à la même position. Sans effet sur la
  /// position si le morceau est déjà dans la playlist (le titre grisé est
  /// alors simplement retiré, une playlist ne contenant jamais deux fois le
  /// même morceau).
  Future<void> linkMissingEntry(int missingId, String trackId);

  /// Retire un titre grisé de la playlist.
  Future<void> removeMissingEntry(int missingId);

  Future<void> updateVibeStyle(String playlistId, VibePreset vibeStyle);

  /// Bascule la playlist sur `VibePreset.custom` et enregistre les couleurs
  /// de dégradé (2 minimum), la couleur d'accentuation explicite des boutons/
  /// éléments interactifs, l'effet de fond ([VibeCustomEffect]) et/ou l'image
  /// et la vidéo de fond choisies dans le Vibe Creator. `backgroundImagePath`/
  /// `backgroundVideoPath` vides retirent l'image/la vidéo (voir
  /// MasterPlayerScreen pour l'exclusivité mutuelle vidéo vs effet/image).
  Future<void> updateCustomVibe(
    String playlistId, {
    required List<Color> colors,
    required Color accentColor,
    required String backgroundImagePath,
    required VibeCustomEffect effect,
    required String backgroundVideoPath,
  });

  Future<void> incrementVersion(String playlistId);

  /// Renomme une playlist locale (menu "..." de Mon espace). Bloqué en amont
  /// dans l'UI pour les playlists système ([kAllImportedPlaylistId],
  /// [kLikedPlaylistId]) plutôt qu'ici, pour garder ce repository agnostique
  /// de la politique d'affichage.
  Future<void> renamePlaylist(String playlistId, String title);

  /// Supprime une playlist locale ainsi que ses liaisons `playlist_tracks` et
  /// ses titres grisés —
  /// les morceaux eux-mêmes ne sont jamais supprimés (ils restent rattachés
  /// à [kAllImportedPlaylistId] et à leurs autres playlists). Même remarque
  /// que [renamePlaylist] sur les playlists système : à bloquer côté UI.
  Future<void> deletePlaylist(String playlistId);

  /// Pochette personnalisée (Design System — PlaylistCard) choisie depuis
  /// l'éditeur de playlist. [path] vide retire la pochette personnalisée et
  /// revient au visuel composite auto-généré (voir PlaylistCoverImage).
  Future<void> updateCoverImagePath(String playlistId, String path);

  /// Visibilité de la pochette dans le Player — exposé dans
  /// VibeCustomizerScreen pour toutes les Vibes.
  Future<void> updateShowCoverImage(String playlistId, bool showCoverImage);
}
