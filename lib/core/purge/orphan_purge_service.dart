import 'dart:io';

import '../storage/database/app_database.dart';
import '../storage/database/blacklist_repository.dart';
import '../storage/database/track_repository.dart';

/// Bilan d'une suppression : morceaux effacés de l'appareil, et ceux dont le
/// système a refusé la suppression du fichier — mis en liste noire à la
/// place, donc retirés de Vibe malgré tout.
class PurgeResult {
  const PurgeResult({required this.deleted, required this.blacklisted});

  final List<Track> deleted;
  final List<Track> blacklisted;

  /// Morceaux sortis de la bibliothèque, quel que soit leur sort.
  Set<String> get removedIds => {
        for (final Track t in [...deleted, ...blacklisted]) t.id
      };
}

/// Suppression **définitive** (fichier physique + lignes `tracks`/`track_artists`
/// + liaisons `playlist_tracks`) des morceaux sélectionnés dans la vue de
/// nettoyage (Étape 7), l'appui long d'un morceau ou l'écran des doublons.
///
/// Fichier protégé (stockage cloisonné d'Android, lecture seule) : l'échec
/// n'interrompt plus rien — le morceau passe en liste noire (voir
/// [BlacklistRepository]) et quitte Vibe quand même. Chaque fichier est
/// traité séparément : auparavant, un refus au milieu d'un lot levait une
/// exception après avoir effacé les fichiers précédents, dont les lignes
/// restaient en base.
class OrphanPurgeService {
  OrphanPurgeService(this._db, {Future<bool> Function(String path)? deleteFile})
      : _deleteFile = deleteFile ?? _deleteIfPresent;

  final AppDatabase _db;
  final Future<bool> Function(String path) _deleteFile;

  Future<PurgeResult> deleteTracks(List<Track> tracks) async {
    final List<Track> deleted = [];
    final List<Track> protected = [];
    for (final Track track in tracks) {
      bool gone;
      try {
        gone = await _deleteFile(track.filePath);
      } catch (_) {
        gone = false;
      }
      (gone ? deleted : protected).add(track);
    }

    await TrackRepository(_db).removeFromLibrary([for (final Track t in deleted) t.id]);
    await BlacklistRepository(_db).blacklist(protected, reason: BlacklistReason.deletionFailed);
    return PurgeResult(deleted: deleted, blacklisted: protected);
  }

  /// `true` si le fichier n'existe plus ensuite (déjà absent compris) —
  /// revérifié après `delete()` plutôt que de s'y fier.
  static Future<bool> _deleteIfPresent(String path) async {
    final File file = File(path);
    if (await file.exists()) await file.delete();
    return !await file.exists();
  }
}
