import 'dart:io';

import 'package:drift/drift.dart';

import '../storage/database/app_database.dart';
import '../storage/database/track_repository.dart';
import 'orphan_track.dart';

/// Détecte les fichiers `tracks` rattachés à 0 ligne dans `playlist_tracks`
/// (anti-jointure) et calcule leur taille sur disque.
class OrphanDetectorService {
  OrphanDetectorService(this._db);

  final AppDatabase _db;

  Future<List<OrphanTrack>> findOrphans() async {
    // Tout morceau importé est automatiquement lié à la playlist système
    // "Tous les titres importés" (voir TrackRepository._linkToAllImportedPlaylist) :
    // sans l'exclure de la jointure, plus aucun morceau n'a jamais 0 ligne
    // dans playlist_tracks et le détecteur ne trouve plus jamais rien — bug
    // réel signalé après l'introduction de cette playlist système. Exclure
    // cette liaison précise du critère de jointure (pas du WHERE final)
    // pour qu'un morceau seulement rattaché à elle soit toujours considéré
    // orphelin (aucune *vraie* playlist ne le référence).
    final query = _db.select(_db.tracks).join([
      leftOuterJoin(
        _db.playlistTracks,
        _db.playlistTracks.trackId.equalsExp(_db.tracks.id) &
            _db.playlistTracks.playlistId.equals(kAllImportedPlaylistId).not(),
      ),
    ])
      ..where(_db.playlistTracks.trackId.isNull());

    final List<Track> orphanTracks = (await query.get()).map((row) => row.readTable(_db.tracks)).toList();

    final List<OrphanTrack> results = [];
    for (final track in orphanTracks) {
      final File file = File(track.filePath);
      final int sizeBytes = await file.exists() ? await file.length() : 0;
      results.add(OrphanTrack(track: track, fileSizeBytes: sizeBytes));
    }
    return results;
  }
}
