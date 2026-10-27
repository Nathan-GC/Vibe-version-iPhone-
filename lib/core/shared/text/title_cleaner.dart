/// Retire les suffixes parasites d'un titre de morceau (tags de version,
/// mentions "Lyrics"/"Paroles"...) — partagé entre le nettoyage des noms de
/// fichiers locaux (FilenameSanitizer, sur le nom de fichier brut) et les
/// titres renvoyés par l'API iTunes (MetadataApiClient), pour un affichage
/// cohérent partout dans l'app plutôt que deux règles qui divergent.
class TitleCleaner {
  const TitleCleaner._();

  // "official" est un préfixe optionnel qui peut se combiner avec n'importe
  // quelle autre mention (pas seulement video/audio/music video) — sans ça,
  // "(Official Lyric Video)" ou "(Official Visualizer)" ne matchaient pas du
  // tout puisque le groupe après "official" n'acceptait que 3 mots fixes.
  // Le suffixe "remaster(ed)" optionnel couvre la forme composée observée en
  // pratique "(Official Music Video Remastered)".
  // Le groupe central est répété (`+`) : certains convertisseurs empilent
  // plusieurs mentions collées sans séparateur dans une même parenthèse (ex.
  // "(LyricsLyricVideo)" = "Lyrics" + "LyricVideo") — un seul passage ne
  // capturait que la première et laissait le reste tel quel.
  // Les mots "letra", "tiktok", "sped up", "slowed (+ reverb)" sont du bruit de
  // convertisseur/réseau social ; le "+" optionnel autorise les listes type
  // "( + paroles letra)". Un crochet qui mêle bruit ET marqueur de version
  // ("hardstyle remix + SLOWED") n'est PAS capté ici : voir [stripNoiseTags].
  // Les mentions françaises ("clip officiel", "vidéo officielle", "audio
  // officiel", "clip vidéo") et "full track" sont du même bruit de
  // téléchargeur : sans elles, "(Clip Officiel)" restait dans le titre.
  static final RegExp noiseTags = RegExp(
    r'[\(\[\{](?:\s*\+?\s*(?:official\s*)?('
    r'official|'
    r'video|audio|music\s*video|lyric\s*video|visuali[sz]er|'
    r'lyrics?|paroles?|letra|'
    r'tiktok(\s*song)?|sped\s*up|slowed(\s*\+?\s*reverb)?|'
    r'hd|4k|hq|\d{3,4}p|\d{2,4}\s*kbps|'
    r'remaster(ed)?(\s*\d{4})?|'
    r'explicit|clean|'
    r'radio\s*edit|album\s*version|single\s*version|'
    r'deluxe(\s*edition)?|bonus\s*track|extended(\s*version)?|'
    r'(?:clip|vid[eé]o|audio)\s*officiel(?:le)?|clip\s*vid[eé]o|full\s*track'
    r'))+\s*[\)\]\}]',
    caseSensitive: false,
  );

  // Un crochet qui COMMENCE par une mention de crédit/téléchargement est du
  // bruit en entier, quel que soit ce qui suit (nom du réalisateur, lien...) :
  // "Directed by", "Free Download", mais aussi "(From <film>)", "(prod. X)",
  // "(réal. X)", "(Participation X)" et tout crochet qui contient le mot
  // "Soundtrack". `(?![A-Za-z])` après le mot-clé : "(Fromage)" ou "(Product)"
  // ne sont pas des crédits.
  static final RegExp _creditBracket = RegExp(
    r'[\(\[\{]\s*(?:directed\s+by|free\s*download|from|prod\.?|r[eé]al\.?|participation|[^\)\]\}]*\bsoundtrack\b)'
    r'(?![A-Za-z])[^\)\]\}]*[\)\]\}]',
    caseSensitive: false,
  );
  static final RegExp _bracket = RegExp(r'[\(\[\{]([^\(\)\[\]\{\}]*)[\)\]\}]');
  // Mots de bruit retirés À L'INTÉRIEUR d'un crochet qui garde un marqueur de
  // version. Bornes alphanumériques (pas `\b`) : "_" ne doit pas les masquer.
  static final RegExp _inlineNoise = RegExp(
    r'(?<![A-Za-z0-9])(?:tiktok(?:\s*song)?|sped\s*up|slowed(?:\s*\+?\s*reverb)?|letra)(?![A-Za-z0-9])',
    caseSensitive: false,
  );
  static final RegExp _edgeSeparators = RegExp(r'^[\s+&,/-]+|[\s+&,/-]+$');

  /// Retire les crochets 100 % bruit, les crochets de crédit ("Directed by
  /// ...", "Free Download ...") et, dans un crochet mixte, seulement les mots
  /// de bruit : "(hardstyle remix + SLOWED)" -> "(hardstyle remix)", pour que
  /// le marqueur de version (remix, live...) survive aux étapes suivantes.
  static String stripNoiseTags(String input) {
    final String withoutWhole = input.replaceAll(_creditBracket, '').replaceAll(noiseTags, '');
    return withoutWhole.replaceAllMapped(_bracket, (match) {
      final String inner = match.group(1)!;
      final String cleaned =
          inner.replaceAll(_inlineNoise, ' ').replaceAll(RegExp(r'\s+'), ' ').replaceAll(_edgeSeparators, '');
      if (cleaned == inner.trim() && !_inlineNoise.hasMatch(inner)) return match.group(0)!;
      if (cleaned.isEmpty) return '';
      final String whole = match.group(0)!;
      return '${whole[0]}$cleaned${whole[whole.length - 1]}';
    });
  }

  static String clean(String title) {
    return stripNoiseTags(title).replaceAll(RegExp(r'\s+'), ' ').trim();
  }
}
