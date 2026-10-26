import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:playlist_app/core/storage/database/app_database.dart';
import 'package:playlist_app/core/storage/database/blacklist_repository.dart';
import 'package:playlist_app/core/storage/database/track_repository.dart';
import 'package:playlist_app/core/storage/metadata_extractor/metadata_extractor.dart';
import 'package:playlist_app/core/storage/metadata_extractor/raw_track_metadata.dart';
import 'package:playlist_app/core/storage/scanner/library_scan_service.dart';
import 'package:playlist_app/core/storage/scanner/scanned_track.dart';
import 'package:playlist_app/core/storage/storage_manager/imported_audio_file.dart';
import 'package:playlist_app/core/storage/storage_manager/storage_manager_service.dart';
import 'package:playlist_app/features/diff/data/missing_track_resolver.dart';

/// Si la copie était tentée, ce faux la ferait échouer : le test prouve donc
/// aussi qu'aucun import n'a lieu.
class _NoCopyStorageManager extends StorageManagerService {
  @override
  Future<ImportedAudioFile> importAudioFile(File sourceFile, {bool moveFile = false}) =>
      throw StateError('aucune copie attendue');
}

class _FakeExtractor extends MetadataExtractor {
  @override
  Future<RawTrackMetadata> extract(File file) async =>
      const RawTrackMetadata(title: 'One More Time', artists: ['Daft Punk']);
}

void main() {
  test('importFromDevice returns the existing track when it is already in the library', () async {
    final AppDatabase db = AppDatabase.forTesting(NativeDatabase.memory());
    final Directory dir = Directory.systemTemp.createTempSync('vibe_resolver');
    addTearDown(() async {
      await db.close();
      dir.deleteSync(recursive: true);
    });
    final File existingFile = File(p.join(dir.path, 'existing.mp3'))..writeAsBytesSync([1]);
    final File picked = File(p.join(dir.path, 'Daft Punk - One More Time.mp3'))..writeAsBytesSync([2]);
    final TrackRepository tracks = TrackRepository(db);
    await tracks.upsertTrack(ScannedTrack(
      id: 'one-more-time__daft-punk',
      title: 'One More Time',
      album: '',
      primaryArtist: 'Daft Punk',
      artists: const ['Daft Punk'],
      filePath: existingFile.path,
      durationMs: 320000,
      requiresUserReview: false,
      trimStartMs: 0,
      trimEndMs: 0,
    ));

    final MissingTrackResolver resolver = MissingTrackResolver(
      _NoCopyStorageManager(),
      LibraryScanService(metadataExtractor: _FakeExtractor()),
      tracks,
      BlacklistRepository(db),
    );

    final Track? result = await resolver.importFromDevice(picked);

    expect(result?.id, 'one-more-time__daft-punk');
    expect(result?.filePath, existingFile.path);
  });
}
