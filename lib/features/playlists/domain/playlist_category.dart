import '../../../core/storage/database/app_database.dart';
import '../../../core/storage/database/track_repository.dart';
import '../data/playlist_repository.dart';

/// Famille d'une playlist, utilisée pour séparer "Mon espace" en trois sections.
enum PlaylistCategory { created, auto, imported }

/// Détermine la famille d'une playlist :
/// - [PlaylistCategory.auto] : les playlists système ([kAllImportedPlaylistId], [kLikedPlaylistId]) ;
/// - [PlaylistCategory.imported] : venue d'un import (manifeste JSON ou lien Spotify), c'est-à-dire avec un
///   `sourceManifestId` ou un `originalCreator`. Ces champs ne sont jamais effacés : une playlist importée
///   puis modifiée ou renommée reste importée ;
/// - [PlaylistCategory.created] : toutes les autres.
PlaylistCategory playlistCategoryOf(Playlist playlist) {
  if (playlist.id == kAllImportedPlaylistId || playlist.id == kLikedPlaylistId) return PlaylistCategory.auto;
  if (playlist.sourceManifestId != null || playlist.originalCreator != null) return PlaylistCategory.imported;
  return PlaylistCategory.created;
}
