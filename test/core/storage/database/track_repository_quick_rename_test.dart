import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/identity/track_key.dart';
import 'package:playlist_app/core/identity/track_match_key.dart';
import 'package:playlist_app/core/networking/metadata_api_client/online_track_result.dart';
import 'package:playlist_app/core/storage/database/app_database.dart';
import 'package:playlist_app/core/storage/database/quick_rename_change.dart';
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

  Future<void> insertTrack(
    String id, {
    String title = 'Old Title',
    List<String> artists = const ['Old Artist'],
    String album = 'Old Album',
    int year = 1999,
    String cover = '/covers/old.jpg',
    List<String> tags = const ['Rock'],
    EnrichmentStatus status = EnrichmentStatus.enrichedAutoItunes,
    bool requiresUserReview = false,
    int attempts = 0,
    bool locked = false,
    bool overwrite = false,
  }) async {
    await db.into(db.tracks).insert(TracksCompanion.insert(
          id: id,
          title: title,
          album: album,
          artists: artists,
          durationSeconds: 180,
          filePath: '/music/$id.mp3',
          releaseYear: Value(year),
          coverArtPath: Value(cover),
          tags: Value(tags),
          trackNumber: const Value(7),
          discNumber: const Value(1),
          trackCount: const Value(12),
          enrichmentStatus: Value(status),
          enrichmentAttempts: Value(attempts),
          requiresUserReview: Value(requiresUserReview),
          identityLocked: Value(locked),
          overwriteOnEnrich: Value(overwrite),
        ));
    await db.batch((batch) {
      batch.insertAll(db.trackArtists, [
        for (int i = 0; i < artists.length; i++)
          TrackArtistsCompanion.insert(trackId: id, artistName: artists[i], position: i),
      ]);
    });
  }

  Future<Track> track(String id) async => (await repository.findById(id))!;

  Future<List<String>> artistIndex(String id) async => [
        for (final TrackArtist a in await (db.select(db.trackArtists)
              ..where((t) => t.trackId.equals(id))
              ..orderBy([(t) => OrderingTerm.asc(t.position)]))
            .get())
          a.artistName,
      ];

  group('upsertTrack on a locked title (file re-read by the incremental scan)', () {
    ScannedTrack rescanned({
      required String id,
      String title = 'Tag Title',
      List<String> artists = const ['Tag Artist'],
      bool review = false,
      int mtime = 99,
    }) =>
        ScannedTrack(
          id: id,
          title: title,
          album: 'Tag Album',
          primaryArtist: artists.first,
          artists: artists,
          filePath: '/music/t1.mp3',
          durationMs: 240000,
          requiresUserReview: review,
          trimStartMs: 500,
          trimEndMs: 700,
          lastModifiedEpochMs: mtime,
          fileHash: 'newhash',
        );

    test('keeps the id, title, artists and track_artists, but updates duration, file stamp and trims', () async {
      await insertTrack('t1', title: 'Kept Title', artists: ['Kept Artist', 'Guest'], locked: true);

      final String? id = await repository.upsertTrack(rescanned(id: 'tag-title__tag-artist'));

      expect(id, 't1', reason: 'l\'id (clé dérivée du titre) ne suit pas les nouveaux tags');
      final List<Track> all = await db.select(db.tracks).get();
      expect(all, hasLength(1));
      final Track after = all.single;
      expect(after.id, 't1');
      expect(after.title, 'Kept Title');
      expect(after.artists, ['Kept Artist', 'Guest']);
      expect(await artistIndex('t1'), ['Kept Artist', 'Guest']);
      expect(after.identityLocked, isTrue);
      expect(after.durationSeconds, 240);
      expect(after.trimStartMs, 500);
      expect(after.trimEndMs, 700);
      expect(after.lastModifiedEpochMs, 99);
      expect(after.fileHash, 'newhash');
    });

    test('an ambiguous file name does not send a locked title back to "À renommer"', () async {
      await insertTrack('t1', title: 'Kept Title', locked: true, status: EnrichmentStatus.pending);

      await repository.upsertTrack(rescanned(id: 'x', review: true));

      final Track after = await track('t1');
      expect(after.requiresUserReview, isFalse);
      expect(after.enrichmentStatus, EnrichmentStatus.pending);
    });

    test('an unlocked title is still rewritten from the tags (témoin)', () async {
      await insertTrack('t1', title: 'Old Title', locked: false);

      final String? id = await repository.upsertTrack(rescanned(id: 'tag-title__tag-artist'));

      expect(id, 'tag-title__tag-artist');
      final Track after = (await db.select(db.tracks).getSingle());
      expect(after.title, 'Tag Title');
      expect(after.artists, ['Tag Artist']);
    });

    test('a locked title is still dégrisé under its kept name, not the tag name', () async {
      await insertTrack('t1', title: 'Kept Title', artists: ['Kept Artist'], locked: true);
      await db.into(db.playlists).insert(PlaylistsCompanion.insert(id: 'p', title: 'Imported'));
      await db.into(db.playlistMissingTracks).insert(PlaylistMissingTracksCompanion.insert(
            playlistId: 'p',
            position: 2,
            title: 'Kept Title',
            artist: 'Kept Artist',
            sanitizedKey: buildSanitizedKey(title: 'Kept Title', primaryArtist: 'Kept Artist'),
            matchKey: buildTrackMatchKey(title: 'Kept Title', artist: 'Kept Artist'),
          ));

      await repository.upsertTrack(rescanned(id: 'tag-title__tag-artist'));

      final List<PlaylistTrack> links =
          await (db.select(db.playlistTracks)..where((t) => t.playlistId.equals('p'))).get();
      expect(links.map((l) => (l.trackId, l.position)), [('t1', 2)]);
    });
  });

  group('correctReversedTitleArtist', () {
    const OnlineTrackResult halo = OnlineTrackResult(title: 'Halo', artist: 'Beyoncé', album: 'I Am... Sasha Fierce');

    test('rewrites an unlocked title (témoin)', () async {
      await insertTrack('t1', title: 'Beyoncé', artists: ['Halo']);

      expect(await repository.correctReversedTitleArtist('t1', halo), isTrue);
      expect((await track('t1')).title, 'Halo');
    });

    test('does nothing on a locked title', () async {
      await insertTrack('t1', title: 'Beyoncé', artists: ['Halo'], locked: true);

      expect(await repository.correctReversedTitleArtist('t1', halo), isFalse);

      final Track after = await track('t1');
      expect(after.title, 'Beyoncé');
      expect(after.artists, ['Halo']);
      expect(await artistIndex('t1'), ['Halo']);
    });
  });

  group('applyRescanResult on a locked title', () {
    test('is a no-op returning false', () async {
      await insertTrack('t1', locked: true);

      final bool applied = await repository.applyRescanResult(
        't1',
        title: 'Other',
        artists: const ['Someone'],
        match: const OnlineTrackResult(title: 'Other', artist: 'Someone', album: 'Alb'),
        swapped: false,
      );

      expect(applied, isFalse);
      final Track after = await track('t1');
      expect(after.title, 'Old Title');
      expect(after.album, 'Old Album');
    });
  });

  group('enrichFromOnlineMetadata', () {
    // Le titre local d'origine correspond au résultat : la confiance est acquise.
    const OnlineTrackResult match = OnlineTrackResult(
      title: 'Halo',
      artist: 'Beyoncé',
      album: 'I Am... Sasha Fierce',
      releaseYear: 2008,
      coverArtUrl: 'https://is1.mzstatic.com/halo/1000x1000bb.jpg',
      genre: 'Pop',
      trackNumber: 3,
      discNumber: 2,
      trackCount: 14,
    );

    test('without the flag, only fills the empty fields and merges tags (behaviour unchanged)', () async {
      await insertTrack('t1', title: 'Halo', artists: ['Beyoncé']);

      expect(await repository.enrichFromOnlineMetadata('t1', match), isTrue);

      final Track after = await track('t1');
      expect(after.album, 'Old Album');
      expect(after.releaseYear, 1999);
      expect(after.coverArtPath, '/covers/old.jpg');
      expect(after.trackNumber, 7);
      expect(after.discNumber, 1);
      expect(after.trackCount, 12);
      expect(after.tags, containsAll(['Rock', 'Pop']), reason: 'fusion avec les anciens tags');
      expect(after.overwriteOnEnrich, isFalse);
    });

    test('with the flag, a reliable match overwrites album, year, cover, numbers and tags, then drops the flag',
        () async {
      await insertTrack('t1', title: 'Halo', artists: ['Beyoncé'], overwrite: true);

      expect(await repository.enrichFromOnlineMetadata('t1', match), isTrue);

      final Track after = await track('t1');
      expect(after.album, 'I Am... Sasha Fierce');
      expect(after.releaseYear, 2008);
      expect(after.coverArtPath, match.coverArtUrl);
      expect(after.trackNumber, 3);
      expect(after.discNumber, 2);
      expect(after.trackCount, 14);
      expect(after.tags, ['Pop', 'Années 2000', 'Feel-good'], reason: 'reconstruits, sans l\'ancien « Rock »');
      expect(after.overwriteOnEnrich, isFalse);
      expect(after.title, 'Halo');
      expect(after.artists, ['Beyoncé']);
    });

    test('with the flag, a value the result does not provide keeps the existing one', () async {
      await insertTrack('t1', title: 'Halo', artists: ['Beyoncé'], overwrite: true);

      await repository.enrichFromOnlineMetadata('t1', const OnlineTrackResult(title: 'Halo', artist: 'Beyoncé'));

      final Track after = await track('t1');
      expect(after.album, 'Old Album');
      expect(after.releaseYear, 1999);
      expect(after.coverArtPath, '/covers/old.jpg');
      expect(after.trackNumber, 7);
      expect(after.tags, ['Rock'], reason: 'un résultat sans genre ni année ne vide pas les tags');
      expect(after.overwriteOnEnrich, isFalse, reason: 'la tentative fiable a bien eu lieu');
    });

    test('with the flag, a failed confidence check writes nothing and keeps the flag', () async {
      await insertTrack('t1', title: 'Feel Good', artists: ['Charlotte Cardin'], overwrite: true);

      final bool ok = await repository.enrichFromOnlineMetadata(
        't1',
        const OnlineTrackResult(title: 'Confetti', artist: 'Charlotte Cardin', album: '99 Nights', releaseYear: 2021),
      );

      expect(ok, isFalse);
      final Track after = await track('t1');
      expect(after.album, 'Old Album');
      expect(after.releaseYear, 1999);
      expect(after.coverArtPath, '/covers/old.jpg');
      expect(after.overwriteOnEnrich, isTrue);
    });

    test('the overwrite never touches title, artists nor the lock', () async {
      await insertTrack('t1', title: 'Halo', artists: ['Beyoncé'], overwrite: true, locked: true);

      await repository.enrichFromOnlineMetadata('t1', match);

      final Track after = await track('t1');
      expect(after.title, 'Halo');
      expect(after.artists, ['Beyoncé']);
      expect(after.identityLocked, isTrue);
    });
  });

  group('applyQuickRename', () {
    test('rewrites title, artists, track_artists (featurings, positions) and sets the lock', () async {
      await insertTrack('t1');

      final int count = await repository.applyQuickRename(
        const [QuickRenameChange(trackId: 't1', title: 'New Title', artists: ['New Main', 'Guest One', 'Guest Two'])],
      );

      expect(count, 1);
      final Track after = await track('t1');
      expect(after.title, 'New Title');
      expect(after.artists, ['New Main', 'Guest One', 'Guest Two']);
      expect(await artistIndex('t1'), ['New Main', 'Guest One', 'Guest Two']);
      expect(after.identityLocked, isTrue);
      expect(after.id, 't1');
      final List<TrackArtist> rows =
          await (db.select(db.trackArtists)..where((t) => t.trackId.equals('t1'))).get();
      expect(rows.map((r) => (r.artistName, r.position)).toSet(), {('New Main', 0), ('Guest One', 1), ('Guest Two', 2)});
    });

    test('an enriched title keeps its status and every other metadata', () async {
      await insertTrack('t1', status: EnrichmentStatus.enrichedManualItunes, attempts: 1);
      final Track before = await track('t1');

      await repository.applyQuickRename(const [QuickRenameChange(trackId: 't1', title: 'New', artists: ['Artist'])]);

      final Track after = await track('t1');
      expect(after.enrichmentStatus, EnrichmentStatus.enrichedManualItunes);
      expect(after.enrichmentAttempts, 1);
      expect(after.album, before.album);
      expect(after.releaseYear, before.releaseYear);
      expect(after.coverArtPath, before.coverArtPath);
      expect(after.tags, before.tags);
      expect(after.trackNumber, before.trackNumber);
      expect(after.overwriteOnEnrich, isFalse);
    });

    test('a "À renommer" title (requiresUserReview + requiresReview) becomes "À enrichir" (pending, attempts 0)',
        () async {
      await insertTrack('t1', status: EnrichmentStatus.requiresReview, requiresUserReview: true, attempts: 1);

      await repository.applyQuickRename(const [QuickRenameChange(trackId: 't1', title: 'New', artists: ['Artist'])]);

      final Track after = await track('t1');
      expect(after.requiresUserReview, isFalse);
      expect(after.enrichmentStatus, EnrichmentStatus.pending);
      expect(after.enrichmentAttempts, 0);
      expect(after.album, 'Old Album', reason: 'les métadonnées ne bougent pas');
    });

    test('a title flagged only by requiresUserReview, or only by the requiresReview status, also leaves "À renommer"',
        () async {
      await insertTrack('a', requiresUserReview: true, status: EnrichmentStatus.pending);
      await insertTrack('b', requiresUserReview: false, status: EnrichmentStatus.requiresReview);

      await repository.applyQuickRename(const [
        QuickRenameChange(trackId: 'a', title: 'A2', artists: ['X']),
        QuickRenameChange(trackId: 'b', title: 'B2', artists: ['X']),
      ]);

      for (final String id in ['a', 'b']) {
        final Track after = await track(id);
        expect(after.requiresUserReview, isFalse, reason: id);
        expect(after.enrichmentStatus, EnrichmentStatus.pending, reason: id);
      }
    });

    test('a "needsManualReview" title keeps its status (not a "À renommer" one)', () async {
      await insertTrack('t1', status: EnrichmentStatus.needsManualReview, attempts: 2);

      await repository.applyQuickRename(const [QuickRenameChange(trackId: 't1', title: 'New', artists: ['Artist'])]);

      final Track after = await track('t1');
      expect(after.enrichmentStatus, EnrichmentStatus.needsManualReview);
      expect(after.enrichmentAttempts, 2);
    });

    test('an unknown id is ignored and the returned count only covers real changes', () async {
      await insertTrack('t1');
      await insertTrack('t2');

      final int count = await repository.applyQuickRename(const [
        QuickRenameChange(trackId: 't1', title: 'One', artists: ['A']),
        QuickRenameChange(trackId: 'ghost', title: 'Nope', artists: ['A']),
        QuickRenameChange(trackId: 't2', title: 'Two', artists: ['B']),
      ]);

      expect(count, 2);
      expect((await track('t1')).title, 'One');
      expect((await track('t2')).title, 'Two');
      expect(await repository.findById('ghost'), isNull);
    });

    test('an empty list does nothing and returns 0', () async {
      await insertTrack('t1');

      expect(await repository.applyQuickRename(const []), 0);
      expect((await track('t1')).title, 'Old Title');
      expect((await track('t1')).identityLocked, isFalse);
    });

    test('a greyed title of an imported playlist matching the new name is dégrisé', () async {
      await insertTrack('t1');
      await db.into(db.playlists).insert(PlaylistsCompanion.insert(id: 'p', title: 'Imported'));
      await db.into(db.playlistMissingTracks).insert(PlaylistMissingTracksCompanion.insert(
            playlistId: 'p',
            position: 4,
            title: 'New Title',
            artist: 'New Main',
            sanitizedKey: 'no-such-key',
            matchKey: buildTrackMatchKey(title: 'New Title', artist: 'New Main'),
          ));

      await repository.applyQuickRename(const [QuickRenameChange(trackId: 't1', title: 'New Title', artists: ['New Main'])]);

      expect(await db.select(db.playlistMissingTracks).get(), isEmpty);
      final List<PlaylistTrack> links =
          await (db.select(db.playlistTracks)..where((t) => t.playlistId.equals('p'))).get();
      expect(links.map((l) => (l.trackId, l.position)), [('t1', 4)]);
    });

    test('the whole batch is one transaction: nothing is written when one change fails', () async {
      await insertTrack('t1');
      await insertTrack('t2');

      // Un déclencheur SQL fait échouer la 2e écriture : la 1re doit être annulée.
      await db.customStatement(
          'CREATE TRIGGER fail_t2 BEFORE UPDATE ON tracks WHEN NEW.id = \'t2\' AND NEW.title = \'Boom\' '
          'BEGIN SELECT RAISE(ABORT, \'boom\'); END');

      await expectLater(
        repository.applyQuickRename(const [
          QuickRenameChange(trackId: 't1', title: 'One', artists: ['A']),
          QuickRenameChange(trackId: 't2', title: 'Boom', artists: ['B']),
        ]),
        throwsA(anything),
      );

      expect((await track('t1')).title, 'Old Title', reason: 'rollback complet');
      expect((await track('t1')).identityLocked, isFalse);
    });

    test('a renamed (locked) title survives a re-extraction of its modified file', () async {
      await insertTrack('t1');
      await repository.applyQuickRename(const [QuickRenameChange(trackId: 't1', title: 'Renamed', artists: ['Me'])]);

      await repository.upsertTrack(ScannedTrack(
        id: 'tag-title__tag-artist',
        title: 'Tag Title',
        album: '',
        primaryArtist: 'Tag Artist',
        artists: const ['Tag Artist'],
        filePath: '/music/t1.mp3',
        durationMs: 180000,
        requiresUserReview: false,
        trimStartMs: 0,
        trimEndMs: 0,
      ));

      final Track after = await track('t1');
      expect(after.title, 'Renamed');
      expect(after.artists, ['Me']);
      expect(await artistIndex('t1'), ['Me']);
    });
  });

  group('markForReenrichment', () {
    test('puts the titles back in the queue and raises the overwrite flag', () async {
      await insertTrack('a', status: EnrichmentStatus.enrichedAutoItunes);
      await insertTrack('b', status: EnrichmentStatus.needsManualReview, attempts: 2);
      await insertTrack('c', status: EnrichmentStatus.requiresReview, requiresUserReview: true);
      await insertTrack('other', status: EnrichmentStatus.enrichedAutoItunes);

      await repository.markForReenrichment(['a', 'b', 'c', 'ghost']);

      for (final String id in ['a', 'b', 'c']) {
        final Track after = await track(id);
        expect(after.enrichmentStatus, EnrichmentStatus.pending, reason: id);
        expect(after.enrichmentAttempts, 0, reason: id);
        expect(after.requiresUserReview, isFalse, reason: id);
        expect(after.overwriteOnEnrich, isTrue, reason: id);
        expect(after.album, 'Old Album', reason: 'rien n\'est effacé avant l\'enrichissement');
      }
      final Track untouched = await track('other');
      expect(untouched.enrichmentStatus, EnrichmentStatus.enrichedAutoItunes);
      expect(untouched.overwriteOnEnrich, isFalse);
    });

    test('an empty list does nothing; a long list (more than one chunk) is fully handled', () async {
      await repository.markForReenrichment(const []);
      final List<String> ids = [for (int i = 0; i < 1200; i++) 'id$i'];
      await db.batch((batch) {
        batch.insertAll(db.tracks, [
          for (final String id in ids)
            TracksCompanion.insert(
                id: id, title: id, album: '', artists: const ['A'], durationSeconds: 1, filePath: '/m/$id.mp3'),
        ]);
      });

      await repository.markForReenrichment(ids);

      final List<Track> all = await db.select(db.tracks).get();
      expect(all, hasLength(1200));
      expect(all.every((t) => t.overwriteOnEnrich), isTrue);
    });
  });
}
