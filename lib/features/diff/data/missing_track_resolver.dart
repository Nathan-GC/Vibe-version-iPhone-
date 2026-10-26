import 'dart:io';

import '../../../core/storage/database/app_database.dart';
import '../../../core/storage/database/blacklist_repository.dart';
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
  MissingTrackResolver(
    StorageManagerService storageManager,
    LibraryScanService scanService,
    this._trackRepository,
    BlacklistRepository blacklistRepository,
  ) : _pipeline = AudioImportPipeline(
          storageManager: storageManager,
          scanService: scanService,
          trackRepository: _trackRepository,
          blacklistRepository: blacklistRepository,
        );

  final AudioImportPipeline _pipeline;
  final TrackRepository _trackRepository;

  /// Lève [BlacklistedImportException] pour un titre en liste noire. Un titre
  /// déjà en bibliothèque (fichier présent) n'est pas réimporté : le titre
  /// existant est simplement renvoyé pour être associé.
  Future<Track?> importFromDevice(File pickedFile) async {
    try {
      final ScannedTrack? scanned = await _pipeline.importFile(pickedFile);
      if (scanned == null) return null;
      return await _trackRepository.findById(scanned.id);
    } on AlreadyInLibraryImportException catch (present) {
      return present.existing;
    }
  }

  /// Titre en liste noire que l'utilisateur a choisi de restaurer, voir
  /// [AudioImportPipeline.restoreBlacklisted].
  Future<Track?> restoreFromDevice(File pickedFile, BlacklistedTrack entry) async {
    final String? id = await _pipeline.restoreBlacklisted(pickedFile, entry);
    return id == null ? null : _trackRepository.findById(id);
  }
}
