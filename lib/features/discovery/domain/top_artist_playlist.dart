/// Playlist auto-générée d'un des 7 artistes les plus présents dans la
/// bibliothèque locale (Section 5.2) — jamais matérialisée comme une vraie
/// ligne `Playlists` (voir DriftArtistRepository.fetchTopArtistPlaylists) :
/// entièrement recalculée à la volée, donc jamais visible dans Mon espace,
/// uniquement dans le carrousel "Suggestions d'artistes" de Découverte.
class TopArtistPlaylist {
  const TopArtistPlaylist({required this.artistName, required this.trackCount, this.coverArtPath});

  final String artistName;
  final int trackCount;
  // Pochette du morceau le plus écouté (playCount) de cet artiste — `null`
  // si aucun de ses morceaux n'a de pochette.
  final String? coverArtPath;
}
