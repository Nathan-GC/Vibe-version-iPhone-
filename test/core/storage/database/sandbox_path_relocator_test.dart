import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/storage/database/app_database.dart';
import 'package:playlist_app/core/storage/database/sandbox_path_relocator.dart';
import 'package:playlist_app/core/storage/database/track_repository.dart';
import 'package:playlist_app/core/storage/scanner/scanned_track.dart';

const String _oldRoot = '/var/mobile/Containers/Data/Application/11111111-2222-3333-4444-555555555555';
const String _newRoot = '/var/mobile/Containers/Data/Application/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE';

void main() {
  group('containerRootOf / relocate', () {
    test('extracts the app container root from device and simulator paths', () {
      expect(SandboxPathRelocator.containerRootOf('$_oldRoot/Documents/Music/AppFolder/a.mp3'), _oldRoot);
      const String simulator = '/Users/me/Library/Developer/CoreSimulator/Devices/'
          '0F0F0F0F-1111-2222-3333-444444444444/data/Containers/Data/Application/'
          '99999999-8888-7777-6666-555555555555';
      expect(SandboxPathRelocator.containerRootOf('$simulator/Documents/x.m4a'), simulator);
    });

    test('ignores empty values, remote URLs and paths outside an app container', () {
      expect(SandboxPathRelocator.relocate('', _newRoot), isNull);
      expect(SandboxPathRelocator.relocate('https://is1-ssl.mzstatic.com/cover.jpg', _newRoot), isNull);
      expect(SandboxPathRelocator.relocate('/storage/emulated/0/Music/song.mp3', _newRoot), isNull);
    });

    test('rewrites a stale container prefix and leaves current ones untouched', () {
      expect(
        SandboxPathRelocator.relocate('$_oldRoot/Documents/Music/AppFolder/Daft Punk-One More Time.m4a', _newRoot),
        '$_newRoot/Documents/Music/AppFolder/Daft Punk-One More Time.m4a',
      );
      expect(SandboxPathRelocator.relocate('$_newRoot/Documents/a.mp3', _newRoot), isNull);
      // Alias `/private/var/...` du même conteneur : réaligné sur la forme courante.
      expect(SandboxPathRelocator.relocate('/private$_newRoot/Documents/a.mp3', _newRoot), '$_newRoot/Documents/a.mp3');
    });
  });

  group('relocateTo', () {
    late AppDatabase db;
    late TrackRepository repository;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      repository = TrackRepository(db);
    });

    tearDown(() => db.close());

    Future<void> insertTrack(String id, String filePath) => repository.upsertTrack(ScannedTrack(
          id: id,
          title: 'Title $id',
          album: '',
          primaryArtist: 'Artist',
          artists: const ['Artist'],
          filePath: filePath,
          durationMs: 180000,
          requiresUserReview: false,
          trimStartMs: 0,
          trimEndMs: 0,
        ));

    test('moves every stored path (tracks and playlists) into the current container', () async {
      await insertTrack('a', '$_oldRoot/Documents/Music/AppFolder/a.mp3');
      await (db.update(db.tracks)..where((t) => t.id.equals('a'))).write(
        const TracksCompanion(coverArtPath: Value('$_oldRoot/Documents/Music/AppFolder/track_covers/a.jpg')),
      );
      await db.into(db.playlists).insert(PlaylistsCompanion.insert(
            id: 'p1',
            title: 'Soirée',
            coverImagePath: const Value('$_oldRoot/Documents/Music/AppFolder/playlist_covers/p1.jpg'),
            customBackgroundImagePath: const Value('$_oldRoot/Documents/Music/AppFolder/vibe_backgrounds/p1.png'),
            customBackgroundVideoPath: const Value('$_oldRoot/Documents/Music/AppFolder/vibe_backgrounds/p1.mov'),
          ));

      final int updated = await SandboxPathRelocator(db).relocateTo(_newRoot);

      expect(updated, 2);
      final Track track = await (db.select(db.tracks)..where((t) => t.id.equals('a'))).getSingle();
      expect(track.filePath, '$_newRoot/Documents/Music/AppFolder/a.mp3');
      expect(track.coverArtPath, '$_newRoot/Documents/Music/AppFolder/track_covers/a.jpg');
      final Playlist playlist = await (db.select(db.playlists)..where((t) => t.id.equals('p1'))).getSingle();
      expect(playlist.coverImagePath, '$_newRoot/Documents/Music/AppFolder/playlist_covers/p1.jpg');
      expect(playlist.customBackgroundImagePath, '$_newRoot/Documents/Music/AppFolder/vibe_backgrounds/p1.png');
      expect(playlist.customBackgroundVideoPath, '$_newRoot/Documents/Music/AppFolder/vibe_backgrounds/p1.mov');
    });

    test('is idempotent: a second pass changes nothing', () async {
      await insertTrack('a', '$_oldRoot/Documents/a.mp3');

      await SandboxPathRelocator(db).relocateTo(_newRoot);
      final int secondPass = await SandboxPathRelocator(db).relocateTo(_newRoot);

      expect(secondPass, 0);
    });

    test('keeps going when a relocated path already exists (unique file_path)', () async {
      await insertTrack('stale', '$_oldRoot/Documents/a.mp3');
      await insertTrack('current', '$_newRoot/Documents/a.mp3');
      await insertTrack('other', '$_oldRoot/Documents/b.mp3');

      await SandboxPathRelocator(db).relocateTo(_newRoot);

      final Track other = await (db.select(db.tracks)..where((t) => t.id.equals('other'))).getSingle();
      expect(other.filePath, '$_newRoot/Documents/b.mp3');
      final Track current = await (db.select(db.tracks)..where((t) => t.id.equals('current'))).getSingle();
      expect(current.filePath, '$_newRoot/Documents/a.mp3');
    });
  });
}
