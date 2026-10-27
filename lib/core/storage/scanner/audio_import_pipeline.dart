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

/// Import sans effet : le titre du fichier choisi est déjà en bibliothèque et
/// son fichier existe encore. Rien n'a été copié ni écrasé (édition manuelle,
/// statut d'enrichissement et fichier protégé restent intacts) ; [existing]
/// est le titre en base, à associer ou à signaler comme « déjà présent ».
class AlreadyInLibraryImportException implements Exception {
  const AlreadyInLibraryImportException(this.existing);

  final Track existing;

  @override
  String toString() => '« ${existing.title} » est déjà dans la bibliothèque';
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
  ///
  /// Titre déjà en base (même clé) : si son fichier existe encore ET qu'il
  /// s'agit du même enregistrement (écart de durée <= [sameRecordingTolerance]),
  /// rien n'est copié ni écrit ([AlreadyInLibraryImportException]) — un
  /// réimport ne doit pas écraser l'édition manuelle ni re-pointer un fichier
  /// protégé vers une copie supprimable. Même clé mais durée différente : c'est
  /// une AUTRE version (« Radio Edit » / original, « Slowed »…, la mention est
  /// retirée par le nettoyage) — import normal ; [TrackRepository.upsertTrack]
  /// lui donne un id de variante `<id>~N` et les deux titres apparaissent dans
  /// « Doublons détectés ». Les versions déjà importées sont toutes
  /// comparées : réimporter la version 2 ne crée pas une version 3.
  /// Si le fichier du titre a disparu, la nouvelle copie ne remplace que le lien
  /// vers le fichier ([TrackRepository.relinkFile]) et le titre est renvoyé
  /// comme importé, sans `wasRenamedFromFilename` : il est déjà enrichi ou
  /// édité, l'enrichissement auto ne doit pas le relancer.
  ///
  /// Le [ScannedTrack] renvoyé porte l'id EFFECTIF en base (possiblement un id
  /// de variante), à utiliser pour la suite (enrichissement, association).
  Future<ScannedTrack?> importFile(File source) async {
    final ScannedTrack? identity = await _scanService.identify(source);
    if (identity == null) return null;
    final BlacklistedTrack? hidden = await _blacklist.findMatch(identity);
    if (hidden != null) throw BlacklistedImportException(hidden);

    final List<Track> versions = await _trackRepository.findVersionsOf(identity.id);
    final List<Track> missing = [];
    for (final Track version in versions) {
      if (!await File(version.filePath).exists()) {
        missing.add(version);
      } else if (_isSameRecording(version, identity)) {
        throw AlreadyInLibraryImportException(version);
      }
    }
    // Fichier disparu : relié de préférence à la version de même durée, sinon à
    // la première (cas historique d'un titre unique).
    final Track? existing =
        missing.isEmpty ? null : missing.firstWhere((v) => _isSameRecording(v, identity), orElse: () => missing.first);

    final ImportedAudioFile imported = await _storageManager.importAudioFile(source);
    try {
      final ScannedTrack? track = await _scanService.processImportedFile(imported);
      if (track == null) {
        await _discard(imported.file);
        return null;
      }
      if (existing != null) {
        await _trackRepository.relinkFile(existing.id, track);
        return ScannedTrack(
          id: existing.id,
          title: existing.title,
          album: existing.album,
          primaryArtist: track.primaryArtist,
          artists: existing.artists,
          filePath: track.filePath,
          durationMs: track.durationMs,
          requiresUserReview: false,
          trimStartMs: track.trimStartMs,
          trimEndMs: track.trimEndMs,
          lastModifiedEpochMs: track.lastModifiedEpochMs,
          fileHash: track.fileHash,
        );
      }
      // Id effectif : un fichier dont l'identité est déjà prise par une autre
      // version reçoit un id de variante, `null` si la liste noire l'a refusé.
      final String? savedId = await _trackRepository.upsertTrack(track);
      return savedId == null ? track : track.withId(savedId);
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
        try {
          return (await importFile(source))?.id;
        } on AlreadyInLibraryImportException catch (present) {
          return present.existing.id;
        }
    }
  }

  /// Écart de durée toléré entre deux fichiers pour y voir le même
  /// enregistrement : les durées lues varient de quelques secondes d'un
  /// encodage ou d'un lecteur à l'autre, pas d'une version (radio edit, slowed,
  /// sped up) à l'autre.
  static const int sameRecordingTolerance = 5;

  /// Même enregistrement ? Durée du fichier choisi inconnue (0) ou du titre en
  /// base inconnue (0) : on ne peut pas distinguer, donc « même » — c'est le
  /// choix prudent (AN-03, ne rien écraser, ne rien dupliquer).
  bool _isSameRecording(Track existing, ScannedTrack picked) {
    if (existing.durationSeconds == 0 || picked.durationMs == 0) return true;
    return (existing.durationSeconds - picked.durationMs ~/ 1000).abs() <= sameRecordingTolerance;
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
