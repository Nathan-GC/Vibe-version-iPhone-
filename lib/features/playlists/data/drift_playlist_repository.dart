import 'package:drift/drift.dart';
import 'package:flutter/material.dart';

import '../../../core/storage/database/app_database.dart';
import '../../../core/theme/vibe_engine/playlist_vibe_resolver.dart';
import '../../../core/theme/vibe_engine/vibe_engine.dart';
import '../domain/playlist_editor_entry.dart';
import 'playlist_repository.dart';

class DriftPlaylistRepository implements PlaylistRepository {
  DriftPlaylistRepository(this._db);

  final AppDatabase _db;

  @override
  Stream<List<Playlist>> watchAll() => _db.select(_db.playlists).watch();

  @override
  Stream<Playlist?> watchPlaylist(String playlistId) {
    return (_db.select(_db.playlists)..where((p) => p.id.equals(playlistId))).watchSingleOrNull();
  }

  @override
  Future<Playlist?> findBySourceManifestId(String manifestId) {
    return (_db.select(_db.playlists)..where((p) => p.sourceManifestId.equals(manifestId))).getSingleOrNull();
  }

  @override
  Future<Playlist> createEmpty({required String title, required VibePreset vibeStyle}) async {
    final String id = 'local-${DateTime.now().millisecondsSinceEpoch}';
    await _db.into(_db.playlists).insert(
          PlaylistsCompanion.insert(id: id, title: title, vibeStyle: Value(vibeStyle)),
        );
    return (_db.select(_db.playlists)..where((p) => p.id.equals(id))).getSingle();
  }

  @override
  Future<Playlist> ensureLikedPlaylist() async {
    final Playlist? existing =
        await (_db.select(_db.playlists)..where((p) => p.id.equals(kLikedPlaylistId))).getSingleOrNull();
    if (existing != null) return existing;

    await _db.into(_db.playlists).insert(
          PlaylistsCompanion.insert(
            id: kLikedPlaylistId,
            title: 'Titres likés',
            vibeStyle: const Value(VibePreset.retro),
          ),
        );
    return (_db.select(_db.playlists)..where((p) => p.id.equals(kLikedPlaylistId))).getSingle();
  }

  /// Deux tables fusionnées (morceaux + titres grisés) : un simple
  /// `query.watch()` ne suivrait que l'une d'elles. Réémet à chaque
  /// modification de l'une des tables concernées.
  @override
  Stream<List<PlaylistEditorEntry>> watchEditorEntries(String playlistId) async* {
    yield await _loadEntries(playlistId);
    final Stream<Set<TableUpdate>> updates = _db.tableUpdates(
      TableUpdateQuery.onAllTables([_db.playlistTracks, _db.playlistMissingTracks, _db.tracks]),
    );
    await for (final _ in updates) {
      yield await _loadEntries(playlistId);
    }
  }

  Future<List<PlaylistEditorEntry>> _loadEntries(String playlistId) async {
    final query = _db.select(_db.playlistTracks).join([
      innerJoin(_db.tracks, _db.tracks.id.equalsExp(_db.playlistTracks.trackId)),
    ])
      ..where(_db.playlistTracks.playlistId.equals(playlistId))
      ..orderBy([OrderingTerm.asc(_db.playlistTracks.position)]);

    final List<PlaylistEditorEntry> entries = [
      for (final row in await query.get())
        PlaylistEditorEntry(
          track: row.readTable(_db.tracks),
          isPendingPlacement: row.readTable(_db.playlistTracks).isPendingPlacement,
          position: row.readTable(_db.playlistTracks).position,
        ),
    ];
    final List<PlaylistMissingTrack> missing =
        await (_db.select(_db.playlistMissingTracks)..where((m) => m.playlistId.equals(playlistId))).get();
    if (missing.isEmpty) return entries;

    // Tri stable : à position égale (cas limite), le morceau lisible passe
    // avant le titre grisé.
    return [...entries, ...missing.map(PlaylistEditorEntry.missing)]..sort((a, b) {
        final int byPosition = a.position.compareTo(b.position);
        if (byPosition != 0) return byPosition;
        return (a.isMissing ? 1 : 0).compareTo(b.isMissing ? 1 : 0);
      });
  }

  @override
  Future<List<Track>> fetchOrderedTracks(String playlistId) async {
    final List<PlaylistEditorEntry> entries = await _loadEntries(playlistId);
    return [
      for (final PlaylistEditorEntry entry in entries)
        if (entry.track != null) entry.track!,
    ];
  }

  @override
  Future<void> commitOrder(String playlistId, List<PlaylistEditorEntry> orderedEntries) {
    return _db.transaction(() async {
      await (_db.delete(_db.playlistTracks)..where((t) => t.playlistId.equals(playlistId))).go();

      final List<PlaylistTracksCompanion> rows = [];
      for (int i = 0; i < orderedEntries.length; i++) {
        final PlaylistEditorEntry entry = orderedEntries[i];
        final Track? track = entry.track;
        if (track != null) {
          rows.add(PlaylistTracksCompanion.insert(
            playlistId: playlistId,
            trackId: track.id,
            position: i,
            isPendingPlacement: const Value(false),
          ));
        } else {
          await (_db.update(_db.playlistMissingTracks)..where((m) => m.id.equals(entry.missing!.id)))
              .write(PlaylistMissingTracksCompanion(position: Value(i)));
        }
      }
      if (rows.isNotEmpty) await _db.batch((batch) => batch.insertAll(_db.playlistTracks, rows));

      await _bumpVersion(playlistId);
    });
  }

  @override
  Future<void> linkMissingEntry(int missingId, String trackId) {
    return _db.transaction(() async {
      final PlaylistMissingTrack? missing =
          await (_db.select(_db.playlistMissingTracks)..where((m) => m.id.equals(missingId))).getSingleOrNull();
      if (missing == null) return;
      final bool alreadyInPlaylist = await (_db.select(_db.playlistTracks)
            ..where((t) => t.playlistId.equals(missing.playlistId) & t.trackId.equals(trackId)))
          .getSingleOrNull()
          .then((row) => row != null);
      if (!alreadyInPlaylist) {
        await _db.into(_db.playlistTracks).insert(
              PlaylistTracksCompanion.insert(
                playlistId: missing.playlistId,
                trackId: trackId,
                position: missing.position,
                isPendingPlacement: const Value(false),
              ),
            );
      }
      await (_db.delete(_db.playlistMissingTracks)..where((m) => m.id.equals(missingId))).go();
    });
  }

  @override
  Future<void> removeMissingEntry(int missingId) {
    return (_db.delete(_db.playlistMissingTracks)..where((m) => m.id.equals(missingId))).go();
  }

  @override
  Future<void> updateVibeStyle(String playlistId, VibePreset vibeStyle) {
    return (_db.update(_db.playlists)..where((p) => p.id.equals(playlistId)))
        .write(PlaylistsCompanion(vibeStyle: Value(vibeStyle)));
  }

  @override
  Future<void> updateCustomVibe(
    String playlistId, {
    required List<Color> colors,
    required Color accentColor,
    required String backgroundImagePath,
    required VibeCustomEffect effect,
    required String backgroundVideoPath,
  }) {
    return (_db.update(_db.playlists)..where((p) => p.id.equals(playlistId))).write(
      PlaylistsCompanion(
        vibeStyle: const Value(VibePreset.custom),
        bgColors: Value(colors.map(colorToHex).toList()),
        customAccentColor: Value(colorToHex(accentColor)),
        customBackgroundImagePath: Value(backgroundImagePath),
        customEffect: Value(effect),
        customBackgroundVideoPath: Value(backgroundVideoPath),
      ),
    );
  }

  @override
  Future<void> incrementVersion(String playlistId) => _bumpVersion(playlistId);

  @override
  Future<void> updateCoverImagePath(String playlistId, String path) {
    return (_db.update(_db.playlists)..where((p) => p.id.equals(playlistId)))
        .write(PlaylistsCompanion(coverImagePath: Value(path)));
  }

  @override
  Future<void> updateShowCoverImage(String playlistId, bool showCoverImage) {
    return (_db.update(_db.playlists)..where((p) => p.id.equals(playlistId)))
        .write(PlaylistsCompanion(showCoverImage: Value(showCoverImage)));
  }

  @override
  Future<void> renamePlaylist(String playlistId, String title) {
    return (_db.update(_db.playlists)..where((p) => p.id.equals(playlistId)))
        .write(PlaylistsCompanion(title: Value(title)));
  }

  @override
  Future<void> deletePlaylist(String playlistId) {
    return _db.transaction(() async {
      await (_db.delete(_db.playlistTracks)..where((t) => t.playlistId.equals(playlistId))).go();
      await (_db.delete(_db.playlistMissingTracks)..where((m) => m.playlistId.equals(playlistId))).go();
      await (_db.delete(_db.playlists)..where((p) => p.id.equals(playlistId))).go();
    });
  }

  Future<void> _bumpVersion(String playlistId) async {
    final Playlist current = await (_db.select(_db.playlists)..where((p) => p.id.equals(playlistId))).getSingle();
    await (_db.update(_db.playlists)..where((p) => p.id.equals(playlistId)))
        .write(PlaylistsCompanion(version: Value(current.version + 1)));
  }
}
