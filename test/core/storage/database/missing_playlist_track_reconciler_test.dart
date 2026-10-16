import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/identity/track_key.dart';
import 'package:playlist_app/core/identity/track_match_key.dart';
import 'package:playlist_app/core/storage/database/app_database.dart';
import 'package:playlist_app/core/storage/database/track_repository.dart';
import 'package:playlist_app/core/storage/scanner/scanned_track.dart';

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<void> import(String title, String artist, {String album = ''}) {
    final String id = buildSanitizedKey(title: title, album: album, primaryArtist: artist);
    return TrackRepository(db).upsertTrack(ScannedTrack(
      id: id,
      title: title,
      album: album,
      primaryArtist: artist,
      artists: [artist],
      filePath: '/music/$id.mp3',
      durationMs: 200000,
      requiresUserReview: false,
      trimStartMs: 0,
      trimEndMs: 0,
    ));
  }

  test('a greyed non-Latin title is only restored by that very title, never by another of the artist', () async {
    await db.into(db.playlists).insert(PlaylistsCompanion.insert(id: 'p', title: 'J-Pop'));
    await db.into(db.playlistMissingTracks).insert(PlaylistMissingTracksCompanion.insert(
          playlistId: 'p',
          position: 4,
          title: '夜に駆ける',
          artist: 'YOASOBI',
          sanitizedKey: buildSanitizedKey(title: '夜に駆ける', primaryArtist: 'YOASOBI'),
          matchKey: buildTrackMatchKey(title: '夜に駆ける', artist: 'YOASOBI'),
        ));
    Future<List<(String, int)>> inPlaylist() async => [
          for (final PlaylistTrack row
              in await (db.select(db.playlistTracks)..where((t) => t.playlistId.equals('p'))).get())
            (row.trackId, row.position)
        ];

    await import('アイドル', 'YOASOBI');
    expect(await inPlaylist(), isEmpty);
    expect(await db.select(db.playlistMissingTracks).get(), hasLength(1), reason: 'toujours grisé');

    await import('夜に駆ける', 'YOASOBI', album: 'THE BOOK'); // autre album : rapproché par titre + artiste
    expect(await inPlaylist(), [(buildSanitizedKey(title: '夜に駆ける', album: 'THE BOOK', primaryArtist: 'YOASOBI'), 4)]);
    expect(await db.select(db.playlistMissingTracks).get(), isEmpty);
  });
}
