/// Source interrogée pour l'enrichissement automatique global (voir
/// LibraryScreen._pickEnrichmentSource) — choisie une fois par lancement
/// d'"Enrichir tout"/post-import, jamais mélangée au sein d'un même lot.
enum EnrichmentSource { itunes, musicBrainz }

/// Interface commune à [TrackAutoEnricher] (iTunes) et [MusicBrainzAutoEnricher]
/// — permet à LibraryScreen de traiter un lot de morceaux sans connaître la
/// source choisie par l'utilisateur.
abstract class TrackEnricher {
  Future<bool> enrichTrack({required String trackId, required String title, required List<String> artists});
}
