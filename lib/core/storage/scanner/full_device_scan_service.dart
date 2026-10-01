import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../database/track_repository.dart';
import '../file_scanner/device_root_resolver.dart';
import '../file_scanner/file_scanner.dart';
import 'library_scan_service.dart';
import 'scanned_track.dart';

/// Étape du scan plein-appareil (Étape 8), pour l'écran d'onboarding.
enum FullDeviceScanPhase { listingFiles, indexing, done }

class FullDeviceScanProgress {
  const FullDeviceScanProgress({
    required this.phase,
    required this.processed,
    required this.total,
    this.skippedIncompleteDownloads = 0,
  });

  final FullDeviceScanPhase phase;
  final int processed;
  final int total;
  // Fichiers reconnus mais non exploitables (ex. ".giga", téléchargement
  // YouTube->audio resté incomplet) — comptés à part pour que l'écran
  // d'onboarding puisse le signaler plutôt que de les faire disparaître sans
  // trace du dossier scanné.
  final int skippedIncompleteDownloads;
}

/// Calcule le SHA-256 d'un fichier — fonction top-level pour pouvoir tourner
/// dans un isolate séparé via [compute] (Étape 8 : ne pas geler l'UI à 60 FPS
/// pendant l'indexation de ~300 fichiers).
Future<String> _hashFile(String path) async {
  final Digest digest = await sha256.bind(File(path).openRead()).first;
  return digest.toString();
}

/// Orchestration du scan plein-appareil du premier lancement et des scans
/// incrémentaux des lancements suivants (Étape 8).
///
/// Le test "fichier inchangé" repose d'abord sur `lastModified` + taille
/// (quasi instantané, aucune lecture de contenu) : c'est ce qui permet un
/// démarrage quasi instantané dès le 2e lancement. Le hash SHA-256 n'est
/// calculé (et stocké) que pour les fichiers nouveaux ou dont `lastModified`/
/// taille ont changé — il sert d'empreinte de contenu fiable pour ces
/// fichiers-là, pas de mécanisme de détection rapide en lui-même.
class FullDeviceScanService {
  // Auparavant restreint à {'.mp3'} : ça écartait silencieusement tous les
  // .m4a/.flac/.aac/.ogg du scan plein-appareil du premier lancement (~30%
  // d'une bibliothèque réelle testée), alors que FileScanner les supporte
  // déjà par défaut et que MetadataExtractor/FilenameSanitizer les traitent
  // très bien. Reprend donc les extensions par défaut de FileScanner.
  FullDeviceScanService({LibraryScanService? scanService})
      : _scanService = scanService ?? LibraryScanService(),
        _fileScanner = FileScanner();

  final LibraryScanService _scanService;
  final FileScanner _fileScanner;

  /// Isolates simultanés max pour le hachage — évite de saturer l'appareil
  /// tout en parallélisant le gros du travail CPU du scan.
  static const int _maxConcurrentHashing = 4;

  Future<List<ScannedTrack>> scan({
    required TrackRepository trackRepository,
    void Function(FullDeviceScanProgress progress)? onProgress,
  }) async {
    final Directory? root = await DeviceRootResolver.resolve();
    if (root == null) return const [];

    onProgress?.call(const FullDeviceScanProgress(phase: FullDeviceScanPhase.listingFiles, processed: 0, total: 0));
    final FileScanResult scanResult = await _fileScanner.scan(root);
    final List<File> candidates = scanResult.audioFiles;
    final int skipped = scanResult.incompleteDownloads.length;

    final List<ScannedTrack> results = [];
    int processed = 0;

    for (int i = 0; i < candidates.length; i += _maxConcurrentHashing) {
      final batch = candidates.skip(i).take(_maxConcurrentHashing);
      final List<ScannedTrack?> batchResults = await Future.wait(
        batch.map((file) => _processOneFile(file, trackRepository)),
      );
      results.addAll(batchResults.whereType<ScannedTrack>());

      processed += batch.length;
      onProgress?.call(
        FullDeviceScanProgress(
          phase: FullDeviceScanPhase.indexing,
          processed: processed,
          total: candidates.length,
          skippedIncompleteDownloads: skipped,
        ),
      );
    }

    onProgress?.call(
      FullDeviceScanProgress(
        phase: FullDeviceScanPhase.done,
        processed: candidates.length,
        total: candidates.length,
        skippedIncompleteDownloads: skipped,
      ),
    );
    return results;
  }

  Future<ScannedTrack?> _processOneFile(File file, TrackRepository trackRepository) async {
    final FileStat stat = await file.stat();
    final int currentMtime = stat.modified.millisecondsSinceEpoch;

    final existing = await trackRepository.findByFilePath(file.path);
    if (existing != null && existing.lastModifiedEpochMs == currentMtime) {
      // Fichier inchangé depuis le dernier scan : on saute entièrement
      // l'extraction ID3 et le découpage de silence.
      return null;
    }

    final String hash = await compute(_hashFile, file.path);
    final ScannedTrack? scanned = await _scanService.processSingleFile(file);
    if (scanned == null) return null;

    return ScannedTrack(
      id: scanned.id,
      title: scanned.title,
      album: scanned.album,
      primaryArtist: scanned.primaryArtist,
      artists: scanned.artists,
      filePath: scanned.filePath,
      durationMs: scanned.durationMs,
      requiresUserReview: scanned.requiresUserReview,
      wasRenamedFromFilename: scanned.wasRenamedFromFilename,
      trimStartMs: scanned.trimStartMs,
      trimEndMs: scanned.trimEndMs,
      genre: scanned.genre,
      bpm: scanned.bpm,
      lastModifiedEpochMs: currentMtime,
      fileHash: hash,
    );
  }
}
