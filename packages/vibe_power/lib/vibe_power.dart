import 'dart:io' show Platform;

import 'package:flutter/services.dart';

/// Pont natif minimal (Android + iOS) du mode Focus de Vibe Player.
///
/// Plugin local plutôt que `wakelock_plus`/`battery_plus` : ceux-ci
/// imposaient un téléchargement Maven (AGP 8.12.1) impossible sur le poste
/// de build, et le code natif ne peut pas vivre dans `android/` (gitignoré).
///
/// Implémentations natives : `android/` (Java, VibePowerPlugin.java) et
/// `ios/` (Swift, VibePowerPlugin.swift) — mêmes canaux, mêmes méthodes.
/// Les appels système sont conditionnés par plateforme ([Platform.isAndroid]
/// / [Platform.isIOS]) : ailleurs (tests sur le poste de développement,
/// desktop), chaque méthode est un no-op plutôt qu'une
/// `MissingPluginException`.
class VibePower {
  const VibePower._();

  static const MethodChannel _methods = MethodChannel('vibe_power/methods');
  static const EventChannel _powerSaveEvents = EventChannel('vibe_power/power_save');

  static bool get _hasNativeImplementation => Platform.isAndroid || Platform.isIOS;

  /// Android : pose ou retire `WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON`
  /// sur la fenêtre de l'activité (réappliqué automatiquement si l'activité
  /// est recréée).
  /// iOS : `UIApplication.shared.isIdleTimerDisabled` (réappliqué à chaque
  /// retour au premier plan).
  static Future<void> setKeepScreenOn(bool enabled) async {
    if (!_hasNativeImplementation) return;
    await _methods.invokeMethod<void>('setKeepScreenOn', enabled);
  }

  /// Android : `PowerManager.isPowerSaveMode()`.
  /// iOS : `ProcessInfo.processInfo.isLowPowerModeEnabled`.
  static Future<bool> isPowerSaveMode() async {
    if (!_hasNativeImplementation) return false;
    return await _methods.invokeMethod<bool>('isPowerSaveMode') ?? false;
  }

  /// Émet le nouvel état à chaque bascule du mode économie d'énergie, tant
  /// qu'il y a un abonné — Android : `ACTION_POWER_SAVE_MODE_CHANGED` ;
  /// iOS : `NSProcessInfoPowerStateDidChange`.
  static Stream<bool> get powerSaveModeChanges {
    if (!_hasNativeImplementation) return const Stream<bool>.empty();
    return _powerSaveEvents.receiveBroadcastStream().map((event) => event == true);
  }
}
