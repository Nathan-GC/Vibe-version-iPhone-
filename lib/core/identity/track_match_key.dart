/// Normalisation tolérante titre/artiste pour rapprocher un titre venu d'un
/// manifeste JSON (autre appareil, autre nommage de fichiers) d'un morceau de
/// la bibliothèque locale — plus permissive que `buildSanitizedKey`, qui
/// exige aussi le même album et le même découpage exact.
///
/// Partagée entre le matching à l'import (ImportTrackMatcher) et le
/// dégrisage automatique (TrackRepository.upsertTrack) : les deux côtés
/// doivent produire exactement la même clé.
library;

import 'package:unorm_dart/unorm_dart.dart' as unorm;

final RegExp _ascii = RegExp(r'^[\x00-\x7f]*$');

/// Accents latins, grecs et cyrilliques que la décomposition NFD sépare de
/// leur lettre de base (bloc U+0300–U+036F). Les signes propres à d'autres
/// écritures (dakuten japonais, voyelles devanagari…) n'en font pas partie.
final RegExp _combiningDiacritics = RegExp('[̀-ͯ]');

/// Lettres sans décomposition Unicode, pliées à la main.
final RegExp _undecomposable = RegExp('[œæøßłđ]');
const Map<String, String> _undecomposableFolds = {'œ': 'oe', 'æ': 'ae', 'ø': 'o', 'ß': 's', 'ł': 'l', 'đ': 'd'};

/// Minuscules, accents retirés ("Beyoncé" -> "beyonce"), `œ`/`æ` décomposés —
/// à l'identique que le texte soit précomposé ("é", NFC) ou décomposé ("e" +
/// accent combinant, NFD : noms de fichiers créés sur macOS…). Lot 2.2 :
/// l'ancienne table ne connaissait que les lettres précomposées courantes,
/// deux écritures du même nom ne se rapprochaient donc pas (recherche,
/// ajout par artiste, rapprochement des imports JSON). Les autres écritures
/// (japonais, coréen…) sont conservées, recomposées en NFC.
String foldDiacritics(String input) {
  final String lower = input.toLowerCase();
  // Texte ASCII, le cas courant : rien à normaliser.
  if (_ascii.hasMatch(lower)) return lower;
  if (_foldCache.length >= _foldCacheLimit) _foldCache.clear();
  return _foldCache.putIfAbsent(lower, () {
    final String stripped = unorm.nfc(unorm.nfd(lower).replaceAll(_combiningDiacritics, ''));
    return stripped.replaceAllMapped(_undecomposable, (match) => _undecomposableFolds[match[0]]!);
  });
}

// ponytail: mémo plafonné, vidé d'un bloc au-delà de la limite — la
// recherche replie les mêmes titres à chaque frappe, et normaliser un texte
// accentué coûte ~20 µs (0,4 µs en ASCII). LRU si la limite devient gênante.
final Map<String, String> _foldCache = {};
const int _foldCacheLimit = 20000;

final RegExp _bracketed = RegExp(r'\([^)]*\)|\[[^\]]*\]');
final RegExp _featTail = RegExp(r'\s(feat|ft|featuring)\b.*$');
// Lettres de TOUT alphabet (et leurs signes), chiffres — même règle que
// buildSanitizedKey et ArtistNameNormalizer. Limitée à `[a-z0-9]`, la clé
// vidait les titres cyrilliques, asiatiques ou arabes : deux titres d'un même
// artiste s'y confondaient (dégrisage, import JSON). Clé inchangée en ASCII.
final RegExp _nonAlphanumeric = RegExp(r'[^\p{L}\p{M}\p{N}]+', unicode: true);

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
