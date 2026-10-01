import '../../../core/networking/metadata_api_client/online_track_result.dart';
import '../../../core/storage/database/app_database.dart';

/// Résultat unifié de recherche (Étape 4) : morceau local, playlist locale,
/// artiste local, ou morceau public non téléchargé (repli iTunes).
sealed class SearchResult {
  const SearchResult();
}

class TrackSearchResult extends SearchResult {
  const TrackSearchResult(this.track);

  final Track track;
}

class PlaylistSearchResult extends SearchResult {
  const PlaylistSearchResult(this.playlist);

  final Playlist playlist;
}

class ArtistSearchResult extends SearchResult {
  const ArtistSearchResult(this.artistName);

  final String artistName;
}

class OnlineTrackSearchResult extends SearchResult {
  const OnlineTrackSearchResult(this.track);

  final OnlineTrackResult track;
}
