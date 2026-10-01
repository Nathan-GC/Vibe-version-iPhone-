import '../storage/database/app_database.dart';

/// Morceau physiquement présent dans /Music/AppFolder/ mais rattaché à 0
/// playlist (`playlist_tracks`) — candidat à la purge mensuelle (Étape 7).
class OrphanTrack {
  const OrphanTrack({required this.track, required this.fileSizeBytes});

  final Track track;
  final int fileSizeBytes;

  double get fileSizeMb => fileSizeBytes / (1024 * 1024);
}
