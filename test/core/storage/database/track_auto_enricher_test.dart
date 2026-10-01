import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/networking/metadata_api_client/metadata_api_client.dart';
import 'package:playlist_app/core/networking/metadata_api_client/online_track_result.dart';
import 'package:playlist_app/core/storage/database/app_database.dart';
import 'package:playlist_app/core/storage/database/track_auto_enricher.dart';
import 'package:playlist_app/core/storage/database/track_repository.dart';

class _FakeMetadataApiClient extends MetadataApiClient {
  _FakeMetadataApiClient(this.results);
  final List<OnlineTrackResult> results;
  int callCount = 0;

  @override
  Future<List<OnlineTrackResult>> search(
    String query, {
    int limit = 15,
    CancelToken? cancelToken,
    bool retryOnFailure = true,
  }) async {
    callCount++;
    return results;
  }
}

class _ThrowingMetadataApiClient extends MetadataApiClient {
  @override
  Future<List<OnlineTrackResult>> search(
    String query, {
    int limit = 15,
    CancelToken? cancelToken,
    bool retryOnFailure = true,
  }) async {
    throw DioException(requestOptions: RequestOptions(path: ''), type: DioExceptionType.connectionError);
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

  Future<void> insertTrack({
    required String id,
    required String title,
    required List<String> artists,
    EnrichmentStatus status = EnrichmentStatus.pending,
  }) async {
    await db.into(db.tracks).insert(
          TracksCompanion.insert(
            id: id,
            title: title,
            album: '',
            artists: artists,
            durationSeconds: 180,
            filePath: '/music/$id.mp3',
            enrichmentStatus: Value(status),
          ),
        );
  }

  test('enriches a confident match and reports success', () async {
    await insertTrack(id: 't1', title: 'One More Time', artists: ['Daft Punk']);
    final enricher = TrackAutoEnricher(
      metadataApiClient: _FakeMetadataApiClient([
        const OnlineTrackResult(
            artist: 'Daft Punk', title: 'One More Time', album: 'Discovery', coverArtUrl: 'https://x/cover.jpg'),
      ]),
      trackRepository: repository,
    );

    final bool ok = await enricher.enrichTrack(trackId: 't1', title: 'One More Time', artists: ['Daft Punk']);

    expect(ok, isTrue);
    final track = await repository.findById('t1');
    expect(track!.album, 'Discovery');
    expect(track.coverArtPath, 'https://x/cover.jpg');
  });

  test('rejects an unreliable match and reports failure without writing anything', () async {
    await insertTrack(id: 't1', title: 'Feel Good', artists: ['Charlotte Cardin']);
    final enricher = TrackAutoEnricher(
      metadataApiClient: _FakeMetadataApiClient([
        const OnlineTrackResult(artist: 'Charlotte Cardin', title: 'Confetti', album: '99 Nights'),
      ]),
      trackRepository: repository,
    );

    final bool ok = await enricher.enrichTrack(trackId: 't1', title: 'Feel Good', artists: ['Charlotte Cardin']);

    expect(ok, isFalse);
    final track = await repository.findById('t1');
    expect(track!.album, isEmpty);
  });

  test('returns false without searching when both title and artist are empty/unknown', () async {
    final enricher = TrackAutoEnricher(
      metadataApiClient: _FakeMetadataApiClient(const [OnlineTrackResult(artist: 'Should Not', title: 'Be Used')]),
      trackRepository: repository,
    );

    final bool ok = await enricher.enrichTrack(trackId: 't1', title: '', artists: const ['Unknown']);

    expect(ok, isFalse);
  });

  test('corrects title/artist when the reversed order is confirmed by a reliable iTunes match', () async {
    // Cas réel : "Halo - Beyoncé.mp3" stockait artist="Halo" title="Beyoncé"
    // (ordre inversé dans le nom source). La recherche primaire ne matche
    // pas ; celle en ordre inversé trouve "Beyoncé - Halo" avec confiance.
    await insertTrack(id: 't1', title: 'Beyoncé', artists: ['Halo']);
    final enricher = TrackAutoEnricher(
      metadataApiClient: _FakeMetadataApiClient(
          const [OnlineTrackResult(artist: 'Beyoncé', title: 'Halo', album: 'I Am... Sasha Fierce')]),
      trackRepository: repository,
    );

    final bool ok = await enricher.enrichTrack(trackId: 't1', title: 'Beyoncé', artists: ['Halo']);

    expect(ok, isTrue);
    final track = await repository.findById('t1');
    expect(track!.title, 'Halo');
    expect(track.artists, ['Beyoncé']);
    expect(track.album, 'I Am... Sasha Fierce');
    expect(track.requiresUserReview, isFalse);
  });

  test('does not touch title/artist when only the primary (non-swapped) order matches', () async {
    await insertTrack(id: 't1', title: 'One More Time', artists: ['Daft Punk']);
    final enricher = TrackAutoEnricher(
      metadataApiClient: _FakeMetadataApiClient(const [OnlineTrackResult(artist: 'Daft Punk', title: 'One More Time')]),
      trackRepository: repository,
    );

    await enricher.enrichTrack(trackId: 't1', title: 'One More Time', artists: ['Daft Punk']);

    final track = await repository.findById('t1');
    expect(track!.title, 'One More Time');
    expect(track.artists, ['Daft Punk']);
  });

  group('enrichment circuit breaker', () {
    test('marks a track needsManualReview after maxEnrichmentAttempts unreliable results, then skips the API entirely',
        () async {
      await insertTrack(id: 't1', title: 'Feel Good', artists: ['Charlotte Cardin']);
      final client = _FakeMetadataApiClient([
        const OnlineTrackResult(artist: 'Charlotte Cardin', title: 'Confetti', album: '99 Nights'),
      ]);
      final enricher = TrackAutoEnricher(metadataApiClient: client, trackRepository: repository);

      for (int i = 0; i < TrackRepository.maxEnrichmentAttempts; i++) {
        final bool ok = await enricher.enrichTrack(trackId: 't1', title: 'Feel Good', artists: ['Charlotte Cardin']);
        expect(ok, isFalse);
      }
      final track = await repository.findById('t1');
      expect(track!.enrichmentStatus, EnrichmentStatus.needsManualReview);
      expect(track.enrichmentAttempts, TrackRepository.maxEnrichmentAttempts);

      final int callsBeforeExtraAttempt = client.callCount;
      final bool okAfterBanned =
          await enricher.enrichTrack(trackId: 't1', title: 'Feel Good', artists: ['Charlotte Cardin']);
      expect(okAfterBanned, isFalse);
      expect(client.callCount, callsBeforeExtraAttempt, reason: 'needsManualReview must not trigger another API call');
    });

    test('marks a successful enrichment as enrichedAutoItunes', () async {
      await insertTrack(id: 't1', title: 'One More Time', artists: ['Daft Punk']);
      final enricher = TrackAutoEnricher(
        metadataApiClient: _FakeMetadataApiClient([
          const OnlineTrackResult(artist: 'Daft Punk', title: 'One More Time', album: 'Discovery'),
        ]),
        trackRepository: repository,
      );

      await enricher.enrichTrack(trackId: 't1', title: 'One More Time', artists: ['Daft Punk']);

      final track = await repository.findById('t1');
      expect(track!.enrichmentStatus, EnrichmentStatus.enrichedAutoItunes);
    });

    test('skips tracks already marked requiresReview without calling the API', () async {
      await insertTrack(id: 't1', title: 'Sounds', artists: ['Unknown'], status: EnrichmentStatus.requiresReview);
      final client = _FakeMetadataApiClient(const [OnlineTrackResult(artist: 'Should Not', title: 'Be Used')]);
      final enricher = TrackAutoEnricher(metadataApiClient: client, trackRepository: repository);

      final bool ok = await enricher.enrichTrack(trackId: 't1', title: 'Sounds', artists: ['Unknown']);

      expect(ok, isFalse);
      expect(client.callCount, 0);
    });

    test('a network failure does not consume an attempt (stays retryable)', () async {
      await insertTrack(id: 't1', title: 'One More Time', artists: ['Daft Punk']);
      final enricher = TrackAutoEnricher(metadataApiClient: _ThrowingMetadataApiClient(), trackRepository: repository);

      final bool ok = await enricher.enrichTrack(trackId: 't1', title: 'One More Time', artists: ['Daft Punk']);

      expect(ok, isFalse);
      final track = await repository.findById('t1');
      expect(track!.enrichmentStatus, EnrichmentStatus.pending);
      expect(track.enrichmentAttempts, 0);
    });
  });

  group('singleAttempt (scan initial, une seule passe sans boucle)', () {
    test('makes exactly one search call and never the swapped-order fallback when nothing is found', () async {
      await insertTrack(id: 't1', title: 'Feel Good', artists: ['Charlotte Cardin']);
      final client = _FakeMetadataApiClient(const []);
      final enricher = TrackAutoEnricher(metadataApiClient: client, trackRepository: repository);

      final bool ok = await enricher.enrichTrack(
        trackId: 't1',
        title: 'Feel Good',
        artists: ['Charlotte Cardin'],
        singleAttempt: true,
      );

      expect(ok, isFalse);
      expect(client.callCount, 1); // jamais la 2e requête (ordre inversé) du mode normal.
      final track = await repository.findById('t1');
      expect(track!.enrichmentStatus, EnrichmentStatus.pending); // "À enrichir", immédiatement.
      expect(track.enrichmentAttempts, 1);
    });

    test('marks the track pending ("À enrichir") on a network failure instead of leaving it unrecorded', () async {
      await insertTrack(id: 't1', title: 'One More Time', artists: ['Daft Punk']);
      final enricher = TrackAutoEnricher(metadataApiClient: _ThrowingMetadataApiClient(), trackRepository: repository);

      final bool ok = await enricher.enrichTrack(
        trackId: 't1',
        title: 'One More Time',
        artists: ['Daft Punk'],
        singleAttempt: true,
      );

      expect(ok, isFalse);
      final track = await repository.findById('t1');
      expect(track!.enrichmentStatus, EnrichmentStatus.pending);
      expect(track.enrichmentAttempts, 1);
    });

    test('still enriches normally when the single attempt succeeds', () async {
      await insertTrack(id: 't1', title: 'One More Time', artists: ['Daft Punk']);
      final enricher = TrackAutoEnricher(
        metadataApiClient: _FakeMetadataApiClient([
          const OnlineTrackResult(artist: 'Daft Punk', title: 'One More Time', album: 'Discovery'),
        ]),
        trackRepository: repository,
      );

      final bool ok = await enricher.enrichTrack(
        trackId: 't1',
        title: 'One More Time',
        artists: ['Daft Punk'],
        singleAttempt: true,
      );

      expect(ok, isTrue);
      final track = await repository.findById('t1');
      expect(track!.enrichmentStatus, EnrichmentStatus.enrichedAutoItunes);
      expect(track.album, 'Discovery');
    });
  });
}
