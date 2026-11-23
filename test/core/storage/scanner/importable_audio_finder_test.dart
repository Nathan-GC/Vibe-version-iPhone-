import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:playlist_app/core/storage/database/app_database.dart';
import 'package:playlist_app/core/storage/database/blacklist_repository.dart';
import 'package:playlist_app/core/storage/database/track_repository.dart';
import 'package:playlist_app/core/storage/scanner/importable_audio_finder.dart';
import 'package:playlist_app/core/storage/scanner/scanned_track.dart';

ScannedTrack _scanned(String id, String path, {String? fileHash, int lastModifiedEpochMs = 0}) => ScannedTrack(
      id: id,
      title: 'Song $id',
      album: '',
      primaryArtist: 'Artist',
      artists: const ['Artist'],
      filePath: path,
      durationMs: 180000,
      requiresUserReview: false,
      trimStartMs: 0,
      trimEndMs: 0,
      fileHash: fileHash,
      lastModifiedEpochMs: lastModifiedEpochMs,
    );

void main() {
  late Directory root; // faux stockage partagé du téléphone
  late Directory libraryDir; // faux dossier de l'app, hors de la racine
  late AppDatabase db;
  late TrackRepository tracks;

  setUp(() {
    root = Directory.systemTemp.createTempSync('vibe_finder_root');
    libraryDir = Directory.systemTemp.createTempSync('vibe_finder_lib');
    db = AppDatabase.forTesting(NativeDatabase.memory());
    tracks = TrackRepository(db);
  });

  tearDown(() async {
    await db.close();
    root.deleteSync(recursive: true);
    libraryDir.deleteSync(recursive: true);
  });

  ImportableAudioFinder finder({Directory? Function()? rootOverride}) => ImportableAudioFinder(
        trackRepository: tracks,
        resolveRoot: () async => rootOverride != null ? rootOverride() : root,
      );

  File write(Directory base, String relative, List<int> bytes, {DateTime? modified}) {
    final File file = File(p.normalize(p.join(base.path, relative)))..createSync(recursive: true);
    file.writeAsBytesSync(bytes);
    if (modified != null) file.setLastModifiedSync(modified);
    return file;
  }

  List<int> bytes(String text) => text.codeUnits;

  test('sorts by modification date, most recent first, then by name', () async {
    write(root, 'Download/old.mp3', bytes('1'), modified: DateTime(2024, 1, 1));
    write(root, 'Download/new.mp3', bytes('22'), modified: DateTime(2026, 6, 1));
    write(root, 'Download/b-same.mp3', bytes('333'), modified: DateTime(2025, 3, 3));
    write(root, 'Download/a-same.mp3', bytes('4444'), modified: DateTime(2025, 3, 3));

    final List<ImportableAudioFile> found = await finder().find();

    expect(found.map((f) => f.name), ['new', 'a-same', 'b-same', 'old']);
  });

  test('reports name without extension, relative folder, size and date', () async {
    final DateTime date = DateTime(2025, 5, 5, 12);
    write(root, 'Music/Daft Punk/One More Time.mp3', bytes('12345'), modified: date);
    write(root, 'at_root.flac', bytes('1'), modified: date);

    final List<ImportableAudioFile> found = await finder().find();
    final Map<String, ImportableAudioFile> byName = {for (final f in found) f.name: f};

    final ImportableAudioFile nested = byName['One More Time']!;
    expect(nested.folder, 'Music/Daft Punk');
    expect(nested.size, 5);
    expect(nested.path, p.join(root.path, 'Music', 'Daft Punk', 'One More Time.mp3'));
    expect(nested.modified.millisecondsSinceEpoch ~/ 1000, date.millisecondsSinceEpoch ~/ 1000);
    expect(byName['at_root']!.folder, '');
  });

  test('applies the FileScanner exclusions (messaging apps, voice clips, unsupported extensions)', () async {
    write(root, 'Download/keep.mp3', bytes('1'));
    write(root, 'Download/keep.m4a', bytes('22'));
    write(root, 'WhatsApp/Media/voice.mp3', bytes('333'));
    write(root, 'Telegram/song.mp3', bytes('4444'));
    write(root, 'Download/note.opus', bytes('55555'));
    write(root, 'Download/clip.wav', bytes('666666'));
    write(root, 'Download/readme.txt', bytes('7777777'));
    write(root, 'Download/stub.giga', bytes('88888888'));

    final List<ImportableAudioFile> found = await finder().find();

    expect(found.map((f) => p.basename(f.path)).toSet(), {'keep.mp3', 'keep.m4a'});
  });

  test('hides a file whose path is already a library track', () async {
    // Taille différente de celle de « fresh » : seul le chemin peut le masquer.
    final File inLibrary = write(root, 'Music/indexed.mp3', bytes('1'));
    write(root, 'Download/fresh.mp3', bytes('22'));
    await tracks.upsertTrack(_scanned('t1', inLibrary.path));

    final List<ImportableAudioFile> found = await finder().find();

    expect(found.map((f) => f.name), ['fresh']);
  });

  test('hides a blacklisted path', () async {
    // Chemins du scanner et de la base comparés tels quels : pas d'import ici.
    final File hidden = write(root, 'Download/hidden.mp3', bytes('1'));
    write(root, 'Download/visible.mp3', bytes('22'));
    await BlacklistRepository(db).hideFiles([_scanned('k1', hidden.path)]);

    final List<ImportableAudioFile> found = await finder().find();
    expect(found.map((f) => f.name), ['visible']);
  });

  test('hides a copy of a library file stored under another name (identical content)', () async {
    // Import manuel = copie renommée « Artiste-Titre.mp3 » dans le dossier de
    // l'app : le nom d'origine est perdu, seul le contenu identifie l'original.
    final File libraryCopy = write(libraryDir, 'Daft Punk-One More Time.mp3', bytes('same audio bytes'));
    await tracks.upsertTrack(_scanned('t1', libraryCopy.path));
    write(root, 'Download/random_name_123.mp3', bytes('same audio bytes'));
    write(root, 'Download/other.mp3', bytes('another one'));

    final List<ImportableAudioFile> found = await finder().find();

    expect(found.map((f) => f.name), ['other']);
  });

  test('keeps a file with the same size but different content', () async {
    final File libraryCopy = write(libraryDir, 'Artist-Song.mp3', bytes('AAAAAAAA'));
    await tracks.upsertTrack(_scanned('t1', libraryCopy.path));
    write(root, 'Download/lookalike.mp3', bytes('BBBBBBBB'));

    final List<ImportableAudioFile> found = await finder().find();

    expect(found.map((f) => f.name), ['lookalike']);
  });

  test('does not trust a stale stored hash: content is hashed again', () async {
    // file_hash est périmé quand le mtime mémorisé ne correspond plus au fichier.
    final File libraryCopy = write(libraryDir, 'Artist-Song.mp3', bytes('real content'));
    await tracks.upsertTrack(_scanned('t1', libraryCopy.path, fileHash: 'bogus', lastModifiedEpochMs: 1));
    write(root, 'Download/copy.mp3', bytes('real content'));

    final List<ImportableAudioFile> found = await finder().find();

    expect(found, isEmpty);
  });

  test('uses the stored hash when the library file has not moved since', () async {
    // Preuve que file_hash sert : un hash volontairement faux mais à jour
    // (même mtime) fait gagner la comparaison sans relire le fichier de la
    // bibliothèque — le candidat de même taille n'est alors plus reconnu.
    final File libraryCopy = write(libraryDir, 'Artist-Song.mp3', bytes('real content'), modified: DateTime(2025, 1, 1));
    final int mtime = libraryCopy.statSync().modified.millisecondsSinceEpoch;
    await tracks.upsertTrack(_scanned('t1', libraryCopy.path, fileHash: 'bogus', lastModifiedEpochMs: mtime));
    write(root, 'Download/copy.mp3', bytes('real content'));

    final List<ImportableAudioFile> found = await finder().find();

    expect(found.map((f) => f.name), ['copy']);
  });

  test('ignores a library file that has disappeared', () async {
    final File gone = write(libraryDir, 'Artist-Gone.mp3', bytes('same size'));
    await tracks.upsertTrack(_scanned('t1', gone.path));
    gone.deleteSync();
    write(root, 'Download/candidate.mp3', bytes('same size'));

    final List<ImportableAudioFile> found = await finder().find();

    expect(found.map((f) => f.name), ['candidate']);
  });

  test('returns an empty list when the root cannot be resolved', () async {
    write(root, 'Download/song.mp3', bytes('1'));

    final List<ImportableAudioFile> found = await finder(rootOverride: () => null).find();

    expect(found, isEmpty);
  });

  test('returns an empty list when the root directory does not exist', () async {
    final Directory missing = Directory(p.join(root.path, 'nope'));

    final List<ImportableAudioFile> found = await finder(rootOverride: () => missing).find();

    expect(found, isEmpty);
  });
}
