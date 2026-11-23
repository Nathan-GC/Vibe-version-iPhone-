import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/identity/track_key.dart';
import 'package:playlist_app/core/playlist_manifest/manifest_track_ref.dart';
import 'package:playlist_app/core/playlist_manifest/playlist_manifest.dart';
import 'package:playlist_app/core/storage/database/app_database.dart';
import 'package:playlist_app/core/storage/database/track_repository.dart';
import 'package:playlist_app/core/storage/scanner/scanned_track.dart';
import 'package:playlist_app/core/theme/vibe_engine/vibe_engine.dart';
import 'package:playlist_app/features/diff/domain/diff_result.dart';
import 'package:playlist_app/features/playlists/data/drift_playlist_repository.dart';
import 'package:playlist_app/features/playlists/data/playlist_manifest_service.dart';
import 'package:playlist_app/features/playlists/data/playlist_repository.dart';
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

  group('computeDiff : contentChanged / orderChanged (même version)', () {
    Future<Playlist> forkOfThree() async {
      await addTrack('Digital Love', 'Daft Punk');
      await addTrack('Midnight City', 'M83');
      await addTrack('Intro', 'The xx');
      return importManifest();
    }

    PlaylistManifest withTracks(PlaylistManifest base, List<ManifestTrackRef> tracks) => PlaylistManifest(
          id: base.id,
          title: base.title,
          description: base.description,
          version: base.version,
          tags: base.tags,
          vibeStyle: base.vibeStyle,
          creatorHandle: base.creatorHandle,
          originalCreator: base.originalCreator,
          tracks: tracks,
        );

    test('an export compared with itself has no content change', () async {
      final Playlist fork = await forkOfThree();
      final PlaylistManifest exported = await service.buildManifest(fork.id, author: 'Moi');

      final DiffResult diff = await service.computeDiff(fork.id, exported);

      expect(diff.contentChanged, isFalse);
      expect(diff.orderChanged, isFalse);
    });

    test('same version, reversed order only: contentChanged without added or removed', () async {
      final Playlist fork = await forkOfThree();
      final PlaylistManifest exported = await service.buildManifest(fork.id, author: 'Moi');

      final DiffResult diff =
          await service.computeDiff(fork.id, withTracks(exported, exported.tracks.reversed.toList()));

      expect(diff.contentChanged, isTrue);
      expect(diff.orderChanged, isTrue);
      expect(diff.added, isEmpty);
      expect(diff.removed, isEmpty);
      expect(diff.hasChanges, isFalse);
    });

    test('same version, one added title: contentChanged, order unchanged', () async {
      final Playlist fork = await forkOfThree();
      final PlaylistManifest exported = await service.buildManifest(fork.id, author: 'Moi');

      final DiffResult diff = await service.computeDiff(
        fork.id,
        withTracks(exported, [...exported.tracks, const ManifestTrackRef(title: 'Teardrop', artist: 'Massive Attack')]),
      );

      expect(diff.contentChanged, isTrue);
      expect(diff.orderChanged, isFalse);
      expect(diff.added.map((t) => t.title), ['Teardrop']);
    });

    test('a duplicate title in the manifest does not count as a change', () async {
      final Playlist fork = await forkOfThree();
      final PlaylistManifest exported = await service.buildManifest(fork.id, author: 'Moi');

      final DiffResult diff = await service.computeDiff(
        fork.id,
        withTracks(exported, [...exported.tracks, exported.tracks.first]),
      );

      expect(diff.contentChanged, isFalse);
    });

    test('an identical greyed title at its place is not a change', () async {
      await addTrack('Digital Love', 'Daft Punk');
      await addTrack('Intro', 'The xx');
      final Playlist fork = await importManifest(); // « Midnight City » grisé
      final PlaylistManifest exported = await service.buildManifest(fork.id, author: 'Moi');

      final DiffResult diff = await service.computeDiff(fork.id, exported);

      expect(exported.tracks.map((t) => t.title), contains('Midnight City'));
      expect(diff.contentChanged, isFalse);
    });

    test('a naming difference already resolved by matching is not a change', () async {
      await addTrack('Digital Love (feat. DJ Test)', 'Daft Punk');
      final Playlist fork = await importManifest();

      final DiffResult diff = await service.computeDiff(fork.id, manifest);

      expect(diff.contentChanged, isFalse);
    });
  });

  group('re-importing an exported playlist updates it instead of copying it', () {
    Future<PlaylistManifest> reexportEnriched(String playlistId) async {
      final PlaylistManifest exported = await service.buildManifest(playlistId, author: 'Moi');
      // Enrichi hors de l'app : un titre ajouté, ordre inversé, version + 1.
      return PlaylistManifest(
        id: exported.id,
        title: exported.title,
        description: exported.description,
        version: exported.version + 1,
        tags: exported.tags,
        vibeStyle: exported.vibeStyle,
        creatorHandle: exported.creatorHandle,
        originalCreator: exported.originalCreator,
        tracks: [
          const ManifestTrackRef(title: 'Teardrop', artist: 'Massive Attack'),
          ...exported.tracks.reversed,
        ],
      );
    }

    test('a fork (id "<source>-fork-<ts>") is found by its own id and updated in place', () async {
      await addTrack('Digital Love', 'Daft Punk');
      await addTrack('Intro', 'The xx');
      await addTrack('Teardrop', 'Massive Attack');
      final Playlist fork = await importManifest();
      final int playlistCountBefore = (await db.select(db.playlists).get()).length;

      final PlaylistManifest enriched = await reexportEnriched(fork.id);
      expect(enriched.id, fork.id);

      final Playlist? target = await playlists.findImportTarget(enriched.id);
      expect(target?.id, fork.id);

      final ImportMatchPlan plan = await service.planImport(enriched.tracks);
      final Playlist updated = await service.applyUpdate(target!.id, enriched, plan.autoResolution);

      expect((await db.select(db.playlists).get()).length, playlistCountBefore);
      expect(updated.version, fork.version + 1);
      final List<PlaylistEditorEntry> entries = await playlists.watchEditorEntries(fork.id).first;
      expect(entries.map((e) => e.title), ['Teardrop', 'Intro', 'Midnight City', 'Digital Love']);
      expect(entries.map((e) => e.isMissing), [false, false, true, false]);
    });

    test('a playlist created in the app (id "local-<ts>") is found by its own id', () async {
      final Playlist local = await playlists.createEmpty(title: 'Ma playlist', vibeStyle: VibePreset.minimal);

      expect((await playlists.findImportTarget(local.id))?.id, local.id);
    });

    test('the source manifest id still finds the fork, even when the source was forked twice', () async {
      await importManifest();
      await importManifest();

      final Playlist? target = await playlists.findImportTarget(manifest.id);
      expect(target?.sourceManifestId, manifest.id);
    });

    test('an unknown manifest id finds nothing (new import)', () async {
      await importManifest();

      expect(await playlists.findImportTarget('someone-else-mix'), isNull);
    });

    test('an export of an automatic playlist never overwrites it', () async {
      await db.into(db.playlists).insertOnConflictUpdate(
            PlaylistsCompanion.insert(id: kLikedPlaylistId, title: 'Titres likés'),
          );

      expect(await playlists.findImportTarget(kLikedPlaylistId), isNull);
      expect(await playlists.findImportTarget(kAllImportedPlaylistId), isNull);
    });
  });
}
