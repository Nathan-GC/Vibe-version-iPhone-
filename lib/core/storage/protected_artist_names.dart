/// Noms d'artistes connus dont la ponctuation/les caractères spéciaux
/// internes seraient sinon détruits par le nettoyage (points de "Fred
/// again..") ou pris à tort pour un séparateur multi-artiste (la virgule de
/// "Earth, Wind & Fire", le "&" de "Florence + The Machine", le "x" de "Hunter
/// x Hunter"). Partagé par le parseur de noms de fichiers
/// (FilenameSanitizer) et celui des tags ID3 (MetadataExtractor) : une seule
/// liste, sinon un artiste protégé d'un côté serait coupé de l'autre.
///
/// Chaque entrée matche aussi les variantes courantes sur disque (espace/
/// tiret/underscore à la place du caractère spécial, ponctuation optionnelle,
/// forme compacte sans espaces) : le "/" de "AC/DC" ne peut lui-même jamais
/// apparaître dans un nom de fichier. Les noms courts (Jay-Z, Ne-Yo, will.i.am)
/// exigent une frontière alphanumérique par lookaround plutôt que `\b` : le "_"
/// collé d'un id de convertisseur compte comme lettre pour `\b`, et sans
/// frontière "will.i.am" matcherait dans "Williams".
class ProtectedArtistNames {
  const ProtectedArtistNames._();

  static final List<({String canonical, RegExp pattern})> _names = [
    (canonical: 'Fred again..', pattern: RegExp(r'fred\s*again\.{0,2}', caseSensitive: false)),
    (canonical: 'AC/DC', pattern: RegExp(r'ac[\s_-]?dc', caseSensitive: false)),
    (canonical: 'Florence + The Machine', pattern: RegExp(r'florence\s*\+\s*the\s*machine', caseSensitive: false)),
    (canonical: 'Earth, Wind & Fire', pattern: RegExp(r'earth,?\s*wind\s*&\s*fire', caseSensitive: false)),
    (canonical: 'Panic! At The Disco', pattern: RegExp(r'panic!?\s*at\s*the\s*disco', caseSensitive: false)),
    (canonical: 'will.i.am', pattern: RegExp(r'(?<![a-z0-9])will\.?i\.?am(?![a-z0-9])', caseSensitive: false)),
    (canonical: 'M.I.A.', pattern: RegExp(r'\bm\.i\.a\.?\b', caseSensitive: false)),
    (canonical: "Guns N' Roses", pattern: RegExp(r"guns\s*n'?\s*roses", caseSensitive: false)),
    (
      canonical: 'Crosby, Stills, Nash & Young',
      pattern: RegExp(r'crosby,?\s*stills,?\s*nash\s*&\s*young', caseSensitive: false),
    ),
    (canonical: 'Tyler, The Creator', pattern: RegExp(r'\btyler,?[\s_]*the[\s_]*creator', caseSensitive: false)),
    (canonical: 'Kool & The Gang', pattern: RegExp(r'\bkool[\s_]*&[\s_]*the[\s_]*gang', caseSensitive: false)),
    (canonical: 'Years & Years', pattern: RegExp(r'\byears[\s_]*&[\s_]*years', caseSensitive: false)),
    (canonical: 'Mumford & Sons', pattern: RegExp(r'\bmumford[\s_]*&[\s_]*sons', caseSensitive: false)),
    (canonical: 'Jay-Z', pattern: RegExp(r'(?<![a-z0-9])jay[\s_-]?z(?![a-z0-9])', caseSensitive: false)),
    (canonical: 'Ne-Yo', pattern: RegExp(r'(?<![a-z0-9])ne[\s_-]?yo(?![a-z0-9])', caseSensitive: false)),
    // Avant "The Scene" seul : plus long, jamais confondu avec "Selena Gomez".
    (
      canonical: 'Selena Gomez & The Scene',
      pattern: RegExp(r'\bselena[\s_]*gomez[\s_]*&[\s_]*the[\s_]*scene', caseSensitive: false),
    ),
    (
      canonical: 'The Mamas & The Papas',
      pattern: RegExp(r'\b(?:the[\s_]*)?mamas[\s_]*&[\s_]*the[\s_]*papas', caseSensitive: false),
    ),
    // "x" minuscule/majuscule ou signe "×" : sans protection, le "x" isolé
    // coupe le nom en "Hunter" + "Hunter".
    (canonical: 'Hunter x Hunter', pattern: RegExp(r'\bhunter[\s_]*[x×][\s_]*hunter', caseSensitive: false)),
  ];

  /// Remplace chaque nom protégé par un caractère privé (zone d'usage privé
  /// Unicode, jamais produit par un vrai nom de fichier/tag) insensible à
  /// toutes les regex de nettoyage/découpe, et renvoie la fonction qui les
  /// restaure sous leur forme canonique une fois le découpage fait.
  static ({String text, String Function(String) restore}) protect(String input) {
    final List<String> canonicalByPlaceholder = [];
    String text = input;
    for (final protectedName in _names) {
      text = text.replaceAllMapped(protectedName.pattern, (match) {
        final String placeholder = String.fromCharCode(0xE000 + canonicalByPlaceholder.length);
        canonicalByPlaceholder.add(protectedName.canonical);
        return placeholder;
      });
    }
    String restore(String value) {
      String result = value;
      for (int i = 0; i < canonicalByPlaceholder.length; i++) {
        result = result.replaceAll(String.fromCharCode(0xE000 + i), canonicalByPlaceholder[i]);
      }
      return result;
    }

    return (text: text, restore: restore);
  }
}
