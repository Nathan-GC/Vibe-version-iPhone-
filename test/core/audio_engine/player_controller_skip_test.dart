import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart' show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:playlist_app/core/audio_engine/player_controller.dart';
import 'package:playlist_app/core/audio_engine/playlist_audio_handler.dart';
import 'package:playlist_app/core/storage/database/app_database.dart';
import 'package:playlist_app/core/storage/database/database_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Faux moteur audio : un chargement prend [loadDelay] et, comme just_audio,
/// un nouveau `setAudioSource` interrompt celui en cours
/// (PlayerInterruptedException). [loaded] = piste réellement dans le lecteur,
/// donc celle qu'on entend.
class _FakeAudioPlayer implements AudioPlayer {
  static const Duration loadDelay = Duration(milliseconds: 30);

  final List<String> requested = [];
  String? loaded;
  int _generation = 0;
  final StreamController<PlayerState> _states = StreamController<PlayerState>.broadcast();

  @override
  Future<Duration?> setAudioSource(
    AudioSource audioSource, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
  }) async {
    final String path = (audioSource as ClippingAudioSource).child.uri.path;
    final int generation = ++_generation;
    requested.add(path);
    await Future<void>.delayed(loadDelay);
    if (generation != _generation) throw PlayerInterruptedException('Loading interrupted');
    loaded = path;
    return null;
  }

  @override
  Stream<PlayerState> get playerStateStream => _states.stream;

  @override
  Stream<Duration> get positionStream => const Stream.empty();

  @override
  bool playing = false;

  @override
  Future<void> play() async => playing = true;

  @override
  Future<void> pause() async => playing = false;

  /// Nombre de libérations explicites du lecteur natif.
  int stops = 0;

  @override
  Future<void> stop() async {
    stops++;
    playing = false;
  }

  @override
  Duration position = Duration.zero;

  Duration? seekedTo;

  @override
  Future<void> seek(Duration? position, {int? index}) async {
    seekedTo = position;
    this.position = position ?? Duration.zero;
  }

  @override
  double volume = 1.0;

  @override
  Future<void> setVolume(double volume) async => this.volume = volume;

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late _FakeAudioPlayer audio;
  late ProviderContainer container;
  late List<Track> tracks;

  /// Le temps de laisser passer l'anti-rebond et le chargement qui suit.
  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 600));

  String pathOf(int index) => '/music/t$index.mp3';
  String? currentId() => container.read(playerControllerProvider).currentTrack?.id;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('com.ryanheise.audio_session'), (call) async => null);

    db = AppDatabase.forTesting(NativeDatabase.memory());
    for (int i = 0; i < 6; i++) {
      await db.into(db.tracks).insert(TracksCompanion.insert(
          id: 't$i', title: 'Track $i', album: '', artists: const ['A'], durationSeconds: 180, filePath: pathOf(i)));
    }
    tracks = [for (int i = 0; i < 6; i++) (await (db.select(db.tracks)..where((t) => t.id.equals('t$i'))).getSingle())];

    audio = _FakeAudioPlayer();
    container = ProviderContainer(overrides: [
      appDatabaseProvider.overrideWithValue(db),
      audioPlayerProvider.overrideWithValue(audio),
    ]);
    container.listen(playerControllerProvider, (_, __) {}); // garde le contrôleur (autoDispose) en vie

    await container.read(playerControllerProvider.notifier).playPlaylist('p', tracks, startIndex: 5);
    expect(audio.loaded, pathOf(5));
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  test('3 rapid "Précédent" land exactly 3 tracks back, on screen and in the speaker', () async {
    final PlayerController player = container.read(playerControllerProvider.notifier);

    unawaited(player.previous());
    unawaited(player.previous());
    unawaited(player.previous());
    await settle();

    expect(currentId(), 't2');
    expect(audio.loaded, pathOf(2), reason: 'la piste entendue doit être celle affichée');
  });

  test('4 rapid "Suivant" from the start of the queue land exactly 4 tracks ahead', () async {
    final PlayerController player = container.read(playerControllerProvider.notifier);
    await player.playPlaylist('p', tracks, startIndex: 0);

    for (int i = 0; i < 4; i++) {
      unawaited(player.next());
    }
    await settle();

    expect(currentId(), 't4');
    expect(audio.loaded, pathOf(4));
  });

  test('each tap updates the displayed track immediately, and only one audio load follows the burst', () async {
    final PlayerController player = container.read(playerControllerProvider.notifier);
    final int loadsBefore = audio.requested.length;

    unawaited(player.previous());
    expect(currentId(), 't4', reason: 'mise à jour visuelle synchrone, sans attendre le chargement');
    unawaited(player.previous());
    unawaited(player.previous());
    expect(currentId(), 't2');
    await settle();

    expect(audio.requested.sublist(loadsBefore), [pathOf(2)], reason: 'un seul chargement, une fois le zap terminé');
  });

  test('the lock screen / notification buttons use the same safe navigation', () async {
    final handler = PlaylistAudioHandler(container);

    unawaited(handler.skipToPrevious());
    unawaited(handler.skipToPrevious());
    unawaited(handler.skipToPrevious());
    unawaited(handler.skipToPrevious());
    await settle();

    expect(currentId(), 't1');
    expect(audio.loaded, pathOf(1));
  });

  group('headset & Bluetooth buttons (Lot 1.3)', () {
    late PlaylistAudioHandler handler;
    Future<void> afterPresses() => Future<void>.delayed(PlaylistAudioHandler.multiPressWindow * 2);

    setUp(() async {
      handler = PlaylistAudioHandler(container);
      await container.read(playerControllerProvider.notifier).playPlaylist('p', tracks, startIndex: 2);
    });

    test('a single press of the headset button toggles play/pause', () async {
      expect(audio.playing, isTrue);

      await handler.click();
      await afterPresses();
      expect(audio.playing, isFalse);

      await handler.click();
      await afterPresses();
      expect(audio.playing, isTrue);
    });

    test('a double press skips to the next track', () async {
      await handler.click();
      await handler.click();
      await afterPresses();
      await settle();

      expect(currentId(), 't3');
      expect(audio.playing, isTrue, reason: 'un double appui ne doit pas aussi mettre en pause');
    });

    test('a triple press goes back to the previous track', () async {
      for (int i = 0; i < 3; i++) {
        await handler.click();
      }
      await afterPresses();
      await settle();

      expect(currentId(), 't1');
    });

    test('on iOS, a press toggles at once (iOS turns double/triple presses into next/previous itself)', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        await handler.click();
        expect(audio.playing, isFalse, reason: 'aucune fenêtre d\'attente des appuis multiples');
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    test('dedicated Bluetooth next/previous keys map straight to next/previous', () async {
      await handler.click(MediaButton.next);
      await settle();
      expect(currentId(), 't3');

      await handler.click(MediaButton.previous);
      await settle();
      expect(currentId(), 't2');
    });
  });

  test('a load interrupted by a newer one never falls through to another track', () async {
    final PlayerController player = container.read(playerControllerProvider.notifier);

    final Future<void> first = player.playTrackAt(1);
    // Le second arrive pendant que le premier charge encore (cas réel du zap).
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(audio.requested.last, pathOf(1), reason: 'le premier chargement doit être en cours');
    final Future<void> second = player.playTrackAt(3);
    await Future.wait([first, second]);
    await settle();

    expect(currentId(), 't3');
    expect(audio.loaded, pathOf(3), reason: 'le chargement interrompu de t1 ne doit pas enchaîner sur t2');
  });

  test('"Suivant" stops at the end of the queue, "Précédent" wraps from the first track to the last', () async {
    final PlayerController player = container.read(playerControllerProvider.notifier);

    unawaited(player.next());
    unawaited(player.next());
    await settle();
    expect(currentId(), 't5', reason: 'déjà sur le dernier morceau');

    await player.playPlaylist('p', tracks, startIndex: 1);
    for (int i = 0; i < 4; i++) {
      unawaited(player.previous());
    }
    await settle();
    expect(currentId(), 't3', reason: 't1 -> t0 -> t5 (bouclage) -> t4 -> t3');
    expect(audio.loaded, pathOf(3));
  });

  group('"Précédent" (Lot 2.1)', () {
    test('after more than 3 s of playback, restarts the current track instead of going back', () async {
      final PlayerController player = container.read(playerControllerProvider.notifier);
      audio.position = const Duration(seconds: 10);

      await player.previous();
      await settle();

      expect(audio.seekedTo, Duration.zero);
      expect(currentId(), 't5');
      expect(audio.loaded, pathOf(5));
    });

    test('within the first 3 s, goes to the previous track', () async {
      final PlayerController player = container.read(playerControllerProvider.notifier);
      audio.position = const Duration(seconds: 2);

      await player.previous();
      await settle();

      expect(audio.seekedTo, isNull);
      expect(currentId(), 't4');
      expect(audio.loaded, pathOf(4));
    });

    test('from the first track, jumps to the last track of the playlist', () async {
      final PlayerController player = container.read(playerControllerProvider.notifier);
      await player.playPlaylist('p', tracks, startIndex: 0);

      await player.previous();
      await settle();

      expect(currentId(), 't5');
      expect(audio.loaded, pathOf(5));
    });

    test('a quick double press restarts the track, then goes back one track', () async {
      final PlayerController player = container.read(playerControllerProvider.notifier);
      audio.position = const Duration(seconds: 42);

      await player.previous();
      await player.previous();
      await settle();

      expect(currentId(), 't4');
    });
  });

  group('audio focus (Lot 1.2)', () {
    late PlayerController player;

    setUp(() {
      player = container.read(playerControllerProvider.notifier);
      expect(audio.playing, isTrue, reason: 'la lecture tourne avant l\'interruption');
    });

    test('a notification only lowers the volume, then restores it — playback never stops', () async {
      player.onAudioInterruption(AudioInterruptionEvent(true, AudioInterruptionType.duck));
      expect(audio.playing, isTrue);
      expect(audio.volume, PlayerController.duckVolume);

      player.onAudioInterruption(AudioInterruptionEvent(false, AudioInterruptionType.duck));
      expect(audio.playing, isTrue);
      expect(audio.volume, 1.0);
    });

    test('a call pauses playback, which resumes with a fade-in once it ends', () async {
      player.onAudioInterruption(AudioInterruptionEvent(true, AudioInterruptionType.pause));
      expect(audio.playing, isFalse);

      player.onAudioInterruption(AudioInterruptionEvent(false, AudioInterruptionType.pause));
      await Future<void>.delayed(Duration.zero);
      expect(audio.playing, isTrue);
      expect(audio.volume, lessThan(1.0), reason: 'repart en fondu, pas d\'un coup à plein volume');

      await Future<void>.delayed(PlayerController.resumeFadeIn * 2);
      expect(audio.volume, 1.0);
    });

    test('a pause from the user during the interruption cancels the automatic resume', () async {
      player.onAudioInterruption(AudioInterruptionEvent(true, AudioInterruptionType.pause));
      await player.pause();

      player.onAudioInterruption(AudioInterruptionEvent(false, AudioInterruptionType.pause));
      await Future<void>.delayed(Duration.zero);

      expect(audio.playing, isFalse);
    });

    test('a pause during the fade-in restores the full volume for the next play', () async {
      player.onAudioInterruption(AudioInterruptionEvent(true, AudioInterruptionType.pause));
      player.onAudioInterruption(AudioInterruptionEvent(false, AudioInterruptionType.pause));
      await Future<void>.delayed(Duration.zero);

      await player.pause();
      await Future<void>.delayed(PlayerController.resumeFadeIn * 2);

      expect(audio.playing, isFalse);
      expect(audio.volume, 1.0);
    });

    test('iOS: an interruption (typeless begin) resumes when the system says it should (shouldResume)', () async {
      player.onAudioInterruption(AudioInterruptionEvent(true, AudioInterruptionType.unknown));
      expect(audio.playing, isFalse);

      player.onAudioInterruption(AudioInterruptionEvent(false, AudioInterruptionType.pause));
      await Future<void>.delayed(Duration.zero);

      expect(audio.playing, isTrue);
    });

    test('an interruption that ends without permission to resume leaves playback paused', () async {
      player.onAudioInterruption(AudioInterruptionEvent(true, AudioInterruptionType.unknown));
      player.onAudioInterruption(AudioInterruptionEvent(false, AudioInterruptionType.unknown));
      await Future<void>.delayed(Duration.zero);

      expect(audio.playing, isFalse);
    });
  });

  group('playlist switch (Lot 1.1)', () {
    test('switching to another playlist releases the native player before loading the new queue', () async {
      final PlayerController player = container.read(playerControllerProvider.notifier);

      await player.playPlaylist('other', tracks, startIndex: 2);

      expect(audio.stops, 1);
      expect(audio.loaded, pathOf(2));
      expect(container.read(playerControllerProvider).currentPlaylistId, 'other');
    });

    test('restarting the same playlist keeps the native player', () async {
      await container.read(playerControllerProvider.notifier).playPlaylist('p', tracks, startIndex: 2);

      expect(audio.stops, 0);
    });
  });
}
