import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/storage/database/app_database.dart';
import 'package:playlist_app/core/storage/database/track_repository.dart';
import 'package:playlist_app/core/storage/scanner/scanned_track.dart';

void main() {
  late AppDatabase db;
  late TrackRepository repository;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repository = TrackRepository(db);
  });

  tearDown(() => db.close());

  ScannedTrack scannedTrack({
    required String id,
    required List<String> artists,
  }) {
    return ScannedTrack(
      id: id,
      title: 'Some Title',
      album: '',
      primaryArtist: artists.isNotEmpty ? artists.first : '',
      artists: artists,
      filePath: '/music/$id.mp3',
      durationMs: 180000,
      requiresUserReview: false,
      trimStartMs: 0,
      trimEndMs: 0,
    );
  }

  test(
    'deduplicates a repeated artist name instead of crashing on the track_artists unique constraint',
    () async {
      // Cas réel : "Hunter X Hunter - Ending 2...mp3" — le séparateur
      // multi-artiste du sanitizer traite le "X" du titre comme un
      // featuring et produit artists: ["Hunter", "Hunter"], ce qui plantait
      // tout le scan (SqliteException 1555, UNIQUE constraint failed) avant
      // la déduplication dans upsertTrack.
      final scanned = scannedTrack(id: 't1', artists: ['Hunter', 'Hunter']);

      await repository.upsertTrack(scanned);

      final track = await repository.findById('t1');
      expect(track!.artists, ['Hunter']);

      final artistRows = await (db.select(db.trackArtists)..where((t) => t.trackId.equals('t1'))).get();
      expect(artistRows.map((r) => r.artistName).toList(), ['Hunter']);
    },
  );

  test('keeps distinct artists in order when there is no duplicate', () async {
    final scanned = scannedTrack(id: 't1', artists: ['Daft Punk', 'Pharrell Williams']);

    await repository.upsertTrack(scanned);

    final track = await repository.findById('t1');
    expect(track!.artists, ['Daft Punk', 'Pharrell Williams']);

    final artistRows = await (db.select(db.trackArtists)..where((t) => t.trackId.equals('t1'))).get();
    expect(artistRows.map((r) => r.artistName).toList(), ['Daft Punk', 'Pharrell Williams']);
  });

  test('re-scanning the same file (upsert) does not duplicate track_artists rows', () async {
    final scanned = scannedTrack(id: 't1', artists: ['Daft Punk']);

    await repository.upsertTrack(scanned);
    await repository.upsertTrack(scanned);

    final artistRows = await (db.select(db.trackArtists)..where((t) => t.trackId.equals('t1'))).get();
    expect(artistRows.length, 1);
  });

  group('renameOrMergeArtists (Section 4, Fusion Manuelle)', () {
    test('renames a single artist across all their tracks while preserving other metadata', () async {
      await repository.upsertTrack(scannedTrack(id: 't1', artists: ['Artist & A']));
      await (db.update(db.tracks)..where((t) => t.id.equals('t1'))).write(
        const TracksCompanion(
            album: Value('Some Album'), releaseYear: Value(2020), coverArtPath: Value('local/cover.jpg')),
      );

      await repository.renameOrMergeArtists(['Artist & A'], 'Artist');

      final track = await repository.findById('t1');
      expect(track!.artists, ['Artist']);
      expect(track.album, 'Some Album');
      expect(track.releaseYear, 2020);
      expect(track.coverArtPath, 'local/cover.jpg');

      final artistRows = await (db.select(db.trackArtists)..where((t) => t.trackId.equals('t1'))).get();
      expect(artistRows.map((r) => r.artistName).toList(), ['Artist']);
    });

    test('merges several artists into one target name, deduplicating when a track credits more than one of them',
        () async {
      await repository.upsertTrack(scannedTrack(id: 't1', artists: ['Artist & A']));
      await repository.upsertTrack(scannedTrack(id: 't2', artists: ['Artist & B']));
      // Crédite déjà les deux sources sur le même morceau — la fusion ne doit
      // pas produire un doublon ["Artist", "Artist"] dans `artists`.
      await repository.upsertTrack(scannedTrack(id: 't3', artists: ['Artist & A', 'Artist & B']));

      await repository.renameOrMergeArtists(['Artist & A', 'Artist & B'], 'Artist');

      expect((await repository.findById('t1'))!.artists, ['Artist']);
      expect((await repository.findById('t2'))!.artists, ['Artist']);
      expect((await repository.findById('t3'))!.artists, ['Artist']);

      final t3ArtistRows = await (db.select(db.trackArtists)..where((t) => t.trackId.equals('t3'))).get();
      expect(t3ArtistRows.map((r) => r.artistName).toList(), ['Artist']);
    });

    test('leaves unrelated tracks untouched', () async {
      await repository.upsertTrack(scannedTrack(id: 't1', artists: ['Artist & A']));
      await repository.upsertTrack(scannedTrack(id: 't2', artists: ['Unrelated Artist']));

      await repository.renameOrMergeArtists(['Artist & A'], 'Artist');

      expect((await repository.findById('t2'))!.artists, ['Unrelated Artist']);
    });

    test('does nothing when sourceNames is empty or targetName is blank', () async {
      await repository.upsertTrack(scannedTrack(id: 't1', artists: ['Artist & A']));

      await repository.renameOrMergeArtists([], 'Artist');
      await repository.renameOrMergeArtists(['Artist & A'], '  ');

      expect((await repository.findById('t1'))!.artists, ['Artist & A']);
    });
  });
}
