/// Résultat prêt à persister dans `tracks` pour un fichier scanné avec succès.
class ScannedTrack {
  const ScannedTrack({
    required this.id,
    required this.title,
    required this.album,
    required this.primaryArtist,
    required this.artists,
    required this.filePath,
    required this.durationMs,
    required this.requiresUserReview,
    required this.trimStartMs,
    required this.trimEndMs,
    this.wasRenamedFromFilename = false,
    this.genre,
    this.bpm,
    this.lastModifiedEpochMs = 0,
    this.fileHash,
  });

  final String id;
  final String title;
  final String album;
  final String primaryArtist;
  final List<String> artists;
  final String filePath;
  final int durationMs;
  final bool requiresUserReview;
  final int trimStartMs;
  final int trimEndMs;
  // true quand titre/artiste viennent du repli FilenameSanitizer (pas de tag
  // ID3 exploitable) — c'est-à-dire que le morceau a été "renommé" à partir
  // de son nom de fichier brut. Sert à restreindre l'enrichissement iTunes
  // automatique de post-import aux seuls morceaux effectivement renommés
  // (voir LibraryScreen._importFiles, OnboardingScanController.start) plutôt
  // que d'interroger l'API pour des morceaux déjà correctement tagués.
  final bool wasRenamedFromFilename;
  final String? genre;
  // Null quand le fichier n'a pas de tag TBPM — le défaut de 120 en base
  // s'applique alors (voir Tracks.bpm, core/storage/database/app_database.dart).
  final int? bpm;
  // Empreinte du fichier au moment du scan (Étape 8) — permet au scan
  // incrémental des lancements suivants de sauter les fichiers inchangés sans
  // relire leurs tags ni relancer le découpage de silence.
  final int lastModifiedEpochMs;
  final String? fileHash;
}
