import 'package:drift/drift.dart' show Value;
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

  /// Positions par morceau, pour vérifier l'ordre et l'absence de déplacement.
  Future<Map<String, int>> positionByTrack() async =>
      {for (final row in await db.select(db.playlistTracks).get()) row.trackId: row.position};

  Future<void> insertTrack(String id) => db.into(db.tracks).insert(TracksCompanion.insert(
      id: id, title: id, album: '', artists: const ['A'], durationSeconds: 180, filePath: '/music/$id.mp3'));

  test('re-adding a track already in the playlist leaves its position and the order untouched', () async {
    await insertTrack('t3');
    await repository.addTracks('p', ['t1', 't2', 't3']);

    final AddTrackResult result = await repository.addTrack('p', 't1');

    expect(result, AddTrackResult.alreadyPresent);
    expect(await positionByTrack(), {'t1': 0, 't2': 1, 't3': 2});
  });

  test('addTrack reports a track missing from the library without inserting anything', () async {
    final AddTrackResult result = await repository.addTrack('p', 'ghost');

    expect(result, AddTrackResult.notInLibrary);
    expect(await positionByTrack(), isEmpty);
  });

  test('a track added after a removal in the middle goes after the highest position, not at the count', () async {
    await insertTrack('t3');
    await insertTrack('t4');
    await repository.addTracks('p', ['t1', 't2', 't3']);
    await repository.removeTrack('p', 't2');

    final AddTrackResult result = await repository.addTrack('p', 't4');

    expect(result, AddTrackResult.added);
    expect(await positionByTrack(), {'t1': 0, 't3': 2, 't4': 3});
  });

  test('a track added goes after the greyed titles holding higher positions', () async {
    await repository.addTrack('p', 't1');
    await db.into(db.playlistMissingTracks).insert(PlaylistMissingTracksCompanion.insert(
        playlistId: 'p', position: 5, title: 'Missing', artist: 'A', sanitizedKey: 'missing', matchKey: 'missing|a'));

    await repository.addTrack('p', 't2');

    expect(await positionByTrack(), {'t1': 0, 't2': 6});
  });

  test('two simultaneous addTrack calls get two distinct consecutive positions after existing ones', () async {
    await insertTrack('t3');
    await insertTrack('t4');
    await repository.addTrack('p', 't1');

    await Future.wait([repository.addTrack('p', 't3'), repository.addTrack('p', 't4')]);

    final Map<String, int> byTrack = await positionByTrack();
    expect(byTrack['t1'], 0);
    expect([byTrack['t3'], byTrack['t4']]..sort(), [1, 2]);
  });

  test('a newly added track is flagged as added since the last save, addTracks rows too', () async {
    await insertTrack('t3');
    await repository.addTrack('p', 't1');
    await repository.addTracks('p', ['t2', 't3']);

    final List<PlaylistTrack> rows = await db.select(db.playlistTracks).get();

    expect(rows, hasLength(3));
    expect(rows.every((row) => row.addedSinceSave), isTrue);
  });

  test('re-adding a track keeps its addedSinceSave flag as it was', () async {
    await repository.addTrack('p', 't1');
    await (db.update(db.playlistTracks)..where((t) => t.trackId.equals('t1')))
        .write(const PlaylistTracksCompanion(addedSinceSave: Value(false)));

    await repository.addTrack('p', 't1');

    final PlaylistTrack row = await db.select(db.playlistTracks).getSingle();
    expect(row.addedSinceSave, isFalse);
  });
}
