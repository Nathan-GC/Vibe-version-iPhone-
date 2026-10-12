import 'package:unorm_dart/unorm_dart.dart' as unorm;

import '../../identity/track_match_key.dart';

/// Scanner/nettoyeur d'artistes, partagé par tous les points d'entrée qui
/// écrivent un nom d'artiste en base (extraction ID3, correction manuelle) —
/// évite qu'un même artiste tagué avec des espaces superflus d'un fichier à
/// l'autre (ex. "Daft Punk " et "Daft  Punk") ne finisse par créer deux
/// entrées distinctes dans `track_artists`.
class ArtistNameNormalizer {
  static final RegExp _whitespace = RegExp(r'\s+');

  /// Trim + réduction des espaces multiples internes à un seul espace.
  static String normalize(String name) => name.trim().replaceAll(_whitespace, ' ');

  /// Découpe une chaîne d'artistes combinée (feat./ft./virgule/&/x) selon
  /// [splitPattern] puis normalise chaque partie — voir
  /// [MetadataExtractor._artistSplitPattern] pour le détail des frontières de
  /// mot qui empêchent de tronquer un nom comme "Daft Punk".
  static List<String> splitAndNormalize(String raw, RegExp splitPattern) {
    return raw.split(splitPattern).map(normalize).where((name) => name.isNotEmpty).toList();
  }

  /// Clé de regroupement insensible à la casse et à toute ponctuation/espace
  /// (ex. "Daft Punk", "DAFT-PUNK" et "DaftPunk" partagent la même clé
  /// "daftpunk"). Risque accepté : deux artistes réellement différents dont
  /// le nom ne diffère que par une ponctuation sémantique (ex. "will.i.am"
  /// vs un hypothétique artiste "William") seraient à tort regroupés — cas
  /// rare en pratique, largement compensé par les vrais doublons de
  /// casse/espacement qu'il permet de fusionner. Partagé par
  /// [TrackRepository.mergeDuplicateCaseArtists] (fusion permanente en base),
  /// [dedupeCaseInsensitive] (dédoublonnage en lecture seule, listes de
  /// sélection) et DriftArtistRepository.watchArtistTracks.
  ///
  /// Lot 2.2 : insensible aux accents quelle que soit leur forme Unicode
  /// ("Céline Dion" précomposé ou décomposé, et "Celine Dion" → "celinedion",
  /// voir [foldDiacritics]) ; lettres de TOUT alphabet conservées, avec leurs
  /// signes propres (dakuten japonais, voyelles devanagari) — limitée à
  /// `[a-z0-9]`, la clé fusionnait "宇多田ヒカル" et "아이유" (clé vide), ou
  /// "-M-" et "MØ". Nom sans lettre ni chiffre (ex. "!!!") : repli sur le nom
  /// lui-même en minuscules, jamais une clé vide.
  static String normalizeForGrouping(String name) {
    final String folded = foldDiacritics(name);
    final String key = folded.replaceAll(_nonAlphanumeric, '');
    return key.isEmpty ? folded.trim() : key;
  }

  static final RegExp _nonAlphanumeric = RegExp(r'[^\p{L}\p{M}\p{N}]', unicode: true);

  // Permet de retrouver les frontières de mots d'une variante collée
  // ("DaftPunk") quand aucune variante déjà espacée n'existe dans le groupe.
  static final RegExp _camelCaseBoundary = RegExp(r'(?<=[a-zA-Z0-9])(?=[A-Z][a-z])');

  /// Choisit le nom canonique d'un groupe de variantes (même clé
  /// [normalizeForGrouping]) : préfère une variante déjà correctement
  /// espacée (la plus longue, pour capter tout mot additionnel) plutôt que
  /// la première alphabétiquement — sans quoi fusionner "DaftPunk"/"Daft
  /// Punk" pourrait produire "Daftpunk" en canonique si la variante collée
  /// gagnait le tri. À défaut, retombe sur la variante en casse mixte
  /// (meilleur indice de frontières de mots) avec un espacement synthétique.
  ///
  /// Variantes recomposées en NFC (une écriture NFD du même nom n'est pas une
  /// variante de plus), et à longueur égale la plus accentuée l'emporte : une
  /// fusion ne remplace jamais "Céline Dion" par "Celine Dion".
  static String pickCanonical(Set<String> variants) {
    final Set<String> composed = {for (final String v in variants) unorm.nfc(v)};
    final Iterable<String> spaced = composed.where((v) => v.contains(' '));
    if (spaced.isNotEmpty) return toTitleCase(spaced.reduce(_richer));

    final Iterable<String> mixedCase = composed.where((v) => v != v.toUpperCase() && v != v.toLowerCase());
    final String source = (mixedCase.isNotEmpty ? mixedCase : composed).reduce(_richer);
    return toTitleCase(source.replaceAllMapped(_camelCaseBoundary, (m) => ' '));
  }

  /// La plus longue ; à longueur égale, celle qui compte le plus de lettres
  /// non ASCII (accentuées).
  static String _richer(String a, String b) {
    if (a.length != b.length) return b.length > a.length ? b : a;
    int nonAscii(String s) => s.runes.where((rune) => rune > 0x7f).length;
    return nonAscii(b) > nonAscii(a) ? b : a;
  }

  static String toTitleCase(String value) {
    return value.toLowerCase().split(' ').map((word) {
      if (word.isEmpty) return word;
      return word[0].toUpperCase() + word.substring(1);
    }).join(' ');
  }

  /// Une entrée canonique par groupe de variantes de casse/espacement/
  /// ponctuation (voir [normalizeForGrouping]/[pickCanonical]) — pour les
  /// listes de SÉLECTION uniquement (ex. "Ajouter par artiste", Section 3.A) :
  /// contrairement à [TrackRepository.mergeDuplicateCaseArtists], n'écrit
  /// rien en base, donc ne doit jamais servir là où l'utilisateur a besoin de
  /// voir/choisir chaque variante brute individuellement (ex. l'écran de
  /// Fusion Manuelle, voir ManualArtistFusionScreen). Le nom canonique
  /// retourné n'est pas forcément un match exact `=` pour CHAQUE variante
  /// d'origine — tout code qui interroge ensuite les morceaux par ce nom doit
  /// comparer par [normalizeForGrouping] (voir
  /// DriftArtistRepository.watchArtistTracks).
  static List<String> dedupeCaseInsensitive(Iterable<String> names) {
    final Map<String, Set<String>> variantsByNormalized = {};
    for (final name in names) {
      variantsByNormalized.putIfAbsent(normalizeForGrouping(name), () => {}).add(name);
    }
    return [for (final variants in variantsByNormalized.values) pickCanonical(variants)];
  }
}
