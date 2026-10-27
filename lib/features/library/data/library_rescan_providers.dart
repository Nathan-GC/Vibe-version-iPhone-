import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/cover_art/remote_cover_auto_trigger.dart';
import '../../../core/storage/cover_art/remote_cover_localizer.dart' show remoteCoverLocalizerProvider;
import '../../../core/storage/database/track_repository.dart';
import '../../settings/data/auto_enrich_preference.dart';
import 'library_providers.dart';
import 'library_rescan_service.dart';

/// Progression du nouveau scan de la bibliothèque (`null` hors passe), lue par
/// la bannière de la Bibliothèque ([LibraryRescanBanner]).
class LibraryRescanProgressNotifier extends Notifier<RescanProgress?> {
  @override
  RescanProgress? build() => null;

  void set(RescanProgress? progress) => state = progress;
}

final NotifierProvider<LibraryRescanProgressNotifier, RescanProgress?> libraryRescanProgressProvider =
    NotifierProvider<LibraryRescanProgressNotifier, RescanProgress?>(LibraryRescanProgressNotifier.new);

/// Délai entre le passage de l'interrupteur sur ON et la reprise du nouveau scan :
/// le réglage est enregistré juste APRÈS le changement d'état (même anti-rebond
/// que [RemoteCoverAutoTrigger]).
const Duration kRescanSwitchDebounce = Duration(seconds: 3);

/// Créé après l'onboarding seulement (voir PlaylistApp) : tant qu'il n'est pas
/// lu, aucun interrupteur n'est écouté et aucune connexion ne peut partir. La
/// garde RGPD elle-même (onboarding fini ET interrupteur ON) est relue par le
/// service avant chaque titre. Quand l'interrupteur repasse sur ON, le nouveau
/// scan est repris s'il est encore en attente.
final Provider<LibraryRescanService> libraryRescanServiceProvider = Provider<LibraryRescanService>((ref) {
  final LibraryRescanService service = LibraryRescanService(
    repository: ref.watch(trackRepositoryProvider),
    scanService: ref.watch(libraryScanServiceProvider),
    enricher: ref.watch(trackAutoEnricherProvider),
    onProgress: (progress) => ref.read(libraryRescanProgressProvider.notifier).set(progress),
    // Pochette http(s) rapatriée juste après le traitement de chaque titre (la
    // garde RGPD du titre vient d'être vérifiée) : le localiseur AUTOMATIQUE, lui,
    // attend la fin du scan. `read` à l'appel, pas `watch` : le service est un
    // singleton de session, il ne doit pas être reconstruit en pleine passe.
    localizeCover: (trackId) => ref.read(remoteCoverLocalizerProvider).localizeTrack(trackId),
    // Pochettes trouvées pendant la passe : rapatriées une fois pour toutes à
    // la fin (la garde du localiseur les retenait tant que le scan était en attente).
    onFinished: () => ref.read(remoteCoverAutoTriggerProvider).runPass(),
  );

  Timer? timer;
  ref.listen<bool>(autoEnrichOnImportProvider, (bool? previous, bool next) {
    if (!next || previous != false) return;
    timer?.cancel();
    timer = Timer(kRescanSwitchDebounce, () => unawaited(service.runIfPending()));
  });
  ref.onDispose(() => timer?.cancel());
  return service;
});
