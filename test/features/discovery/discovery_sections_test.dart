import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:playlist_app/core/navigation/active_tab_provider.dart';
import 'package:playlist_app/core/shared/widgets/playlist_card.dart';
import 'package:playlist_app/core/storage/database/app_database.dart';
import 'package:playlist_app/core/storage/database/database_provider.dart';
import 'package:playlist_app/core/storage/database/track_repository.dart';
import 'package:playlist_app/features/discovery/data/autocomplete_providers.dart';
import 'package:playlist_app/features/discovery/data/search_providers.dart';
import 'package:playlist_app/features/discovery/domain/search_result.dart';
import 'package:playlist_app/features/discovery/presentation/discovery_screen.dart';
import 'package:playlist_app/features/playlists/data/playlist_repository.dart';
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

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await tester.pumpAndSettle();
  }

  Future<ProviderContainer> pumpScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final GoRouter router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, __) => const DiscoveryScreen()),
        GoRoute(path: '/space/playlist/:id/edit', builder: (_, __) => const Scaffold(body: Text('EDITEUR'))),
      ],
    );
    final ProviderContainer container = ProviderContainer(overrides: [
      appDatabaseProvider.overrideWithValue(db),
      // Aucun appel réseau : toute requête soumise renvoie une liste vide.
      searchResultsProvider.overrideWith((ref) async => <SearchResult>[]),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ));
    await settle(tester);
    return container;
  }

  Future<void> teardownTree(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(Duration.zero);
  }

  Finder cardWithin(String title) => find.descendant(of: find.byType(PlaylistCard), matching: find.text(title));

  testWidgets('four carousels in order, imported one present', (tester) async {
    await insert(kAllImportedPlaylistId, 'Tous les titres importés');
    await insert(kLikedPlaylistId, 'Titres likés');
    await insert('a', 'Alpha');
    await insert('i', 'Importée', manifestId: 'm1');
    await pumpScreen(tester);

    expect(find.text('Mes playlists'), findsOneWidget);
    expect(find.text('Playlists auto'), findsOneWidget);
    expect(find.text('Playlists importées'), findsOneWidget);
    expect(find.byType(PlaylistCard), findsNWidgets(4));
    final double created = tester.getTopLeft(cardWithin('Alpha')).dy;
    final double auto = tester.getTopLeft(cardWithin('Titres likés')).dy;
    final double imported = tester.getTopLeft(cardWithin('Importée')).dy;
    expect(created, lessThan(auto));
    expect(auto, lessThan(imported));
    expect(cardWithin('Tous les titres importés'), findsOneWidget);

    await teardownTree(tester);
  });

  testWidgets('imported carousel is absent without imported playlists', (tester) async {
    await insert(kLikedPlaylistId, 'Titres likés');
    await insert('a', 'Alpha');
    await pumpScreen(tester);

    expect(find.text('Mes playlists'), findsOneWidget);
    expect(find.text('Playlists auto'), findsOneWidget);
    expect(find.text('Playlists importées'), findsNothing);

    await teardownTree(tester);
  });

  testWidgets('long-press on a playlist card opens the editor', (tester) async {
    await insert('a', 'Alpha');
    await pumpScreen(tester);

    await tester.longPress(cardWithin('Alpha'));
    await settle(tester);
    expect(find.text('EDITEUR'), findsOneWidget);

    await teardownTree(tester);
  });

  testWidgets('search is cleared when the active tab changes', (tester) async {
    await insert('a', 'Alpha');
    final ProviderContainer container = await pumpScreen(tester);

    await tester.enterText(find.byType(TextField), 'a');
    container.read(searchQueryProvider.notifier).set('zzz');
    await settle(tester);
    expect(find.text('Aucun résultat.'), findsOneWidget);
    expect(find.byType(PlaylistCard), findsNothing);

    container.read(activeTabIndexProvider.notifier).set(1);
    await settle(tester);

    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
    expect(container.read(searchQueryProvider), isEmpty);
    expect(container.read(liveQueryProvider), isEmpty);
    expect(container.read(debouncedAutocompleteQueryProvider), isEmpty);
    expect(find.byType(PlaylistCard), findsOneWidget);

    await teardownTree(tester);
  });
}
