import 'package:drift/drift.dart' show OrderingTerm, Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/storage/database/app_database.dart';
import 'package:playlist_app/core/storage/database/database_provider.dart';
import 'package:playlist_app/features/playlists/presentation/editor/playlist_editor_screen.dart';

void main() {
  late AppDatabase db;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.into(db.playlists).insert(PlaylistsCompanion.insert(id: 'p', title: 'Ma playlist'));
    for (int p = 1; p <= 12; p++) {
      await db.into(db.tracks).insert(TracksCompanion.insert(
          id: 't$p', title: 'Track $p', album: '', artists: const ['A'], durationSeconds: 180, filePath: '/m/t$p.mp3'));
      await db.into(db.playlistTracks).insert(PlaylistTracksCompanion.insert(
          playlistId: 'p', trackId: 't$p', position: p - 1, isPendingPlacement: const Value(false)));
    }
  });

  tearDown(() => db.close());

  Future<List<String>> savedOrder(WidgetTester tester) async {
    final List<PlaylistTrack> rows = (await tester.runAsync(() => (db.select(db.playlistTracks)
          ..where((t) => t.playlistId.equals('p'))
          ..orderBy([(t) => OrderingTerm.asc(t.position)]))
        .get()))!;
    return [for (final row in rows) row.trackId];
  }

  testWidgets('ticks scattered tracks, moves them as one block and saves the new order atomically (Lot 3.2)',
      (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(ProviderScope(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
      child: const MaterialApp(home: PlaylistEditorScreen(playlistId: 'p')),
    ));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Réorganisation intelligente'));
    await tester.pumpAndSettle();
    // Temps 1 : sélection par simple appui (le long-appui reste aux actions du titre).
    for (final String title in ['Track 2', 'Track 5', 'Track 8']) {
      await tester.tap(find.text(title));
    }
    await tester.pumpAndSettle();
    expect(find.text('3 titres sélectionnés'), findsOneWidget);

    // Temps 2 : position cible du bloc.
    await tester.tap(find.text('Déplacer…'));
    await tester.pumpAndSettle();
    expect(find.textContaining('De 1 à 10'), findsOneWidget,
        reason: '12 titres, 3 déplacés : 10 positions de départ possibles');
    await tester.enterText(find.byType(TextField), '10');
    await tester.tap(find.text('Déplacer'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();

    expect(await savedOrder(tester), ['t1', 't3', 't4', 't6', 't7', 't9', 't10', 't11', 't12', 't2', 't5', 't8']);
    expect(find.text('3 titres regroupés en positions 10 à 12'), findsOneWidget);
    expect(find.text('Aucun titre sélectionné'), findsOneWidget, reason: 'prêt pour un nouveau regroupement');

    // Démontage : Drift arme un `Timer.run` à la fermeture de chaque flux
    // surveillé — l'horloge simulée doit avancer pour le déclencher, sans
    // quoi `db.close()` (tearDown) l'attendrait indéfiniment.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(Duration.zero);
  });
}
