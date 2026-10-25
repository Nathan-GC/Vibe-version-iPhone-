import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/storage/database/app_database.dart';
import 'package:playlist_app/core/storage/database/track_repository.dart';
import 'package:playlist_app/features/playlists/data/drift_playlist_repository.dart';

void main() {
  late AppDatabase db;
  late DriftPlaylistRepository repo;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = DriftPlaylistRepository(db);
    // Ordre de création : all-imported, a, b, c.
    for (final String id in [kAllImportedPlaylistId, 'a', 'b', 'c']) {
      await db.into(db.playlists).insert(PlaylistsCompanion.insert(id: id, title: id));
    }
  });

  tearDown(() => db.close());

  Future<List<String>> carouselIds() async => (await repo.watchCarousel().first).map((p) => p.id).toList();

  test('carousel excludes all-imported and keeps creation order when never ordered', () async {
    expect(await carouselIds(), ['a', 'b', 'c']);
  });

  test('reorderCarousel persists positions; playlists without position come after, in creation order', () async {
    await repo.reorderCarousel(['c', 'a']);
    expect(await carouselIds(), ['c', 'a', 'b']);

    // Nouvelle playlist : en fin de carrousel.
    await db.into(db.playlists).insert(PlaylistsCompanion.insert(id: 'd', title: 'd'));
    expect(await carouselIds(), ['c', 'a', 'b', 'd']);

    await repo.reorderCarousel(['d', 'b', 'a', 'c']);
    expect(await carouselIds(), ['d', 'b', 'a', 'c']);
  });

  test('watchAll (vertical list) is unchanged by carousel ordering', () async {
    await repo.reorderCarousel(['c', 'b', 'a']);
    final List<String> all = (await repo.watchAll().first).map((p) => p.id).toList();
    expect(all, [kAllImportedPlaylistId, 'a', 'b', 'c']);
  });
}
