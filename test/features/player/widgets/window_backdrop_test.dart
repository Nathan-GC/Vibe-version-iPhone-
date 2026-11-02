import 'dart:io' show Directory, File;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/theme/vibe_engine/window_color_zones.dart';
import 'package:playlist_app/features/player/widgets/window_backdrop.dart';

void main() {
  group('windowDecodeSize', () {
    test('couvre l\'écran en gardant les proportions', () {
      // Portrait 3:4 sur un écran 720×1280 : la hauteur impose l'échelle (0,32).
      expect(windowDecodeSize(3000, 4000, const Size(720, 1280)), (960, 1280));
    });

    test('borne le plus grand côté à 2048', () {
      // Cover exigerait 1800×2400 : ramené à 2048 de haut, proportions gardées.
      expect(windowDecodeSize(3000, 4000, const Size(1080, 2400)), (1536, 2048));
      // Paysage 4:3 sur un écran portrait : cover exigerait 3200×2400.
      expect(windowDecodeSize(4000, 3000, const Size(1080, 2400)), (2048, 1536));
    });

    test('n\'agrandit jamais une image plus petite que l\'écran', () {
      expect(windowDecodeSize(800, 600, const Size(1080, 2400)), (800, 600));
    });

    test('la rotation de l\'écran donne la même taille pour une grande photo', () {
      expect(
        windowDecodeSize(4000, 3000, const Size(2400, 1080)),
        windowDecodeSize(4000, 3000, const Size(1080, 2400)),
      );
    });

    test('écran vide : image bornée seule, jamais zéro', () {
      expect(windowDecodeSize(4096, 2048, Size.zero), (2048, 1024));
      expect(windowDecodeSize(1, 5000, const Size(1080, 2400)), (1, 2048));
    });
  });

  group('windowDecodeSizeChanged', () {
    test('ignore les petits écarts', () {
      expect(windowDecodeSizeChanged((2048, 1536), (2048, 1536)), isFalse);
      expect(windowDecodeSizeChanged((1536, 2048), (1300, 1734)), isFalse);
    });

    test('signale un changement net, dans les deux sens', () {
      expect(windowDecodeSizeChanged((960, 1280), (1536, 2048)), isTrue);
      expect(windowDecodeSizeChanged((1536, 2048), (960, 1280)), isTrue);
    });
  });

  group('windowZoneUniforms', () {
    test('toujours 6 emplacements, vides à poids 0', () {
      final List<double> uniforms = windowZoneUniforms(const []);
      expect(uniforms, hasLength(48));
      expect(uniforms.every((v) => v == 0), isTrue);
    });

    test('formes puis couleurs, dans l\'ordre des zones', () {
      final List<double> uniforms = windowZoneUniforms(const [
        WindowColorZone(x: 0.25, y: 0.5, radius: 0.1, color: Color(0xFFFF0000), weight: 1),
        WindowColorZone(x: 0.75, y: 0.2, radius: 0.2, color: Color(0xFF0000FF), weight: 0.5),
      ]);
      expect(uniforms.sublist(0, 8), [0.25, 0.5, 0.1, 1.0, 0.75, 0.2, 0.2, 0.5]);
      expect(uniforms.sublist(8, 24).every((v) => v == 0), isTrue);
      expect(uniforms.sublist(24, 32), [1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0]);
      expect(uniforms.sublist(32).every((v) => v == 0), isTrue);
    });

    test('au-delà de 6 zones, les suivantes sont ignorées', () {
      final List<double> uniforms = windowZoneUniforms([
        for (int i = 0; i < 8; i++)
          WindowColorZone(x: i / 10, y: 0, radius: 0.1, color: const Color(0xFFFFFFFF), weight: 1),
      ]);
      expect(uniforms, hasLength(48));
      expect(uniforms[5 * 4], closeTo(0.5, 1e-9));
    });
  });

  group('windowNeonDrive', () {
    test('suit les basses quand elles existent', () {
      expect(windowNeonDrive(0.7, 0.0), 0.7);
      expect(windowNeonDrive(1.4, 0.5), 1.0);
    });

    test('repli sur la pulsation, sans saut entre deux battements', () {
      expect(windowNeonDrive(null, 0.0), closeTo(0, 1e-9));
      expect(windowNeonDrive(null, 0.5), closeTo(1, 1e-9));
      // Fin d'un battement et début du suivant : même valeur (pas de dent de scie).
      expect(windowNeonDrive(null, 0.999), closeTo(windowNeonDrive(null, 0.0), 1e-3));
    });
  });

  group('loadWindowBackdrop', () {
    testWidgets('décode l\'image écran, la miniature et les zones', (tester) async {
      final File photo = File('${Directory.systemTemp.path}/vibe_window_load_${DateTime.now().microsecondsSinceEpoch}.png');
      final WindowBackdrop? backdrop = await tester.runAsync<WindowBackdrop?>(() async {
        // 400×200, nuit sombre et une "enseigne" magenta à gauche.
        final PictureRecorder recorder = PictureRecorder();
        Canvas(recorder)
          ..drawRect(const Rect.fromLTWH(0, 0, 400, 200), Paint()..color = const Color(0xFF0A0A14))
          ..drawCircle(const Offset(100, 100), 40, Paint()..color = const Color(0xFFFF20C0));
        final Image image = await recorder.endRecording().toImage(400, 200);
        final ByteData? png = await image.toByteData(format: ImageByteFormat.png);
        image.dispose();
        await photo.writeAsBytes(png!.buffer.asUint8List());
        try {
          return await loadWindowBackdrop(photo.path, const Size(200, 100));
        } finally {
          await photo.delete();
        }
      });

      expect(backdrop, isNotNull);
      expect(backdrop!.decodeSize, (200, 100));
      expect((backdrop.sourceWidth, backdrop.sourceHeight), (400, 200));
      expect((backdrop.blurImage.width, backdrop.blurImage.height), (48, 24));
      // Première zone = l'enseigne : poids 1, centrée vers x = 0,25.
      expect(backdrop.zoneUniforms[0], closeTo(0.25, 0.05));
      expect(backdrop.zoneUniforms[1], closeTo(0.5, 0.05));
      expect(backdrop.zoneUniforms[3], 1.0);
      backdrop.dispose();
    });

    testWidgets('fichier absent ou illisible : null, sans exception', (tester) async {
      final String base = '${Directory.systemTemp.path}/vibe_window_bad_${DateTime.now().microsecondsSinceEpoch}';
      final (WindowBackdrop?, WindowBackdrop?) results = (await tester.runAsync(() async {
        final File garbage = File('$base.jpg');
        await garbage.writeAsBytes(List<int>.generate(256, (i) => i));
        try {
          return (
            await loadWindowBackdrop('$base.missing.png', const Size(1080, 2400)),
            await loadWindowBackdrop(garbage.path, const Size(1080, 2400)),
          );
        } finally {
          await garbage.delete();
        }
      }))!;
      expect(results.$1, isNull);
      expect(results.$2, isNull);
    });
  });

  group('windowNeonSpeed', () {
    test('proportionnelle à bpm / 120, bornée à [0,6 ; 1,8]', () {
      expect(windowNeonSpeed(120), 1.0);
      expect(windowNeonSpeed(150), 1.25);
      expect(windowNeonSpeed(40), 0.6);
      expect(windowNeonSpeed(300), 1.8);
    });
  });
}
