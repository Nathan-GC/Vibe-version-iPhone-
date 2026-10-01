import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/identity/track_key.dart';
import 'package:playlist_app/core/playlist_manifest/manifest_track_ref.dart';
import 'package:playlist_app/core/playlist_manifest/playlist_manifest.dart';
import 'package:playlist_app/core/storage/database/app_database.dart';
import 'package:playlist_app/core/storage/database/track_repository.dart';
import 'package:playlist_app/core/storage/scanner/scanned_track.dart';
import 'package:playlist_app/features/diff/domain/diff_result.dart';
import 'package:playlist_app/features/playlists/data/drift_playlist_repository.dart';
import 'package:playlist_app/features/playlists/data/playlist_manifest_service.dart';
import 'package:playlist_app/features/playlists/domain/import_match_plan.dart';
import 'package:playlist_app/features/playlists/domain/playlist_editor_entry.dart';

void main() {
  late AppDatabase db;
  late TrackRepository tracks;
  late DriftPlaylistRepository playlists;
  late PlaylistManifestService service;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    tracks = TrackRepository(db);
    playlists = DriftPlaylistRepository(db);
    service = PlaylistManifestService(db);
  });

  tearDown(() => db.close());

  Future<String> addTrack(String title, String artist) async {
    final String id = buildSanitizedKey(title: title, album: '', primaryArtist: artist);
    await tracks.upsertTrack(ScannedTrack(
      id: id,
      title: title,
      album: '',
      primaryArtist: artist,
      artists: [artist],
      filePath: '/music/$id.mp3',
      durationMs: 200000,
      requiresUserReview: false,
      trimStartMs: 0,
      trimEndMs: 0,
    ));
    return id;
  }

  const PlaylistManifest manifest = PlaylistManifest(
    id: 'shared-mix',
    title: 'Mix partagé',
    description: '',
    version: 1,
    tags: [],
    vibeStyle: 'oled',
    creatorHandle: 'Alice',
    tracks: [
      ManifestTrackRef(title: 'Digital Love', artist: 'Daft Punk'),
      ManifestTrackRef(title: 'Midnight City', artist: 'M83'),
      ManifestTrackRef(title: 'Intro', artist: 'The xx'),
    ],
  );

  Future<Playlist> importManifest() async {
    final ImportMatchPlan plan = await service.planImport(manifest.tracks);
    return service.importAsNewPlaylist(manifest, plan.autoResolution);
  }

  test('unmatched titles stay in the playlist, greyed, at their original position', () async {
    await addTrack('Digital Love', 'Daft Punk');
    await addTrack('Intro', 'The xx');

    final Playlist imported = await importManifest();
    final List<PlaylistEditorEntry> entries = await playlists.watchEditorEntries(imported.id).first;

    expect(entries.map((e) => e.title), ['Digital Love', 'Midnight City', 'Intro']);
    expect(entries.map((e) => e.isMissing), [false, true, false]);
    expect(imported.originalCreator, 'Alice');
  });

  test('greyed titles are skipped by playback (never part of the ordered playable tracks)', () async {
    await addTrack('Digital Love', 'Daft Punk');
    await addTrack('Intro', 'The xx');

    final Playlist imported = await importManifest();
    final List<Track> playable = await playlists.fetchOrderedTracks(imported.id);

    expect(playable.map((t) => t.title), ['Digital Love', 'Intro']);
  });

  test('adding the missing file to the library un-greys the title in place, without re-importing', () async {
    await addTrack('Digital Love', 'Daft Punk');
    await addTrack('Intro', 'The xx');
    final Playlist imported = await importManifest();

    // Même morceau, nommé autrement dans le fichier ajouté plus tard.
    await addTrack('Midnight City (Official Video)', 'M83');

    final List<PlaylistEditorEntry> entries = await playlists.watchEditorEntries(imported.id).first;
    expect(entries.map((e) => e.isMissing), [false, false, false]);
    expect((await playlists.fetchOrderedTracks(imported.id)).map((t) => t.title),
        ['Digital Love', 'Midnight City (Official Video)', 'Intro']);
  });

  test('the same title by another artist does not un-grey automatically', () async {
    final Playlist imported = await importManifest();

    await addTrack('Midnight City', 'Someone Else');

    final List<PlaylistEditorEntry> entries = await playlists.watchEditorEntries(imported.id).first;
    expect(entries.every((e) => e.isMissing), isTrue);
  });

  test('reordering keeps greyed titles where the user moved them', () async {
    await addTrack('Digital Love', 'Daft Punk');
    await addTrack('Intro', 'The xx');
    final Playlist imported = await importManifest();

    final List<PlaylistEditorEntry> entries = await playlists.watchEditorEntries(imported.id).first;
    await playlists.commitOrder(imported.id, [entries[1], entries[2], entries[0]]);

    final List<PlaylistEditorEntry> reordered = await playlists.watchEditorEntries(imported.id).first;
    expect(reordered.map((e) => e.title), ['Midnight City', 'Intro', 'Digital Love']);
  });

  test('export carries the author, the title and every track (greyed ones included)', () async {
    await addTrack('Digital Love', 'Daft Punk');
    final Playlist imported = await importManifest();

    final Map<String, dynamic> json =
        jsonDecode(await service.exportManifestJson(imported.id, author: 'Bob')) as Map<String, dynamic>;

    expect(json['title'], 'Mix partagé');
    expect(json['author'], 'Bob');
    expect((json['tracks'] as List<dynamic>).map((t) => (t as Map<String, dynamic>)['title']),
        ['Digital Love', 'Midnight City', 'Intro']);
    expect(PlaylistManifest.fromJson(json).creatorHandle, 'Bob');
  });

  test('the update preview ignores naming differences already resolved by matching', () async {
    await addTrack('Digital Love (feat. DJ Test)', 'Daft Punk');
    final Playlist imported = await importManifest();

    final DiffResult diff = await service.computeDiff(
      imported.id,
      const PlaylistManifest(
        id: 'shared-mix',
        title: 'Mix partagé',
        description: '',
        version: 2,
        tags: [],
        vibeStyle: 'oled',
        tracks: [
          ManifestTrackRef(title: 'Digital Love', artist: 'Daft Punk'),
          ManifestTrackRef(title: 'Midnight City', artist: 'M83'),
          ManifestTrackRef(title: 'Teardrop', artist: 'Massive Attack'),
        ],
      ),
    );

    expect(diff.added.map((t) => t.title), ['Teardrop']);
    expect(diff.removed.map((t) => t.title), ['Intro']);
  });

  test('deleting an imported playlist also removes its greyed titles', () async {
    final Playlist imported = await importManifest();

    await playlists.deletePlaylist(imported.id);

    expect(await db.select(db.playlistMissingTracks).get(), isEmpty);
  });
}
