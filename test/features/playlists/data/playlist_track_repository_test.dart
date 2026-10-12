import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/storage/database/app_database.dart';
import 'package:playlist_app/features/playlists/data/playlist_track_repository.dart';

void main() {
  late AppDatabase db;
  late PlaylistTrackRepository repository;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repository = PlaylistTrackRepository(db);
    await db.into(db.playlists).insert(PlaylistsCompanion.insert(id: 'p', title: 'P'));
    for (final String id in ['t1', 't2']) {
      await db.into(db.tracks).insert(TracksCompanion.insert(
          id: id, title: id, album: '', artists: const ['A'], durationSeconds: 180, filePath: '/music/$id.mp3'));
    }
  });

  tearDown(() => db.close());

  Future<List<int>> positions() async =>
      [for (final row in await db.select(db.playlistTracks).get()) row.position]..sort();

  test('addTracks skips ids repeated in the input instead of failing on the primary key', () async {
    final int added = await repository.addTracks('p', ['t1', 't1', 't2']);

    expect(added, 2);
    expect(await positions(), [0, 1]);
  });

  test('two simultaneous addTrack calls never get the same position', () async {
    await Future.wait([repository.addTrack('p', 't1'), repository.addTrack('p', 't2')]);

    expect(await positions(), [0, 1]);
  });
}
