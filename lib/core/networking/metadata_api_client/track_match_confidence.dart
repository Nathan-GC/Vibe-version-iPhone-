import '../../identity/track_match_key.dart' show foldDiacritics, normalizeTrackTitle;
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
///
/// Un candidat est accepté quand, dans l'ordre :
/// 1. les mots-clés de version (remix, instrumental, live, cover, acoustic)
///    sont les MÊMES dans les deux titres complets ;
/// 2. si les deux durées sont connues, elles diffèrent d'au plus
///    [maxDurationGapMs] (sauf [skipDurationCheck]) ;
/// 3. artiste local connu : la moyenne du score de titre (mots communs des
///    titres "cœur") et du score d'artiste atteint [acceptanceThreshold] ;
///    artiste local inconnu : titre identique + garde-fou d'ambiguïté.
class TrackMatchConfidence {
  const TrackMatchConfidence._();

  /// Seuil du score composite (moyenne titre/artiste) d'un candidat.
  static const double acceptanceThreshold = 0.8;

  /// Écart de durée maximal toléré entre le fichier local et le candidat.
  static const int maxDurationGapMs = 15000;

  // Une version "remix"/"live"... n'est jamais le morceau standard : une simple
  // différence de mot-clé entre les deux titres suffit à rejeter, dans les deux
  // sens. Bornes par lookaround Unicode (`\b` ne connaît que l'ASCII).
  static final RegExp _versionKeywords = RegExp(
    r'(?<![\p{L}\p{M}\p{N}])(instrumentale?|remix|live|cover|acoustic|acoustique)(?![\p{L}\p{M}\p{N}])',
    unicode: true,
  );

  /// Choisit, parmi [candidates] (déjà triés par pertinence iTunes), le
  /// premier assez fiable pour être appliqué — ou `null` si aucun ne l'est.
  /// À privilégier sur [isReliableMatch] dès que plusieurs candidats sont
  /// disponibles : avec un artiste local inconnu, un titre exact peut être
  /// partagé par plusieurs artistes différents (reprise, cover "lullaby"...),
  /// signe qu'aucun des deux n'est fiable sans confirmation croisée — un
  /// candidat examiné isolément ne peut pas le détecter (vérifié
  /// empiriquement : "Money Trees" sans artiste matchait en premier une
  /// reprise pour enfants plutôt que l'original).
  ///
  /// [localDurationMs] (durée du fichier, si connue) écarte un candidat dont la
  /// durée diffère de plus de [maxDurationGapMs] ; [skipDurationCheck]
  /// désactive ce contrôle (fichier issu d'un clip vidéo, dont la durée n'est
  /// pas celle du morceau studio).
  static OnlineTrackResult? pickBestMatch({
    required String localTitle,
    required List<String> localArtists,
    required List<OnlineTrackResult> candidates,
    int? localDurationMs,
    bool skipDurationCheck = false,
  }) {
    final String? knownArtist = _knownArtist(localArtists);
    if (knownArtist != null) {
      for (final candidate in candidates) {
        if (isReliableMatch(
          localTitle: localTitle,
          localArtists: localArtists,
          candidate: candidate,
          localDurationMs: localDurationMs,
          skipDurationCheck: skipDurationCheck,
        )) {
          return candidate;
        }
      }
      return null;
    }

    final String normLocalTitle = _normalize(localTitle);
    if (normLocalTitle.isEmpty) return null;

    final List<OnlineTrackResult> exactTitleMatches = candidates
        .where((c) =>
            _normalize(c.title) == normLocalTitle &&
            _passesGuards(localTitle, c, localDurationMs: localDurationMs, skipDurationCheck: skipDurationCheck))
        .toList();
    if (exactTitleMatches.isEmpty) return null;

    final Set<String> distinctArtists = exactTitleMatches.map((c) => _normalize(c.artist)).toSet();
    if (distinctArtists.length > 1) return null; // titre trop générique/repris pour trancher sans artiste connu

    return exactTitleMatches.first;
  }

  static bool isReliableMatch({
    required String localTitle,
    required List<String> localArtists,
    required OnlineTrackResult candidate,
    int? localDurationMs,
    bool skipDurationCheck = false,
  }) {
    final String normLocalTitle = _normalize(localTitle);
    final String normCandidateTitle = _normalize(candidate.title);
    if (normLocalTitle.isEmpty || normCandidateTitle.isEmpty) return false;

    if (!_passesGuards(localTitle, candidate, localDurationMs: localDurationMs, skipDurationCheck: skipDurationCheck)) {
      return false;
    }

    final String? knownArtist = _knownArtist(localArtists);
    if (knownArtist == null) {
      // Pas d'artiste local fiable pour croiser le résultat : n'accepter
      // qu'un titre strictement identique, segments entre parenthèses compris
      // (ex. "4 Raws" vs "4 Raws (slowed)" : les deux titres "cœur" sont égaux,
      // mais c'est trop faible pour appliquer pochette/album d'un morceau
      // qu'on ne peut pas confirmer autrement). Voir [pickBestMatch] pour une
      // vérification plus stricte encore quand plusieurs candidats sont
      // disponibles.
      return normLocalTitle == normCandidateTitle;
    }

    final double score = (_titleScore(localTitle, candidate.title) + _artistScore(knownArtist, candidate.artist)) / 2;
    // Epsilon : 0,6 + 1,0 doit bien valoir 0,8 malgré l'arrondi flottant.
    return score >= acceptanceThreshold - 1e-9;
  }

  /// Gardes communs à tous les candidats, artiste connu ou non : parité des
  /// mots-clés de version, puis écart de durée.
  static bool _passesGuards(
    String localTitle,
    OnlineTrackResult candidate, {
    required int? localDurationMs,
    required bool skipDurationCheck,
  }) {
    if (!_sameKeywords(localTitle, candidate.title)) return false;

    final int? candidateDurationMs = candidate.durationMs;
    if (!skipDurationCheck &&
        localDurationMs != null &&
        localDurationMs > 0 &&
        candidateDurationMs != null &&
        (localDurationMs - candidateDurationMs).abs() > maxDurationGapMs) {
      return false;
    }
    return true;
  }

  /// Mots-clés de version présents dans les titres COMPLETS (accents repliés,
  /// avant retrait des parenthèses : "Roi (Instrumental)" et "Roi INSTRUMENTAL"
  /// donnent le même ensemble). Les variantes françaises sont ramenées à la
  /// forme anglaise.
  static bool _sameKeywords(String a, String b) {
    final Set<String> keywordsA = _keywords(a);
    final Set<String> keywordsB = _keywords(b);
    return keywordsA.length == keywordsB.length && keywordsA.containsAll(keywordsB);
  }

  static Set<String> _keywords(String title) => _versionKeywords
      .allMatches(foldDiacritics(title))
      .map((m) => m[1] == 'instrumentale'
          ? 'instrumental'
          : m[1] == 'acoustique'
              ? 'acoustic'
              : m[1]!)
      .toSet();

  /// Proportion de mots communs entre les titres "cœur" (sans parenthèses, ni
  /// crochets, ni "feat." final) : coefficient de Dice `2·|A∩B| / (|A|+|B|)`.
  /// "Godzilla" et "Godzilla (feat. Juice WRLD)" valent donc 1.
  static double _titleScore(String localTitle, String candidateTitle) {
    final Set<String> a = _coreWords(localTitle);
    final Set<String> b = _coreWords(candidateTitle);
    if (a.isEmpty || b.isEmpty) return 0;
    return 2 * a.intersection(b).length / (a.length + b.length);
  }

  /// Part des mots de l'artiste LOCAL principal retrouvés chez l'artiste du
  /// candidat — pas l'inverse : iTunes liste souvent les invités dans l'artiste
  /// ("Kavinsky, Angèle & Phoenix" pour un fichier "Kavinsky"), ce qui ne doit
  /// pas pénaliser.
  static double _artistScore(String localArtist, String candidateArtist) {
    final Set<String> local = _words(_normalize(localArtist));
    if (local.isEmpty) return 0;
    final Set<String> candidate = _words(_normalize(candidateArtist));
    return local.intersection(candidate).length / local.length;
  }

  // Titre "cœur" ; repli sur le titre complet quand tout est entre parenthèses
  // (ex. "(What's The Story) Morning Glory?" garde son sens, pas un ensemble vide).
  static Set<String> _coreWords(String title) {
    final String core = normalizeTrackTitle(title);
    return _words(core.isNotEmpty ? core : _normalize(title));
  }

  static Set<String> _words(String normalized) => normalized.isEmpty ? <String>{} : normalized.split(' ').toSet();

  static String? _knownArtist(List<String> localArtists) {
    return localArtists.isNotEmpty && localArtists.first.toLowerCase() != 'unknown' ? localArtists.first : null;
  }

  static String _normalize(String input) => MatchTextNormalizer.normalize(input);
}
