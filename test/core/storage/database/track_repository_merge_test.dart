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

  test('merges accent and Unicode-form variants under the accented spelling', () async {
    await _insertTrack(db, id: 't1', artists: ['Celine Dion']);
    await _insertTrack(db, id: 't2', artists: ['Céline Dion']); // NFC
    await _insertTrack(db, id: 't3', artists: ['Céline Dion']); // NFD

    final int merged = await repository.mergeDuplicateCaseArtists();

    expect(merged, 1);
    for (final String id in ['t1', 't2', 't3']) {
      expect((await repository.findById(id))!.artists, ['Céline Dion'], reason: id);
    }
  });

  test('never merges distinct artists written in non-Latin scripts or sharing one ASCII letter', () async {
    // Clé de regroupement autrefois limitée à [a-z0-9] : ces noms tombaient
    // tous sur la même clé ("" ou "m") et étaient fusionnés en un seul artiste.
    await _insertTrack(db, id: 't1', artists: ['宇多田ヒカル']);
    await _insertTrack(db, id: 't2', artists: ['아이유']);
    await _insertTrack(db, id: 't3', artists: ['-M-']);
    await _insertTrack(db, id: 't4', artists: ['MØ']);

    final int merged = await repository.mergeDuplicateCaseArtists();

    expect(merged, 0);
    expect((await repository.findById('t1'))!.artists, ['宇多田ヒカル']);
    expect((await repository.findById('t2'))!.artists, ['아이유']);
    expect((await repository.findById('t3'))!.artists, ['-M-']);
    expect((await repository.findById('t4'))!.artists, ['MØ']);
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
