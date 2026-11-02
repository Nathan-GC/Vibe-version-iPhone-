import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:flutter/painting.dart' show HSVColor;
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/theme/vibe_engine/window_color_zones.dart';

// Images de synthèse 64×64 : c'est la taille réelle passée à l'analyse en
// production (image réduite avant `compute`), les seuils sont calibrés dessus.
const int _size = 64;

/// Image RGBA unie de la couleur donnée.
Uint8List _filled(Color c, {int w = _size, int h = _size}) {
  final buf = Uint8List(w * h * 4);
  for (var i = 0; i < w * h; i++) {
    buf[i * 4] = (c.r * 255).round();
    buf[i * 4 + 1] = (c.g * 255).round();
    buf[i * 4 + 2] = (c.b * 255).round();
    buf[i * 4 + 3] = 255;
  }
  return buf;
}

/// Peint un disque plein (bord net, sans anti-aliasing : les pixels de bord ne
/// brouillent pas la teinte mesurée). Centre et rayon en pixels.
void _disc(Uint8List buf, double cx, double cy, double r, Color c, {int w = _size}) {
  final h = buf.length ~/ 4 ~/ w;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final dx = x + 0.5 - cx, dy = y + 0.5 - cy;
      if (dx * dx + dy * dy <= r * r) {
        final i = (y * w + x) * 4;
        buf[i] = (c.r * 255).round();
        buf[i + 1] = (c.g * 255).round();
        buf[i + 2] = (c.b * 255).round();
      }
    }
  }
}

double _hueDistance(double a, double b) {
  final d = (a - b).abs() % 360;
  return d > 180 ? 360 - d : d;
}

void main() {
  const night = Color(0xFF080818);
  const magenta = Color(0xFFFF00FF);
  const cyan = Color(0xFF00FFFF);

  test('deux disques néon sur fond nuit donnent deux zones bien placées', () {
    final img = _filled(night);
    _disc(img, 16, 16, 8, magenta); // haut gauche
    _disc(img, 48, 48, 11, cyan); // bas droite, plus grand

    final zones = analyzeWindowColorZones(img, _size, _size);

    expect(zones, hasLength(2));
    final mag = zones.firstWhere((z) => _hueDistance(HSVColor.fromColor(z.color).hue, 300) < 20);
    final cy = zones.firstWhere((z) => _hueDistance(HSVColor.fromColor(z.color).hue, 180) < 20);
    expect(mag.x, closeTo(0.25, 0.08));
    expect(mag.y, closeTo(0.25, 0.08));
    expect(cy.x, closeTo(0.75, 0.08));
    expect(cy.y, closeTo(0.75, 0.08));
    expect(cy.weight, 1.0);
    expect(mag.weight, inInclusiveRange(0.0, 1.0));
    expect(mag.weight, lessThan(1.0));
    expect(mag.color.a, 1.0);
  });

  test('image grise, noire ou dégradé de gris : aucune zone', () {
    expect(analyzeWindowColorZones(_filled(const Color(0xFF808080)), _size, _size), isEmpty);
    expect(analyzeWindowColorZones(_filled(const Color(0xFF000000)), _size, _size), isEmpty);

    final gradient = _filled(night);
    for (var i = 0; i < _size * _size; i++) {
      final v = (i % _size) * 255 ~/ (_size - 1);
      gradient[i * 4] = gradient[i * 4 + 1] = gradient[i * 4 + 2] = v;
    }
    expect(analyzeWindowColorZones(gradient, _size, _size), isEmpty);
  });

  test('huit disques de teintes différentes : plafonné à maxZones', () {
    final img = _filled(night);
    for (var i = 0; i < 8; i++) {
      final color = HSVColor.fromAHSV(1, i * 45.0, 1, 1).toColor();
      _disc(img, 8.0 + (i % 4) * 16, i < 4 ? 16 : 48, 7, color);
    }

    expect(analyzeWindowColorZones(img, _size, _size), hasLength(6));
    expect(analyzeWindowColorZones(img, _size, _size, maxZones: 2), hasLength(2));
    expect(analyzeWindowColorZones(img, _size, _size, maxZones: 0), isEmpty);
  });

  test('le même disque en deux tailles : la grande zone a le plus grand rayon', () {
    const orange = Color(0xFFFF8000);
    final small = _filled(night);
    _disc(small, 32, 32, 6, orange);
    final big = _filled(night);
    _disc(big, 32, 32, 12, orange);

    final zSmall = analyzeWindowColorZones(small, _size, _size);
    final zBig = analyzeWindowColorZones(big, _size, _size);

    expect(zSmall, hasLength(1));
    expect(zBig, hasLength(1));
    expect(zBig.single.radius, greaterThan(zSmall.single.radius));
  });

  test('déterministe : même entrée, même résultat', () {
    final img = _filled(night);
    _disc(img, 20, 20, 9, magenta);
    _disc(img, 44, 40, 7, cyan);

    final a = analyzeWindowColorZones(img, _size, _size);
    final b = analyzeWindowColorZones(img, _size, _size);

    expect(a.length, b.length);
    for (var i = 0; i < a.length; i++) {
      expect(a[i].x, b[i].x);
      expect(a[i].y, b[i].y);
      expect(a[i].radius, b[i].radius);
      expect(a[i].color, b[i].color);
      expect(a[i].weight, b[i].weight);
    }
  });

  test('entrées dégénérées : liste vide, jamais d\'exception', () {
    expect(analyzeWindowColorZones(Uint8List(10), _size, _size), isEmpty);
    expect(analyzeWindowColorZones(Uint8List(0), 0, 0), isEmpty);
    expect(analyzeWindowColorZones(Uint8List(16), -2, -2), isEmpty);
  });

  test('mesure indicative du temps pour 4 096 pixels', () {
    final img = _filled(night);
    _disc(img, 16, 16, 8, magenta);
    _disc(img, 48, 48, 11, cyan);
    final sw = Stopwatch()..start();
    for (var i = 0; i < 100; i++) {
      analyzeWindowColorZones(img, _size, _size);
    }
    sw.stop();
    // ignore: avoid_print
    print('analyzeWindowColorZones : ${sw.elapsedMicroseconds / 100} µs / appel');
  });
}
