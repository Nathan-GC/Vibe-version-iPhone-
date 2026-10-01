import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Droit d'opposition (RGPD, art. 21) à l'enrichissement en ligne
/// automatique après un import ou l'analyse initiale — activé par défaut.
/// Désactivé, l'import reste entièrement hors-ligne ; l'enrichissement
/// manuel (bouton ✨, "Enrichir tout", éditeur) reste disponible à la demande.
class AutoEnrichPreference extends Notifier<bool> {
  static const String _key = 'privacy.auto_enrich_on_import';

  /// Lecture directe du réglage enregistré, à utiliser aux points de
  /// décision plutôt que [state] (restauré en différé, comme les autres
  /// préférences) : un import lancé juste après le démarrage ne doit jamais
  /// contourner un refus.
  static Future<bool> isEnabled() async => (await SharedPreferences.getInstance()).getBool(_key) ?? true;

  // Un choix fait avant la fin de la restauration différée prime sur elle.
  bool _chosen = false;

  @override
  bool build() {
    Future.microtask(() async {
      final bool stored = await isEnabled();
      if (!_chosen) state = stored;
    });
    return true;
  }

  Future<void> set(bool enabled) async {
    _chosen = true;
    state = enabled;
    await (await SharedPreferences.getInstance()).setBool(_key, enabled);
  }
}

final NotifierProvider<AutoEnrichPreference, bool> autoEnrichOnImportProvider =
    NotifierProvider<AutoEnrichPreference, bool>(AutoEnrichPreference.new);
