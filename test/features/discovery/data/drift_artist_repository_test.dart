import 'dart:async';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/storage/database/app_database.dart';
import 'package:playlist_app/core/storage/database/track_repository.dart';
import 'package:playlist_app/core/storage/scanner/scanned_track.dart';
import 'package:playlist_app/features/discovery/data/drift_artist_repository.dart';
import 'package:playlist_app/features/discovery/domain/playlist_artist_candidate.dart';
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

    // Lot 2.2 : "Ajouter par artiste" omettait des morceaux — la liste regroupe
    // les variantes par clé (casse, espaces, ponctuation), la requête ne
    // comparait que la casse, et seulement en ASCII (`lower()` SQLite).
    test('returns every spelling grouped under the listed name (punctuation, spacing, accented capitals)', () async {
      await addTrack(id: 't1', artists: ['Jay-Z']);
      await addTrack(id: 't2', artists: ['JAY Z']);
      await addTrack(id: 't3', artists: ['CÉLINE DION']);
      await addTrack(id: 't4', artists: ['Céline Dion']);
      final List<String> names = await artistRepository.fetchAllArtistNames();
      expect(names, hasLength(2));

      Future<Set<String>> idsFor(String fragment) async {
        final String name = names.singleWhere((n) => n.toLowerCase().contains(fragment));
        return (await artistRepository.watchArtistTracks(name).first).map((t) => t.id).toSet();
      }

      expect(await idsFor('jay'), {'t1', 't2'});
      expect(await idsFor('céline'), {'t3', 't4'});
    });

    test('keeps artists written in non-Latin scripts apart instead of collapsing them into one entry', () async {
      await addTrack(id: 't1', artists: ['宇多田ヒカル']);
      await addTrack(id: 't2', artists: ['아이유']);

      final List<String> names = await artistRepository.fetchAllArtistNames();

      expect(names.toSet(), {'宇多田ヒカル', '아이유'});
      expect((await artistRepository.watchArtistTracks('아이유').first).map((t) => t.id), ['t2']);
    });

    test('lists a track credited under two spellings of the same artist only once', () async {
      await addTrack(id: 't1', artists: ['Daft Punk', 'DAFT PUNK']);

      final List<Track> tracks = await artistRepository.watchArtistTracks('Daft Punk').first;

      expect(tracks.map((t) => t.id), ['t1']);
    });

    test('re-emits when a new spelling of the artist is imported later', () async {
      await addTrack(id: 't1', artists: ['Daft Punk']);
      final StreamIterator<List<Track>> updates = StreamIterator(artistRepository.watchArtistTracks('Daft Punk'));
      addTearDown(updates.cancel);
      expect(await updates.moveNext(), isTrue);
      expect(updates.current.map((t) => t.id), ['t1']);

      await addTrack(id: 't2', artists: ['DAFT-PUNK']);

      expect(await updates.moveNext(), isTrue);
      expect(updates.current.map((t) => t.id).toSet(), {'t1', 't2'});
    });
  });

  group('fetchArtistsForPlaylist', () {
    setUp(() async {
      await db.into(db.playlists).insert(PlaylistsCompanion.insert(id: 'p', title: 'Mix'));
    });

    Future<void> putInPlaylist(String trackId, {bool pending = true}) => db.into(db.playlistTracks).insert(
          PlaylistTracksCompanion.insert(
            playlistId: 'p',
            trackId: trackId,
            position: 0,
            isPendingPlacement: Value(pending),
          ),
        );

    Future<PlaylistArtistCandidate?> candidate(String name) async {
      final List<PlaylistArtistCandidate> all = await artistRepository.fetchArtistsForPlaylist('p');
      return all.where((c) => c.artistName == name).firstOrNull;
    }

    test('reports total and missing counts, sorted like fetchAllArtistNames', () async {
      await addTrack(id: 'b1', artists: ['Beta']);
      await addTrack(id: 'a1', artists: ['Alpha']);
      await addTrack(id: 'a2', artists: ['Alpha']);
      await putInPlaylist('a1', pending: false);

      final List<PlaylistArtistCandidate> all = await artistRepository.fetchArtistsForPlaylist('p');
      expect(all.map((c) => c.artistName), ['Alpha', 'Beta']);
      expect(all.first.totalTracks, 2);
      expect(all.first.missingTracks, 1);
      expect(all.last.totalTracks, 1);
      expect(all.last.missingTracks, 1);
    });

    test('counts featurings in the total', () async {
      await addTrack(id: 't1', artists: ['Main']);
      await addTrack(id: 't2', artists: ['Other', 'Main']);
      await addTrack(id: 't3', artists: ['Other', 'Main']);

      final PlaylistArtistCandidate? main = await candidate('Main');
      expect(main?.totalTracks, 3);
      expect(main?.missingTracks, 3);
    });

    test('groups case variants without double counting a track credited under both', () async {
      await addTrack(id: 't1', artists: ['Daft Punk']);
      await addTrack(id: 't2', artists: ['DAFT PUNK']);
      await addTrack(id: 't3', artists: ['Daft Punk', 'DAFT PUNK']);

      final List<PlaylistArtistCandidate> all = await artistRepository.fetchArtistsForPlaylist('p');
      final Iterable<PlaylistArtistCandidate> daft = all.where((c) => c.artistName.toLowerCase() == 'daft punk');
      expect(daft, hasLength(1));
      expect(daft.single.totalTracks, 3);
      expect(daft.single.missingTracks, 3);
    });

    test('a fully added artist has zero missing tracks', () async {
      await addTrack(id: 't1', artists: ['Solo']);
      await addTrack(id: 't2', artists: ['Solo']);
      await addTrack(id: 't3', artists: ['Solo']);
      for (final String id in ['t1', 't2', 't3']) {
        await putInPlaylist(id);
      }

      final PlaylistArtistCandidate? solo = await candidate('Solo');
      expect(solo?.totalTracks, 3);
      expect(solo?.missingTracks, 0);
    });

    test('a single missing track is reported as 1, other playlists are ignored', () async {
      await db.into(db.playlists).insert(PlaylistsCompanion.insert(id: 'q', title: 'Autre'));
      await addTrack(id: 't1', artists: ['Solo']);
      await addTrack(id: 't2', artists: ['Solo']);
      await addTrack(id: 't3', artists: ['Solo']);
      await putInPlaylist('t1');
      await putInPlaylist('t2', pending: false);
      await db.into(db.playlistTracks).insert(PlaylistTracksCompanion.insert(playlistId: 'q', trackId: 't3', position: 0));

      final PlaylistArtistCandidate? solo = await candidate('Solo');
      expect(solo?.totalTracks, 3);
      expect(solo?.missingTracks, 1);
    });
  });
}
