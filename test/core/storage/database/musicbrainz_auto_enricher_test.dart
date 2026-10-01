import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/networking/metadata_api_client/metadata_api_client.dart';
import 'package:playlist_app/core/networking/metadata_api_client/online_track_result.dart';
import 'package:playlist_app/core/networking/musicbrainz/musicbrainz_client.dart';
import 'package:playlist_app/core/storage/database/app_database.dart';
import 'package:playlist_app/core/storage/database/musicbrainz_auto_enricher.dart';
import 'package:playlist_app/core/storage/database/track_auto_enricher.dart';
import 'package:playlist_app/core/storage/database/track_repository.dart';

class _FakeMusicBrainzClient extends MusicBrainzClient {
  _FakeMusicBrainzClient(this.results, {this.fail = false});
  final List<OnlineTrackResult> results;
  final bool fail;
  int callCount = 0;

  @override
  Future<List<OnlineTrackResult>> searchRecordings({required String artist, required String title}) async {
    callCount++;
    if (fail) throw DioException(requestOptions: RequestOptions(path: ''), type: DioExceptionType.badResponse);
    return results;
  }
}

class _FakeItunes extends MetadataApiClient {
  _FakeItunes(this.results);
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

const OnlineTrackResult _mbMatch = OnlineTrackResult(
  title: 'Bootleg Mix',
  artist: 'Some DJ',
  album: 'Club Edits',
  releaseYear: 2019,
  coverArtUrl: 'https://coverartarchive.org/release-group/rg/front-500',
);

void main() {
  late AppDatabase db;
  late TrackRepository repository;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repository = TrackRepository(db);
  });
  tearDown(() => db.close());

  Future<void> insertTrack({String coverArtPath = '', EnrichmentStatus status = EnrichmentStatus.pending}) {
    return db.into(db.tracks).insert(TracksCompanion.insert(
          id: 't1',
          title: 'Bootleg Mix',
          album: '',
          artists: const ['Some DJ'],
          durationSeconds: 180,
          filePath: '/music/t1.mp3',
          coverArtPath: Value(coverArtPath),
          enrichmentStatus: Value(status),
        ));
  }

  MusicBrainzAutoEnricher enricher(MusicBrainzClient client) =>
      MusicBrainzAutoEnricher(client: client, trackRepository: repository);

  group('MusicBrainz as the chosen source', () {
    test('applies a confident match and records the MusicBrainz provenance', () async {
      await insertTrack();

      final bool ok = await enricher(_FakeMusicBrainzClient(const [_mbMatch]))
          .enrichTrack(trackId: 't1', title: 'Bootleg Mix', artists: const ['Some DJ']);

      expect(ok, isTrue);
      final Track track = (await repository.findById('t1'))!;
      expect(track.enrichmentStatus, EnrichmentStatus.enrichedAutoMusicBrainz);
      expect(track.album, 'Club Edits');
      expect(track.releaseYear, 2019);
      expect(track.coverArtPath, _mbMatch.coverArtUrl);
    });

    test('keeps an existing cover and still succeeds (non-destructive, no false "Échec auto")', () async {
      await insertTrack(coverArtPath: 'local/existing.jpg');

      final bool ok = await enricher(_FakeMusicBrainzClient(const [_mbMatch]))
          .enrichTrack(trackId: 't1', title: 'Bootleg Mix', artists: const ['Some DJ']);

      expect(ok, isTrue);
      final Track track = (await repository.findById('t1'))!;
      expect(track.coverArtPath, 'local/existing.jpg');
      expect(track.enrichmentStatus, EnrichmentStatus.enrichedAutoMusicBrainz);
    });

    test('an unrelated result counts as a failed attempt, until the circuit-breaker stops the API', () async {
      await insertTrack();
      final client = _FakeMusicBrainzClient(const [OnlineTrackResult(title: 'Something Else', artist: 'Other')]);

      for (int i = 0; i < TrackRepository.maxEnrichmentAttempts; i++) {
        expect(await enricher(client).enrichTrack(trackId: 't1', title: 'Bootleg Mix', artists: const ['Some DJ']),
            isFalse);
      }
      expect((await repository.findById('t1'))!.enrichmentStatus, EnrichmentStatus.needsManualReview);

      final int callsBefore = client.callCount;
      await enricher(client).enrichTrack(trackId: 't1', title: 'Bootleg Mix', artists: const ['Some DJ']);
      expect(client.callCount, callsBefore);
    });

    test('a network error (503 rate limit included) does not consume an attempt', () async {
      await insertTrack();

      final bool ok = await enricher(_FakeMusicBrainzClient(const [], fail: true))
          .enrichTrack(trackId: 't1', title: 'Bootleg Mix', artists: const ['Some DJ']);

      expect(ok, isFalse);
      final Track track = (await repository.findById('t1'))!;
      expect(track.enrichmentAttempts, 0);
      expect(track.enrichmentStatus, EnrichmentStatus.pending);
    });

    test('skips tracks marked requiresReview without calling the API', () async {
      await insertTrack(status: EnrichmentStatus.requiresReview);
      final client = _FakeMusicBrainzClient(const [_mbMatch]);

      expect(
          await enricher(client).enrichTrack(trackId: 't1', title: 'Bootleg Mix', artists: const ['Some DJ']), isFalse);
      expect(client.callCount, 0);
    });
  });

  group('automatic order: iTunes first, MusicBrainz as fallback', () {
    TrackAutoEnricher chain(_FakeItunes itunes, _FakeMusicBrainzClient musicBrainz) => TrackAutoEnricher(
          metadataApiClient: itunes,
          trackRepository: repository,
          fallback: enricher(musicBrainz),
        );

    test('iTunes finds nothing, MusicBrainz matches: enriched with MusicBrainz provenance', () async {
      await insertTrack();
      final musicBrainz = _FakeMusicBrainzClient(const [_mbMatch]);

      final bool ok = await chain(_FakeItunes(const []), musicBrainz)
          .enrichTrack(trackId: 't1', title: 'Bootleg Mix', artists: const ['Some DJ']);

      expect(ok, isTrue);
      expect(musicBrainz.callCount, 1);
      final Track track = (await repository.findById('t1'))!;
      expect(track.enrichmentStatus, EnrichmentStatus.enrichedAutoMusicBrainz);
      expect(track.enrichmentAttempts, 0);
    });

    test('an iTunes match never queries MusicBrainz', () async {
      await insertTrack();
      final musicBrainz = _FakeMusicBrainzClient(const [_mbMatch]);
      final itunes = _FakeItunes(const [OnlineTrackResult(title: 'Bootleg Mix', artist: 'Some DJ', album: 'iTunes')]);

      expect(
          await chain(itunes, musicBrainz).enrichTrack(trackId: 't1', title: 'Bootleg Mix', artists: const ['Some DJ']),
          isTrue);
      expect(musicBrainz.callCount, 0);
      expect((await repository.findById('t1'))!.enrichmentStatus, EnrichmentStatus.enrichedAutoItunes);
    });

    test('both sources find nothing: one single attempt is counted, not two', () async {
      await insertTrack();

      final bool ok = await chain(_FakeItunes(const []), _FakeMusicBrainzClient(const []))
          .enrichTrack(trackId: 't1', title: 'Bootleg Mix', artists: const ['Some DJ']);

      expect(ok, isFalse);
      final Track track = (await repository.findById('t1'))!;
      expect(track.enrichmentAttempts, 1);
      expect(track.enrichmentStatus, EnrichmentStatus.pending);
    });
  });
}
