import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/storage/file_scanner/file_scanner.dart';

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('file_scanner_test');
  });

  tearDown(() {
    root.deleteSync(recursive: true);
  });

  test('finds mp3 and m4a by default, ignores unsupported extensions', () async {
    File('${root.path}/song.mp3').writeAsStringSync('x');
    File('${root.path}/song.m4a').writeAsStringSync('x');
    File('${root.path}/note.txt').writeAsStringSync('x');

    final result = await FileScanner().scan(root);

    expect(result.audioFiles.map((f) => f.path.split(Platform.pathSeparator).last).toSet(), {'song.mp3', 'song.m4a'});
    expect(result.incompleteDownloads, isEmpty);
  });

  test('reports .giga incomplete-download stubs separately instead of silently dropping them', () async {
    File('${root.path}/Track - Artist.mp3.giga').writeAsStringSync('{"a":"stub"}');
    File('${root.path}/song.mp3').writeAsStringSync('x');

    final result = await FileScanner().scan(root);

    expect(result.audioFiles.map((f) => f.path.split(Platform.pathSeparator).last).toList(), ['song.mp3']);
    expect(result.incompleteDownloads, hasLength(1));
    expect(result.incompleteDownloads.single.path, endsWith('.mp3.giga'));
  });

  test('does not crash when scanning a .giga stub alongside normal files', () async {
    File('${root.path}/a.mp3.giga').writeAsStringSync('{"a":"stub"}');

    expect(() => FileScanner().scan(root), returnsNormally);
  });
}
