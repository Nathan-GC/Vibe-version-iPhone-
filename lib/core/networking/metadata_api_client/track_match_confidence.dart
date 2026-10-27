import 'package:flutter/foundation.dart' show visibleForTesting;

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
/// 2. si les deux durées sont connues (sauf [skipDurationCheck]), elles
///    diffèrent d'au plus : artiste local connu, [undecoratedMaxDurationGapMs]
///    pour un candidat NON décoré (même titre que le local, hors clause
///    "feat.") et [maxDurationGapMs] pour un candidat décoré ("Poker Face
///    (Glam As You Radio Mix)", "Starman (Demo 2)" : un autre enregistrement,
///    dont la durée doit coller de près) ; artiste local inconnu,
///    [unknownArtistMaxDurationGapMs] ;
/// 3. artiste local connu : la moyenne du score de titre (mots communs des
///    titres "cœur") et du score d'artiste atteint [acceptanceThreshold] ;
///    artiste local inconnu : titre identique (clauses "feat." mises à part,
///    "tv off (feat. Lefty Gunplay)" égale "tv off") + garde-fou d'ambiguïté.
///
/// Plusieurs candidats fiables : [pickBestMatch] les CLASSE (non décoré d'abord,
/// puis proximité de durée) au lieu de prendre le premier.
class TrackMatchConfidence {
  const TrackMatchConfidence._();

  /// Seuil du score composite (moyenne titre/artiste) d'un candidat.
  static const double acceptanceThreshold = 0.8;

  /// Écart de durée maximal toléré entre le fichier local et le candidat.
  static const int maxDurationGapMs = 15000;

  /// Écart de durée toléré pour un candidat NON décoré (artiste local connu) :
  /// c'est bien le même titre, seule la version (réédition, remaster, coupe
  /// radio) peut varier — ex. « The Look » 241 s en local contre 277 s chez iTunes.
  static const int undecoratedMaxDurationGapMs = 40000;

  /// Écart de durée toléré quand l'artiste local est INCONNU : seul le titre
  /// (souvent générique) croise le résultat, donc la durée doit quasiment
  /// coller — « Vin italien » 196 s refuse un homonyme à 188 s.
  static const int unknownArtistMaxDurationGapMs = 1500;

  // Une version "remix"/"live"... n'est jamais le morceau standard : une simple
  // différence de mot-clé entre les deux titres suffit à rejeter, dans les deux
  // sens. Bornes par lookaround Unicode (`\b` ne connaît que l'ASCII).
  static final RegExp _versionKeywords = RegExp(
    r'(?<![\p{L}\p{M}\p{N}])(instrumentale?|remix|live|cover|acoustic|acoustique)(?![\p{L}\p{M}\p{N}])',
    unicode: true,
  );

  /// Choisit, parmi [candidates] (déjà triés par pertinence iTunes), le
  /// meilleur assez fiable pour être appliqué — ou `null` si aucun ne l'est.
  /// À privilégier sur [isReliableMatch] dès que plusieurs candidats sont
  /// disponibles : avec un artiste local inconnu, un titre exact peut être
  /// partagé par plusieurs artistes différents (reprise, cover "lullaby"...),
  /// signe qu'aucun des deux n'est fiable sans confirmation croisée — un
  /// candidat examiné isolément ne peut pas le détecter (vérifié
  /// empiriquement : "Money Trees" sans artiste matchait en premier une
  /// reprise pour enfants plutôt que l'original).
  ///
  /// Artiste local connu : tous les candidats fiables sont collectés puis
  /// CLASSÉS par clé lexicographique — (1) non décoré avant décoré (« Poker
  /// Face » avant « Poker Face (Glam As You Radio Mix) » même si iTunes liste
  /// le remix en premier), (2) invité étranger après les autres — seulement
  /// quand l'identité locale nomme elle-même des invités (voir
  /// [_creditsForeignGuest]) : « Timbaland - The Way I Are ft. Keri Hilson,
  /// D.O.E., Sebastian » doit préférer « Shock Value » au single France crédité
  /// « Timbaland featuring Tyssem », (3) durée : avec [skipDurationCheck] le
  /// plus proche de [localDurationMs] d'abord (clip vidéo : on départage au
  /// mieux entre « Nightcall (Kavinsky) » 258 s et la version 179 s), sinon dans
  /// la fenêtre de [maxDurationGapMs] avant hors fenêtre (≤ 40 s, non décoré),
  /// (4) album compilation après les autres (voir [_isCompilationAlbum]),
  /// (5) ordre iTunes. Ne PAS trier sur la durée seule : essayé et rejeté,
  /// cela fait remonter des compilations. Tous ces critères ne servent qu'au
  /// RANG : aucun ne rejette un candidat.
  ///
  /// Si le seul candidat fiable est décoré alors qu'un candidat NON décoré du
  /// même morceau (mots-clés de version et score titre+artiste valides) n'est
  /// écarté que par la durée, on renvoie `null` : mieux vaut refuser que
  /// d'appliquer la démo/le refix (« Starman (Demo 2) » 234 s contre
  /// « Starman » 300 s pour un fichier de 220 s).
  ///
  /// [localDurationMs] (durée du fichier, si connue) écarte un candidat dont la
  /// durée diffère trop (voir [maxDurationGapMs], [undecoratedMaxDurationGapMs],
  /// [unknownArtistMaxDurationGapMs]) ; [skipDurationCheck] désactive ce
  /// contrôle (fichier issu d'un clip vidéo, dont la durée n'est pas celle du
  /// morceau studio).
  static OnlineTrackResult? pickBestMatch({
    required String localTitle,
    required List<String> localArtists,
    required List<OnlineTrackResult> candidates,
    int? localDurationMs,
    bool skipDurationCheck = false,
  }) {
    final String? knownArtist = _knownArtist(localArtists);
    if (knownArtist != null) {
      // Index d'origine conservés : dernier critère de départage (ordre iTunes).
      final List<int> reliable = <int>[
        for (int n = 0; n < candidates.length; n++)
          if (isReliableMatch(
            localTitle: localTitle,
            localArtists: localArtists,
            candidate: candidates[n],
            localDurationMs: localDurationMs,
            skipDurationCheck: skipDurationCheck,
          ))
            n,
      ];
      if (reliable.isEmpty) return null;

      final bool onlyDecorated = reliable.every((n) => isDecorated(localTitle, candidates[n].title));
      if (onlyDecorated && _hasUndecoratedRejectedByDurationOnly(localTitle, knownArtist, candidates)) return null;

      int durationRank(OnlineTrackResult c) {
        final int gap = _durationGapMs(c, localDurationMs);
        return skipDurationCheck ? gap : (gap <= maxDurationGapMs ? 0 : 1);
      }

      // Clé finale : (décoré, invité étranger, rang de durée, album compilation, ordre iTunes).
      // L'invité étranger n'est évalué que si l'identité locale nomme elle-même des invités.
      final bool localHasGuests = _localNamesGuests(localTitle, localArtists);
      final String localContext = localHasGuests ? _localContextCompact(localTitle, localArtists) : '';
      List<int> rankKey(int n) {
        final OnlineTrackResult c = candidates[n];
        return <int>[
          isDecorated(localTitle, c.title) ? 1 : 0,
          localHasGuests && _creditsForeignGuest(c, localContext) ? 1 : 0,
          durationRank(c),
          _isCompilationAlbum(c.album) ? 1 : 0,
        ];
      }

      int compareKeys(List<int> a, List<int> b) {
        for (int i = 0; i < a.length; i++) {
          final int cmp = a[i].compareTo(b[i]);
          if (cmp != 0) return cmp;
        }
        return 0;
      }

      int best = reliable.first;
      List<int> bestKey = rankKey(best);
      for (final int n in reliable.skip(1)) {
        final List<int> key = rankKey(n);
        // `n` croît dans la boucle : à égalité sur toute la clé, le premier (ordre iTunes) gagne.
        if (compareKeys(key, bestKey) < 0) {
          best = n;
          bestKey = key;
        }
      }
      return candidates[best];
    }

    final String normLocalTitle = _normalize(localTitle);
    if (normLocalTitle.isEmpty) return null;

    final List<OnlineTrackResult> exactTitleMatches = candidates
        .where((c) =>
            _sameTitleIgnoringFeat(localTitle, c.title) &&
            _passesGuards(localTitle, c,
                localDurationMs: localDurationMs,
                skipDurationCheck: skipDurationCheck,
                maxGapMs: unknownArtistMaxDurationGapMs))
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

    final String? knownArtist = _knownArtist(localArtists);
    if (!_passesGuards(
      localTitle,
      candidate,
      localDurationMs: localDurationMs,
      skipDurationCheck: skipDurationCheck,
      // Artiste connu : tolérance large pour le même titre, serrée pour une
      // version décorée ; artiste inconnu : quasi exacte.
      maxGapMs: knownArtist == null
          ? unknownArtistMaxDurationGapMs
          : (isDecorated(localTitle, candidate.title) ? maxDurationGapMs : undecoratedMaxDurationGapMs),
    )) {
      return false;
    }

    if (knownArtist == null) {
      // Pas d'artiste local fiable pour croiser le résultat : n'accepter
      // qu'un titre strictement identique, segments entre parenthèses compris
      // (ex. "4 Raws" vs "4 Raws (slowed)" : les deux titres "cœur" sont égaux,
      // mais c'est trop faible pour appliquer pochette/album d'un morceau
      // qu'on ne peut pas confirmer autrement). Seules les clauses "feat."
      // sont ignorées : "tv off (feat. Lefty Gunplay)" est bien "tv off".
      // Voir [pickBestMatch] pour une vérification plus stricte encore quand
      // plusieurs candidats sont disponibles.
      return _sameTitleIgnoringFeat(localTitle, candidate.title);
    }

    final double score = (_titleScore(localTitle, candidate.title) + _artistScore(knownArtist, candidate.artist)) / 2;
    // Epsilon : 0,6 + 1,0 doit bien valoir 0,8 malgré l'arrondi flottant.
    return score >= acceptanceThreshold - 1e-9;
  }

  /// Gardes communs à tous les candidats, artiste connu ou non : parité des
  /// mots-clés de version, puis écart de durée d'au plus [maxGapMs].
  static bool _passesGuards(
    String localTitle,
    OnlineTrackResult candidate, {
    required int? localDurationMs,
    required bool skipDurationCheck,
    required int maxGapMs,
  }) {
    if (!_sameKeywords(localTitle, candidate.title)) return false;
    return skipDurationCheck || _durationGapMs(candidate, localDurationMs) <= maxGapMs;
  }

  /// Écart de durée local/candidat ; 0 quand l'une des deux durées est inconnue
  /// (aucun contrôle possible, donc aucun écart reproché).
  static int _durationGapMs(OnlineTrackResult candidate, int? localDurationMs) {
    final int? candidateDurationMs = candidate.durationMs;
    if (localDurationMs == null || localDurationMs <= 0 || candidateDurationMs == null) return 0;
    return (localDurationMs - candidateDurationMs).abs();
  }

  // Clause "feat."/"with" entre parenthèses ou crochets, puis clause finale
  // non parenthésée ("Titre feat. X & Y") : un invité ne change pas le morceau.
  static final RegExp _bracketedFeatClause = RegExp(
    r'\s*[\(\[]\s*(feat|ft|featuring|with)\b[^\)\]]*[\)\]]',
    caseSensitive: false,
  );
  static final RegExp _trailingFeatClause = RegExp(r'\s+(feat|ft|featuring)\b\.?.*$', caseSensitive: false);

  static String _withoutFeatClauses(String title) =>
      title.replaceAll(_bracketedFeatClause, '').replaceAll(_trailingFeatClause, '');

  static bool _sameTitleIgnoringFeat(String a, String b) {
    final String normA = _normalize(_withoutFeatClauses(a));
    return normA.isNotEmpty && normA == _normalize(_withoutFeatClauses(b));
  }

  /// Un candidat est « décoré » quand son titre, une fois les clauses "feat."
  /// retirées, diffère de celui du fichier local : version, démo, remix radio...
  /// — « Poker Face (Glam As You Radio Mix) » l'est pour « Poker Face », mais
  /// « The Way I Are (feat. Keri Hilson & D.O.E.) » ne l'est pas pour
  /// « The Way I Are ». Un candidat décoré est un AUTRE enregistrement du
  /// morceau : classé après, et avec une tolérance de durée plus serrée.
  ///
  /// Les mentions d'édition NEUTRES ([_neutralWords]) sont retirées des deux
  /// côtés avant comparaison : « Starman (2012 Remaster) » est l'album studio de
  /// « Starman », pas un autre enregistrement — le juger décoré le limitait à
  /// 15 s et laissait une compilation non décorée passer devant.
  @visibleForTesting
  static bool isDecorated(String localTitle, String candidateTitle) =>
      _normalize(_withoutFeatClauses(_withoutNeutralEditions(localTitle))) !=
      _normalize(_withoutFeatClauses(_withoutNeutralEditions(candidateTitle)));

  // Mention d'édition neutre : remaster(ed) / mono / stereo / single version /
  // original single mix, année optionnelle avant ou après, entre parenthèses ou
  // crochets, ou après " - " en fin de titre. Rien d'autre (live, demo, radio
  // edit, deluxe... restent des décorations).
  static const String _neutralWords =
      r'(?:\d{4}\s+)?(?:remaster(?:ed)?|mono|stereo|single\s+version|original\s+single\s+mix)(?:\s+\d{4})?';
  static final RegExp _bracketedNeutralEdition =
      RegExp(r'\s*[\(\[]\s*' + _neutralWords + r'\s*[\)\]]', caseSensitive: false);
  static final RegExp _dashedNeutralEdition = RegExp(r'\s+-\s+' + _neutralWords + r'\s*$', caseSensitive: false);

  static String _withoutNeutralEditions(String title) =>
      title.replaceAll(_bracketedNeutralEdition, '').replaceAll(_dashedNeutralEdition, '');

  // Album « compilation » : mots entiers, insensible à la casse. « ChangesTwoBowie »
  // n'en est volontairement pas une (hors liste) : l'ordre iTunes tranche alors.
  // Les bandes originales n'en font volontairement PAS partie : c'est souvent
  // l'album d'origine (« Lose Yourself » sur « 8 Mile »), mesuré sur le corpus
  // réel. Contrepartie connue : écarter « Greatest Hits » peut laisser passer la
  // BO d'un film tiers (« California Dreamin' »), une compilation pour une autre.
  static final RegExp _compilationAlbum = RegExp(
    r'(?<![\p{L}\p{M}\p{N}])(greatest|best\s+of|hits|remixes)(?![\p{L}\p{M}\p{N}])',
    caseSensitive: false,
    unicode: true,
  );

  static bool _isCompilationAlbum(String? album) => album != null && _compilationAlbum.hasMatch(album);

  // ---- Invité étranger (AN-18) --------------------------------------------

  // Contenu (groupe 2) d'une clause feat./ft./featuring/with entre parenthèses ou
  // crochets, ou d'une clause finale non parenthésée feat./ft./featuring — « with »
  // n'est jamais lu en fin de titre libre (« Stuck With U »).
  static final RegExp _bracketedFeatContent = RegExp(
    r'[\(\[]\s*(feat|ft|featuring|with)\b\.?([^\)\]]*)[\)\]]',
    caseSensitive: false,
  );
  static final RegExp _trailingFeatContent = RegExp(r'\s+(feat|ft|featuring)\b\.?(.*)$', caseSensitive: false);
  // Séparateurs de noms dans une clause ou un champ artiste.
  static final RegExp _creditSeparator = RegExp(
    r'\s*(?:,|&|\s+x\s+|\s+(?:feat|ft|featuring|with)\b\.?)\s*',
    caseSensitive: false,
  );

  static List<String> _splitCreditedNames(String text) =>
      text.split(_creditSeparator).map((n) => n.trim()).where((n) => n.isNotEmpty).toList();

  /// Noms crédités d'un candidat : invités des clauses feat./ft./featuring/with de
  /// son titre + co-artistes de son champ artiste (tout ce qui suit le premier).
  static List<String> _creditedNames(OnlineTrackResult candidate) {
    return <String>[
      for (final RegExpMatch m in _bracketedFeatContent.allMatches(candidate.title)) ..._splitCreditedNames(m[2]!),
      for (final RegExpMatch m in _trailingFeatContent.allMatches(candidate.title)) ..._splitCreditedNames(m[2]!),
      ..._splitCreditedNames(candidate.artist).skip(1),
    ];
  }

  /// Vrai quand l'identité locale nomme elle-même des invités (plusieurs artistes
  /// locaux, ou clause feat. dans le titre local) — sans ça le critère est
  /// inactif : « Nightcall » de « Kavinsky » doit pouvoir choisir « Kavinsky,
  /// Angèle & Phoenix ».
  static bool _localNamesGuests(String localTitle, List<String> localArtists) =>
      localArtists.length > 1 ||
      _bracketedFeatContent.hasMatch(localTitle) ||
      _trailingFeatContent.hasMatch(localTitle);

  /// Contexte local normalisé SANS espaces : titre local + TOUS les artistes
  /// locaux. Comparaison sans espaces car les noms de fichiers collent souvent
  /// les invités (« ColbyO'Donis » pour « Colby O'Donis ») : par mots, l'invité
  /// légitime passait pour étranger et « Just Dance » cédait la place à un EP de
  /// remixes.
  static String _localContextCompact(String localTitle, List<String> localArtists) =>
      _normalize(<String>[localTitle, ...localArtists].join(' ')).replaceAll(' ', '');

  /// Un candidat crédite un invité étranger quand un nom crédité (normalisé, sans
  /// espaces) n'apparaît pas dans [localContext] (« Tyssem » pour un fichier dont
  /// les invités sont Keri Hilson, D.O.E., Sebastian). Critère de RANG, jamais un
  /// rejet.
  static bool _creditsForeignGuest(OnlineTrackResult candidate, String localContext) {
    for (final String name in _creditedNames(candidate)) {
      final String compact = _normalize(name).replaceAll(' ', '');
      if (compact.isNotEmpty && !localContext.contains(compact)) return true;
    }
    return false;
  }

  /// Vrai quand un candidat NON décoré est le bon morceau (mots-clés de version
  /// identiques, score titre+artiste ≥ seuil) et n'est écarté que par la durée.
  static bool _hasUndecoratedRejectedByDurationOnly(
    String localTitle,
    String knownArtist,
    List<OnlineTrackResult> candidates,
  ) {
    return candidates.any((c) =>
        !isDecorated(localTitle, c.title) &&
        _normalize(c.title).isNotEmpty &&
        _sameKeywords(localTitle, c.title) &&
        (_titleScore(localTitle, c.title) + _artistScore(knownArtist, c.artist)) / 2 >= acceptanceThreshold - 1e-9);
  }

  /// Parité des mots-clés de version entre deux titres complets — exposée pour
  /// les chemins en ordre inversé (Titre/Artiste), où le texte local qui joue
  /// le rôle d'artiste dans l'appel inversé n'est pas contrôlé par
  /// [pickBestMatch] (« Ian Asher (Remix) » ne doit pas devenir « Desire »).
  static bool sameVersionKeywords(String a, String b) => _sameKeywords(a, b);

  // Clause "feat."/"ft."/"featuring" (parenthésée ou non, collée ou non) et
  // tout ce qui suit : le lookbehind refuse de couper au milieu d'un mot
  // (« Daft », « Left »), mais accepte « Gaga(Feat. » où seule la parenthèse précède.
  static final RegExp _swapFeatClause = RegExp(
    r'\s*[\(\[]?\s*(?<![A-Za-z])(?:feat|ft|featuring)\b\.?.*$',
    caseSensitive: false,
  );
  // Tout caractère qui n'a rien à faire dans un nom d'artiste (emoji, guillemets,
  // parenthèses, apostrophes de bruit...).
  static final RegExp _nonArtistChars = RegExp(r'[^\p{L}\p{N}_\s.\-&$,]', unicode: true);

  /// Texte du TITRE local utilisé comme ARTISTE dans l'appel en ordre inversé
  /// (Titre/Artiste échangés) : sans nettoyage, « Lady Gaga(Feat.Colby O'Donis) »
  /// donnerait un score d'artiste très bas face à « Lady Gaga ». Retire la clause
  /// "feat./ft./featuring" et la suite (si le résultat est vide, le titre d'origine
  /// est conservé), puis tout caractère hors lettres/chiffres/`_`/espaces/`.-&$,`.
  ///
  /// Partagé par `TrackAutoEnricher.decide` ET par la revérification de
  /// `TrackRepository.correctReversedTitleArtist` : les deux doivent juger le
  /// MÊME texte, sinon la base rejetterait une inversion que la décision a validée.
  static String artistTextForSwap(String title) {
    final String withoutFeat = title.replaceFirst(_swapFeatClause, '').trim();
    final String base = withoutFeat.isEmpty ? title : withoutFeat;
    return base.replaceAll(_nonArtistChars, '').trim();
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
  // Mention d'édition neutre retirée d'abord : la forme " - Remastered 2009"
  // n'est pas entre parenthèses, elle aurait sinon fait chuter le score de titre
  // d'un candidat que [isDecorated] juge pourtant non décoré.
  static Set<String> _coreWords(String title) {
    final String core = normalizeTrackTitle(_withoutNeutralEditions(title));
    return _words(core.isNotEmpty ? core : _normalize(title));
  }

  static Set<String> _words(String normalized) => normalized.isEmpty ? <String>{} : normalized.split(' ').toSet();

  static String? _knownArtist(List<String> localArtists) {
    return localArtists.isNotEmpty && localArtists.first.toLowerCase() != 'unknown' ? localArtists.first : null;
  }

  static String _normalize(String input) => MatchTextNormalizer.normalize(input);
}
