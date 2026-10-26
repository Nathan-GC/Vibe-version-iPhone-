import 'dart:io';

import 'package:disk_space_plus/disk_space_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:playlist_app/core/storage/storage_manager/storage_manager_service.dart';

class _FakeDisk extends DiskSpacePlus {
  @override
  Future<double?> get getFreeDiskSpace async => null;
}

void main() {
  late Directory root;
  late StorageManagerService service;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('storage_manager_test');
    service = StorageManagerService(diskSpace: _FakeDisk(), appFolderResolver: () async => root);
  });

  tearDown(() => root.delete(recursive: true));

  File seed(String folder, String name) {
    final File f = File(p.join(root.path, folder, name));
    f.createSync(recursive: true);
    return f;
  }

  test('newOwnedFilePath returns a distinct path on each call', () async {
    final String a = await service.newOwnedFilePath('vibe_backgrounds', 'pl', '.mp4');
    File(a).createSync();
    final String b = await service.newOwnedFilePath('vibe_backgrounds', 'pl', '.mp4');
    expect(a, isNot(b));
    expect(p.basename(a), matches(RegExp(r'^pl_\d+\.mp4$')));
    expect(Directory(p.dirname(a)).existsSync(), isTrue);
  });

  test('deleteOtherOwnedFiles removes legacy and stamped files of the id only', () async {
    final File legacy = seed('track_covers', 'a_b_c.jpg');
    final File oldStamped = seed('track_covers', 'a_b_c_123.png');
    final File keep = seed('track_covers', 'a_b_c_456.jpg');
    final File otherId = seed('track_covers', 'a_b_c_d_789.jpg');
    final File prefixOnly = seed('track_covers', 'a_b.jpg');
    final File alpha = seed('track_covers', 'a_b_c_x.jpg');

    await service.deleteOtherOwnedFiles('track_covers', 'a_b_c', keepPath: keep.path);

    expect(legacy.existsSync(), isFalse);
    expect(oldStamped.existsSync(), isFalse);
    expect(keep.existsSync(), isTrue);
    expect(otherId.existsSync(), isTrue);
    expect(prefixOnly.existsSync(), isTrue);
    expect(alpha.existsSync(), isTrue);
  });

  test('importing a video replaces the old video but keeps the image of the playlist', () async {
    final File oldVideo = seed('vibe_backgrounds', 'pl.mp4');
    final File image = seed('vibe_backgrounds', 'pl_111.jpg');
    final File source = File(p.join(root.path, 'src.mp4'))..writeAsStringSync('v');

    final File imported = await service.importVibeBackgroundVideo(source, 'pl');

    expect(imported.existsSync(), isTrue);
    expect(imported.path, isNot(oldVideo.path));
    expect(oldVideo.existsSync(), isFalse);
    expect(image.existsSync(), isTrue);
  });

  test('two successive imports leave a single file with a new path', () async {
    final File source = File(p.join(root.path, 'c.png'))..writeAsStringSync('x');
    final File first = await service.importPlaylistCoverImage(source, 'pl');
    final File second = await service.importPlaylistCoverImage(source, 'pl');

    expect(second.path, isNot(first.path));
    expect(first.existsSync(), isFalse);
    expect(second.existsSync(), isTrue);
  });
}
