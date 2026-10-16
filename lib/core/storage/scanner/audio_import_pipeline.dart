import 'dart:io';

import '../database/app_database.dart';
import '../database/blacklist_repository.dart';
import '../database/track_repository.dart';
import '../storage_manager/imported_audio_file.dart';
import '../storage_manager/storage_manager_service.dart';
import 'library_scan_service.dart';
import 'scanned_track.dart';

/// Import refusé : le fichier choisi correspond à un titre de la liste noire
/// ([BlacklistRepository.findMatch]). Rien n'a été copié ; à l'utilisateur de
/// choisir de le restaurer ([AudioImportPipeline.restoreBlacklisted]).
class BlacklistedImportException implements Exception {
  const BlacklistedImportException(this.entry);

  final BlacklistedTrack entry;

  @override
  String toString() => '« ${entry.title} » est dans la liste noire';
}

/// Import d'un fichier audio choisi par l'utilisateur : copie vers le
/// dossier de l'app (StorageManagerService, Disk Guard), scan (ID3/nom de
/// fichier, filtre de durée, silences — LibraryScanService), puis insertion
/// en base. Partagé par la Bibliothèque et l'assistant de morceaux manquants.
///
/// Nettoyage (recette QA v1.2, choix 3-A) : la copie privée est supprimée
/// dès que le fichier n'entre pas en bibliothèque — refusé car plus court
/// que 30 s (`processImportedFile` renvoie `null`) ou en échec avant la fin
/// de l'insertion en base — pour ne pas accumuler de fichiers invisibles
/// dans l'app. Seule la COPIE est supprimée : l'import copie toujours
/// (`moveFile: false`), le fichier d'origine de l'utilisateur n'est jamais
/// touché.
class AudioImportPipeline {
  AudioImportPipeline({
    required StorageManagerService storageManager,
    required LibraryScanService scanService,
    required TrackRepository trackRepository,
    required BlacklistRepository blacklistRepository,
  })  : _storageManager = storageManager,
        _scanService = scanService,
        _trackRepository = trackRepository,
        _blacklist = blacklistRepository;

  final StorageManagerService _storageManager;
  final LibraryScanService _scanService;
  final TrackRepository _trackRepository;
  final BlacklistRepository _blacklist;

  /// Morceau inséré en base, ou `null` si refusé (trop court). Un titre en
  /// liste noire (même clé, ou même titre + artiste) est refusé AVANT toute
  /// copie : [BlacklistedImportException]. Relance toute erreur, copie déjà
  /// nettoyée.
  Future<ScannedTrack?> importFile(File source) async {
    final ScannedTrack? identity = await _scanService.identify(source);
    if (identity == null) return null;
    final BlacklistedTrack? hidden = await _blacklist.findMatch(identity);
    if (hidden != null) throw BlacklistedImportException(hidden);

    final ImportedAudioFile imported = await _storageManager.importAudioFile(source);
    try {
      final ScannedTrack? track = await _scanService.processImportedFile(imported);
      if (track == null) {
        await _discard(imported.file);
        return null;
      }
      await _trackRepository.upsertTrack(track);
      return track;
    } catch (_) {
      await _discard(imported.file);
      rethrow;
    }
  }

  /// « Restaurer » en réponse à [BlacklistedImportException] : le titre masqué
  /// revient à l'identique (playlists et positions comprises) si son fichier
  /// est toujours là ; sinon (fichier disparu, ou masqué avant indexation)
  /// [source] est importé normalement. Id du titre en bibliothèque, ou `null`
  /// si [source] est refusé (trop court).
  Future<String?> restoreBlacklisted(File source, BlacklistedTrack entry) async {
    switch (await _blacklist.restore(entry)) {
      case RestoreOutcome.restored || RestoreOutcome.alreadyInLibrary:
        return BlacklistRepository.trackKeyOf(entry);
      case RestoreOutcome.fileMissing || RestoreOutcome.unhidden:
        return (await importFile(source))?.id;
    }
  }

  Future<void> _discard(File copy) async {
    try {
      if (await copy.exists()) await copy.delete();
    } on FileSystemException {
      // Nettoyage au mieux : un échec ici ne doit pas masquer le résultat
      // réel de l'import (refus ou erreur d'origine).
    }
  }
}
