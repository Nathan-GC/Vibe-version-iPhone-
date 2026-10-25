import 'package:drift/native.dart';
import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/storage/database/app_database.dart';
import 'package:playlist_app/core/storage/database/database_provider.dart';
import 'package:playlist_app/core/theme/vibe_engine/vibe_engine.dart';
import 'package:playlist_app/features/playlists/presentation/vibe_customizer/vibe_customizer_screen.dart';

void main() {
  late AppDatabase db;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.into(db.playlists).insert(PlaylistsCompanion.insert(id: 'p', title: 'Test'));
  });

  tearDown(() => db.close());

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await tester.pumpAndSettle();
  }

  Future<void> pumpScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
      child: const MaterialApp(home: VibeCustomizerScreen(playlistId: 'p')),
    ));
    await settle(tester);
  }

  Future<void> teardownTree(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(Duration.zero);
  }

  Future<Playlist> savedPlaylist(WidgetTester tester) async {
    final Finder apply = find.text('Appliquer la Vibe personnalisée');
    await tester.ensureVisible(apply);
    await tester.tap(apply);
    await settle(tester);
    return (await tester.runAsync(() => db.select(db.playlists).getSingle()))!;
  }

  testWidgets('"Aucune couleur" clears the gradient and saves the transparent sentinel', (tester) async {
    await pumpScreen(tester);

    await tester.tap(find.text('Aucune couleur'));
    await tester.pump();
    expect(find.textContaining('Ordre du dégradé'), findsNothing);

    final Playlist saved = await savedPlaylist(tester);
    expect(saved.bgColors, ['00000000']);
    expect(saved.vibeStyle, VibePreset.custom);

    await teardownTree(tester);
  });

  testWidgets('picking a colour after "Aucune couleur" deselects it', (tester) async {
    await pumpScreen(tester);

    await tester.tap(find.text('Aucune couleur'));
    await tester.pump();
    await tester.tap(find.byWidgetPredicate((widget) {
      if (widget is! Container) return false;
      final Decoration? decoration = widget.decoration;
      return decoration is BoxDecoration && decoration.color == const Color(0xFFFF3D68);
    }).first);
    await tester.pump();

    final Playlist saved = await savedPlaylist(tester);
    expect(saved.bgColors, ['FFFF3D68']);

    await teardownTree(tester);
  });

  testWidgets('dragging the second colour before the first reverses the saved order', (tester) async {
    await pumpScreen(tester);

    final Finder items = find.bySemanticsLabel(RegExp('Couleur . sur 2'));
    expect(items, findsNWidgets(2));
    final Offset first = tester.getCenter(items.at(0));
    final Offset second = tester.getCenter(items.at(1));

    final TestGesture gesture = await tester.startGesture(second);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    for (int step = 1; step <= 8; step++) {
      await gesture.moveTo(second + (first - second) * (step / 8) - const Offset(10, 0));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    final Playlist saved = await savedPlaylist(tester);
    expect(saved.bgColors, ['FF00F0FF', 'FFFF3D68']);

    await teardownTree(tester);
  });
}
