import '../../shared/text/title_cleaner.dart';
import '../protected_artist_names.dart';

class SanitizedFilename {
  const SanitizedFilename({
    required this.title,
    required this.artist,
    this.featuringArtists = const [],
    required this.requiresUserReview,
  });

  final String title;
  // Artiste principal — utilisé pour les requêtes API et les classements.
  final String artist;
  // Artistes en featuring/collaboration détectés dans le segment artiste
  // (séparateurs ",", "&", "x", "vs", "feat.", "ft.") — jamais dans le titre.
  final List<String> featuringArtists;
  final bool requiresUserReview;
}

/// Nettoie les noms de fichiers bruts : numéro de piste, qualité, tags parasites,
/// puis sépare Artiste / Titre. Ex. "01_Daft_Punk_-_One_More_Time_(Official_320kbps).mp3"
/// -> Artist: "Daft Punk", Title: "One More Time".
class FilenameSanitizer {
  // Ponctuation exigée juste après les chiffres (pas un simple espace) : sans
  // ça, "21 Savage - Song.mp3" perdait son "21" (pris pour un numéro de
  // piste) et devenait artist="Savage" — bug réel découvert avec de vrais
  // fichiers dont l'artiste commence par un chiffre (21 Savage, etc.).
  // Le "." n'autorise pas de chiffre juste après (lookahead) pour ne pas
  // confondre un numéro de piste avec un nombre décimal glissé dans le nom
  // (ex. "104.5SkyFM-..." une fréquence radio) ; "_"/"-" n'ont pas cette
  // restriction car appliqué en boucle (voir plus bas), ce qui permet de
  // dépiler un préfixe disque-piste répété (ex. "01-01- Title.mp3").
  static final RegExp _trackNumberPrefix = RegExp(r'^\s*\d{1,3}(?:\.(?!\d)|[_-])\s*');
  // Bruit technique laissé par certains convertisseurs : hash (MD5/SHA-like),
  // GUID, ou fragment de requête type "yt_v=<id>" — jamais du contenu de
  // titre. Un hash hexadécimal est distingué d'un vrai numéro ("Blink 182",
  // "Waltz No. 2", "Mambo No. 5" : uniquement des chiffres) en exigeant un
  // mélange chiffres+lettres a-f sur au moins 8 caractères — un mot anglais
  // de cette forme est quasi inexistant, contrairement à un simple nombre.
  // Ne mange que la ponctuation de liaison immédiate (espace/tiret/underscore),
  // jamais un mot entier avant le hash : une première version tentait
  // d'avaler aussi un éventuel nom réattribué juste avant ("-NomChaîne-hash"),
  // mais rien ne distingue ça d'un vrai "Artist - Title-hash" — testé, ça
  // supprimait le vrai titre ("One More Time-<guid>" perdait "One More Time").
  // Quelques fichiers réels gardent donc un segment "-NomChaîne" résiduel une
  // fois le hash seul retiré (ex. "...-Eurythmics-<hash>" -> "...-Eurythmics") :
  // limite acceptée plutôt que de risquer d'effacer un vrai titre.
  static final RegExp _idNoise = RegExp(
    r'[\s_-]*(?:'
    r'\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b|' // GUID
    r'\b(?=[0-9a-f]*[a-f])(?=[0-9a-f]*[0-9])[0-9a-f]{8,64}\b|' // hash hex mixte chiffres+lettres
    r'\b(?:yt[_-]?v|v|id)=[\w-]{6,}' // fragment de requête, ex. "yt_v=dQw4w9WgXcQ"
    r')[\s_-]*',
    caseSensitive: false,
  );
  // Coquille de parenthèse/crochet vidée par un nettoyage précédent (ex. un
  // id seul entre crochets, "[yt_v=...]") : sans ce filet, "[ ]" restait
  // affiché tel quel dans le titre final.
  static final RegExp _emptyBracketPair = RegExp(r'[\(\[\{]\s*[\)\]\}]');
  // Identifiant numérique en fin de nom, typique des fichiers issus de
  // convertisseurs/téléchargeurs en ligne : soit un long timestamp epoch
  // (ex. "_1747590913639", souvent sans séparateur net), soit un compteur
  // court mais toujours précédé d'un "_" explicite (ex. "_733", "_28") — le
  // "_" requis pour les IDs courts évite de tronquer un vrai titre numérique
  // séparé par un espace (ex. "Blink 182").
  static final RegExp _trailingNumericId = RegExp(r'[\s_]*\d{6,}$|_\d{1,5}$');
  static final RegExp _separator = RegExp(r'\s*[-–—]\s*');
  // Bruit terminal non parenthésé, laissé tel quel par TitleCleaner (qui ne
  // nettoie que le contenu entre parenthèses/crochets) — très fréquent dans
  // les noms compacts des convertisseurs YouTube (ex. "...-HQ", "... Lyrics",
  // "... Official Audio"). Appliqué en boucle : certains fichiers empilent
  // plusieurs suffixes ("-Lyrics" puis, une fois retiré, plus rien d'autre).
  static final RegExp _bareTrailingNoise = RegExp(
    // "free download ..." avale tout ce qui suit (lien, "IN DESCRIPTION"...).
    r'[\s_-]+(?:(?:official\s+)?(?:lyrics?|paroles?|letra|audio|video|visuali[sz]er|hq|tiktok|slowed|sped\s*up)\s*$|'
    r'free\s*download\b.*$)',
    caseSensitive: false,
  );
  // Mots de bruit isolés au milieu d'un segment ("Till I Collapse Lyrics by
  // Eminem") : bornes alphanumériques pour ne jamais couper dans un mot
  // ("Lyricist", "Tiktoker"). Les groupes entre crochets sont captés pour être
  // laissés tels quels : "(JENNIE Remix - Official Lyric Video)" est déjà
  // traité par TitleCleaner et ne doit pas être grignoté ici. "slowed + reverb"
  // part d'un bloc : sinon "Reverb" restait seul dans le titre.
  static final RegExp _standaloneNoise = RegExp(
    r'([\(\[\{][^\(\)\[\]\{\}]*[\)\]\}])|'
    r'(?<![A-Za-z0-9])(?:lyrics?|tiktok|slowed(?:\s*\+?\s*reverb)?|sped\s*up)(?![A-Za-z0-9])',
    caseSensitive: false,
  );
  // Emoji corrompu par un convertisseur : suite de "?" ; un "?" ou "?!" seul
  // fait partie d'un vrai titre et reste.
  static final RegExp _corruptedEmoji = RegExp(r'\?{2,}');
  // Insère un espace aux frontières de mots collés (style "TVGirl",
  // "IWannaBeYours") — fréquent dans les noms compacts sans espaces d'un
  // convertisseur en particulier. Purement additif (n'efface jamais rien),
  // donc sans risque sur les noms déjà correctement espacés.
  // Classes Unicode (\p{L}/\p{Lu}) plutôt qu'ASCII : sans ça, "ÉricClapton" ou
  // "BeyoncéKnowles" ne se découpaient jamais (É/é hors de [A-Z]/[a-z]).
  static final RegExp _camelCaseBoundary = RegExp(r'(?<=[\p{L}\p{N}])(?=\p{Lu}\p{Ll})', unicode: true);
  // Pronom "I" collé après une minuscule ("DoIWanna" -> "Do IWanna") : la règle
  // générale ne le sépare pas (un "I" suivi d'une majuscule n'est pas une
  // frontière "Majuscule+minuscule") ; on isole le "I", puis
  // [_camelCaseBoundary] sépare le mot qui suit.
  static final RegExp _camelPronounI = RegExp(r'(?<=\p{Ll})(?=I\p{Lu}\p{Ll})', unicode: true);

  // Séparateurs entre artistes multiples au sein du segment artiste (jamais
  // appliqué au titre) : virgule, esperluette, "x" isolé, "vs", "feat.",
  // "ft.". Le "x" exige des espaces des deux côtés (pas simplement `\b`) pour
  // ne pas couper un nom d'artiste qui commence par "X" ("X Ambassadors").
  // "feat"/"ft"/"vs" acceptent un point final via `(?:\.|\b)` plutôt que
  // `\.?\b` : un `\b` après un point optionnel échoue quand le point est
  // suivi d'un espace (aucune frontière mot/non-mot entre deux non-mots), ce
  // qui aurait laissé le point traîner devant l'artiste suivant ("feat. Sia"
  // -> ". Sia" au lieu de "Sia").
  // "feat"/"ft" sont gardés par `(?<![A-Za-z])` et non `\b` : un `\b` refusait
  // "French79feat.Sarah" (chiffre juste avant = pas de frontière de mot), alors
  // que "Stanft.Dido" ne doit pas être coupé au milieu d'un mot (lettre avant).
  static final RegExp _artistSeparator = RegExp(
    r'\s*,\s*|\s*&\s*|\s+x\s+|\s*\bvs(?:\.|\b)\s*|\s*(?<![A-Za-z])feat(?:\.|\b)\s*|\s*(?<![A-Za-z])ft(?:\.|\b)\s*',
    caseSensitive: false,
  );
  // Clause "feat./ft./featuring" présente dans le TITRE : soit entre
  // parenthèses/crochets, soit nue après un espace, soit collée au titre
  // ("Stanft.Dido" : point obligatoire, sinon "Aft"/"Loft" seraient coupés).
  // Les invités vont dans `featuringArtists` et la clause quitte le titre.
  static final RegExp _titleFeat = RegExp(
    r'[\(\[]\s*(?:feat|ft|featuring)\b\.?\s*([^\(\)\[\]]+?)\s*[\)\]]'
    r'|(?<=\s)(?:feat|ft|featuring)(?:\.\s*|\s+)([^\(\)\[\]]+?)(?=\s*(?:[\(\[]|$))'
    r'|(?<=[A-Za-z0-9\)\]])(?:feat|ft)\.\s*([^\(\)\[\]]+?)(?=\s*(?:[\(\[]|$))',
    caseSensitive: false,
  );
  // Clause "(Feat. X)" / "[ft X]" située dans le SEGMENT ARTISTE ("David
  // Guetta (Feat. Ne-Yo & Akon)"). Sensible à la casse exprès : le mot-clé
  // est écrit [Ff]… à la main afin d'accepter une clause collée où le nom
  // commence par une majuscule ("(ftNataliaKills)", "(Feat.ColbyO'Donis)") —
  // `` est inopérant entre "ft" et une majuscule collée, et le lookahead
  // `(?=\p{Lu})` remplace la frontière. Sans cette exigence (point, espace ou
  // majuscule après le mot-clé), "(Feature)" ou "(Ftw)" seraient pris pour une
  // clause. Une parenthèse SANS feat ("Artiste (Band)") n'est jamais touchée.
  static final RegExp _artistFeat = RegExp(
    r'[\(\[]\s*(?:[Ff]eaturing|[Ff]eat|[Ff][Tt])(?:\.\s*|\s+|(?=\p{Lu}))([^\(\)\[\]]+?)\s*[\)\]]',
    unicode: true,
  );
  // Texte recopié après un tag "(Lyrics)" ("Titre (Lyrics) paroles de la
  // chanson recopiées...") : bruit de convertisseur. Le lookahead négatif
  // épargne "(Lyrics) feat. X" (vrai featuring) ; le groupe 3 conserve un
  // éventuel identifiant numérique terminal pour que [_trailingNumericId] le
  // retire ensuite comme d'habitude.
  static final RegExp _lyricsTail = RegExp(
    r'([\(\[]\s*(?:official\s*)?(?:lyrics?|paroles?)\s*[\)\]])\s+(?!(?:ft|feat|featuring|x|vs|with)\b)'
    r'([^\(\)\[\]]+?)((?:_\d{6,})?)\s*$',
    caseSensitive: false,
  );
  // Suffixe "(1)", "(2)"... ajouté par l'OS/le navigateur à un téléchargement
  // en double : jamais du contenu de titre.
  static final RegExp _dupSuffix = RegExp(r'(?:\s*\(\d{1,2}\))+\s*$');
  // "Titre by Artiste" sans séparateur " - " (fichiers de convertisseurs).
  static final RegExp _byArtist = RegExp(r'^(.+?)\s+by\s+(.+)$', caseSensitive: false);
  // ... sauf quand "by" est suivi d'un simple pronom : c'est alors le titre
  // lui-même ("Stand by Me", "Stand by You"), jamais un nom d'artiste.
  static final RegExp _byPronounOnly = RegExp(
    r'^(?:me|you|u|us|him|her|them|it|myself|yourself|ourselves|themselves)$',
    caseSensitive: false,
  );
  // Aides à la distinction entre un tiret de mot composé ("après-midi") et un
  // séparateur artiste/titre, et à la détection d'un séparateur converti en
  // suite d'espaces ou en " _ " (perdu sinon par l'écrasement des espaces).
  static final RegExp _dashChar = RegExp(r'[-–—]');
  static final RegExp _lowerLetter = RegExp(r'\p{Ll}', unicode: true);
  static final RegExp _whitespaceRun = RegExp(r'\s{2,}|\s_\s');
  static final RegExp _anyWhitespace = RegExp(r'\s+');
  // Emoji 🎵 : certains téléchargeurs nomment "Titre - Artiste 🎵" (ordre inversé).
  static const String _musicNoteEmoji = '\u{1F3B5}';

  SanitizedFilename sanitizeFilename(String rawFilename) {
    final String withoutExtension = rawFilename.replaceAll(RegExp(r'\.[^.]+$'), '');

    // Protège les noms d'artistes connus AVANT toute découpe/nettoyage par
    // regex : remplacés par un caractère privé (zone d'usage privé Unicode,
    // jamais produit par un vrai nom de fichier) insensible à toutes les
    // regex de nettoyage ci-dessous (aucune ne matche en dehors de
    // [0-9a-zA-Z] et de quelques mots précis), puis restaurés à la toute fin.
    final protection = ProtectedArtistNames.protect(withoutExtension);
    final String protectedInput = protection.text;
    final String Function(String) restoreProtectedNames = protection.restore;

    String withoutTrackNumber = protectedInput;
    String previous;
    do {
      previous = withoutTrackNumber;
      withoutTrackNumber = withoutTrackNumber.replaceFirst(_trackNumberPrefix, '');
    } while (withoutTrackNumber != previous);

    final firstPass = _splitIntoSegments(withoutTrackNumber);
    List<String> parts = firstPass.parts;

    // "Titre by Artiste" sans séparateur " - " (ex. "Till I Collapse by
    // Eminem", surtout avec des noms issus de convertisseurs). Seulement quand
    // rien d'autre n'a pu découper le nom, et si le côté artiste reste court
    // (<= 5 mots) : "Ben E. King - Stand by Me" a déjà deux segments et n'est
    // jamais concerné. Revue manuelle conservée : le découpage reste une
    // heuristique.
    if (parts.length == 1) {
      final Match? byMatch = _byArtist.firstMatch(parts[0]);
      if (byMatch != null &&
          byMatch.group(2)!.trim().split(_anyWhitespace).length <= 5 &&
          !_byPronounOnly.hasMatch(byMatch.group(2)!.trim())) {
        final List<String> artists = _artistsOfSegment(byMatch.group(2)!).map(restoreProtectedNames).toList();
        if (artists.isNotEmpty) {
          return SanitizedFilename(
            artist: artists.first,
            featuringArtists: artists.length > 1 ? artists.sublist(1) : const [],
            title: restoreProtectedNames(_denoiseSegment(byMatch.group(1)!.trim())),
            requiresUserReview: true,
          );
        }
      }
    }

    // Séparateur converti en suite d'espaces ou en " _ " par un téléchargeur
    // ("Artiste   Titre") : l'écrasement des espaces l'a fait disparaître, donc
    // on le rétablit en " - " sur le nom d'origine (hors crochets) et on relance
    // la chaîne ; adopté seulement s'il produit effectivement 2 segments ou plus.
    if (parts.length == 1) {
      final String? withSeparator = _replaceFirstWhitespaceRun(withoutTrackNumber.trim());
      if (withSeparator != null) {
        final List<String> retried = _splitIntoSegments(withSeparator).parts;
        if (retried.length >= 2) parts = retried;
      }
    }

    // Convention "Titre - Artiste 🎵" : l'emoji signale un ordre inversé. On le
    // retire puis on permute AVANT [_assemble] : l'extraction du featuring du
    // titre (clause "feat." du titre) s'y applique au segment désormais en
    // seconde position, et celle d'une clause "(Feat. X)" du segment artiste
    // au segment désormais en première position ([_artistsOfSegment]).
    if (rawFilename.contains(_musicNoteEmoji)) {
      parts = parts.map((p) => p.replaceAll(_musicNoteEmoji, '').trim()).where((p) => p.isNotEmpty).toList();
      if (parts.length == 2) parts = [parts[1], parts[0]];
    }

    if (parts.length == 2) {
      // (Le cas d'un second segment qui répète l'artiste est traité en amont,
      // dans [_splitIntoSegments] : le segment redondant est déjà retiré.)
      return _assemble(
          artistSegment: parts[0], title: parts[1], restore: restoreProtectedNames, requiresUserReview: false);
    }

    if (parts.length > 2) {
      // Séparateurs multiples (ex. plusieurs "-") : ambigu, best-effort + review manuelle.
      return _assemble(
          artistSegment: parts.first,
          title: parts.sublist(1).join(' - '),
          restore: restoreProtectedNames,
          requiresUserReview: true);
    }

    // Aucun séparateur trouvé : impossible de distinguer artiste/titre.
    final String single = parts.isNotEmpty ? parts.first : firstPass.normalized;
    return SanitizedFilename(
        artist: 'Unknown', title: restoreProtectedNames(_denoiseSegment(single)), requiresUserReview: true);
  }

  /// Construit le résultat à partir du segment artiste et du titre : artistes
  /// multiples du segment artiste + invités d'une clause "feat." du titre
  /// ([_extractTitleFeat]), qui quitte alors le titre.
  SanitizedFilename _assemble({
    required String artistSegment,
    required String title,
    required String Function(String) restore,
    required bool requiresUserReview,
  }) {
    final List<String> artists = _artistsOfSegment(artistSegment).map(restore).toList();
    final (String, List<String>) feat = _extractTitleFeat(title);
    final List<String> all = [...artists, ...feat.$2.map(restore)];
    return SanitizedFilename(
      artist: all.isNotEmpty ? all.first : 'Unknown',
      featuringArtists: all.length > 1 ? all.sublist(1) : const [],
      title: restore(feat.$1),
      requiresUserReview: requiresUserReview,
    );
  }

  /// Chaîne de nettoyage complète (ids, tags, bruit terminal) puis découpe en
  /// segments. Isolée de [sanitizeFilename] pour pouvoir être rejouée sur une
  /// variante du nom (voir le rétablissement d'un séparateur perdu).
  ({List<String> parts, String normalized}) _splitIntoSegments(String withoutTrackNumber) {
    String previous;

    // Retiré avant le nettoyage des tags entre parenthèses et avant le
    // découpage artiste/titre : un GUID contient lui-même des tirets qui
    // fausseraient sinon la détection du séparateur artiste/titre.
    String withoutIdNoise = withoutTrackNumber.replaceAll(_idNoise, ' ');
    do {
      previous = withoutIdNoise;
      withoutIdNoise = withoutIdNoise.replaceFirst(_emptyBracketPair, ' ');
    } while (withoutIdNoise != previous);

    // Paroles recopiées après "(Lyrics)" : au moins 3 mots (en dessous, c'est
    // plus probablement un vrai complément de titre) sont du bruit.
    withoutIdNoise = withoutIdNoise.replaceAllMapped(_lyricsTail, (m) {
      final int words = m.group(2)!.trim().split(_anyWhitespace).length;
      return words >= 3 ? '${m.group(1)}${m.group(3)}' : m.group(0)!;
    });

    final String withoutNoise = TitleCleaner.stripNoiseTags(withoutIdNoise).replaceFirst(_dupSuffix, '');

    // Mémorisé avant l'espacement des mots collés : sert à décider si un tiret
    // sans espace est un mot composé ou un séparateur (voir
    // [_splitOnTopLevelSeparator]).
    final bool hadSpaces = withoutNoise.trim().contains(' ');

    // Espacement des mots collés fait tôt, *avant* le dépiècement de l'ID et
    // du bruit terminal nu : sans ça, un suffixe comme "EnglishLyrics" ne
    // révèle jamais son "Lyrics" isolable (pas d'espace/underscore devant),
    // et le bruit ne peut plus être reconnu ensuite.
    final String spacedEarly = _spaceGluedWords(withoutNoise);

    String withoutTrailingId = spacedEarly;
    do {
      previous = withoutTrailingId;
      withoutTrailingId = withoutTrailingId.replaceFirst(_trailingNumericId, '');
    } while (withoutTrailingId != previous);

    String withoutBareNoise = withoutTrailingId;
    do {
      previous = withoutBareNoise;
      withoutBareNoise = withoutBareNoise.replaceFirst(_bareTrailingNoise, '');
    } while (withoutBareNoise != previous);

    final String normalized = _normalizedOf(withoutBareNoise);

    List<String> parts = _splitOnTopLevelSeparator(normalized, hadSpaces).map(_denoiseSegment).toList();

    // Segments finaux qui ne font que répéter (une partie de) l'artiste : pas
    // de vrais titres — signe d'une réattribution redondante ajoutée par un
    // convertisseur juste avant son id de téléchargement (ex. "...Sweet Dreams
    // (Are Made Of This)-Eurythmics-<hash>" une fois le hash seul retiré :
    // "Eurythmics" en dernier segment serait sinon pris à tort pour le titre,
    // avec l'artiste ET le vrai titre restés collés côté "artiste"). Aucun
    // faux positif plausible : un vrai titre identique à un simple sous-mot du
    // nom d'artiste n'existe pas en pratique. Appliqué en boucle : plusieurs
    // réattributions peuvent s'empiler.
    while (parts.length >= 2 &&
        _normalizeForComparison(parts.last).isNotEmpty &&
        _normalizeForComparison(parts.first).contains(_normalizeForComparison(parts.last))) {
      parts = parts.sublist(0, parts.length - 1);
    }

    return (parts: parts, normalized: normalized);
  }

  static String _normalizedOf(String s) => s.replaceAll('_', ' ').replaceAll(_anyWhitespace, ' ').trim();

  /// Insère un espace aux frontières de mots collés ([_camelCaseBoundary],
  /// [_camelPronounI]). Un nom déjà bien espacé (au moins 1 espace pour 10
  /// caractères) est laissé intact : le camelCase y est volontaire ("McDonald",
  /// "DeLorean", "iPhone") et ne doit pas être éclaté.
  static String _spaceGluedWords(String s) {
    final String trimmed = s.trim();
    final int spaces = ' '.allMatches(trimmed).length;
    if (spaces * 10 >= trimmed.length) return s;
    return s.replaceAllMapped(_camelPronounI, (m) => ' ').replaceAllMapped(_camelCaseBoundary, (m) => ' ');
  }

  /// Extrait la clause "feat./ft./featuring" du titre : renvoie (titre sans la
  /// clause, invités). Inchangé si rien n'est trouvé ou si retirer la clause
  /// viderait le titre.
  (String, List<String>) _extractTitleFeat(String title) {
    final Match? m = _titleFeat.firstMatch(title);
    if (m == null) return (title, const []);
    final String names = (m.group(1) ?? m.group(2) ?? m.group(3) ?? '').trim();
    final List<String> feats = _splitArtists(names);
    if (feats.isEmpty) return (title, const []);
    final String rest =
        '${title.substring(0, m.start)} ${title.substring(m.end)}'.replaceAll(_anyWhitespace, ' ').trim();
    if (rest.isEmpty) return (title, const []);
    return (rest, feats);
  }

  /// Remplace la première suite de >= 2 espaces ou " _ " située hors crochets
  /// (et ni en tête ni en queue) par " - ". Renvoie null s'il n'y en a pas.
  String? _replaceFirstWhitespaceRun(String s) {
    int depth = 0;
    for (int i = 0; i < s.length; i++) {
      final String c = s[i];
      if (c == '(' || c == '[' || c == '{') depth++;
      if (c == ')' || c == ']' || c == '}') depth = depth > 0 ? depth - 1 : 0;
      if (depth != 0) continue;
      final Match? m = _whitespaceRun.matchAsPrefix(s, i);
      if (m != null && i > 0 && m.end < s.length) {
        return '${s.substring(0, i)} - ${s.substring(m.end)}';
      }
    }
    return null;
  }

  /// Retire les "??" et les mots de bruit isolés d'un segment. Si le nettoyage
  /// viderait le segment, on garde la valeur d'origine : mieux vaut un titre
  /// moche qu'un titre/artiste vide.
  static String _denoiseSegment(String segment) {
    final String cleaned = segment
        .replaceAll(_corruptedEmoji, ' ')
        .replaceAllMapped(_standaloneNoise, (m) => m.group(1) ?? ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return cleaned.isEmpty ? segment : cleaned;
  }

  /// Artistes d'un segment artiste : retire d'abord une clause "(Feat. X)"
  /// ([_artistFeat]) — sinon la découpe sur `feat`/`&` laisserait des
  /// parenthèses orphelines ("David Guetta (", "Akon)") — puis découpe le
  /// reste ; les invités de la clause, découpés comme les autres, suivent
  /// l'artiste principal. Inchangé si retirer la clause viderait le segment.
  static List<String> _artistsOfSegment(String artistSegment) {
    final Match? m = _artistFeat.firstMatch(artistSegment);
    if (m == null) return _splitArtists(artistSegment);
    final String rest = '${artistSegment.substring(0, m.start)} ${artistSegment.substring(m.end)}'
        .replaceAll(_anyWhitespace, ' ')
        .trim();
    if (rest.isEmpty) return _splitArtists(artistSegment);
    return [..._splitArtists(rest), ..._splitArtists(m.group(1)!)];
  }

  /// Sépare un segment "artiste" en artiste principal + featurings sur les
  /// séparateurs `,` `&` `x` `vs` `feat.` `ft.` — jamais appliqué au titre.
  static List<String> _splitArtists(String artistSegment) =>
      artistSegment.split(_artistSeparator).map((part) => part.trim()).where((part) => part.isNotEmpty).toList();

  /// Découpe sur [_separator] en ignorant les tirets internes à une
  /// parenthèse/crochet/accolade — sans ça, un remix noté "(JENNIE Remix -
  /// Official Lyric Video)" ou un tag "(WSHHExclusive-OfficialMusicVideo)"
  /// fait croire à un séparateur artiste/titre supplémentaire là où il n'y en
  /// a pas, et casse un découpage par ailleurs sans ambiguïté.
  ///
  /// Un tiret SANS espace de part et d'autre est ambigu : séparateur compact
  /// ("21Savage-redrum") ou tiret de mot composé ("après-midi"). Il est traité
  /// comme un mot composé dans deux cas seulement : un vrai séparateur espacé
  /// (" - ") existe ailleurs au premier niveau, ou le nom est espacé
  /// ([hadSpaces]) et le tiret est entouré de deux minuscules. Sinon on coupe
  /// comme avant, pour ne pas casser les noms compacts.
  List<String> _splitOnTopLevelSeparator(String input, bool hadSpaces) {
    final List<String> parts = [];
    final StringBuffer current = StringBuffer();
    final bool spacedDash = _hasTopLevelSpacedDash(input);
    int depth = 0;
    int i = 0;
    while (i < input.length) {
      final String char = input[i];
      if (char == '(' || char == '[' || char == '{') depth++;
      if (char == ')' || char == ']' || char == '}') depth = depth > 0 ? depth - 1 : 0;

      if (depth == 0) {
        final Match? match = _separator.matchAsPrefix(input, i);
        if (match != null && match.start == i) {
          if (match.end - match.start == 1) {
            final bool lowerBefore = i > 0 && _lowerLetter.hasMatch(input[i - 1]);
            final bool lowerAfter = i + 1 < input.length && _lowerLetter.hasMatch(input[i + 1]);
            if (spacedDash || (hadSpaces && lowerBefore && lowerAfter)) {
              current.write(char);
              i++;
              continue;
            }
          }
          parts.add(current.toString());
          current.clear();
          i = match.end;
          continue;
        }
      }
      current.write(char);
      i++;
    }
    parts.add(current.toString());
    return parts.map((part) => part.trim()).where((part) => part.isNotEmpty).toList();
  }

  /// Vrai si un tiret collé à une espace (d'un côté au moins) existe hors de
  /// tout crochet : signe d'un vrai séparateur artiste/titre " - ".
  static bool _hasTopLevelSpacedDash(String input) {
    int depth = 0;
    for (int i = 0; i < input.length; i++) {
      final String c = input[i];
      if (c == '(' || c == '[' || c == '{') depth++;
      if (c == ')' || c == ']' || c == '}') depth = depth > 0 ? depth - 1 : 0;
      if (depth != 0) continue;
      if (_dashChar.hasMatch(c)) {
        final bool spaceBefore = i > 0 && input[i - 1] == ' ';
        final bool spaceAfter = i + 1 < input.length && input[i + 1] == ' ';
        if (spaceBefore || spaceAfter) return true;
      }
    }
    return false;
  }

  static String _normalizeForComparison(String value) => value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
}
