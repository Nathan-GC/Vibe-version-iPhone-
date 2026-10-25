import 'package:drift/native.dart';
import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:playlist_app/core/shared/widgets/playlist_card.dart';
import 'package:playlist_app/core/storage/database/app_database.dart';
import 'package:playlist_app/core/storage/database/database_provider.dart';
import 'package:playlist_app/core/storage/database/track_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:playlist_app/features/playlists/presentation/personal_space_screen.dart';

void main() {
  late AppDatabase db;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase.forTesting(NativeDatabase.memory());
    for (final (String id, String title) in [
      (kAllImportedPlaylistId, 'Tous les titres importés'),
      ('a', 'Alpha'),
      ('b', 'Bravo'),
      ('c', 'Charlie'),
    ]) {
      await db.into(db.playlists).insert(PlaylistsCompanion.insert(id: id, title: title));
    }
  });

  tearDown(() => db.close());

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

  testWidgets('carousel includes all-imported (also in the list) and long-press does not open the editor',
      (tester) async {
    await pumpScreen(tester);

    expect(find.byType(PlaylistCard), findsNWidgets(4));
    expect(find.descendant(of: find.byType(PlaylistCard), matching: find.text('Tous les titres importés')),
        findsOneWidget);
    expect(find.byType(ListTile), findsNWidgets(4));
    expect(find.widgetWithText(ListTile, 'Tous les titres importés'), findsOneWidget);

    await tester.longPress(find.text('Alpha').first);
    await settle(tester);
    expect(find.text('EDITEUR'), findsNothing);

    await teardownTree(tester);
  });

  testWidgets('long-press then drag reorders the carousel and persists the order', (tester) async {
    await pumpScreen(tester);

    final Offset start = tester.getCenter(find.text('Alpha').first);
    final TestGesture gesture = await tester.startGesture(start);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    for (int i = 0; i < 20; i++) {
      await gesture.moveBy(const Offset(25, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await settle(tester);

    final List<Playlist> stored = (await tester.runAsync(() => (db.select(db.playlists)).get()))!;
    final Map<String, int?> positions = {for (final Playlist p in stored) p.id: p.carouselPosition};
    expect(positions['a'], isNot(0), reason: 'Alpha doit avoir quitté la première place');
    expect(positions['a'], isNotNull);
    expect(find.text('EDITEUR'), findsNothing);

    await teardownTree(tester);
  });
}
