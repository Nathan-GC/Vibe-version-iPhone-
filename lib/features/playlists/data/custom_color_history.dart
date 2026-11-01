import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Nuancier fixe de l'éditeur de Vibe personnalisée (partagé par le nuancier
/// du dégradé et celui de l'accent) ; le code hexadécimal couvre le reste.
const List<Color> kVibeSwatches = [
  Color(0xFFFF3D68), // rose
  Color(0xFFFF8A00), // orange
  Color(0xFFFFE14D), // jaune
  Color(0xFF6FCF97), // vert
  Color(0xFF00F0FF), // cyan
  Color(0xFF2F80ED), // bleu
  Color(0xFF9B51E0), // violet
  Color(0xFFFFFFFF), // blanc
  Color(0xFF000000), // noir
];

/// Historique local des codes hexadécimaux validés dans l'éditeur : proposés
/// ensuite comme pastilles après le nuancier fixe. Stocké en `AARRGGBB`
/// (comme `bgColors`) sur l'appareil uniquement, sans donnée personnelle.
class CustomColorHistory extends Notifier<List<Color>> {
  static const String _key = 'vibe.custom_color_history';
  static const int maxLength = 8;

  // Un ajout fait avant la fin de la restauration différée prime sur elle.
  bool _changed = false;

  @override
  List<Color> build() {
    Future.microtask(() async {
      final List<String> stored = (await SharedPreferences.getInstance()).getStringList(_key) ?? const [];
      if (_changed) return;
      state = [
        for (final String hex in stored)
          if (int.tryParse(hex, radix: 16) case final int value) Color(value),
      ].take(maxLength).toList();
    });
    return const [];
  }

  /// Ajoute [color] en tête (elle remonte si déjà présente) ; les teintes du
  /// nuancier fixe n'y ont pas leur place.
  Future<void> add(Color color) async {
    if (kVibeSwatches.contains(color)) return;
    _changed = true;
    state = [color, ...state.where((c) => c != color)].take(maxLength).toList();
    await (await SharedPreferences.getInstance()).setStringList(
      _key,
      [for (final Color c in state) c.toARGB32().toRadixString(16).toUpperCase().padLeft(8, '0')],
    );
  }
}

final NotifierProvider<CustomColorHistory, List<Color>> customColorHistoryProvider =
    NotifierProvider<CustomColorHistory, List<Color>>(CustomColorHistory.new);
