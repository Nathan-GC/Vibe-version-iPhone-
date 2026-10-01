/// Normalisation tolérante titre/artiste pour rapprocher un titre venu d'un
/// manifeste JSON (autre appareil, autre nommage de fichiers) d'un morceau de
/// la bibliothèque locale — plus permissive que `buildSanitizedKey`, qui
/// exige aussi le même album et le même découpage exact.
///
/// Partagée entre le matching à l'import (ImportTrackMatcher) et le
/// dégrisage automatique (TrackRepository.upsertTrack) : les deux côtés
/// doivent produire exactement la même clé.
library;

const String _accented = 'àáâãäåāçćčèéêëēėęìíîïīñńòóôõöøōùúûüūýÿžźżšśß';
const String _plain = 'aaaaaaaccceeeeeeeiiiiinnooooooouuuuuyyzzzsss';

/// Minuscules, accents retirés ("Beyoncé" -> "beyonce"), `œ`/`æ` décomposés.
String foldDiacritics(String input) {
  final StringBuffer buffer = StringBuffer();
  for (final int rune in input.toLowerCase().runes) {
    final String char = String.fromCharCode(rune);
    if (char == 'œ') {
      buffer.write('oe');
      continue;
    }
    if (char == 'æ') {
      buffer.write('ae');
      continue;
    }
    final int index = _accented.indexOf(char);
    buffer.write(index == -1 ? char : _plain[index]);
  }
  return buffer.toString();
}

final RegExp _bracketed = RegExp(r'\([^)]*\)|\[[^\]]*\]');
final RegExp _featTail = RegExp(r'\s(feat|ft|featuring)\b.*$');
final RegExp _nonAlphanumeric = RegExp(r'[^a-z0-9]+');

String _collapse(String input) => input.replaceAll(_nonAlphanumeric, ' ').trim().replaceAll(RegExp(r'\s+'), ' ');

/// Titre comparable : sans accents ni ponctuation, sans segments entre
/// parenthèses/crochets ("(Remastered 2011)", "[Official Video]") ni
/// featuring final ("feat. X") — deux versions nommées différemment du même
/// morceau donnent la même valeur.
String normalizeTrackTitle(String title) {
  final String withoutBrackets = foldDiacritics(title).replaceAll(_bracketed, ' ');
  return _collapse(withoutBrackets.replaceAll(_featTail, ''));
}

/// Nom d'artiste comparable : sans accents ni ponctuation.
String normalizeArtistName(String artist) => _collapse(foldDiacritics(artist));

/// Clé de rapprochement titre + artiste principal (sans album).
String buildTrackMatchKey({required String title, required String artist}) =>
    '${normalizeTrackTitle(title)}|${normalizeArtistName(artist)}';
