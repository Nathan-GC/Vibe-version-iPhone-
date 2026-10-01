import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/networking/metadata_api_client/online_track_result.dart';
import '../../../core/storage/database/app_database.dart';
import '../../../core/storage/database/database_provider.dart';
import '../domain/album_group.dart';
import '../domain/artist_filter.dart';
import '../domain/artist_metadata.dart';
import '../domain/artist_sort.dart';
import '../domain/top_artist_playlist.dart';
import 'artist_metadata_api.dart';
import 'artist_repository.dart';
import 'drift_artist_repository.dart';

final Provider<ArtistRepository> artistRepositoryProvider = Provider<ArtistRepository>((ref) {
  return DriftArtistRepository(ref.watch(appDatabaseProvider));
});

final Provider<ArtistMetadataApi> artistMetadataApiProvider = Provider<ArtistMetadataApi>((ref) => ArtistMetadataApi());

final artistMetadataProvider = FutureProvider.family<ArtistMetadata?, String>((ref, artistName) {
  return ref.watch(artistMetadataApiProvider).fetchArtistMetadata(artistName);
});

typedef ArtistTracksQuery = ({String artistName, ArtistFilter filter, ArtistSort sort});

final artistTracksProvider = StreamProvider.family<List<Track>, ArtistTracksQuery>((ref, query) {
  return ref
      .watch(artistRepositoryProvider)
      .watchArtistTracks(query.artistName, filter: query.filter, sort: query.sort);
});

/// "Morceaux populaires" (Profil Artiste) — `autoDispose` : inutile de garder
/// ces résultats en mémoire une fois l'écran quitté.
final artistTopTracksProvider = FutureProvider.autoDispose.family<List<OnlineTrackResult>, String>((ref, artistName) {
  return ref.watch(artistMetadataApiProvider).fetchTopTracks(artistName);
});

/// "Discographie & Albums" (Profil Artiste).
final artistDiscographyProvider = FutureProvider.autoDispose.family<List<AlbumGroup>, String>((ref, artistName) {
  return ref.watch(artistMetadataApiProvider).fetchAlbums(artistName);
});

/// Morceaux d'un album de la discographie en ligne, chargés à la demande
/// (tap sur une vignette d'album) — voir AlbumGroup.collectionId.
final albumTracksProvider = FutureProvider.autoDispose.family<List<OnlineTrackResult>, int>((ref, collectionId) {
  return ref.watch(artistMetadataApiProvider).fetchAlbumTracks(collectionId);
});

/// Noms de tous les artistes locaux — sélecteur "Ajouter par artiste" de
/// l'éditeur de playlist (Feuille de route pt.9). `autoDispose` : inutile de
/// garder cette liste en mémoire une fois la feuille de sélection fermée.
final allLocalArtistNamesProvider = FutureProvider.autoDispose<List<String>>((ref) {
  return ref.watch(artistRepositoryProvider).fetchAllArtistNames();
});

/// Carrousel "Suggestions d'artistes" de Découverte (Section 5.2) — remplace
/// l'ancien moteur basé sur les mots-clés (supprimé, voir Section 5.1).
final topArtistPlaylistsProvider = FutureProvider.autoDispose<List<TopArtistPlaylist>>((ref) {
  return ref.watch(artistRepositoryProvider).fetchTopArtistPlaylists();
});

/// Écran de Fusion Manuelle (Section 4, Réglages) — `autoDispose` : inutile
/// de garder cette liste en mémoire une fois l'écran fermé.
final allArtistsWithTrackCountProvider = FutureProvider.autoDispose<List<TopArtistPlaylist>>((ref) {
  return ref.watch(artistRepositoryProvider).fetchAllArtistsWithTrackCount();
});
