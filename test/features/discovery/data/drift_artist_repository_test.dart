import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/storage/database/app_database.dart';
import 'package:playlist_app/core/storage/database/track_repository.dart';
import 'package:playlist_app/core/storage/scanner/scanned_track.dart';
import 'package:playlist_app/features/discovery/data/drift_artist_repository.dart';
import 'package:playlist_app/features/discovery/domain/top_artist_playlist.dart';

void main() {
  late AppDatabase db;
  late TrackRepository trackRepository;
  late DriftArtistRepository artistRepository;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    trackRepository = TrackRepository(db);
    artistRepository = DriftArtistRepository(db);
  });

  tearDown(() => db.close());

  Future<void> addTrack({
    required String id,
    required List<String> artists,
    String coverArtPath = '',
    int playCount = 0,
  }) async {
    await trackRepository.upsertTrack(
      ScannedTrack(
        id: id,
        title: 'Title $id',
        album: '',
        primaryArtist: artists.first,
        artists: artists,
        filePath: '/music/$id.mp3',
        durationMs: 180000,
        requiresUserReview: false,
        trimStartMs: 0,
        trimEndMs: 0,
      ),
    );
    if (coverArtPath.isNotEmpty || playCount > 0) {
      await (db.update(db.tracks)..where((t) => t.id.equals(id))).write(
        TracksCompanion(
          coverArtPath: coverArtPath.isEmpty ? const Value.absent() : Value(coverArtPath),
          playCount: Value(playCount),
        ),
      );
    }
  }

  test('ranks artists by local track count, counting featurings like primary credits', () async {
    await addTrack(id: 't1', artists: ['Daft Punk']);
    await addTrack(id: 't2', artists: ['Daft Punk']);
    await addTrack(id: 't3', artists: ['Daft Punk', 'Pharrell Williams']);
    await addTrack(id: 't4', artists: ['Pharrell Williams']);

    final List<TopArtistPlaylist> top = await artistRepository.fetchTopArtistPlaylists(limit: 7);

    expect(top.first.artistName, 'Daft Punk');
    expect(top.first.trackCount, 3);
    final TopArtistPlaylist pharrell = top.firstWhere((p) => p.artistName == 'Pharrell Williams');
    expect(pharrell.trackCount, 2);
  });

  test('respects the limit parameter', () async {
    for (int i = 0; i < 10; i++) {
      await addTrack(id: 't$i', artists: ['Artist $i']);
    }

    final List<TopArtistPlaylist> top = await artistRepository.fetchTopArtistPlaylists(limit: 7);

    expect(top.length, 7);
  });

  test('uses the most-played track cover for the artist', () async {
    await addTrack(id: 't1', artists: ['Daft Punk'], coverArtPath: 'cover1.jpg', playCount: 2);
    await addTrack(id: 't2', artists: ['Daft Punk'], coverArtPath: 'cover2.jpg', playCount: 9);
    await addTrack(id: 't3', artists: ['Daft Punk'], playCount: 0);

    final List<TopArtistPlaylist> top = await artistRepository.fetchTopArtistPlaylists(limit: 7);

    expect(top.single.coverArtPath, 'cover2.jpg');
  });

  test('resolves to a null cover when none of the artist\'s tracks have one', () async {
    await addTrack(id: 't1', artists: ['Daft Punk']);

    final List<TopArtistPlaylist> top = await artistRepository.fetchTopArtistPlaylists(limit: 7);

    expect(top.single.coverArtPath, isNull);
  });

  group('fetchAllArtistNames (QA Section 3.A — case-insensitive dedup)', () {
    test('collapses case variants of the same artist into a single canonical entry', () async {
      await addTrack(id: 't1', artists: ['ABBA']);
      await addTrack(id: 't2', artists: ['Abba']);

      final List<String> names = await artistRepository.fetchAllArtistNames();

      expect(names, ['Abba']);
    });

    test('keeps genuinely distinct artists separate', () async {
      await addTrack(id: 't1', artists: ['Daft Punk']);
      await addTrack(id: 't2', artists: ['Justice']);

      final List<String> names = await artistRepository.fetchAllArtistNames();

      expect(names, ['Daft Punk', 'Justice']);
    });
  });

  group('watchArtistTracks (QA Section 3.A — comparaison insensible à la casse)', () {
    test('finds tracks regardless of the stored casing, matching the canonical name from fetchAllArtistNames',
        () async {
      await addTrack(id: 't1', artists: ['ABBA']);
      await addTrack(id: 't2', artists: ['Abba']);
      final String canonical = (await artistRepository.fetchAllArtistNames()).single;

      final List<Track> tracks = await artistRepository.watchArtistTracks(canonical).first;

      expect(tracks.map((t) => t.id).toSet(), {'t1', 't2'});
    });
  });
}
