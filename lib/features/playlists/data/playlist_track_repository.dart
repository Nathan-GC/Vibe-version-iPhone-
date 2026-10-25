import 'package:drift/drift.dart';

import '../../../core/storage/database/app_database.dart';

/// Issue de [PlaylistTrackRepository.addTrack].
enum AddTrackResult {
  /// Morceau inséré en dernière position de la playlist.
  added,

  /// Morceau déjà dans la playlist : rien n'est écrit, sa position est conservée.
  alreadyPresent,

  /// Id absent de la bibliothèque (supprimé ou en liste noire) : rien n'est écrit.
  notInLibrary,
}

/// Ajout direct d'un morceau local à une playlist — utilisé par le mode "Dans
/// ma bibliothèque" du moteur de suggestions (Étape 4) : le fichier est déjà
/// présent sur l'appareil, donc l'insertion est instantanée (0 latence réseau).
/// Le morceau ajouté reste `is_pending_placement = true` jusqu'à son
/// positionnement manuel dans l'éditeur drag-and-drop (Étape 5).
class PlaylistTrackRepository {
  PlaylistTrackRepository(this._db);

  final AppDatabase _db;

  /// Lecture de la position suivante + insertion dans UNE transaction (Lot
  /// 1.1) : Drift sérialise les transactions, deux ajouts simultanés ("J'aime"
  /// et "Ajouter à une playlist") ne peuvent plus obtenir la même position.
  ///
  /// Un morceau déjà présent n'est jamais réécrit (l'ancien upsert le
  /// renvoyait en fin de playlist) : [AddTrackResult.alreadyPresent], position
  /// inchangée. Un ajout est marqué `added_since_save` jusqu'à la prochaine
  /// sauvegarde de l'éditeur.
  Future<AddTrackResult> addTrack(String playlistId, String trackId) {
    return _db.transaction(() async {
      if ((await _inLibrary([trackId])).isEmpty) return AddTrackResult.notInLibrary;
      final bool present = await (_db.selectOnly(_db.playlistTracks)
            ..addColumns([_db.playlistTracks.trackId])
            ..where(_db.playlistTracks.playlistId.equals(playlistId) & _db.playlistTracks.trackId.equals(trackId)))
          .get()
          .then((rows) => rows.isNotEmpty);
      if (present) return AddTrackResult.alreadyPresent;
      final int nextPosition = await _nextPosition(playlistId);
      await _db.into(_db.playlistTracks).insert(
            PlaylistTracksCompanion.insert(
              playlistId: playlistId,
              trackId: trackId,
              position: nextPosition,
              addedSinceSave: const Value(true),
            ),
          );
      return AddTrackResult.added;
    });
  }

  /// Ajout en masse (ex. "Ajouter par artiste" de l'éditeur de playlist,
  /// Feuille de route pt.9) : une seule transaction plutôt que N appels
  /// séquentiels à [addTrack], qui recalculeraient chacun `_nextPosition` par
  /// une requête à part — coûteux et sujet à une position dupliquée si deux
  /// ajouts se chevauchaient. [trackIds] déjà présents dans la playlist sont
  /// ignorés (jamais dupliqués ni déplacés) plutôt qu'écrasés, tout comme un
  /// id répété dans [trackIds] (sinon violation de clé primaire : rien
  /// n'était ajouté).
  Future<int> addTracks(String playlistId, List<String> trackIds) async {
    if (trackIds.isEmpty) return 0;

    return _db.transaction(() async {
      final List<PlaylistTrack> existing =
          await (_db.select(_db.playlistTracks)..where((t) => t.playlistId.equals(playlistId))).get();
      final Set<String> alreadyPresent = existing.map((t) => t.trackId).toSet();
      final Set<String> inLibrary = await _inLibrary(trackIds);
      final List<String> toAdd =
          {...trackIds}.where((id) => inLibrary.contains(id) && !alreadyPresent.contains(id)).toList();
      if (toAdd.isEmpty) return 0;

      int nextPosition = await _nextPosition(playlistId);
      await _db.batch((batch) {
        batch.insertAll(_db.playlistTracks, [
          for (final trackId in toAdd)
            PlaylistTracksCompanion.insert(
              playlistId: playlistId,
              trackId: trackId,
              position: nextPosition++,
              addedSinceSave: const Value(true),
            ),
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

  /// Ids réellement en bibliothèque : un id périmé (morceau supprimé ou mis
  /// en liste noire pendant qu'un écran l'affichait encore) n'est jamais
  /// ajouté — SQLite n'impose pas la clé étrangère `track_id`.
  Future<Set<String>> _inLibrary(List<String> trackIds) async {
    final query = _db.selectOnly(_db.tracks)
      ..addColumns([_db.tracks.id])
      ..where(_db.tracks.id.isIn(trackIds));
    return {for (final row in await query.get()) row.read(_db.tracks.id)!};
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
