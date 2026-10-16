import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../identity/track_match_key.dart';
import '../scanner/scanned_track.dart';
import 'app_database.dart';
import 'database_provider.dart';
import 'track_repository.dart';

final Provider<BlacklistRepository> blacklistRepositoryProvider = Provider<BlacklistRepository>((ref) {
  return BlacklistRepository(ref.watch(appDatabaseProvider));
});

/// Liste noire, les plus récemment masqués en premier (page Import).
final StreamProvider<List<BlacklistedTrack>> blacklistedTracksProvider = StreamProvider<List<BlacklistedTrack>>((ref) {
  return ref.watch(blacklistRepositoryProvider).watchAll();
});

enum RestoreOutcome {
  /// De retour en bibliothèque, à l'identique, dans ses playlists d'origine.
  restored,

  /// Fichier disparu du stockage : simplement retiré de la liste noire.
  fileMissing,

  /// Fichier masqué avant d'avoir été indexé ([BlacklistRepository.hideFiles]) :
  /// plus masqué, il pourra de nouveau être importé ou indexé.
  unhidden,

  /// Un morceau de même identité (même titre/album/artiste, autre fichier)
  /// est déjà en bibliothèque : le restaurer l'écraserait, il reste masqué.
  alreadyInLibrary,
}

/// Liste noire de Vibe (voir [BlacklistedTracks]) : alimentée par les
/// suppressions de fichier refusées par le système et par le masquage manuel
/// de la page Import, entièrement réversible.
class BlacklistRepository {
  BlacklistRepository(this._db, {Future<bool> Function(String path)? fileExists})
      : _fileExists = fileExists ?? ((path) => File(path).exists());

  final AppDatabase _db;
  final Future<bool> Function(String path) _fileExists;

  Stream<List<BlacklistedTrack>> watchAll() {
    return (_db.select(_db.blacklistedTracks)..orderBy([(b) => OrderingTerm.desc(b.blacklistedAt)])).watch();
  }

  /// Clé (`tracks.id`) du morceau masqué par [entry].
  static String trackKeyOf(BlacklistedTrack entry) => _Snapshot.decode(entry.trackSnapshot).trackKey;

  /// Masque [tracks] et les retire de Vibe en une transaction : jamais un
  /// morceau en liste noire encore présent en bibliothèque, ni l'inverse.
  /// Leurs playlists et positions sont mémorisées pour la restauration.
  Future<void> blacklist(List<Track> tracks, {required BlacklistReason reason}) async {
    if (tracks.isEmpty) return;
    await _db.transaction(() async {
      for (final Track track in tracks) {
        final List<PlaylistTrack> links =
            await (_db.select(_db.playlistTracks)..where((t) => t.trackId.equals(track.id))).get();
        await _db.into(_db.blacklistedTracks).insertOnConflictUpdate(
              BlacklistedTracksCompanion.insert(
                filePath: track.filePath,
                title: track.title,
                artists: track.artists,
                reason: reason,
                trackSnapshot: _Snapshot(
                  trackKey: track.id,
                  track: track,
                  playlists: [
                    for (final PlaylistTrack link in links)
                      (
                        playlistId: link.playlistId,
                        position: link.position,
                        isPendingPlacement: link.isPendingPlacement
                      ),
                  ],
                ).encode(),
              ),
            );
      }
      await TrackRepository(_db).removeFromLibrary([for (final Track track in tracks) track.id]);
    });
  }

  /// Masquage préventif (page Import, « Masquer un fichier… ») de fichiers
  /// choisis sur l'appareil, identifiés par LibraryScanService.identify et
  /// reconnus ensuite par leur clé — le sélecteur Android ne livre qu'une
  /// copie en cache, dont le chemin ne servira plus. Un titre déjà en
  /// bibliothèque est masqué normalement (restaurable à l'identique) et
  /// renvoyé, pour être retiré aussi de la file de lecture.
  Future<List<Track>> hideFiles(List<ScannedTrack> files) async {
    final TrackRepository tracks = TrackRepository(_db);
    final List<Track> inLibrary = [];
    await _db.transaction(() async {
      for (final ScannedTrack file in files) {
        final Track? existing = await tracks.findById(file.id) ?? await tracks.findByFilePath(file.filePath);
        if (existing != null) {
          inLibrary.add(existing);
          continue;
        }
        await _db.into(_db.blacklistedTracks).insertOnConflictUpdate(BlacklistedTracksCompanion.insert(
              filePath: file.filePath,
              title: file.title,
              artists: file.artists,
              reason: BlacklistReason.manual,
              trackSnapshot: _Snapshot(trackKey: file.id).encode(),
            ));
      }
      await blacklist(inLibrary, reason: BlacklistReason.manual);
    });
    return inLibrary;
  }

  /// Entrée correspondant à [file] (identité lue sans import, voir
  /// LibraryScanService.identify) : même chemin, même clé, ou même titre +
  /// artiste principal (clé de rapprochement des imports JSON) — un import
  /// manuel demande alors s'il faut restaurer le titre.
  Future<BlacklistedTrack?> findMatch(ScannedTrack file) async {
    // Titre ou artiste vide une fois normalisé (ponctuation seule, titre
    // entièrement entre parenthèses) : la clé titre + artiste confondrait
    // tous ces titres — seuls le chemin et la clé `tracks.id` comptent alors.
    final String? matchKey = normalizeTrackTitle(file.title).isEmpty || normalizeArtistName(file.primaryArtist).isEmpty
        ? null
        : buildTrackMatchKey(title: file.title, artist: file.primaryArtist);
    for (final BlacklistedTrack entry in await _db.select(_db.blacklistedTracks).get()) {
      if (entry.filePath == file.filePath || trackKeyOf(entry) == file.id) return entry;
      if (matchKey != null &&
          entry.artists.isNotEmpty &&
          buildTrackMatchKey(title: entry.title, artist: entry.artists.first) == matchKey) {
        return entry;
      }
    }
    return null;
  }

  /// Sort [entry] de la liste noire ; le morceau ne repasse en bibliothèque
  /// (lecture, playlists, recherche) que si son fichier est toujours là.
  Future<RestoreOutcome> restore(BlacklistedTrack entry) async {
    final _Snapshot snapshot = _Snapshot.decode(entry.trackSnapshot);
    Future<void> forget() => (_db.delete(_db.blacklistedTracks)..where((b) => b.filePath.equals(entry.filePath))).go();
    final Track? hidden = snapshot.track;
    if (hidden == null) {
      await forget();
      return RestoreOutcome.unhidden;
    }

    // Chemin de l'entrée, pas celui de l'instantané : sur iOS, il suit le
    // conteneur de l'app à chaque mise à jour (SandboxPathRelocator).
    final Track track = hidden.copyWith(filePath: entry.filePath);
    final TrackRepository tracks = TrackRepository(_db);
    final bool fileStillThere = await _fileExists(entry.filePath);
    if (fileStillThere && await tracks.findById(track.id) != null) return RestoreOutcome.alreadyInLibrary;

    await _db.transaction(() async {
      await forget();
      if (fileStillThere) await tracks.restoreTrack(track, playlists: snapshot.playlists);
    });
    return fileStillThere ? RestoreOutcome.restored : RestoreOutcome.fileMissing;
  }
}

/// Instantané JSON d'une entrée : clé du morceau, ligne complète (`null` pour
/// un fichier masqué avant indexation) et playlists d'origine. Les tout
/// premiers instantanés (recette 1.3.6) ne contenaient que la ligne.
class _Snapshot {
  const _Snapshot({required this.trackKey, this.track, this.playlists = const []});

  factory _Snapshot.decode(String raw) {
    final Map<String, dynamic> json = jsonDecode(raw) as Map<String, dynamic>;
    if (json['version'] != _version) {
      final Track track = Track.fromJson(json, serializer: const _TrackSnapshotSerializer());
      return _Snapshot(trackKey: track.id, track: track);
    }
    final Object? track = json['track'];
    return _Snapshot(
      trackKey: json['trackKey'] as String,
      track: track == null
          ? null
          : Track.fromJson(track as Map<String, dynamic>, serializer: const _TrackSnapshotSerializer()),
      playlists: [
        for (final Object? link in json['playlists'] as List<dynamic>)
          (
            playlistId: (link as Map<String, dynamic>)['id'] as String,
            position: link['position'] as int,
            isPendingPlacement: link['pending'] as bool,
          ),
      ],
    );
  }

  static const int _version = 2;

  final String trackKey;
  final Track? track;
  final List<PlaylistLink> playlists;

  String encode() => jsonEncode({
        'version': _version,
        'trackKey': trackKey,
        'track': track?.toJson(serializer: const _TrackSnapshotSerializer()),
        'playlists': [
          for (final PlaylistLink link in playlists)
            {'id': link.playlistId, 'position': link.position, 'pending': link.isPendingPlacement},
        ],
      });
}

/// Ligne `Track` complète en JSON : le sérialiseur par défaut de Drift ne
/// sait ni encoder l'enum [EnrichmentStatus] ni relire une `List<String>`
/// (artistes, tags).
class _TrackSnapshotSerializer extends ValueSerializer {
  const _TrackSnapshotSerializer();

  static const ValueSerializer _defaults = ValueSerializer.defaults();

  @override
  dynamic toJson<T>(T value) => value is EnrichmentStatus ? value.name : _defaults.toJson<T>(value);

  @override
  T fromJson<T>(dynamic json) {
    if (T == EnrichmentStatus) return const EnrichmentStatusConverter().fromSql(json as String) as T;
    if (json is List) return json.cast<String>().toList() as T;
    return _defaults.fromJson<T>(json);
  }
}
