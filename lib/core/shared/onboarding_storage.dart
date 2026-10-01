import 'package:shared_preferences/shared_preferences.dart';

/// Persiste si le scan plein-appareil du premier lancement (Étape 8) a déjà
/// été effectué. Tant que ce n'est pas le cas, [PlaylistApp] redirige vers
/// l'écran d'onboarding au lieu du shell principal.
class OnboardingStorage {
  static const String _keyCompleted = 'onboarding.full_scan_completed';

  Future<bool> isFirstLaunch() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return !(prefs.getBool(_keyCompleted) ?? false);
  }

  Future<void> markCompleted() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyCompleted, true);
  }
}
