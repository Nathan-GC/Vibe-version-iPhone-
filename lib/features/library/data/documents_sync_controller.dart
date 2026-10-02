import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/platform/app_platform.dart';
import '../../../core/storage/database/track_auto_enricher.dart';
import '../../../core/storage/database/track_repository.dart';
import '../../../core/storage/scanner/documents_library_sync.dart';
import '../../../core/storage/scanner/full_device_scan_service.dart';
import '../../../core/storage/scanner/scanned_track.dart';
import '../../settings/data/auto_enrich_preference.dart';
import 'library_providers.dart';

/// État de la synchronisation du dossier Documents (iOS), affiché dans la
/// Bibliothèque pendant qu'elle tourne.
class DocumentsSyncState {
  const DocumentsSyncState({this.isRunning = false, this.processed = 0, this.total = 0, this.lastResult});

  final bool isRunning;
  final int processed;
  final int total;
  final DocumentsSyncResult? lastResult;
}

final Provider<DocumentsLibrarySync> documentsLibrarySyncProvider = Provider<DocumentsLibrarySync>((ref) {
  final TrackAutoEnricher enricher = ref.watch(trackAutoEnricherProvider);
  return DocumentsLibrarySync(
    scanService: FullDeviceScanService(scanService: ref.watch(libraryScanServiceProvider)),
    repository: ref.watch(trackRepositoryProvider),
    enrichRenamedTrack: (track) => enrichSyncedTrack(enricher, track),
  );
});

/// Phase 2 de [DocumentsLibrarySync] pour un morceau renommé : passe unique
/// iTunes puis MusicBrainz — même règle que le premier scan (voir
/// OnboardingScanController.start et TrackAutoEnricher.enrichTrack). Droit
/// d'opposition (Paramètres) : désactivé, la synchronisation reste hors-ligne.
Future<bool> enrichSyncedTrack(TrackAutoEnricher enricher, ScannedTrack track) async =>
    await AutoEnrichPreference.isEnabled() &&
    await enricher.enrichTrack(trackId: track.id, title: track.title, artists: track.artists, singleAttempt: true);

/// Déclencheurs de [DocumentsLibrarySync] (iOS uniquement) : lancement de
/// l'app et retour au premier plan (automatiques, espacés d'au moins
/// [automaticInterval]), bouton de la Bibliothèque (manuel, immédiat). Une
/// seule synchronisation à la fois — un déclenchement pendant qu'une autre
/// tourne est ignoré.
class DocumentsSyncController extends Notifier<DocumentsSyncState> {
  static const Duration automaticInterval = Duration(seconds: 30);
  static const String _automaticSyncKey = 'library.documents_auto_sync';

  /// Refus de l'import à l'onboarding (étape 4) : plus aucun déclenchement
  /// automatique, seul le bouton de la Bibliothèque synchronise.
  static Future<void> disableAutomaticSync() async =>
      (await SharedPreferences.getInstance()).setBool(_automaticSyncKey, false);

  DateTime? _lastAutomaticRun;

  @override
  DocumentsSyncState build() => const DocumentsSyncState();

  /// `null` si rien n'a été lancé (plateforme non iOS, synchronisation déjà
  /// en cours, déclenchement automatique désactivé ou trop rapproché).
  Future<DocumentsSyncResult?> sync({bool automatic = false}) async {
    // Lu avant les gardes ci-dessous : plus aucun `await` entre elles et le
    // passage à `isRunning`, sans quoi deux synchronisations pourraient partir.
    if (automatic && !((await SharedPreferences.getInstance()).getBool(_automaticSyncKey) ?? true)) return null;
    if (!AppPlatform.isIOS || state.isRunning) return null;
    final DateTime now = DateTime.now();
    if (automatic) {
      final DateTime? last = _lastAutomaticRun;
      if (last != null && now.difference(last) < automaticInterval) return null;
      _lastAutomaticRun = now;
    }

    state = const DocumentsSyncState(isRunning: true);
    DocumentsSyncResult? result;
    try {
      result = await ref.read(documentsLibrarySyncProvider).run(
        onProgress: (progress) {
          if (!ref.mounted) return;
          state = DocumentsSyncState(isRunning: true, processed: progress.processed, total: progress.total);
        },
      );
    } catch (_) {
      // Dossier illisible, fichier corrompu en cours de scan... : la
      // synchronisation suivante réessaiera, sans jamais bloquer l'app.
    }
    if (ref.mounted) state = DocumentsSyncState(lastResult: result);
    return result;
  }
}

final NotifierProvider<DocumentsSyncController, DocumentsSyncState> documentsSyncControllerProvider =
    NotifierProvider<DocumentsSyncController, DocumentsSyncState>(DocumentsSyncController.new);
