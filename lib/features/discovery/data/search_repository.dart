import 'package:drift/drift.dart';

import '../../../core/networking/metadata_api_client/metadata_api_client.dart';
import '../../../core/storage/database/app_database.dart';
import '../domain/search_result.dart';

/// Recherche unifiée : interroge d'abord la base locale (tracks, playlists,
/// artistes) ; si aucun résultat local, interroge l'API publique iTunes.
class SearchRepository {
  SearchRepository(this._db, this._metadataApiClient);

  final AppDatabase _db;
  final MetadataApiClient _metadataApiClient;

  Future<List<SearchResult>> search(String query) async {
    final String trimmed = query.trim();
    if (trimmed.isEmpty) return const [];

    final List<SearchResult> localResults = await _searchLocal(trimmed);
    if (localResults.isNotEmpty) return localResults;

    final onlineResults = await _metadataApiClient.search(trimmed);
    return onlineResults.map(OnlineTrackSearchResult.new).toList();
  }

  Future<List<SearchResult>> _searchLocal(String query) async {
    final String pattern = '%$query%';

    final List<Track> tracks = await _searchTracks(pattern);
    final List<Playlist> playlists = await (_db.select(_db.playlists)..where((p) => p.title.like(pattern))).get();
    final List<String> artistNames = await _searchArtistNames(pattern);

    return [
      ...tracks.map(TrackSearchResult.new),
      ...playlists.map(PlaylistSearchResult.new),
      ...artistNames.map(ArtistSearchResult.new),
    ];
  }

  Future<List<Track>> _searchTracks(String pattern) async {
    final List<Track> byTitle = await (_db.select(_db.tracks)..where((t) => t.title.like(pattern))).get();

    final artistJoin = _db.select(_db.tracks).join([
      innerJoin(_db.trackArtists, _db.trackArtists.trackId.equalsExp(_db.tracks.id)),
    ])
      ..where(_db.trackArtists.artistName.like(pattern));
    final List<Track> byArtist = (await artistJoin.get()).map((row) => row.readTable(_db.tracks)).toList();

    final Map<String, Track> merged = {
      for (final t in [...byTitle, ...byArtist]) t.id: t
    };
    return merged.values.toList();
  }

  Future<List<String>> _searchArtistNames(String pattern) async {
    final query = _db.selectOnly(_db.trackArtists, distinct: true)
      ..addColumns([_db.trackArtists.artistName])
      ..where(_db.trackArtists.artistName.like(pattern));
    final rows = await query.get();
    return rows.map((row) => row.read(_db.trackArtists.artistName)!).toList();
  }
}
