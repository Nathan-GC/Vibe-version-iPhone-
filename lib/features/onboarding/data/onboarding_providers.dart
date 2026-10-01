import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../core/platform/app_platform.dart';
import '../../../core/shared/onboarding_storage.dart';
import '../../../core/shared/permission_retry.dart';
import '../../../core/storage/database/database_provider.dart';
import '../../../core/storage/database/track_auto_enricher.dart';
import '../../../core/storage/database/track_repository.dart';
import '../../../core/storage/scanner/full_device_scan_service.dart';
import '../../../core/storage/scanner/scanned_track.dart';
import '../../library/data/library_providers.dart' show trackAutoEnricherProvider;
import '../../settings/data/auto_enrich_preference.dart';

final Provider<FullDeviceScanService> fullDeviceScanServiceProvider = Provider<FullDeviceScanService>((ref) {
  return FullDeviceScanService();
});

final Provider<OnboardingStorage> onboardingStorageProvider = Provider<OnboardingStorage>((ref) {
  return OnboardingStorage();
});

/// État de l'écran d'onboarding (Étape 8) : indexation plein-appareil du
/// premier lancement, exposée pour la barre de progression.
class OnboardingScanState {
  const OnboardingScanState({
    this.phase = FullDeviceScanPhase.listingFiles,
    this.processed = 0,
    this.total = 0,
    this.permissionDenied = false,
    this.skippedIncompleteDownloads = 0,
    this.isEnriching = false,
    this.enrichmentProcessed = 0,
    this.enrichmentTotal = 0,
  });

  final FullDeviceScanPhase phase;
  final int processed;
  final int total;
  final bool permissionDenied;
  final int skippedIncompleteDownloads;
  // Phase 2 (après le renommage/import complet, voir OnboardingScanController
  // .start) : enrichissement iTunes des seuls morceaux renommés depuis leur
  // nom de fichier. `phase` reste à `done` pendant ce temps — c'est ce
  // booléen qui pilote l'affichage, pas un cas de plus dans
  // [FullDeviceScanPhase] (qui ne concerne que le scan/renommage).
  final bool isEnriching;
  final int enrichmentProcessed;
  final int enrichmentTotal;

  OnboardingScanState copyWith({
    FullDeviceScanPhase? phase,
    int? processed,
    int? total,
    bool? permissionDenied,
    int? skippedIncompleteDownloads,
    bool? isEnriching,
    int? enrichmentProcessed,
    int? enrichmentTotal,
  }) {
    return OnboardingScanState(
      phase: phase ?? this.phase,
      processed: processed ?? this.processed,
      total: total ?? this.total,
      permissionDenied: permissionDenied ?? this.permissionDenied,
      skippedIncompleteDownloads: skippedIncompleteDownloads ?? this.skippedIncompleteDownloads,
      isEnriching: isEnriching ?? this.isEnriching,
      enrichmentProcessed: enrichmentProcessed ?? this.enrichmentProcessed,
      enrichmentTotal: enrichmentTotal ?? this.enrichmentTotal,
    );
  }
}

class OnboardingScanController extends Notifier<OnboardingScanState> {
  @override
  OnboardingScanState build() => const OnboardingScanState();

  /// Demande la permission audio, lance le scan plein-appareil (isolates
  /// séparés pour le hachage — voir FullDeviceScanService), persiste chaque
  /// morceau trouvé (phase 1 : renommage/import — un seul passage par
  /// fichier, [FullDeviceScanService]/[LibraryScanService] ne bouclent ni ne
  /// retentent), puis enrichit via iTunes exclusivement (voir "Recadrage du
  /// Workflow d'Enrichissement" — jamais de choix de source ni de question
  /// posée au premier scan) les seuls morceaux renommés depuis leur nom de
  /// fichier (phase 2, jamais entrelacée avec la phase 1 — tout le renommage
  /// est déjà en base avant qu'un seul appel réseau d'enrichissement ne
  /// parte), avant de marquer l'onboarding comme terminé.
  ///
  /// iOS : aucune autorisation à demander — le scan porte sur le dossier
  /// Documents de l'app (voir DeviceRootResolver), toujours lisible par
  /// elle ; `Permission.audio` (READ_MEDIA_AUDIO) n'a pas d'équivalent iOS
  /// et y serait systématiquement refusée.
  Future<void> start() async {
    if (!AppPlatform.isIOS) {
      await requestPermissionWithRetry(Permission.audio);
      final PermissionStatus status = await Permission.audio.status;
      if (!status.isGranted) {
        state = state.copyWith(permissionDenied: true, phase: FullDeviceScanPhase.done);
        await ref.read(onboardingStorageProvider).markCompleted();
        return;
      }
    }

    final TrackRepository repository = TrackRepository(ref.read(appDatabaseProvider));
    final FullDeviceScanService scanService = ref.read(fullDeviceScanServiceProvider);

    final List<ScannedTrack> tracks = await scanService.scan(
      trackRepository: repository,
      onProgress: (progress) {
        state = state.copyWith(
          phase: progress.phase,
          processed: progress.processed,
          total: progress.total,
          skippedIncompleteDownloads: progress.skippedIncompleteDownloads,
        );
      },
    );

    for (final ScannedTrack track in tracks) {
      await repository.upsertTrack(track);
    }

    final List<ScannedTrack> renamedTracks = tracks.where((t) => t.wasRenamedFromFilename).toList();
    // Droit d'opposition (Paramètres) : désactivé, l'analyse reste hors-ligne.
    if (renamedTracks.isNotEmpty && await AutoEnrichPreference.isEnabled()) {
      final TrackAutoEnricher enricher = ref.read(trackAutoEnricherProvider);
      state = state.copyWith(isEnriching: true, enrichmentProcessed: 0, enrichmentTotal: renamedTracks.length);
      for (int i = 0; i < renamedTracks.length; i++) {
        // Passe unique et stricte (voir TrackAutoEnricher.enrichTrack) :
        // exactement une requête iTunes par morceau, jamais de nouvelle
        // tentative sur le même fichier en cas d'échec/403/non-trouvé — sans
        // quoi un blocage de débit iTunes en tout début de scan gèlerait
        // l'écran d'onboarding le temps des reprises internes (jusqu'à
        // plusieurs minutes chacune, voir MetadataApiClient) au lieu de
        // passer directement au morceau suivant.
        await enricher.enrichTrack(
          trackId: renamedTracks[i].id,
          title: renamedTracks[i].title,
          artists: renamedTracks[i].artists,
          singleAttempt: true,
        );
        state = state.copyWith(enrichmentProcessed: i + 1);
      }
    }

    await ref.read(onboardingStorageProvider).markCompleted();
  }
}

final NotifierProvider<OnboardingScanController, OnboardingScanState> onboardingScanControllerProvider =
    NotifierProvider<OnboardingScanController, OnboardingScanState>(OnboardingScanController.new);
