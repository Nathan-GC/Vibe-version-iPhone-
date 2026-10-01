import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vibe_power/vibe_power.dart';

import '../audio_engine/player_immersive_mode_provider.dart';

/// Accès plateforme du maintien d'écran allumé — isolé derrière une
/// interface pour que [FocusKeepScreenOnController] soit testable sans
/// plugin natif.
abstract class KeepScreenOnPlatform {
  /// Pose (`true`) ou retire (`false`) le maintien de l'écran allumé —
  /// Android : drapeau `FLAG_KEEP_SCREEN_ON` ; iOS : `isIdleTimerDisabled`.
  Future<void> setKeepScreenOn(bool enabled);

  /// Mode économie d'énergie — Android : `PowerManager.isPowerSaveMode` ;
  /// iOS : mode Économie d'énergie (`isLowPowerModeEnabled`).
  Future<bool> isPowerSaveMode();

  /// Bascules du mode économie d'énergie, poussées par le système.
  Stream<bool> get powerSaveModeChanges;
}

/// Plugin local `packages/vibe_power` (code natif versionné dans le dépôt).
class PluginKeepScreenOnPlatform implements KeepScreenOnPlatform {
  @override
  Future<void> setKeepScreenOn(bool enabled) => VibePower.setKeepScreenOn(enabled);

  @override
  Future<bool> isPowerSaveMode() => VibePower.isPowerSaveMode();

  @override
  Stream<bool> get powerSaveModeChanges => VibePower.powerSaveModeChanges;
}

final Provider<KeepScreenOnPlatform> keepScreenOnPlatformProvider =
    Provider<KeepScreenOnPlatform>((ref) => PluginKeepScreenOnPlatform());

/// Maintien de l'écran allumé pendant l'écoute en mode Focus (retour
/// d'usage v1.0.x : l'écran se mettait en veille en plein Focus).
///
/// Règle STRICTE : écran maintenu allumé uniquement si le mode Focus est
/// actif ET que l'appareil n'est pas en économie d'énergie. Retiré dès que
/// le Focus prend fin, ou dès que l'économie d'énergie s'active (le système
/// notifie la bascule, écoutée uniquement pendant le Focus).
///
/// Aucun appel plateforme au démarrage : l'écran n'est jamais maintenu par
/// défaut, le premier appel n'a lieu qu'à l'entrée en Focus.
class FocusKeepScreenOnController {
  FocusKeepScreenOnController(this._platform);

  final KeepScreenOnPlatform _platform;

  bool _focusActive = false;
  bool _keepingScreenOn = false;
  StreamSubscription<bool>? _powerSaveSubscription;
  bool _disposed = false;

  /// Dernier état effectivement appliqué à la plateforme.
  bool get isKeepingScreenOn => _keepingScreenOn;

  Future<void> setFocusActive(bool active) async {
    if (_disposed) return;
    _focusActive = active;
    if (active) {
      _powerSaveSubscription ??= _platform.powerSaveModeChanges.listen(
        (_) => reevaluate(),
        // Canal indisponible (tests, plateforme non supportée) : l'état est
        // tout de même relu à chaque entrée en Focus.
        onError: (Object _) {},
      );
    } else {
      await _powerSaveSubscription?.cancel();
      _powerSaveSubscription = null;
    }
    await reevaluate();
  }

  /// Recalcule l'état voulu et ne parle à la plateforme que s'il change.
  @visibleForTesting
  Future<void> reevaluate() async {
    bool shouldKeepOn = _focusActive;
    if (shouldKeepOn) {
      try {
        shouldKeepOn = !await _platform.isPowerSaveMode();
      } catch (_) {
        // Information indisponible : on privilégie la demande explicite de
        // l'utilisateur (le Focus), sans jamais planter l'écoute.
      }
    }
    // Le Focus a pu se terminer pendant l'appel asynchrone ci-dessus.
    if (!_focusActive || _disposed) shouldKeepOn = false;
    if (shouldKeepOn == _keepingScreenOn) return;
    _keepingScreenOn = shouldKeepOn;
    try {
      await _platform.setKeepScreenOn(shouldKeepOn);
    } catch (_) {
      // Plugin absent (tests, plateforme non supportée) : sans effet.
    }
  }

  void dispose() {
    _disposed = true;
    _powerSaveSubscription?.cancel();
    _powerSaveSubscription = null;
    if (_keepingScreenOn) {
      _keepingScreenOn = false;
      _platform.setKeepScreenOn(false).catchError((Object _) {});
    }
  }
}

/// Branché sur [playerImmersiveModeProvider] : à garder vivant depuis la
/// coque de navigation (`_TabShell`, router.dart), qui le lit à chaque build.
final Provider<FocusKeepScreenOnController> focusKeepScreenOnProvider = Provider<FocusKeepScreenOnController>((ref) {
  final FocusKeepScreenOnController controller = FocusKeepScreenOnController(ref.watch(keepScreenOnPlatformProvider));
  ref.listen<bool>(playerImmersiveModeProvider, (previous, next) => controller.setFocusActive(next));
  ref.onDispose(controller.dispose);
  return controller;
});
