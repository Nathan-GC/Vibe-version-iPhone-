import 'dart:async';

import 'package:drift/native.dart';
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
  bool get playing => false;

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

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

  test('zapping stops at the ends of the queue', () async {
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
    expect(currentId(), 't0');
    expect(audio.loaded, pathOf(0));
  });
}
