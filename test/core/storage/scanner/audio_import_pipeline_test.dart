import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:playlist_app/core/storage/database/app_database.dart';
import 'package:playlist_app/core/storage/database/track_repository.dart';
import 'package:playlist_app/core/storage/filename_sanitizer/filename_sanitizer.dart';
import 'package:playlist_app/core/storage/metadata_extractor/metadata_extractor.dart';
import 'package:playlist_app/core/storage/metadata_extractor/raw_track_metadata.dart';
import 'package:playlist_app/core/storage/scanner/audio_import_pipeline.dart';
import 'package:playlist_app/core/storage/scanner/library_scan_service.dart';
import 'package:playlist_app/core/storage/storage_manager/imported_audio_file.dart';
import 'package:playlist_app/core/storage/storage_manager/storage_manager_service.dart';

/// Copie dans un dossier temporaire au lieu de /Music/AppFolder (plugin
/// natif indisponible hors device), comme le vrai importAudioFile.
class _FakeStorageManager extends StorageManagerService {
  _FakeStorageManager(this.appFolder);
  final Directory appFolder;

  @override
  Future<ImportedAudioFile> importAudioFile(File sourceFile, {bool moveFile = false}) async {
    final File copy = await sourceFile.copy(p.join(appFolder.path, 'Unknown-${p.basename(sourceFile.path)}'));
    return ImportedAudioFile(
      file: copy,
      sanitizedFromOriginalName: FilenameSanitizer().sanitizeFilename(p.basename(sourceFile.path)),
    );
  }
}

/// Évite ffprobe/ffmpeg : `durationMs` null court-circuite aussi le détecteur
/// de silence (voir LibraryScanService._process).
class _FakeMetadataExtractor extends MetadataExtractor {
  _FakeMetadataExtractor({this.durationMs, this.error});
  final int? durationMs;
  final Object? error;

  @override
  Future<RawTrackMetadata> extract(File file) async {
    if (error != null) throw error!;
    return RawTrackMetadata(title: 'One More Time', artists: const ['Daft Punk'], durationMs: durationMs);
  }
}

void main() {
  late Directory sourceDir;
  late Directory appFolder;
  late AppDatabase db;

  setUp(() {
    sourceDir = Directory.systemTemp.createTempSync('vibe_import_source');
    appFolder = Directory.systemTemp.createTempSync('vibe_import_app');
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
    sourceDir.deleteSync(recursive: true);
    appFolder.deleteSync(recursive: true);
  });

  AudioImportPipeline pipeline(_FakeMetadataExtractor extractor) => AudioImportPipeline(
        storageManager: _FakeStorageManager(appFolder),
        scanService: LibraryScanService(metadataExtractor: extractor),
        trackRepository: TrackRepository(db),
      );

  File sourceFile() => File(p.join(sourceDir.path, 'Daft Punk - One More Time.mp3'))..writeAsBytesSync([1, 2, 3]);

  test('a file shorter than 30 s is refused and its private copy is deleted (choix 3-A)', () async {
    final File source = sourceFile();

    final track = await pipeline(_FakeMetadataExtractor(durationMs: 10000)).importFile(source);

    expect(track, isNull);
    expect(appFolder.listSync(), isEmpty, reason: 'aucune copie ne doit encombrer le stockage de l\'app');
    expect(await db.select(db.tracks).get(), isEmpty);
    expect(source.existsSync(), isTrue, reason: 'le fichier d\'origine de l\'utilisateur n\'est jamais touché');
  });

  test('an accepted file keeps its copy and is saved in the library', () async {
    final track = await pipeline(_FakeMetadataExtractor()).importFile(sourceFile());

    expect(track, isNotNull);
    expect(appFolder.listSync(), hasLength(1));
    final Track saved = await db.select(db.tracks).getSingle();
    expect(saved.filePath, appFolder.listSync().single.path);
  });

  test('a processing failure deletes the copy and still reports the original error', () async {
    final File source = sourceFile();

    await expectLater(
      pipeline(_FakeMetadataExtractor(error: const FileSystemException('corrupt'))).importFile(source),
      throwsA(isA<FileSystemException>()),
    );
    expect(appFolder.listSync(), isEmpty);
    expect(source.existsSync(), isTrue);
  });
}
