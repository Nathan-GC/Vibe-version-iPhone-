/// Nature d'une suggestion d'autocomplétion (Onglet Recherche) — pilote
/// l'icône affichée et l'action au tap (remplir le champ vs. naviguer
/// directement vers la fiche artiste).
enum SuggestionKind { track, artist, album, query }

/// Entrée du menu déroulant d'autocomplétion, mélangeant matchs locaux
/// (bibliothèque Drift, prioritaires) et matchs en ligne (iTunes Search).
class AutocompleteSuggestion {
  const AutocompleteSuggestion._({
    required this.kind,
    required this.label,
    this.subtitle,
    this.artworkUrl,
    this.isLocal = false,
  });

  /// Correspond à un titre déjà dans la bibliothèque locale.
  factory AutocompleteSuggestion.localTrack({required String title, required String artist}) {
    return AutocompleteSuggestion._(kind: SuggestionKind.track, label: title, subtitle: artist, isLocal: true);
  }

  /// Correspond à un nom d'artiste déjà présent localement — `label` sert
  /// aussi de nom exact pour la navigation directe vers son profil.
  factory AutocompleteSuggestion.localArtist(String name) {
    return AutocompleteSuggestion._(kind: SuggestionKind.artist, label: name, isLocal: true);
  }

  /// Correspond à un album déjà présent localement.
  factory AutocompleteSuggestion.localAlbum(String album) {
    return AutocompleteSuggestion._(kind: SuggestionKind.album, label: album, isLocal: true);
  }

  /// Morceau suggéré par l'API iTunes (pas encore dans la bibliothèque).
  factory AutocompleteSuggestion.onlineTrack({required String title, required String artist, String? artworkUrl}) {
    return AutocompleteSuggestion._(kind: SuggestionKind.track, label: title, subtitle: artist, artworkUrl: artworkUrl);
  }

  /// Artiste suggéré par l'API iTunes (aucun morceau local ne le mentionne) —
  /// comble les places restantes de la section Artistes quand la bibliothèque
  /// locale n'en fournit pas assez (voir AutocompleteRepository.suggest).
  factory AutocompleteSuggestion.onlineArtist(String name) {
    return AutocompleteSuggestion._(kind: SuggestionKind.artist, label: name);
  }

  /// Entrée de repli `Rechercher '<texte tapé>'`, toujours en dernière position.
  factory AutocompleteSuggestion.globalSearch(String text) {
    return AutocompleteSuggestion._(kind: SuggestionKind.query, label: text);
  }

  final SuggestionKind kind;
  final String label;
  final String? subtitle;
  final String? artworkUrl;
  final bool isLocal;
}
