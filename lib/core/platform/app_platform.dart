import 'package:flutter/foundation.dart';

/// Point unique de détection de plateforme pour les adaptations iOS (voir
/// docs/PARTIES.md) : chaque partie de l'app qui diverge entre Android et
/// iOS passe par ici plutôt que par des tests `dart:io` dispersés.
///
/// Basé sur [defaultTargetPlatform] plutôt que sur `Platform.isIOS` :
///  - sous `flutter test`, il vaut [TargetPlatform.android] quel que soit le
///    poste de développement — les tests existants continuent donc
///    d'exercer exactement le chemin Android, inchangé ;
///  - un test peut simuler iOS via `debugDefaultTargetPlatformOverride`.
///
/// Convention de toutes les branches : `if (AppPlatform.isIOS) { ...iOS... }`
/// puis le code Android d'origine, jamais l'inverse — le comportement
/// Android reste strictement celui de Vibe (Android).
abstract final class AppPlatform {
  static bool get isIOS => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  static bool get isAndroid => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
}
