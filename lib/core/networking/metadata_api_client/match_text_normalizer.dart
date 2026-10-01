/// Normalisation de texte partagée entre [TrackMatchConfidence] et
/// [OnlineResultRanker] pour comparer artiste/titre de façon tolérante à la
/// ponctuation ET aux mots de liaison entre artistes multiples ("vs", "x",
/// "ft", "feat", "featuring") — sans ça, "David Guetta vs Benny Benassi" ne
/// matchait pas "David Guetta & Benny Benassi", et "... ft. Wyclef Jean" ne
/// matchait pas "... (feat. Wyclef Jean)" (vérifié empiriquement : même
/// morceau, résultat correct présent dans les candidats, mais rejeté par la
/// comparaison à cause de ce seul mot).
class MatchTextNormalizer {
  const MatchTextNormalizer._();

  // Uniquement des mots qui ne servent jamais de contenu distinctif d'un
  // titre/artiste réel — contrairement à "and"/"with", omis volontairement
  // (ex. "You and I", "Stuck With U" perdraient un mot qui fait partie du
  // titre lui-même).
  static final RegExp _connectorWords = RegExp(r'\b(vs|x|ft|feat|featuring)\b');

  static String normalize(String input) {
    final String withoutPunctuation = input.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ');
    final String withoutConnectors = withoutPunctuation.replaceAll(_connectorWords, ' ');
    return withoutConnectors.replaceAll(RegExp(r'\s+'), ' ').trim();
  }
}
