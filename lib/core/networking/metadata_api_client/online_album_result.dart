/// Album public renvoyé par l'API de métadonnées (iTunes Search,
/// `entity=album`) — utilisé pour la discographie d'un artiste (Profil
/// Artiste). Distinct d'[OnlineTrackResult] : un album n'a pas de preview.
class OnlineAlbumResult {
  const OnlineAlbumResult({
    required this.collectionId,
    required this.title,
    required this.artist,
    this.releaseYear,
    this.artworkUrl,
    this.label,
    this.trackCount,
  });

  final int collectionId;
  final String title;
  final String artist;
  final int? releaseYear;
  final String? artworkUrl;
  // `copyright` iTunes ("℗ 2001 Daft Life Limited") — meilleur proxy
  // disponible pour un label/maison de disques, voir ArtistMetadataApi.
  final String? label;
  final int? trackCount;
}
