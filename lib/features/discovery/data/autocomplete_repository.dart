import 'package:dio/dio.dart';
import 'package:drift/drift.dart';

import '../../../core/networking/metadata_api_client/metadata_api_client.dart';
import '../../../core/networking/metadata_api_client/online_track_result.dart';
import '../../../core/storage/database/app_database.dart';
import '../domain/autocomplete_suggestion.dart';

/// Alimente le menu déroulant d'autocomplétion de l'onglet Recherche, en 2
/// sections strictement ordonnées — Artistes (max [_maxArtists]) puis Titres
/// (max [_maxTracks]) : matchs locaux d'abord (bibliothèque Drift, réponse
/// instantanée et prioritaire), l'API iTunes ne comblant que les places
/// restantes de chaque section.
class AutocompleteRepository {
  AutocompleteRepository(this._db, this._metadataApiClient);

  final AppDatabase _db;
  final MetadataApiClient _metadataApiClient;

  static const int _maxArtists = 2;
  static const int _maxTracks = 3;
  // Sur-échantillonné par rapport à _maxArtists/_maxTracks : une même requête
  // sert à combler les deux sections, et une partie des résultats est filtrée
  // (doublons déjà locaux) avant d'atteindre les quotas.
  static const int _onlineFetchLimit = 8;

  Future<List<AutocompleteSuggestion>> suggest(String query, {CancelToken? cancelToken}) async {
    final String trimmed = query.trim();
    if (trimmed.length < 2) return const [];

    // Local et en ligne sont récupérés indépendamment : un souci sur l'un ne
    // doit jamais priver l'utilisateur des suggestions de l'autre.
    List<AutocompleteSuggestion> localArtists = const [];
    List<AutocompleteSuggestion> localTracks = const [];
    try {
      localArtists = await _localArtists(trimmed);
      localTracks = await _localTracks(trimmed);
    } catch (_) {
      // Ignoré : mieux vaut des suggestions en ligne seules qu'un panneau vide.
    }

    List<OnlineTrackResult> online = const [];
    try {
      online = await _metadataApiClient.search(trimmed, limit: _onlineFetchLimit, cancelToken: cancelToken);
    } catch (_) {
      // Requête annulée (nouvelle frappe), réseau indisponible... — une
      // autocomplétion ne doit jamais afficher d'état d'erreur en pleine
      // frappe : au pire, on se rabat sur les seuls matchs locaux.
    }

    final List<AutocompleteSuggestion> artists = _fillArtists(localArtists, online);
    final List<AutocompleteSuggestion> tracks = _fillTracks(localTracks, online);

    return [...artists, ...tracks, AutocompleteSuggestion.globalSearch(trimmed)];
  }

  /// Section Artistes : locaux d'abord, puis un artiste en ligne par nom
  /// distinct (déjà local exclu) jusqu'à [_maxArtists].
  List<AutocompleteSuggestion> _fillArtists(List<AutocompleteSuggestion> local, List<OnlineTrackResult> online) {
    final List<AutocompleteSuggestion> artists = [...local];
    final Set<String> seen = artists.map((a) => a.label.toLowerCase()).toSet();

    for (final result in online) {
      if (artists.length >= _maxArtists) break;
      final String artistName = result.artist.trim();
      if (artistName.isEmpty) continue;
      final String key = artistName.toLowerCase();
      if (!seen.add(key)) continue;
      artists.add(AutocompleteSuggestion.onlineArtist(artistName));
    }

    return artists.take(_maxArtists).toList();
  }

  /// Section Titres : locaux d'abord, puis les morceaux en ligne (titre +
  /// artiste, déjà locaux exclus) jusqu'à [_maxTracks].
  List<AutocompleteSuggestion> _fillTracks(List<AutocompleteSuggestion> local, List<OnlineTrackResult> online) {
    final List<AutocompleteSuggestion> tracks = [...local];
    final Set<String> seen = tracks.map((t) => '${t.label.toLowerCase()}|${(t.subtitle ?? '').toLowerCase()}').toSet();

    for (final result in online) {
      if (tracks.length >= _maxTracks) break;
      final String key = '${result.title.toLowerCase()}|${result.artist.toLowerCase()}';
      if (!seen.add(key)) continue;
      tracks.add(AutocompleteSuggestion.onlineTrack(
          title: result.title, artist: result.artist, artworkUrl: result.coverArtUrl));
    }

    return tracks.take(_maxTracks).toList();
  }

  Future<List<AutocompleteSuggestion>> _localArtists(String query) async {
    final String pattern = '%$query%';
    final artistQuery = _db.selectOnly(_db.trackArtists, distinct: true)
      ..addColumns([_db.trackArtists.artistName])
      ..where(_db.trackArtists.artistName.like(pattern))
      ..limit(_maxArtists);
    final artistRows = await artistQuery.get();

    return [for (final row in artistRows) AutocompleteSuggestion.localArtist(row.read(_db.trackArtists.artistName)!)];
  }

  Future<List<AutocompleteSuggestion>> _localTracks(String query) async {
    final String pattern = '%$query%';
    final List<Track> tracks = await (_db.select(_db.tracks)
          ..where((t) => t.title.like(pattern))
          ..limit(_maxTracks))
        .get();

    return [
      for (final track in tracks)
        AutocompleteSuggestion.localTrack(title: track.title, artist: track.artists.join(', ')),
    ];
  }
}
