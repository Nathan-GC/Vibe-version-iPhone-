import 'package:dio/dio.dart';

import '../../playlist_manifest/manifest_track_ref.dart';
import '../../playlist_manifest/playlist_manifest.dart';
import '../app_dio.dart';
import 'spotify_auth_service.dart';
import 'spotify_credentials.dart';

/// Récupère titre/cover/morceaux d'une playlist Spotify publique.
///
/// Sans identifiants configurés : repli sur l'endpoint public `oEmbed` de
/// Spotify (titre + cover uniquement — aucune liste de morceaux, Spotify ne
/// l'expose pas sans authentification).
/// Avec identifiants (Client Credentials, voir SpotifyCredentialsStorage) :
/// utilise le Web API officiel pour récupérer la liste complète des morceaux.
class SpotifyPlaylistClient {
  SpotifyPlaylistClient({Dio? dio, SpotifyAuthService? authService})
      : _dio = dio ?? createAppDio(),
        _authService = authService ?? SpotifyAuthService();

  final Dio _dio;
  final SpotifyAuthService _authService;

  Future<PlaylistManifest> fetchPlaylist(String playlistId, {SpotifyCredentials? credentials}) {
    return credentials == null ? _fetchViaOEmbed(playlistId) : _fetchViaWebApi(playlistId, credentials);
  }

  Future<PlaylistManifest> _fetchViaOEmbed(String playlistId) async {
    final Response<Map<String, dynamic>> response = await _dio.get<Map<String, dynamic>>(
      'https://open.spotify.com/oembed',
      queryParameters: {'url': 'https://open.spotify.com/playlist/$playlistId'},
    );
    final String title = response.data?['title'] as String? ?? 'Playlist Spotify';

    return PlaylistManifest(
      id: 'spotify-$playlistId',
      title: title,
      description:
          'Importé depuis Spotify sans identifiants API — configure-les pour récupérer la liste complète des morceaux.',
      version: 1,
      tags: const [],
      vibeStyle: 'minimal',
      creatorHandle: 'spotify',
      tracks: const [],
    );
  }

  Future<PlaylistManifest> _fetchViaWebApi(String playlistId, SpotifyCredentials credentials) async {
    final String token = await _authService.getAccessToken(credentials);
    final Options authOptions = Options(headers: {'Authorization': 'Bearer $token'});

    final Response<Map<String, dynamic>> playlistResponse = await _dio.get<Map<String, dynamic>>(
      'https://api.spotify.com/v1/playlists/$playlistId',
      queryParameters: {'fields': 'name,owner.display_name'},
      options: authOptions,
    );

    final String title = playlistResponse.data?['name'] as String? ?? 'Playlist Spotify';
    final Map<String, dynamic>? owner = playlistResponse.data?['owner'] as Map<String, dynamic>?;
    final String? ownerHandle = owner?['display_name'] as String?;

    final List<ManifestTrackRef> tracks = await _fetchAllTracks(playlistId, authOptions);

    return PlaylistManifest(
      id: 'spotify-$playlistId',
      title: title,
      description: '',
      version: 1,
      tags: const [],
      vibeStyle: 'minimal',
      creatorHandle: ownerHandle,
      tracks: tracks,
    );
  }

  Future<List<ManifestTrackRef>> _fetchAllTracks(String playlistId, Options authOptions) async {
    final List<ManifestTrackRef> tracks = [];
    String? nextUrl = 'https://api.spotify.com/v1/playlists/$playlistId/tracks?limit=50';

    while (nextUrl != null) {
      final Response<Map<String, dynamic>> response =
          await _dio.get<Map<String, dynamic>>(nextUrl, options: authOptions);
      final List<dynamic> items = response.data?['items'] as List<dynamic>? ?? const [];

      for (final dynamic item in items) {
        final Map<String, dynamic>? track = (item as Map<String, dynamic>)['track'] as Map<String, dynamic>?;
        if (track == null) continue;

        final String? name = track['name'] as String?;
        final List<dynamic> artists = track['artists'] as List<dynamic>? ?? const [];
        final String? primaryArtist =
            artists.isNotEmpty ? (artists.first as Map<String, dynamic>)['name'] as String? : null;
        final String? album = (track['album'] as Map<String, dynamic>?)?['name'] as String?;

        if (name != null && primaryArtist != null) {
          tracks.add(ManifestTrackRef(title: name, artist: primaryArtist, album: album));
        }
      }

      nextUrl = response.data?['next'] as String?;
    }

    return tracks;
  }
}
