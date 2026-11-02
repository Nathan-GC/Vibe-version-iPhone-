import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:playlist_app/core/storage/database/app_database.dart';
import 'package:playlist_app/core/storage/database/database_provider.dart';
import 'package:playlist_app/core/theme/vibe_engine/vibe_engine.dart';
import 'package:playlist_app/features/playlists/data/custom_color_history.dart';
import 'package:playlist_app/features/playlists/presentation/vibe_customizer/vibe_customizer_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Recette Axe 4 (persistance), phase 1 sur émulateur : vraies
/// SharedPreferences (fichier XML de l'app), vrai stockage externe
/// (Music/AppFolder/window_backgrounds/), base Drift sur fichier ouverte avec
/// le même réglage que l'app (busy_timeout + WAL). La phase 2
/// (persistence_restart_test.dart) relit tout après redémarrage du processus.

const String qaDbName = 'qa_persistence.sqlite';
const String qaPlaylistId = 'qa_window';
const String historyKey = 'vibe.custom_color_history';

Future<String> _writePng(Directory dir, String name, Color color) async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(const Rect.fromLTWH(0, 0, 64, 64), Paint()..color = color);
  final ui.Image image = await recorder.endRecording().toImage(64, 64);
  final File file = File('${dir.path}/$name')
    ..writeAsBytesSync((await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List());
  return file.path;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('S-01..S-03 historique hexa : 8 max, doublon remonté, nuancier fixe exclu', (tester) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    // Sauvegarde de l'historique réel de l'app, restauré en phase 2.
    final List<String>? original = prefs.getStringList(historyKey);
    await prefs.setStringList('qa.history_backup', original ?? const ['<none>']);
    await prefs.remove(historyKey);

    final ProviderContainer container = ProviderContainer();
    addTearDown(container.dispose);
    container.listen(customColorHistoryProvider, (_, __) {});
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    final CustomColorHistory history = container.read(customColorHistoryProvider.notifier);

    // S-01 : 10 codes distincts (#10..#1A0) validés dans l'ordre.
    final List<Color> colors = [for (int i = 1; i <= 10; i++) Color(0xFF000000 | (i * 0x101010))];
    for (final Color c in colors) {
      await tester.runAsync(() => history.add(c));
    }
    List<Color> state = container.read(customColorHistoryProvider);
    expect(state.length, 8);
    expect(state, colors.reversed.take(8).toList(), reason: 'le plus récent en tête, les 2 plus anciens évincés');

    // S-02 : revalider un code déjà présent (le 5e) le remonte sans doublon.
    await tester.runAsync(() => history.add(colors[4]));
    state = container.read(customColorHistoryProvider);
    expect(state.first, colors[4]);
    expect(state.where((c) => c == colors[4]).length, 1);
    expect(state.length, 8);

    // S-03 : une teinte du nuancier fixe (#FF3D68) n'entre pas.
    final List<Color> beforeSwatch = [...state];
    await tester.runAsync(() => history.add(const Color(0xFFFF3D68)));
    expect(container.read(customColorHistoryProvider), beforeSwatch);

    final List<String> written = (await SharedPreferences.getInstance()).getStringList(historyKey)!;
    // ignore: avoid_print
    print('QA-PREFS $historyKey=$written');
    expect(written.length, 8);
    expect(written.first, 'FF505050');
  });

  testWidgets('I-01/I-02 + W-01 image "Behind the window" via l\'éditeur, base en WAL', (tester) async {
    final Directory docs = await getApplicationDocumentsDirectory();
    final File dbFile = File('${docs.path}/$qaDbName');
    for (final String suffix in ['', '-wal', '-shm']) {
      if (File('${dbFile.path}$suffix').existsSync()) File('${dbFile.path}$suffix').deleteSync();
    }
    final AppDatabase db = AppDatabase.forTesting(NativeDatabase(dbFile, setup: AppDatabase.configureConnection));
    await db.into(db.playlists).insert(PlaylistsCompanion.insert(
        id: qaPlaylistId, title: 'QA window', vibeStyle: const Value(VibePreset.neon)));

    final Directory tmp = await getTemporaryDirectory();
    final String red = await tester.runAsync(() => _writePng(tmp, 'qa_red.png', const Color(0xFFE53935))) as String;
    final String blue = await tester.runAsync(() => _writePng(tmp, 'qa_blue.png', const Color(0xFF1E88E5))) as String;
    String next = red;

    await tester.pumpWidget(ProviderScope(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
      child: MaterialApp(home: VibeCustomizerScreen(playlistId: qaPlaylistId, pickWindowImage: () async => next)),
    ));
    Future<void> settle() async {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 700)));
      await tester.pump(const Duration(milliseconds: 300));
    }

    Future<String> storedPath() async =>
        (await tester.runAsync(() => (db.select(db.playlists)..where((p) => p.id.equals(qaPlaylistId))).getSingle()))!
            .windowBackgroundImagePath;

    Future<void> tapLabel(String label) async {
      await settle();
      final Finder button = find.text(label);
      await tester.scrollUntilVisible(button, 300, scrollable: find.byType(Scrollable).first);
      await tester.tap(button);
      await settle();
    }

    // I-01 : choix d'une image.
    await tapLabel("Choisir l'image");
    final String first = await storedPath();
    // ignore: avoid_print
    print('QA-DB after choose: window_background_image_path=$first');
    expect(first, contains('/Music/AppFolder/window_backgrounds/${qaPlaylistId}_'));
    expect(File(first).existsSync(), isTrue);

    // I-02a : changement d'image → nouveau chemin, ancien fichier supprimé.
    next = blue;
    await tapLabel("Changer l'image");
    final String second = await storedPath();
    // ignore: avoid_print
    print('QA-DB after change: window_background_image_path=$second; old exists=${File(first).existsSync()}');
    expect(second, isNot(first));
    expect(File(second).existsSync(), isTrue);
    expect(File(first).existsSync(), isFalse, reason: "l'ancienne image ne doit pas rester sur le disque");

    // I-02b : retrait → chemin vidé, fichier supprimé.
    await tapLabel('Retirer');
    final String removed = await storedPath();
    // ignore: avoid_print
    print('QA-DB after remove: window_background_image_path="$removed"; file exists=${File(second).existsSync()}');
    expect(removed, '');
    expect(File(second).existsSync(), isFalse);

    // Image finale laissée en place pour la relecture après redémarrage.
    next = red;
    await tapLabel("Choisir l'image");
    final String finalPath = await storedPath();
    expect(File(finalPath).existsSync(), isTrue);

    // W-01 : journal WAL réellement actif sur le SQLite d'Android.
    final String mode = (await tester.runAsync(() => db.customSelect('PRAGMA journal_mode').getSingle()))!.read<String>('journal_mode');
    final int timeout = (await tester.runAsync(() => db.customSelect('PRAGMA busy_timeout').getSingle()))!.data.values.first as int;
    final bool walFile = File('${dbFile.path}-wal').existsSync();
    // ignore: avoid_print
    print('QA-DB PRAGMA journal_mode=$mode busy_timeout=$timeout wal_file=$walFile final=$finalPath');
    expect(mode, 'wal');
    expect(timeout, 5000);
    expect(walFile, isTrue);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(Duration.zero);
    await tester.runAsync(db.close);
  });
}
