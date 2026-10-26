import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:playlist_app/core/theme/global_theme/global_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Comme main.dart : aucun téléchargement de police en test.
  GoogleFonts.config.allowRuntimeFetching = false;

  test('every text style carries a font fallback (Outfit has no Greek/Cyrillic)', () {
    for (final Brightness b in Brightness.values) {
      final TextTheme theme = buildTextThemeForTest(b);
      for (final TextStyle? style in [
        theme.titleLarge,
        theme.bodyMedium,
        theme.bodySmall,
        theme.labelLarge,
        theme.headlineSmall
      ]) {
        expect(style?.fontFamilyFallback, contains('Roboto'));
      }
    }
  });
}
