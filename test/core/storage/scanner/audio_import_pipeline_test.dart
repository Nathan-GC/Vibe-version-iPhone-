import 'dart:io';

import 'package:drift/drift.dart' show OrderingTerm, Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:playlist_app/core/storage/database/app_database.dart';
import 'package:playlist_app/core/storage/database/blacklist_repository.dart';
import 'package:playlist_app/core/storage/database/track_repository.dart';
import 'package:playlist_app/core/storage/filename_sanitizer/filename_sanitizer.dart';
import 'package:playlist_app/core/storage/metadata_extractor/metadata_extractor.dart';
import 'package:playlist_app/core/storage/metadata_extractor/raw_track_metadata.dart';
import 'package:playlist_app/core/storage/scanner/audio_import_pipeline.dart';
import 'package:playlist_app/core/storage/scanner/library_scan_service.dart';
import 'package:playlist_app/core/storage/scanner/scanned_track.dart';
import 'package:playlist_app/core/storage/silence_trimmer/silence_trimmer.dart';
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

/// Pas de FFmpeg hors device : quand la durée est connue, le scan lance le
/// détecteur de silence (voir LibraryScanService._process).
class _NoSilenceTrimmer extends SilenceTrimmerService {
  @override
  Future<TrimResult> detect(String filePath, {required int durationMs}) async =>
      const TrimResult(trimStartMs: 0, trimEndMs: 0);
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

  AudioImportPipeline pipeline(_FakeMetadataExtractor extractor, {BlacklistRepository? blacklist}) =>
      AudioImportPipeline(
        storageManager: _FakeStorageManager(appFolder),
        scanService: LibraryScanService(metadataExtractor: extractor, silenceTrimmer: _NoSilenceTrimmer()),
        trackRepository: TrackRepository(db),
        blacklistRepository: blacklist ?? BlacklistRepository(db),
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

  group('P1 — a blacklisted title is refused before any copy', () {
    // Clé du fichier source : One More Time / sans album / Daft Punk.
    const String sourceKey = 'one-more-time__daft-punk';

    ScannedTrack hidden({required String id, String album = '', required String path}) => ScannedTrack(
          id: id,
          title: 'One More Time',
          album: album,
          primaryArtist: 'Daft Punk',
          artists: const ['Daft Punk'],
          filePath: path,
          durationMs: 320000,
          requiresUserReview: false,
          trimStartMs: 0,
          trimEndMs: 0,
        );

    /// Titre en bibliothèque (album Discovery : autre clé que le fichier
    /// source), placé dans une playlist puis masqué.
    Future<BlacklistRepository> blacklistLibraryTrack() async {
      final BlacklistRepository blacklist = BlacklistRepository(db, fileExists: (_) async => true);
      await TrackRepository(db)
          .upsertTrack(hidden(id: 'omt_discovery_daft-punk', album: 'Discovery', path: '/music/omt.mp3'));
      await db.into(db.playlists).insert(PlaylistsCompanion.insert(id: 'p', title: 'Mix'));
      await db.into(db.playlistTracks).insert(
            PlaylistTracksCompanion.insert(playlistId: 'p', trackId: 'omt_discovery_daft-punk', position: 0),
          );
      final Track track = (await TrackRepository(db).findById('omt_discovery_daft-punk'))!;
      await blacklist.blacklist([track], reason: BlacklistReason.manual);
      return blacklist;
    }

    test('same key (file hidden from the device)', () async {
      await BlacklistRepository(db).hideFiles([hidden(id: sourceKey, path: '/cache/file_picker/omt.mp3')]);
      final File source = sourceFile();

      await expectLater(
        pipeline(_FakeMetadataExtractor()).importFile(source),
        throwsA(isA<BlacklistedImportException>()),
      );
      expect(appFolder.listSync(), isEmpty, reason: 'rien n\'est copié dans le dossier privé');
      expect(await db.select(db.tracks).get(), isEmpty);
      expect(source.existsSync(), isTrue);
    });

    test('same title + primary artist, other album', () async {
      final BlacklistRepository blacklist = await blacklistLibraryTrack();

      await expectLater(
        pipeline(_FakeMetadataExtractor(), blacklist: blacklist).importFile(sourceFile()),
        throwsA(isA<BlacklistedImportException>().having((e) => e.entry.filePath, 'entry', '/music/omt.mp3')),
      );
      expect(appFolder.listSync(), isEmpty);
    });

    test('"Restaurer" brings the hidden track back to its playlist, without copying the picked file', () async {
      final BlacklistRepository blacklist = await blacklistLibraryTrack();
      final AudioImportPipeline importer = pipeline(_FakeMetadataExtractor(), blacklist: blacklist);
      final File source = sourceFile();
      late BlacklistedTrack entry;
      try {
        await importer.importFile(source);
      } on BlacklistedImportException catch (blocked) {
        entry = blocked.entry;
      }

      expect(await importer.restoreBlacklisted(source, entry), 'omt_discovery_daft-punk');

      expect(appFolder.listSync(), isEmpty);
      expect(await db.select(db.blacklistedTracks).get(), isEmpty);
      final List<PlaylistTrack> links = await db.select(db.playlistTracks).get();
      expect(links.where((l) => l.playlistId == 'p').map((l) => (l.trackId, l.position)), [
        ('omt_discovery_daft-punk', 0),
      ]);
    });

    test('"Restaurer" on a file hidden before any import imports the picked file', () async {
      final BlacklistRepository blacklist = BlacklistRepository(db);
      await blacklist.hideFiles([hidden(id: sourceKey, path: '/cache/file_picker/omt.mp3')]);
      final BlacklistedTrack entry = (await db.select(db.blacklistedTracks).get()).single;

      expect(await pipeline(_FakeMetadataExtractor(), blacklist: blacklist).restoreBlacklisted(sourceFile(), entry),
          sourceKey);

      expect(appFolder.listSync(), hasLength(1));
      expect((await db.select(db.tracks).getSingle()).id, sourceKey);
      expect(await db.select(db.blacklistedTracks).get(), isEmpty);
    });
  });

  group('AN-28 — same identity, different recording', () {
    const String key = 'one-more-time__daft-punk';

    /// Titre déjà en base : 320 s, fichier présent.
    Future<File> seedPresent() async {
      final File present = File(p.join(sourceDir.path, 'original.mp3'))..writeAsBytesSync([9]);
      await TrackRepository(db).upsertTrack(ScannedTrack(
        id: key,
        title: 'One More Time',
        album: '',
        primaryArtist: 'Daft Punk',
        artists: const ['Daft Punk'],
        filePath: present.path,
        durationMs: 320000,
        requiresUserReview: false,
        trimStartMs: 0,
        trimEndMs: 0,
      ));
      return present;
    }

    test('duration within 2 s: same recording, still "already in the library"', () async {
      await seedPresent();

      await expectLater(
        pipeline(_FakeMetadataExtractor(durationMs: 322000)).importFile(sourceFile()),
        throwsA(isA<AlreadyInLibraryImportException>().having((e) => e.existing.id, 'existing', key)),
      );

      expect(appFolder.listSync(), isEmpty);
      expect(await db.select(db.tracks).get(), hasLength(1));
    });

    test('duration 60 s apart: another version, imported under a variant id, the existing row untouched', () async {
      final File present = await seedPresent();

      final ScannedTrack? track = await pipeline(_FakeMetadataExtractor(durationMs: 260000)).importFile(sourceFile());

      expect(track?.id, '$key~2', reason: 'l\'id effectif, pas l\'id calculé à l\'identité');
      expect(appFolder.listSync(), hasLength(1));
      final List<Track> rows = await (db.select(db.tracks)..orderBy([(t) => OrderingTerm(expression: t.id)])).get();
      expect(rows.map((t) => (t.id, t.durationSeconds)), [(key, 320), ('$key~2', 260)]);
      expect(rows.first.filePath, present.path);
      expect(rows.last.filePath, appFolder.listSync().single.path);
    });

    test('re-importing that second version is recognised (no ~3 copy)', () async {
      await seedPresent();
      final AudioImportPipeline importer = pipeline(_FakeMetadataExtractor(durationMs: 260000));
      await importer.importFile(sourceFile());

      await expectLater(
        importer.importFile(sourceFile()),
        throwsA(isA<AlreadyInLibraryImportException>().having((e) => e.existing.id, 'existing', '$key~2')),
      );

      expect(appFolder.listSync(), hasLength(1), reason: 'la seconde tentative ne copie rien');
      expect(await db.select(db.tracks).get(), hasLength(2));
    });

    test('file gone: relink is unchanged even when the duration differs', () async {
      await TrackRepository(db).upsertTrack(ScannedTrack(
        id: key,
        title: 'One More Time',
        album: '',
        primaryArtist: 'Daft Punk',
        artists: const ['Daft Punk'],
        filePath: p.join(sourceDir.path, 'disparu.mp3'),
        durationMs: 320000,
        requiresUserReview: false,
        trimStartMs: 0,
        trimEndMs: 0,
      ));

      final ScannedTrack? track = await pipeline(_FakeMetadataExtractor(durationMs: 260000)).importFile(sourceFile());

      expect(track?.id, key);
      final Track saved = await db.select(db.tracks).getSingle();
      expect(saved.id, key);
      expect(saved.filePath, appFolder.listSync().single.path);
    });
  });

  group('AN-03 — reimport of a title already in the library', () {
    const String key = 'one-more-time__daft-punk';

    /// Titre déjà en base, édité à la main (titre/album différents des tags du
    /// fichier source, statut `enrichedManualEdit`).
    Future<void> seedEdited(String path) async {
      await TrackRepository(db).upsertTrack(ScannedTrack(
        id: key,
        title: 'One More Time',
        album: '',
        primaryArtist: 'Daft Punk',
        artists: const ['Daft Punk'],
        filePath: path,
        durationMs: 320000,
        requiresUserReview: false,
        trimStartMs: 0,
        trimEndMs: 0,
      ));
      await (db.update(db.tracks)..where((t) => t.id.equals(key))).write(const TracksCompanion(
        album: Value('Discovery (édité)'),
        coverArtPath: Value('/covers/omt.jpg'),
        enrichmentStatus: Value(EnrichmentStatus.enrichedManualEdit),
      ));
    }

    test('file still present: nothing is copied or overwritten', () async {
      final File protected = File(p.join(sourceDir.path, 'protected.mp3'))..writeAsBytesSync([9]);
      await seedEdited(protected.path);

      await expectLater(
        pipeline(_FakeMetadataExtractor()).importFile(sourceFile()),
        throwsA(isA<AlreadyInLibraryImportException>().having((e) => e.existing.id, 'existing', key)),
      );

      expect(appFolder.listSync(), isEmpty);
      final Track saved = await db.select(db.tracks).getSingle();
      expect(saved.filePath, protected.path);
      expect(saved.album, 'Discovery (édité)');
      expect(saved.enrichmentStatus, EnrichmentStatus.enrichedManualEdit);
    });

    test('file gone: only the file link is replaced, edits are kept', () async {
      await seedEdited(p.join(sourceDir.path, 'disparu.mp3'));

      final ScannedTrack? track = await pipeline(_FakeMetadataExtractor()).importFile(sourceFile());

      expect(track?.id, key);
      expect(track?.wasRenamedFromFilename, isFalse, reason: 'déjà enrichi : no auto-enrichment restart');
      expect(appFolder.listSync(), hasLength(1));
      final Track saved = await db.select(db.tracks).getSingle();
      expect(saved.filePath, appFolder.listSync().single.path);
      expect(saved.durationSeconds, 0, reason: 'physical duration of the new file (fake extractor reports none)');
      expect(saved.album, 'Discovery (édité)');
      expect(saved.coverArtPath, '/covers/omt.jpg');
      expect(saved.enrichmentStatus, EnrichmentStatus.enrichedManualEdit);
    });
  });
}
