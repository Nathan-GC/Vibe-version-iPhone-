import 'package:drift/drift.dart' show OrderingTerm;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/shared/widgets/add_to_playlist_sheet.dart';
import 'package:playlist_app/core/storage/database/app_database.dart';
import 'package:playlist_app/core/storage/database/database_provider.dart';
import 'package:playlist_app/core/storage/database/track_repository.dart';
import 'package:playlist_app/core/storage/scanner/scanned_track.dart';

void main() {
  late AppDatabase db;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await TrackRepository(db).upsertTrack(const ScannedTrack(
      id: 't1',
      title: 'Ma chanson',
      album: '',
      primaryArtist: 'Artist',
      artists: ['Artist'],
      filePath: '/music/t1.mp3',
      durationMs: 180000,
      requiresUserReview: false,
      trimStartMs: 0,
      trimEndMs: 0,
    ));
    await db.into(db.playlists).insert(PlaylistsCompanion.insert(id: 'p', title: 'Mix'));
  });

  tearDown(() => db.close());

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await tester.pumpAndSettle();
  }

  Future<List<PlaylistTrack>> rows(WidgetTester tester) async {
    return (await tester.runAsync(
      () => (db.select(db.playlistTracks)
            ..where((t) => t.playlistId.equals('p'))
            ..orderBy([(t) => OrderingTerm.asc(t.position)]))
          .get(),
    ))!;
  }

  Future<void> openSheet(WidgetTester tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => AddToPlaylistSheet.show(context, 't1'),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await settle(tester);
  }

  Future<void> openSheetAgain(WidgetTester tester) async {
    await tester.tap(find.text('open'));
    await settle(tester);
  }

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(Duration.zero);
  }

  testWidgets('added: confirmation snackbar, then Annuler removes the row', (tester) async {
    await openSheet(tester);
    await tester.tap(find.text('Mix'));
    await settle(tester);

    expect(find.text('"Ma chanson" a été ajouté à la playlist "Mix"'), findsOneWidget);
    expect((await rows(tester)).length, 1);

    await tester.tap(find.text('Annuler'));
    await settle(tester);
    expect(await rows(tester), isEmpty);

    await dispose(tester);
  });

  testWidgets('already present: error snackbar, nothing rewritten', (tester) async {
    await tester.runAsync(() => db.into(db.playlistTracks).insert(
          PlaylistTracksCompanion.insert(playlistId: 'p', trackId: 't1', position: 5),
        ));
    await openSheet(tester);
    await tester.tap(find.text('Mix'));
    await settle(tester);

    expect(find.text('Ce titre est déjà présent dans la playlist'), findsOneWidget);
    expect(find.text('Annuler'), findsNothing);
    final List<PlaylistTrack> after = await rows(tester);
    expect(after.length, 1);
    expect(after.single.position, 5);

    await dispose(tester);
  });

  testWidgets('add then duplicate: the red alert replaces the confirmation', (tester) async {
    await openSheet(tester);
    await tester.tap(find.text('Mix'));
    await settle(tester);
    expect(find.text('Annuler'), findsOneWidget);

    await openSheetAgain(tester);
    await tester.tap(find.text('Mix'));
    await settle(tester);

    expect(find.text('Ce titre est déjà présent dans la playlist'), findsOneWidget);
    expect(find.text('Annuler'), findsNothing);

    await dispose(tester);
  });

  test('truncateTitle keeps short titles and cuts long ones at 30 chars + ellipsis', () {
    expect(truncateTitle('Court'), 'Court');
    expect(truncateTitle('a' * 30), 'a' * 30);
    expect(truncateTitle('a' * 31), '${'a' * 30}…');
    // Un emoji compte pour un caractère et n'est jamais coupé en deux.
    expect(truncateTitle('${'a' * 29}🎧🎶'), '${'a' * 29}🎧…');
  });
}
