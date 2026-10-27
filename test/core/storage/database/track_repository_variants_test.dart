import 'dart:io';

import 'package:drift/drift.dart' show OrderingTerm;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:playlist_app/core/storage/database/app_database.dart';
import 'package:playlist_app/core/storage/database/blacklist_repository.dart';
import 'package:playlist_app/core/storage/database/duplicate_detector_service.dart';
import 'package:playlist_app/core/storage/database/track_repository.dart';
import 'package:playlist_app/core/storage/scanner/scanned_track.dart';

/// AN-28 : deux fichiers DIFFÉRENTS qui produisent le même id (titre + album +
/// artiste principal, mention de version retirée par le nettoyage) doivent
/// coexister en base — le second reçoit un id de variante `<id>~N` et apparaît
/// dans « Doublons détectés » au lieu d'écraser le premier.
void main() {
  late AppDatabase db;
  late TrackRepository repository;
  late Directory dir;

  const String key = 'nightcall__kavinsky';

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repository = TrackRepository(db);
    dir = Directory.systemTemp.createTempSync('vibe_variants');
  });

  tearDown(() async {
    await db.close();
    dir.deleteSync(recursive: true);
  });

  /// Fichier réel (le test d'existence passe par le disque) + son titre scanné.
  ScannedTrack scanned(String fileName, {String id = key, String title = 'Nightcall', int durationMs = 257000}) {
    final File file = File(p.join(dir.path, fileName))..writeAsBytesSync([1, 2, 3]);
    return ScannedTrack(
      id: id,
      title: title,
      album: '',
      primaryArtist: 'Kavinsky',
      artists: const ['Kavinsky'],
      filePath: file.path,
      durationMs: durationMs,
      requiresUserReview: false,
      trimStartMs: 0,
      trimEndMs: 0,
    );
  }

  Future<List<Track>> allTracks() => (db.select(db.tracks)..orderBy([(t) => OrderingTerm(expression: t.id)])).get();

  test('the first file of an identity keeps the plain id, and upsertTrack returns it', () async {
    expect(await repository.upsertTrack(scanned('a.mp3')), key);
  });

  test('a second DIFFERENT file with the same id becomes a variant instead of overwriting the first', () async {
    final ScannedTrack first = scanned('Kavinsky - Nightcall (Drive OST).mp3');
    final ScannedTrack second = scanned('Kavinsky, Angèle, Phoenix - Nightcall.mp3', durationMs: 179000);
    await repository.upsertTrack(first);

    final String? effective = await repository.upsertTrack(second);

    expect(effective, '$key~2');
    final List<Track> rows = await allTracks();
    expect(rows.map((t) => (t.id, t.filePath, t.durationSeconds)), [
      (key, first.filePath, 257),
      ('$key~2', second.filePath, 179),
    ]);
  });

  test('the variant is linked to artists and to "Tous les titres importés" under its effective id', () async {
    await repository.upsertTrack(scanned('a.mp3'));
    await repository.upsertTrack(scanned('b.mp3'));

    final List<TrackArtist> artistRows = await db.select(db.trackArtists).get();
    expect(artistRows.map((r) => r.trackId).toSet(), {key, '$key~2'});
    final List<PlaylistTrack> links =
        await (db.select(db.playlistTracks)..where((t) => t.playlistId.equals(kAllImportedPlaylistId))).get();
    expect(links.map((l) => l.trackId).toSet(), {key, '$key~2'});
  });

  test('an embedded cover extracted for the variant is applied to the variant, not to the first file', () async {
    await repository.upsertTrack(scanned('a.mp3'));
    final File cover = File(p.join(dir.path, 'cover.jpg'))..writeAsBytesSync([9]);
    final ScannedTrack second = scanned('b.mp3');

    await repository.upsertTrack(ScannedTrack(
      id: second.id,
      title: second.title,
      album: second.album,
      primaryArtist: second.primaryArtist,
      artists: second.artists,
      filePath: second.filePath,
      durationMs: second.durationMs,
      requiresUserReview: false,
      trimStartMs: 0,
      trimEndMs: 0,
      coverArtPath: cover.path,
    ));

    expect((await repository.findById(key))!.coverArtPath, '');
    expect((await repository.findById('$key~2'))!.coverArtPath, cover.path);
  });

  test('a third file takes the first free variant id (~3)', () async {
    await repository.upsertTrack(scanned('a.mp3'));
    await repository.upsertTrack(scanned('b.mp3'));

    expect(await repository.upsertTrack(scanned('c.mp3')), '$key~3');

    expect((await allTracks()).map((t) => t.id), [key, '$key~2', '$key~3']);
  });

  test('re-upserting the variant file (same path) keeps its id and creates no new row', () async {
    await repository.upsertTrack(scanned('a.mp3'));
    final ScannedTrack second = scanned('b.mp3');
    await repository.upsertTrack(second);

    expect(await repository.upsertTrack(second), '$key~2');

    expect((await allTracks()).map((t) => t.id), [key, '$key~2']);
  });

  test('when the existing row\'s file is gone, the new file replaces it (previous behaviour)', () async {
    final ScannedTrack first = scanned('a.mp3');
    await repository.upsertTrack(first);
    File(first.filePath).deleteSync();
    final ScannedTrack second = scanned('b.mp3');

    expect(await repository.upsertTrack(second), key);

    final List<Track> rows = await allTracks();
    expect(rows.map((t) => (t.id, t.filePath)), [(key, second.filePath)]);
  });

  test('a variant slot whose file is gone is reused rather than skipped', () async {
    await repository.upsertTrack(scanned('a.mp3'));
    final ScannedTrack second = scanned('b.mp3');
    await repository.upsertTrack(second);
    File(second.filePath).deleteSync();
    final ScannedTrack third = scanned('c.mp3');

    expect(await repository.upsertTrack(third), '$key~2');

    expect((await allTracks()).map((t) => (t.id, t.filePath)).last, ('$key~2', third.filePath));
  });

  test('a blacklisted file inserts nothing and upsertTrack returns null', () async {
    final ScannedTrack hidden = scanned('a.mp3');
    await BlacklistRepository(db).hideFiles([hidden]);

    expect(await repository.upsertTrack(hidden), isNull);

    expect(await allTracks(), isEmpty);
  });

  group('Doublons détectés', () {
    test('the two files of one identity are grouped', () async {
      await repository.upsertTrack(scanned('a.mp3'));
      await repository.upsertTrack(scanned('b.mp3', durationMs: 179000));

      final groups = DuplicateDetectorService.groupDuplicates(await allTracks());

      expect(groups, hasLength(1));
      expect(groups.single.tracks.map((t) => t.id), [key, '$key~2']);
    });

    test('"Song" and "Song (Instrumental)" are NOT grouped', () async {
      await repository.upsertTrack(scanned('a.mp3', id: 'song__kavinsky', title: 'Song'));
      await repository.upsertTrack(
        scanned('b.mp3', id: 'song-instrumental__kavinsky', title: 'Song (Instrumental)'),
      );

      expect(DuplicateDetectorService.groupDuplicates(await allTracks()), isEmpty);
    });
  });
}
