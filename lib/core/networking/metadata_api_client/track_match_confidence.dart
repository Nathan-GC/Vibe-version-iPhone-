import 'match_text_normalizer.dart';
import 'online_track_result.dart';

/// Filtre de confiance appliqué avant d'accepter un résultat iTunes comme
/// correspondance d'un morceau local — sans ça, `enrichFromOnlineMetadata`
/// appliquait aveuglément le premier résultat d'une recherche en texte libre
/// (`MetadataApiClient.search`, sans le filtre d'artiste exact utilisé par
/// `searchByArtist`/`searchAlbumsByArtist`), ce qui pochette/genre/année d'un
/// morceau homonyme ou d'un remix sans rapport sur le morceau local (ex.
/// vérifié empiriquement : "Charlotte Cardin - Feel Good" matchait "Confetti"
/// du même artiste, un morceau du même artiste mais totalement différent).
class TrackMatchConfidence {
  const TrackMatchConfidence._();

  /// Choisit, parmi [candidates] (déjà triés par pertinence iTunes), le
  /// premier assez fiable pour être appliqué — ou `null` si aucun ne l'est.
  /// À privilégier sur [isReliableMatch] dès que plusieurs candidats sont
  /// disponibles : avec un artiste local inconnu, un titre exact peut être
  /// partagé par plusieurs artistes différents (reprise, cover "lullaby"...),
  /// signe qu'aucun des deux n'est fiable sans confirmation croisée — un
  /// candidat examiné isolément ne peut pas le détecter (vérifié
  /// empiriquement : "Money Trees" sans artiste matchait en premier une
  /// reprise pour enfants plutôt que l'original).
  static OnlineTrackResult? pickBestMatch({
    required String localTitle,
    required List<String> localArtists,
    required List<OnlineTrackResult> candidates,
  }) {
    final String? knownArtist = _knownArtist(localArtists);
    if (knownArtist != null) {
      for (final candidate in candidates) {
        if (isReliableMatch(localTitle: localTitle, localArtists: localArtists, candidate: candidate)) {
          return candidate;
        }
      }
      return null;
    }

    final String normLocalTitle = _normalize(localTitle);
    if (normLocalTitle.isEmpty) return null;

    final List<OnlineTrackResult> exactTitleMatches =
        candidates.where((c) => _normalize(c.title) == normLocalTitle).toList();
    if (exactTitleMatches.isEmpty) return null;

    final Set<String> distinctArtists = exactTitleMatches.map((c) => _normalize(c.artist)).toSet();
    if (distinctArtists.length > 1) return null; // titre trop générique/repris pour trancher sans artiste connu

    return exactTitleMatches.first;
  }

  static bool isReliableMatch({
    required String localTitle,
    required List<String> localArtists,
    required OnlineTrackResult candidate,
  }) {
    final String normLocalTitle = _normalize(localTitle);
    final String normCandidateTitle = _normalize(candidate.title);
    if (normLocalTitle.isEmpty || normCandidateTitle.isEmpty) return false;

    final bool titleMatches = normLocalTitle == normCandidateTitle ||
        normLocalTitle.contains(normCandidateTitle) ||
        normCandidateTitle.contains(normLocalTitle);
    if (!titleMatches) return false;

    final String? knownArtist = _knownArtist(localArtists);
    if (knownArtist == null) {
      // Pas d'artiste local fiable pour croiser le résultat : n'accepter
      // qu'un titre strictement identique (une simple inclusion, ex. "4 Raws"
      // vs "4 Raws (slowed)", est trop faible pour appliquer pochette/album
      // d'un morceau qu'on ne peut pas confirmer autrement). Voir
      // [pickBestMatch] pour une vérification plus stricte encore quand
      // plusieurs candidats sont disponibles.
      return normLocalTitle == normCandidateTitle;
    }

    final String normKnownArtist = _normalize(knownArtist);
    final String normCandidateArtist = _normalize(candidate.artist);
    return normKnownArtist == normCandidateArtist ||
        normKnownArtist.contains(normCandidateArtist) ||
        normCandidateArtist.contains(normKnownArtist);
  }

  static String? _knownArtist(List<String> localArtists) {
    return localArtists.isNotEmpty && localArtists.first.toLowerCase() != 'unknown' ? localArtists.first : null;
  }

  static String _normalize(String input) => MatchTextNormalizer.normalize(input);
}
