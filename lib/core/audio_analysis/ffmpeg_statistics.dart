import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit_config.dart';
import 'package:flutter/foundation.dart';

Future<void>? _statisticsDisabled;

/// Coupe les statistiques FFmpeg pour tout le processus (appel natif unique).
///
/// Le plugin envoie une statistique par trame au thread Dart de l'UI (~37 000
/// événements pour un titre de 6 min) : l'analyse des basses durait 52-110 s et
/// l'animation tombait à ~7 images/s. L'app ne lit les statistiques nulle part.
///
/// NE JAMAIS utiliser `FFmpegKitConfig.disableRedirection()` à la place : il
/// casserait `FFprobeKit.getMediaInformation` (metadata_extractor) et les logs
/// de session lus par silence_trimmer. Ne jamais rappeler `enableRedirection()`
/// non plus : cela réactiverait les statistiques.
///
/// Les erreurs sont avalées (plateforme sans plugin, tests) : l'analyse doit
/// continuer même si l'appel échoue.
Future<void> ensureFfmpegStatisticsDisabled() => _statisticsDisabled ??= _disable();

Future<void> _disable() async {
  try {
    await FFmpegKitConfig.disableStatistics();
  } catch (_) {
    // Simple optimisation : sans elle, l'analyse reste correcte, juste plus lente.
  }
}

/// Réinitialise la mémoïsation pour isoler les tests.
@visibleForTesting
void resetFfmpegStatisticsForTest() => _statisticsDisabled = null;
