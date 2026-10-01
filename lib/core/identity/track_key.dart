/// Génère `tracks.id` : title_slug + "_" + album_slug + "_" + primary_artist_slug,
/// ex. "one-more-time_discovery_daft-punk". Les featurings restent dans artists[]
/// et ne sont jamais fusionnés dans cette clé.
String buildSanitizedKey({required String title, String? album, required String primaryArtist}) {
  String slugify(String input) =>
      input.toLowerCase().trim().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');

  return '${slugify(title)}_${slugify(album ?? '')}_${slugify(primaryArtist)}';
}
