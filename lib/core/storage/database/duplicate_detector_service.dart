import 'app_database.dart';
import 'duplicate_track_group.dart';

/// Détecte les morceaux strictement en double (Titre + Artiste identiques à
/// la casse près) — alerte l'utilisateur pour qu'il renomme ou ré-enrichisse
/// manuellement l'un des deux plutôt que de laisser deux fiches concurrentes
/// dans la bibliothèque. Comparaison sur l'ensemble de `tracks.artists`
/// (featurings compris, dans l'ordre) : deux morceaux au même titre mais
/// crédités à des artistes différents (même partiellement) ne sont jamais
/// des doublons.
class DuplicateDetectorService {
  DuplicateDetectorService(this._db);

  final AppDatabase _db;

  Future<List<DuplicateTrackGroup>> findDuplicates() async {
    final List<Track> allTracks = await _db.select(_db.tracks).get();
    return groupDuplicates(allTracks);
  }

  Stream<List<DuplicateTrackGroup>> watchDuplicates() {
    return _db.select(_db.tracks).watch().map(groupDuplicates);
  }

  static List<DuplicateTrackGroup> groupDuplicates(List<Track> tracks) {
    final Map<String, List<Track>> byKey = {};
    for (final track in tracks) {
      final String artistKey = track.artists.join(', ').trim().toLowerCase();
      final String key = '${track.title.trim().toLowerCase()}|$artistKey';
      byKey.putIfAbsent(key, () => []).add(track);
    }

    return [
      for (final entry in byKey.entries)
        if (entry.value.length > 1)
          DuplicateTrackGroup(
              title: entry.value.first.title, artist: entry.value.first.artists.join(', '), tracks: entry.value),
    ];
  }
}
