import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Durée des transitions déclenchées par le mode immersif — partagée entre
/// `MasterPlayerScreen._PlayerPageState` (fondu des contrôles/pochette) et
/// `_TabShell` (repli de la barre de navigation, voir router.dart) pour que
/// tous les éléments qui réagissent à `playerImmersiveModeProvider`
/// transitionnent ensemble plutôt que de se désynchroniser visuellement.
const Duration kImmersiveTransitionDuration = Duration(milliseconds: 1500);

/// Mode Canvas immersif du Master Player (voir MasterPlayerScreen._PlayerPage)
/// — sorti de l'état local du widget pour que la coque de navigation
/// (`_TabShell`, router.dart) puisse à la fois le lire (pour décider si le
/// bouton Retour doit d'abord réduire le mode immersif plutôt que quitter
/// l'app, Section 2.B) et l'écrire (pour l'y forcer depuis l'extérieur).
class PlayerImmersiveMode extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool value) => state = value;
}

final NotifierProvider<PlayerImmersiveMode, bool> playerImmersiveModeProvider =
    NotifierProvider<PlayerImmersiveMode, bool>(PlayerImmersiveMode.new);
