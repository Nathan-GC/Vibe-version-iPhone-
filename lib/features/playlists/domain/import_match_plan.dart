import '../../../core/playlist_manifest/manifest_track_ref.dart';
import '../../../core/storage/database/app_database.dart';

/// Résultat du matching automatique d'un titre de manifeste JSON importé
/// contre la bibliothèque locale (voir ImportTrackMatcher).
enum ImportMatchStatus {
  /// Même clé exacte (titre + album + artiste) qu'un morceau local.
  exact,

  /// Même titre normalisé et même artiste, un seul candidat : sans ambiguïté.
  confident,

  /// Même titre et même artiste, mais plusieurs morceaux locaux possibles
  /// (versions, albums différents) : l'utilisateur tranche.
  ambiguous,

  /// Même titre mais chez un autre artiste : jamais associé d'office.
  titleOnly,

  /// Aucun titre équivalent en bibliothèque.
  notFound,
}

class ImportMatchEntry {
  const ImportMatchEntry({
    required this.index,
    required this.ref,
    required this.status,
    this.match,
    this.candidates = const [],
  });

  /// Position du titre dans le manifeste (= sa position dans la playlist).
  final int index;
  final ManifestTrackRef ref;
  final ImportMatchStatus status;

  /// Association automatique ([ImportMatchStatus.exact]/`confident` seulement).
  final Track? match;

  /// Suggestions proposées au matching manuel, meilleure d'abord.
  final List<Track> candidates;

  bool get isAutoMatched => match != null;
}

/// Plan d'import complet, un [ImportMatchEntry] par titre du manifeste,
/// dans l'ordre du manifeste.
class ImportMatchPlan {
  const ImportMatchPlan(this.entries);

  final List<ImportMatchEntry> entries;

  /// Titres qui passent par la fenêtre de matching manuel.
  List<ImportMatchEntry> get needsReview => entries.where((e) => !e.isAutoMatched).toList();

  bool get requiresManualReview => entries.any((e) => !e.isAutoMatched);

  int get autoMatchedCount => entries.where((e) => e.isAutoMatched).length;

  /// Résolution sans intervention : morceau associé automatiquement, sinon
  /// `null` (titre grisé). Même longueur et même ordre que [entries].
  List<String?> get autoResolution => [for (final ImportMatchEntry e in entries) e.match?.id];
}
