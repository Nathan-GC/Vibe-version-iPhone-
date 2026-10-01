import 'dart:convert';

import 'package:dio/dio.dart';

import '../../../core/networking/app_dio.dart';
import '../../../core/networking/metadata_api_client/itunes_artwork.dart';
import '../../../core/networking/metadata_api_client/label_cleaner.dart';
import '../../../core/networking/metadata_api_client/metadata_api_client.dart';
import '../../../core/networking/metadata_api_client/online_album_result.dart';
import '../../../core/networking/metadata_api_client/online_track_result.dart';
import '../domain/album_group.dart';
import '../domain/artist_metadata.dart';

/// Interroge l'API publique iTunes Search (sans clé requise) pour décorer
/// l'en-tête du profil artiste (genre principal + pochette HD), ses morceaux
/// populaires et sa discographie complète, pendant que la liste de morceaux
/// locale se charge séparément.
///
/// Deux optimisations de temps de chargement (Feuille de route pt.6) :
/// - un cache mémoire léger par méthode/artiste, réinitialisé à chaque
///   redémarrage de l'app — un même artiste déjà visité dans la session
///   revient instantanément plutôt que de refaire les mêmes appels réseau ;
/// - dans [fetchArtistMetadata], les deux appels iTunes internes (identité de
///   l'artiste, puis pochette/label via son album représentatif) ne dépendent
///   pas l'un de l'autre : les paralléliser via `Future.wait` évite d'attendre
///   deux allers-retours réseau l'un après l'autre pour rien.
class ArtistMetadataApi {
  ArtistMetadataApi({Dio? dio, MetadataApiClient? metadataApiClient})
      : _dio = dio ?? createAppDio(),
        _metadataApiClient = metadataApiClient ?? MetadataApiClient();

  final Dio _dio;
  final MetadataApiClient _metadataApiClient;

  final Map<String, List<OnlineTrackResult>> _topTracksCache = {};
  final Map<String, List<AlbumGroup>> _albumsCache = {};
  final Map<String, ArtistMetadata?> _metadataCache = {};

  /// "Morceaux populaires" (Profil Artiste).
  Future<List<OnlineTrackResult>> fetchTopTracks(String artistName, {int limit = 10}) async {
    final List<OnlineTrackResult>? cached = _topTracksCache[artistName];
    if (cached != null) return cached;

    final List<OnlineTrackResult> results = await _metadataApiClient.searchByArtist(artistName, limit: limit);
    _topTracksCache[artistName] = results;
    return results;
  }

  /// "Discographie & Albums" (Profil Artiste), triée du plus récent au plus
  /// ancien — les albums sans date connue sont relégués en fin de liste
  /// plutôt qu'en tête (voir tri ci-dessous).
  Future<List<AlbumGroup>> fetchAlbums(String artistName, {int limit = 20}) async {
    final List<AlbumGroup>? cached = _albumsCache[artistName];
    if (cached != null) return cached;

    final List<OnlineAlbumResult> albums = await _metadataApiClient.searchAlbumsByArtist(artistName, limit: limit);

    final List<AlbumGroup> groups = albums
        .map((album) => AlbumGroup(
              album: album.title,
              releaseYear: album.releaseYear ?? 0,
              tracks: const [],
              artworkUrl: album.artworkUrl,
              label: album.label,
              trackCount: album.trackCount,
              collectionId: album.collectionId,
            ))
        .toList();

    groups.sort((a, b) => b.releaseYear.compareTo(a.releaseYear));
    _albumsCache[artistName] = groups;
    return groups;
  }

  /// Morceaux d'un album de la discographie en ligne, pour l'écran ouvert au
  /// tap sur une vignette d'album (voir AlbumGroup.collectionId).
  Future<List<OnlineTrackResult>> fetchAlbumTracks(int collectionId) {
    return _metadataApiClient.fetchCollectionTracks(collectionId);
  }

  Future<ArtistMetadata?> fetchArtistMetadata(String artistName) async {
    if (_metadataCache.containsKey(artistName)) return _metadataCache[artistName];

    // Ni l'un ni l'autre appel ne dépend du résultat de l'autre : les
    // démarrer tous les deux avant le premier `await` (plutôt que
    // `await`/puis-appeler) les exécute en parallèle sans les complications
    // de typage de `Future.wait` sur des types de retour différents.
    final Future<Map<String, dynamic>?> artistFuture = _searchFirst(artistName, entity: 'musicArtist');
    final Future<({String? artworkUrl, String? label})> albumInfoFuture = _fetchRepresentativeAlbumInfo(artistName);

    final Map<String, dynamic>? artistResult = await artistFuture;
    if (artistResult == null) {
      _metadataCache[artistName] = null;
      return null;
    }
    final ({String? artworkUrl, String? label}) albumInfo = await albumInfoFuture;

    final ArtistMetadata metadata = ArtistMetadata(
      name: artistResult['artistName'] as String? ?? artistName,
      genre: artistResult['primaryGenreName'] as String?,
      artworkUrl: albumInfo.artworkUrl,
      label: albumInfo.label,
    );
    _metadataCache[artistName] = metadata;
    return metadata;
  }

  /// L'entité `musicArtist` ne renvoie ni illustration ni label : un second
  /// appel sur `entity=album` récupère la pochette de son résultat le plus
  /// pertinent (1000x1000, voir ItunesArtwork) et son `copyright`
  /// ("℗ 2001 Daft Life Limited") — le proxy le plus proche d'un label/maison
  /// de disques disponible sans clé API supplémentaire. Échec silencieux :
  /// l'en-tête reste utilisable sans ces deux informations.
  Future<({String? artworkUrl, String? label})> _fetchRepresentativeAlbumInfo(String artistName) async {
    try {
      final Map<String, dynamic>? albumResult = await _searchFirst(artistName, entity: 'album');
      final String? artworkUrl100 = albumResult?['artworkUrl100'] as String?;
      return (
        artworkUrl: artworkUrl100 == null ? null : ItunesArtwork.upgrade(artworkUrl100),
        label: LabelCleaner.clean(albumResult?['copyright'] as String?),
      );
    } catch (_) {
      return (artworkUrl: null, label: null);
    }
  }

  Future<Map<String, dynamic>?> _searchFirst(String term, {required String entity}) async {
    // Réponse décodée manuellement : l'API iTunes Search renvoie du JSON
    // avec `Content-Type: text/javascript`, que Dio ne reconnaît pas comme
    // JSON et laisse donc en String brute plutôt que de la parser en Map.
    final Response<String> response = await _dio.get<String>(
      'https://itunes.apple.com/search',
      queryParameters: {'term': term, 'entity': entity, 'limit': 1},
    );

    final Map<String, dynamic> body = jsonDecode(response.data ?? '{}') as Map<String, dynamic>;
    final List<dynamic>? results = body['results'] as List<dynamic>?;
    if (results == null || results.isEmpty) return null;
    return results.first as Map<String, dynamic>;
  }
}
