import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/settings/data/auto_enrich_preference.dart';
import '../database/track_repository.dart';
import 'remote_cover_localizer.dart';

/// Déclencheurs automatiques du rapatriement des pochettes en ligne. Il ne
/// décide de rien en matière de RGPD : chaque passe passe par
/// [RemoteCoverLocalizer.localizePending], qui relit avant chaque titre
/// « onboarding terminé ET interrupteur ON ». Ce service se contente de dire
/// QUAND essayer :
///   - au démarrage et à la fin de l'onboarding : appel explicite de [runPass] ;
///   - quand de nouveaux titres à pochette http(s) apparaissent (flux du
///     dépôt, avec anti-rebond : l'enrichissement les écrit un par un) ;
///   - quand l'interrupteur repasse sur ON (même anti-rebond : le réglage
///     est enregistré juste APRÈS le changement d'état).
class RemoteCoverAutoTrigger {
  RemoteCoverAutoTrigger({
    required RemoteCoverLocalizer localizer,
    required TrackRepository repository,
    this.debounce = const Duration(seconds: 3),
  })  : _localizer = localizer,
        _repository = repository;

  final RemoteCoverLocalizer _localizer;
  final TrackRepository _repository;
  final Duration debounce;

  StreamSubscription<int>? _subscription;
  Timer? _timer;
  int? _lastCount;

  /// Passe immédiate (le garde-fou RGPD est dans le localiseur).
  Future<int> runPass() => _localizer.localizePending();

  /// Écoute le dépôt : seule une AUGMENTATION du nombre de pochettes http(s)
  /// déclenche (la première valeur et les baisses dues au rapatriement
  /// lui-même sont ignorées).
  void start() {
    _subscription ??= _repository.watchRemoteCoverCount().listen((int count) {
      final int? previous = _lastCount;
      _lastCount = count;
      if (previous != null && count > previous) schedulePass();
    }, onError: (Object _) {});
  }

  void schedulePass() {
    _timer?.cancel();
    _timer = Timer(debounce, () => unawaited(runPass()));
  }

  void dispose() {
    _timer?.cancel();
    _subscription?.cancel();
    _subscription = null;
  }
}

/// Créé une seule fois, APRÈS l'onboarding (voir PlaylistApp et
/// OnboardingScanController) : tant qu'il n'est pas lu, aucun flux ni
/// interrupteur n'est écouté et aucune connexion ne peut partir.
final Provider<RemoteCoverAutoTrigger> remoteCoverAutoTriggerProvider = Provider<RemoteCoverAutoTrigger>((ref) {
  final RemoteCoverAutoTrigger trigger = RemoteCoverAutoTrigger(
    localizer: ref.watch(remoteCoverLocalizerProvider),
    repository: ref.watch(trackRepositoryProvider),
  )..start();
  ref.listen<bool>(autoEnrichOnImportProvider, (bool? previous, bool next) {
    if (next && previous == false) trigger.schedulePass();
  });
  ref.onDispose(trigger.dispose);
  return trigger;
});
