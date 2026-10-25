import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Index de l'onglet actif de la coque de navigation (0 = Recherche, 1 = Lecteur,
/// 2 = Espace). Écrit par `_TabShell` dès que `navigationShell.currentIndex`
/// change, quelle que soit la cause (barre de navigation, bouton Retour,
/// `context.go` programmatique) ; les onglets qui doivent se réinitialiser au
/// changement d'onglet (ex. la Recherche) l'écoutent.
class ActiveTabIndex extends Notifier<int> {
  @override
  int build() => 0;

  void set(int value) => state = value;
}

final NotifierProvider<ActiveTabIndex, int> activeTabIndexProvider =
    NotifierProvider<ActiveTabIndex, int>(ActiveTabIndex.new);
