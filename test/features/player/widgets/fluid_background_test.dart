import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/animation/tempo_sync/tempo_sync_controller.dart';
import 'package:playlist_app/core/theme/vibe_engine/vibe_engine.dart';
import 'package:playlist_app/features/player/widgets/fluid_background.dart';

void main() {
  testWidgets('the fluid turbulence shader asset is bundled and loads', (tester) async {
    final ui.FragmentProgram? program =
        await tester.runAsync(() => ui.FragmentProgram.fromAsset('assets/shaders/fluid_turbulence.frag'));
    expect(program, isNotNull);
    expect(program!.fragmentShader(), isNotNull);
  });

  testWidgets('custom+fluid then minimal backgrounds build and paint without error', (tester) async {
    final TempoSyncController tempo = TempoSyncController(vsync: const TestVSync());
    addTearDown(tempo.dispose);

    Widget background(VibeVisual vibe) => MaterialApp(
          home: FluidBackground(
            tempoController: tempo,
            vibe: vibe,
            coverArtPath: null,
            child: const SizedBox.expand(),
          ),
        );

    await tester.pumpWidget(background(const VibeVisual(
      gradientColors: [Color(0xFFE53935), Color(0xFF1E88E5), Color(0xFF1E88E5)],
      accentColor: Colors.white,
      preset: VibePreset.custom,
    )));
    // Laisse le chargement réel du shader aboutir, pour peindre la turbulence
    // et pas seulement le repli halos.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(background(VibeVisual(
      gradientColors: VibePreset.minimal.gradientColors,
      accentColor: VibePreset.minimal.accentColor,
      preset: VibePreset.minimal,
    )));
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.takeException(), isNull);

    // Démonte FluidBackground (et son AnimationController en boucle) : aucun
    // Ticker ne doit rester actif en fin de test.
    await tester.pumpWidget(const SizedBox());
  });

  group('Behind the window (neon)', () {
    // Vérifie aussi que le shader (zones en tableaux d'uniforms, second
    // sampler) passe le compilateur de shaders de Flutter.
    testWidgets('the particles shader asset is bundled and loads', (tester) async {
      final ui.FragmentProgram? program =
          await tester.runAsync(() => ui.FragmentProgram.fromAsset('assets/shaders/vibe_particles.frag'));
      expect(program, isNotNull);
      expect(program!.fragmentShader(), isNotNull);
    });

    Widget neon(TempoSyncController tempo, String? windowImagePath) => MaterialApp(
          home: FluidBackground(
            tempoController: tempo,
            vibe: VibeVisual(
              gradientColors: VibePreset.neon.gradientColors,
              accentColor: VibePreset.neon.accentColor,
              preset: VibePreset.neon,
              windowImagePath: windowImagePath,
            ),
            coverArtPath: null,
            child: const SizedBox.expand(),
          ),
        );

    // Laisse aboutir les chargements réels (shader, fichier, décodages,
    // isolate) en alternant temps réel et frames de test.
    Future<void> settleRealAsync(WidgetTester tester) async {
      for (int i = 0; i < 10; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 16));
      }
    }

    Finder nightFlat() => find.byWidgetPredicate((w) => w is ColoredBox && w.color == const Color(0xFF050D1A));

    testWidgets('without an image: night flat, no exception', (tester) async {
      final TempoSyncController tempo = TempoSyncController(vsync: const TestVSync());
      addTearDown(tempo.dispose);

      await tester.pumpWidget(neon(tempo, null));
      await settleRealAsync(tester);

      expect(tester.takeException(), isNull);
      expect(nightFlat(), findsOneWidget);
      expect(find.byType(RawImage), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('with a missing file: night flat, no exception', (tester) async {
      final TempoSyncController tempo = TempoSyncController(vsync: const TestVSync());
      addTearDown(tempo.dispose);

      final String missing = '${Directory.systemTemp.path}/vibe_window_missing_${DateTime.now().microsecondsSinceEpoch}.png';
      await tester.pumpWidget(neon(tempo, missing));
      await settleRealAsync(tester);

      expect(tester.takeException(), isNull);
      expect(nightFlat(), findsOneWidget);
      expect(find.byType(RawImage), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('with an unreadable file: night flat, no exception', (tester) async {
      final TempoSyncController tempo = TempoSyncController(vsync: const TestVSync());
      addTearDown(tempo.dispose);

      final File garbage = File('${Directory.systemTemp.path}/vibe_window_garbage_${DateTime.now().microsecondsSinceEpoch}.png');
      await tester.runAsync(() => garbage.writeAsBytes(List<int>.generate(256, (i) => i)));
      addTearDown(() => tester.runAsync(() => garbage.delete()));

      await tester.pumpWidget(neon(tempo, garbage.path));
      await settleRealAsync(tester);

      expect(tester.takeException(), isNull);
      expect(nightFlat(), findsOneWidget);
      expect(find.byType(RawImage), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('with a valid image: shown as layer 1, painted without error', (tester) async {
      final TempoSyncController tempo = TempoSyncController(vsync: const TestVSync());
      addTearDown(tempo.dispose);

      // Petite photo de nuit : fond sombre et une "enseigne" magenta.
      final File photo = File('${Directory.systemTemp.path}/vibe_window_photo_${DateTime.now().microsecondsSinceEpoch}.png');
      await tester.runAsync(() async {
        final ui.PictureRecorder recorder = ui.PictureRecorder();
        Canvas(recorder)
          ..drawRect(const Rect.fromLTWH(0, 0, 120, 80), Paint()..color = const Color(0xFF0A0A14))
          ..drawCircle(const Offset(40, 30), 12, Paint()..color = const Color(0xFFFF20C0));
        final ui.Image image = await recorder.endRecording().toImage(120, 80);
        final ByteData? png = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        await photo.writeAsBytes(png!.buffer.asUint8List());
      });
      addTearDown(() => tester.runAsync(() => photo.delete()));

      await tester.pumpWidget(neon(tempo, photo.path));
      await settleRealAsync(tester);

      expect(tester.takeException(), isNull);
      final RawImage layer = tester.widget<RawImage>(find.byType(RawImage));
      // Plus petite que l'écran de test : décodée à sa taille, jamais agrandie.
      expect((layer.image!.width, layer.image!.height), (120, 80));
      expect(layer.fit, BoxFit.cover);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
