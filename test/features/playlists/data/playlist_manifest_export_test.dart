import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/identity/track_key.dart';
import 'package:playlist_app/core/identity/track_match_key.dart';
import 'package:playlist_app/core/playlist_manifest/playlist_manifest.dart';
import 'package:playlist_app/core/storage/database/app_database.dart';
import 'package:playlist_app/core/storage/database/track_repository.dart';
import 'package:playlist_app/core/storage/scanner/scanned_track.dart';
import 'package:playlist_app/features/playlists/data/playlist_manifest_service.dart';
import 'package:playlist_app/features/playlists/data/playlist_repository.dart';

void main() {
  late AppDatabase db;
  late TrackRepository tracks;
  late PlaylistManifestService service;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    tracks = TrackRepository(db);
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

  Future<void> insertPlaylist(String id, String title) =>
      db.into(db.playlists).insert(PlaylistsCompanion.insert(id: id, title: title));

  Future<void> placeTrack(String playlistId, String trackId, int position) => db
      .into(db.playlistTracks)
      .insert(PlaylistTracksCompanion.insert(playlistId: playlistId, trackId: trackId, position: position));

  Future<void> placeMissing(String playlistId, int position, String title, String artist) => db
      .into(db.playlistMissingTracks)
      .insert(PlaylistMissingTracksCompanion.insert(
        playlistId: playlistId,
        position: position,
        title: title,
        artist: artist,
        sanitizedKey: buildSanitizedKey(title: title, album: '', primaryArtist: artist),
        matchKey: buildTrackMatchKey(title: title, artist: artist),
      ));

  List<Map<String, dynamic>> trackJsons(PlaylistManifest manifest) =>
      (manifest.toJson()['tracks'] as List<dynamic>).cast<Map<String, dynamic>>();

  test('"Tous les titres importés" : chaque titre porte son id, dans l\'ordre affiché', () async {
    // Chaque morceau importé est relié à cette playlist, à la suite (upsertTrack).
    final String b = await addTrack('Bravo', 'Alpha');
    final String a = await addTrack('Alpha', 'Zed');

    final PlaylistManifest manifest = await service.buildManifest(kAllImportedPlaylistId);

    expect(manifest.tracks.map((t) => t.id), [b, a]);
    expect(trackJsons(manifest).map((t) => t['id']), [b, a]);
    expect(trackJsons(manifest).map((t) => t['title']), ['Bravo', 'Alpha']);
  });

  test('playlist normale : aucun id, clé absente du JSON des titres', () async {
    await insertPlaylist('mix', 'Mix');
    final String id = await addTrack('Halo', 'Beyoncé');
    await placeTrack('mix', id, 0);
    await placeMissing('mix', 1, 'Introuvable', 'Nul');

    final PlaylistManifest manifest = await service.buildManifest('mix');

    expect(manifest.tracks.map((t) => t.title), ['Halo', 'Introuvable']);
    expect(manifest.tracks.every((t) => t.id == null), isTrue);
    expect(trackJsons(manifest).every((t) => !t.containsKey('id')), isTrue);
  });

  test('titres grisés de "Tous les titres importés" : jamais d\'id', () async {
    final String id = await addTrack('Halo', 'Beyoncé');
    await placeMissing(kAllImportedPlaylistId, 1, 'Introuvable', 'Nul');

    final PlaylistManifest manifest = await service.buildManifest(kAllImportedPlaylistId);

    expect(manifest.tracks.map((t) => t.id), [id, null]);
    expect(trackJsons(manifest)[1].containsKey('id'), isFalse);
  });

  test('"Titres likés" est exportable comme une playlist ordinaire', () async {
    await insertPlaylist(kLikedPlaylistId, 'Titres likés');
    final String id = await addTrack('Halo', 'Beyoncé');
    await placeTrack(kLikedPlaylistId, id, 0);

    final String json = await service.exportManifestJson(kLikedPlaylistId, author: 'Nathan');
    final PlaylistManifest manifest = PlaylistManifest.fromJson(_decode(json));

    expect(manifest.title, 'Titres likés');
    expect(manifest.creatorHandle, 'Nathan');
    expect(manifest.tracks.map((t) => t.title), ['Halo']);
    // Export exploitable : le titre est relu, l'id ne sert qu'au renommage rapide.
    expect(manifest.tracks.first.id, isNull);
  });

  test('"Tous les titres importés" exporté en JSON contient les ids', () async {
    final String id = await addTrack('Halo', 'Beyoncé');

    final String json = await service.exportManifestJson(kAllImportedPlaylistId, author: 'Nathan');

    expect(json, contains('"id": "$id"'));
    expect(PlaylistManifest.fromJson(_decode(json)).tracks.first.id, id);
  });
}

Map<String, dynamic> _decode(String json) => (jsonDecode(json) as Map).cast<String, dynamic>();
