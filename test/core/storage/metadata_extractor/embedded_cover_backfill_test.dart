import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/storage/database/app_database.dart';
import 'package:playlist_app/core/storage/database/track_repository.dart';
import 'package:playlist_app/core/storage/metadata_extractor/embedded_cover_backfill.dart';
import 'package:playlist_app/core/storage/metadata_extractor/embedded_cover_extractor.dart';
import 'package:playlist_app/core/storage/metadata_extractor/metadata_extractor.dart';
import 'package:playlist_app/core/storage/metadata_extractor/raw_track_metadata.dart';
import 'package:playlist_app/core/storage/scanner/scanned_track.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeMetadataExtractor extends MetadataExtractor {
  _FakeMetadataExtractor(this.codecByPath);
  final Map<String, String?> codecByPath;

  @override
  Future<RawTrackMetadata> extract(File file) async {
    if (file.path.endsWith('boom.mp3')) throw StateError('ffprobe KO');
    return RawTrackMetadata(embeddedCoverCodec: codecByPath[file.path]);
  }
}

class _FakeCoverExtractor extends EmbeddedCoverExtractor {
  _FakeCoverExtractor(this.dir);
  final Directory dir;
  final List<String> extractedFor = [];

  @override
  Future<String?> extract(File audio, {required String trackId, required String codec}) async {
    extractedFor.add(trackId);
    return (File('${dir.path}/${trackId}_1.jpg')..writeAsBytesSync([1])).path;
  }
}

void main() {
  late AppDatabase db;
  late TrackRepository repository;
  late Directory tempDir;
  late _FakeCoverExtractor covers;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repository = TrackRepository(db);
    tempDir = Directory.systemTemp.createTempSync('embedded_cover_backfill_test');
    covers = _FakeCoverExtractor(tempDir);
  });

  tearDown(() async {
    await db.close();
    tempDir.deleteSync(recursive: true);
  });

  /// Titre indexé dont le fichier existe (sauf [fileExists] faux).
  Future<String> addTrack(String id, {bool fileExists = true}) async {
    final String path = '${tempDir.path}/$id.mp3';
    if (fileExists) File(path).writeAsStringSync('x');
    await repository.upsertTrack(ScannedTrack(
      id: id,
      title: id,
      album: '',
      primaryArtist: 'A',
      artists: const ['A'],
      filePath: path,
      durationMs: 180000,
      requiresUserReview: false,
      trimStartMs: 0,
      trimEndMs: 0,
    ));
    return path;
  }

  EmbeddedCoverBackfill backfill(Map<String, String?> codecs, {bool firstLaunch = false}) => EmbeddedCoverBackfill(
        repository: repository,
        metadataExtractor: _FakeMetadataExtractor(codecs),
        coverExtractor: covers,
        isFirstLaunch: () async => firstLaunch,
      );

  Future<bool> flagSet() async =>
      (await SharedPreferences.getInstance()).getBool(EmbeddedCoverBackfill.doneFlagKey) ?? false;

  test('applies the embedded cover of tracks without cover, then sets the flag', () async {
    final String path = await addTrack('t1');

    await backfill({path: 'mjpeg'}).runOnce();

    expect((await repository.findById('t1'))!.coverArtPath, '${tempDir.path}/t1_1.jpg');
    expect(await flagSet(), isTrue);
  });

  test('ignores tracks that already have a cover', () async {
    final String path = await addTrack('t1');
    await repository.updateCoverArtPath('t1', '/covers/chosen.jpg');

    await backfill({path: 'mjpeg'}).runOnce();

    expect(covers.extractedFor, isEmpty);
    expect((await repository.findById('t1'))!.coverArtPath, '/covers/chosen.jpg');
  });

  test('ignores tracks whose file is missing, and files without embedded cover', () async {
    await addTrack('gone', fileExists: false);
    final String plain = await addTrack('plain');

    await backfill({plain: null}).runOnce();

    expect(covers.extractedFor, isEmpty);
    expect(await flagSet(), isTrue);
  });

  test('an error on one file does not stop the pass', () async {
    await addTrack('boom');
    final String ok = await addTrack('ok');

    await backfill({ok: 'png'}).runOnce();

    expect(covers.extractedFor, ['ok']);
    expect(await flagSet(), isTrue);
  });

  test('runs only once: the second call does nothing', () async {
    final String first = await addTrack('t1');
    await backfill({first: 'mjpeg'}).runOnce();
    final String second = await addTrack('t2');

    await backfill({second: 'mjpeg'}).runOnce();

    expect(covers.extractedFor, ['t1']);
    expect((await repository.findById('t2'))!.coverArtPath, isEmpty);
  });

  test('does nothing on first launch (onboarding scan extracts) and leaves the flag unset', () async {
    final String path = await addTrack('t1');

    await backfill({path: 'mjpeg'}, firstLaunch: true).runOnce();

    expect(covers.extractedFor, isEmpty);
    expect(await flagSet(), isFalse);
  });
}
