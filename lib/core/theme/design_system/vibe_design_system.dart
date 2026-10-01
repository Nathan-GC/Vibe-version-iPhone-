import 'package:flutter/material.dart';

/// Rayons d'arrondi standard du Design System (charte graphique inspirée de
/// Spotify) : formes douces et modernes pour les cartes/modales, et une
/// forme "Pill" entièrement arrondie pour les boutons d'action principale et
/// badges.
abstract final class AppRadii {
  /// Cartes (PlaylistCard, SuggestionCard...) et modales/bottom sheets.
  static const double card = 16;

  /// Variante plus resserrée pour les petits éléments (miniatures, chips).
  static const double cardCompact = 12;

  /// Boutons d'action principale et badges — assez grand pour dépasser la
  /// moitié de la hauteur d'un bouton standard et donner une forme pleinement
  /// arrondie ("Pill") quel que soit son padding.
  static const double pill = 30;
}

/// Formes prêtes à l'emploi dérivées de [AppRadii] — évite de reconstruire un
/// `RoundedRectangleBorder(borderRadius: BorderRadius.circular(...))`
/// identique à chaque écran.
abstract final class AppShapes {
  static const RoundedRectangleBorder card = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(AppRadii.card)),
  );

  static const RoundedRectangleBorder cardCompact = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(AppRadii.cardCompact)),
  );

  static const RoundedRectangleBorder pill = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(AppRadii.pill)),
  );

  /// Coins hauts arrondis seulement — feuilles modales (`showModalBottomSheet`).
  static const RoundedRectangleBorder modalTop = RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadii.card)),
  );
}

/// Fond sombre de référence façon Spotify (`#121212`) — sert de base à
/// [buildDarkTheme] avant application de la Vibe active (voir
/// `global_theme.dart`/`applyVibe`), plutôt que le gris Material 3 par défaut.
const Color kSpotifyDarkBackground = Color(0xFF121212);
