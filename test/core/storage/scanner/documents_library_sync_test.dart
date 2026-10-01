import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/storage/database/app_database.dart';
import 'package:playlist_app/core/storage/database/track_repository.dart';
import 'package:playlist_app/core/storage/scanner/documents_library_sync.dart';
import 'package:playlist_app/core/storage/scanner/full_device_scan_service.dart';
import 'package:playlist_app/core/storage/scanner/scanned_track.dart';

/// Scan scripté : renvoie [results] comme le ferait un vrai passage sur le
/// dossier Documents (fichiers nouveaux/modifiés uniquement).
class _ScriptedScan extends FullDeviceScanService {
  _ScriptedScan(this.results, {this.skipped = 0});

  final List<ScannedTrack> results;
  final int skipped;

  @override
  Future<List<ScannedTrack>> scan({
    required TrackRepository trackRepository,
    void Function(FullDeviceScanProgress progress)? onProgress,
  }) async {
    onProgress?.call(FullDeviceScanProgress(
      phase: FullDeviceScanPhase.done,
      processed: results.length,
      total: results.length,
      skippedIncompleteDownloads: skipped,
    ));
    return results;
  }
}

ScannedTrack _track(String id, {bool renamed = false}) => ScannedTrack(
      id: id,
      title: 'Title $id',
      album: '',
      primaryArtist: 'Artist',
      artists: const ['Artist'],
      filePath: '/Documents/$id.mp3',
      durationMs: 180000,
      requiresUserReview: false,
      trimStartMs: 0,
      trimEndMs: 0,
      wasRenamedFromFilename: renamed,
      lastModifiedEpochMs: 1000,
    );

void main() {
  late AppDatabase db;
  late TrackRepository repository;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repository = TrackRepository(db);
  });

  tearDown(() => db.close());

  test('persists every new file, then enriches only the tracks renamed from their filename', () async {
    final List<String> enrichedIds = [];
    final DocumentsLibrarySync sync = DocumentsLibrarySync(
      scanService: _ScriptedScan(
          [_track('tagged'), _track('renamed-ok', renamed: true), _track('renamed-ko', renamed: true)],
          skipped: 2),
      repository: repository,
      enrichRenamedTrack: (track) async {
        // Phase 2 strictement après la phase 1 : tout est déjà en base.
        expect(await repository.fetchAllTracks(), hasLength(3));
        enrichedIds.add(track.id);
        return track.id == 'renamed-ok';
      },
    );

    final DocumentsSyncResult result = await sync.run();

    expect(result.added, 3);
    expect(result.enriched, 1);
    expect(result.skippedIncompleteDownloads, 2);
    expect(enrichedIds, ['renamed-ok', 'renamed-ko']);
    expect((await repository.fetchAllTracks()).map((t) => t.id).toSet(), {'tagged', 'renamed-ok', 'renamed-ko'});
  });

  test('nothing new in the Documents folder: no write, no network call', () async {
    bool enricherCalled = false;
    final DocumentsLibrarySync sync = DocumentsLibrarySync(
      scanService: _ScriptedScan(const []),
      repository: repository,
      enrichRenamedTrack: (_) async => enricherCalled = true,
    );

    final DocumentsSyncResult result = await sync.run();

    expect(result.added, 0);
    expect(enricherCalled, isFalse);
    expect(await repository.fetchAllTracks(), isEmpty);
  });
}
