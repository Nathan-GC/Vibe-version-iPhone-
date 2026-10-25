import 'package:flutter/material.dart';

import '../../storage/database/app_database.dart';
import 'vibe_engine.dart';

/// Résout le rendu effectif de la Vibe d'une playlist : presets figés pour les
/// valeurs de [VibePreset] autres que `custom`, sinon couleurs/image propres à
/// la playlist (Vibe Creator). Fichier séparé de vibe_engine.dart pour éviter
/// un import circulaire avec app_database.dart (qui dépend déjà de VibePreset
/// pour la colonne `vibe_style`).
/// Sentinelle "Aucune couleur" stockée seule dans `playlists.bg_colors`
/// (`00000000`) : fond transparent, sans changement de schéma.
const Color kNoVibeColor = Color(0x00000000);

extension PlaylistVibeResolver on Playlist {
  /// `playlists.show_cover_image` s'applique désormais à TOUTES les Vibes :
  /// le bouton "Afficher la pochette" est proposé sur chaque preset (voir
  /// VibeCustomizerScreen), l'utilisateur peut donc toujours la réafficher
  /// depuis la Vibe active — le repli "toujours visible" des presets sans
  /// bouton (retest QA 61b5cf1) n'a plus lieu d'être.
  VibeVisual get resolvedVibe {
    if (vibeStyle != VibePreset.custom) {
      return VibeVisual(
        gradientColors: vibeStyle.gradientColors,
        accentColor: vibeStyle.accentColor,
        preset: vibeStyle,
        showCoverImage: showCoverImage,
      );
    }

    final List<Color> customColors = bgColors.map(_colorFromHex).whereType<Color>().toList();
    final Color? explicitAccent = customAccentColor.isEmpty ? null : _colorFromHex(customAccentColor);
    // "Aucune couleur" : seules des couleurs entièrement transparentes (le
    // sentinelle `00000000`). Une liste vide garde son sens historique
    // ("preset par défaut") pour les playlists existantes.
    final bool noColor = customColors.isNotEmpty && customColors.every((color) => color.a == 0);
    final List<Color> solidColors = customColors.where((color) => color.a > 0).toList();
    return VibeVisual(
      // Une seule couleur choisie : aplat de cette couleur, comme l'aperçu du
      // Vibe Creator (auparavant le dégradé du preset la remplaçait).
      gradientColors: noColor
          ? const [kNoVibeColor, kNoVibeColor]
          : switch (customColors.length) {
              0 => VibePreset.custom.gradientColors,
              1 => [customColors.single, customColors.single],
              _ => customColors,
            },
      // Repli pour les Vibes personnalisées créées avant l'ajout du choix
      // explicite d'accent : la dernière couleur du dégradé restait alors la
      // meilleure approximation disponible. Jamais une couleur transparente
      // (accent invisible) : preset par défaut sans couleur opaque.
      accentColor: explicitAccent ?? (solidColors.isEmpty ? VibePreset.custom.accentColor : solidColors.last),
      backgroundImagePath: customBackgroundImagePath.isEmpty ? null : customBackgroundImagePath,
      preset: VibePreset.custom,
      effect: customEffect,
      customBackgroundVideoPath: customBackgroundVideoPath.isEmpty ? null : customBackgroundVideoPath,
      showCoverImage: showCoverImage,
    );
  }
}

Color? _colorFromHex(String hex) {
  final int? value = int.tryParse(hex, radix: 16);
  return value == null ? null : Color(value);
}

/// Inverse de [_colorFromHex] : format "AARRGGBB" stocké dans `playlists.bg_colors`.
String colorToHex(Color color) => color.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase();
