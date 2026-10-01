import 'match_text_normalizer.dart';
import 'online_track_result.dart';

/// Reclasse une liste de résultats iTunes déjà reçue (tri "côté app", pas de
/// paramètre supplémentaire côté API) pour remonter en tête ceux dont
/// `artistName` correspond à l'artiste recherché ET dont `trackName` contient
/// le titre recherché — la recherche `term` combinée envoyée à iTunes reste
/// un texte libre : sa pertinence interne ne priorise pas forcément ces deux
/// critères à la fois.
class OnlineResultRanker {
  const OnlineResultRanker._();

  static List<OnlineTrackResult> rankByRelevance(
    List<OnlineTrackResult> results, {
    required String artist,
    required String title,
  }) {
    final String normArtist = _normalize(artist);
    final String normTitle = _normalize(title);
    if (normArtist.isEmpty && normTitle.isEmpty) return results;

    // Tri stable par score décroissant : `List.sort` n'est pas garanti
    // stable en Dart, donc l'index d'origine sert de départage explicite
    // pour préserver l'ordre de pertinence déjà renvoyé par iTunes au sein
    // d'un même score.
    final List<(int, OnlineTrackResult)> indexed = results.indexed.toList();
    indexed.sort((a, b) {
      final int scoreDiff = _score(b.$2, normArtist, normTitle).compareTo(_score(a.$2, normArtist, normTitle));
      return scoreDiff != 0 ? scoreDiff : a.$1.compareTo(b.$1);
    });
    return indexed.map((e) => e.$2).toList();
  }

  static int _score(OnlineTrackResult result, String normArtist, String normTitle) {
    final bool artistMatches = normArtist.isEmpty || _matches(_normalize(result.artist), normArtist);
    final bool titleMatches = normTitle.isEmpty || _normalize(result.title).contains(normTitle);
    if (artistMatches && titleMatches) return 2;
    if (artistMatches || titleMatches) return 1;
    return 0;
  }

  static bool _matches(String normResultArtist, String normArtist) =>
      normResultArtist == normArtist || normResultArtist.contains(normArtist) || normArtist.contains(normResultArtist);

  static String _normalize(String input) => MatchTextNormalizer.normalize(input);
}
