import 'dart:io';

import 'package:disk_space_plus/disk_space_plus.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:playlist_app/core/storage/database/app_database.dart';
import 'package:playlist_app/core/storage/database/database_provider.dart';
import 'package:playlist_app/core/storage/storage_manager/storage_manager_service.dart';
import 'package:playlist_app/core/theme/vibe_engine/vibe_engine.dart';
import 'package:playlist_app/features/library/data/library_providers.dart';
import 'package:playlist_app/features/playlists/presentation/vibe_customizer/vibe_customizer_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeDisk extends DiskSpacePlus {
  @override
  Future<double?> get getFreeDiskSpace async => null;
}

void main() {
  late AppDatabase db;
  late Directory root;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase.forTesting(NativeDatabase.memory());
    root = Directory.systemTemp.createTempSync('window_image_test');
  });

  tearDown(() async {
    await db.close();
    root.deleteSync(recursive: true);
  });

  Future<void> insertPlaylist({VibePreset style = VibePreset.neon, String windowPath = ''}) =>
      db.into(db.playlists).insert(PlaylistsCompanion.insert(
          id: 'p', title: 'Test', vibeStyle: Value(style), windowBackgroundImagePath: Value(windowPath)));

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await tester.pumpAndSettle();
  }

  Future<void> pumpScreen(WidgetTester tester, {Future<String?> Function()? pick}) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        storageManagerServiceProvider.overrideWithValue(
            StorageManagerService(diskSpace: _FakeDisk(), appFolderResolver: () async => root)),
      ],
      child: MaterialApp(home: VibeCustomizerScreen(playlistId: 'p', pickWindowImage: pick)),
    ));
    await settle(tester);
  }

  Future<void> teardownTree(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(Duration.zero);
  }

  Future<Playlist> stored(WidgetTester tester) async =>
      (await tester.runAsync(() => db.select(db.playlists).getSingle()))!;

  testWidgets('the image button only appears on the active neon card', (tester) async {
    await insertPlaylist(style: VibePreset.minimal);
    await pumpScreen(tester);
    expect(find.text("Choisir l'image"), findsNothing);
    await teardownTree(tester);
  });

  testWidgets('on an active neon card: choose button, no remove button without image', (tester) async {
    await insertPlaylist();
    await pumpScreen(tester);
    expect(find.text("Choisir l'image"), findsOneWidget);
    expect(find.text('Retirer'), findsNothing);
    await teardownTree(tester);
  });

  testWidgets('picking copies the file into window_backgrounds and stores its path', (tester) async {
    await insertPlaylist();
    final File source = File(p.join(root.path, 'src.jpg'))..writeAsStringSync('img');
    await pumpScreen(tester, pick: () async => source.path);

    await tester.tap(find.text("Choisir l'image"));
    // Copie de fichier réelle : plusieurs tours d'E/S avant l'écriture en base.
    for (int i = 0; i < 50 && (await stored(tester)).windowBackgroundImagePath.isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await settle(tester);

    final Playlist playlist = await stored(tester);
    expect(p.basename(p.dirname(playlist.windowBackgroundImagePath)), 'window_backgrounds');
    expect(File(playlist.windowBackgroundImagePath).existsSync(), isTrue);
    expect(playlist.customBackgroundImagePath, '');
    expect(find.text("Changer l'image"), findsOneWidget);
    expect(find.text('Retirer'), findsOneWidget);
    await teardownTree(tester);
  });

  testWidgets('a cancelled picker changes nothing', (tester) async {
    await insertPlaylist(windowPath: '/old/window_backgrounds/p_1.jpg');
    await pumpScreen(tester, pick: () async => null);

    await tester.tap(find.text("Changer l'image"));
    await settle(tester);

    expect((await stored(tester)).windowBackgroundImagePath, '/old/window_backgrounds/p_1.jpg');
    await teardownTree(tester);
  });

  testWidgets('a copy failure shows a SnackBar and keeps the previous path', (tester) async {
    await insertPlaylist(windowPath: '/old/window_backgrounds/p_1.jpg');
    await pumpScreen(tester, pick: () async => p.join(root.path, 'missing.jpg'));

    await tester.tap(find.text("Changer l'image"));
    await settle(tester);

    expect(find.text("Impossible d'importer l'image"), findsOneWidget);
    expect((await stored(tester)).windowBackgroundImagePath, '/old/window_backgrounds/p_1.jpg');
    await teardownTree(tester);
  });

  testWidgets('"Retirer" clears the path and deletes the owned file only', (tester) async {
    final File owned = File(p.join(root.path, 'window_backgrounds', 'p_1.jpg'))
      ..createSync(recursive: true);
    await insertPlaylist(windowPath: owned.path);
    await pumpScreen(tester);

    await tester.tap(find.text('Retirer'));
    await settle(tester);

    expect((await stored(tester)).windowBackgroundImagePath, '');
    expect(owned.existsSync(), isFalse);
    expect(find.text('Retirer'), findsNothing);
    await teardownTree(tester);
  });

  testWidgets('"Retirer" never deletes a file outside window_backgrounds', (tester) async {
    final File foreign = File(p.join(root.path, 'gallery', 'photo.jpg'))..createSync(recursive: true);
    await insertPlaylist(windowPath: foreign.path);
    await pumpScreen(tester);

    await tester.tap(find.text('Retirer'));
    await settle(tester);

    expect((await stored(tester)).windowBackgroundImagePath, '');
    expect(foreign.existsSync(), isTrue);
    await teardownTree(tester);
  });
}
