import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:playlist_app/core/shared/widgets/playlist_card.dart';
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

  Future<void> insert(String id, String title, {String? manifestId}) => db
      .into(db.playlists)
      .insert(PlaylistsCompanion.insert(id: id, title: title, sourceManifestId: Value(manifestId)));

  Future<void> seedAll() async {
    await insert(kAllImportedPlaylistId, 'Tous les titres importés');
    await insert(kLikedPlaylistId, 'Titres likés');
    await insert('a', 'Alpha');
    await insert('i', 'Importée', manifestId: 'm1');
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await tester.pumpAndSettle();
  }

  Future<void> pumpScreen(WidgetTester tester) async {
    // Écran haut : toutes les sections sont construites sans défilement.
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final GoRouter router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, __) => const PersonalSpaceScreen()),
        GoRoute(path: '/space/playlist/:id/edit', builder: (_, __) => const Scaffold(body: Text('EDITEUR'))),
      ],
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

  Finder cardWithin(String title) => find.descendant(of: find.byType(PlaylistCard), matching: find.text(title));

  testWidgets('three carousels hold the right playlists', (tester) async {
    await seedAll();
    await pumpScreen(tester);

    expect(find.byType(PlaylistCard), findsNWidgets(4));
    expect(cardWithin('Alpha'), findsOneWidget);
    expect(cardWithin('Importée'), findsOneWidget);
    expect(cardWithin('Tous les titres importés'), findsOneWidget);
    expect(cardWithin('Titres likés'), findsOneWidget);
    // Ordre : créées, auto, importées.
    final double created = tester.getTopLeft(cardWithin('Alpha')).dy;
    final double auto = tester.getTopLeft(cardWithin('Titres likés')).dy;
    final double imported = tester.getTopLeft(cardWithin('Importée')).dy;
    expect(created, lessThan(auto));
    expect(auto, lessThan(imported));

    await teardownTree(tester);
  });

  testWidgets('imported carousel and section are absent without imported playlists', (tester) async {
    await insert('a', 'Alpha');
    await insert(kLikedPlaylistId, 'Titres likés');
    await pumpScreen(tester);

    expect(find.text('Playlists importées'), findsNothing);
    expect(find.byTooltip('Replier la section Playlists importées'), findsNothing);
    expect(find.byTooltip('Replier la section Playlists créées'), findsOneWidget);
    expect(find.byTooltip('Replier la section Playlists automatiques'), findsOneWidget);

    await teardownTree(tester);
  });

  testWidgets('created section shows the invitation when empty', (tester) async {
    await insert(kLikedPlaylistId, 'Titres likés');
    await pumpScreen(tester);

    expect(find.textContaining('Touche le bouton "+"'), findsOneWidget);
    expect(find.byTooltip('Replier la section Playlists créées'), findsOneWidget);

    await teardownTree(tester);
  });

  testWidgets('collapsing a section hides its tiles and is remembered', (tester) async {
    await seedAll();
    await pumpScreen(tester);

    expect(find.widgetWithText(ListTile, 'Alpha'), findsOneWidget);
    await tester.tap(find.byTooltip('Replier la section Playlists créées'));
    await settle(tester);

    expect(find.widgetWithText(ListTile, 'Alpha'), findsNothing);
    expect(find.byTooltip('Déplier la section Playlists créées'), findsOneWidget);
    // Les autres sections restent dépliées.
    expect(find.widgetWithText(ListTile, 'Importée'), findsOneWidget);
    expect((await SharedPreferences.getInstance()).getBool('personal_space_collapsed_created'), isTrue);

    // Réouverture de l'écran : l'état replié est restauré.
    await teardownTree(tester);
    await pumpScreen(tester);
    expect(find.widgetWithText(ListTile, 'Alpha'), findsNothing);
    expect(find.byTooltip('Déplier la section Playlists créées'), findsOneWidget);

    await tester.tap(find.byTooltip('Déplier la section Playlists créées'));
    await settle(tester);
    expect(find.widgetWithText(ListTile, 'Alpha'), findsOneWidget);
    expect((await SharedPreferences.getInstance()).getBool('personal_space_collapsed_created'), isFalse);

    await teardownTree(tester);
  });

  testWidgets('long-press on a list tile opens the editor', (tester) async {
    await seedAll();
    await pumpScreen(tester);

    await tester.longPress(find.widgetWithText(ListTile, 'Alpha'));
    await settle(tester);
    expect(find.text('EDITEUR'), findsOneWidget);

    await teardownTree(tester);
  });
}
