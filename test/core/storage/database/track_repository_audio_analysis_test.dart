import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/storage/database/app_database.dart';
import 'package:playlist_app/core/storage/database/track_repository.dart';

void main() {
  late AppDatabase db;
  late TrackRepository repository;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repository = TrackRepository(db);
  });

  tearDown(() => db.close());

  Future<void> insertTrack(String id) {
    return db.into(db.tracks).insert(TracksCompanion.insert(
        id: id, title: id, album: '', artists: const ['A'], durationSeconds: 180, filePath: '/m/$id.mp3'));
  }

  test('bassEnvelopeFor returns null for a track that was never analyzed', () async {
    await insertTrack('t1');
    expect(await repository.bassEnvelopeFor('t1'), isNull);
  });

  test('saveAudioAnalysis stores the envelope and the estimated BPM, readable back', () async {
    await insertTrack('t1');

    await repository.saveAudioAnalysis('t1', envelope: Uint8List.fromList([0, 128, 255]), estimatedBpm: 128);

    expect(await repository.bassEnvelopeFor('t1'), [0, 128, 255]);
    expect((await repository.findById('t1'))!.estimatedBpm, 128);
  });

  test('saveAudioAnalysis replaces a previous analysis, a missing BPM clears the old estimate', () async {
    await insertTrack('t1');
    await repository.saveAudioAnalysis('t1', envelope: Uint8List.fromList([1, 2]), estimatedBpm: 90);

    await repository.saveAudioAnalysis('t1', envelope: Uint8List.fromList([9, 8, 7]));

    expect(await repository.bassEnvelopeFor('t1'), [9, 8, 7]);
    expect((await repository.findById('t1'))!.estimatedBpm, isNull);
    expect(await db.select(db.trackBassEnvelopes).get(), hasLength(1));
  });

  test('saveAudioAnalysis purges envelopes whose track no longer exists, and only those', () async {
    await insertTrack('gone');
    await insertTrack('kept');
    await insertTrack('new');
    await repository.saveAudioAnalysis('gone', envelope: Uint8List.fromList([1]));
    await repository.saveAudioAnalysis('kept', envelope: Uint8List.fromList([2]));
    // Cette base n'active pas les clés étrangères : la suppression du morceau
    // laisse l'enveloppe en place, c'est la purge suivante qui la retire.
    await repository.removeFromLibrary(['gone']);
    expect(await repository.bassEnvelopeFor('gone'), [1]);

    await repository.saveAudioAnalysis('new', envelope: Uint8List.fromList([3]));

    expect(await repository.bassEnvelopeFor('gone'), isNull);
    expect(await repository.bassEnvelopeFor('kept'), [2]);
    expect(await repository.bassEnvelopeFor('new'), [3]);
  });
}
