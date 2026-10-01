import 'dart:convert';

import 'package:dio/dio.dart';

import '../../shared/text/title_cleaner.dart';
import '../app_dio.dart';
import 'itunes_artwork.dart';
import 'label_cleaner.dart';
import 'online_album_result.dart';
import 'online_result_ranker.dart';
import 'online_track_result.dart';

/// Recherche publique de morceaux via l'API iTunes Search (`entity=song`,
/// sans clé requise) — utilisé par la recherche unifiée (Étape 4) quand
/// aucun résultat local n'existe, et par le moteur de suggestions globales.
class MetadataApiClient {
  MetadataApiClient({Dio? dio}) : _dio = dio ?? createAppDio();

  final Dio _dio;

  // Nombre de tentatives et délais entre elles pour les échecs réseau
  // transitoires (timeout, coupure Wi-Fi/passage en 4G) — sans clé API,
  // aucune garantie de quota ni de SLA, et sur un vrai réseau mobile un aléa
  // isolé est courant. Sans retry, une seule requête malchanceuse se
  // traduisait par un morceau jamais enrichi (ou un "Connexion impossible"
  // dans l'éditeur manuel) alors qu'un simple nouvel essai aurait suffi. La
  // vitesse n'est pas la priorité ici : mieux vaut attendre que rater un
  // enrichissement possible.
  static const int _maxAttempts = 4;
  static const List<Duration> _retryDelays = [
    Duration(milliseconds: 500),
    Duration(seconds: 1),
    Duration(seconds: 2),
  ];

  // Délais bien plus longs, dédiés au blocage de débit iTunes (403 ou 429) —
  // vérifié empiriquement : ce blocage dure largement plus de 3 minutes une
  // fois déclenché (contrairement à un simple aléa réseau, retombé en
  // quelques secondes), et surtout il touche TOUTES les requêtes suivantes
  // tant qu'il n'est pas retombé, y compris des tentatives manuelles sans
  // rapport dans l'éditeur de métadonnées. D'où aussi
  // [_minIntervalBetweenRequests] ci-dessous, bien plus prudent qu'un simple
  // évitement réactif : mieux vaut espacer les requêtes en amont que risquer
  // de multiplier les 403 en aval.
  static const List<Duration> _rateLimitRetryDelays = [
    Duration(seconds: 15),
    Duration(seconds: 30),
    Duration(seconds: 60),
    Duration(minutes: 2),
    Duration(minutes: 4),
  ];

  // Espacement minimal entre deux requêtes iTunes, tous appelants confondus
  // (recherche unifiée, autocomplétion, enrichissement...) — l'API publique
  // sans clé n'a pas de quota documenté, mais une rafale (observée
  // empiriquement pendant les tests de cette fonctionnalité : quelques
  // dizaines de requêtes rapprochées suffisent) déclenche un blocage 403 qui
  // persiste ensuite plusieurs minutes et invalide le reste du lot en cours.
  // Volontairement prudent (3s, ~20 req/min) plutôt que rapide : la vitesse
  // n'est pas la priorité, éviter le blocage en cascade l'est.
  static const Duration _minIntervalBetweenRequests = Duration(seconds: 3);
  DateTime? _lastRequestAt;

  /// `cancelToken` : annule la requête HTTP précédente encore en vol quand
  /// l'utilisateur retape avant qu'elle n'ait répondu (autocomplétion —
  /// évite d'afficher une réponse obsolète après une réponse plus récente).
  ///
  /// `retryOnFailure` (défaut `true`) : passé à `false` par l'enrichissement
  /// automatique du premier scan (voir `OnboardingScanController.start` /
  /// `TrackAutoEnricher.enrichTrack(singleAttempt: true)`), qui exige
  /// exactement une requête par morceau — sans quoi un blocage de débit
  /// iTunes en tout début de scan geler l'écran d'onboarding le temps des
  /// reprises internes ci-dessous (jusqu'à plusieurs minutes chacune).
  Future<List<OnlineTrackResult>> search(
    String query, {
    int limit = 15,
    CancelToken? cancelToken,
    bool retryOnFailure = true,
  }) async {
    if (query.trim().isEmpty) return const [];

    final Response<String> response = await _getWithRetry(
      'https://itunes.apple.com/search',
      queryParameters: {'term': query, 'entity': 'song', 'limit': limit},
      cancelToken: cancelToken,
      retryOnFailure: retryOnFailure,
    );

    final Map<String, dynamic> body = jsonDecode(response.data ?? '{}') as Map<String, dynamic>;
    final List<dynamic> results = body['results'] as List<dynamic>? ?? const [];
    return results.map((raw) => _mapResult(raw as Map<String, dynamic>)).toList();
  }

  /// Recherche combinant artiste et titre saisis séparément (Éditeur de
  /// métadonnées, recherche iTunes) — construit le terme selon ce qui est
  /// réellement renseigné plutôt que d'exiger une chaîne déjà combinée par
  /// l'appelant, puis reclasse les résultats pour remonter en tête les
  /// correspondances artiste+titre les plus plausibles (voir
  /// [OnlineResultRanker] : la recherche `term` reste un texte libre côté
  /// iTunes, sa pertinence interne ne priorise pas forcément les deux à la
  /// fois).
  ///
  /// `media=music` explicite en plus de `entity=song` : sans lui, une requête
  /// ambiguë (un titre qui ressemble à un nom de film/podcast, par exemple)
  /// peut faire dériver la recherche hors du catalogue musical.
  ///
  /// `term` n'est volontairement PAS ré-encodé ici (pas de
  /// `Uri.encodeComponent`) : `queryParameters` fait déjà cet encodage côté
  /// Dio en construisant l'URL — l'appliquer une seconde fois encoderait le
  /// "%" lui-même et casserait la requête (double encodage : un espace
  /// deviendrait "%2520" au lieu de "%20").
  Future<List<OnlineTrackResult>> searchByArtistAndTitle({
    String? artist,
    String? title,
    int limit = 15,
    CancelToken? cancelToken,
  }) async {
    final String trimmedArtist = (artist ?? '').trim();
    final String trimmedTitle = (title ?? '').trim();
    final String term = [trimmedArtist, trimmedTitle].where((part) => part.isNotEmpty).join(' ');
    if (term.isEmpty) return const [];

    final Response<String> response = await _getWithRetry(
      'https://itunes.apple.com/search',
      queryParameters: {'term': term, 'media': 'music', 'entity': 'song', 'limit': limit},
      cancelToken: cancelToken,
    );

    final Map<String, dynamic> body = jsonDecode(response.data ?? '{}') as Map<String, dynamic>;
    final List<dynamic> results = body['results'] as List<dynamic>? ?? const [];
    final List<OnlineTrackResult> mapped = results.map((raw) => _mapResult(raw as Map<String, dynamic>)).toList();

    return OnlineResultRanker.rankByRelevance(mapped, artist: trimmedArtist, title: trimmedTitle);
  }

  /// Morceaux les plus pertinents d'un artiste ("Morceaux populaires", Profil
  /// Artiste) — `attribute=artistTerm` biaise la recherche vers le champ
  /// artiste, mais reste un texte libre côté iTunes : un titre d'album/morceau
  /// qui contient juste le nom de l'artiste peut matcher chez un artiste
  /// homonyme différent (vérifié empiriquement, ex. "Queen" en single de
  /// Loren Gray) — d'où le filtre exact ci-dessous plutôt qu'une confiance
  /// aveugle dans la réponse de l'API.
  Future<List<OnlineTrackResult>> searchByArtist(String artistName, {int limit = 10, CancelToken? cancelToken}) async {
    if (artistName.trim().isEmpty) return const [];

    final Response<String> response = await _getWithRetry(
      'https://itunes.apple.com/search',
      queryParameters: {'term': artistName, 'entity': 'song', 'attribute': 'artistTerm', 'limit': limit},
      cancelToken: cancelToken,
    );

    final Map<String, dynamic> body = jsonDecode(response.data ?? '{}') as Map<String, dynamic>;
    final List<dynamic> results = body['results'] as List<dynamic>? ?? const [];
    return results
        .cast<Map<String, dynamic>>()
        .where((json) => _isExactArtist(json, artistName))
        .map(_mapResult)
        .toList();
  }

  /// Discographie complète d'un artiste ("Discographie & Albums", Profil
  /// Artiste) — mêmes réserves sur `attribute=artistTerm` que [searchByArtist].
  Future<List<OnlineAlbumResult>> searchAlbumsByArtist(
    String artistName, {
    int limit = 20,
    CancelToken? cancelToken,
  }) async {
    if (artistName.trim().isEmpty) return const [];

    final Response<String> response = await _getWithRetry(
      'https://itunes.apple.com/search',
      queryParameters: {'term': artistName, 'entity': 'album', 'attribute': 'artistTerm', 'limit': limit},
      cancelToken: cancelToken,
    );

    final Map<String, dynamic> body = jsonDecode(response.data ?? '{}') as Map<String, dynamic>;
    final List<dynamic> results = body['results'] as List<dynamic>? ?? const [];
    return results
        .cast<Map<String, dynamic>>()
        .where((json) => _isExactArtist(json, artistName))
        .map(_mapAlbum)
        .toList();
  }

  /// Morceaux d'un album via `/lookup` (id de collection connu, voir
  /// [OnlineAlbumResult.collectionId]) — `results[0]` est la collection
  /// elle-même, les morceaux suivent, dans le même format que `entity=song`.
  Future<List<OnlineTrackResult>> fetchCollectionTracks(int collectionId, {CancelToken? cancelToken}) async {
    final Response<String> response = await _getWithRetry(
      'https://itunes.apple.com/lookup',
      queryParameters: {'id': collectionId, 'entity': 'song'},
      cancelToken: cancelToken,
    );

    final Map<String, dynamic> body = jsonDecode(response.data ?? '{}') as Map<String, dynamic>;
    final List<dynamic> results = body['results'] as List<dynamic>? ?? const [];
    return results
        .cast<Map<String, dynamic>>()
        .where((json) => json['wrapperType'] == 'track')
        .map(_mapResult)
        .toList();
  }

  /// `GET` avec reprise automatique sur échec réseau transitoire — voir
  /// [_maxAttempts]. Centralise aussi le décodage manuel de la réponse :
  /// l'API iTunes Search renvoie du JSON avec `Content-Type: text/javascript`,
  /// que Dio ne reconnaît pas comme JSON et laisse donc en String brute
  /// plutôt que de la parser en Map — d'où `get<String>` puis `jsonDecode`
  /// explicite chez chaque appelant.
  ///
  /// `retryOnFailure: false` court-circuite toute la logique de reprise
  /// ci-dessous : la toute première erreur (transitoire ou blocage de débit)
  /// est immédiatement relancée à l'appelant plutôt que d'attendre un délai
  /// de reprise — voir [search].
  Future<Response<String>> _getWithRetry(
    String path, {
    required Map<String, dynamic> queryParameters,
    CancelToken? cancelToken,
    bool retryOnFailure = true,
  }) async {
    int genericAttempt = 0;
    int rateLimitAttempt = 0;

    while (true) {
      await _throttle();
      try {
        return await _dio.get<String>(path, queryParameters: queryParameters, cancelToken: cancelToken);
      } on DioException catch (e) {
        if (e.type == DioExceptionType.cancel || !retryOnFailure) rethrow;

        if (_isRateLimited(e)) {
          if (rateLimitAttempt >= _rateLimitRetryDelays.length) rethrow;
          await Future.delayed(_rateLimitRetryDelays[rateLimitAttempt]);
          rateLimitAttempt++;
          continue;
        }

        if (!_isTransient(e) || genericAttempt >= _maxAttempts - 1) rethrow;
        await Future.delayed(_retryDelays[genericAttempt]);
        genericAttempt++;
      }
    }
  }

  /// Impose [_minIntervalBetweenRequests] entre deux requêtes, en attendant
  /// ici plutôt qu'en comptant sur chaque appelant pour espacer ses appels.
  Future<void> _throttle() async {
    final DateTime? last = _lastRequestAt;
    if (last != null) {
      final Duration remaining = _minIntervalBetweenRequests - DateTime.now().difference(last);
      if (remaining > Duration.zero) await Future.delayed(remaining);
    }
    _lastRequestAt = DateTime.now();
  }

  /// iTunes signale son blocage de débit par un 403 (pas le 429 standard,
  /// vérifié empiriquement) — les deux sont traités pareil au cas où.
  bool _isRateLimited(DioException e) {
    final int? status = e.response?.statusCode;
    return e.type == DioExceptionType.badResponse && (status == 403 || status == 429);
  }

  /// Échecs valant la peine d'être retentés (hors blocage de débit, voir
  /// [_isRateLimited]) : timeouts et coupures réseau (réseau mobile
  /// capricieux, Wi-Fi qui bascule), et 5xx (incident ponctuel côté
  /// serveur). Une autre erreur HTTP (400/404...) est une vraie erreur de
  /// requête : la retenter ne changerait rien.
  bool _isTransient(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.connectionError:
        return true;
      case DioExceptionType.badResponse:
        final int? status = e.response?.statusCode;
        return status != null && status >= 500;
      default:
        return false;
    }
  }

  bool _isExactArtist(Map<String, dynamic> json, String artistName) {
    final String? resultArtist = json['artistName'] as String?;
    return resultArtist != null && resultArtist.toLowerCase() == artistName.trim().toLowerCase();
  }

  OnlineAlbumResult _mapAlbum(Map<String, dynamic> json) {
    final String? releaseDate = json['releaseDate'] as String?;
    final String? artworkUrl100 = json['artworkUrl100'] as String?;

    return OnlineAlbumResult(
      collectionId: json['collectionId'] as int,
      title: json['collectionName'] as String? ?? '',
      artist: json['artistName'] as String? ?? '',
      releaseYear: (releaseDate != null && releaseDate.length >= 4) ? int.tryParse(releaseDate.substring(0, 4)) : null,
      artworkUrl: artworkUrl100 == null ? null : ItunesArtwork.upgrade(artworkUrl100),
      label: LabelCleaner.clean(json['copyright'] as String?),
      trackCount: json['trackCount'] as int?,
    );
  }

  OnlineTrackResult _mapResult(Map<String, dynamic> json) {
    final String? releaseDate = json['releaseDate'] as String?;
    final String? artworkUrl100 = json['artworkUrl100'] as String?;

    return OnlineTrackResult(
      title: TitleCleaner.clean(json['trackName'] as String? ?? ''),
      artist: json['artistName'] as String? ?? '',
      album: json['collectionName'] as String?,
      releaseYear: (releaseDate != null && releaseDate.length >= 4) ? int.tryParse(releaseDate.substring(0, 4)) : null,
      previewUrl: json['previewUrl'] as String?,
      coverArtUrl: artworkUrl100 == null ? null : ItunesArtwork.upgrade(artworkUrl100),
      genre: json['primaryGenreName'] as String?,
      isExplicit: json['trackExplicitness'] == 'explicit',
      trackNumber: json['trackNumber'] as int?,
      discNumber: json['discNumber'] as int?,
      trackCount: json['trackCount'] as int?,
    );
  }
}
