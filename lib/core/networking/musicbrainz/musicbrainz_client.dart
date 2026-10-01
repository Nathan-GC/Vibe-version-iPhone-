import 'package:dio/dio.dart';

import '../../shared/constants/app_constants.dart';
import '../app_dio.dart';
import '../metadata_api_client/online_track_result.dart';

/// Recherche MusicBrainz + pochettes Cover Art Archive — API officielle,
/// sans clé, alternative légale à iTunes pour les morceaux absents du
/// catalogue Apple (remixes, bootlegs, sets DJ...).
///
/// Règles d'usage (https://musicbrainz.org/doc/MusicBrainz_API/Rate_Limiting) :
/// en moyenne 1 requête/seconde par IP (au-delà : HTTP 503), et un
/// User-Agent `Application/version ( contact )` obligatoire.
class MusicBrainzClient {
  MusicBrainzClient({Dio? dio}) : _dio = dio ?? createAppDio() {
    _dio.options.headers['User-Agent'] = userAgent;
  }

  final Dio _dio;

  static const String userAgent = 'Vibe/1.3.1 ( ${AppConstants.contactEmail} )';
  static const Duration minInterval = Duration(milliseconds: 1100);
  static const int resultLimit = 5;

  // ponytail: horloge partagée par instance (une seule via son provider),
  // suffisant pour un client mono-appareil — aucune file d'attente nécessaire.
  DateTime _lastRequest = DateTime.fromMillisecondsSinceEpoch(0);

  /// Enregistrements correspondant à [artist]/[title] (Lucene, champs
  /// `recording:`/`artist:` — https://musicbrainz.org/doc/MusicBrainz_API/Search),
  /// pochette vérifiée sur le Cover Art Archive. Relance toute erreur réseau
  /// (503 de limitation compris) : c'est à l'appelant de distinguer "erreur"
  /// et "aucun résultat", comme pour MetadataApiClient.
  Future<List<OnlineTrackResult>> searchRecordings({required String artist, required String title}) async {
    final String query = [
      if (title.trim().isNotEmpty) 'recording:"${_escape(title)}"',
      if (artist.trim().isNotEmpty && artist != 'Unknown') 'artist:"${_escape(artist)}"',
    ].join(' AND ');
    if (query.isEmpty) return const [];

    await _throttle();
    final Response<Map<String, dynamic>> response = await _dio.get<Map<String, dynamic>>(
      'https://musicbrainz.org/ws/2/recording',
      queryParameters: {'query': query, 'fmt': 'json', 'limit': resultLimit},
    );

    final List<dynamic> recordings = response.data?['recordings'] as List<dynamic>? ?? const [];
    final List<OnlineTrackResult> results = recordings.map((r) => parseRecording(r as Map<String, dynamic>)).toList();
    // Pochettes vérifiées en parallèle : le Cover Art Archive n'est pas
    // limité en débit, et une URL non vérifiée (404) laisserait une pochette
    // vide marquée comme "enrichie".
    return Future.wait(results.map(_withVerifiedCover));
  }

  /// Champs exploités d'un enregistrement de la réponse de recherche ; la
  /// pochette est l'URL Cover Art Archive du groupe de parutions, encore
  /// NON vérifiée à ce stade (voir [searchRecordings]).
  static OnlineTrackResult parseRecording(Map<String, dynamic> json) {
    final List<dynamic> credits = json['artist-credit'] as List<dynamic>? ?? const [];
    final String artist =
        credits.map((c) => '${(c as Map<String, dynamic>)['name'] ?? ''}${c['joinphrase'] ?? ''}').join().trim();
    final List<dynamic> releases = json['releases'] as List<dynamic>? ?? const [];
    final Map<String, dynamic>? release = releases.isEmpty ? null : releases.first as Map<String, dynamic>;
    final String? releaseGroupId = (release?['release-group'] as Map<String, dynamic>?)?['id'] as String?;
    final String? date = json['first-release-date'] as String?;
    // Tags votés par la communauté : le plus voté sert de genre.
    final List<Map<String, dynamic>> tags = [...?(json['tags'] as List<dynamic>?)?.cast<Map<String, dynamic>>()]
      ..sort((a, b) => ((b['count'] as int?) ?? 0).compareTo((a['count'] as int?) ?? 0));

    return OnlineTrackResult(
      title: json['title'] as String? ?? '',
      artist: artist,
      album: release?['title'] as String?,
      releaseYear: (date != null && date.length >= 4) ? int.tryParse(date.substring(0, 4)) : null,
      genre: tags.isEmpty ? null : tags.first['name'] as String?,
      coverArtUrl:
          releaseGroupId == null ? null : 'https://coverartarchive.org/release-group/$releaseGroupId/front-500',
    );
  }

  /// HEAD sur l'URL de pochette (https://musicbrainz.org/doc/Cover_Art_Archive/API) :
  /// 307 = image choisie, 404 = aucune — dans ce dernier cas, résultat
  /// conservé sans pochette.
  Future<OnlineTrackResult> _withVerifiedCover(OnlineTrackResult result) async {
    final String? url = result.coverArtUrl;
    if (url == null) return result;
    try {
      final Response<void> head = await _dio.head<void>(
        url,
        options: Options(followRedirects: false, validateStatus: (status) => status != null && status < 500),
      );
      final int status = head.statusCode ?? 404;
      if (status == 200 || (status >= 300 && status < 400)) return result;
    } on DioException {
      // Archive injoignable : pas de pochette plutôt qu'un lien cassé.
    }
    return OnlineTrackResult(
      title: result.title,
      artist: result.artist,
      album: result.album,
      releaseYear: result.releaseYear,
      genre: result.genre,
    );
  }

  Future<void> _throttle() async {
    final Duration wait = minInterval - DateTime.now().difference(_lastRequest);
    if (wait > Duration.zero) await Future<void>.delayed(wait);
    _lastRequest = DateTime.now();
  }

  /// Échappe les caractères spéciaux Lucene d'une valeur placée entre
  /// guillemets.
  static String _escape(String value) => value.trim().replaceAllMapped(RegExp(r'[\\"]'), (m) => '\\${m[0]}');
}
