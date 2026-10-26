import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/shared/widgets/playlist_cover_image.dart';
import 'package:playlist_app/core/storage/database/app_database.dart';
import 'package:playlist_app/features/playlists/data/playlist_providers.dart';
import 'package:playlist_app/features/playlists/domain/playlist_editor_entry.dart';

void main() {
  late AppDatabase db;
  late Playlist playlist;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.into(db.playlists).insert(PlaylistsCompanion.insert(id: 'p', title: 'P'));
    playlist = await (db.select(db.playlists)..where((p) => p.id.equals('p'))).getSingle();
  });

  tearDown(() => db.close());

  Future<void> pumpWith(WidgetTester tester, List<String> covers) async {
    final List<PlaylistEditorEntry> entries = [];
    for (int i = 0; i < covers.length; i++) {
      await db.into(db.tracks).insert(TracksCompanion.insert(
          id: 't$i',
          title: 'T$i',
          album: '',
          artists: const ['A'],
          durationSeconds: 100,
          filePath: '/m/$i.mp3',
          coverArtPath: Value(covers[i])));
      final Track track = await (db.select(db.tracks)..where((t) => t.id.equals('t$i'))).getSingle();
      entries.add(PlaylistEditorEntry(track: track, isPendingPlacement: false, position: i));
    }
    await tester.pumpWidget(ProviderScope(
      overrides: [playlistEditorEntriesProvider('p').overrideWith((ref) => Stream.value(entries))],
      child: MaterialApp(
        home: SizedBox(width: 200, height: 200, child: PlaylistCoverImage(playlist: playlist)),
      ),
    ));
    await tester.pump();
    await tester.pump();
  }

  Iterable<Image> images(WidgetTester tester) => tester.widgetList<Image>(find.byType(Image));

  testWidgets('une seule pochette locale -> une image pleine carte', (tester) async {
    await pumpWith(tester, ['', '/c/a.jpg', '/c/a.jpg']);
    expect(images(tester), hasLength(1));
    expect(find.byType(GridView), findsNothing);
  });

  testWidgets('4 pochettes distinctes -> grille 2x2, titres sans pochette en tête ignorés', (tester) async {
    await pumpWith(tester, ['', '/c/1.jpg', '/c/2.jpg', '/c/3.jpg', '/c/4.jpg']);
    expect(find.byType(GridView), findsOneWidget);
    expect(images(tester), hasLength(4));
  });

  testWidgets('pochettes http seulement -> repli Vibe, aucun NetworkImage', (tester) async {
    await pumpWith(tester, ['https://x.test/a.jpg', 'http://x.test/b.jpg']);
    expect(images(tester), isEmpty);
    expect(find.byIcon(Icons.queue_music), findsOneWidget);
  });

  testWidgets('aucun NetworkImage même mêlé à des locales', (tester) async {
    await pumpWith(tester, ['https://x.test/a.jpg', '/c/1.jpg']);
    expect(images(tester).map((i) => i.image), everyElement(isNot(isA<NetworkImage>())));
  });
}
