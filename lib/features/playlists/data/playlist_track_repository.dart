import 'package:drift/drift.dart';

import '../../../core/storage/database/app_database.dart';

/// Ajout direct d'un morceau local à une playlist — utilisé par le mode "Dans
/// ma bibliothèque" du moteur de suggestions (Étape 4) : le fichier est déjà
/// présent sur l'appareil, donc l'insertion est instantanée (0 latence réseau).
/// Le morceau ajouté reste `is_pending_placement = true` jusqu'à son
/// positionnement manuel dans l'éditeur drag-and-drop (Étape 5).
class PlaylistTrackRepository {
  PlaylistTrackRepository(this._db);

  final AppDatabase _db;

  Future<void> addTrack(String playlistId, String trackId) async {
    final int nextPosition = await _nextPosition(playlistId);
    await _db.into(_db.playlistTracks).insertOnConflictUpdate(
          PlaylistTracksCompanion.insert(playlistId: playlistId, trackId: trackId, position: nextPosition),
        );
  }

  /// Ajout en masse (ex. "Ajouter par artiste" de l'éditeur de playlist,
  /// Feuille de route pt.9) : une seule transaction plutôt que N appels
  /// séquentiels à [addTrack], qui recalculeraient chacun `_nextPosition` par
  /// une requête à part — coûteux et sujet à une position dupliquée si deux
  /// ajouts se chevauchaient. [trackIds] déjà présents dans la playlist sont
  /// ignorés (jamais dupliqués ni déplacés) plutôt qu'écrasés.
  Future<int> addTracks(String playlistId, List<String> trackIds) async {
    if (trackIds.isEmpty) return 0;

    return _db.transaction(() async {
      final List<PlaylistTrack> existing =
          await (_db.select(_db.playlistTracks)..where((t) => t.playlistId.equals(playlistId))).get();
      final Set<String> alreadyPresent = existing.map((t) => t.trackId).toSet();
      final List<String> toAdd = trackIds.where((id) => !alreadyPresent.contains(id)).toList();
      if (toAdd.isEmpty) return 0;

      int nextPosition = await _nextPosition(playlistId);
      await _db.batch((batch) {
        batch.insertAll(_db.playlistTracks, [
          for (final trackId in toAdd)
            PlaylistTracksCompanion.insert(playlistId: playlistId, trackId: trackId, position: nextPosition++),
        ]);
      });
      return toAdd.length;
    });
  }

  /// Retrait instantané (bouton "J'aime", Étape 3).
  Future<void> removeTrack(String playlistId, String trackId) {
    return (_db.delete(_db.playlistTracks)..where((t) => t.playlistId.equals(playlistId) & t.trackId.equals(trackId)))
        .go();
  }

  /// Alimente l'état (rempli/vide) du bouton "J'aime" — réactif aux ajouts
  /// faits depuis n'importe quel écran, pas seulement le Player.
  Stream<bool> watchContainsTrack(String playlistId, String trackId) {
    final query = _db.select(_db.playlistTracks)
      ..where((t) => t.playlistId.equals(playlistId) & t.trackId.equals(trackId));
    return query.watch().map((rows) => rows.isNotEmpty);
  }

  /// Position suivant la plus grande position occupée, morceaux ET titres
  /// grisés confondus (numérotation commune, voir [PlaylistMissingTracks]) —
  /// plutôt que le simple nombre de morceaux, qui retomberait sur la position
  /// d'un titre grisé.
  Future<int> _nextPosition(String playlistId) async {
    final maxTrackExp = _db.playlistTracks.position.max();
    final int? maxTrack = await (_db.selectOnly(_db.playlistTracks)
          ..addColumns([maxTrackExp])
          ..where(_db.playlistTracks.playlistId.equals(playlistId)))
        .getSingle()
        .then((row) => row.read(maxTrackExp));
    final maxMissingExp = _db.playlistMissingTracks.position.max();
    final int? maxMissing = await (_db.selectOnly(_db.playlistMissingTracks)
          ..addColumns([maxMissingExp])
          ..where(_db.playlistMissingTracks.playlistId.equals(playlistId)))
        .getSingle()
        .then((row) => row.read(maxMissingExp));
    final int highest = [maxTrack ?? -1, maxMissing ?? -1].reduce((a, b) => a > b ? a : b);
    return highest + 1;
  }
}
