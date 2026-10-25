import 'package:drift/drift.dart' show OrderingTerm, Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/storage/database/app_database.dart';
import 'package:playlist_app/core/storage/database/track_repository.dart';
import 'package:playlist_app/features/playlists/data/drift_playlist_repository.dart';
import 'package:playlist_app/features/playlists/data/playlist_track_repository.dart';
import 'package:playlist_app/features/playlists/domain/playlist_editor_entry.dart';

void main() {
  late AppDatabase db;
  late DriftPlaylistRepository repository;
  late PlaylistTrackRepository tracksRepository;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repository = DriftPlaylistRepository(db);
    tracksRepository = PlaylistTrackRepository(db);
    await db.into(db.playlists).insert(PlaylistsCompanion.insert(id: 'p', title: 'P'));
    await db.into(db.playlists).insert(PlaylistsCompanion.insert(id: kAllImportedPlaylistId, title: 'Tous'));
    for (final String id in ['t1', 't2', 't3', 't4']) {
      await db.into(db.tracks).insert(TracksCompanion.insert(
          id: id, title: id, album: '', artists: const ['A'], durationSeconds: 180, filePath: '/music/$id.mp3'));
    }
  });

  tearDown(() => db.close());

  Future<List<PlaylistTrack>> rows(String playlistId) => (db.select(db.playlistTracks)
        ..where((t) => t.playlistId.equals(playlistId))
        ..orderBy([(t) => OrderingTerm.asc(t.position)]))
      .get();

  Future<PlaylistTrack> row(String trackId) async => (await rows('p')).singleWhere((r) => r.trackId == trackId);

  Future<List<PlaylistEditorEntry>> entries() => repository.watchEditorEntries('p').first;

  /// Insère directement une ligne avec des drapeaux précis.
  Future<void> insertRow(String trackId, int position, {bool pending = false, bool added = false}) =>
      db.into(db.playlistTracks).insert(PlaylistTracksCompanion.insert(
            playlistId: 'p',
            trackId: trackId,
            position: position,
            isPendingPlacement: Value(pending),
            addedSinceSave: Value(added),
          ));

  group('commitOrder', () {
    test('keeps a track added meanwhile, appended after the listed entries with its flags intact', () async {
      await insertRow('t1', 0, pending: false);
      await insertRow('t2', 1, pending: false);
      final List<PlaylistEditorEntry> stale = await entries(); // liste ouverte dans l'éditeur

      await tracksRepository.addTrack('p', 't3'); // ajouté pendant que l'éditeur est ouvert
      await tracksRepository.addTrack('p', 't4');

      await repository.commitOrder('p', stale.reversed.toList());

      final List<PlaylistTrack> saved = await rows('p');
      expect([for (final r in saved) r.trackId], ['t2', 't1', 't3', 't4']);
      expect([for (final r in saved) r.position], [0, 1, 2, 3]);
      expect([for (final r in saved) r.addedSinceSave], [false, false, true, true]);
      expect([for (final r in saved) r.isPendingPlacement], [false, false, true, true]);
    });

    test('never brings back a listed track removed from the playlist meanwhile', () async {
      await insertRow('t1', 0);
      await insertRow('t2', 1);
      final List<PlaylistEditorEntry> stale = await entries();

      await tracksRepository.removeTrack('p', 't2'); // retiré depuis un autre écran

      await repository.commitOrder('p', stale);

      expect([for (final r in await rows('p')) r.trackId], ['t1']);
    });

    test('full save clears pending and addedSinceSave on the listed rows', () async {
      await insertRow('t1', 0, pending: true, added: true);
      await insertRow('t2', 1, pending: true, added: true);

      await repository.commitOrder('p', await entries());

      for (final PlaylistTrack r in await rows('p')) {
        expect(r.isPendingPlacement, isFalse);
        expect(r.addedSinceSave, isFalse);
      }
    });

    test('partial save keeps the pending flag read from the database but clears addedSinceSave', () async {
      await insertRow('t1', 0, pending: true, added: true);
      await insertRow('t2', 1, pending: false);
      // Entrée périmée : prétend que t1 n'est plus en attente alors que la base dit le contraire.
      final List<PlaylistEditorEntry> stale = [
        for (final PlaylistEditorEntry e in await entries())
          PlaylistEditorEntry(track: e.track!, isPendingPlacement: false, position: e.position),
      ];

      await repository.commitOrder('p', stale.reversed.toList(), keepPending: true);

      final PlaylistTrack t1 = await row('t1');
      expect(t1.isPendingPlacement, isTrue, reason: 'reste orange jusqu\'à un enregistrement complet');
      expect(t1.addedSinceSave, isFalse);
      expect((await row('t2')).isPendingPlacement, isFalse);
      expect([for (final r in await rows('p')) r.trackId], ['t2', 't1']);

      // Un enregistrement complet ultérieur les considère enfin bien placés.
      await repository.commitOrder('p', await entries());
      expect((await row('t1')).isPendingPlacement, isFalse);
    });
  });

  group('discardAdditionsSinceSave', () {
    test('removes only the rows added since the last save', () async {
      await insertRow('t1', 0);
      await insertRow('t2', 1, pending: true); // orange mais déjà enregistré une fois
      await insertRow('t3', 2, pending: true, added: true);
      await insertRow('t4', 3, pending: true, added: true);

      final int removed = await repository.discardAdditionsSinceSave('p');

      expect(removed, 2);
      expect([for (final r in await rows('p')) r.trackId], ['t1', 't2']);
    });

    test('is a no-op for the all-imported playlist', () async {
      await db.into(db.playlistTracks).insert(PlaylistTracksCompanion.insert(
          playlistId: kAllImportedPlaylistId, trackId: 't1', position: 0, addedSinceSave: const Value(true)));

      final int removed = await repository.discardAdditionsSinceSave(kAllImportedPlaylistId);

      expect(removed, 0);
      expect(await rows(kAllImportedPlaylistId), hasLength(1));
    });
  });
}
