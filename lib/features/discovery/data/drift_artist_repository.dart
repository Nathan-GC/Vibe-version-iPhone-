import 'package:drift/drift.dart';

import '../../../core/storage/database/app_database.dart';
import '../../../core/storage/metadata_extractor/artist_name_normalizer.dart';
import '../domain/artist_filter.dart';
import '../domain/artist_sort.dart';
import '../domain/top_artist_playlist.dart';
import 'artist_repository.dart';

class DriftArtistRepository implements ArtistRepository {
  DriftArtistRepository(this._db);

  final AppDatabase _db;

  @override
  Stream<List<Track>> watchArtistTracks(
    String artistName, {
    ArtistFilter filter = ArtistFilter.all,
    ArtistSort sort = ArtistSort.chronological,
  }) {
    // Comparaison insensible à la casse (QA Section 3.A) : [artistName] peut
    // être le nom canonique choisi par [ArtistNameNormalizer.
    // dedupeCaseInsensitive] (voir [fetchAllArtistNames]), qui ne correspond
    // pas forcément exactement (`=`) à CHAQUE variante de casse réellement
    // stockée dans `track_artists` — un `.equals()` strict manquerait alors
    // les morceaux tagués sous l'autre variante.
    final query = _db.select(_db.tracks).join([
      innerJoin(_db.trackArtists, _db.trackArtists.trackId.equalsExp(_db.tracks.id)),
    ])
      ..where(_db.trackArtists.artistName.lower().equals(artistName.toLowerCase()));

    return query.watch().map((rows) {
      final List<Track> tracks = rows.map((row) => row.readTable(_db.tracks)).toList();
      return _sort(_filterTracks(tracks, filter), sort);
    });
  }

  List<Track> _filterTracks(List<Track> tracks, ArtistFilter filter) {
    switch (filter) {
      case ArtistFilter.all:
        return tracks;
      case ArtistFilter.albums:
        return tracks.where((t) => t.album.trim().isNotEmpty).toList();
      case ArtistFilter.singlesEps:
        return tracks.where((t) => t.album.trim().isEmpty).toList();
      case ArtistFilter.collaborations:
        return tracks.where((t) => t.artists.length > 1).toList();
    }
  }

  List<Track> _sort(List<Track> tracks, ArtistSort sort) {
    final List<Track> sorted = [...tracks];
    switch (sort) {
      case ArtistSort.chronological:
        sorted.sort((a, b) => b.releaseYear.compareTo(a.releaseYear));
      case ArtistSort.popularity:
        sorted.sort((a, b) => b.playCount.compareTo(a.playCount));
      case ArtistSort.alphabetical:
        sorted.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    }
    return sorted;
  }

  @override
  Future<List<String>> fetchAllArtistNames() async {
    final query = _db.selectOnly(_db.trackArtists, distinct: true)..addColumns([_db.trackArtists.artistName]);
    final List<TypedResult> rows = await query.get();
    final List<String> rawNames = rows.map((row) => row.read(_db.trackArtists.artistName)!).toList();
    // QA Section 3.A : un même artiste tagué sous plusieurs casses d'un
    // fichier à l'autre (ex. "ABBA" et "Abba") apparaissait jusqu'ici comme
    // deux entrées distinctes dans "Ajouter par artiste" — une seule entrée
    // canonique par variante désormais (voir watchArtistTracks pour la
    // comparaison insensible à la casse qui garde ce choix sûr en aval).
    final List<String> names = ArtistNameNormalizer.dedupeCaseInsensitive(rawNames);
    names.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return names;
  }

  @override
  Future<List<TopArtistPlaylist>> fetchTopArtistPlaylists({int limit = 7}) async {
    final countExp = _db.trackArtists.trackId.count();
    final query = _db.selectOnly(_db.trackArtists)
      ..addColumns([_db.trackArtists.artistName, countExp])
      ..groupBy([_db.trackArtists.artistName])
      ..orderBy([OrderingTerm.desc(countExp)])
      ..limit(limit);
    final List<TypedResult> rows = await query.get();

    final List<TopArtistPlaylist> playlists = [];
    for (final row in rows) {
      final String artistName = row.read(_db.trackArtists.artistName)!;
      final int trackCount = row.read(countExp) ?? 0;
      playlists.add(
        TopArtistPlaylist(
          artistName: artistName,
          trackCount: trackCount,
          coverArtPath: await _mostPlayedTrackCover(artistName),
        ),
      );
    }
    return playlists;
  }

  @override
  Future<List<TopArtistPlaylist>> fetchAllArtistsWithTrackCount() async {
    final countExp = _db.trackArtists.trackId.count();
    final query = _db.selectOnly(_db.trackArtists)
      ..addColumns([_db.trackArtists.artistName, countExp])
      ..groupBy([_db.trackArtists.artistName])
      ..orderBy([OrderingTerm.asc(_db.trackArtists.artistName)]);
    final List<TypedResult> rows = await query.get();

    return [
      for (final row in rows)
        TopArtistPlaylist(artistName: row.read(_db.trackArtists.artistName)!, trackCount: row.read(countExp) ?? 0),
    ];
  }

  // Pochette du morceau le plus écouté (`playCount`) de [artistName] — `null`
  // si aucun de ses morceaux n'a de pochette (jamais enrichi, jamais joué).
  Future<String?> _mostPlayedTrackCover(String artistName) async {
    final query = _db.select(_db.tracks).join([
      innerJoin(_db.trackArtists, _db.trackArtists.trackId.equalsExp(_db.tracks.id)),
    ])
      ..where(_db.trackArtists.artistName.equals(artistName))
      ..orderBy([OrderingTerm.desc(_db.tracks.playCount)])
      ..limit(1);
    final row = await query.getSingleOrNull();
    final Track? track = row?.readTable(_db.tracks);
    return (track != null && track.coverArtPath.isNotEmpty) ? track.coverArtPath : null;
  }
}
