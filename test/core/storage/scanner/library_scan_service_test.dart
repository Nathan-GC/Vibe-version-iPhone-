import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/storage/filename_sanitizer/filename_sanitizer.dart';
import 'package:playlist_app/core/storage/metadata_extractor/embedded_cover_extractor.dart';
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

/// Enregistre les appels au lieu de lancer ffmpeg (indisponible hors device).
class _FakeCoverExtractor extends EmbeddedCoverExtractor {
  _FakeCoverExtractor({this.result = '/covers/extracted.jpg'});
  final String? result;
  final List<({String trackId, String codec})> calls = [];

  @override
  Future<String?> extract(File audio, {required String trackId, required String codec}) async {
    calls.add((trackId: trackId, codec: codec));
    return result;
  }
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

  group('pochette intégrée', () {
    const tagged = RawTrackMetadata(title: 'One More Time', artists: ['Daft Punk'], embeddedCoverCodec: 'png');
    late File file;

    setUp(() => file = File('${tempDir.path}/song.mp3')..writeAsStringSync('x'));

    LibraryScanService serviceWith(RawTrackMetadata metadata, _FakeCoverExtractor covers) => LibraryScanService(
          metadataExtractor: _FakeMetadataExtractor(metadata),
          filenameSanitizer: FilenameSanitizer(),
          coverExtractor: covers,
        );

    test('extracts the cover of a fully processed file and exposes its path', () async {
      final covers = _FakeCoverExtractor();

      final track = await serviceWith(tagged, covers).processSingleFile(file);

      expect(covers.calls, hasLength(1));
      expect(covers.calls.single.codec, 'png');
      expect(covers.calls.single.trackId, track!.id);
      expect(track.coverArtPath, '/covers/extracted.jpg');
    });

    test('leaves coverArtPath null when the extraction fails', () async {
      final track = await serviceWith(tagged, _FakeCoverExtractor(result: null)).processSingleFile(file);

      expect(track, isNotNull);
      expect(track!.coverArtPath, isNull);
    });

    test('does not call the extractor when the file has no embedded cover', () async {
      final covers = _FakeCoverExtractor();

      final track = await serviceWith(
        const RawTrackMetadata(title: 'One More Time', artists: ['Daft Punk']),
        covers,
      ).processSingleFile(file);

      expect(covers.calls, isEmpty);
      expect(track!.coverArtPath, isNull);
    });

    test('never extracts for identify (recognition only)', () async {
      final covers = _FakeCoverExtractor();

      final track = await serviceWith(tagged, covers).identify(file);

      expect(track, isNotNull);
      expect(covers.calls, isEmpty);
      expect(track!.coverArtPath, isNull);
    });

    test('does not extract for a file skipped by skipKey', () async {
      final covers = _FakeCoverExtractor();

      final track = await serviceWith(tagged, covers).processSingleFile(file, skipKey: (_) async => true);

      expect(track, isNull);
      expect(covers.calls, isEmpty);
    });
  });
}
