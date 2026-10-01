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
  static final RegExp noiseTags = RegExp(
    r'[\(\[\{](?:\s*(?:official\s*)?('
    r'official|'
    r'video|audio|music\s*video|lyric\s*video|visuali[sz]er|'
    r'lyrics?|paroles?|'
    r'hd|4k|hq|\d{3,4}p|\d{2,4}\s*kbps|'
    r'remaster(ed)?(\s*\d{4})?|'
    r'explicit|clean|'
    r'radio\s*edit|album\s*version|single\s*version|'
    r'deluxe(\s*edition)?|bonus\s*track|extended(\s*version)?'
    r'))+\s*[\)\]\}]',
    caseSensitive: false,
  );

  static String clean(String title) {
    return title.replaceAll(noiseTags, '').replaceAll(RegExp(r'\s+'), ' ').trim();
  }
}
