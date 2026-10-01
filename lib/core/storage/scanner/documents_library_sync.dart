import '../database/track_repository.dart';
import 'full_device_scan_service.dart';
import 'scanned_track.dart';

/// Bilan d'une synchronisation du dossier Documents (iOS).
class DocumentsSyncResult {
  const DocumentsSyncResult({required this.added, required this.enriched, required this.skippedIncompleteDownloads});

  /// Morceaux nouveaux (ou modifiés depuis le dernier passage) indexés.
  final int added;

  /// Parmi eux, morceaux renommés depuis leur nom de fichier puis enrichis.
  final int enriched;

  /// Fichiers reconnus mais inexploitables (voir FileScanner, `.giga`).
  final int skippedIncompleteDownloads;
}

/// iOS : indexation incrémentale des fichiers audio que l'utilisateur dépose
/// dans le dossier Documents de l'app — app Fichiers (« Sur mon iPhone >
/// Vibe ») ou Finder/iTunes (partage de fichiers, `UIFileSharingEnabled`).
///
/// Pendant iOS des scans incrémentaux de [FullDeviceScanService] : sur
/// Android, le scan plein-appareil du premier lancement voit d'emblée toute
/// la musique déjà présente sur le téléphone ; sur iOS, ce dossier est
/// forcément vide à l'installation — sans cette synchronisation relancée au
/// démarrage, au retour au premier plan et à la demande (Bibliothèque), un
/// morceau déposé plus tard ne serait jamais indexé.
///
/// Même enchaînement que le premier scan (OnboardingScanController.start) :
/// phase 1, indexation et persistance de TOUS les fichiers nouveaux ; phase 2
/// seulement ensuite, enrichissement en passe unique (iTunes puis MusicBrainz) des seuls
/// morceaux renommés depuis leur nom de fichier. Les fichiers inchangés sont
/// ignorés sans être relus (test `lastModified`, voir FullDeviceScanService).
class DocumentsLibrarySync {
  DocumentsLibrarySync({
    required FullDeviceScanService scanService,
    required TrackRepository repository,
    required Future<bool> Function(ScannedTrack track) enrichRenamedTrack,
  })  : _scanService = scanService,
        _repository = repository,
        _enrichRenamedTrack = enrichRenamedTrack;

  final FullDeviceScanService _scanService;
  final TrackRepository _repository;
  final Future<bool> Function(ScannedTrack track) _enrichRenamedTrack;

  Future<DocumentsSyncResult> run({void Function(FullDeviceScanProgress progress)? onProgress}) async {
    int skipped = 0;
    final List<ScannedTrack> tracks = await _scanService.scan(
      trackRepository: _repository,
      onProgress: (progress) {
        skipped = progress.skippedIncompleteDownloads;
        onProgress?.call(progress);
      },
    );

    for (final ScannedTrack track in tracks) {
      await _repository.upsertTrack(track);
    }

    int enriched = 0;
    for (final ScannedTrack track in tracks.where((t) => t.wasRenamedFromFilename)) {
      if (await _enrichRenamedTrack(track)) enriched++;
    }

    return DocumentsSyncResult(added: tracks.length, enriched: enriched, skippedIncompleteDownloads: skipped);
  }
}
