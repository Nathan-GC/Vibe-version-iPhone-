/// Échelle d'espacement standard du Design System — toute marge/padding de
/// l'app doit piocher dans ces 5 crans plutôt que des valeurs magiques
/// éparpillées, pour que la densité visuelle reste cohérente d'un écran à
/// l'autre (charte graphique inspirée de Spotify).
abstract final class AppSpacing {
  static const double xs = 4;
  static const double s = 8;
  static const double m = 16;
  static const double l = 24;
  static const double xl = 32;
}
