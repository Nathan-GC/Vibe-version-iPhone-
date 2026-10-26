import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/storage/database/app_database.dart';
import 'package:playlist_app/core/storage/database/database_provider.dart';
import 'package:playlist_app/features/library/data/library_providers.dart';

void main() {
  testWidgets('libraryTracksProvider: created_at égal -> titre asc puis id asc', (tester) async {
    final AppDatabase db = AppDatabase.forTesting(NativeDatabase.memory());
    final DateTime same = DateTime(2026, 1, 1);
    for (final (String id, String title) in [('3', 'B'), ('2', 'B'), ('1', 'A')]) {
      await db.into(db.tracks).insert(TracksCompanion.insert(
            id: id,
            title: title,
            filePath: '/m/$id.mp3',
            album: '',
            artists: const ['X'],
            durationSeconds: 1,
            createdAt: Value(same),
          ));
    }
    final ProviderContainer container = ProviderContainer(overrides: [appDatabaseProvider.overrideWithValue(db)]);
    final ProviderSubscription<AsyncValue<List<Track>>> sub = container.listen(libraryTracksProvider, (_, __) {});
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    final List<Track> tracks = sub.read().requireValue;
    expect(tracks.map((t) => t.id), ['1', '2', '3']);
    sub.close();
    container.dispose();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(Duration.zero);
    await db.close();
  });
}
