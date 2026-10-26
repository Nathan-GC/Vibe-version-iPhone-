import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../shared/onboarding_storage.dart';
import '../database/app_database.dart';
import '../database/track_repository.dart';
import 'embedded_cover_extractor.dart';
import 'metadata_extractor.dart';

/// Rattrapage UNIQUE des pochettes intégrées pour les titres déjà scannés : le
/// scan incrémental ne relit pas un fichier inchangé, donc une bibliothèque
/// indexée avant l'extraction des pochettes n'en recevrait jamais. 100 %
/// local (aucun réseau, donc indépendant de l'interrupteur d'enrichissement).
class EmbeddedCoverBackfill {
  EmbeddedCoverBackfill({
    required TrackRepository repository,
    MetadataExtractor? metadataExtractor,
    EmbeddedCoverExtractor? coverExtractor,
    Future<bool> Function()? isFirstLaunch,
  })  : _repository = repository,
        _metadataExtractor = metadataExtractor ?? MetadataExtractor(),
        _coverExtractor = coverExtractor ?? EmbeddedCoverExtractor(),
        _isFirstLaunch = isFirstLaunch ?? OnboardingStorage().isFirstLaunch;

  static const String doneFlagKey = 'covers.embedded_backfill_v1_done';

  final TrackRepository _repository;
  final MetadataExtractor _metadataExtractor;
  final EmbeddedCoverExtractor _coverExtractor;
  final Future<bool> Function() _isFirstLaunch;
  bool _running = false;

  /// Une seule passe par installation : le drapeau n'est posé qu'une fois tous
  /// les titres parcourus (une passe interrompue reprend au lancement suivant,
  /// les titres déjà pourvus étant ignorés). Rien au premier lancement : le scan
  /// d'onboarding extrait déjà les pochettes.
  Future<void> runOnce() async {
    if (_running) return;
    _running = true;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(doneFlagKey) ?? false) return;
      if (await _isFirstLaunch()) return;

      final List<Track> tracks = await _repository.fetchAllTracks();
      // Séquentiel : un ffprobe/ffmpeg à la fois pour ne pas saturer le téléphone.
      for (final Track track in tracks) {
        if (track.coverArtPath.isNotEmpty) continue;
        await _backfill(track);
      }
      await prefs.setBool(doneFlagKey, true);
    } finally {
      _running = false;
    }
  }

  Future<void> _backfill(Track track) async {
    try {
      final File file = File(track.filePath);
      if (!await file.exists()) return;
      final String? codec = (await _metadataExtractor.extract(file)).embeddedCoverCodec;
      if (codec == null) return;
      final String? cover = await _coverExtractor.extract(file, trackId: track.id, codec: codec);
      await _repository.applyExtractedCover(track.id, cover);
    } catch (_) {
      // Un fichier illisible n'arrête pas la passe : il sera simplement sans pochette.
    }
  }
}

final Provider<EmbeddedCoverBackfill> embeddedCoverBackfillProvider = Provider<EmbeddedCoverBackfill>((ref) {
  return EmbeddedCoverBackfill(repository: ref.watch(trackRepositoryProvider));
});
