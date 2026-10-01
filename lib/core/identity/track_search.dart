import 'track_match_key.dart';

/// Filtrage en temps réel d'une liste de morceaux sur le TITRE et les NOMS
/// D'ARTISTES (featurings compris), insensible à la casse et aux accents
/// ("beyonce" trouve "Beyoncé", "HALO" trouve "Halo"). Chaque mot saisi doit
/// apparaître dans le titre ou l'un des artistes, dans n'importe quel ordre
/// ("punk one more" trouve "One More Time" de Daft Punk). Une recherche vide
/// ou composée uniquement d'espaces correspond à tout.
bool trackMatchesSearch({required String title, required List<String> artists, required String query}) {
  final List<String> words = foldDiacritics(query).split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return true;
  final String haystack = foldDiacritics('$title ${artists.join(' ')}');
  return words.every(haystack.contains);
}
