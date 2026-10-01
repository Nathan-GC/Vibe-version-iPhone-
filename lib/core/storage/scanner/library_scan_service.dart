import 'dart:io';

import 'package:path/path.dart' as p;

import '../../identity/track_key.dart';
import '../../shared/constants/app_constants.dart';
import '../filename_sanitizer/filename_sanitizer.dart';
import '../metadata_extractor/metadata_extractor.dart';
import '../metadata_extractor/raw_track_metadata.dart';
import '../silence_trimmer/silence_trimmer.dart';
import '../storage_manager/imported_audio_file.dart';
import 'scanned_track.dart';

/// Lecture ID3 avec repli sur le nom de fichier (MetadataExtractor +
/// FilenameSanitizer), filtre de durée < 30s, puis découpage des silences
/// (SilenceTrimmerService). Produit des [ScannedTrack] prêts à insérer en base
/// — pour un fichier importé (StorageManagerService) ou déjà connu
/// (FullDeviceScanService, assistant de morceaux manquants).
class LibraryScanService {
  LibraryScanService({
    MetadataExtractor? metadataExtractor,
    FilenameSanitizer? filenameSanitizer,
    SilenceTrimmerService? silenceTrimmer,
  })  : _metadataExtractor = metadataExtractor ?? MetadataExtractor(),
        _filenameSanitizer = filenameSanitizer ?? FilenameSanitizer(),
        _silenceTrimmer = silenceTrimmer ?? SilenceTrimmerService();

  final MetadataExtractor _metadataExtractor;
  final FilenameSanitizer _filenameSanitizer;
  final SilenceTrimmerService _silenceTrimmer;

  /// Traite un fichier déjà connu (hors scan de dossier) — le repli sans-ID3
  /// reparse son propre nom de fichier sur disque.
  Future<ScannedTrack?> processSingleFile(File file) {
    return _process(file, () => _filenameSanitizer.sanitizeFilename(p.basename(file.path)));
  }

  /// Traite un fichier tout juste importé via StorageManagerService (Étape 6 —
  /// assistant de morceaux manquants, Bibliothèque). Le repli sans-ID3 réutilise
  /// le résultat de sanitization déjà calculé sur le nom *original* plutôt que
  /// de reparser le nom déjà renommé en `{artist}-{title}.mp3` (voir
  /// ImportedAudioFile).
  Future<ScannedTrack?> processImportedFile(ImportedAudioFile imported) {
    return _process(imported.file, () => imported.sanitizedFromOriginalName);
  }

  Future<ScannedTrack?> _process(File file, SanitizedFilename Function() fallbackSanitize) async {
    final RawTrackMetadata metadata = await _metadataExtractor.extract(file);
    final int durationMs = metadata.durationMs ?? 0;

    if (durationMs > 0 && durationMs < AppConstants.minTrackDuration.inMilliseconds) {
      return null;
    }

    late final String title;
    late final List<String> artists;
    late final bool requiresUserReview;
    late final bool wasRenamedFromFilename;

    if (metadata.hasTitleAndArtist) {
      title = metadata.title!.trim();
      artists = metadata.artists;
      requiresUserReview = false;
      wasRenamedFromFilename = false;
    } else {
      final SanitizedFilename sanitized = fallbackSanitize();
      title = sanitized.title;
      artists = [sanitized.artist, ...sanitized.featuringArtists];
      requiresUserReview = sanitized.requiresUserReview;
      wasRenamedFromFilename = true;
    }

    final String primaryArtist = artists.isNotEmpty ? artists.first : 'Unknown';
    final String id = buildSanitizedKey(title: title, album: metadata.album, primaryArtist: primaryArtist);

    final trim = durationMs > 0
        ? await _silenceTrimmer.detect(file.path, durationMs: durationMs)
        : const TrimResult(trimStartMs: 0, trimEndMs: 0);

    return ScannedTrack(
      id: id,
      title: title,
      album: metadata.album ?? '',
      primaryArtist: primaryArtist,
      artists: artists,
      filePath: file.path,
      durationMs: durationMs,
      genre: metadata.genre,
      bpm: metadata.bpm,
      requiresUserReview: requiresUserReview,
      wasRenamedFromFilename: wasRenamedFromFilename,
      trimStartMs: trim.trimStartMs,
      trimEndMs: trim.trimEndMs,
    );
  }
}
