import '../../../core/networking/spotify/spotify_credentials.dart';
import '../../../core/networking/spotify/spotify_playlist_client.dart';
import '../../../core/networking/spotify_link_parser/spotify_link_parser.dart';
import '../../../core/playlist_manifest/playlist_manifest.dart';

/// L'import de manifestes JSON (Étape 6.2) passe désormais par
/// PlaylistJsonImportFlow (lecture, validation, matching) — ce repository ne
/// garde que la source Spotify.
abstract class DiscoveryRepository {
  /// Étape 6.1 : importe une playlist Spotify publique (nécessite des
  /// identifiants API configurés pour récupérer la liste complète des morceaux).
  Future<PlaylistManifest> importFromSpotifyLink(String url, {SpotifyCredentials? credentials});
}

class DefaultDiscoveryRepository implements DiscoveryRepository {
  DefaultDiscoveryRepository({SpotifyPlaylistClient? spotifyClient, SpotifyLinkParser? linkParser})
      : _spotifyClient = spotifyClient ?? SpotifyPlaylistClient(),
        _linkParser = linkParser ?? SpotifyLinkParser();

  final SpotifyPlaylistClient _spotifyClient;
  final SpotifyLinkParser _linkParser;

  @override
  Future<PlaylistManifest> importFromSpotifyLink(String url, {SpotifyCredentials? credentials}) {
    final SpotifyLink? link = _linkParser.parse(url);
    if (link == null || link.type != 'playlist') {
      throw const FormatException('Lien Spotify invalide — attendu : .../playlist/<id>');
    }
    return _spotifyClient.fetchPlaylist(link.id, credentials: credentials);
  }
}
