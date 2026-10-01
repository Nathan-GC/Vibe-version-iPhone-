import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/theme/vibe_engine/vibe_engine.dart';

void main() {
  test('ignoresCoverPalette is true for the presets with a fixed identity (Section 3)', () {
    for (final preset in [
      VibePreset.minimal,
      VibePreset.neon,
      VibePreset.retro,
      VibePreset.organic,
      VibePreset.custom,
      VibePreset.newOled,
    ]) {
      expect(preset.ignoresCoverPalette, isTrue, reason: '$preset should ignore the cover palette');
    }
  });

  test('ignoresCoverPalette is false for Space (oled) and Glassmorphism', () {
    expect(VibePreset.oled.ignoresCoverPalette, isFalse, reason: "Space's nebula is built from the cover palette");
    expect(VibePreset.glassmorphism.ignoresCoverPalette, isFalse);
  });

  test('Space (oled) keeps its stored name for backward compatibility despite the "Space" label', () {
    expect(VibePreset.oled.name, 'oled');
    expect(VibePreset.oled.label, 'Space');
  });

  test('newOled has a pure black/white identity and no particle shader', () {
    expect(VibePreset.newOled.gradientColors, [const Color(0xFF000000), const Color(0xFF000000)]);
    expect(VibePreset.newOled.accentColor, const Color(0xFFFFFFFF));
    expect(VibePreset.newOled.particleStyleIndex, isNull);
  });
}
