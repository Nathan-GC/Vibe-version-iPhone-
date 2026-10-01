import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/storage/filename_sanitizer/filename_sanitizer.dart';
import 'package:playlist_app/core/storage/metadata_extractor/metadata_extractor.dart';
import 'package:playlist_app/core/storage/metadata_extractor/raw_track_metadata.dart';
import 'package:playlist_app/core/storage/scanner/library_scan_service.dart';

/// Évite tout appel ffprobe réel (indisponible hors device) : renvoie des
/// métadonnées fixes, avec `durationMs` null pour aussi court-circuiter le
/// détecteur de silence (ffmpeg), voir `LibraryScanService._process`.
class _FakeMetadataExtractor extends MetadataExtractor {
  _FakeMetadataExtractor(this.result);
  final RawTrackMetadata result;

  @override
  Future<RawTrackMetadata> extract(File file) async => result;
}

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('library_scan_service_test');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  test('marks a track as renamed-from-filename when ID3 tags are missing (renommage puis enrichissement)', () async {
    final File file = File('${tempDir.path}/Daft Punk - One More Time.mp3')..writeAsStringSync('x');
    final service = LibraryScanService(
      metadataExtractor: _FakeMetadataExtractor(const RawTrackMetadata()),
      filenameSanitizer: FilenameSanitizer(),
    );

    final track = await service.processSingleFile(file);

    expect(track, isNotNull);
    expect(track!.wasRenamedFromFilename, isTrue);
    expect(track.title, 'One More Time');
    expect(track.artists, ['Daft Punk']);
  });

  test('does not mark a track as renamed when proper ID3 tags are already present', () async {
    final File file = File('${tempDir.path}/whatever_filename_12345.mp3')..writeAsStringSync('x');
    final service = LibraryScanService(
      metadataExtractor: _FakeMetadataExtractor(
        const RawTrackMetadata(title: 'One More Time', artists: ['Daft Punk']),
      ),
      filenameSanitizer: FilenameSanitizer(),
    );

    final track = await service.processSingleFile(file);

    expect(track, isNotNull);
    expect(track!.wasRenamedFromFilename, isFalse);
    expect(track.title, 'One More Time');
    expect(track.artists, ['Daft Punk']);
  });
}
