import 'dart:io';

import '../../../core/storage/database/app_database.dart';
import '../../../core/storage/database/track_repository.dart';
import '../../../core/storage/scanner/audio_import_pipeline.dart';
import '../../../core/storage/scanner/library_scan_service.dart';
import '../../../core/storage/scanner/scanned_track.dart';
import '../../../core/storage/storage_manager/storage_manager_service.dart';

/// Résout une entrée de manifeste manquante (Étape 6.4) en important un
/// fichier choisi par l'utilisateur : copie vers /Music/AppFolder/ (Disk
/// Guard, Étape 1), passage par le pipeline de scan/sanitization (Étape 2),
/// puis insertion en base (Étape 3) — voir [AudioImportPipeline], qui
/// supprime aussi la copie d'un fichier refusé (< 30 s).
class MissingTrackResolver {
  MissingTrackResolver(StorageManagerService storageManager, LibraryScanService scanService, this._trackRepository)
      : _pipeline = AudioImportPipeline(
          storageManager: storageManager,
          scanService: scanService,
          trackRepository: _trackRepository,
        );

  final AudioImportPipeline _pipeline;
  final TrackRepository _trackRepository;

  Future<Track?> importFromDevice(File pickedFile) async {
    final ScannedTrack? scanned = await _pipeline.importFile(pickedFile);
    if (scanned == null) return null;
    return _trackRepository.findById(scanned.id);
  }
}
