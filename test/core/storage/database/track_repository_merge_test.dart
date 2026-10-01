import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/storage/database/app_database.dart';
import 'package:playlist_app/core/storage/database/track_repository.dart';

Future<void> _insertTrack(AppDatabase db, {required String id, required List<String> artists}) async {
  await db.into(db.tracks).insert(
        TracksCompanion.insert(
          id: id,
          title: 'Title $id',
          album: '',
          artists: artists,
          durationSeconds: 180,
          filePath: '/music/$id.mp3',
        ),
      );
}

void main() {
  late AppDatabase db;
  late TrackRepository repository;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repository = TrackRepository(db);
  });

  tearDown(() => db.close());

  test('merges artists differing only by case', () async {
    await _insertTrack(db, id: 't1', artists: ['DAFT PUNK']);
    await _insertTrack(db, id: 't2', artists: ['daft punk']);

    final int merged = await repository.mergeDuplicateCaseArtists();

    expect(merged, 1);
    final t1 = await repository.findById('t1');
    final t2 = await repository.findById('t2');
    expect(t1!.artists, ['Daft Punk']);
    expect(t2!.artists, ['Daft Punk']);
  });

  test('merges artists differing only by spacing/punctuation (bug fixed)', () async {
    await _insertTrack(db, id: 't1', artists: ['DaftPunk']);
    await _insertTrack(db, id: 't2', artists: ['Daft Punk']);

    final int merged = await repository.mergeDuplicateCaseArtists();

    expect(merged, 1);
    final t1 = await repository.findById('t1');
    final t2 = await repository.findById('t2');
    // La variante déjà correctement espacée gagne comme forme canonique.
    expect(t1!.artists, ['Daft Punk']);
    expect(t2!.artists, ['Daft Punk']);
  });

  test('does not merge distinct artists', () async {
    await _insertTrack(db, id: 't1', artists: ['Daft Punk']);
    await _insertTrack(db, id: 't2', artists: ['Justice']);

    final int merged = await repository.mergeDuplicateCaseArtists();

    expect(merged, 0);
    final t1 = await repository.findById('t1');
    final t2 = await repository.findById('t2');
    expect(t1!.artists, ['Daft Punk']);
    expect(t2!.artists, ['Justice']);
  });

  test('merges featuring artists too, not just the primary one', () async {
    await _insertTrack(db, id: 't1', artists: ['Daft Punk', 'PHARRELL WILLIAMS']);
    await _insertTrack(db, id: 't2', artists: ['pharrell williams']);

    final int merged = await repository.mergeDuplicateCaseArtists();

    expect(merged, 1);
    final t1 = await repository.findById('t1');
    final t2 = await repository.findById('t2');
    expect(t1!.artists, ['Daft Punk', 'Pharrell Williams']);
    expect(t2!.artists, ['Pharrell Williams']);
  });
}
