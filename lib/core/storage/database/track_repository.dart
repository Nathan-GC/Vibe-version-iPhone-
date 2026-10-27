import 'dart:io' show File, FileSystemException;

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../networking/metadata_api_client/music_keyword_enricher.dart';
import '../../networking/metadata_api_client/online_track_result.dart';
import '../../networking/metadata_api_client/track_match_confidence.dart';
import '../../theme/vibe_engine/vibe_engine.dart';
import '../metadata_extractor/artist_name_normalizer.dart';
import '../scanner/scanned_track.dart';
import 'app_database.dart';
import 'database_provider.dart';
import 'library_category.dart';
import 'missing_playlist_track_reconciler.dart';
import 'track_enricher.dart';

final Provider<TrackRepository> trackRepositoryProvider = Provider<TrackRepository>((ref) {
  return TrackRepository(ref.watch(appDatabaseProvider));
});

/// Id fixe de la playlist système "Tous les titres importés" — regroupe
/// automatiquement 100% des morceaux importés (import manuel, scan complet,
/// résolution de morceau manquant), qu'ils passent tous par
/// [TrackRepository.upsertTrack]. Non supprimable : l'app n'expose aucune
/// action de suppression de playlist à ce jour, donc rien à bloquer
/// explicitement — au même titre que [kLikedPlaylistId] (voir
/// features/playlists/data/playlist_repository.dart).
const String kAllImportedPlaylistId = 'all-imported-tracks';

/// Appartenance d'un morceau à une playlist, mémorisée à sa mise en liste
/// noire pour l'y remettre à l'identique (BlacklistRepository.restore).
typedef PlaylistLink = ({String playlistId, int position, bool isPendingPlacement});

/// Écrit un [ScannedTrack] en base et tient `track_artists` synchronisé avec
/// le tableau `artists` de la track — c'est ce qui permet à un morceau en
/// featuring d'apparaître dans le profil de chaque artiste sans dupliquer le
/// fichier physique référencé par `file_path`.
class TrackRepository {
  TrackRepository(this._db);

  final AppDatabase _db;

  Future<Track?> findById(String trackId) {
    return (_db.select(_db.tracks)..where((t) => t.id.equals(trackId))).getSingleOrNull();
  }

  /// Lecture directe de la base, à jour de toutes les écritures déjà
  /// attendues — contrairement à `libraryTracksProvider.future`, qui renvoie
  /// la dernière émission du flux Drift, émise de façon asynchrone APRÈS
  /// chaque écriture (voir LibraryScreen._enrichLibrary).
  Future<List<Track>> fetchAllTracks() => _db.select(_db.tracks).get();

  /// Résout un résultat en ligne (iTunes) vers un morceau déjà possédé
  /// localement, si son titre/artiste correspond — permet au bouton "+" d'un
  /// [OnlineTrackResult] (Morceaux populaires, discographie) d'ajouter à une
  /// playlist un fichier réellement présent plutôt qu'une simple référence
  /// distante non lisible hors connexion (l'app est locale-first : aucun
  /// mécanisme de téléchargement du morceau complet n'existe).
  Future<Track?> findLocalMatch(String title, String artist) async {
    final String pattern = '%${title.trim()}%';
    final List<Track> candidates = await (_db.select(_db.tracks)..where((t) => t.title.like(pattern))).get();
    if (candidates.isEmpty) return null;

    final String normalizedArtist = artist.trim().toLowerCase();
    for (final track in candidates) {
      final bool artistMatches = track.artists.any(
        (a) => a.toLowerCase().contains(normalizedArtist) || normalizedArtist.contains(a.toLowerCase()),
      );
      if (artistMatches) return track;
    }
    return null;
  }

  /// Empreinte connue d'un fichier déjà scanné — utilisé par le scan
  /// incrémental (Étape 8) pour décider en quelques millisecondes s'il faut
  /// relire ses tags/relancer le découpage de silence, sans toucher au contenu
  /// du fichier lui-même.
  Future<Track?> findByFilePath(String filePath) {
    return (_db.select(_db.tracks)..where((t) => t.filePath.equals(filePath))).getSingleOrNull();
  }

  /// Incrémente `play_count` et met à jour `last_played_at` — alimente le tri
  /// Popularité (Étape 3) et la vue de purge des orphelins (Étape 7). Un seul
  /// `UPDATE ... SET play_count = play_count + 1` (Lot 1.1) plutôt qu'une
  /// lecture puis une écriture : appelé à chaque changement de piste, deux
  /// appels rapprochés ne peuvent plus perdre une écoute.
  Future<void> recordPlay(String trackId) {
    return (_db.update(_db.tracks)..where((t) => t.id.equals(trackId))).write(
      TracksCompanion.custom(
        playCount: _db.tracks.playCount + const Constant(1),
        lastPlayedAt: Variable(DateTime.now()),
      ),
    );
  }

  /// En liste noire ([BlacklistedTracks]) : jamais réindexé, que ce soit
  /// par le scan plein-appareil, le dossier Fichiers (iOS) ou un import.
  /// Reconnu par son chemin, ou par sa clé [trackKey] (`tracks.id`) : sur
  /// Android, un fichier choisi via le sélecteur n'est connu que par une
  /// copie en cache, seule son identité permet de le reconnaître ensuite.
  /// La clé est lue dans l'instantané JSON (format courant `trackKey`, ou
  /// `id` de la ligne seule des premiers instantanés).
  Future<bool> isBlacklisted({required String filePath, String? trackKey}) async {
    final QueryRow? row = await _db.customSelect(
      'SELECT 1 FROM blacklisted_tracks WHERE file_path = ?1 OR (?2 IS NOT NULL AND '
      "(json_extract(track_snapshot, '\$.trackKey') = ?2 OR json_extract(track_snapshot, '\$.id') = ?2)) LIMIT 1",
      variables: [Variable.withString(filePath), Variable<String>(trackKey)],
      readsFrom: {_db.blacklistedTracks},
    ).getSingleOrNull();
    return row != null;
  }

  /// Retire des morceaux de Vibe : ligne `tracks`, index d'artistes et
  /// liaisons de playlists — sans quoi un morceau retiré laisserait une ligne
  /// fantôme dans "Tous les titres importés" (masquée par les jointures
  /// internes, mais comptée dans les positions de la playlist). Partagé par
  /// la suppression de fichier (OrphanPurgeService) et la liste noire.
  Future<void> removeFromLibrary(List<String> trackIds) async {
    if (trackIds.isEmpty) return;
    await _db.transaction(() async {
      await (_db.delete(_db.playlistTracks)..where((t) => t.trackId.isIn(trackIds))).go();
      await (_db.delete(_db.trackArtists)..where((t) => t.trackId.isIn(trackIds))).go();
      await (_db.delete(_db.tracks)..where((t) => t.id.isIn(trackIds))).go();
    });
  }

  /// Remet en bibliothèque une ligne complète sortie de la liste noire
  /// (BlacklistRepository.restore) : métadonnées enrichies, compteur
  /// d'écoutes et pochette conservés ; index d'artistes, playlists d'origine
  /// aux positions d'origine ([playlists]), "Tous les titres importés" et
  /// dégrisage des playlists importées, comme à l'import.
  Future<void> restoreTrack(Track track, {List<PlaylistLink> playlists = const []}) {
    return _db.transaction(() async {
      await _db.into(_db.tracks).insert(track);
      await _db.batch((batch) {
        batch.insertAll(_db.trackArtists, [
          for (int i = 0; i < track.artists.length; i++)
            TrackArtistsCompanion.insert(trackId: track.id, artistName: track.artists[i], position: i),
        ]);
      });
      for (final PlaylistLink link in playlists) {
        await _reinsertAt(track.id, link);
      }
      await _linkToAllImportedPlaylist(track.id);
      await MissingPlaylistTrackReconciler(_db).reconcileTrack(
        trackId: track.id,
        title: track.title,
        artists: track.artists,
      );
    });
  }

  /// Réinsère [trackId] à sa position d'origine dans une playlist qui existe
  /// encore. Position reprise entre-temps (playlist réordonnée puis
  /// enregistrée) : la suite est décalée d'un cran, titres grisés compris
  /// (numérotation commune, voir [PlaylistMissingTracks]).
  Future<void> _reinsertAt(String trackId, PlaylistLink link) async {
    final Playlist? playlist =
        await (_db.select(_db.playlists)..where((p) => p.id.equals(link.playlistId))).getSingleOrNull();
    if (playlist == null) return;

    final bool taken = await (_db.select(_db.playlistTracks)
              ..where((t) => t.playlistId.equals(link.playlistId) & t.position.equals(link.position)))
            .get()
            .then((rows) => rows.isNotEmpty) ||
        await (_db.select(_db.playlistMissingTracks)
              ..where((m) => m.playlistId.equals(link.playlistId) & m.position.equals(link.position)))
            .get()
            .then((rows) => rows.isNotEmpty);
    if (taken) {
      for (final String table in const ['playlist_tracks', 'playlist_missing_tracks']) {
        await _db.customUpdate(
          'UPDATE $table SET position = position + 1 WHERE playlist_id = ? AND position >= ?',
          variables: [Variable.withString(link.playlistId), Variable.withInt(link.position)],
          updates: {_db.playlistTracks, _db.playlistMissingTracks},
        );
      }
    }
    await _db.into(_db.playlistTracks).insertOnConflictUpdate(PlaylistTracksCompanion.insert(
          playlistId: link.playlistId,
          trackId: trackId,
          position: link.position,
          isPendingPlacement: Value(link.isPendingPlacement),
        ));
  }

  /// Écrit [scanned] en base et renvoie l'id EFFECTIVEMENT utilisé — il peut
  /// différer de `scanned.id` : les appelants doivent s'en servir pour la suite
  /// (enrichissement, association à une playlist, titre renvoyé à l'écran).
  ///
  /// - `null` : rien n'a été inséré (titre en liste noire).
  /// - `scanned.id` : cas courant (nouveau titre, mise à jour du même fichier,
  ///   ou remplacement d'une ligne dont le fichier a disparu).
  /// - `<id>~N` (N >= 2) : l'id calculé (titre + album + artiste principal) est
  ///   déjà porté par un AUTRE fichier qui existe encore sur le disque — deux
  ///   versions dont la mention (« Radio Edit », « Slowed »…) est retirée par
  ///   le nettoyage, deux éditions, ou deux copies. Le second fichier reçoit
  ///   le premier id de variante libre, de façon déterministe, au lieu
  ///   d'écraser la ligne du premier : les deux titres coexistent et tombent
  ///   dans « Doublons détectés », où l'utilisateur tranche.
  /// - `previous.id` : le fichier était déjà indexé sous une autre clé que
  ///   celle recalculée, laquelle appartient à un autre fichier — sa ligne est
  ///   gardée telle quelle (voir plus bas).
  Future<String?> upsertTrack(ScannedTrack scanned) async {
    if (await isBlacklisted(filePath: scanned.filePath, trackKey: scanned.id)) {
      await _deleteExtractedCover(scanned.coverArtPath);
      return null;
    }

    // Un même artiste peut apparaître plusieurs fois dans le nom de fichier
    // sanitizé (ex. "Hunter X Hunter" scindé par erreur en featuring
    // "Hunter" + "Hunter" par le séparateur multi-artiste, qui traite le "X"
    // du titre comme un séparateur) — dédupliquer ici, ordre préservé
    // (première occurrence gagnante, même règle que
    // [mergeDuplicateCaseArtists]), avant d'écrire dans `track_artists` :
    // sans quoi la contrainte UNIQUE(track_id, artist_name) fait planter tout
    // le scan sur ce morceau (crash réel observé lors d'un scan plein-appareil
    // sur une grosse bibliothèque).
    final List<String> artists = [];
    for (final name in scanned.artists) {
      if (!artists.contains(name)) artists.add(name);
    }

    return _db.transaction<String?>(() async {
      // Même fichier déjà indexé sous une autre clé (tags modifiés, ou clé
      // d'une version antérieure de buildSanitizedKey) : la ligne est
      // renommée en place, playlists comprises — sans quoi l'insertion
      // ci-dessous créerait une seconde ligne et heurterait l'unicité de
      // `file_path`.
      final Track? previous = await findByFilePath(scanned.filePath);
      if (previous != null && previous.id != scanned.id && await findById(scanned.id) != null) {
        // Nouvelle clé déjà portée par un AUTRE fichier (deux copies devenues
        // identiques, ex. « Été » / « Ete » depuis le repli des accents) : la
        // ligne existante est gardée telle quelle — l'écraser heurterait
        // l'unicité de `file_path` et interromprait tout le scan. Date et
        // empreinte à jour : le scan suivant ne le relit pas.
        await (_db.update(_db.tracks)..where((t) => t.id.equals(previous.id))).write(TracksCompanion(
          lastModifiedEpochMs: Value(scanned.lastModifiedEpochMs),
          fileHash: Value(scanned.fileHash),
        ));
        await _deleteExtractedCover(scanned.coverArtPath);
        return previous.id;
      }
      if (previous != null && previous.id != scanned.id) {
        await (_db.update(_db.tracks)..where((t) => t.id.equals(previous.id)))
            .write(TracksCompanion(id: Value(scanned.id)));
        await (_db.update(_db.playlistTracks)..where((t) => t.trackId.equals(previous.id)))
            .write(PlaylistTracksCompanion(trackId: Value(scanned.id)));
        await (_db.delete(_db.trackArtists)..where((t) => t.trackId.equals(previous.id))).go();
      }

      // Aucun titre n'est lié à CE chemin : si l'id calculé appartient déjà à un
      // autre fichier encore présent, ce n'est pas une mise à jour mais une
      // autre version — id de variante (voir la doc de la méthode). Fichier de
      // la ligne existante disparu : c'est un remplacement, comportement
      // historique (la ligne est réécrite sous le même id). Un titre déjà
      // indexé sous ce chemin (`previous`) garde son id : c'est le même fichier.
      String trackId = scanned.id;
      if (previous == null) {
        final Track? holder = await findById(scanned.id);
        if (holder != null && _fileStillThere(holder.filePath)) trackId = await _firstFreeVariantId(scanned.id);
      }

      await _db.into(_db.tracks).insertOnConflictUpdate(
            TracksCompanion.insert(
              id: trackId,
              title: scanned.title,
              album: scanned.album,
              artists: artists,
              durationSeconds: scanned.durationMs ~/ 1000,
              filePath: scanned.filePath,
              trimStartMs: Value(scanned.trimStartMs),
              trimEndMs: Value(scanned.trimEndMs),
              bpm: scanned.bpm == null ? const Value.absent() : Value(scanned.bpm!),
              requiresUserReview: Value(scanned.requiresUserReview),
              tags: Value(scanned.genre == null ? const [] : [scanned.genre!]),
              lastModifiedEpochMs: Value(scanned.lastModifiedEpochMs),
              fileHash: Value(scanned.fileHash),
              // Voir [EnrichmentStatus] : un morceau ambigu dès le nom de
              // fichier ne doit pas gaspiller de tentative d'enrichissement
              // automatique tant qu'un humain n'a pas confirmé Titre/Artiste.
              enrichmentStatus:
                  Value(scanned.requiresUserReview ? EnrichmentStatus.requiresReview : EnrichmentStatus.pending),
            ),
          );

      // Pochette, artistes et playlists suivent l'id EFFECTIF : sous l'id
      // calculé, ils s'attacheraient à la ligne du premier fichier.
      await applyExtractedCover(trackId, scanned.coverArtPath);

      await (_db.delete(_db.trackArtists)..where((t) => t.trackId.equals(trackId))).go();

      if (artists.isNotEmpty) {
        await _db.batch((batch) {
          batch.insertAll(_db.trackArtists, [
            for (int i = 0; i < artists.length; i++)
              TrackArtistsCompanion.insert(trackId: trackId, artistName: artists[i], position: i),
          ]);
        });
      }

      await _linkToAllImportedPlaylist(trackId);

      // Dégrisage automatique : ce morceau peut être un titre attendu par
      // une playlist importée (JSON) — il y redevient lisible, à sa place.
      await MissingPlaylistTrackReconciler(_db).reconcileTrack(
        trackId: trackId,
        title: scanned.title,
        artists: artists,
      );
      return trackId;
    });
  }

  /// Fichier d'un titre toujours sur le disque. Synchrone à dessein : appelé
  /// seulement lors d'une collision d'id (rare), et sans l'indétermination
  /// d'une E/S asynchrone sous horloge simulée dans les tests de widgets.
  bool _fileStillThere(String filePath) {
    try {
      return File(filePath).existsSync();
    } on FileSystemException {
      return false;
    }
  }

  /// Premier id de variante `<baseId>~N` (N >= 2) disponible : aucune ligne, ou
  /// une ligne dont le fichier a disparu (remplacée, comme l'id de base).
  /// Déterministe — le même ensemble de fichiers redonne les mêmes ids.
  Future<String> _firstFreeVariantId(String baseId) async {
    for (int n = 2;; n++) {
      final String candidate = '$baseId~$n';
      final Track? holder = await findById(candidate);
      if (holder == null || !_fileStillThere(holder.filePath)) return candidate;
    }
  }

  /// Titres portant l'identité [baseId] : la ligne d'id [baseId] puis ses
  /// variantes `<baseId>~N` par N croissant. Sert à l'import manuel pour
  /// reconnaître un enregistrement déjà présent parmi plusieurs versions.
  Future<List<Track>> findVersionsOf(String baseId) async {
    // `_` et `%` sont des jokers de LIKE et peuvent figurer dans un id : la
    // requête peut ramener trop de lignes, l'expression régulière exacte
    // ci-dessous fait foi.
    final List<Track> rows =
        await (_db.select(_db.tracks)..where((t) => t.id.equals(baseId) | t.id.like('$baseId~%'))).get();
    final RegExp variant = RegExp('^${RegExp.escape(baseId)}~(\\d+)\$');
    int rank(Track t) => t.id == baseId ? 1 : int.parse(variant.firstMatch(t.id)!.group(1)!);
    return [
      for (final Track t in rows)
        if (t.id == baseId || variant.hasMatch(t.id)) t,
    ]..sort((a, b) => rank(a).compareTo(rank(b)));
  }

  /// Lie [trackId] à la playlist système "Tous les titres importés", en la
  /// créant paresseusement au premier import (même pattern que
  /// `DriftPlaylistRepository.ensureLikedPlaylist`). `insertOnConflictUpdate`
  /// sur `playlist_tracks` rend l'appel idempotent si le morceau y est déjà
  /// (ex. réimport du même fichier) sans dupliquer de ligne ni décaler sa
  /// position existante.
  Future<void> _linkToAllImportedPlaylist(String trackId) async {
    final bool playlistExists = await (_db.select(_db.playlists)..where((p) => p.id.equals(kAllImportedPlaylistId)))
        .getSingleOrNull()
        .then((row) => row != null);
    if (!playlistExists) {
      await _db.into(_db.playlists).insert(
            PlaylistsCompanion.insert(
              id: kAllImportedPlaylistId,
              title: 'Tous les titres importés',
              vibeStyle: const Value(VibePreset.minimal),
            ),
          );
    }

    final bool alreadyLinked = await (_db.select(_db.playlistTracks)
          ..where((t) => t.playlistId.equals(kAllImportedPlaylistId) & t.trackId.equals(trackId)))
        .getSingleOrNull()
        .then((row) => row != null);
    if (alreadyLinked) return;

    // Position suivant la plus grande occupée, pas le nombre de lignes : après
    // la suppression d'un morceau, le compte retombait sur une position déjà
    // prise et l'ordre de la playlist devenait imprévisible (v1.3.7).
    final maxExp = _db.playlistTracks.position.max();
    final positionQuery = _db.selectOnly(_db.playlistTracks)
      ..addColumns([maxExp])
      ..where(_db.playlistTracks.playlistId.equals(kAllImportedPlaylistId));
    final int nextPosition = await positionQuery.getSingle().then((row) => (row.read(maxExp) ?? -1) + 1);

    await _db.into(_db.playlistTracks).insert(
          PlaylistTracksCompanion.insert(
            playlistId: kAllImportedPlaylistId,
            trackId: trackId,
            position: nextPosition,
            isPendingPlacement: const Value(false),
          ),
        );
  }

  /// Enregistrement manuel depuis l'éditeur de métadonnées — Artiste/Titre
  /// resynchronisent `track_artists` (la modale n'expose qu'un artiste
  /// unique, pas de featurings multiples) ; Album/Année/Genre/Pochette sont
  /// optionnels (recherche API acceptée ou saisie manuelle directe). [genre]
  /// remplace entièrement `tags` (pas de fusion avec l'existant) : c'est une
  /// correction manuelle explicite, contrairement à [enrichFromOnlineMetadata]
  /// qui ne fait que compléter. Toujours sûr à rappeler : un titre déjà
  /// enrichi peut être ré-enrichi ou renommé à tout moment.
  ///
  /// [enrichmentStatus] (Section 1) : le contenu de l'éditeur ne dit pas à
  /// lui seul si ces valeurs viennent d'une saisie libre ou de la validation
  /// d'une suggestion iTunes/MusicBrainz — c'est à l'appelant (MetadataEditorModal)
  /// de trancher via `EnrichmentStatus.enrichedManualEdit`/
  /// `enrichedManualItunes`/`enrichedManualMusicBrainz` selon ce que l'utilisateur
  /// vient réellement de faire.
  Future<void> updateMetadata(
    String trackId, {
    required String title,
    required String artist,
    required EnrichmentStatus enrichmentStatus,
    String? album,
    int? releaseYear,
    String? coverArtUrl,
    String? genre,
  }) async {
    final String normalizedArtist = ArtistNameNormalizer.normalize(artist);

    await _db.transaction(() async {
      await (_db.update(_db.tracks)..where((t) => t.id.equals(trackId))).write(
        TracksCompanion(
          title: Value(title),
          artists: Value([normalizedArtist]),
          album: album == null ? const Value.absent() : Value(album),
          releaseYear: releaseYear == null ? const Value.absent() : Value(releaseYear),
          coverArtPath: coverArtUrl == null ? const Value.absent() : Value(coverArtUrl),
          tags: genre == null ? const Value.absent() : Value(genre.isEmpty ? const [] : [genre]),
          requiresUserReview: const Value(false),
          // Une correction manuelle change les données de départ : le
          // circuit-breaker d'enrichissement (voir [EnrichmentStatus]) repart
          // à zéro plutôt que de rester bloqué `needsManualReview`/
          // `requiresReview` sur un Titre/Artiste qui n'existe plus.
          enrichmentAttempts: const Value(0),
          enrichmentStatus: Value(enrichmentStatus),
        ),
      );

      await (_db.delete(_db.trackArtists)..where((t) => t.trackId.equals(trackId))).go();
      await _db.into(_db.trackArtists).insert(
            TrackArtistsCompanion.insert(trackId: trackId, artistName: normalizedArtist, position: 0),
          );

      // Un Titre/Artiste corrigé à la main peut désormais correspondre à un
      // titre grisé d'une playlist importée : même dégrisage qu'à l'import.
      await MissingPlaylistTrackReconciler(_db).reconcileTrack(
        trackId: trackId,
        title: title,
        artists: [normalizedArtist],
      );
    });
  }

  /// Nombre de tentatives d'enrichissement automatique avant abandon
  /// définitif — voir [EnrichmentStatus.needsManualReview].
  static const int maxEnrichmentAttempts = 2;

  /// `false` si [trackId] est `needsManualReview` (tentatives épuisées) ou
  /// `requiresReview` (Titre/Artiste trop ambigus depuis le nom de fichier) —
  /// évite à [TrackAutoEnricher] de rappeler l'API pour rien. Un morceau
  /// introuvable ou déjà enrichi (`enrichedAuto*`/`enrichedManual*`) ou
  /// `pending` reste éligible.
  Future<bool> shouldAttemptEnrichment(String trackId) async {
    final Track? track = await findById(trackId);
    if (track == null) return false;
    return track.enrichmentStatus != EnrichmentStatus.needsManualReview &&
        track.enrichmentStatus != EnrichmentStatus.requiresReview;
  }

  /// Met à jour le circuit-breaker après une tentative d'enrichissement
  /// [TrackAutoEnricher]/[MusicBrainzAutoEnricher] menée à son terme (recherche
  /// API réussie, qu'une correspondance fiable ait été trouvée ou non) —
  /// jamais appelé après une simple erreur réseau/timeout, qui ne doit pas
  /// consommer de tentative (voir [TrackAutoEnricher.enrichTrack]). [source]
  /// détermine le statut de provenance appliqué en cas de succès (Section 1).
  Future<void> recordEnrichmentOutcome(String trackId,
      {required bool success, required EnrichmentSource source}) async {
    final Track? track = await findById(trackId);
    if (track == null) return;

    if (success) {
      final EnrichmentStatus status = source == EnrichmentSource.itunes
          ? EnrichmentStatus.enrichedAutoItunes
          : EnrichmentStatus.enrichedAutoMusicBrainz;
      await (_db.update(_db.tracks)..where((t) => t.id.equals(trackId))).write(
        TracksCompanion(enrichmentStatus: Value(status)),
      );
      return;
    }

    final int attempts = track.enrichmentAttempts + 1;
    final EnrichmentStatus status =
        attempts >= maxEnrichmentAttempts ? EnrichmentStatus.needsManualReview : EnrichmentStatus.pending;
    await (_db.update(_db.tracks)..where((t) => t.id.equals(trackId))).write(
      TracksCompanion(enrichmentAttempts: Value(attempts), enrichmentStatus: Value(status)),
    );
  }

  /// "Changer de catégorie" (appui long dans la Bibliothèque) : fait passer
  /// [trackId] dans [category] en réécrivant les deux seules colonnes dont
  /// elle dérive (voir [libraryCategoryOf]) :
  ///  - [LibraryCategory.toRename] : `requiresUserReview` + `requiresReview`,
  ///    exclu des passes d'enrichissement automatique jusqu'au renommage.
  ///  - [LibraryCategory.toEnrich] : `pending`, compteur de tentatives remis à
  ///    zéro — y compris depuis "Échec auto" (`needsManualReview`) : le
  ///    circuit-breaker est levé, le morceau redevient immédiatement une
  ///    cible d'"Enrichir tout" (voir [shouldAttemptEnrichment]).
  ///  - [LibraryCategory.done] : provenance d'enrichissement existante
  ///    conservée si le morceau était déjà enrichi, sinon sous-catégorie
  ///    "Enrichi totalement manuellement" (`enrichedManualEdit`) — c'est
  ///    l'utilisateur qui déclare le morceau terminé (recette QA, choix 1-A).
  Future<void> forceLibraryCategory(String trackId, LibraryCategory category) async {
    final Track? track = await findById(trackId);
    if (track == null) return;

    final EnrichmentStatus status = switch (category) {
      LibraryCategory.toRename => EnrichmentStatus.requiresReview,
      LibraryCategory.toEnrich => EnrichmentStatus.pending,
      LibraryCategory.done => kEnrichedStatuses.contains(track.enrichmentStatus)
          ? track.enrichmentStatus
          : EnrichmentStatus.enrichedManualEdit,
    };
    await (_db.update(_db.tracks)..where((t) => t.id.equals(trackId))).write(
      TracksCompanion(
        requiresUserReview: Value(category == LibraryCategory.toRename),
        enrichmentStatus: Value(status),
        enrichmentAttempts: const Value(0),
      ),
    );
  }

  /// Pochette choisie manuellement (appui long sur un morceau) — remplace
  /// toute pochette existante, à la différence de [enrichFromOnlineMetadata]
  /// qui ne comble que les champs vides.
  Future<void> updateCoverArtPath(String trackId, String path) {
    return (_db.update(_db.tracks)..where((t) => t.id.equals(trackId)))
        .write(TracksCompanion(coverArtPath: Value(path)));
  }

  /// Enrichissement non destructif (Vibe Engine, Étape 2) : ne comble que les
  /// champs vides (album, année, pochette) plutôt que d'écraser des valeurs
  /// déjà correctes, et fusionne genre/mood/époque dans `tags` sans doublons.
  /// Contrairement à [updateMetadata] (correction manuelle d'un morceau "à
  /// renommer"), ce n'est jamais destructif — sûr à relancer plusieurs fois.
  ///
  /// Retourne `false` sans rien écrire si [match] ne passe pas
  /// [TrackMatchConfidence] (ex. titre local "Feel Good" vs résultat "Confetti"
  /// du même artiste) — évite d'appliquer pochette/album/genre d'un morceau
  /// homonyme ou d'un remix sans rapport au morceau local.
  Future<bool> enrichFromOnlineMetadata(String trackId, OnlineTrackResult match) async {
    final Track? track = await findById(trackId);
    if (track == null) return false;

    if (!TrackMatchConfidence.isReliableMatch(localTitle: track.title, localArtists: track.artists, candidate: match)) {
      return false;
    }

    final List<String> keywords = MusicKeywordEnricher.buildKeywords(
      genre: match.genre,
      releaseYear: match.releaseYear,
      existing: track.tags,
    );

    await (_db.update(_db.tracks)..where((t) => t.id.equals(trackId))).write(
      TracksCompanion(
        album: (track.album.isEmpty && (match.album?.isNotEmpty ?? false)) ? Value(match.album!) : const Value.absent(),
        releaseYear:
            (track.releaseYear == 0 && match.releaseYear != null) ? Value(match.releaseYear!) : const Value.absent(),
        coverArtPath: (track.coverArtPath.isEmpty && match.coverArtUrl != null)
            ? Value(match.coverArtUrl!)
            : const Value.absent(),
        // Ordre officiel d'album (organisation de la bibliothèque, voir
        // AlbumGroup) — comblé seulement si jamais renseigné (scan local sans
        // ces tags ID3).
        trackNumber:
            (track.trackNumber == 0 && match.trackNumber != null) ? Value(match.trackNumber!) : const Value.absent(),
        discNumber:
            (track.discNumber == 0 && match.discNumber != null) ? Value(match.discNumber!) : const Value.absent(),
        trackCount:
            (track.trackCount == 0 && match.trackCount != null) ? Value(match.trackCount!) : const Value.absent(),
        tags: Value(keywords),
      ),
    );
    return true;
  }

  /// Corrige Titre et Artiste à partir d'une correspondance iTunes fiable
  /// trouvée en ordre inversé (voir [TrackAutoEnricher.enrichTrack]) — cas
  /// vérifié empiriquement sur de vrais fichiers dont le nom source liste
  /// "Titre - Artiste" au lieu de "Artiste - Titre" (ex. "Halo - Beyoncé.mp3"
  /// stockait artist="Halo" title="Beyoncé"), confidents à tort puisque
  /// structurellement indiscernables d'un nom bien ordonné sans confirmation
  /// externe. Contrairement à [enrichFromOnlineMetadata] (jamais destructif),
  /// celle-ci écrase volontairement Titre/Artiste : [match] vient des propres
  /// champs iTunes (donc déjà "propres"), pas d'un simple échange des deux
  /// chaînes locales, qui resteraient bruitées (émojis, résidus non nettoyés).
  ///
  /// Revérifie la confiance ici avec les rôles inversés plutôt que de faire
  /// confiance à l'appelant : [match] doit correspondre à `track.artists`
  /// comme *titre* et à `track.title` comme *artiste*, sans quoi rien n'est
  /// écrit. Sort aussi le morceau de "À renommer" : on a désormais une
  /// confirmation externe fiable.
  Future<bool> correctReversedTitleArtist(String trackId, OnlineTrackResult match) async {
    final Track? track = await findById(trackId);
    if (track == null) return false;

    final bool swapConfirmed = TrackMatchConfidence.isReliableMatch(
      localTitle: track.artists.isNotEmpty ? track.artists.first : '',
      // Même texte nettoyé que TrackAutoEnricher.decide (clause feat., bruit) :
      // sans quoi « Lady Gaga(Feat.Colby O'Donis) » serait rejeté ici.
      localArtists: [TrackMatchConfidence.artistTextForSwap(track.title)],
      candidate: match,
    );
    if (!swapConfirmed) return false;
    // Même parité de version que dans TrackAutoEnricher : le titre local
    // d'origine ("Ian Asher (Remix)") ne doit pas être écrasé par « Desire ».
    if (!TrackMatchConfidence.sameVersionKeywords(track.title, match.title)) return false;

    final String correctedArtist = ArtistNameNormalizer.normalize(match.artist);
    final List<String> keywords = MusicKeywordEnricher.buildKeywords(
      genre: match.genre,
      releaseYear: match.releaseYear,
      existing: track.tags,
    );

    await _db.transaction(() async {
      await (_db.update(_db.tracks)..where((t) => t.id.equals(trackId))).write(
        TracksCompanion(
          title: Value(match.title),
          artists: Value([correctedArtist]),
          requiresUserReview: const Value(false),
          album:
              (track.album.isEmpty && (match.album?.isNotEmpty ?? false)) ? Value(match.album!) : const Value.absent(),
          releaseYear:
              (track.releaseYear == 0 && match.releaseYear != null) ? Value(match.releaseYear!) : const Value.absent(),
          coverArtPath: (track.coverArtPath.isEmpty && match.coverArtUrl != null)
              ? Value(match.coverArtUrl!)
              : const Value.absent(),
          trackNumber:
              (track.trackNumber == 0 && match.trackNumber != null) ? Value(match.trackNumber!) : const Value.absent(),
          discNumber:
              (track.discNumber == 0 && match.discNumber != null) ? Value(match.discNumber!) : const Value.absent(),
          trackCount:
              (track.trackCount == 0 && match.trackCount != null) ? Value(match.trackCount!) : const Value.absent(),
          tags: Value(keywords),
        ),
      );

      await (_db.delete(_db.trackArtists)..where((t) => t.trackId.equals(trackId))).go();
      await _db.into(_db.trackArtists).insert(
            TrackArtistsCompanion.insert(trackId: trackId, artistName: correctedArtist, position: 0),
          );
    });

    return true;
  }

  /// Scanner de nettoyage des artistes (case-insensitive) : détecte les noms
  /// qui ne diffèrent que par la casse (ex. "DAFT PUNK" / "daft punk" /
  /// "Daft Punk") et fusionne chaque groupe sous une unique entité en Title
  /// Case, en réécrivant `tracks.artists` (JSON) et en resynchronisant
  /// `track_artists` pour tout morceau concerné — featuring compris, jamais
  /// seulement l'artiste principal. Les entrées sans doublon de casse restent
  /// intactes (pas de renommage silencieux d'un artiste déjà unique). Retourne
  /// le nombre de groupes fusionnés.
  Future<int> mergeDuplicateCaseArtists() async {
    final List<Track> allTracks = await _db.select(_db.tracks).get();

    // Regroupement par clé alphanumérique normalisée (casse ET
    // espacement/ponctuation ignorés) — pas seulement `toLowerCase()` : sans
    // ça, "DaftPunk" (sans espace, typique des fichiers issus d'un
    // convertisseur compact) et "Daft Punk" produisent deux clés différentes
    // ("daftpunk" ≠ "daft punk") et ne sont jamais rapprochés alors qu'il
    // s'agit du même artiste.
    final Map<String, Set<String>> variantsByNormalized = {};
    for (final track in allTracks) {
      for (final name in track.artists) {
        variantsByNormalized.putIfAbsent(ArtistNameNormalizer.normalizeForGrouping(name), () => {}).add(name);
      }
    }

    final Map<String, String> canonicalByVariant = {};
    int mergedGroups = 0;
    for (final entry in variantsByNormalized.entries) {
      if (entry.value.length < 2) continue; // pas de doublon casse/espacement pour cet artiste
      final String canonical = ArtistNameNormalizer.pickCanonical(entry.value);
      mergedGroups++;
      for (final variant in entry.value) {
        canonicalByVariant[variant] = canonical;
      }
    }
    if (canonicalByVariant.isEmpty) return 0;

    await _db.transaction(() async {
      for (final track in allTracks) {
        if (!track.artists.any(canonicalByVariant.containsKey)) continue;

        // Remplace chaque variante par son nom canonique en dédupliquant
        // (ordre préservé, première occurrence gagnante) — ne fusionne
        // jamais deux artistes distincts entre eux, seulement leurs variantes
        // de casse.
        final List<String> remapped = [];
        for (final name in track.artists) {
          final String mapped = canonicalByVariant[name] ?? name;
          if (!remapped.contains(mapped)) remapped.add(mapped);
        }

        await (_db.update(_db.tracks)..where((t) => t.id.equals(track.id)))
            .write(TracksCompanion(artists: Value(remapped)));

        await (_db.delete(_db.trackArtists)..where((t) => t.trackId.equals(track.id))).go();
        await _db.batch((batch) {
          batch.insertAll(_db.trackArtists, [
            for (int i = 0; i < remapped.length; i++)
              TrackArtistsCompanion.insert(trackId: track.id, artistName: remapped[i], position: i),
          ]);
        });
      }
    });

    return mergedGroups;
  }

  /// Fusionne/renomme un ou plusieurs artistes vers [targetName] (Section 4,
  /// Fusion Manuelle des Réglages) — même mécanique que
  /// [mergeDuplicateCaseArtists] mais sur une sélection explicite de
  /// l'utilisateur plutôt qu'un regroupement automatique par casse : réécrit
  /// `tracks.artists` (JSON) et resynchronise entièrement `track_artists`
  /// pour tout morceau créditant l'un de [sourceNames] (featuring compris),
  /// sans jamais toucher le reste des métadonnées (album, année, pochette).
  /// Un seul nom dans [sourceNames] équivaut à un simple renommage. La
  /// resynchronisation complète de `track_artists` élimine d'elle-même toute
  /// trace de l'ancien nom (pas de table `Artists` séparée à nettoyer dans ce
  /// schéma). Sans effet si [sourceNames] est vide, si [targetName] est vide,
  /// ou si aucun morceau ne crédite l'un de [sourceNames].
  Future<void> renameOrMergeArtists(List<String> sourceNames, String targetName) async {
    final String trimmedTarget = targetName.trim();
    final Set<String> sources = sourceNames.toSet();
    if (sources.isEmpty || trimmedTarget.isEmpty) return;

    final List<Track> allTracks = await _db.select(_db.tracks).get();
    final List<Track> affected = allTracks.where((t) => t.artists.any(sources.contains)).toList();
    if (affected.isEmpty) return;

    await _db.transaction(() async {
      for (final track in affected) {
        final List<String> remapped = [];
        for (final name in track.artists) {
          final String mapped = sources.contains(name) ? trimmedTarget : name;
          if (!remapped.contains(mapped)) remapped.add(mapped);
        }

        await (_db.update(_db.tracks)..where((t) => t.id.equals(track.id)))
            .write(TracksCompanion(artists: Value(remapped)));

        await (_db.delete(_db.trackArtists)..where((t) => t.trackId.equals(track.id))).go();
        await _db.batch((batch) {
          batch.insertAll(_db.trackArtists, [
            for (int i = 0; i < remapped.length; i++)
              TrackArtistsCompanion.insert(trackId: track.id, artistName: remapped[i], position: i),
          ]);
        });
      }
    });
  }

  /// Réimport d'un titre dont le fichier a disparu : seul ce qui décrit le
  /// fichier physique est remplacé (chemin, durée, silences, empreinte). Titre,
  /// artistes, album, statut d'enrichissement, pochette, tags et playlists
  /// sont conservés — contrairement à [upsertTrack], qui réécrit tout.
  Future<void> relinkFile(String trackId, ScannedTrack scanned) async {
    await (_db.update(_db.tracks)..where((t) => t.id.equals(trackId))).write(TracksCompanion(
      filePath: Value(scanned.filePath),
      durationSeconds: Value(scanned.durationMs ~/ 1000),
      trimStartMs: Value(scanned.trimStartMs),
      trimEndMs: Value(scanned.trimEndMs),
      lastModifiedEpochMs: Value(scanned.lastModifiedEpochMs),
      fileHash: Value(scanned.fileHash),
    ));
    await applyExtractedCover(trackId, scanned.coverArtPath);
  }

  /// Pochette intégrée au fichier (extraite au scan) : appliquée UNIQUEMENT si
  /// le titre n'a pas encore de pochette — jamais par-dessus une pochette
  /// choisie à la main ou trouvée en ligne. Sinon le fichier extrait est
  /// supprimé, pour ne pas laisser d'image orpheline dans `track_covers/`.
  /// Public : aussi utilisé par le rattrapage des pochettes (EmbeddedCoverBackfill).
  Future<void> applyExtractedCover(String trackId, String? coverPath) async {
    if (coverPath == null) return;
    final int updated = await (_db.update(_db.tracks)..where((t) => t.id.equals(trackId) & t.coverArtPath.equals('')))
        .write(TracksCompanion(coverArtPath: Value(coverPath)));
    if (updated == 0) await _deleteExtractedCover(coverPath);
  }

  Future<void> _deleteExtractedCover(String? coverPath) async {
    if (coverPath == null) return;
    try {
      final File file = File(coverPath);
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Fichier verrouillé ou déjà parti : sans conséquence.
    }
  }

  /// Filtre « pochette = URL http(s) » : ce sont les pochettes trouvées en
  /// ligne et pas encore rapatriées sur l'appareil (RemoteCoverLocalizer).
  Expression<bool> _hasRemoteCover($TracksTable t) =>
      t.coverArtPath.like('http://%') | t.coverArtPath.like('https://%');

  /// Ids des titres dont la pochette est encore une URL http(s).
  Future<List<String>> trackIdsWithRemoteCover() async {
    final List<Track> rows = await (_db.select(_db.tracks)..where(_hasRemoteCover)).get();
    return [for (final Track t in rows) t.id];
  }

  /// Nombre de titres à pochette http(s), en flux : sert à déclencher un
  /// rapatriement quand l'enrichissement en écrit de nouvelles.
  Stream<int> watchRemoteCoverCount() {
    final JoinedSelectStatement<$TracksTable, Track> query = _db.selectOnly(_db.tracks)
      ..addColumns([_db.tracks.id.count()])
      ..where(_hasRemoteCover(_db.tracks));
    return query.map((row) => row.read(_db.tracks.id.count()) ?? 0).watchSingle().distinct();
  }

  /// Remplace l'URL [remoteUrl] par le chemin local [localPath] SEULEMENT si la
  /// pochette du titre est toujours cette URL (elle a pu être changée à la
  /// main pendant le téléchargement). Renvoie `true` si la ligne a été modifiée.
  Future<bool> replaceRemoteCoverWithLocal(String trackId, String remoteUrl, String localPath) async {
    final int updated = await (_db.update(_db.tracks)
          ..where((t) => t.id.equals(trackId) & t.coverArtPath.equals(remoteUrl)))
        .write(TracksCompanion(coverArtPath: Value(localPath)));
    return updated > 0;
  }

  /// « Nouveau scan de la bibliothèque » (voir LibraryRescanService) : réécrit
  /// un titre déjà indexé comme le ferait un import neuf suivi d'un
  /// enrichissement iTunes, à partir de l'identité relue sur le fichier
  /// ([title], [artists], [album] et [genre] viennent de
  /// `LibraryScanService.identify`) et de la correspondance fiable [match].
  ///
  /// - Titre/artistes : l'identité ; en [swapped] (Titre/Artiste inversés dans
  ///   le fichier), les champs propres d'iTunes. `track_artists` est
  ///   resynchronisé dans la même transaction.
  /// - Album : celui des tags du fichier s'il existe (source la plus fiable),
  ///   sinon celui d'iTunes, sinon l'ancien. Année et numéros de piste/disque/
  ///   total : ceux d'iTunes quand ils sont connus, sinon les anciens.
  /// - Pochette : celle d'iTunes SEULEMENT si l'ancienne est vide ou encore une
  ///   URL http(s) ; une pochette locale (choisie à la main, intégrée au
  ///   fichier ou déjà rapatriée) est conservée.
  /// - `tags` : repart de zéro (genre des tags du fichier + genre/époque/mood
  ///   d'iTunes) — l'ancien genre pouvait venir d'une mauvaise correspondance.
  ///   Seuls le scan, l'enrichissement et l'éditeur (dont les titres sont
  ///   exclus du nouveau scan) écrivent `tags` : aucun tag manuel à préserver.
  /// - Statut `enrichedAutoItunes`, tentatives à 0, plus « à renommer ».
  ///
  /// Ne touche jamais id, chemin, durée, silences, playlists, lectures/likes ni
  /// date de création. Les titres grisés d'une playlist importée ne sont
  /// dégrisés (comme à l'import) que si titre/artistes ont réellement changé.
  /// `false` si le titre n'existe plus.
  Future<bool> applyRescanResult(
    String trackId, {
    required String title,
    required List<String> artists,
    required OnlineTrackResult match,
    required bool swapped,
    String? album,
    String? genre,
  }) async {
    final Track? track = await findById(trackId);
    if (track == null) return false;

    // Même dédoublonnage qu'à l'import (UNIQUE(track_id, artist_name)), ordre préservé.
    final List<String> newArtists = [];
    for (final String name in swapped ? [ArtistNameNormalizer.normalize(match.artist)] : artists) {
      if (name.isNotEmpty && !newArtists.contains(name)) newArtists.add(name);
    }
    final List<String> finalArtists = newArtists.isEmpty ? track.artists : newArtists;
    final String finalTitle = swapped ? match.title : title;

    final String oldCover = track.coverArtPath;
    final bool oldCoverReplaceable =
        oldCover.isEmpty || oldCover.startsWith('http://') || oldCover.startsWith('https://');
    final String? matchCover = match.coverArtUrl;
    final String? matchAlbum = match.album;
    // Un numéro/une année à 0 ou négatif est « inconnu » : jamais écrit par-dessus une valeur connue.
    int? known(int? value) => (value != null && value > 0) ? value : null;
    final int? year = known(match.releaseYear);
    final int? trackNumber = known(match.trackNumber);
    final int? discNumber = known(match.discNumber);
    final int? trackCount = known(match.trackCount);

    final List<String> keywords = MusicKeywordEnricher.buildKeywords(
      genre: match.genre,
      releaseYear: match.releaseYear,
      existing: (genre != null && genre.trim().isNotEmpty) ? [genre] : const [],
    );

    await _db.transaction(() async {
      await (_db.update(_db.tracks)..where((t) => t.id.equals(trackId))).write(
        TracksCompanion(
          title: Value(finalTitle),
          artists: Value(finalArtists),
          album: (album != null && album.isNotEmpty)
              ? Value(album)
              : (matchAlbum != null && matchAlbum.isNotEmpty)
                  ? Value(matchAlbum)
                  : const Value.absent(),
          releaseYear: year == null ? const Value.absent() : Value(year),
          trackNumber: trackNumber == null ? const Value.absent() : Value(trackNumber),
          discNumber: discNumber == null ? const Value.absent() : Value(discNumber),
          trackCount: trackCount == null ? const Value.absent() : Value(trackCount),
          coverArtPath: (oldCoverReplaceable && matchCover != null && matchCover.isNotEmpty)
              ? Value(matchCover)
              : const Value.absent(),
          tags: Value(keywords),
          requiresUserReview: const Value(false),
          enrichmentStatus: const Value(EnrichmentStatus.enrichedAutoItunes),
          enrichmentAttempts: const Value(0),
        ),
      );

      await (_db.delete(_db.trackArtists)..where((t) => t.trackId.equals(trackId))).go();
      await _db.batch((batch) {
        batch.insertAll(_db.trackArtists, [
          for (int i = 0; i < finalArtists.length; i++)
            TrackArtistsCompanion.insert(trackId: trackId, artistName: finalArtists[i], position: i),
        ]);
      });

      final bool identityChanged =
          finalTitle != track.title || finalArtists.join('\u0000') != track.artists.join('\u0000');
      if (identityChanged) {
        await MissingPlaylistTrackReconciler(_db).reconcileTrack(
          trackId: trackId,
          title: finalTitle,
          artists: finalArtists,
        );
      }
    });
    return true;
  }
}
