import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:playlist_app/core/storage/database/app_database.dart';
import 'package:playlist_app/core/storage/database/database_provider.dart';
import 'package:playlist_app/core/storage/database/track_repository.dart';
import 'package:playlist_app/features/playlists/data/playlist_repository.dart';
import 'package:playlist_app/features/playlists/presentation/personal_space_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() => db.close());

  Future<void> insert(String id, String title) =>
      db.into(db.playlists).insert(PlaylistsCompanion.insert(id: id, title: title));

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await tester.pumpAndSettle();
  }

  Future<void> pumpScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final GoRouter router = GoRouter(
      routes: [GoRoute(path: '/', builder: (_, __) => const PersonalSpaceScreen())],
    );
    await tester.pumpWidget(ProviderScope(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
      child: MaterialApp.router(routerConfig: router),
    ));
    await settle(tester);
  }

  Future<void> teardownTree(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(Duration.zero);
  }

  /// Menu (bouton à trois points) de la ligne portant ce titre.
  Finder menuButtonOf(String title) => find.descendant(
        of: find.widgetWithText(ListTile, title),
        matching: find.byWidgetPredicate((w) => w is PopupMenuButton),
      );

  testWidgets('playlist système : menu réduit à "Exporter en JSON"', (tester) async {
    await insert(kLikedPlaylistId, 'Titres likés');
    await insert(kAllImportedPlaylistId, 'Tous les titres importés');
    await pumpScreen(tester);

    for (final String title in ['Titres likés', 'Tous les titres importés']) {
      await tester.tap(menuButtonOf(title));
      await settle(tester);

      expect(find.text('Exporter en JSON'), findsOneWidget);
      expect(find.text('Renommer la playlist'), findsNothing);
      expect(find.text('Supprimer la playlist'), findsNothing);
      // Renommage rapide : uniquement pour « Tous les titres importés ».
      expect(find.text('Renommage rapide (importer un JSON)'),
          title == 'Tous les titres importés' ? findsOneWidget : findsNothing);

      await tester.tapAt(const Offset(5, 5)); // Ferme le menu.
      await settle(tester);
    }

    await teardownTree(tester);
  });

  testWidgets('export d\'une playlist système ouvre la fenêtre auteur', (tester) async {
    await insert(kLikedPlaylistId, 'Titres likés');
    await pumpScreen(tester);

    await tester.tap(menuButtonOf('Titres likés'));
    await settle(tester);
    await tester.tap(find.text('Exporter en JSON'));
    await settle(tester);

    expect(find.text('Exporter la playlist'), findsOneWidget);
    expect(find.textContaining('« Titres likés » sera exportée'), findsOneWidget);

    await tester.tap(find.text('Annuler'));
    await settle(tester);
    await teardownTree(tester);
  });

  testWidgets('playlist ordinaire : menu complet inchangé', (tester) async {
    await insert('a', 'Alpha');
    await pumpScreen(tester);

    await tester.tap(menuButtonOf('Alpha'));
    await settle(tester);

    expect(find.text('Exporter en JSON'), findsOneWidget);
    expect(find.text('Renommer la playlist'), findsOneWidget);
    expect(find.text('Supprimer la playlist'), findsOneWidget);
    expect(find.textContaining('Renommage rapide'), findsNothing);

    await tester.tapAt(const Offset(5, 5));
    await settle(tester);
    await teardownTree(tester);
  });
}
