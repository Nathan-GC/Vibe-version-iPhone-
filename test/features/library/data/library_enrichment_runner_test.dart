import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/storage/database/app_database.dart';
import 'package:playlist_app/core/storage/database/library_category.dart';
import 'package:playlist_app/core/storage/database/track_enricher.dart';
import 'package:playlist_app/core/storage/database/track_repository.dart';
import 'package:playlist_app/core/storage/scanner/scanned_track.dart';
import 'package:playlist_app/features/library/data/library_enrichment_runner.dart';

/// Enricher scripté : réussit pour les ids de [succeeds], échoue sinon, et
/// écrit son résultat en base comme les vrais (circuit-breaker compris).
class _ScriptedEnricher implements TrackEnricher {
  _ScriptedEnricher(this.repository, {this.succeeds = const {}, this.onEnrich});

  final TrackRepository repository;
  final Set<String> succeeds;
  final Future<void> Function(String trackId)? onEnrich;
  final Map<String, int> calls = {};

  @override
  Future<bool> enrichTrack({required String trackId, required String title, required List<String> artists}) async {
    calls.update(trackId, (count) => count + 1, ifAbsent: () => 1);
    await onEnrich?.call(trackId);
    final bool ok = succeeds.contains(trackId);
    await repository.recordEnrichmentOutcome(trackId, success: ok, source: EnrichmentSource.itunes);
    return ok;
  }
}

void main() {
  late AppDatabase db;
  late TrackRepository repository;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repository = TrackRepository(db);
  });
  tearDown(() => db.close());

  Future<void> insert(String id) => repository.upsertTrack(ScannedTrack(
        id: id,
        title: 'Title $id',
        album: '',
        primaryArtist: 'Artist',
        artists: const ['Artist'],
        filePath: '/music/$id.mp3',
        durationMs: 180000,
        requiresUserReview: false,
        trimStartMs: 0,
        trimEndMs: 0,
      ));

  test('an enriched track is never processed a second time in the next pass', () async {
    await insert('found');
    await insert('missing');
    final enricher = _ScriptedEnricher(repository, succeeds: {'found'});

    final LibraryEnrichmentResult result =
        await LibraryEnrichmentRunner(repository: repository, enricher: enricher).run();

    expect(result.enriched, 1);
    expect(result.targets, 2);
    expect(enricher.calls['found'], 1, reason: 'enrichi en passe 1 : absent de la passe 2');
    // Seul l'échec est retenté (passe 2), jusqu'au circuit-breaker.
    expect(enricher.calls['missing'], TrackRepository.maxEnrichmentAttempts);
    expect((await repository.findById('missing'))!.enrichmentStatus, EnrichmentStatus.needsManualReview);
  });

  test('a track that left "À enrichir" before its turn is skipped', () async {
    await insert('a');
    await insert('b');
    final enricher = _ScriptedEnricher(
      repository,
      succeeds: {'a', 'b'},
      // Le premier morceau traité fait sortir l'autre de "À enrichir"
      // (ex. Changer de catégorie pendant le traitement).
      onEnrich: (trackId) => repository.forceLibraryCategory(trackId == 'a' ? 'b' : 'a', LibraryCategory.done),
    );

    await LibraryEnrichmentRunner(repository: repository, enricher: enricher).run();

    expect(enricher.calls.values.fold<int>(0, (sum, count) => sum + count), 1);
  });

  test('nothing to enrich makes no call at all', () async {
    await insert('a');
    await repository.forceLibraryCategory('a', LibraryCategory.done);
    final enricher = _ScriptedEnricher(repository);

    final LibraryEnrichmentResult result =
        await LibraryEnrichmentRunner(repository: repository, enricher: enricher).run();

    expect(result.targets, 0);
    expect(enricher.calls, isEmpty);
  });
}
