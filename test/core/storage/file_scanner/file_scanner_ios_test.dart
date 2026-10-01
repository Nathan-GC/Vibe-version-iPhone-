import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/storage/file_scanner/file_scanner.dart';

/// Racine iOS = dossier Documents de l'app (voir DeviceRootResolver).
void main() {
  late Directory root;

  Set<String> names(FileScanResult result) =>
      result.audioFiles.map((f) => f.path.split(Platform.pathSeparator).last).toSet();

  setUp(() {
    root = Directory.systemTemp.createTempSync('file_scanner_ios_test');
    Directory('${root.path}/Music/AppFolder').createSync(recursive: true);
    Directory('${root.path}/Inbox').createSync();
    Directory('${root.path}/.Trash').createSync();
    File('${root.path}/song.mp3').writeAsStringSync('x');
    File('${root.path}/song.flac').writeAsStringSync('x');
    File('${root.path}/vorbis.ogg').writeAsStringSync('x');
    File('${root.path}/Music/AppFolder/Artist-Imported.m4a').writeAsStringSync('x');
    File('${root.path}/Inbox/received.mp3').writeAsStringSync('x');
    File('${root.path}/.Trash/deleted.mp3').writeAsStringSync('x');
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    root.deleteSync(recursive: true);
  });

  test('iOS: skips .ogg (not decodable by AVFoundation), the managed import folder, Inbox and the Files trash',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

    final FileScanResult result = await FileScanner().scan(root);

    expect(names(result), {'song.mp3', 'song.flac'});
  });

  test('Android: default behaviour unchanged (.ogg kept, no iOS-only exclusions)', () async {
    final FileScanResult result = await FileScanner().scan(root);

    expect(
      names(result),
      {'song.mp3', 'song.flac', 'vorbis.ogg', 'Artist-Imported.m4a', 'received.mp3', 'deleted.mp3'},
    );
  });
}
