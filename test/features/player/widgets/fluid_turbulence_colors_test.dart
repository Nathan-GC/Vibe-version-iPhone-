import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/features/player/widgets/fluid_background.dart';

void main() {
  const Color red = Color(0xFFE53935);
  const Color blue = Color(0xFF1E88E5);

  void expectDarkerShadeOf(Color derived, Color base) {
    expect(derived, isNot(base));
    expect(derived.computeLuminance(), lessThan(base.computeLuminance() * 0.5));
    // Même teinte : seule la luminosité baisse.
    expect(HSLColor.fromColor(derived).hue, closeTo(HSLColor.fromColor(base).hue, 1.0));
    expect(derived.a, base.a);
  }

  test('two distinct colors are used as-is, extra colors ignored', () {
    expect(fluidTurbulenceColors(const [red, blue]), (red, blue));
    expect(fluidTurbulenceColors(const [red, blue, blue]), (red, blue));
  });

  test('a single color is paired with a clearly darker shade of itself', () {
    final (Color a, Color b) = fluidTurbulenceColors(const [red]);
    expect(a, red);
    expectDarkerShadeOf(b, red);
  });

  test('identical colors (AnimatedVibeTheme duplication) get a darker second shade', () {
    final (Color a, Color b) = fluidTurbulenceColors(const [blue, blue, blue]);
    expect(a, blue);
    expectDarkerShadeOf(b, blue);
  });
}
