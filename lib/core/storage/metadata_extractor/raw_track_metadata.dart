/// Métadonnées brutes lues depuis les tags ID3 d'un fichier audio.
class RawTrackMetadata {
  const RawTrackMetadata({
    this.title,
    this.artists = const [],
    this.album,
    this.genre,
    this.durationMs,
    this.embeddedCoverCodec,
    this.bpm,
  });

  final String? title;
  final List<String> artists;
  final String? album;
  final String? genre;
  final int? durationMs;
  // Codec ("mjpeg", "png"…) de la pochette intégrée au fichier, `null` s'il n'en
  // a pas. Seule la présence est détectée ici : l'image est écrite sur disque
  // par EmbeddedCoverExtractor, uniquement pour un traitement complet.
  final String? embeddedCoverCodec;
  // Lu depuis le tag ID3 TBPM quand présent (rip déjà analysé par un autre
  // outil) — aucune détection de tempo par analyse audio n'est effectuée ici.
  final int? bpm;

  bool get hasTitleAndArtist => (title?.trim().isNotEmpty ?? false) && artists.isNotEmpty;
}
