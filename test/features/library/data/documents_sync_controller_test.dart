import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/storage/database/track_auto_enricher.dart';
import 'package:playlist_app/core/storage/scanner/documents_library_sync.dart';
import 'package:playlist_app/core/storage/scanner/full_device_scan_service.dart';
import 'package:playlist_app/core/storage/scanner/scanned_track.dart';
import 'package:playlist_app/features/library/data/documents_sync_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Synchronisation pilotée par le test : chaque `run` attend [release].
class _ControlledSync implements DocumentsLibrarySync {
  int runs = 0;
  Completer<void> release = Completer<void>();

  @override
  Future<DocumentsSyncResult> run({void Function(FullDeviceScanProgress progress)? onProgress}) async {
    runs++;
    onProgress?.call(const FullDeviceScanProgress(phase: FullDeviceScanPhase.indexing, processed: 1, total: 4));
    await release.future;
    return const DocumentsSyncResult(added: 4, enriched: 1, skippedIncompleteDownloads: 0);
  }
}

class _CountingEnricher implements TrackAutoEnricher {
  int calls = 0;

  @override
  Future<bool> enrichTrack({
    required String trackId,
    required String title,
    required List<String> artists,
    bool singleAttempt = false,
  }) async {
    calls++;
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const ScannedTrack _renamed = ScannedTrack(
  id: 'renamed',
  title: 'Title',
  album: '',
  primaryArtist: 'Artist',
  artists: ['Artist'],
  filePath: '/Documents/Artist - Title.mp3',
  durationMs: 180000,
  requiresUserReview: false,
  trimStartMs: 0,
  trimEndMs: 0,
  wasRenamedFromFilename: true,
  lastModifiedEpochMs: 0,
);

void main() {
  group('enrichSyncedTrack (privacy: auto-enrichment opt-out)', () {
    test('enriches a renamed track by default', () async {
      SharedPreferences.setMockInitialValues({});
      final _CountingEnricher enricher = _CountingEnricher();

      expect(await enrichSyncedTrack(enricher, _renamed), isTrue);
      expect(enricher.calls, 1);
    });

    test('stays offline once the user opted out in Settings', () async {
      SharedPreferences.setMockInitialValues({'privacy.auto_enrich_on_import': false});
      final _CountingEnricher enricher = _CountingEnricher();

      expect(await enrichSyncedTrack(enricher, _renamed), isFalse);
      expect(enricher.calls, 0, reason: 'aucune requête iTunes/MusicBrainz');
    });
  });

  late _ControlledSync fake;
  late ProviderContainer container;

  setUp(() {
    fake = _ControlledSync();
    SharedPreferences.setMockInitialValues({});
    container = ProviderContainer(overrides: [documentsLibrarySyncProvider.overrideWithValue(fake)]);
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    container.dispose();
  });

  DocumentsSyncController controller() => container.read(documentsSyncControllerProvider.notifier);

  test('Android: never runs (the Documents sync is an iOS-only channel)', () async {
    fake.release.complete();

    expect(await controller().sync(), isNull);
    expect(fake.runs, 0);
  });

  test('iOS: exposes progress while running, then the result', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

    final Future<DocumentsSyncResult?> pending = controller().sync();
    await pumpEventQueue();
    final DocumentsSyncState running = container.read(documentsSyncControllerProvider);
    expect(running.isRunning, isTrue);
    expect(running.processed, 1);
    expect(running.total, 4);

    fake.release.complete();
    final DocumentsSyncResult? result = await pending;

    expect(result?.added, 4);
    final DocumentsSyncState done = container.read(documentsSyncControllerProvider);
    expect(done.isRunning, isFalse);
    expect(done.lastResult?.added, 4);
  });

  test('iOS: a second trigger while a sync is running is ignored', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

    final Future<DocumentsSyncResult?> first = controller().sync();
    await pumpEventQueue();
    expect(await controller().sync(), isNull);

    fake.release.complete();
    await first;
    expect(fake.runs, 1);
  });

  test('iOS: automatic triggers are spaced out, manual ones always run', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    fake.release.complete();

    expect(await controller().sync(automatic: true), isNotNull);
    expect(await controller().sync(automatic: true), isNull);
    expect(await controller().sync(), isNotNull);
    expect(fake.runs, 2);
  });

  test('iOS: once import was refused at onboarding, only the Library button syncs', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    fake.release.complete();

    await DocumentsSyncController.disableAutomaticSync();

    expect(await controller().sync(automatic: true), isNull, reason: 'ni au lancement ni au retour au premier plan');
    expect(fake.runs, 0);
    expect(await controller().sync(), isNotNull);
    expect(fake.runs, 1);
  });
}
