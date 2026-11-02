import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audio_service/audio_service.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:playlist_app/core/audio_engine/player_controller.dart';
import 'package:playlist_app/core/audio_engine/playlist_audio_handler.dart';
import 'package:playlist_app/core/audio_engine/queue_controller.dart';
import 'package:playlist_app/core/storage/database/app_database.dart';
import 'package:playlist_app/core/storage/database/database_provider.dart';
import 'package:playlist_app/features/player/presentation/queue_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Recette Axe 3 (navigation) sur émulateur : vrai moteur just_audio/ExoPlayer,
/// vrais fichiers WAV locaux, base Drift en mémoire (les données de l'app
/// installée ne sont pas touchées).

const int _trackCount = 4;
const int _trackSeconds = 30;

/// WAV mono 16 bits 8 kHz : une sinusoïde par piste, pour qu'ExoPlayer ait un
/// vrai flux à décoder.
Future<String> _writeTone(Directory dir, int index) async {
  const int rate = 8000;
  const int samples = rate * _trackSeconds;
  final ByteData data = ByteData(44 + samples * 2);
  void ascii(int offset, String s) {
    for (int i = 0; i < s.length; i++) {
      data.setUint8(offset + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  data.setUint32(4, 36 + samples * 2, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  data.setUint32(40, samples * 2, Endian.little);
  final double freq = 220.0 * (index + 1);
  for (int i = 0; i < samples; i++) {
    data.setInt16(44 + i * 2, (math.sin(2 * math.pi * freq * i / rate) * 3000).round(), Endian.little);
  }
  final File file = File('${dir.path}/qa_nav_t$index.wav');
  await file.writeAsBytes(data.buffer.asUint8List());
  return file.path;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late ProviderContainer container;
  late List<Track> tracks;

  PlayerController player() => container.read(playerControllerProvider.notifier);
  String? currentId() => container.read(playerControllerProvider).currentTrack?.id;
  AudioPlayer engine() => container.read(audioPlayerProvider);
  Future<List<String>> queueIds() async => [for (final Track t in await container.read(queueTracksProvider.future)) t.id];

  /// Fichier réellement chargé dans ExoPlayer (donc entendu).
  String? loadedPath() {
    final AudioSource? source = engine().audioSource;
    if (source is ClippingAudioSource) return source.child.uri.toFilePath();
    if (source is UriAudioSource) return source.uri.toFilePath();
    return null;
  }

  String pathOfId(String id) => tracks.firstWhere((t) => t.id == id).filePath;

  /// Anti-rebond (200 ms) + chargement natif.
  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 900));

  Future<void> waitPosition(Duration atLeast) async {
    final Stopwatch watch = Stopwatch()..start();
    while (engine().position < atLeast) {
      if (watch.elapsed > const Duration(seconds: 20)) fail('lecture bloquée à ${engine().position}');
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    final Directory dir = await getTemporaryDirectory();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    for (int i = 0; i < _trackCount; i++) {
      await db.into(db.tracks).insert(TracksCompanion.insert(
          id: 't$i',
          title: 'Track $i',
          album: '',
          artists: const ['QA'],
          durationSeconds: _trackSeconds,
          filePath: await _writeTone(dir, i)));
    }
    tracks = [
      for (int i = 0; i < _trackCount; i++) await (db.select(db.tracks)..where((t) => t.id.equals('t$i'))).getSingle()
    ];
    container = ProviderContainer(overrides: [appDatabaseProvider.overrideWithValue(db)]);
    container.listen(playerControllerProvider, (_, __) {});
  });

  tearDownAll(() async {
    await engine().stop();
    container.dispose();
    await db.close();
  });

  for (final PlayerRepeatMode mode in PlayerRepeatMode.values) {
    testWidgets('N-01 [${mode.name}] "Suivant" sur le dernier titre revient au premier', (tester) async {
      await tester.runAsync(() async {
        while (container.read(playerControllerProvider).repeatMode != mode) {
          await player().cycleRepeatMode();
        }
        await player().playPlaylist('qa', tracks, startIndex: _trackCount - 1);
        await settle();
        final List<String> order = await queueIds();
        // En aléatoire, la piste de départ est placée en tête : on se cale sur
        // le dernier titre de l'ordre RÉEL de la file.
        await player().playTrackAt(order.length - 1);
        await settle();
        expect(currentId(), order.last);

        await player().next();
        await settle();
        expect(currentId(), order.first, reason: 'ordre de la file : $order');
        expect(loadedPath(), pathOfId(order.first), reason: 'la piste entendue doit être celle affichée');
        expect(engine().playing, isTrue);
      });
    });
  }

  testWidgets('N-02 "Précédent" après 3 s relance le titre à 00:00', (tester) async {
    await tester.runAsync(() async {
      while (container.read(playerControllerProvider).repeatMode != PlayerRepeatMode.playlistOrder) {
        await player().cycleRepeatMode();
      }
      await player().playPlaylist('qa', tracks, startIndex: 2);
      await waitPosition(const Duration(milliseconds: 4500));

      await player().previous();
      await settle();
      expect(currentId(), 't2');
      expect(loadedPath(), pathOfId('t2'));
      expect(engine().position, lessThan(const Duration(seconds: 2)));
    });
  });

  testWidgets('N-03 "Précédent" à moins de 3 s sur le premier titre saute au dernier', (tester) async {
    await tester.runAsync(() async {
      await player().playTrackAt(0);
      await waitPosition(const Duration(milliseconds: 800));
      expect(engine().position, lessThan(const Duration(seconds: 3)));

      await player().previous();
      await settle();
      expect(currentId(), 't${_trackCount - 1}');
      expect(loadedPath(), pathOfId('t${_trackCount - 1}'));
    });
  });

  testWidgets('N-04 "Précédent" ×3 en rafale après 3 s : relance, puis recule de 2', (tester) async {
    await tester.runAsync(() async {
      await player().playTrackAt(3);
      await waitPosition(const Duration(milliseconds: 4500));

      // Premier appui : position > 3 s et aucun zap en cours → retour à 00:00.
      // Les deux suivants reculent d'un titre chacun.
      await player().previous();
      unawaited(player().previous());
      unawaited(player().previous());
      await settle();
      expect(currentId(), 't1');
      expect(loadedPath(), pathOfId('t1'));
    });
  });

  testWidgets('N-05 bouton casque Android : ×2 = Suivant, ×3 = Précédent, touches next/previous', (tester) async {
    await tester.runAsync(() async {
      final PlaylistAudioHandler handler = PlaylistAudioHandler(container);
      await player().playTrackAt(1);
      await settle();

      Future<void> presses(int n) async {
        for (int i = 0; i < n; i++) {
          unawaited(handler.click());
          await Future<void>.delayed(const Duration(milliseconds: 80));
        }
        await Future<void>.delayed(PlaylistAudioHandler.multiPressWindow);
        await settle();
      }

      await presses(2);
      expect(currentId(), 't2', reason: 'double appui = Suivant');

      await presses(3);
      expect(currentId(), 't1', reason: 'triple appui = Précédent (position < 3 s)');

      await presses(1);
      expect(engine().playing, isFalse, reason: 'simple appui = Pause');
      await presses(1);
      expect(engine().playing, isTrue, reason: 'simple appui = Lecture');

      await handler.click(MediaButton.next);
      await settle();
      expect(currentId(), 't2');
      await handler.click(MediaButton.previous);
      await settle();
      expect(currentId(), 't1');
      expect(loadedPath(), pathOfId('t1'));
    });
  });

  testWidgets('N-06 la file d\'attente est en lecture seule (appui long + glisser)', (tester) async {
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: QueueScreen())),
    ));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
    await tester.pump(const Duration(milliseconds: 500));

    final List<String> before = container.read(queueControllerProvider);
    expect(find.byType(ReorderableListView), findsNothing);
    expect(find.byType(ReorderableDragStartListener), findsNothing);
    expect(find.byType(ReorderableDelayedDragStartListener), findsNothing);

    final TestGesture gesture = await tester.startGesture(tester.getCenter(find.text('Track 0')));
    await tester.pump(const Duration(seconds: 1));
    await gesture.moveBy(const Offset(0, 300));
    await tester.pump(const Duration(milliseconds: 300));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 500));

    expect(container.read(queueControllerProvider), before);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(Duration.zero);
  });
}
