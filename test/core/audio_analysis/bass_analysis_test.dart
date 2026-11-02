import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/audio_analysis/bass_analysis.dart';

void main() {
  group('parseRmsLevelsDb', () {
    test('extracts every level in order from ametadata print output', () {
      const String output = 'frame:0    pts:0       pts_time:0\n'
          'lavfi.astats.Overall.RMS_level=-23.456\n'
          'frame:1    pts:80      pts_time:0.01\n'
          'lavfi.astats.Overall.RMS_level=-30.000000\n'
          'frame:2    pts:160     pts_time:0.02\n'
          'lavfi.astats.Overall.RMS_level=-6.5\n';
      expect(parseRmsLevelsDb(output), [-23.456, -30.0, -6.5]);
    });

    test('turns -inf, nan and unreadable values into the -120 dB silence floor', () {
      const String output = 'frame:0 pts:0 pts_time:0\n'
          'lavfi.astats.Overall.RMS_level=-inf\n'
          'frame:1 pts:80 pts_time:0.01\n'
          'lavfi.astats.Overall.RMS_level=nan\n'
          'frame:2 pts:160 pts_time:0.02\n'
          'lavfi.astats.Overall.RMS_level=oops\n'
          'frame:3 pts:240 pts_time:0.03\n'
          'lavfi.astats.Overall.RMS_level=-12.0\n';
      expect(parseRmsLevelsDb(output), [-120.0, -120.0, -120.0, -12.0]);
    });

    test('returns an empty list when there is nothing to read', () {
      expect(parseRmsLevelsDb(''), isEmpty);
      expect(parseRmsLevelsDb('frame:0 pts:0 pts_time:0\n'), isEmpty);
    });
  });

  group('bassEnvelopeFromDb', () {
    test('groups four 10 ms windows into one 40 ms step, keeping the maximum', () {
      // 10 pas de 10 ms -> ceil(10 / 4) = 3 octets (le dernier groupe est partiel).
      final Uint8List envelope = bassEnvelopeFromDb(List<double>.filled(10, -20));
      expect(envelope.length, 3);
    });

    test('normalizes by the 95th percentile, clamped to 255', () {
      // 100 pas à -20 dB et 1 pas à 0 dB : le pic isolé dépasse le p95 (borné à 255),
      // le reste vaut 255 aussi puisqu'il EST le p95.
      final List<double> levels = List<double>.filled(400, -20)..[0] = 0;
      final Uint8List envelope = bassEnvelopeFromDb(levels);
      expect(envelope.length, 100);
      expect(envelope[0], 255);
      expect(envelope[50], 255);
    });

    test('keeps the dynamics: a quieter step maps proportionally below the loudest', () {
      // Moitié des pas à -6 dB, moitié à -12 dB (amplitude ~ x0.5) : p95 = niveau fort.
      final List<double> levels = [
        ...List<double>.filled(200, -6),
        ...List<double>.filled(200, -12),
      ];
      final Uint8List envelope = bassEnvelopeFromDb(levels);
      expect(envelope.first, 255);
      expect(envelope.last, closeTo(255 * math.pow(10, -6 / 20), 2));
    });

    test('a silent track gives zeros, without dividing by zero', () {
      final Uint8List envelope = bassEnvelopeFromDb(List<double>.filled(400, -120));
      expect(envelope.length, 100);
      expect(envelope.every((int v) => v == 0), isTrue);
    });

    test('an empty input gives an empty envelope', () {
      expect(bassEnvelopeFromDb(const []), isEmpty);
    });
  });

  group('estimateBpm', () {
    /// Train d'impulsions d'énergie à [bpm] sur [seconds] s, échantillonné à 100 Hz
    /// (une fenêtre RMS de 10 ms), avec un bruit de fond léger reproductible.
    List<double> pulseTrain(double bpm, {double seconds = 30, int seed = 7}) {
      final math.Random random = math.Random(seed);
      final int n = (seconds * 100).round();
      final List<double> levels = List<double>.generate(n, (_) => -50 + random.nextDouble() * 4);
      final double period = 6000 / bpm;
      for (double t = 0; t < n; t += period) {
        final int i = t.round();
        if (i < n) levels[i] = -10;
        if (i + 1 < n) levels[i + 1] = -16;
        if (i + 2 < n) levels[i + 2] = -24;
      }
      return levels;
    }

    for (final double bpm in [90, 120, 128, 140]) {
      test('finds $bpm BPM on a pulse train within 2 BPM', () {
        final int? estimate = estimateBpm(pulseTrain(bpm));
        expect(estimate, isNotNull);
        expect(estimate!.toDouble(), closeTo(bpm, 2));
      });
    }

    test('folds a slow pulse into the 70-160 range', () {
      // 60 BPM -> 120 (octave au-dessus), pas 60.
      final int? estimate = estimateBpm(pulseTrain(60));
      expect(estimate, isNotNull);
      expect(estimate!.toDouble(), closeTo(120, 2));
    });

    test('returns null on silence', () {
      expect(estimateBpm(List<double>.filled(3000, -120)), isNull);
    });

    test('returns null on white noise (no clear pulse)', () {
      // Plusieurs graines : le seuil ne doit pas tenir à un tirage chanceux.
      for (int seed = 1; seed <= 10; seed++) {
        final math.Random random = math.Random(seed);
        final List<double> noise = List<double>.generate(3000, (_) => -40 + random.nextDouble() * 20);
        expect(estimateBpm(noise), isNull, reason: 'seed $seed');
      }
    });

    test('returns null when the track is shorter than 10 seconds', () {
      expect(estimateBpm(pulseTrain(120, seconds: 9)), isNull);
    });

    test('returns null on an empty input', () {
      expect(estimateBpm(const []), isNull);
    });
  });

  group('effectiveBpm', () {
    test('keeps a real tag that is not the 120 default', () {
      expect(effectiveBpm(95, 128), 95);
    });

    test('replaces the 120 default by the estimate', () {
      expect(effectiveBpm(120, 128), 128);
    });

    test('falls back to the tag when there is no usable estimate', () {
      expect(effectiveBpm(120, null), 120);
      expect(effectiveBpm(120, 0), 120);
    });
  });
}
