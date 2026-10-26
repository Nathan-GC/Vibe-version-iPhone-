/// Répare le "mojibake" de certains titres/artistes : du texte écrit dans la
/// page de code Windows OEM CP850 (octet 0x82 = "é") puis relu comme du Mac
/// Roman (où ce même octet s'affiche "Ç") — "BeyoncÇ", "áa n'en vaut pas la
/// peine" (= "ça …"), "ROSAL÷A" (= "ROSALÍA", exception explicite `÷ → í`).
///
/// Appliquer la table caractère par caractère à toute chaîne serait faux :
/// beaucoup de clés sont des lettres légitimes d'un texte bien encodé (un vrai
/// "é" deviendrait "Ä"). On exige donc au moins un caractère SIGNATURE — un
/// glyphe Mac Roman qui n'apparaît pratiquement jamais dans un titre normal —
/// et seulement alors la chaîne ENTIÈRE passe par la table. Sans signature, la
/// chaîne est rendue telle quelle (un "á" seul n'est pas une signature).
///
/// Limite acceptée : un "Ç"/"ä"/"Ö" légitime dans un titre bien encodé ("Ça
/// plane pour moi", "Mädchen") est altéré. Acceptable car la correction ne sert
/// qu'à construire la requête iTunes, jamais aux données stockées.
class EncodingFixer {
  const EncodingFixer._();

  static const String _signatureChars = 'ÇÖä÷¢£§°¶·†‡•‰∂∆∑◊';

  // Glyphe Mac Roman lu -> lettre CP850 d'origine. La ponctuation typographique
  // (’ – — « » “ ”) est volontairement absente : elle est légitime telle quelle.
  static const Map<String, String> _macRomanToCp850 = {
    'Ä': 'Ç',
    'Å': 'ü',
    'Ç': 'é',
    'É': 'â',
    'Ñ': 'ä',
    'Ö': 'à',
    'Ü': 'å',
    'á': 'ç',
    'à': 'ê',
    'â': 'ë',
    'ä': 'è',
    'ã': 'ï',
    'å': 'î',
    'ç': 'ì',
    'é': 'Ä',
    'è': 'Å',
    'ê': 'É',
    'ë': 'æ',
    'í': 'Æ',
    'ì': 'ô',
    'î': 'ö',
    'ï': 'ò',
    'ñ': 'û',
    'ó': 'ù',
    'ò': 'ÿ',
    'ô': 'Ö',
    'ö': 'Ü',
    'õ': 'ø',
    'ù': 'Ø',
    'ü': 'ƒ',
    '†': 'á',
    '°': 'í',
    '¢': 'ó',
    '£': 'ú',
    '§': 'ñ',
    '•': 'Ñ',
    '¶': 'ª',
    'ß': 'º',
    'µ': 'Á',
    '∂': 'Â',
    '∑': 'À',
    '∆': 'ã',
    '÷': 'í',
    '◊': 'Î',
    'ÿ': 'Ï',
    'ﬁ': 'Ì',
    '‡': 'Ó',
    '·': 'ß',
    '‰': 'õ',
    'Â': 'Õ',
    'Ê': 'µ',
    'Á': 'þ',
    'Ë': 'Þ',
    'È': 'Ú',
    'Í': 'Û',
    'Î': 'Ù',
    'Ï': 'ý',
    'Ì': 'Ý',
  };

  static String fix(String input) {
    if (!input.runes.any((int r) => _signatureChars.contains(String.fromCharCode(r)))) return input;
    final StringBuffer out = StringBuffer();
    for (final int r in input.runes) {
      final String c = String.fromCharCode(r);
      out.write(_macRomanToCp850[c] ?? c);
    }
    return out.toString();
  }
}
