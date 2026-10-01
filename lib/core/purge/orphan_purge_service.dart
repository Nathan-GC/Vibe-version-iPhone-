import 'dart:io';

import '../storage/database/app_database.dart';

/// Suppression **définitive** (fichier physique + lignes `tracks`/`track_artists`
/// + liaisons `playlist_tracks`) des morceaux sélectionnés dans la vue de
/// nettoyage (Étape 7), l'appui long d'un morceau ou l'écran des doublons.
/// Les liaisons de playlist sont retirées aussi : un morceau supprimé
/// depuis l'écran des doublons figure au moins dans "Tous les titres
/// importés", et y laisserait sinon une ligne fantôme (masquée par les
/// jointures internes, mais comptée dans les positions de la playlist).
class OrphanPurgeService {
  OrphanPurgeService(this._db);

  final AppDatabase _db;

  Future<void> deleteTracks(List<Track> tracks) async {
    if (tracks.isEmpty) return;

    for (final track in tracks) {
      final File file = File(track.filePath);
      if (await file.exists()) await file.delete();
    }

    final List<String> ids = tracks.map((t) => t.id).toList();
    await _db.transaction(() async {
      await (_db.delete(_db.playlistTracks)..where((t) => t.trackId.isIn(ids))).go();
      await (_db.delete(_db.trackArtists)..where((t) => t.trackId.isIn(ids))).go();
      await (_db.delete(_db.tracks)..where((t) => t.id.isIn(ids))).go();
    });
  }
}
