import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/storage/database/app_database.dart';
import 'package:playlist_app/core/storage/database/database_provider.dart';
import 'package:playlist_app/core/storage/database/track_repository.dart';
import 'package:playlist_app/features/playlists/data/drift_playlist_repository.dart';
import 'package:playlist_app/features/playlists/data/playlist_providers.dart';
import 'package:playlist_app/features/playlists/data/playlist_repository.dart';
import 'package:playlist_app/features/playlists/domain/playlist_category.dart';

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<Playlist> insert(String id, {String? manifestId, String? creator, String? title}) async {
    await db.into(db.playlists).insert(PlaylistsCompanion.insert(
          id: id,
          title: title ?? id,
          sourceManifestId: Value(manifestId),
          originalCreator: Value(creator),
        ));
    return (db.select(db.playlists)..where((p) => p.id.equals(id))).getSingle();
  }

  group('playlistCategoryOf', () {
    test('plain playlist is created', () async {
      expect(playlistCategoryOf(await insert('x')), PlaylistCategory.created);
    });

    test('both system playlists are auto', () async {
      expect(playlistCategoryOf(await insert(kAllImportedPlaylistId)), PlaylistCategory.auto);
      expect(playlistCategoryOf(await insert(kLikedPlaylistId)), PlaylistCategory.auto);
    });

    test('sourceManifestId makes it imported', () async {
      expect(playlistCategoryOf(await insert('x', manifestId: 'm1')), PlaylistCategory.imported);
    });

    test('originalCreator alone makes it imported', () async {
      expect(playlistCategoryOf(await insert('x', creator: 'Alice')), PlaylistCategory.imported);
    });

    test('an imported playlist stays imported after a rename', () async {
      await insert('x', manifestId: 'm1');
      await (db.update(db.playlists)..where((p) => p.id.equals('x'))).write(
        const PlaylistsCompanion(title: Value('Renommée')),
      );
      final Playlist renamed = await (db.select(db.playlists)..where((p) => p.id.equals('x'))).getSingle();
      expect(renamed.title, 'Renommée');
      expect(playlistCategoryOf(renamed), PlaylistCategory.imported);
    });
  });

  group('providers par famille', () {
    late ProviderContainer container;

    setUp(() async {
      // Ordre de création : all, c1, i1, liked, c2, i2.
      await insert(kAllImportedPlaylistId);
      await insert('c1');
      await insert('i1', manifestId: 'm1');
      await insert(kLikedPlaylistId);
      await insert('c2');
      await insert('i2', creator: 'Bob');
      container = ProviderContainer(overrides: [appDatabaseProvider.overrideWithValue(db)]);
      addTearDown(container.dispose);
    });

    Future<List<String>> ids(ProviderListenable<AsyncValue<List<Playlist>>> provider) async {
      final Completer<void> completer = Completer<void>();
      final ProviderSubscription<AsyncValue<List<Playlist>>> sub = container.listen(provider, (_, next) {
        if (next.hasValue && !completer.isCompleted) completer.complete();
      }, fireImmediately: true);
      await completer.future;
      final List<String> result = sub.read().requireValue.map((p) => p.id).toList();
      sub.close();
      return result;
    }

    test('lists per family follow creation order', () async {
      expect(await ids(playlistsByCategoryProvider(PlaylistCategory.created)), ['c1', 'c2']);
      expect(await ids(playlistsByCategoryProvider(PlaylistCategory.auto)), [kAllImportedPlaylistId, kLikedPlaylistId]);
      expect(await ids(playlistsByCategoryProvider(PlaylistCategory.imported)), ['i1', 'i2']);
    });

    test('carousels per family: positions first, then nulls in creation order', () async {
      await DriftPlaylistRepository(db).reorderCarousel(['c2', 'liked-tracks', 'i2']);
      expect(await ids(carouselByCategoryProvider(PlaylistCategory.created)), ['c2', 'c1']);
      expect(await ids(carouselByCategoryProvider(PlaylistCategory.auto)), [kLikedPlaylistId, kAllImportedPlaylistId]);
      expect(await ids(carouselByCategoryProvider(PlaylistCategory.imported)), ['i2', 'i1']);
    });
  });
}
