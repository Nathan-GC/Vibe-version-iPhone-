import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/storage/database/app_database.dart';

void main() {
  test('a second connection waits for the other one\'s write lock instead of failing with "database is locked"',
      () async {
    final Directory dir = await Directory.systemTemp.createTemp('vibe_db_lock');
    addTearDown(() => dir.delete(recursive: true));
    final File file = File('${dir.path}/playlist_app.sqlite');
    // Comme en production : l'app et la tâche de purge (WorkManager, isolate
    // séparé) ouvrent chacune leur propre connexion au même fichier.
    final AppDatabase app = AppDatabase.forTesting(NativeDatabase(file, setup: AppDatabase.configureConnection));
    final AppDatabase background =
        AppDatabase.forTesting(NativeDatabase.createInBackground(file, setup: AppDatabase.configureConnection));
    addTearDown(() async {
      await app.close();
      await background.close();
    });
    await app.customStatement('CREATE TABLE lock_probe (x INTEGER)');
    await background.customSelect('SELECT 1').get();

    final Completer<void> lockHeld = Completer<void>();
    final Future<void> longWrite = app.transaction(() async {
      await app.customStatement('INSERT INTO lock_probe VALUES (1)');
      lockHeld.complete();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await lockHeld.future;

    await background.customStatement('INSERT INTO lock_probe VALUES (2)');
    await longWrite;

    expect((await app.customSelect('SELECT COUNT(*) AS n FROM lock_probe').getSingle()).read<int>('n'), 2);
  });
}
