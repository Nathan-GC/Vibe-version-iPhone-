import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../storage/database/track_repository.dart';
import 'bass_analysis_service.dart';

final Provider<BassAnalysisService> bassAnalysisServiceProvider =
    Provider<BassAnalysisService>((ref) => BassAnalysisService());

/// Analyse hors ligne d'un morceau : enveloppe des basses + BPM estimé.
typedef TrackAudioAnalysis = ({Uint8List envelope, int? estimatedBpm});

// Morceaux dont l'analyse a échoué pendant cette session : un fichier
// illisible ne relance pas FFmpeg à chaque affichage (le provider est
// autoDispose). Non persisté : un fichier réparé est retenté au prochain lancement.
final Set<String> _failedAnalyses = {};

/// Analyse d'un morceau, calculée une seule fois puis relue en base. Observé
/// uniquement quand la Vibe "Behind the window" est affichée : sans observateur,
/// aucune analyse ne se lance. Le paramètre de la famille garantit qu'un même
/// morceau n'est jamais analysé deux fois en parallèle.
///
/// Null : morceau sans fichier local, ou analyse impossible (l'effet retombe
/// alors sur la pulsation du tempo).
final trackAudioAnalysisProvider = FutureProvider.autoDispose.family<TrackAudioAnalysis?, String>((ref, trackId) async {
  final TrackRepository repository = ref.watch(trackRepositoryProvider);

  final Uint8List? stored = await repository.bassEnvelopeFor(trackId);
  if (stored != null) {
    // Le BPM est lu en base et non dans le `Track` du lecteur, copie qui peut
    // dater d'avant l'analyse.
    return (envelope: stored, estimatedBpm: (await repository.findById(trackId))?.estimatedBpm);
  }

  final filePath = (await repository.findById(trackId))?.filePath;
  if (filePath == null || filePath.isEmpty || _failedAnalyses.contains(trackId)) return null;

  final TrackAudioAnalysis? analysis = await ref.read(bassAnalysisServiceProvider).analyze(filePath);
  if (analysis == null) {
    _failedAnalyses.add(trackId);
    return null;
  }
  await repository.saveAudioAnalysis(trackId, envelope: analysis.envelope, estimatedBpm: analysis.estimatedBpm);
  return analysis;
});
