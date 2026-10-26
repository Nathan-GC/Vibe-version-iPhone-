import 'dart:async';

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
    String? country,
  }) async {
    callCount++;
    return results;
  }
}

class _RecordingMetadataApiClient extends MetadataApiClient {
  final List<String> queries = [];

  @override
  Future<List<OnlineTrackResult>> search(
    String query, {
    int limit = 15,
    CancelToken? cancelToken,
    bool retryOnFailure = true,
    String? country,
  }) async {
    queries.add(query);
    return const [];
  }
}

class _ThrowingMetadataApiClient extends MetadataApiClient {
  @override
  Future<List<OnlineTrackResult>> search(
    String query, {
    int limit = 15,
    CancelToken? cancelToken,
    bool retryOnFailure = true,
    String? country,
  }) async {
    throw DioException(requestOptions: RequestOptions(path: ''), type: DioExceptionType.connectionError);
  }
}

/// Un appel reçu par [_CatalogMetadataApiClient].
class _SearchCall {
  _SearchCall(this.query, this.limit, this.country, this.retryOnFailure);
  final String query;
  final int limit;
  final String? country;
  final bool retryOnFailure;
}

/// Faux client iTunes avec des réponses par catalogue (`country`), un échec
/// possible par catalogue, et une "porte" optionnelle qui garde chaque requête
/// en vol tant que le test ne la libère pas (preuve de simultanéité).
class _CatalogMetadataApiClient extends MetadataApiClient {
  _CatalogMetadataApiClient({this.byCountry = const {}, this.failingCountries = const {}, this.gated = false});

  final Map<String, List<OnlineTrackResult>> byCountry;
  final Set<String> failingCountries;
  final bool gated;
  final List<_SearchCall> calls = [];
  final Map<String, Completer<void>> gates = {};

  @override
  Future<List<OnlineTrackResult>> search(
    String query, {
    int limit = 15,
    CancelToken? cancelToken,
    bool retryOnFailure = true,
    String? country,
  }) async {
    calls.add(_SearchCall(query, limit, country, retryOnFailure));
    if (gated) await gates.putIfAbsent(country!, Completer<void>.new).future;
    if (failingCountries.contains(country)) {
      throw DioException(requestOptions: RequestOptions(path: ''), type: DioExceptionType.connectionError);
    }
    return byCountry[country] ?? const [];
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
    String? filePath,
  }) async {
    await db.into(db.tracks).insert(
          TracksCompanion.insert(
            id: id,
            title: title,
            album: '',
            artists: artists,
            durationSeconds: 180,
            filePath: filePath ?? '/music/$id.mp3',
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

  group('garde-fou de durée (piste stockée : 180 s)', () {
    Future<bool> enrichWith(OnlineTrackResult candidate) {
      final enricher =
          TrackAutoEnricher(metadataApiClient: _FakeMetadataApiClient([candidate]), trackRepository: repository);
      return enricher.enrichTrack(trackId: 't1', title: 'One More Time', artists: ['Daft Punk']);
    }

    OnlineTrackResult candidateOf(int durationMs) =>
        OnlineTrackResult(artist: 'Daft Punk', title: 'One More Time', album: 'Discovery', durationMs: durationMs);

    test('uses the stored duration: a candidate 20 s away is rejected, 12 s away accepted', () async {
      await insertTrack(id: 't1', title: 'One More Time', artists: ['Daft Punk']);

      expect(await enrichWith(candidateOf(200000)), isFalse);
      expect(await enrichWith(candidateOf(192000)), isTrue);
    });

    test('a video file name disables the duration check', () async {
      await insertTrack(
        id: 't1',
        title: 'One More Time',
        artists: ['Daft Punk'],
        filePath: '/music/Daft Punk - One More Time (Official Video)_1725636997429.mp3',
      );

      expect(await enrichWith(candidateOf(400000)), isTrue);
    });

    test('a video mention only counts in the file name, never in the folder', () async {
      await insertTrack(
        id: 't1',
        title: 'One More Time',
        artists: ['Daft Punk'],
        filePath: '/music/Official Video/One More Time.mp3',
      );

      expect(await enrichWith(candidateOf(400000)), isFalse);
    });

    test('mentionsVideo: explicit forms (compact too) and whole word only', () {
      for (final name in [
        'A - B (Official Video).mp3',
        'A - B OFFICIAL MUSIC VIDEO.mp3',
        'A-B-OfficialMusicVideo.mp3',
        'A - B (Music Video).mp3',
        'A - B [Lyric Video].mp3',
        'A - B lyrics video.mp3',
        'A - B (Video Clip).mp3',
        'A - B VideoClip.mp3',
        'A - B (Clip Officiel).mp3',
        'A - B Visualizer.mp3',
        'A - B visualiser.mp3',
        'A - B (Video).mp3',
      ]) {
        expect(TrackAutoEnricher.mentionsVideo(name), isTrue, reason: name);
      }
      for (final name in ['A - VIDEOCLUB.mp3', 'A - B.mp3', 'Videotheque - B.mp3']) {
        expect(TrackAutoEnricher.mentionsVideo(name), isFalse, reason: name);
      }
    });
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

  test('sends the repaired text in the query but leaves the stored title/artist untouched', () async {
    await insertTrack(id: 't1', title: 'crÇature', artists: ['BeyoncÇ']);
    final client = _RecordingMetadataApiClient();
    final enricher = TrackAutoEnricher(metadataApiClient: client, trackRepository: repository);

    await enricher.enrichTrack(trackId: 't1', title: 'crÇature', artists: ['BeyoncÇ'], singleAttempt: true);

    expect(client.queries.toSet(), {'Beyoncé créature'}); // même requête sur les deux catalogues.
    final track = await repository.findById('t1');
    expect(track!.title, 'crÇature');
    expect(track.artists, ['BeyoncÇ']);
  });

  test('a signature in the artist also repairs the title of the same query', () async {
    await insertTrack(id: 't1', title: "áa n'en vaut pas la peine", artists: ['BeyoncÇ']);
    final client = _RecordingMetadataApiClient();
    final enricher = TrackAutoEnricher(metadataApiClient: client, trackRepository: repository);

    await enricher.enrichTrack(
      trackId: 't1',
      title: "áa n'en vaut pas la peine",
      artists: ['BeyoncÇ'],
      singleAttempt: true,
    );

    expect(client.queries.toSet(), {"Beyoncé ça n'en vaut pas la peine"});
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
    test('makes exactly one search per catalog (no retry, no extra swapped-order call) when nothing is found',
        () async {
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
      expect(client.callCount, 2); // une par catalogue (US, FR), jamais de requête d'ordre inversé.
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

  group('double catalogue US + FR', () {
    const OnlineTrackResult usHit = OnlineTrackResult(
      trackId: 1,
      artist: 'Daft Punk',
      title: 'One More Time',
      album: 'Discovery (US)',
    );
    const OnlineTrackResult frHit = OnlineTrackResult(
      trackId: 2,
      artist: 'Daft Punk',
      title: 'One More Time',
      album: 'Discovery (FR)',
    );

    Future<bool> enrich(TrackAutoEnricher enricher, {bool singleAttempt = false}) => enricher.enrichTrack(
          trackId: 't1',
          title: 'One More Time',
          artists: ['Daft Punk'],
          singleAttempt: singleAttempt,
        );

    test('requests both catalogs once each, same query, limit 15, concurrently', () async {
      await insertTrack(id: 't1', title: 'One More Time', artists: ['Daft Punk']);
      final client = _CatalogMetadataApiClient(byCountry: {
        'US': [usHit]
      }, gated: true);
      final enricher = TrackAutoEnricher(metadataApiClient: client, trackRepository: repository);

      final Future<bool> result = enrich(enricher);

      // Les deux requêtes doivent être parties AVANT qu'aucune n'ait répondu :
      // si elles étaient séquentielles, la 2e ne partirait jamais (la 1re est
      // bloquée par sa porte) et ce test échouerait.
      for (int i = 0; i < 500 && client.calls.length < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(client.calls.map((c) => c.country), unorderedEquals(['US', 'FR']));
      expect(client.gates.values.every((gate) => !gate.isCompleted), isTrue);

      for (final gate in client.gates.values) {
        gate.complete();
      }
      expect(await result, isTrue);

      expect(client.calls, hasLength(2));
      expect(client.calls.map((c) => c.limit), everyElement(15));
      expect(TrackAutoEnricher.candidateLimit, 15);
      expect(client.calls.map((c) => c.query).toSet(), {'Daft Punk One More Time'});
    });

    test('merges US first then FR and keeps the US result when both match', () async {
      await insertTrack(id: 't1', title: 'One More Time', artists: ['Daft Punk']);
      final client = _CatalogMetadataApiClient(byCountry: {
        'US': [usHit],
        'FR': [frHit]
      });
      final enricher = TrackAutoEnricher(metadataApiClient: client, trackRepository: repository);

      expect(await enrich(enricher), isTrue);

      expect((await repository.findById('t1'))!.album, 'Discovery (US)');
    });

    test('falls back on the FR catalog when only it knows the track', () async {
      await insertTrack(id: 't1', title: 'One More Time', artists: ['Daft Punk']);
      final client = _CatalogMetadataApiClient(byCountry: {
        'FR': [frHit]
      });
      final enricher = TrackAutoEnricher(metadataApiClient: client, trackRepository: repository);

      expect(await enrich(enricher), isTrue);

      expect((await repository.findById('t1'))!.album, 'Discovery (FR)');
    });

    test('mergeCandidates counts the same trackId once, keeps US order first, and key-dedups id-less results', () {
      const OnlineTrackResult usOnly = OnlineTrackResult(trackId: 10, artist: 'A', title: 'US only');
      const OnlineTrackResult shared = OnlineTrackResult(trackId: 11, artist: 'A', title: 'Shared');
      const OnlineTrackResult sharedFr = OnlineTrackResult(trackId: 11, artist: 'A', title: 'Shared', album: 'FR');
      const OnlineTrackResult frOnly = OnlineTrackResult(trackId: 12, artist: 'A', title: 'FR only');
      const OnlineTrackResult noIdUs = OnlineTrackResult(artist: 'B', title: 'No Id', album: 'Alb');
      const OnlineTrackResult noIdFr = OnlineTrackResult(artist: 'b', title: 'NO ID', album: 'alb');

      final merged = TrackAutoEnricher.mergeCandidates([
        [usOnly, shared, noIdUs],
        [sharedFr, frOnly, noIdFr],
      ]);

      expect(merged, [usOnly, shared, noIdUs, frOnly]);
      expect(
          TrackAutoEnricher.mergeCandidates([
            null,
            [frOnly]
          ]),
          [frOnly]);
    });

    test('finds a reversed filename locally: no third request, title/artist corrected', () async {
      await insertTrack(id: 't1', title: 'Beyoncé', artists: ['Halo']);
      final client = _CatalogMetadataApiClient(byCountry: {
        'US': const [OnlineTrackResult(trackId: 5, artist: 'Beyoncé', title: 'Halo', album: 'I Am... Sasha Fierce')],
      });
      final enricher = TrackAutoEnricher(metadataApiClient: client, trackRepository: repository);

      final bool ok = await enricher.enrichTrack(trackId: 't1', title: 'Beyoncé', artists: ['Halo']);

      expect(ok, isTrue);
      expect(client.calls, hasLength(2)); // US + FR seulement, pas de requête d'ordre inversé.
      final track = await repository.findById('t1');
      expect(track!.title, 'Halo');
      expect(track.artists, ['Beyoncé']);
      expect(track.album, 'I Am... Sasha Fierce');
    });

    test('the local inversion also applies in singleAttempt mode', () async {
      await insertTrack(id: 't1', title: 'Beyoncé', artists: ['Halo']);
      final client = _CatalogMetadataApiClient(byCountry: {
        'FR': const [OnlineTrackResult(trackId: 5, artist: 'Beyoncé', title: 'Halo', album: 'I Am... Sasha Fierce')],
      });
      final enricher = TrackAutoEnricher(metadataApiClient: client, trackRepository: repository);

      final bool ok = await enricher.enrichTrack(
        trackId: 't1',
        title: 'Beyoncé',
        artists: ['Halo'],
        singleAttempt: true,
      );

      expect(ok, isTrue);
      expect(client.calls, hasLength(2));
      expect((await repository.findById('t1'))!.title, 'Halo');
    });

    test('one catalog failing still enriches from the other', () async {
      await insertTrack(id: 't1', title: 'One More Time', artists: ['Daft Punk']);
      final client = _CatalogMetadataApiClient(byCountry: {
        'FR': [frHit]
      }, failingCountries: {
        'US'
      });
      final enricher = TrackAutoEnricher(metadataApiClient: client, trackRepository: repository);

      expect(await enrich(enricher), isTrue);

      final track = await repository.findById('t1');
      expect(track!.album, 'Discovery (FR)');
      expect(track.enrichmentStatus, EnrichmentStatus.enrichedAutoItunes);
    });

    test('both catalogs failing behaves like a network error: no attempt consumed in normal mode', () async {
      await insertTrack(id: 't1', title: 'One More Time', artists: ['Daft Punk']);
      final client = _CatalogMetadataApiClient(failingCountries: {'US', 'FR'});
      final enricher = TrackAutoEnricher(metadataApiClient: client, trackRepository: repository);

      expect(await enrich(enricher), isFalse);

      final track = await repository.findById('t1');
      expect(track!.enrichmentStatus, EnrichmentStatus.pending);
      expect(track.enrichmentAttempts, 0);
    });

    test('both catalogs failing in singleAttempt mode consumes the attempt', () async {
      await insertTrack(id: 't1', title: 'One More Time', artists: ['Daft Punk']);
      final client = _CatalogMetadataApiClient(failingCountries: {'US', 'FR'});
      final enricher = TrackAutoEnricher(metadataApiClient: client, trackRepository: repository);

      expect(await enrich(enricher, singleAttempt: true), isFalse);

      expect((await repository.findById('t1'))!.enrichmentAttempts, 1);
    });

    test('singleAttempt sends retryOnFailure: false on both requests, normal mode keeps retries', () async {
      await insertTrack(id: 't1', title: 'One More Time', artists: ['Daft Punk']);
      final single = _CatalogMetadataApiClient(byCountry: {
        'US': [usHit]
      });
      await enrich(TrackAutoEnricher(metadataApiClient: single, trackRepository: repository), singleAttempt: true);
      expect(single.calls, hasLength(2));
      expect(single.calls.map((c) => c.retryOnFailure), everyElement(isFalse));

      final normal = _CatalogMetadataApiClient(byCountry: {
        'US': [usHit]
      });
      await enrich(TrackAutoEnricher(metadataApiClient: normal, trackRepository: repository));
      expect(normal.calls, hasLength(2));
      expect(normal.calls.map((c) => c.retryOnFailure), everyElement(isTrue));
    });
  });
}
