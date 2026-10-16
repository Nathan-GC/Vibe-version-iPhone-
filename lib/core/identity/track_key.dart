import 'track_match_key.dart';

final RegExp _separators = RegExp(r'[^\p{L}\p{M}\p{N}]+', unicode: true);
final RegExp _edgeDashes = RegExp(r'^-+|-+$');

/// Génère `tracks.id` : title_slug + "_" + album_slug + "_" + primary_artist_slug,
/// ex. "one-more-time_discovery_daft-punk". Les featurings restent dans artists[]
/// et ne sont jamais fusionnés dans cette clé.
///
/// Slugs normalisés comme le reste de l'app ([foldDiacritics] : NFC/NFD,
/// accents latins retirés) — les lettres de TOUT alphabet sont conservées,
/// avec leurs signes (harakat, voyelles devanagari). Limitée à `[a-z0-9]`, la
/// clé vidait les titres cyrilliques, asiatiques ou arabes : deux morceaux
/// différents du même artiste partageaient alors le même id et le second
/// écrasait le premier. Clé inchangée pour un texte ASCII.
String buildSanitizedKey({required String title, String? album, required String primaryArtist}) {
  String slugify(String input) => foldDiacritics(input.trim()).replaceAll(_separators, '-').replaceAll(_edgeDashes, '');

  return '${slugify(title)}_${slugify(album ?? '')}_${slugify(primaryArtist)}';
}
