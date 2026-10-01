import 'package:drift/drift.dart';

import '../../identity/track_match_key.dart';
import 'app_database.dart';

/// Dégrisage automatique des titres de playlists importées (voir
/// [PlaylistMissingTracks]) : dès qu'un morceau entre en bibliothèque, tout
/// titre grisé qui lui correspond redevient une vraie entrée de playlist, à
/// la même position — sans réimporter la playlist.
///
/// Correspondance retenue (volontairement stricte, aucun choix à faire à la
/// place de l'utilisateur) : même `sanitizedKey` (titre + album + artiste),
/// ou même titre normalisé ET l'un des artistes du morceau égal à l'artiste
/// du titre grisé (voir `buildTrackMatchKey`). Un titre identique chez un
/// autre artiste reste grisé : c'est au matching manuel de trancher.
class MissingPlaylistTrackReconciler {
  MissingPlaylistTrackReconciler(this._db);

  final AppDatabase _db;

  /// Retourne le nombre de titres dégrisés. À appeler dans la même
  /// transaction que l'insertion du morceau.
  Future<int> reconcileTrack({required String trackId, required String title, required List<String> artists}) async {
    final Set<String> matchKeys = {
      for (final String artist in artists) buildTrackMatchKey(title: title, artist: artist),
    };
    final List<PlaylistMissingTrack> matches = await (_db.select(_db.playlistMissingTracks)
          ..where((m) => m.sanitizedKey.equals(trackId) | m.matchKey.isIn(matchKeys))
          ..orderBy([(m) => OrderingTerm.asc(m.id)]))
        .get();

    int restored = 0;
    for (final PlaylistMissingTrack missing in matches) {
      final bool alreadyInPlaylist = await (_db.select(_db.playlistTracks)
            ..where((t) => t.playlistId.equals(missing.playlistId) & t.trackId.equals(trackId)))
          .getSingleOrNull()
          .then((row) => row != null);
      // Même morceau déjà présent (doublon dans le JSON d'origine) : la clé
      // primaire (playlist, morceau) interdit une 2e ligne — le titre grisé
      // en double est simplement retiré plutôt que de rester grisé à vie.
      if (!alreadyInPlaylist) {
        await _db.into(_db.playlistTracks).insert(
              PlaylistTracksCompanion.insert(
                playlistId: missing.playlistId,
                trackId: trackId,
                position: missing.position,
                isPendingPlacement: const Value(false),
              ),
            );
        restored++;
      }
      await (_db.delete(_db.playlistMissingTracks)..where((m) => m.id.equals(missing.id))).go();
    }
    return restored;
  }
}
