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
}
