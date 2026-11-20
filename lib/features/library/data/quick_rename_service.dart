import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/playlist_manifest/manifest_track_ref.dart';
import '../../../core/storage/database/app_database.dart';
import '../../../core/storage/database/database_provider.dart';
import '../../../core/storage/database/quick_rename_change.dart';
import '../../../core/storage/database/track_repository.dart';
import '../../../core/storage/metadata_extractor/artist_name_normalizer.dart';
import '../../playlists/data/playlist_manifest_service.dart';

/// Résultat de [QuickRenameService.analyze] : un plan à prévisualiser, ou un
/// refus dont le message (en français) est affiché tel quel à l'utilisateur.
sealed class QuickRenameAnalysis {
  const QuickRenameAnalysis();
}

class QuickRenameSuccess extends QuickRenameAnalysis {
  const QuickRenameSuccess(this.plan);

  final QuickRenamePlan plan;
}

class QuickRenameFailure extends QuickRenameAnalysis {
  const QuickRenameFailure(this.message);

  final String message;
}

/// Un titre réellement modifié, tel que l'aperçu l'affiche (« Ancien → Nouveau »).
/// Les artistes sont déjà mis en forme : principal, puis « feat. X, Y ».
class QuickRenameItem {
  const QuickRenameItem({
    required this.trackId,
    required this.oldTitle,
    required this.oldArtist,
    required this.newTitle,
    required this.newArtist,
  });

  final String trackId;
  final String oldTitle;
  final String oldArtist;
  final String newTitle;
  final String newArtist;
}

/// Ce que [QuickRenameService.apply] écrira : [items] pour l'aperçu, [changes]
/// pour le dépôt (même ordre, même longueur), [unchangedCount] titres du fichier
/// déjà conformes.
class QuickRenamePlan {
  const QuickRenamePlan({required this.items, required this.changes, required this.unchangedCount});

  final List<QuickRenameItem> items;
  final List<QuickRenameChange> changes;
  final int unchangedCount;
}

/// Renommage rapide : relit le JSON d'export de « Tous les titres importés »
/// corrigé par l'utilisateur (ou une IA), le valide, calcule les changements à
/// prévisualiser, puis les applique en une transaction.
///
/// Service pur (sans UI). [analyze] n'écrit jamais rien : en cas de refus, la
/// bibliothèque est intacte.
class QuickRenameService {
  QuickRenameService(this._db, this._repository) : _manifests = PlaylistManifestService(_db);

  final AppDatabase _db;
  final TrackRepository _repository;
  final PlaylistManifestService _manifests;

  /// Marqueurs d'invité reconnus, et UNIQUEMENT eux : jamais `,` `&` `x` `vs`,
  /// sinon « Earth, Wind & Fire » ou « Mumford & Sons » seraient cassés (le
  /// découpage du scan, lui, a été conçu pour des tags). Mots entiers (« Daft »
  /// ne contient pas `ft`), point facultatif, parenthèse ou crochet ouvrant
  /// éventuel avalé avec le marqueur. Frontières Unicode plutôt que `\b`
  /// (ASCII en Dart) : une lettre accentuée compte comme lettre, « Séft » ou
  /// « Ëft » ne sont pas coupés.
  static final RegExp _featMarker = RegExp(
    r'\s*([(\[])?\s*(?<![\p{L}\p{N}])(?:featuring|feat|ft)(?![\p{L}\p{N}])\.?\s*',
    caseSensitive: false,
    unicode: true,
  );

  /// Fermeture éventuelle de la clause invitée : « A (feat. B) ».
  static final RegExp _trailingCloser = RegExp(r'\s*[)\]]\s*$');

  Future<QuickRenameAnalysis> analyze(String jsonText) async {
    final Object? decoded;
    try {
      decoded = jsonDecode(jsonText);
    } on FormatException {
      return const QuickRenameFailure(
          'Ce fichier n\'est pas un JSON valide. Vérifie que tu as copié le fichier en entier, sans texte autour.');
    }

    // Objet (export complet) ou tableau nu (une IA rend parfois juste la liste).
    final List<dynamic> rawTracks;
    String? manifestId;
    bool isObject = false;
    if (decoded is Map) {
      final Object? list = decoded['tracks'];
      if (list is! List) {
        return const QuickRenameFailure(
            'Le fichier ne contient pas de liste « tracks ». Réimporte le JSON exporté depuis « Tous les titres importés ».');
      }
      rawTracks = list;
      isObject = true;
      final Object? id = decoded['id'];
      manifestId = id is String ? id.trim() : null;
    } else if (decoded is List) {
      rawTracks = decoded;
    } else {
      return const QuickRenameFailure(
          'Le fichier doit contenir un objet avec une liste « tracks » (ou directement une liste de titres).');
    }

    // Lecture à la main, sans PlaylistManifest.fromJson : il écarte en silence
    // les titres vides, ce qui masquerait une erreur de l'IA.
    final List<_FileEntry> entries = [];
    for (int i = 0; i < rawTracks.length; i++) {
      final int n = i + 1;
      final Object? raw = rawTracks[i];
      if (raw is! Map) {
        return QuickRenameFailure('Titre n°$n : l\'entrée n\'est pas un objet { "title": …, "artist": … }.');
      }
      final Object? title = raw['title'];
      if (title is! String || title.trim().isEmpty) {
        return QuickRenameFailure('Titre n°$n : le titre (« title ») est vide ou manquant.');
      }
      final Object? artist = raw['artist'];
      if (artist is! String || artist.trim().isEmpty) {
        return QuickRenameFailure('Titre n°$n : l\'artiste (« artist ») est vide ou manquant.');
      }
      final Object? rawId = raw['id'];
      if (rawId != null && rawId is! String) {
        return QuickRenameFailure('Titre n°$n : l\'« id » doit être un texte, tel qu\'il figure dans l\'export.');
      }
      final String id = (rawId as String?)?.trim() ?? '';
      entries.add(_FileEntry(position: n, id: id.isEmpty ? null : id, title: title.trim(), artist: artist.trim()));
    }

    // Référence : la liste actuelle, exactement comme l'exporte l'app (même
    // ordre, avec les ids) — c'est ce que l'utilisateur a donné à corriger.
    final List<ManifestTrackRef> reference = (await _manifests.buildManifest(kAllImportedPlaylistId)).tracks;
    final Map<String, Track> tracksById = {for (final Track t in await _db.select(_db.tracks).get()) t.id: t};

    final int withId = entries.where((e) => e.id != null).length;
    final List<(_FileEntry, Track)> matched = [];

    if (withId == entries.length && entries.isNotEmpty) {
      // Par id : l'ordre n'importe plus, le fichier peut être partiel.
      final Set<String> referenceIds = {
        for (final ManifestTrackRef r in reference)
          if (r.id != null) r.id!,
      };
      final Map<String, int> firstSeen = {};
      for (final _FileEntry e in entries) {
        final String id = e.id!;
        final int? previous = firstSeen[id];
        if (previous != null) {
          return QuickRenameFailure(
              'Titre n°${e.position} : l\'id « $id » apparaît déjà au titre n°$previous. Chaque titre ne doit figurer qu\'une fois.');
        }
        firstSeen[id] = e.position;
        final Track? track = referenceIds.contains(id) ? tracksById[id] : null;
        if (track == null) {
          return QuickRenameFailure(
              'Titre n°${e.position} : l\'id « $id » ne correspond à aucun titre de « Tous les titres importés ». Réexporte la liste puis recommence.');
        }
        matched.add((e, track));
      }
    } else if (withId > 0) {
      return const QuickRenameFailure(
          'Certains titres ont un « id » et d\'autres non. Garde l\'id de tous les titres (ou retire-le partout).');
    } else {
      // Par position : sans garde, l'export d'une autre playlist de même
      // longueur renommerait toute la bibliothèque de travers.
      if (isObject && manifestId != kAllImportedPlaylistId) {
        return const QuickRenameFailure('Ce fichier n\'est pas un export de « Tous les titres importés ».');
      }
      if (entries.length != reference.length) {
        return QuickRenameFailure(
            'Le fichier contient ${entries.length} titre(s) mais « Tous les titres importés » en compte ${reference.length}. '
            'Sans « id », le nombre de titres doit être identique : réexporte la liste puis recommence.');
      }
      for (int i = 0; i < entries.length; i++) {
        // Un titre grisé (sans id) n'a aucun morceau local à renommer.
        final String? id = reference[i].id;
        final Track? track = id == null ? null : tracksById[id];
        if (track != null) matched.add((entries[i], track));
      }
    }

    final List<QuickRenameItem> items = [];
    final List<QuickRenameChange> changes = [];
    int unchanged = 0;
    for (final (_FileEntry entry, Track track) in matched) {
      final List<String> oldArtists = track.artists;
      final List<String> newArtists;
      if (entry.artist == _primaryOf(oldArtists)) {
        // L'export n'écrit que l'artiste principal : le retrouver tel quel
        // signifie « pas touché », donc les featurings ne bougent pas.
        newArtists = oldArtists;
      } else {
        final List<String>? merged = _mergeArtists(entry.artist, oldArtists);
        if (merged == null) {
          return QuickRenameFailure(
              'Titre n°${entry.position} : l\'artiste « ${entry.artist} » ne contient aucun nom d\'artiste principal.');
        }
        newArtists = merged;
      }

      if (entry.title == track.title && _sameList(newArtists, oldArtists)) {
        unchanged++;
        continue;
      }
      items.add(QuickRenameItem(
        trackId: track.id,
        oldTitle: track.title,
        oldArtist: _displayArtist(oldArtists),
        newTitle: entry.title,
        newArtist: _displayArtist(newArtists),
      ));
      changes.add(QuickRenameChange(trackId: track.id, title: entry.title, artists: newArtists));
    }

    return QuickRenameSuccess(QuickRenamePlan(items: items, changes: changes, unchangedCount: unchanged));
  }

  /// Écrit le plan en une seule transaction ; retourne le nombre de titres modifiés.
  Future<int> apply(QuickRenamePlan plan) => _repository.applyQuickRename(plan.changes);

  /// Artiste principal tel que l'export l'écrit.
  static String _primaryOf(List<String> artists) => artists.isEmpty ? 'Unknown' : artists.first;

  /// « Principal feat. X, Y » (aperçu).
  static String _displayArtist(List<String> artists) {
    final String primary = _primaryOf(artists);
    return artists.length > 1 ? '$primary feat. ${artists.skip(1).join(', ')}' : primary;
  }

  static bool _sameList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Nouvelle liste : [principal, invités du champ…, anciens featurings non
  /// déjà présents (casse ignorée)]. `null` si le principal est vide.
  ///
  /// Un ancien featuring déjà contenu dans le nouveau champ n'est pas repris :
  /// c'est le plus souvent un morceau d'un nom mal découpé au scan (« Earth »,
  /// « Wind », « Fire ») que l'utilisateur vient justement de recoller en
  /// « Earth, Wind & Fire » — le garder en invité défairait la correction.
  static List<String>? _mergeArtists(String field, List<String> oldArtists) {
    final List<RegExpMatch> markers = _featMarker.allMatches(field).toList();
    final List<String> parts = [];
    if (markers.isEmpty) {
      parts.add(field);
    } else {
      parts.add(field.substring(0, markers.first.start));
      for (int i = 0; i < markers.length; i++) {
        final int end = i + 1 < markers.length ? markers[i + 1].start : field.length;
        String clause = field.substring(markers[i].end, end);
        // La clause a été ouverte par « ( » ou « [ » : on retire sa fermeture.
        if (markers[i].group(1) != null) clause = clause.replaceFirst(_trailingCloser, '');
        parts.add(clause);
      }
    }

    final List<String> names = [for (final String p in parts) ArtistNameNormalizer.normalize(p)];
    if (names.first.isEmpty) return null;

    final List<String> result = [];
    final Set<String> seen = {};
    void add(String name) {
      if (name.isNotEmpty && seen.add(name.toLowerCase())) result.add(name);
    }

    names.forEach(add);
    final String fieldLower = field.toLowerCase();
    for (final String old in oldArtists.skip(1)) {
      if (!fieldLower.contains(old.toLowerCase())) add(old);
    }
    return result;
  }
}

class _FileEntry {
  const _FileEntry({required this.position, required this.id, required this.title, required this.artist});

  /// Position dans le fichier, à partir de 1 (« Titre n°12 »).
  final int position;
  final String? id;
  final String title;
  final String artist;
}

final Provider<QuickRenameService> quickRenameServiceProvider = Provider<QuickRenameService>((ref) {
  return QuickRenameService(ref.watch(appDatabaseProvider), ref.watch(trackRepositoryProvider));
});
