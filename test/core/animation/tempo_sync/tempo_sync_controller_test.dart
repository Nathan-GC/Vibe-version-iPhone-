import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/animation/tempo_sync/tempo_sync_controller.dart';

void main() {
  group('bassLevelAt', () {
    // 25 Hz : un octet toutes les 40 ms.
    final Uint8List envelope = Uint8List.fromList([0, 255, 0, 51]);

    test('reads a step exactly on its timestamp', () {
      expect(bassLevelAt(envelope, 0.04), 1.0);
      expect(bassLevelAt(envelope, 0.0), 0.0);
    });

    test('interpolates linearly between two steps', () {
      expect(bassLevelAt(envelope, 0.02), closeTo(0.5, 1e-9));
      expect(bassLevelAt(envelope, 0.10), closeTo(0.1, 1e-9));
    });

    test('clamps before the start and after the end', () {
      expect(bassLevelAt(envelope, -1), 0.0);
      expect(bassLevelAt(envelope, 99), closeTo(0.2, 1e-9));
    });

    test('an empty envelope reads as silence', () {
      expect(bassLevelAt(Uint8List(0), 1), 0.0);
    });
  });

  group('smoothBassLevel', () {
    test('rises faster than it falls', () {
      final double up = smoothBassLevel(0, 1, 0.03);
      final double down = smoothBassLevel(1, 0, 0.03);
      // Une constante de temps (tau) écoulée : ~63 % du chemin parcouru.
      expect(up, closeTo(0.632, 0.01));
      expect(1 - down, lessThan(up));
      expect(down, greaterThan(0.85));
    });

    test('does not depend on the frame rate', () {
      double fine = 0;
      for (int i = 0; i < 6; i++) {
        fine = smoothBassLevel(fine, 1, 1 / 120);
      }
      final double coarse = smoothBassLevel(0, 1, 6 / 120);
      expect(fine, closeTo(coarse, 1e-9));
    });

    test('stays put without elapsed time and reaches the target over a long one', () {
      expect(smoothBassLevel(0.4, 1, 0), 0.4);
      expect(smoothBassLevel(0.4, 1, 10), closeTo(1, 1e-6));
      expect(smoothBassLevel(0.4, 0, 10), closeTo(0, 1e-6));
    });
  });

  group('TempoSyncController bass level', () {
    testWidgets('is null without an envelope, then follows the playing position', (tester) async {
      final TempoSyncController controller = TempoSyncController(vsync: const TestVSync());
      controller.start();

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(controller.bassLevel, isNull);

      // Enveloppe pleine d'un bout à l'autre : la cible vaut 1 tant que ça joue.
      controller.setBassEnvelope(Uint8List.fromList(List<int>.filled(250, 255)));
      controller.syncPosition(const Duration(seconds: 1), playing: true);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(controller.bassLevel, greaterThan(0.9));

      // En pause, la cible retombe à 0 et le niveau décroît.
      controller.syncPosition(const Duration(seconds: 1), playing: false);
      await tester.pump(const Duration(milliseconds: 100));
      final double justPaused = controller.bassLevel!;
      await tester.pump(const Duration(seconds: 2));
      expect(controller.bassLevel!, lessThan(justPaused));
      expect(controller.bassLevel!, lessThan(0.05));

      // Dans le corps du test : le ticker doit être arrêté avant la vérification
      // de fin de testWidgets (un addTearDown passerait trop tard).
      controller.dispose();
    });

    testWidgets('extrapolates the position between two syncs while playing', (tester) async {
      final TempoSyncController controller = TempoSyncController(vsync: const TestVSync());
      controller.start();
      await tester.pump();

      // Silence jusqu'à 0,5 s, puis plein : sans synchro entre-temps, le niveau
      // ne monte que si la position est extrapolée.
      final Uint8List envelope = Uint8List(250);
      for (int i = 13; i < 250; i++) {
        envelope[i] = 255;
      }
      controller.setBassEnvelope(envelope);
      controller.syncPosition(Duration.zero, playing: true);
      await tester.pump(const Duration(milliseconds: 100));
      expect(controller.bassLevel, lessThan(0.05));

      for (int i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(controller.bassLevel, greaterThan(0.9));
      controller.dispose();
    });

    testWidgets('setBassEnvelope(null) goes back to no bass level', (tester) async {
      final TempoSyncController controller = TempoSyncController(vsync: const TestVSync());
      controller.start();
      controller.setBassEnvelope(Uint8List.fromList([255, 255]));
      controller.syncPosition(Duration.zero, playing: true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(controller.bassLevel, isNotNull);

      controller.setBassEnvelope(null);
      await tester.pump(const Duration(milliseconds: 100));

      expect(controller.bassLevel, isNull);
      controller.dispose();
    });
  });
}
