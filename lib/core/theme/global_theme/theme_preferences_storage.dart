import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persiste les préférences de thème global choisies dans Réglages (mode
/// clair/sombre/système, couleur principale) — même pattern que
/// `OnboardingStorage`/`PlayerStateStorage` : un simple wrapper
/// `SharedPreferences`, restauré de façon asynchrone après le premier frame
/// (voir `GlobalThemeMode.build`/`UserAccentColor.build`) plutôt que de
/// bloquer le lancement de l'app sur cette lecture.
class ThemePreferencesStorage {
  static const String _keyThemeMode = 'theme.mode';
  static const String _keyAccentColor = 'theme.accent_color_argb';

  Future<ThemeMode?> loadThemeMode() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? stored = prefs.getString(_keyThemeMode);
    return switch (stored) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      'system' => ThemeMode.system,
      _ => null,
    };
  }

  Future<void> saveThemeMode(ThemeMode mode) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyThemeMode, mode.name);
  }

  Future<Color?> loadAccentColor() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final int? argb = prefs.getInt(_keyAccentColor);
    return argb == null ? null : Color(argb);
  }

  Future<void> saveAccentColor(Color color) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyAccentColor, color.toARGB32());
  }
}
