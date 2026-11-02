import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:playlist_app/core/animation/tempo_sync/tempo_sync_controller.dart';
import 'package:playlist_app/core/audio_analysis/bass_analysis_service.dart';
import 'package:playlist_app/core/theme/vibe_engine/vibe_engine.dart';
import 'package:playlist_app/features/player/widgets/fluid_background.dart';

/// Recette Axe 1 sur émulateur (build --profile) : les vrais shaders plein
/// écran animés en continu pendant que just_audio joue un vrai MP3. Le test
/// imprime des marqueurs `QA-PERF` horodatés et les temps de frame ; l'hôte
/// relève en parallèle meminfo, CPU et sous-alimentations audio.

const Duration phaseFluid = Duration(minutes: 4);
const Duration phaseWindow = Duration(minutes: 4);
const int zapCycles = 8;

final ValueNotifier<VibeVisual> _vibe = ValueNotifier(_fluid);

const VibeVisual _fluid = VibeVisual(
  gradientColors: [Color(0xFFE53935), Color(0xFF1E88E5), Color(0xFF1E88E5)],
  accentColor: Colors.white,
  preset: VibePreset.custom,
);

VibeVisual _window(String path) => VibeVisual(
      gradientColors: VibePreset.neon.gradientColors,
      accentColor: VibePreset.neon.accentColor,
      preset: VibePreset.neon,
      windowImagePath: path,
    );

/// Enveloppe synthétique à 116 BPM (25 Hz) : même charge shader qu'une vraie.
Uint8List _envelope(int seconds) => Uint8List.fromList([
      for (int i = 0; i < seconds * 25; i++) (127 + 120 * math.sin(2 * math.pi * (116 / 60) * i / 25)).round(),
    ]);

class _Host extends StatefulWidget {
  const _Host({required this.player});
  final AudioPlayer player;
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> with TickerProviderStateMixin {
  late final TempoSyncController _tempo = TempoSyncController(vsync: this);
  StreamSubscription<Duration>? _position;

  @override
  void initState() {
    super.initState();
    _tempo
      ..updateBpm(116)
      ..setBassEnvelope(_envelope(400))
      ..start();
    _position = widget.player.positionStream.listen((p) => _tempo.syncPosition(p, playing: widget.player.playing));
  }

  @override
  void dispose() {
    _position?.cancel();
    _tempo.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<VibeVisual>(
        valueListenable: _vibe,
        builder: (context, vibe, _) => FluidBackground(
          tempoController: _tempo,
          vibe: vibe,
          coverArtPath: null,
          child: const SizedBox.expand(),
        ),
      );
}

/// Percentiles des temps UI/raster depuis le dernier relevé.
class _Frames {
  final List<FrameTiming> _timings = [];
  void add(List<FrameTiming> t) => _timings.addAll(t);

  String flush() {
    if (_timings.isEmpty) return 'frames=0';
    List<int> sorted(int Function(FrameTiming) f) => _timings.map(f).toList()..sort();
    final List<int> build = sorted((t) => t.buildDuration.inMicroseconds);
    final List<int> raster = sorted((t) => t.rasterDuration.inMicroseconds);
    final List<int> total = sorted((t) => t.totalSpan.inMicroseconds);
    String pct(List<int> v, double p) => (v[((v.length - 1) * p).round()] / 1000).toStringAsFixed(1);
    final int over = total.where((us) => us > 16667).length;
    final String line = 'frames=${_timings.length} '
        'build_p50=${pct(build, .5)} p90=${pct(build, .9)} p99=${pct(build, .99)} '
        'raster_p50=${pct(raster, .5)} p90=${pct(raster, .9)} p99=${pct(raster, .99)} '
        'span_p90=${pct(total, .9)} over16ms=${(100 * over / _timings.length).toStringAsFixed(1)}%';
    _timings.clear();
    return line;
  }
}

void _log(String s) {
  // ignore: avoid_print
  print('QA-PERF ${DateTime.now().toIso8601String().substring(11, 19)} $s');
}

Future<String> _variant(Directory dir, int i) async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  final math.Random rnd = math.Random(i);
  canvas.drawRect(const Rect.fromLTWH(0, 0, 1344, 2992), Paint()..color = const Color(0xFF101820));
  for (int k = 0; k < 14; k++) {
    canvas.drawCircle(Offset(rnd.nextDouble() * 1344, rnd.nextDouble() * 2992), 80 + rnd.nextDouble() * 260,
        Paint()..color = HSVColor.fromAHSV(1, rnd.nextDouble() * 360, .8, .9).toColor());
  }
  final ui.Image image = await recorder.endRecording().toImage(1344, 2992);
  final File file = File('${dir.path}/qa_variant_$i.png')
    ..writeAsBytesSync((await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List());
  image.dispose();
  return file.path;
}

void main() {
  final IntegrationTestWidgetsFlutterBinding binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('P-01..P-04 shaders en continu + audio + zaps', (tester) async {
    final Directory external = (await getExternalStorageDirectory())!;
    final String song = '${external.path}/qa_audio/a_get_lucky.mp3';
    final String photo = '${external.path}/qa_window.png';
    final AudioPlayer player = AudioPlayer(handleInterruptions: false);
    await player.setFilePath(song);
    unawaited(player.setLoopMode(LoopMode.one));
    unawaited(player.play());

    final _Frames frames = _Frames();
    SchedulerBinding.instance.addTimingsCallback(frames.add);
    await tester.pumpWidget(MaterialApp(debugShowCheckedModeBanner: false, home: _Host(player: player)));

    Future<void> phase(String name, Duration length) async {
      _log('BEGIN $name');
      final Stopwatch w = Stopwatch()..start();
      while (w.elapsed < length) {
        await Future<void>.delayed(const Duration(seconds: 30));
        _log('$name t=${w.elapsed.inSeconds}s pos=${player.position.inSeconds}s playing=${player.playing} ${frames.flush()}');
      }
      _log('END $name');
    }

    frames.flush();
    _vibe.value = _fluid;
    await phase('FLUID', phaseFluid);

    _vibe.value = _window(photo);
    // Analyse FFmpeg d'un autre titre pendant la lecture, comme à l'arrivée
    // d'un morceau jamais analysé sous "Behind the window".
    final Stopwatch ffmpeg = Stopwatch()..start();
    _log('FFMPEG start (concurrent with playback)');
    final Future<void> analysis = BassAnalysisService()
        .analyze('${external.path}/qa_audio/b_lose_yourself.mp3')
        .then((r) => _log('FFMPEG done ok=${r != null} in ${ffmpeg.elapsed.inSeconds}s'));
    await phase('WINDOW', phaseWindow);
    await analysis;

    final List<String> variants = [for (int i = 0; i < 5; i++) await _variant(await getTemporaryDirectory(), i)];
    _log('BEGIN ZAP');
    for (int i = 0; i < zapCycles; i++) {
      _vibe.value = _fluid;
      await Future<void>.delayed(const Duration(seconds: 6));
      _vibe.value = _window(i < variants.length ? variants[i] : photo);
      await Future<void>.delayed(const Duration(seconds: 6));
      _log('ZAP cycle=${i + 1} ${frames.flush()}');
    }
    _log('END ZAP');

    _vibe.value = VibeVisual(
      gradientColors: VibePreset.minimal.gradientColors,
      accentColor: VibePreset.minimal.accentColor,
      preset: VibePreset.minimal,
    );
    await phase('IDLE_MINIMAL', const Duration(seconds: 60));

    SchedulerBinding.instance.removeTimingsCallback(frames.add);
    await player.stop();
    await player.dispose();
    await tester.pumpWidget(const SizedBox());
    _log('DONE');
  }, timeout: const Timeout(Duration(minutes: 20)));
}
