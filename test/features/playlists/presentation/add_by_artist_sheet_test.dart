import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/storage/database/app_database.dart';
import 'package:playlist_app/core/storage/database/database_provider.dart';
import 'package:playlist_app/core/storage/database/track_repository.dart';
import 'package:playlist_app/core/storage/scanner/scanned_track.dart';
import 'package:playlist_app/features/playlists/presentation/editor/add_by_artist_sheet.dart';

void main() {
  late AppDatabase db;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.into(db.playlists).insert(PlaylistsCompanion.insert(id: 'p', title: 'Mix'));
    final TrackRepository repo = TrackRepository(db);
    Future<void> add(String id, String artist) => repo.upsertTrack(ScannedTrack(
          id: id,
          title: 'Title $id',
          album: '',
          primaryArtist: artist,
          artists: [artist],
          filePath: '/music/$id.mp3',
          durationMs: 180000,
          requiresUserReview: false,
          trimStartMs: 0,
          trimEndMs: 0,
        ));
    // Gros : 4 titres dont 1 déjà dans la playlist -> 3 à ajouter.
    for (int n = 1; n <= 4; n++) {
      await add('g$n', 'Gros');
    }
    // Complet : 3 titres tous dans la playlist.
    for (int n = 1; n <= 3; n++) {
      await add('c$n', 'Complet');
    }
    // Petit : 1 seul titre, absent de la playlist.
    await add('s1', 'Petit');
    // Deux : 2 titres, sous le seuil.
    await add('d1', 'Deux');
    await add('d2', 'Deux');
    // Un seul manquant.
    for (int n = 1; n <= 3; n++) {
      await add('m$n', 'Presque');
    }
    for (final String id in ['g1', 'c1', 'c2', 'c3', 'm1', 'm2']) {
      await db.into(db.playlistTracks).insert(PlaylistTracksCompanion.insert(playlistId: 'p', trackId: id, position: 0));
    }
  });

  tearDown(() => db.close());

  Future<void> openSheet(WidgetTester tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
      child: const MaterialApp(home: Scaffold(body: AddByArtistSheet(playlistId: 'p'))),
    ));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await tester.pumpAndSettle();
  }

  Future<void> teardownTree(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(Duration.zero);
  }

  testWidgets('without search, lists only artists with 3+ tracks and something to add', (tester) async {
    await openSheet(tester);

    expect(find.text('Gros'), findsOneWidget);
    expect(find.text('3 titres à ajouter'), findsOneWidget);
    expect(find.text('Presque'), findsOneWidget);
    expect(find.text('1 titre à ajouter'), findsOneWidget);
    expect(find.text('Complet'), findsNothing);
    expect(find.text('Petit'), findsNothing);
    expect(find.text('Deux'), findsNothing);

    await teardownTree(tester);
  });

  testWidgets('with search, ignores the threshold and greys out fully added artists', (tester) async {
    await openSheet(tester);

    await tester.enterText(find.byType(TextField), 'petit');
    await tester.pumpAndSettle();
    expect(find.text('Petit'), findsOneWidget);
    expect(find.text('1 titre à ajouter'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'complet');
    await tester.pumpAndSettle();
    expect(find.text('Complet'), findsOneWidget);
    expect(find.text('Déjà dans la playlist'), findsOneWidget);

    await teardownTree(tester);
  });
}
