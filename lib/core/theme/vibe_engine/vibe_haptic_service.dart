import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'active_vibe_provider.dart';
import 'vibe_engine.dart';

/// Points d'interaction déclenchant un retour haptique (Vibe Engine —
/// feedback synesthésique). Un seul point d'entrée pour tous plutôt qu'un
/// appel `HapticFeedback` direct à chaque site : le style dépend de la Vibe
/// active, pas de l'interaction elle-même.
enum VibeInteraction { like, trackChange, seek, vibeSelect }

/// `VibeHapticService.trigger(context, interaction)` lit la Vibe active via
/// Riverpod (le `BuildContext` suffit, pas besoin de `WidgetRef` au site
/// d'appel) et joue le retour haptique associé à son style.
class VibeHapticService {
  const VibeHapticService._();

  static void trigger(BuildContext context, VibeInteraction interaction) {
    final VibePreset? preset = ProviderScope.containerOf(context, listen: false).read(activeVibeProvider).preset;
    _play(preset, interaction);
  }

  /// Pour le Vibe Customizer : joue le retour du preset qu'on est en train de
  /// choisir plutôt que celui de la Vibe active — plus cohérent quand
  /// l'utilisateur explore les presets un par un.
  static void triggerForPreset(VibePreset preset, VibeInteraction interaction) => _play(preset, interaction);

  static void _play(VibePreset? preset, VibeInteraction interaction) {
    switch (preset) {
      case VibePreset.retro:
      case VibePreset.oled:
        // Hard Rock / intensité — mappé sur les presets les plus "lourds"
        // visuellement (voir la palette braises/sombre de vibe_engine.dart).
        HapticFeedback.heavyImpact();
      case VibePreset.neon:
        // Cyberpunk/Synthwave : double-tap sec.
        HapticFeedback.mediumImpact();
        Future.delayed(const Duration(milliseconds: 90), HapticFeedback.mediumImpact);
      case VibePreset.organic:
        // Nature/Rétro : micro-déclic léger.
        HapticFeedback.selectionClick();
      case VibePreset.minimal:
      case VibePreset.glassmorphism:
      case VibePreset.custom:
      case VibePreset.newOled:
      case null:
        // Presets non couverts explicitement par le cahier des charges —
        // repli neutre plutôt que de ne rien jouer du tout.
        HapticFeedback.lightImpact();
    }
  }
}
