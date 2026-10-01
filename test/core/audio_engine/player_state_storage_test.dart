import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/audio_engine/player_state_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('save then load round-trips the queue, index and playlist id (bug critique QA — redémarrage à froid)', () async {
    final storage = PlayerStateStorage();

    await storage.save(queueTrackIds: ['t1', 't2', 't3'], currentIndex: 1, currentPlaylistId: 'playlist-42');

    final PersistedPlayerState? restored = await storage.load();

    expect(restored, isNotNull);
    expect(restored!.queueTrackIds, ['t1', 't2', 't3']);
    expect(restored.currentIndex, 1);
    expect(restored.currentPlaylistId, 'playlist-42');
  });

  test('save without a playlist id clears any previously persisted one', () async {
    final storage = PlayerStateStorage();

    await storage.save(queueTrackIds: ['t1'], currentIndex: 0, currentPlaylistId: 'playlist-42');
    await storage.save(queueTrackIds: ['t1'], currentIndex: 0);

    final PersistedPlayerState? restored = await storage.load();

    expect(restored!.currentPlaylistId, isNull);
  });

  test('load returns null when nothing has been persisted yet', () async {
    final storage = PlayerStateStorage();

    expect(await storage.load(), isNull);
  });
}
