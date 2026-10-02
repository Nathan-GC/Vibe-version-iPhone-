import 'package:shared_preferences/shared_preferences.dart';

/// Persiste si le scan plein-appareil du premier lancement (Étape 8) a déjà
/// été effectué. Tant que ce n'est pas le cas, [PlaylistApp] redirige vers
/// l'écran d'onboarding au lieu du shell principal.
class OnboardingStorage {
  static const String _keyCompleted = 'onboarding.full_scan_completed';
  static const String _keyLegalAccepted = 'legal.accepted_version';

  Future<bool> isFirstLaunch() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return !(prefs.getBool(_keyCompleted) ?? false);
  }

  Future<void> markCompleted() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyCompleted, true);
  }

  /// Étape 1 de l'onboarding : trace locale du consentement aux conditions
  /// d'utilisation et à la politique de confidentialité, sous la forme de la
  /// date de mise à jour des textes acceptés (Paramètres > Légal).
  Future<void> acceptLegal(String version) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyLegalAccepted, version);
  }

  /// `null` si aucun consentement n'a été donné (installation antérieure).
  Future<String?> acceptedLegalVersion() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyLegalAccepted);
  }
}
