import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/storage/database/app_database.dart';
import 'package:playlist_app/core/storage/database/database_provider.dart';
import 'package:playlist_app/core/storage/database/track_repository.dart';
import 'package:playlist_app/features/playlists/data/playlist_providers.dart';
import 'package:playlist_app/features/playlists/data/playlist_track_repository.dart';
import 'package:playlist_app/features/playlists/presentation/editor/playlist_editor_screen.dart';

const String _title = 'Attention, vous n\'avez pas enregistré';

void main() {
  late AppDatabase db;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.into(db.playlists).insert(PlaylistsCompanion.insert(id: 'p', title: 'Ma playlist'));
    await db.into(db.playlists).insert(PlaylistsCompanion.insert(id: kAllImportedPlaylistId, title: 'Tous'));
    for (int n = 1; n <= 2; n++) {
      await db.into(db.tracks).insert(TracksCompanion.insert(
          id: 't$n', title: 'Track $n', album: '', artists: const ['A'], durationSeconds: 180, filePath: '/m/t$n.mp3'));
    }
  });

  tearDown(() => db.close());

  /// t1 déjà enregistré (ni ambre ni ajout récent) ; t2 ajouté ensuite : ambre + `addedSinceSave`.
  Future<void> seedSavedPlusAdded(WidgetTester tester) => tester.runAsync(() async {
        final PlaylistTrackRepository repo = PlaylistTrackRepository(db);
        await repo.addTrack('p', 't1');
        await (db.update(db.playlistTracks))
            .write(const PlaylistTracksCompanion(isPendingPlacement: Value(false), addedSinceSave: Value(false)));
        await repo.addTrack('p', 't2');
      });

  Future<List<PlaylistTrack>> dbRows(WidgetTester tester, [String playlistId = 'p']) async => (await tester
      .runAsync(() => (db.select(db.playlistTracks)..where((t) => t.playlistId.equals(playlistId))).get()))!;

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await tester.pumpAndSettle();
  }

  /// Monte une page d'accueil qui POUSSE l'éditeur (le retour passe ainsi par le Navigator).
  Future<void> openEditor(WidgetTester tester, {String playlistId = 'p', ProviderContainer? container}) async {
    final Widget app = MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute<void>(builder: (_) => PlaylistEditorScreen(playlistId: playlistId))),
            child: const Text('ouvrir'),
          ),
        ),
      ),
    );
    await tester.pumpWidget(container == null
        ? ProviderScope(overrides: [appDatabaseProvider.overrideWithValue(db)], child: app)
        : UncontrolledProviderScope(container: container, child: app));
    await tester.tap(find.text('ouvrir'));
    await tester.pump(); // construit la route : initState lance la lecture fraîche
    await settle(tester);
  }

  Future<void> pressBack(WidgetTester tester) async {
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
  }

  Future<void> teardownTree(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(Duration.zero);
  }

  testWidgets('shows a track added to the playlist before opening on the very first open', (tester) async {
    await seedSavedPlusAdded(tester);
    // Provider réchauffé AVANT l'ajout : sa valeur en cache est périmée.
    final ProviderContainer container = ProviderContainer(overrides: [appDatabaseProvider.overrideWithValue(db)]);
    addTearDown(container.dispose);
    final ProviderSubscription<Object?> sub = container.listen(playlistEditorEntriesProvider('p'), (_, __) {});
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await tester.runAsync(() => db.into(db.tracks).insert(TracksCompanion.insert(
        id: 't3', title: 'Track 3', album: '', artists: const ['A'], durationSeconds: 180, filePath: '/m/t3.mp3')));
    await tester.runAsync(() => PlaylistTrackRepository(db).addTrack('p', 't3'));

    await openEditor(tester, container: container);

    expect(find.text('Track 1'), findsOneWidget);
    expect(find.text('Track 2'), findsOneWidget);
    expect(find.text('Track 3'), findsOneWidget);

    sub.close();
    await teardownTree(tester);
  });

  testWidgets('leaves silently when nothing is unsaved', (tester) async {
    await tester.runAsync(() async {
      await PlaylistTrackRepository(db).addTrack('p', 't1');
      await db
          .update(db.playlistTracks)
          .write(const PlaylistTracksCompanion(isPendingPlacement: Value(false), addedSinceSave: Value(false)));
    });
    await openEditor(tester);
    expect(find.byType(PlaylistEditorScreen), findsOneWidget);

    await pressBack(tester);

    expect(find.text(_title), findsNothing);
    expect(find.byType(PlaylistEditorScreen), findsNothing);
    await teardownTree(tester);
  });

  testWidgets('asks what to do when an orange track exists, and dismissing keeps the editor open', (tester) async {
    await seedSavedPlusAdded(tester);
    await openEditor(tester);

    await pressBack(tester);

    expect(find.text(_title), findsOneWidget);
    expect(find.text('Enregistrer'), findsOneWidget);
    expect(find.text('Enregistrer partiellement'), findsOneWidget);
    expect(find.text('Ne pas enregistrer'), findsOneWidget);

    await tester.tapAt(const Offset(4, 4)); // hors du dialogue
    await tester.pumpAndSettle();

    expect(find.text(_title), findsNothing);
    expect(find.byType(PlaylistEditorScreen), findsOneWidget);
    await teardownTree(tester);
  });

  testWidgets('"Ne pas enregistrer" leaves directly when no track was added since the last save', (tester) async {
    // Titre encore ambre (enregistrement partiel précédent) mais aucun ajout récent.
    await tester.runAsync(() async {
      await PlaylistTrackRepository(db).addTrack('p', 't1');
      await db.update(db.playlistTracks).write(const PlaylistTracksCompanion(addedSinceSave: Value(false)));
    });
    await openEditor(tester);

    await pressBack(tester);
    await tester.tap(find.text('Ne pas enregistrer'));
    await settle(tester);

    expect(find.text('Conserver les titres ajoutés'), findsNothing);
    expect(find.byType(PlaylistEditorScreen), findsNothing);
    expect((await dbRows(tester)).single.isPendingPlacement, isTrue, reason: 'rien enregistré');
    await teardownTree(tester);
  });

  testWidgets('"Enregistrer" clears the orange flags and leaves', (tester) async {
    await seedSavedPlusAdded(tester);
    await openEditor(tester);

    await pressBack(tester);
    await tester.tap(find.text('Enregistrer'));
    await settle(tester);

    expect(find.byType(PlaylistEditorScreen), findsNothing);
    final List<PlaylistTrack> rows = await dbRows(tester);
    expect(rows, hasLength(2));
    expect(rows.every((r) => !r.isPendingPlacement && !r.addedSinceSave), isTrue);
    await teardownTree(tester);
  });

  testWidgets('"Enregistrer partiellement" saves but the new track stays orange in the database', (tester) async {
    await seedSavedPlusAdded(tester);
    await openEditor(tester);

    await pressBack(tester);
    await tester.tap(find.text('Enregistrer partiellement'));
    await settle(tester);

    expect(find.byType(PlaylistEditorScreen), findsNothing);
    final List<PlaylistTrack> rows = await dbRows(tester);
    final PlaylistTrack t2 = rows.singleWhere((r) => r.trackId == 't2');
    expect(t2.isPendingPlacement, isTrue);
    expect(t2.addedSinceSave, isFalse);
    expect(rows.singleWhere((r) => r.trackId == 't1').isPendingPlacement, isFalse);
    await teardownTree(tester);
  });

  testWidgets('"Ne pas enregistrer" then "Ne pas conserver les nouveaux titres" removes the added track',
      (tester) async {
    await seedSavedPlusAdded(tester);
    await openEditor(tester);

    await pressBack(tester);
    await tester.tap(find.text('Ne pas enregistrer'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ne pas conserver les nouveaux titres'));
    await settle(tester);

    expect(find.byType(PlaylistEditorScreen), findsNothing);
    expect([for (final r in await dbRows(tester)) r.trackId], ['t1']);
    await teardownTree(tester);
  });

  testWidgets('"Ne pas enregistrer" then "Conserver les titres ajoutés" leaves the database untouched', (tester) async {
    await seedSavedPlusAdded(tester);
    await openEditor(tester);

    await pressBack(tester);
    await tester.tap(find.text('Ne pas enregistrer'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Conserver les titres ajoutés'));
    await settle(tester);

    expect(find.byType(PlaylistEditorScreen), findsNothing);
    final PlaylistTrack t2 = (await dbRows(tester)).singleWhere((r) => r.trackId == 't2');
    expect(t2.isPendingPlacement, isTrue);
    expect(t2.addedSinceSave, isTrue);
    await teardownTree(tester);
  });

  testWidgets('dismissing the second dialog keeps the editor open', (tester) async {
    await seedSavedPlusAdded(tester);
    await openEditor(tester);

    await pressBack(tester);
    await tester.tap(find.text('Ne pas enregistrer'));
    await tester.pumpAndSettle();
    expect(find.text('Ne pas conserver les nouveaux titres'), findsOneWidget);
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();

    expect(find.byType(PlaylistEditorScreen), findsOneWidget);
    expect(find.text('Ne pas conserver les nouveaux titres'), findsNothing);
    expect(await dbRows(tester), hasLength(2));
    await teardownTree(tester);
  });

  testWidgets('all-imported playlist: "Ne pas enregistrer" leaves directly, without a second dialog', (tester) async {
    await tester.runAsync(() async {
      await db.into(db.playlistTracks).insert(PlaylistTracksCompanion.insert(
          playlistId: kAllImportedPlaylistId, trackId: 't1', position: 0, addedSinceSave: const Value(true)));
    });
    await openEditor(tester, playlistId: kAllImportedPlaylistId);

    await pressBack(tester);
    await tester.tap(find.text('Ne pas enregistrer'));
    await settle(tester);

    expect(find.text('Ne pas conserver les nouveaux titres'), findsNothing);
    expect(find.byType(PlaylistEditorScreen), findsNothing);
    expect(await dbRows(tester, kAllImportedPlaylistId), hasLength(1));
    await teardownTree(tester);
  });
}
