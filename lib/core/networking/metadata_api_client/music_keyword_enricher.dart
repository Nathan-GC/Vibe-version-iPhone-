/// Construit la liste de mots-clés stockée dans `tracks.tags` /
/// `playlists.tags` (genre, mood, époque) à partir d'un genre iTunes et d'une
/// année de sortie — alimente la future détection automatique de Vibe.
/// L'association genre -> mood est une heuristique de départ, pas une
/// classification musicale exacte : à affiner si la détection de Vibe s'avère
/// trop approximative en pratique.
class MusicKeywordEnricher {
  const MusicKeywordEnricher._();

  static const Map<String, String> _moodByGenre = {
    'Hip-Hop/Rap': 'Urbain',
    'Rock': 'Énergique',
    'Alternative': 'Énergique',
    'Metal': 'Intense',
    'Electronic': 'Festif',
    'Dance': 'Festif',
    'House': 'Festif',
    'Pop': 'Feel-good',
    'R&B/Soul': 'Sensuel',
    'Jazz': 'Chill',
    'Classical': 'Calme',
    'Singer/Songwriter': 'Introspectif',
    'Country': 'Chaleureux',
    'Reggae': 'Détente',
    'Folk': 'Chaleureux',
  };

  /// "Années 1990", "Années 2010"... — null si l'année est inconnue.
  static String? eraLabel(int? releaseYear) {
    if (releaseYear == null || releaseYear <= 0) return null;
    final int decade = (releaseYear ~/ 10) * 10;
    return 'Années $decade';
  }

  static String? moodFromGenre(String? genre) => genre == null ? null : _moodByGenre[genre];

  /// Fusionne genre + époque + mood dérivé avec les mots-clés déjà présents,
  /// sans doublons. Les entrées existantes (tags manuels, genre ID3 déjà
  /// scanné) sont préservées.
  static List<String> buildKeywords({String? genre, int? releaseYear, List<String> existing = const []}) {
    final Set<String> merged = {...existing};
    if (genre != null && genre.trim().isNotEmpty) merged.add(genre.trim());

    final String? era = eraLabel(releaseYear);
    if (era != null) merged.add(era);

    final String? mood = moodFromGenre(genre);
    if (mood != null) merged.add(mood);

    return merged.toList();
  }
}
