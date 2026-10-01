import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/database/app_database.dart';
import '../../../core/storage/database/database_provider.dart';
import '../domain/playlist_editor_entry.dart';
import 'drift_playlist_repository.dart';
import 'playlist_manifest_service.dart';
import 'playlist_repository.dart';
import 'playlist_track_repository.dart';

final Provider<PlaylistRepository> playlistRepositoryProvider = Provider<PlaylistRepository>((ref) {
  return DriftPlaylistRepository(ref.watch(appDatabaseProvider));
});

final Provider<PlaylistTrackRepository> playlistTrackRepositoryProvider = Provider<PlaylistTrackRepository>((ref) {
  return PlaylistTrackRepository(ref.watch(appDatabaseProvider));
});

final Provider<PlaylistManifestService> playlistManifestServiceProvider = Provider<PlaylistManifestService>((ref) {
  return PlaylistManifestService(ref.watch(appDatabaseProvider));
});

final StreamProvider<List<Playlist>> playlistsProvider = StreamProvider<List<Playlist>>((ref) {
  return ref.watch(playlistRepositoryProvider).watchAll();
});

final playlistByIdProvider = StreamProvider.family<Playlist?, String>((ref, playlistId) {
  return ref.watch(playlistRepositoryProvider).watchPlaylist(playlistId);
});

final playlistEditorEntriesProvider = StreamProvider.family<List<PlaylistEditorEntry>, String>((ref, playlistId) {
  return ref.watch(playlistRepositoryProvider).watchEditorEntries(playlistId);
});

/// État du bouton "J'aime" (Étape 3) — réactif, pas besoin que la playlist
/// "Titres likés" existe déjà pour regarder si `trackId` en fait partie.
final isTrackLikedProvider = StreamProvider.autoDispose.family<bool, String>((ref, trackId) {
  return ref.watch(playlistTrackRepositoryProvider).watchContainsTrack(kLikedPlaylistId, trackId);
});
