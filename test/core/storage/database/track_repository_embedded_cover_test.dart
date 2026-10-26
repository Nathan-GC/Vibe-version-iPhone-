import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/storage/database/app_database.dart';
import 'package:playlist_app/core/storage/database/track_repository.dart';
import 'package:playlist_app/core/storage/scanner/scanned_track.dart';

/// Pochette intégrée au fichier audio (extraite au scan) : appliquée seulement
/// si le titre n'a pas déjà de pochette, et jamais laissée orpheline sur disque.
void main() {
  late AppDatabase db;
  late TrackRepository repository;
  late Directory tempDir;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repository = TrackRepository(db);
    tempDir = Directory.systemTemp.createTempSync('track_repository_embedded_cover_test');
  });

  tearDown(() async {
    await db.close();
    tempDir.deleteSync(recursive: true);
  });

  File extractedCover(String name) => File('${tempDir.path}/$name')..writeAsBytesSync([1, 2, 3]);

  ScannedTrack scanned({String? coverArtPath, String filePath = '/music/t1.mp3'}) => ScannedTrack(
        id: 't1',
        title: 'Some Title',
        album: '',
        primaryArtist: 'Artist',
        artists: const ['Artist'],
        filePath: filePath,
        durationMs: 180000,
        requiresUserReview: false,
        trimStartMs: 0,
        trimEndMs: 0,
        coverArtPath: coverArtPath,
      );

  group('upsertTrack', () {
    test('applies the extracted cover to a track without cover', () async {
      final File cover = extractedCover('t1_1.jpg');

      await repository.upsertTrack(scanned(coverArtPath: cover.path));

      expect((await repository.findById('t1'))!.coverArtPath, cover.path);
      expect(cover.existsSync(), isTrue);
    });

    test('keeps an existing cover and deletes the extracted file', () async {
      await repository.upsertTrack(scanned());
      await repository.updateCoverArtPath('t1', '/covers/chosen.jpg');
      final File cover = extractedCover('t1_2.jpg');

      await repository.upsertTrack(scanned(coverArtPath: cover.path));

      expect((await repository.findById('t1'))!.coverArtPath, '/covers/chosen.jpg');
      expect(cover.existsSync(), isFalse);
    });

    test('a rescan without embedded cover leaves the stored cover untouched', () async {
      final File cover = extractedCover('t1_1.jpg');
      await repository.upsertTrack(scanned(coverArtPath: cover.path));

      await repository.upsertTrack(scanned());

      expect((await repository.findById('t1'))!.coverArtPath, cover.path);
    });

    test('deletes the extracted file when the track is skipped (same key carried by another file)', () async {
      await repository.upsertTrack(scanned());
      await repository.upsertTrack(ScannedTrack(
        id: 'other',
        title: 'Other',
        album: '',
        primaryArtist: 'Artist',
        artists: const ['Artist'],
        filePath: '/music/other.mp3',
        durationMs: 180000,
        requiresUserReview: false,
        trimStartMs: 0,
        trimEndMs: 0,
      ));
      final File cover = extractedCover('t1_3.jpg');

      // « other » est renommé en « t1 » alors que « t1 » existe déjà : ligne gardée telle quelle.
      await repository.upsertTrack(scanned(coverArtPath: cover.path, filePath: '/music/other.mp3'));

      expect((await repository.findById('t1'))!.coverArtPath, isEmpty);
      expect(cover.existsSync(), isFalse);
    });
  });

  group('relinkFile', () {
    test('applies the extracted cover when the track has none', () async {
      await repository.upsertTrack(scanned());
      final File cover = extractedCover('t1_1.png');

      await repository.relinkFile('t1', scanned(coverArtPath: cover.path, filePath: '/music/new.mp3'));

      final track = (await repository.findById('t1'))!;
      expect(track.filePath, '/music/new.mp3');
      expect(track.coverArtPath, cover.path);
    });

    test('keeps the existing cover and deletes the extracted file', () async {
      await repository.upsertTrack(scanned());
      await repository.updateCoverArtPath('t1', 'https://example.com/art.jpg');
      final File cover = extractedCover('t1_2.png');

      await repository.relinkFile('t1', scanned(coverArtPath: cover.path, filePath: '/music/new.mp3'));

      expect((await repository.findById('t1'))!.coverArtPath, 'https://example.com/art.jpg');
      expect(cover.existsSync(), isFalse);
    });
  });
}
