import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:playlist_app/core/audio_analysis/bass_analysis.dart';
import 'package:playlist_app/core/audio_analysis/track_audio_analysis_provider.dart';
import 'package:playlist_app/core/storage/database/app_database.dart';
import 'package:playlist_app/core/storage/database/database_provider.dart';
import 'package:playlist_app/core/theme/vibe_engine/window_color_zones.dart';
import 'package:playlist_app/features/player/widgets/window_backdrop.dart' show kWindowMaxZones, kWindowZoneSampleSize;

/// Recette Axe 2 sur émulateur : vrai ffmpeg_kit_flutter_new_min, vrais
/// fichiers audio poussés par adb dans `files/qa_audio/`, mode avion activé
/// par l'hôte pendant toute l'exécution (l'hôte relève aussi les sockets de
/// l'UID de l'app).
List<WindowColorZone> _zones(Uint8List rgba) =>
    analyzeWindowColorZones(rgba, kWindowZoneSampleSize, kWindowZoneSampleSize, maxZones: kWindowMaxZones);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('A-01..A-04 analyse FFmpeg hors ligne, repli sans plantage, BPM, base', (tester) async {
    final Directory external = (await getExternalStorageDirectory())!;
    final List<File> audio = Directory('${external.path}/qa_audio')
        .listSync()
        .whereType<File>()
        .where((f) => !f.path.endsWith('.corrupt.mp3'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    expect(audio, isNotEmpty, reason: 'fichiers à pousser par adb dans ${external.path}/qa_audio');

    final Directory docs = await getApplicationDocumentsDirectory();
    final File dbFile = File('${docs.path}/qa_analysis.sqlite');
    for (final String suffix in ['', '-wal', '-shm']) {
      if (File('${dbFile.path}$suffix').existsSync()) File('${dbFile.path}$suffix').deleteSync();
    }
    final AppDatabase db = AppDatabase.forTesting(NativeDatabase(dbFile, setup: AppDatabase.configureConnection));
    final ProviderContainer container = ProviderContainer(overrides: [appDatabaseProvider.overrideWithValue(db)]);
    addTearDown(container.dispose);

    final File corrupt = File('${external.path}/qa_audio/zz.corrupt.mp3');
    final List<(String, String)> cases = [
      for (int i = 0; i < audio.length; i++) ('a$i', audio[i].path),
      ('corrupt', corrupt.path),
      ('missing', '${external.path}/qa_audio/does_not_exist.mp3'),
    ];
    await tester.runAsync(() async {
      corrupt.writeAsBytesSync(List<int>.generate(200000, (i) => (i * 7919) % 256));
      for (final (String id, String path) in cases) {
        await db.into(db.tracks).insert(TracksCompanion.insert(
            id: id, title: path.split('/').last, album: '', artists: const ['QA'], durationSeconds: 0, filePath: path));
      }
    });

    for (final (String id, String path) in cases) {
      final Stopwatch watch = Stopwatch()..start();
      final TrackAudioAnalysis? result = await tester.runAsync<TrackAudioAnalysis?>(() => container.read(trackAudioAnalysisProvider(id).future));
      watch.stop();
      final int? bpm = result?.estimatedBpm;
      final Uint8List? env = result?.envelope;
      final double mean = env == null || env.isEmpty ? 0 : env.fold<int>(0, (s, v) => s + v) / env.length;
      // ignore: avoid_print
      print('QA-FFMPEG id=$id file="${path.split('/').last}" ok=${result != null} '
          'envelope=${env?.length ?? 0}B (${((env?.length ?? 0) / 25).toStringAsFixed(1)} s @25 Hz, mean=${mean.toStringAsFixed(1)}) '
          'bpm=$bpm effective=${effectiveBpm(120, bpm)} in ${watch.elapsedMilliseconds} ms');
      if (id == 'corrupt' || id == 'missing') {
        expect(result, isNull, reason: 'repli tempo attendu, sans exception');
      } else {
        expect(result, isNotNull, reason: 'FFmpeg (build min) doit analyser $path');
        expect(env!.length, greaterThan(25 * 30));
      }
    }

    // Deuxième lecture : relue en base, FFmpeg n'est pas relancé.
    final Stopwatch again = Stopwatch()..start();
    await tester.runAsync(() => container.read(trackAudioAnalysisProvider('a0').future));
    // ignore: avoid_print
    print('QA-FFMPEG second read a0 in ${again.elapsedMilliseconds} ms');

    final List<Map<String, Object?>> rows = (await tester.runAsync(() => db
        .customSelect('SELECT t.id, t.estimated_bpm, length(e.envelope) AS len FROM tracks t '
            'LEFT JOIN track_bass_envelopes e ON e.track_id = t.id ORDER BY t.id')
        .get()))!
        .map((r) => r.data)
        .toList();
    // ignore: avoid_print
    print('QA-DB track_bass_envelopes join: $rows');
    expect(rows.where((r) => r['len'] != null).length, audio.length);

    await tester.runAsync(() async {
      await db.close();
      for (final String suffix in ['', '-wal', '-shm']) {
        if (File('${dbFile.path}$suffix').existsSync()) File('${dbFile.path}$suffix').deleteSync();
      }
      corrupt.deleteSync();
    });
  });

  testWidgets('A-05 analyse colorimétrique de l\'image, hors ligne', (tester) async {
    // Image 256×256 à 3 bandes (rouge, vert, bleu), réduite en 64×64 comme
    // dans WindowBackdrop, puis analysée dans un isolate.
    final List<WindowColorZone> zones = (await tester.runAsync(() async {
      final ui.PictureRecorder recorder = ui.PictureRecorder();
      final Canvas canvas = Canvas(recorder);
      const List<Color> bands = [Color(0xFFE53935), Color(0xFF43A047), Color(0xFF1E88E5)];
      for (int i = 0; i < 3; i++) {
        canvas.drawRect(Rect.fromLTWH(0, i * 256 / 3, 256, 256 / 3), Paint()..color = bands[i]);
      }
      final ui.Image big = await recorder.endRecording().toImage(256, 256);
      final ui.Picture scaled = (() {
        final ui.PictureRecorder r = ui.PictureRecorder();
        Canvas(r).drawImageRect(big, const Rect.fromLTWH(0, 0, 256, 256),
            Rect.fromLTWH(0, 0, kWindowZoneSampleSize.toDouble(), kWindowZoneSampleSize.toDouble()), Paint());
        return r.endRecording();
      })();
      final ui.Image sample = await scaled.toImage(kWindowZoneSampleSize, kWindowZoneSampleSize);
      final ByteData data = (await sample.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      final Uint8List rgba = data.buffer.asUint8List();
      return compute(_zones, rgba);
    }))!;
    // ignore: avoid_print
    print('QA-ZONES count=${zones.length} max=$kWindowMaxZones '
        '${zones.map((z) => z.toString()).join(' | ')}');
    expect(zones, isNotEmpty);
    expect(zones.length, lessThanOrEqualTo(kWindowMaxZones));
  });
}
