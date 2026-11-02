import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/audio_analysis/bass_analysis_service.dart';
import 'package:playlist_app/core/audio_analysis/track_audio_analysis_provider.dart';
import 'package:playlist_app/core/storage/database/app_database.dart';
import 'package:playlist_app/core/storage/database/database_provider.dart';
import 'package:playlist_app/core/storage/database/track_repository.dart';

class _FakeBassAnalysisService extends BassAnalysisService {
  _FakeBassAnalysisService(this.result);
  final ({Uint8List envelope, int? estimatedBpm})? result;
  final List<String> analyzed = [];

  @override
  Future<({Uint8List envelope, int? estimatedBpm})?> analyze(String filePath) async {
    analyzed.add(filePath);
    return result;
  }
}

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<void> insertTrack(String id, {String filePath = '/m/t.mp3'}) {
    return db.into(db.tracks).insert(TracksCompanion.insert(
        id: id, title: id, album: '', artists: const ['A'], durationSeconds: 180, filePath: filePath));
  }

  ProviderContainer containerWith(_FakeBassAnalysisService service) {
    final ProviderContainer container = ProviderContainer(overrides: [
      appDatabaseProvider.overrideWithValue(db),
      bassAnalysisServiceProvider.overrideWithValue(service),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  test('analyzes the local file, saves the result, then returns it', () async {
    await insertTrack('t1', filePath: '/m/t1.mp3');
    final service = _FakeBassAnalysisService((envelope: Uint8List.fromList([1, 2, 3]), estimatedBpm: 128));
    final container = containerWith(service);

    final analysis = await container.read(trackAudioAnalysisProvider('t1').future);

    expect(service.analyzed, ['/m/t1.mp3']);
    expect(analysis!.envelope, [1, 2, 3]);
    expect(analysis.estimatedBpm, 128);
    final repository = TrackRepository(db);
    expect(await repository.bassEnvelopeFor('t1'), [1, 2, 3]);
    expect((await repository.findById('t1'))!.estimatedBpm, 128);
  });

  test('reads a stored analysis without running the service again', () async {
    await insertTrack('t1');
    await TrackRepository(db).saveAudioAnalysis('t1', envelope: Uint8List.fromList([9, 9]), estimatedBpm: 100);
    final service = _FakeBassAnalysisService(null);
    final container = containerWith(service);

    final analysis = await container.read(trackAudioAnalysisProvider('t1').future);

    expect(service.analyzed, isEmpty);
    expect(analysis!.envelope, [9, 9]);
    expect(analysis.estimatedBpm, 100);
  });

  test('returns null, stores nothing and does not retry a failed analysis in the same session', () async {
    // Id propre à ce test : les échecs sont mémorisés pour toute la session.
    await insertTrack('broken', filePath: '/m/broken.mp3');
    final service = _FakeBassAnalysisService(null);
    final container = containerWith(service);

    expect(await container.read(trackAudioAnalysisProvider('broken').future), isNull);
    expect(await db.select(db.trackBassEnvelopes).get(), isEmpty);

    container.invalidate(trackAudioAnalysisProvider('broken'));
    expect(await container.read(trackAudioAnalysisProvider('broken').future), isNull);
    expect(service.analyzed, ['/m/broken.mp3']);
  });

  test('returns null for a track without a local file, without running the service', () async {
    await insertTrack('t1', filePath: '');
    final service = _FakeBassAnalysisService((envelope: Uint8List(1), estimatedBpm: null));
    final container = containerWith(service);

    expect(await container.read(trackAudioAnalysisProvider('t1').future), isNull);
    expect(await container.read(trackAudioAnalysisProvider('unknown').future), isNull);
    expect(service.analyzed, isEmpty);
  });
}
