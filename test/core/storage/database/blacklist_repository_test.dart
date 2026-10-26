import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/networking/metadata_api_client/metadata_api_client.dart';
import 'package:playlist_app/core/networking/metadata_api_client/online_track_result.dart';
import 'package:playlist_app/core/purge/orphan_purge_service.dart';
import 'package:playlist_app/core/storage/database/app_database.dart';
import 'package:playlist_app/core/storage/database/blacklist_repository.dart';
import 'package:playlist_app/core/storage/database/track_repository.dart';
import 'package:playlist_app/core/storage/scanner/scanned_track.dart';
import 'package:playlist_app/features/discovery/data/drift_artist_repository.dart';
import 'package:playlist_app/features/discovery/data/search_repository.dart';
import 'package:playlist_app/features/discovery/domain/search_result.dart';
import 'package:playlist_app/features/playlists/data/drift_playlist_repository.dart';
import 'package:playlist_app/features/playlists/data/playlist_track_repository.dart';

/// Recherche en ligne neutralisée : seul le résultat local compte ici.
class _OfflineMetadataApiClient extends MetadataApiClient {
  @override
  Future<List<OnlineTrackResult>> search(String query,
          {int limit = 15, CancelToken? cancelToken, bool retryOnFailure = true, String? country}) async =>
      const [];
}

ScannedTrack _scanned(String id, String artist) => ScannedTrack(
      id: id,
      title: 'Song $id',
      album: 'Album',
      primaryArtist: artist,
      artists: [artist],
      filePath: '/music/$id.mp3',
      durationMs: 180000,
      requiresUserReview: false,
      trimStartMs: 0,
      trimEndMs: 0,
    );

/// Identité d'un fichier choisi sur l'appareil (LibraryScanService.identify).
ScannedTrack _file(String id, {required String title, required String artist, required String path}) => ScannedTrack(
      id: id,
      title: title,
      album: '',
      primaryArtist: artist,
      artists: [artist],
      filePath: path,
      durationMs: 180000,
      requiresUserReview: false,
      trimStartMs: 0,
      trimEndMs: 0,
    );

void main() {
  late AppDatabase db;
  late TrackRepository tracks;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    tracks = TrackRepository(db);
    await tracks.upsertTrack(_scanned('a', 'Protected Artist'));
    await tracks.upsertTrack(_scanned('b', 'Other Artist'));
    await db.into(db.playlists).insert(PlaylistsCompanion.insert(id: 'p', title: 'Ma playlist'));
    await PlaylistTrackRepository(db).addTracks('p', ['a', 'b']);
  });

  tearDown(() => db.close());

  Future<Track> track(String id) async => (await tracks.findById(id))!;
  Future<List<String>> idsIn(String playlistId) async => [
        for (final row in await (db.select(db.playlistTracks)..where((t) => t.playlistId.equals(playlistId))).get())
          row.trackId
      ];
  Future<List<(String, int)>> ordered(String playlistId) async => [
        for (final row in await (db.select(db.playlistTracks)
              ..where((t) => t.playlistId.equals(playlistId))
              ..orderBy([(t) => OrderingTerm.asc(t.position)]))
            .get())
          (row.trackId, row.position)
      ];
  Future<BlacklistedTrack> onlyEntry() async => (await db.select(db.blacklistedTracks).get()).single;

  group('physical deletion refused by the system (File.delete fallback)', () {
    test('an exception from File.delete() blacklists the track instead of failing', () async {
      final OrphanPurgeService purge = OrphanPurgeService(db, deleteFile: (path) async {
        if (path.endsWith('a.mp3')) throw const FileSystemException('Accès refusé', '/music/a.mp3');
        return true;
      });

      final PurgeResult result = await purge.deleteTracks([await track('a'), await track('b')]);

      expect(result.blacklisted.map((t) => t.id), ['a']);
      expect(result.deleted.map((t) => t.id), ['b'], reason: 'le reste du lot est supprimé normalement');
      expect(result.removedIds, {'a', 'b'});
      expect(await tracks.findById('a'), isNull);
      expect(await tracks.findById('b'), isNull);
      final List<BlacklistedTrack> entries = await db.select(db.blacklistedTracks).get();
      expect(entries.map((e) => (e.filePath, e.reason)), [('/music/a.mp3', BlacklistReason.deletionFailed)]);
    });

    test('a file still present after delete() counts as protected too', () async {
      final OrphanPurgeService purge = OrphanPurgeService(db, deleteFile: (_) async => false);

      final PurgeResult result = await purge.deleteTracks([await track('a')]);

      expect(result.blacklisted.map((t) => t.id), ['a']);
      expect(await tracks.isBlacklisted(filePath: '/music/a.mp3'), isTrue);
    });
  });

  group('a blacklisted track is sealed off from the whole app', () {
    setUp(() async => BlacklistRepository(db).blacklist([await track('a')], reason: BlacklistReason.manual));

    test('library, rankings and artist views no longer see it', () async {
      expect((await tracks.fetchAllTracks()).map((t) => t.id), ['b']);
      final DriftArtistRepository artists = DriftArtistRepository(db);
      expect(await artists.fetchAllArtistNames(), ['Other Artist']);
      expect((await artists.fetchTopArtistPlaylists()).map((p) => p.artistName), ['Other Artist']);
      expect(await artists.watchArtistTracks('Protected Artist').first, isEmpty);
    });

    test('search does not find it', () async {
      final List<SearchResult> results = await SearchRepository(db, _OfflineMetadataApiClient()).search('Song a');

      expect(results.whereType<TrackSearchResult>(), isEmpty);
    });

    test('it leaves every playlist and can never be added back to one', () async {
      expect(await idsIn('p'), ['b']);
      expect(await idsIn(kAllImportedPlaylistId), ['b']);
      expect((await DriftPlaylistRepository(db).fetchOrderedTracks('p')).map((t) => t.id), ['b']);

      final PlaylistTrackRepository playlists = PlaylistTrackRepository(db);
      await playlists.addTrack('p', 'a');
      expect(await playlists.addTracks('p', ['a']), 0);
      expect(await idsIn('p'), ['b'], reason: 'id périmé : jamais réinséré');
    });

    test('a later scan or import never re-imports the file', () async {
      await tracks.upsertTrack(_scanned('a', 'Protected Artist'));

      expect(await tracks.findById('a'), isNull);
    });
  });

  group('restore', () {
    test('brings the exact track back (enriched metadata, play count) into the library', () async {
      await (db.update(db.tracks)..where((t) => t.id.equals('a'))).write(TracksCompanion(
        title: const Value('Titre corrigé à la main'),
        playCount: const Value(7),
        tags: const Value(['pop']),
        enrichmentStatus: const Value(EnrichmentStatus.enrichedManualEdit),
      ));
      final Track before = await track('a');
      final BlacklistRepository blacklist = BlacklistRepository(db, fileExists: (_) async => true);
      await blacklist.blacklist([before], reason: BlacklistReason.manual);

      final RestoreOutcome outcome = await blacklist.restore((await db.select(db.blacklistedTracks).get()).single);

      expect(outcome, RestoreOutcome.restored);
      // toJson : l'égalité générée compare les listes (artistes, tags) par identité.
      expect((await track('a')).toJson(), before.toJson());
      expect(await db.select(db.blacklistedTracks).get(), isEmpty);
      expect(await idsIn(kAllImportedPlaylistId), containsAll(['a', 'b']));
      expect(await DriftArtistRepository(db).fetchAllArtistNames(), contains('Protected Artist'));
    });

    test('a file that disappeared is simply cleared from the blacklist', () async {
      final BlacklistRepository blacklist = BlacklistRepository(db, fileExists: (_) async => false);
      await blacklist.blacklist([await track('a')], reason: BlacklistReason.deletionFailed);

      final RestoreOutcome outcome = await blacklist.restore((await db.select(db.blacklistedTracks).get()).single);

      expect(outcome, RestoreOutcome.fileMissing);
      expect(await db.select(db.blacklistedTracks).get(), isEmpty);
      expect(await tracks.findById('a'), isNull);
    });

    test('never overwrites an identical track that reached the library from another file', () async {
      final BlacklistRepository blacklist = BlacklistRepository(db, fileExists: (_) async => true);
      final Track original = await track('a');
      await blacklist.blacklist([original], reason: BlacklistReason.manual);
      final ScannedTrack copy = _scanned('a', 'Protected Artist');
      await tracks.upsertTrack(ScannedTrack(
        id: copy.id,
        title: copy.title,
        album: copy.album,
        primaryArtist: copy.primaryArtist,
        artists: copy.artists,
        filePath: '/music/copy-of-a.mp3',
        durationMs: copy.durationMs,
        requiresUserReview: false,
        trimStartMs: 0,
        trimEndMs: 0,
      ));
      expect(await tracks.findById('a'), isNull, reason: 'même clé : la copie est masquée elle aussi');
      // Filet de sécurité : copie entrée par une voie qui ignore la liste noire.
      await tracks.restoreTrack(original.copyWith(filePath: '/music/copy-of-a.mp3'));

      final RestoreOutcome outcome = await blacklist.restore((await db.select(db.blacklistedTracks).get()).single);

      expect(outcome, RestoreOutcome.alreadyInLibrary);
      expect((await track('a')).filePath, '/music/copy-of-a.mp3');
      expect(await db.select(db.blacklistedTracks).get(), hasLength(1));
    });
  });

  group('P3 — playlists and positions survive a blacklist round trip', () {
    late BlacklistRepository blacklist;

    setUp(() async {
      blacklist = BlacklistRepository(db, fileExists: (_) async => true);
      await db.into(db.playlists).insert(PlaylistsCompanion.insert(id: 'q', title: 'Autre playlist'));
      await PlaylistTrackRepository(db).addTracks('q', ['b', 'a']);
    });

    test('the track goes back to its original slot in every playlist', () async {
      await blacklist.blacklist([await track('a')], reason: BlacklistReason.manual);
      expect(await ordered('p'), [('b', 1)]);

      expect(await blacklist.restore(await onlyEntry()), RestoreOutcome.restored);

      expect(await ordered('p'), [('a', 0), ('b', 1)]);
      expect(await ordered('q'), [('b', 0), ('a', 1)]);
    });

    test('a slot taken meanwhile shifts the rest down, greyed titles included', () async {
      await blacklist.blacklist([await track('a')], reason: BlacklistReason.manual);
      await tracks.upsertTrack(_scanned('c', 'Other Artist'));
      await db
          .into(db.playlistTracks)
          .insert(PlaylistTracksCompanion.insert(playlistId: 'p', trackId: 'c', position: 0));
      await db.into(db.playlistMissingTracks).insert(PlaylistMissingTracksCompanion.insert(
            playlistId: 'p',
            position: 2,
            title: 'Absent',
            artist: 'Nobody',
            sanitizedKey: 'absent__nobody',
            matchKey: 'absent|nobody',
          ));

      await blacklist.restore(await onlyEntry());

      expect(await ordered('p'), [('a', 0), ('c', 1), ('b', 2)]);
      final PlaylistMissingTrack greyed = await db.select(db.playlistMissingTracks).getSingle();
      expect(greyed.position, 3);
    });

    test('a playlist deleted meanwhile is simply skipped', () async {
      await blacklist.blacklist([await track('a')], reason: BlacklistReason.manual);
      await (db.delete(db.playlistTracks)..where((t) => t.playlistId.equals('q'))).go();
      await (db.delete(db.playlists)..where((t) => t.id.equals('q'))).go();

      expect(await blacklist.restore(await onlyEntry()), RestoreOutcome.restored);

      expect(await ordered('p'), [('a', 0), ('b', 1)]);
      expect(await ordered('q'), isEmpty);
    });

    test('an entry from the first blacklist build (bare track snapshot) still restores', () async {
      final Track before = await track('a');
      await blacklist.blacklist([before], reason: BlacklistReason.manual);
      final BlacklistedTrack entry = await onlyEntry();
      final Object? bareTrack = (jsonDecode(entry.trackSnapshot) as Map<String, dynamic>)['track'];
      await (db.update(db.blacklistedTracks)..where((b) => b.filePath.equals(entry.filePath)))
          .write(BlacklistedTracksCompanion(trackSnapshot: Value(jsonEncode(bareTrack))));

      final BlacklistedTrack legacy = await onlyEntry();
      expect(BlacklistRepository.trackKeyOf(legacy), 'a');
      expect(await blacklist.restore(legacy), RestoreOutcome.restored);

      expect((await track('a')).toJson(), before.toJson());
      expect(await idsIn(kAllImportedPlaylistId), contains('a'));
    });
  });

  group('P2 — files hidden straight from the device', () {
    test('a file never imported is sealed by its key, wherever it shows up later', () async {
      final BlacklistRepository blacklist = BlacklistRepository(db);
      final List<Track> removed = await blacklist.hideFiles([
        _file('c', title: 'Song c', artist: 'Other Artist', path: '/cache/file_picker/1/c.mp3'),
      ]);

      expect(removed, isEmpty);
      final BlacklistedTrack entry = await onlyEntry();
      expect(
          (entry.reason, entry.title, BlacklistRepository.trackKeyOf(entry)), (BlacklistReason.manual, 'Song c', 'c'));
      expect(await tracks.isBlacklisted(filePath: '/music/c.mp3', trackKey: 'c'), isTrue);
      await tracks.upsertTrack(_scanned('c', 'Other Artist')); // scan de l'appareil : autre chemin, même clé
      expect(await tracks.findById('c'), isNull);

      expect(await blacklist.restore(entry), RestoreOutcome.unhidden);
      expect(await db.select(db.blacklistedTracks).get(), isEmpty);
      await tracks.upsertTrack(_scanned('c', 'Other Artist'));
      expect(await tracks.findById('c'), isNotNull);
    });

    test('a file already in the library leaves it, restorable with its playlists', () async {
      final BlacklistRepository blacklist = BlacklistRepository(db, fileExists: (_) async => true);

      final List<Track> removed = await blacklist.hideFiles([
        _file('a', title: 'Song a', artist: 'Protected Artist', path: '/cache/file_picker/2/a.mp3'),
      ]);

      expect(removed.map((t) => t.id), ['a']);
      expect(await tracks.findById('a'), isNull);
      expect((await onlyEntry()).filePath, '/music/a.mp3', reason: 'le fichier de la bibliothèque, pas la copie');
      expect(await blacklist.restore(await onlyEntry()), RestoreOutcome.restored);
      expect(await ordered('p'), [('a', 0), ('b', 1)]);
    });
  });

  group('P1 — findMatch (manual import of a blacklisted title)', () {
    setUp(() async => BlacklistRepository(db).blacklist([await track('a')], reason: BlacklistReason.manual));

    test('matches the same path, the same key, or the same title + primary artist', () async {
      final BlacklistRepository blacklist = BlacklistRepository(db);
      Future<String?> match(String id, String title, String path) async =>
          (await blacklist.findMatch(_file(id, title: title, artist: 'Protected Artist', path: path)))?.filePath;

      expect(await match('other-key', 'Other title', '/music/a.mp3'), '/music/a.mp3');
      expect(await match('a', 'Other title', '/cache/a.mp3'), '/music/a.mp3');
      expect(await match('song-a_live_protected-artist', 'Song A (Live)', '/cache/a.mp3'), '/music/a.mp3');
      expect(await match('song-b__protected-artist', 'Song b', '/cache/b.mp3'), isNull);
    });

    test('two different non-Latin titles of the same artist never match each other', () async {
      final BlacklistRepository blacklist = BlacklistRepository(db);
      await blacklist.hideFiles([_file('кукушка__кино', title: 'Кукушка', artist: 'Кино', path: '/cache/k.mp3')]);

      expect(
        await blacklist.findMatch(_file('группа-крови__кино', title: 'Группа крови', artist: 'Кино', path: '/x.mp3')),
        isNull,
      );
      expect(
        (await blacklist.findMatch(_file('кукушка__кино', title: 'Кукушка', artist: 'Кино', path: '/x.mp3')))?.title,
        'Кукушка',
      );
    });
  });
}
