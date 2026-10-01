import 'package:flutter/material.dart';

import '../../storage/database/app_database.dart';
import 'vibe_engine.dart';

/// Résout le rendu effectif de la Vibe d'une playlist : presets figés pour les
/// valeurs de [VibePreset] autres que `custom`, sinon couleurs/image propres à
/// la playlist (Vibe Creator). Fichier séparé de vibe_engine.dart pour éviter
/// un import circulaire avec app_database.dart (qui dépend déjà de VibePreset
/// pour la colonne `vibe_style`).
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
    return VibeVisual(
      gradientColors: customColors.length >= 2 ? customColors : VibePreset.custom.gradientColors,
      // Repli pour les Vibes personnalisées créées avant l'ajout du choix
      // explicite d'accent : la dernière couleur du dégradé restait alors la
      // meilleure approximation disponible.
      accentColor: explicitAccent ?? (customColors.isEmpty ? VibePreset.custom.accentColor : customColors.last),
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
