import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/storage/database/app_database.dart';
import 'package:playlist_app/core/storage/database/database_provider.dart';
import 'package:playlist_app/core/storage/scanner/importable_audio_finder.dart';
import 'package:playlist_app/features/library/presentation/import/importable_audio_screen.dart';
import 'package:playlist_app/features/library/presentation/library_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeFinder implements ImportableAudioFinder {
  _FakeFinder(this.files, {this.gate});

  final List<ImportableAudioFile> files;

  /// Si fourni, `find()` attend ce signal : recensement « qui tarde ».
  final Completer<void>? gate;

  @override
  Future<List<ImportableAudioFile>> find() async {
    await gate?.future;
    return files;
  }
}

final DateTime _now = DateTime(2026, 11, 23, 18, 0);

ImportableAudioFile _file(String name, String folder, DateTime modified) => ImportableAudioFile(
      path: '/storage/emulated/0/${folder.isEmpty ? '' : '$folder/'}$name.mp3',
      name: name,
      folder: folder,
      modified: modified,
      size: 1000,
    );

final List<ImportableAudioFile> _files = [
  _file('Daft Punk - Voyager', 'Download', DateTime(2026, 11, 23, 14, 32)),
  _file('Édith Piaf - La vie en rose', 'Music/Chansons', DateTime(2026, 11, 22, 9, 10)),
  _file('Zebra', '', DateTime(2026, 11, 12, 8, 0)),
];

void main() {
  /// Ouvre l'écran depuis un bouton, comme LibraryScreen, et capte le résultat.
  Future<ValueNotifier<Object?>> pumpScreen(
    WidgetTester tester,
    ImportableAudioFinder finder, {
    bool settle = true,
  }) async {
    final ValueNotifier<Object?> result = ValueNotifier<Object?>('pas de retour');
    await tester.pumpWidget(ProviderScope(
      overrides: [importableAudioFinderProvider.overrideWithValue(finder)],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result.value = await Navigator.of(context).push<ImportableAudioResult>(
                  MaterialPageRoute(builder: (_) => ImportableAudioScreen(clock: () => _now)),
                );
              },
              child: const Text('ouvrir'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('ouvrir'));
    // Un indicateur animé ne « se stabilise » jamais : transition de route seule.
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    }
    return result;
  }

  FilledButton importButton(WidgetTester tester) => tester.widget<FilledButton>(find.byType(FilledButton));

  testWidgets('indicateur et message pendant le recensement, puis la liste', (tester) async {
    final Completer<void> gate = Completer<void>();
    await pumpScreen(tester, _FakeFinder(_files, gate: gate), settle: false);
    expect(find.text('Importer des fichiers audio'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Recherche des fichiers audio du téléphone…'), findsOneWidget);

    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(CheckboxListTile), findsNWidgets(3));
  });

  testWidgets('liste dans l\'ordre fourni, avec dossier et date lisible', (tester) async {
    await pumpScreen(tester, _FakeFinder(_files));

    final List<String> titles = tester
        .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
        .map((tile) => (tile.title! as Text).data!)
        .toList();
    expect(titles, ['Daft Punk - Voyager', 'Édith Piaf - La vie en rose', 'Zebra']);
    expect(find.text("Download · aujourd'hui 14:32"), findsOneWidget);
    expect(find.text('Music/Chansons · hier 09:10'), findsOneWidget);
    expect(find.text('Stockage interne · 12 nov. 2026'), findsOneWidget);
  });

  testWidgets('recherche insensible casse/accents, la sélection survit au filtre', (tester) async {
    final ValueNotifier<Object?> result = await pumpScreen(tester, _FakeFinder(_files));

    await tester.tap(find.text('Zebra'));
    await tester.pump();
    expect(find.text('Importer (1)'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'EDITH');
    await tester.pump();
    expect(find.byType(CheckboxListTile), findsOneWidget);
    expect(find.text('Édith Piaf - La vie en rose'), findsOneWidget);
    // Zebra est masqué par le filtre mais toujours coché.
    expect(find.text('Importer (1)'), findsOneWidget);

    await tester.tap(find.text('Édith Piaf - La vie en rose'));
    await tester.pump();
    expect(find.text('Importer (2)'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'introuvable');
    await tester.pump();
    expect(find.text('Aucun fichier ne correspond.'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '');
    await tester.pump();
    await tester.tap(find.text('Importer (2)'));
    await tester.pumpAndSettle();

    // Chemins renvoyés dans l'ordre de la liste, pas celui des clics.
    final ImportableAudioPicked picked = result.value! as ImportableAudioPicked;
    expect(picked.paths, [_files[1].path, _files[2].path]);
  });

  testWidgets('« Importer (N) » désactivé à 0, compteur juste en cochant/décochant', (tester) async {
    await pumpScreen(tester, _FakeFinder(_files));

    expect(find.text('Importer (0)'), findsOneWidget);
    expect(importButton(tester).onPressed, isNull);

    await tester.tap(find.text('Zebra'));
    await tester.pump();
    expect(importButton(tester).onPressed, isNotNull);
    expect(find.text('Importer (1)'), findsOneWidget);

    await tester.tap(find.text('Daft Punk - Voyager'));
    await tester.pump();
    expect(find.text('Importer (2)'), findsOneWidget);

    await tester.tap(find.text('Zebra'));
    await tester.pump();
    await tester.tap(find.text('Daft Punk - Voyager'));
    await tester.pump();
    expect(find.text('Importer (0)'), findsOneWidget);
    expect(importButton(tester).onPressed, isNull);
  });

  testWidgets('« Parcourir les dossiers… » renvoie la demande de sélecteur système', (tester) async {
    final ValueNotifier<Object?> result = await pumpScreen(tester, _FakeFinder(_files));

    await tester.tap(find.text('Parcourir les dossiers…'));
    await tester.pumpAndSettle();

    expect(result.value, isA<ImportableAudioBrowse>());
  });

  testWidgets('retour arrière : aucun résultat', (tester) async {
    final ValueNotifier<Object?> result = await pumpScreen(tester, _FakeFinder(_files));

    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(result.value, isNull);
  });

  testWidgets('état vide : message et bouton « Parcourir les dossiers… » seul', (tester) async {
    final ValueNotifier<Object?> result = await pumpScreen(tester, _FakeFinder(const []));

    expect(find.text('Aucun nouveau fichier audio sur le téléphone.'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
    expect(find.text('Parcourir les dossiers…'), findsOneWidget);

    await tester.tap(find.text('Parcourir les dossiers…'));
    await tester.pumpAndSettle();
    expect(result.value, isA<ImportableAudioBrowse>());
  });

  test('formatImportableDate : aujourd\'hui, hier, sinon date courte', () {
    expect(formatImportableDate(DateTime(2026, 11, 23, 0, 5), _now), "aujourd'hui 00:05");
    expect(formatImportableDate(DateTime(2026, 11, 22, 23, 59), _now), 'hier 23:59');
    expect(formatImportableDate(DateTime(2026, 11, 21, 12, 0), _now), '21 nov. 2026');
    expect(formatImportableDate(DateTime(2026, 2, 1), _now), '1 févr. 2026');
  });

  group('LibraryScreen', () {
    late AppDatabase db;
    const MethodChannel permissions = MethodChannel('flutter.baseflow.com/permissions/methods');

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      db = AppDatabase.forTesting(NativeDatabase.memory());
      // Autorisation audio accordée (1 = granted).
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(permissions, (call) async {
        if (call.method == 'requestPermissions') {
          return {for (final Object? permission in call.arguments as List) permission as int: 1};
        }
        return 1;
      });
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(permissions, null);
      await db.close();
    });

    // La boucle d'import elle-même (AudioImportPipeline : ffmpeg, copie dans le
    // dossier de l'app) n'est pas exécutable en widget test : plugins natifs.
    // On vérifie donc le branchement jusqu'à l'écran, et le retour sans effet.
    testWidgets("« Importer des MP3 » ouvre l'écran d'import (autorisation accordée), retour sans import", (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          importableAudioFinderProvider.overrideWithValue(_FakeFinder([_files[0]])),
        ],
        child: const MaterialApp(home: LibraryScreen()),
      ));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
      await tester.pump();

      await tester.tap(find.text('Importer des MP3'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
      await tester.pumpAndSettle();
      expect(find.text('Importer des fichiers audio'), findsOneWidget);
      expect(find.text('Daft Punk - Voyager'), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Importer des fichiers audio'), findsNothing);
      expect(find.byType(SnackBar), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(Duration.zero);
    });
  });
}
