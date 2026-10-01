/// Morceau public non téléchargé, renvoyé par l'API de métadonnées (iTunes Search).
class OnlineTrackResult {
  const OnlineTrackResult({
    required this.title,
    required this.artist,
    this.album,
    this.releaseYear,
    this.previewUrl,
    this.coverArtUrl,
    this.genre,
    this.isExplicit = false,
    this.trackNumber,
    this.discNumber,
    this.trackCount,
  });

  final String title;
  final String artist;
  final String? album;
  final int? releaseYear;
  final String? previewUrl;
  final String? coverArtUrl;
  // `primaryGenreName` iTunes — alimente l'enrichissement automatique des
  // mots-clés de morceau (genre/mood/époque), voir MusicKeywordEnricher.
  final String? genre;
  // `trackExplicitness == 'explicit'` — affiché en badge (OnlineTrackCard).
  final bool isExplicit;
  // `trackNumber`/`discNumber`/`trackCount` iTunes — organisation de la
  // bibliothèque locale par ordre officiel d'album une fois enrichie
  // (voir TrackRepository.enrichFromOnlineMetadata, Tracks.trackNumber).
  final int? trackNumber;
  final int? discNumber;
  final int? trackCount;
}
