import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../design_system/vibe_design_system.dart';
import '../vibe_engine/vibe_engine.dart';
import 'theme_preferences_storage.dart';

/// Palette de couleurs principales proposée dans Réglages (carrousel
/// horizontal façon Spotify) — sert de teinte de base (`ColorScheme.fromSeed`)
/// tant qu'aucune Vibe de playlist n'est active pour la reteinter (voir
/// [applyVibe]).
const List<Color> kAccentColorChoices = [
  Color(0xFF1DB954), // vert Spotify — repli par défaut, familier de l'UX visée.
  Color(0xFF9B51E0),
  Color(0xFF2F80ED),
  Color(0xFF00F0FF),
  Color(0xFFFF3D68),
  Color(0xFFFF8A00),
  Color(0xFFFFE14D),
  Color(0xFF6FCF97),
];

/// Layer A : thème global de l'app (dark/light système), indépendant
/// du Vibe Engine par playlist (Layer B, voir vibe_engine.dart). Persisté
/// (voir ThemePreferencesStorage) — restauré de façon asynchrone juste après
/// le premier frame, même pattern que PlayerController._restoreLastSession.
class GlobalThemeMode extends Notifier<ThemeMode> {
  final ThemePreferencesStorage _storage = ThemePreferencesStorage();

  @override
  ThemeMode build() {
    Future.microtask(_restore);
    return ThemeMode.system;
  }

  Future<void> _restore() async {
    final ThemeMode? persisted = await _storage.loadThemeMode();
    if (persisted != null && ref.mounted) state = persisted;
  }

  void setThemeMode(ThemeMode mode) {
    state = mode;
    unawaited(_storage.saveThemeMode(mode));
  }
}

final NotifierProvider<GlobalThemeMode, ThemeMode> globalThemeModeProvider =
    NotifierProvider<GlobalThemeMode, ThemeMode>(GlobalThemeMode.new);

/// Couleur principale choisie par l'utilisateur (Réglages > carrousel de
/// couleurs) — seed de base de [buildLightTheme]/[buildDarkTheme] tant
/// qu'aucune Vibe de playlist n'est active pour la surclasser (voir
/// [applyVibe], toujours appelé par-dessus dans `PlaylistApp.build`).
class UserAccentColor extends Notifier<Color> {
  final ThemePreferencesStorage _storage = ThemePreferencesStorage();

  @override
  Color build() {
    Future.microtask(_restore);
    return kAccentColorChoices.first;
  }

  Future<void> _restore() async {
    final Color? persisted = await _storage.loadAccentColor();
    if (persisted != null && ref.mounted) state = persisted;
  }

  void setAccentColor(Color color) {
    state = color;
    unawaited(_storage.saveAccentColor(color));
  }
}

final NotifierProvider<UserAccentColor, Color> userAccentColorProvider =
    NotifierProvider<UserAccentColor, Color>(UserAccentColor.new);

/// Hiérarchie typographique du Design System — Outfit (Google Fonts),
/// sans-serif moderne et lisible, avec des poids marqués pour distinguer
/// clairement titres/corps/légendes (charte inspirée de Spotify).
TextTheme _buildTextTheme(Brightness brightness) {
  final Color baseColor = brightness == Brightness.dark ? Colors.white : Colors.black87;
  return GoogleFonts.outfitTextTheme().apply(bodyColor: baseColor, displayColor: baseColor).copyWith(
        headlineSmall: GoogleFonts.outfit(fontSize: 24, fontWeight: FontWeight.w700, color: baseColor),
        titleLarge: GoogleFonts.outfit(fontSize: 20, fontWeight: FontWeight.w700, color: baseColor),
        titleMedium: GoogleFonts.outfit(fontSize: 16, fontWeight: FontWeight.w600, color: baseColor),
        bodyLarge: GoogleFonts.outfit(fontSize: 15, fontWeight: FontWeight.w400, color: baseColor),
        bodyMedium: GoogleFonts.outfit(fontSize: 13, fontWeight: FontWeight.w400, color: baseColor),
        bodySmall: GoogleFonts.outfit(
          fontSize: 12,
          fontWeight: FontWeight.w400,
          color: baseColor.withValues(alpha: 0.7),
        ),
        labelLarge: GoogleFonts.outfit(fontSize: 14, fontWeight: FontWeight.w600, color: baseColor),
      );
}

/// Applique les formes du Design System (cartes/modales à [AppRadii.card],
/// boutons d'action principale en "Pill" — voir `vibe_design_system.dart`) à
/// [base], commun aux thèmes clair et sombre.
ThemeData _applyDesignSystemShapes(ThemeData base) {
  return base.copyWith(
    textTheme: _buildTextTheme(base.brightness),
    cardTheme: base.cardTheme.copyWith(
      shape: AppShapes.card,
      clipBehavior: Clip.antiAlias,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
          shape: AppShapes.pill, padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14)),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
          shape: AppShapes.pill, padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14)),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
          shape: AppShapes.pill, padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14)),
    ),
    chipTheme: base.chipTheme.copyWith(shape: AppShapes.pill),
    bottomSheetTheme: base.bottomSheetTheme.copyWith(shape: AppShapes.modalTop),
    dialogTheme: base.dialogTheme.copyWith(shape: AppShapes.card),
  );
}

ThemeData buildLightTheme({Color seedColor = const Color(0xFF1DB954)}) {
  final ThemeData base = ThemeData(
    brightness: Brightness.light,
    useMaterial3: true,
    colorSchemeSeed: seedColor,
  );
  return _applyDesignSystemShapes(base);
}

/// Fond `#121212` façon Spotify (voir `kSpotifyDarkBackground`) plutôt que le
/// gris Material 3 par défaut — [applyVibe] blend ensuite l'accent de la Vibe
/// active par-dessus, exactement comme pour le thème clair.
ThemeData buildDarkTheme({Color seedColor = const Color(0xFF1DB954)}) {
  final ThemeData base = ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    colorSchemeSeed: seedColor,
    scaffoldBackgroundColor: kSpotifyDarkBackground,
  );
  return _applyDesignSystemShapes(base).copyWith(
    colorScheme: base.colorScheme.copyWith(surface: kSpotifyDarkBackground),
  );
}

/// Reteinte [base] avec la Vibe active (voir active_vibe_provider.dart) :
/// `ColorScheme.fromSeed` dérive une palette harmonieuse et suffisamment
/// contrastée à partir de l'accent choisi, qui irrigue automatiquement AppBar,
/// Card, NavigationBar, boutons... (comportement par défaut de Material 3,
/// aucune sous-config à dupliquer). Le fond reçoit en plus une légère teinte
/// de la même couleur pour que l'ensemble de l'app — pas seulement le Player —
/// se ressente comme habillé par la Vibe active.
ThemeData applyVibe(ThemeData base, VibeVisual vibe) {
  final ColorScheme scheme = ColorScheme.fromSeed(seedColor: vibe.accentColor, brightness: base.brightness);
  return base.copyWith(
    colorScheme: scheme,
    scaffoldBackgroundColor: Color.alphaBlend(vibe.accentColor.withValues(alpha: 0.05), scheme.surface),
  );
}
