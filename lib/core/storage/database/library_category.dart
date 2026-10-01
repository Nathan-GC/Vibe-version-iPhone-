import 'app_database.dart';

/// Les 3 catégories d'état de la Bibliothèque (filtres principaux +
/// "Changer de catégorie" sur un morceau). Dérivées UNIQUEMENT de
/// `requiresUserReview` + `enrichmentStatus` (voir [libraryCategoryOf]) —
/// pas de colonne dédiée : une catégorie forcée à la main reste ainsi
/// cohérente avec le circuit-breaker d'enrichissement automatique, et un
/// renommage/enrichissement ultérieur la fait évoluer naturellement.
///  - [toRename] : Titre/Artiste ambigus depuis le nom de fichier (ex-"À
///    vérifier"), à confirmer avant toute requête d'enrichissement.
///  - [toEnrich] : nom confirmé, jamais enrichi (`pending`) ou tentatives
///    automatiques épuisées (`needsManualReview`).
///  - [done] : renommé et enrichi, quelle qu'en soit la provenance.
enum LibraryCategory { toRename, toEnrich, done }

extension LibraryCategoryLabel on LibraryCategory {
  String get label => switch (this) {
        LibraryCategory.toRename => 'À renommer',
        LibraryCategory.toEnrich => 'À enrichir',
        LibraryCategory.done => 'Renommé et enrichi',
      };
}

/// Statuts "enrichi" : toute provenance d'enrichissement réussi — y compris
/// un passage forcé à la main via "Changer de catégorie", rangé sous
/// `enrichedManualEdit` (voir `TrackRepository.forceLibraryCategory`).
const Set<EnrichmentStatus> kEnrichedStatuses = {
  EnrichmentStatus.enrichedAutoItunes,
  EnrichmentStatus.enrichedAutoMusicBrainz,
  EnrichmentStatus.enrichedManualEdit,
  EnrichmentStatus.enrichedManualItunes,
  EnrichmentStatus.enrichedManualMusicBrainz,
};

LibraryCategory libraryCategoryOf(Track track) {
  if (track.requiresUserReview || track.enrichmentStatus == EnrichmentStatus.requiresReview) {
    return LibraryCategory.toRename;
  }
  if (kEnrichedStatuses.contains(track.enrichmentStatus)) return LibraryCategory.done;
  return LibraryCategory.toEnrich;
}
