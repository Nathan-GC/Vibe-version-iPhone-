import 'dart:convert';

import 'package:drift/drift.dart';

import '../../../core/identity/track_match_key.dart';
import '../../../core/playlist_manifest/manifest_track_ref.dart';
import '../../../core/playlist_manifest/playlist_manifest.dart';
import '../../../core/storage/database/app_database.dart';
import '../../../core/theme/vibe_engine/vibe_engine.dart';
import '../../diff/domain/diff_result.dart';
import '../domain/import_match_plan.dart';
import 'import_track_matcher.dart';

/// Export / import / mise à jour de playlists via le manifeste JSON commun.
///
/// Import en deux temps, pour laisser l'utilisateur trancher entre les deux :
///  1. [planImport] : matching automatique contre la bibliothèque locale
///     (voir ImportTrackMatcher) — ce qui n'est pas sûr part au matching
///     manuel (ImportMatchingScreen) ;
///  2. [importAsNewPlaylist] / [applyUpdate] avec la résolution finale, un
///     `trackId` (ou `null`) par titre du manifeste : les titres sans morceau
///     local deviennent des titres grisés ([PlaylistMissingTracks]) à leur
///     position d'origine, jamais lus, dégrisés automatiquement plus tard.
class PlaylistManifestService {
  PlaylistManifestService(this._db);

  final AppDatabase _db;

  /// Manifeste d'une playlist locale, titres grisés compris (à leur place) :
  /// réexporter une playlist importée ne perd pas les titres introuvables.
  Future<PlaylistManifest> buildManifest(String playlistId, {String? author}) async {
    final Playlist playlist = await (_db.select(_db.playlists)..where((p) => p.id.equals(playlistId))).getSingle();

    return PlaylistManifest(
      id: playlist.id,
      title: playlist.title,
      description: playlist.description,
      version: playlist.version,
      tags: playlist.tags,
      vibeStyle: playlist.vibeStyle.name,
      creatorHandle: author,
      originalCreator: playlist.originalCreator,
      tracks: await _orderedRefs(playlistId),
    );
  }

  /// JSON indenté prêt à être enregistré, avec l'auteur saisi à l'export.
  Future<String> exportManifestJson(String playlistId, {required String author}) async {
    final PlaylistManifest manifest = await buildManifest(playlistId, author: author);
    return const JsonEncoder.withIndent('  ').convert(manifest.toJson());
  }

  /// Nom de fichier proposé pour l'export ("Ma playlist.json").
  static String exportFileNameFor(String playlistTitle) {
    final String safe = playlistTitle.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    return '${safe.isEmpty ? 'playlist' : safe}.json';
  }

  Future<ImportMatchPlan> planImport(List<ManifestTrackRef> refs) async {
    final List<Track> library = await _db.select(_db.tracks).get();
    return ImportTrackMatcher(library).plan(refs);
  }

  /// Crée la playlist importée (visible dans "Tes playlists", Découverte et
  /// Mon espace), attribuée à l'auteur du manifeste ("Inspiré par @X").
  Future<Playlist> importAsNewPlaylist(PlaylistManifest manifest, List<String?> resolution) async {
    final String newId = '${manifest.id}-fork-${DateTime.now().millisecondsSinceEpoch}';
    final String? attribution = manifest.creatorHandle ?? manifest.originalCreator;

    await _db.transaction(() async {
      await _db.into(_db.playlists).insert(
            PlaylistsCompanion.insert(
              id: newId,
              title: manifest.title,
              description: Value(manifest.description),
              originalCreator: Value(attribution),
              sourceManifestId: Value(manifest.id),
              version: Value(manifest.version),
              tags: Value(manifest.tags),
              vibeStyle: Value(_parseVibe(manifest.vibeStyle)),
            ),
          );
      await _writeEntries(newId, manifest.tracks, resolution);
    });

    return (_db.select(_db.playlists)..where((p) => p.id.equals(newId))).getSingle();
  }

  /// "Accepter la mise à jour" : remplace le contenu de la playlist (morceaux
  /// ET titres grisés) par celui du manifeste entrant, met à jour `version`.
  Future<Playlist> applyUpdate(String playlistId, PlaylistManifest incoming, List<String?> resolution) async {
    await _db.transaction(() async {
      await (_db.delete(_db.playlistTracks)..where((t) => t.playlistId.equals(playlistId))).go();
      await (_db.delete(_db.playlistMissingTracks)..where((m) => m.playlistId.equals(playlistId))).go();
      await _writeEntries(playlistId, incoming.tracks, resolution);
      await (_db.update(_db.playlists)..where((p) => p.id.equals(playlistId)))
          .write(PlaylistsCompanion(version: Value(incoming.version)));
    });

    return (_db.select(_db.playlists)..where((p) => p.id.equals(playlistId))).getSingle();
  }

  Future<DiffResult> computeDiff(String playlistId, PlaylistManifest incoming) async {
    final Playlist local = await (_db.select(_db.playlists)..where((p) => p.id.equals(playlistId))).getSingle();
    // Même clé tolérante que le matching d'import (titre + artiste
    // normalisés, sans album) : un titre associé à "Move feat. X" localement
    // n'apparaît pas comme retiré/ajouté face au "Move" du manifeste — la clé
    // exacte (album compris) gonflait l'aperçu de faux changements.
    String keyOf(ManifestTrackRef ref) => buildTrackMatchKey(title: ref.title, artist: ref.artist);
    final Map<String, ManifestTrackRef> localByKey = {
      for (final ManifestTrackRef ref in await _orderedRefs(playlistId)) keyOf(ref): ref,
    };
    final Map<String, ManifestTrackRef> incomingByKey = {for (final t in incoming.tracks) keyOf(t): t};

    return DiffResult(
      localVersion: local.version,
      incomingVersion: incoming.version,
      added: [
        for (final e in incomingByKey.entries)
          if (!localByKey.containsKey(e.key)) e.value,
      ],
      removed: [
        for (final e in localByKey.entries)
          if (!incomingByKey.containsKey(e.key)) e.value,
      ],
    );
  }

  /// Écrit un titre par position `i` du manifeste : morceau local si
  /// `resolution[i]` est renseigné, titre grisé sinon. Un morceau déjà placé
  /// plus haut (doublon) n'est pas réinséré — clé primaire (playlist,
  /// morceau).
  Future<void> _writeEntries(String playlistId, List<ManifestTrackRef> refs, List<String?> resolution) async {
    if (resolution.length != refs.length) {
      throw ArgumentError('Résolution incomplète : ${resolution.length} choix pour ${refs.length} titres');
    }
    final Set<String> placed = {};
    final List<PlaylistTracksCompanion> tracks = [];
    final List<PlaylistMissingTracksCompanion> missing = [];

    for (int i = 0; i < refs.length; i++) {
      final String? trackId = resolution[i];
      final ManifestTrackRef ref = refs[i];
      if (trackId != null) {
        if (!placed.add(trackId)) continue;
        tracks.add(PlaylistTracksCompanion.insert(
          playlistId: playlistId,
          trackId: trackId,
          position: i,
          isPendingPlacement: const Value(false),
        ));
      } else {
        missing.add(PlaylistMissingTracksCompanion.insert(
          playlistId: playlistId,
          position: i,
          title: ref.title,
          artist: ref.artist,
          album: Value(ref.album ?? ''),
          sanitizedKey: ref.sanitizedKey,
          matchKey: buildTrackMatchKey(title: ref.title, artist: ref.artist),
        ));
      }
    }

    await _db.batch((batch) {
      if (tracks.isNotEmpty) batch.insertAll(_db.playlistTracks, tracks);
      if (missing.isNotEmpty) batch.insertAll(_db.playlistMissingTracks, missing);
    });
  }

  /// Titres de la playlist dans l'ordre d'affichage, morceaux et titres
  /// grisés fusionnés.
  Future<List<ManifestTrackRef>> _orderedRefs(String playlistId) async {
    final query = _db.select(_db.playlistTracks).join([
      innerJoin(_db.tracks, _db.tracks.id.equalsExp(_db.playlistTracks.trackId)),
    ])
      ..where(_db.playlistTracks.playlistId.equals(playlistId));
    final List<(int, ManifestTrackRef)> positioned = [
      for (final row in await query.get())
        (row.readTable(_db.playlistTracks).position, _toManifestRef(row.readTable(_db.tracks))),
    ];
    final List<PlaylistMissingTrack> missing =
        await (_db.select(_db.playlistMissingTracks)..where((m) => m.playlistId.equals(playlistId))).get();
    for (final PlaylistMissingTrack m in missing) {
      positioned.add(
          (m.position, ManifestTrackRef(title: m.title, artist: m.artist, album: m.album.isEmpty ? null : m.album)));
    }
    positioned.sort((a, b) => a.$1.compareTo(b.$1));
    return positioned.map((pair) => pair.$2).toList();
  }

  ManifestTrackRef _toManifestRef(Track track) => ManifestTrackRef(
        title: track.title,
        artist: track.artists.isNotEmpty ? track.artists.first : 'Unknown',
        album: track.album.isEmpty ? null : track.album,
      );

  VibePreset _parseVibe(String raw) =>
      VibePreset.values.firstWhere((v) => v.name == raw, orElse: () => VibePreset.minimal);
}
