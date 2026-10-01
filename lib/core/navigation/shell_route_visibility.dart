import 'package:flutter/widgets.dart';

/// Indique aux onglets de la coque de navigation (`_TabShell`, router.dart)
/// si la coque elle-même est la route au premier plan du Navigator RACINE.
///
/// Nécessaire parce que les sous-pages (/settings, fiche artiste, dialogues
/// `useRootNavigator`...) sont poussées sur ce Navigator racine, AU-DESSUS de
/// la coque : pour une page d'onglet comme le Lecteur, `ModalRoute.of`
/// renvoie la route de SON Navigator de branche, qui reste "courante" même
/// quand /settings recouvre tout l'écran. Seule la coque connaît sa propre
/// route racine — elle la publie via ce widget, que le Lecteur écoute
/// (`isCurrentOf` crée une dépendance : `didChangeDependencies` est rappelé
/// à chaque ouverture/fermeture d'une sous-page).
class ShellRouteVisibility extends InheritedWidget {
  const ShellRouteVisibility({super.key, required this.isCurrent, required super.child});

  final bool isCurrent;

  /// `true` hors coque (widget testé isolément) : ne bloque jamais rien.
  static bool isCurrentOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ShellRouteVisibility>()?.isCurrent ?? true;

  @override
  bool updateShouldNotify(ShellRouteVisibility oldWidget) => isCurrent != oldWidget.isCurrent;
}
