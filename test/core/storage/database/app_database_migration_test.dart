import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/storage/database/app_database.dart';
import 'package:playlist_app/core/theme/vibe_engine/vibe_engine.dart';

void main() {
  late Directory dir;
  late File dbFile;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('vibe_migration_test');
    dbFile = File('${dir.path}/app.sqlite');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  /// Les bases "héritées" des tests sont créées au schéma courant : on leur
  /// retire les colonnes ajoutées en v19 pour que la migration puisse les
  /// recréer (sinon `ADD COLUMN` échoue sur une colonne déjà présente).
  Future<void> dropV19Columns(AppDatabase legacy) async {
    await legacy.customStatement('ALTER TABLE playlists DROP COLUMN carousel_position');
    await legacy.customStatement('ALTER TABLE playlist_tracks DROP COLUMN added_since_save');
  }

  test('upgrading from v12 keeps what users saw and remaps the retired forced-done status', () async {
    // Base "v12" : schéma identique pour ces tables, données héritées écrites
    // en SQL brut (valeur d'enum retirée), puis user_version ramené à 12.
    final AppDatabase legacy = AppDatabase.forTesting(NativeDatabase(dbFile));
    await legacy.into(legacy.tracks).insert(TracksCompanion.insert(
        id: 't1', title: 'Forced', album: '', artists: const ['A'], durationSeconds: 180, filePath: '/m/t1.mp3'));
    await legacy.customStatement("UPDATE tracks SET enrichment_status = 'markedEnrichedManually' WHERE id = 't1'");
    for (final (String id, String status) in const [
      ('yt-auto', 'enrichedAutoYoutube'),
      ('yt-man', 'enrichedManualYoutube')
    ]) {
      await legacy.into(legacy.tracks).insert(TracksCompanion.insert(
          id: id, title: id, album: '', artists: const ['A'], durationSeconds: 180, filePath: '/m/$id.mp3'));
      await legacy.customStatement("UPDATE tracks SET enrichment_status = '$status' WHERE id = '$id'");
    }
    await legacy.into(legacy.playlists).insert(PlaylistsCompanion.insert(
        id: 'space', title: 'Space', vibeStyle: const Value(VibePreset.oled), showCoverImage: const Value(false)));
    await legacy.into(legacy.playlists).insert(PlaylistsCompanion.insert(
        id: 'retro', title: 'Retro', vibeStyle: const Value(VibePreset.retro), showCoverImage: const Value(false)));
    await dropV19Columns(legacy);
    await legacy.customStatement('PRAGMA user_version = 12');
    await legacy.close();

    final AppDatabase upgraded = AppDatabase.forTesting(NativeDatabase(dbFile));
    addTearDown(upgraded.close);

    Future<EnrichmentStatus> statusOf(String id) =>
        (upgraded.select(upgraded.tracks)..where((t) => t.id.equals(id))).getSingle().then((t) => t.enrichmentStatus);
    expect(await statusOf('t1'), EnrichmentStatus.enrichedManualEdit, reason: 'v14 : Enrichi totalement manuellement');
    expect(await statusOf('yt-auto'), EnrichmentStatus.enrichedAutoMusicBrainz, reason: 'v15 : YouTube -> MusicBrainz');
    expect(await statusOf('yt-man'), EnrichmentStatus.enrichedManualMusicBrainz,
        reason: 'v15 : YouTube -> MusicBrainz');

    Future<bool> showCover(String id) => (upgraded.select(upgraded.playlists)..where((p) => p.id.equals(id)))
        .getSingle()
        .then((playlist) => playlist.showCoverImage);
    expect(await showCover('space'), isTrue, reason: 'v13 : pochette toujours affichée avant la mise à jour');
    expect(await showCover('retro'), isFalse, reason: 'v13 : choix explicite conservé là où le bouton existait');

    final int version =
        await upgraded.customSelect('PRAGMA user_version').getSingle().then((row) => row.read<int>('user_version'));
    expect(version, upgraded.schemaVersion);
  });

  group('purge of YouTube cover URLs (privacy: no request to Google servers)', () {
    /// Base au [legacyVersion] donné, avec des pochettes héritées écrites en
    /// SQL brut comme sur un vrai appareil, puis rouverte en version courante.
    Future<AppDatabase> upgradeFrom(int legacyVersion, Map<String, (String cover, String status)> rows) async {
      final AppDatabase legacy = AppDatabase.forTesting(NativeDatabase(dbFile));
      for (final MapEntry<String, (String, String)> row in rows.entries) {
        await legacy.into(legacy.tracks).insert(TracksCompanion.insert(
            id: row.key,
            title: row.key,
            album: '',
            artists: const ['A'],
            durationSeconds: 180,
            filePath: '/m/${row.key}.mp3'));
        await legacy.customStatement(
          'UPDATE tracks SET cover_art_path = ?, enrichment_status = ?, enrichment_attempts = 1 WHERE id = ?',
          [row.value.$1, row.value.$2, row.key],
        );
      }
      await dropV19Columns(legacy);
      await legacy.customStatement('PRAGMA user_version = $legacyVersion');
      await legacy.close();
      final AppDatabase upgraded = AppDatabase.forTesting(NativeDatabase(dbFile));
      addTearDown(upgraded.close);
      return upgraded;
    }

    Future<Track> trackOf(AppDatabase db, String id) =>
        (db.select(db.tracks)..where((t) => t.id.equals(id))).getSingle();

    test('a 1.3.0+7 device (schema v15) gets its i.ytimg.com covers cleared and the tracks back in "À enrichir"',
        () async {
      final AppDatabase db = await upgradeFrom(15, {
        'yt-auto': ('https://i.ytimg.com/vi/abc/maxresdefault.jpg', 'enrichedAutoMusicBrainz'),
        'yt-manual': ('https://i.ytimg.com/vi/def/hqdefault.jpg', 'enrichedManualMusicBrainz'),
        'itunes': ('https://is1-ssl.mzstatic.com/image/thumb/a.jpg', 'enrichedAutoItunes'),
      });

      for (final String id in const ['yt-auto', 'yt-manual']) {
        final Track track = await trackOf(db, id);
        expect(track.coverArtPath, isEmpty, reason: '$id : plus aucune requête vers i.ytimg.com');
        expect(track.enrichmentStatus, EnrichmentStatus.pending,
            reason: '$id : à ré-enrichir (iTunes puis MusicBrainz)');
        expect(track.enrichmentAttempts, 0);
      }
      final Track itunes = await trackOf(db, 'itunes');
      expect(itunes.coverArtPath, startsWith('https://is1-ssl.mzstatic.com'), reason: 'pochette iTunes conservée');
      expect(itunes.enrichmentStatus, EnrichmentStatus.enrichedAutoItunes);
    });

    test('a 1.2 device (schema v12) is cleaned too, after its YouTube statuses were remapped', () async {
      final AppDatabase db = await upgradeFrom(12, {
        'yt': ('https://i.ytimg.com/vi/abc/maxresdefault.jpg', 'enrichedAutoYoutube'),
      });

      final Track track = await trackOf(db, 'yt');
      expect(track.coverArtPath, isEmpty);
      expect(track.enrichmentStatus, EnrichmentStatus.pending);
    });

    test('a track still awaiting renaming stays in "À renommer"', () async {
      final AppDatabase legacy = AppDatabase.forTesting(NativeDatabase(dbFile));
      await legacy.into(legacy.tracks).insert(TracksCompanion.insert(
          id: 'ambiguous', title: 'x', album: '', artists: const ['A'], durationSeconds: 180, filePath: '/m/x.mp3'));
      await legacy.customStatement(
          "UPDATE tracks SET cover_art_path = 'https://i.ytimg.com/vi/x/0.jpg', requires_user_review = 1 WHERE id = 'ambiguous'");
      await dropV19Columns(legacy);
      await legacy.customStatement('PRAGMA user_version = 15');
      await legacy.close();
      final AppDatabase db = AppDatabase.forTesting(NativeDatabase(dbFile));
      addTearDown(db.close);

      final Track track = await trackOf(db, 'ambiguous');
      expect(track.coverArtPath, isEmpty);
      expect(track.enrichmentStatus, EnrichmentStatus.requiresReview);
    });

    test('never touches a local cover file, even when its path contains "youtube"', () async {
      final AppDatabase db = await upgradeFrom(15, {
        'local': ('/data/user/0/app/track_covers/youtube_rewind_2019.jpg', 'enrichedManualEdit'),
      });

      final Track track = await trackOf(db, 'local');
      expect(track.coverArtPath, '/data/user/0/app/track_covers/youtube_rewind_2019.jpg');
      expect(track.enrichmentStatus, EnrichmentStatus.enrichedManualEdit);
    });
  });

  test('upgrading from v16 adds the blacklist table without touching existing data', () async {
    // Base "v16" : schéma actuel moins la liste noire, user_version ramené à 16.
    final AppDatabase legacy = AppDatabase.forTesting(NativeDatabase(dbFile));
    await legacy.into(legacy.tracks).insert(TracksCompanion.insert(
        id: 't1', title: 'Kept', album: '', artists: const ['A'], durationSeconds: 180, filePath: '/m/t1.mp3'));
    await legacy.customStatement('DROP TABLE blacklisted_tracks');
    await dropV19Columns(legacy);
    await legacy.customStatement('PRAGMA user_version = 16');
    await legacy.close();

    final AppDatabase upgraded = AppDatabase.forTesting(NativeDatabase(dbFile));
    addTearDown(upgraded.close);

    expect((await upgraded.select(upgraded.tracks).get()).map((t) => t.title), ['Kept']);
    await upgraded.into(upgraded.blacklistedTracks).insert(BlacklistedTracksCompanion.insert(
        filePath: '/m/x.mp3', title: 'X', artists: const ['A'], reason: BlacklistReason.manual, trackSnapshot: '{}'));
    expect(await upgraded.select(upgraded.blacklistedTracks).get(), hasLength(1));
  });

  test('upgrading from v17 recomputes the keys of greyed titles, non-Latin ones included', () async {
    final AppDatabase legacy = AppDatabase.forTesting(NativeDatabase(dbFile));
    await legacy.into(legacy.playlists).insert(PlaylistsCompanion.insert(id: 'p', title: 'Mix'));
    // Clés telles que les écrivait la v1.3.5 : lettres non latines purgées.
    await legacy.into(legacy.playlistMissingTracks).insert(PlaylistMissingTracksCompanion.insert(
        playlistId: 'p',
        position: 0,
        title: '夜に駆ける',
        artist: 'YOASOBI',
        sanitizedKey: '__yoasobi',
        matchKey: '|yoasobi'));
    await legacy.into(legacy.playlistMissingTracks).insert(PlaylistMissingTracksCompanion.insert(
        playlistId: 'p',
        position: 1,
        title: 'One More Time',
        artist: 'Daft Punk',
        album: const Value('Discovery'),
        sanitizedKey: 'one-more-time_discovery_daft-punk',
        matchKey: 'one more time|daft punk'));
    await dropV19Columns(legacy);
    await legacy.customStatement('PRAGMA user_version = 17');
    await legacy.close();

    final AppDatabase upgraded = AppDatabase.forTesting(NativeDatabase(dbFile));
    addTearDown(upgraded.close);

    final List<PlaylistMissingTrack> rows =
        await (upgraded.select(upgraded.playlistMissingTracks)..orderBy([(m) => OrderingTerm.asc(m.position)])).get();
    expect(rows.map((m) => (m.sanitizedKey, m.matchKey)), [
      ('夜に駆ける__yoasobi', '夜に駆ける|yoasobi'),
      ('one-more-time_discovery_daft-punk', 'one more time|daft punk'),
    ]);
  });

  test('upgrading from v18 adds the carousel position and the unsaved-add flag, existing rows keep null / false',
      () async {
    final AppDatabase legacy = AppDatabase.forTesting(NativeDatabase(dbFile));
    await legacy.into(legacy.playlists).insert(PlaylistsCompanion.insert(id: 'p', title: 'Mix'));
    await legacy.into(legacy.tracks).insert(TracksCompanion.insert(
        id: 't1', title: 'Kept', album: '', artists: const ['A'], durationSeconds: 180, filePath: '/m/t1.mp3'));
    await legacy
        .into(legacy.playlistTracks)
        .insert(PlaylistTracksCompanion.insert(playlistId: 'p', trackId: 't1', position: 0));
    await dropV19Columns(legacy);
    await legacy.customStatement('PRAGMA user_version = 18');
    await legacy.close();

    final AppDatabase upgraded = AppDatabase.forTesting(NativeDatabase(dbFile));
    addTearDown(upgraded.close);

    final Playlist playlist = await upgraded.select(upgraded.playlists).getSingle();
    expect(playlist.title, 'Mix');
    expect(playlist.carouselPosition, equals(null));
    final PlaylistTrack entry = await upgraded.select(upgraded.playlistTracks).getSingle();
    expect(entry.trackId, 't1');
    expect(entry.position, 0);
    expect(entry.addedSinceSave, isFalse);
  });

  test('upgrading from v19 renumbers only playlists with duplicate positions, missing titles included', () async {
    final AppDatabase legacy = AppDatabase.forTesting(NativeDatabase(dbFile));
    for (final String id in ['dup', 'ok']) {
      await legacy.into(legacy.playlists).insert(PlaylistsCompanion.insert(id: id, title: id));
    }
    for (final String id in ['a', 'b', 'c', 'd', 'e']) {
      await legacy.into(legacy.tracks).insert(TracksCompanion.insert(
          id: id, title: id, album: '', artists: const ['A'], durationSeconds: 180, filePath: '/m/$id.mp3'));
    }
    // 'dup' : a=0, b=0 (doublon), grisé=1 (intercalé), c=1 (doublon avec le grisé), d=5 (trou).
    for (final (String, int) e in const [('a', 0), ('b', 0), ('c', 1), ('d', 5)]) {
      await legacy
          .into(legacy.playlistTracks)
          .insert(PlaylistTracksCompanion.insert(playlistId: 'dup', trackId: e.$1, position: e.$2));
    }
    await legacy.into(legacy.playlistMissingTracks).insert(PlaylistMissingTracksCompanion.insert(
        playlistId: 'dup', position: 1, title: 'Ghost', artist: 'G', sanitizedKey: 'k', matchKey: 'm'));
    // 'ok' : saine, avec un trou volontaire qui ne doit PAS être touché.
    for (final (String, int) e in const [('a', 0), ('e', 3)]) {
      await legacy
          .into(legacy.playlistTracks)
          .insert(PlaylistTracksCompanion.insert(playlistId: 'ok', trackId: e.$1, position: e.$2));
    }
    await legacy.into(legacy.playlistMissingTracks).insert(PlaylistMissingTracksCompanion.insert(
        playlistId: 'ok', position: 1, title: 'Ghost2', artist: 'G', sanitizedKey: 'k2', matchKey: 'm2'));
    await legacy.customStatement('PRAGMA user_version = 19');
    await legacy.close();

    final AppDatabase upgraded = AppDatabase.forTesting(NativeDatabase(dbFile));
    addTearDown(upgraded.close);

    Future<List<(String, int)>> merged(String playlistId) async {
      final List<PlaylistTrack> t =
          await (upgraded.select(upgraded.playlistTracks)..where((r) => r.playlistId.equals(playlistId))).get();
      final List<PlaylistMissingTrack> m =
          await (upgraded.select(upgraded.playlistMissingTracks)..where((r) => r.playlistId.equals(playlistId))).get();
      return [...t.map((r) => (r.trackId, r.position)), ...m.map((r) => ('ghost:${r.title}', r.position))]
        ..sort((x, y) => x.$2.compareTo(y.$2));
    }

    // Ordre : a(0,rowid1) b(0,rowid2) | grisé(1) vs c(1) -> principale d'abord | d(5).
    expect(await merged('dup'), [('a', 0), ('b', 1), ('c', 2), ('ghost:Ghost', 3), ('d', 4)]);
    expect(await merged('ok'), [('a', 0), ('ghost:Ghost2', 1), ('e', 3)]);
  });
}
