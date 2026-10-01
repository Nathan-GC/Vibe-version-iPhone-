/// Métadonnées publiques d'un artiste (bio/genre), récupérées via une API
/// publique (iTunes/MusicBrainz) pour décorer l'en-tête du profil artiste.
class ArtistMetadata {
  const ArtistMetadata({required this.name, this.genre, this.artworkUrl, this.label});

  final String name;
  final String? genre;
  final String? artworkUrl;
  // L'API iTunes Search n'expose pas de champ "label" dédié pour un artiste ;
  // `copyright` de son album le plus pertinent ("℗ 2001 Daft Life Limited")
  // en est le meilleur proxy disponible sans clé API supplémentaire.
  final String? label;
}
