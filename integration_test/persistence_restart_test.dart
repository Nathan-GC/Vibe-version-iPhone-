import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:playlist_app/core/storage/database/app_database.dart';
import 'package:playlist_app/features/playlists/data/custom_color_history.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'persistence_test.dart' show historyKey, qaDbName, qaPlaylistId;

/// Recette Axe 4, phase 2 : nouveau processus après persistence_test.dart.
/// Relit l'historique et l'image, puis remet l'app dans son état d'avant.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('S-04 + I-03 historique et image restaurés après redémarrage, puis nettoyage', (tester) async {
    final ProviderContainer container = ProviderContainer();
    addTearDown(container.dispose);
    container.listen(customColorHistoryProvider, (_, __) {});
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    final List<Color> restored = container.read(customColorHistoryProvider);
    // ignore: avoid_print
    print('QA-RESTART history=${restored.map((c) => c.toARGB32().toRadixString(16)).toList()}');
    expect(restored.length, 8);
    expect(restored.first, const Color(0xFF505050));

    final Directory docs = await getApplicationDocumentsDirectory();
    final File dbFile = File('${docs.path}/$qaDbName');
    final AppDatabase db = AppDatabase.forTesting(NativeDatabase(dbFile, setup: AppDatabase.configureConnection));
    final Playlist row =
        (await tester.runAsync(() => (db.select(db.playlists)..where((p) => p.id.equals(qaPlaylistId))).getSingle()))!;
    // ignore: avoid_print
    print('QA-RESTART window_background_image_path=${row.windowBackgroundImagePath} exists=${File(row.windowBackgroundImagePath).existsSync()}');
    expect(row.windowBackgroundImagePath, isNotEmpty);
    expect(File(row.windowBackgroundImagePath).existsSync(), isTrue);

    // Nettoyage : image QA, base QA, historique réel de l'app restauré.
    await tester.runAsync(() async {
      await db.close();
      File(row.windowBackgroundImagePath).deleteSync();
      for (final String suffix in ['', '-wal', '-shm']) {
        if (File('${dbFile.path}$suffix').existsSync()) File('${dbFile.path}$suffix').deleteSync();
      }
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final List<String> backup = prefs.getStringList('qa.history_backup') ?? const ['<none>'];
      if (backup.length == 1 && backup.first == '<none>') {
        await prefs.remove(historyKey);
      } else {
        await prefs.setStringList(historyKey, backup);
      }
      await prefs.remove('qa.history_backup');
    });
  });
}
