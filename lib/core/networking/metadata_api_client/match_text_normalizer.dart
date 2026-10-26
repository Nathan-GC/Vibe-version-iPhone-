import '../../identity/track_match_key.dart' show foldDiacritics;

/// Normalisation de texte partagée entre [TrackMatchConfidence] et
/// [OnlineResultRanker] pour comparer artiste/titre de façon tolérante à la
/// ponctuation, aux accents ET aux mots de liaison entre artistes multiples
/// ("vs", "x", "ft", "feat", "featuring") — sans ça, "David Guetta vs Benny
/// Benassi" ne matchait pas "David Guetta & Benny Benassi", et "... ft. Wyclef
/// Jean" ne matchait pas "... (feat. Wyclef Jean)" (vérifié empiriquement :
/// même morceau, résultat correct présent dans les candidats, mais rejeté par
/// la comparaison à cause de ce seul mot).
///
/// Les lettres de TOUT alphabet sont conservées (même classe de caractères que
/// `track_match_key.dart`) : limitée à `[a-z0-9]`, la normalisation vidait les
/// titres cyrilliques/asiatiques, qui devenaient tous "égaux". Résultat
/// inchangé pour le texte ASCII.
class MatchTextNormalizer {
  const MatchTextNormalizer._();

  // Uniquement des mots qui ne servent jamais de contenu distinctif d'un
  // titre/artiste réel — contrairement à "and"/"with", omis volontairement
  // (ex. "You and I", "Stuck With U" perdraient un mot qui fait partie du
  // titre lui-même). Bornes par lookaround Unicode plutôt que `\b`, qui ne
  // connaît que les lettres ASCII.
  static final RegExp _connectorWords = RegExp(
    r'(?<![\p{L}\p{M}\p{N}])(vs|x|ft|feat|featuring)(?![\p{L}\p{M}\p{N}])',
    unicode: true,
  );
  static final RegExp _nonAlphanumeric = RegExp(r'[^\p{L}\p{M}\p{N}]+', unicode: true);

  static String normalize(String input) {
    final String withoutPunctuation = foldDiacritics(input).replaceAll(_nonAlphanumeric, ' ');
    final String withoutConnectors = withoutPunctuation.replaceAll(_connectorWords, ' ');
    return withoutConnectors.replaceAll(RegExp(r'\s+'), ' ').trim();
  }
}
